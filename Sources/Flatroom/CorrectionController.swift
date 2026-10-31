import AppKit
import AudioEngine
import CoreAudio
import Foundation

/// Decides when and where the correction runs. Each output device can have its own filter (the
/// filter corrects the speakers and room behind that device). The tap goes to the system output if
/// it has one; otherwise to another connected device that has one, since apps can send audio to it
/// directly. Restarts the tap when the target device, its sample rate or its filter changes.
/// All Core Audio work happens on `queue`; `onChange` is called on the main queue.
final class CorrectionController {
    enum State: Equatable {
        case disabled
        case waiting(String)
        case starting
        case running(device: String, sampleRate: Int, latencyMs: Int)
        case failed(String)
    }

    struct Config: Equatable {
        var deviceID: AudioObjectID
        var sampleRate: Double
        var filter: String
        var excludedApps: [String]
    }

    var onChange: (() -> Void)?
    private(set) var state: State = .disabled
    /// Filter directories in `filtersURL` (each with a meta.json), by name.
    private(set) var filters: [String]

    // Set from the main thread; the audio queue works on its own copies (`want…`).
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "enabled")
            let value = enabled
            queue.async { self.wantEnabled = value; self.scheduleReconcile() }
        }
    }
    /// Filter per output device, keyed by device UID. Devices without an entry play uncorrected.
    var deviceFilters: [String: String] {
        didSet {
            UserDefaults.standard.set(deviceFilters, forKey: "deviceFilters")
            let value = deviceFilters
            queue.async { self.wantDeviceFilters = value; self.scheduleReconcile() }
        }
    }
    /// Bundle IDs of apps that play straight to the device, uncorrected and without our latency
    /// (DAWs). Defaults to GarageBand.
    var excludedApps: [String] {
        didSet {
            UserDefaults.standard.set(excludedApps, forKey: "excludedApps")
            let value = excludedApps
            queue.async { self.wantExcludedApps = value; self.scheduleCallCheck(); self.scheduleReconcile() }
        }
    }
    /// Apps in a call (recording and playing at once) play straight to the device while the call
    /// lasts, like `excludedApps`: our filter's latency would put their audio out of sync with the
    /// video and confuse their echo cancellation.
    var callsUncorrected: Bool {
        didSet {
            UserDefaults.standard.set(callsUncorrected, forKey: "callsUncorrected")
            let value = callsUncorrected
            queue.async { self.wantCallsUncorrected = value; self.scheduleCallCheck() }
        }
    }
    /// Apps currently in a call and playing uncorrected (empty unless `callsUncorrected`).
    private(set) var callApps: [String] = []
    /// Run the interface at the sample rate of what Apple Music is playing (no conversion by macOS).
    var autoSampleRate: Bool {
        didSet { UserDefaults.standard.set(autoSampleRate, forKey: "autoSampleRate") }
    }
    var bypass = false {
        didSet { queue.async { self.passthrough?.engine?.bypass = self.bypass } }
    }
    /// 0...1 like the system volume; mapped to -50...0 dB (0 = silence).
    var volume: Float {
        didSet { UserDefaults.standard.set(volume, forKey: "volume"); applyGain() }
    }
    var muted: Bool {
        didSet { UserDefaults.standard.set(muted, forKey: "muted"); applyGain() }
    }
    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }
    /// The target device is the system output, so the volume keys are meant for it.
    private(set) var isSystemOutput = false

    static func gain(volume: Float, muted: Bool) -> Float {
        guard !muted, volume > 0 else { return 0 }
        return powf(10, 50 * (min(volume, 1) - 1) / 20)
    }

    let filtersURL: URL
    private let queue = DispatchQueue(label: "flatroom.audio")
    private var passthrough: TapPassthrough?
    private var runningConfig: Config?
    private var observers: [AudioPropertyObserver] = []
    private var rateObserver: (id: AudioObjectID, observer: AudioPropertyObserver)?
    private var pending: DispatchWorkItem?
    private var wantEnabled: Bool
    private var wantDeviceFilters: [String: String]
    private var wantExcludedApps: [String]
    private var wantFilters: [String]
    private var wantCallsUncorrected: Bool
    private var wantCallApps: [String] = []
    private var processObservers: [AudioObjectID: [AudioPropertyObserver]] = [:]
    private var pendingCallCheck: DispatchWorkItem?
    private var wantGain: Float
    private var queueState: State = .disabled

    init(filtersURL: URL) {
        self.filtersURL = filtersURL
        filters = Self.listFilters(in: filtersURL)
        wantFilters = filters
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        deviceFilters = defaults.dictionary(forKey: "deviceFilters") as? [String: String] ?? [:]
        volume = defaults.object(forKey: "volume") as? Float ?? 1
        muted = defaults.bool(forKey: "muted")
        excludedApps = defaults.stringArray(forKey: "excludedApps") ?? ["com.apple.garageband10"]
        autoSampleRate = defaults.object(forKey: "autoSampleRate") as? Bool ?? true
        callsUncorrected = defaults.object(forKey: "callsUncorrected") as? Bool ?? true
        wantEnabled = enabled
        wantDeviceFilters = deviceFilters
        wantExcludedApps = excludedApps
        wantCallsUncorrected = callsUncorrected
        wantGain = Self.gain(volume: volume, muted: muted)
    }

    static func listFilters(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0)/meta.json").path) }
            .sorted()
    }

    /// Picks up filters added or removed in the folder. With `replaced`, that filter's files changed:
    /// reload it if it's the one running.
    func reloadFilters(replaced: String? = nil) {
        let list = Self.listFilters(in: filtersURL)
        guard list != filters || replaced != nil else { return }
        filters = list
        queue.async {
            self.wantFilters = list
            if let replaced, self.runningConfig?.filter == replaced { self.runningConfig = nil }
            self.scheduleReconcile()
        }
    }

    private func applyGain() {
        let value = Self.gain(volume: volume, muted: muted)
        queue.async {
            self.wantGain = value
            self.passthrough?.setOutputGain(value)
        }
    }

    func start() {
        queue.async {
            let reconcile: () -> Void = { [weak self] in self?.scheduleReconcile() }
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
                if let observer = try? AudioPropertyObserver.system(selector, queue: self.queue, handler: reconcile) {
                    self.observers.append(observer)
                }
            }
            if let observer = try? AudioPropertyObserver.system(kAudioHardwarePropertyProcessObjectList, queue: self.queue,
                                                                handler: { [weak self] in self?.watchProcesses() }) {
                self.observers.append(observer)
            }
            self.watchProcesses()
            self.reconcile()
        }
    }

    /// Output peak since the last call (dBFS), or nil if not running.
    func peakSinceLastCheck() -> Float? {
        queue.sync {
            guard let passthrough, case .running = queueState else { return nil }
            return passthrough.readStats().outputPeak
        }
    }

    /// Apple Music started a track at `rate`: switch the interface to it. The rate listener then
    /// restarts the tap with that rate's filter. Left alone while a DAW from `excludedApps` is open,
    /// since it runs the interface at its project's rate.
    func matchSourceRate(_ rate: Double) {
        guard autoSampleRate else { return }
        let dawOpen = excludedApps.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        queue.async {
            // Music plays to the system output: act only when that's the device we correct.
            guard let id = self.runningConfig?.deviceID, (try? AudioDevice.defaultOutput())?.id == id,
                  let device = ((try? AudioDevice.all()) ?? []).first(where: { $0.id == id }),
                  device.sampleRate != rate else { return }
            if let dawOpen {
                return Log.write("Music at \(Int(rate)) Hz: keeping \(Int(device.sampleRate)) Hz, \(dawOpen) is open")
            }
            guard device.availableSampleRates().contains(rate) else {
                return Log.write("Music at \(Int(rate)) Hz: not supported by \(device.name)")
            }
            do {
                try device.setSampleRate(rate)
                Log.write("Music at \(Int(rate)) Hz: \(device.name) \(Int(device.sampleRate)) → \(Int(rate)) Hz")
            } catch {
                Log.write("Music at \(Int(rate)) Hz: \(error)")
            }
        }
    }

    func stopForQuit() {
        queue.sync { stopTap() }
    }

    // MARK: - Audio queue

    /// Coalesces bursts of device notifications (creating our own aggregate fires a few).
    private func scheduleReconcile() {
        queue.async {
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reconcile() }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func reconcile() {
        guard wantEnabled else {
            stopTap()
            return setState(.disabled)
        }
        let devices = (try? AudioDevice.all()) ?? []
        let systemOutputID = (try? AudioDevice.defaultOutput())?.id
        let withFilter = devices.filter {
            $0.outputChannels >= 2 && wantDeviceFilters[$0.uid].map(wantFilters.contains) == true
        }
        guard let device = withFilter.first(where: { $0.id == systemOutputID }) ?? withFilter.first,
              let filter = wantDeviceFilters[device.uid] else {
            stopTap()
            DispatchQueue.main.async { self.isSystemOutput = false }
            return setState(.waiting("no connected output has a profile"))
        }
        watchSampleRate(of: device.id)
        let systemOutput = device.id == systemOutputID
        DispatchQueue.main.async { self.isSystemOutput = systemOutput }

        let excluded = wantExcludedApps + wantCallApps
        let config = Config(deviceID: device.id, sampleRate: device.sampleRate, filter: filter,
                            excludedApps: excluded)
        if config == runningConfig, passthrough != nil { return }

        stopTap()
        setState(.starting)
        let tap = TapPassthrough(device: device) { Log.write($0) }
        tap.filterDirectory = filtersURL.appendingPathComponent(filter)
        tap.excludedBundleIDs = excluded
        tap.setOutputGain(wantGain)
        do {
            // Blocks while macOS waits for the audio-capture permission on first launch.
            try tap.start()
            tap.engine?.bypass = bypass
            passthrough = tap
            runningConfig = config
            let latency = tap.engine.map { Double($0.totalLatencyFrames) / device.sampleRate * 1000 } ?? 0
            if tap.engine == nil {
                Log.write("no filter loaded: running as plain passthrough")
            }
            setState(.running(device: device.name, sampleRate: Int(device.sampleRate), latencyMs: Int(latency.rounded())))
        } catch {
            tap.stop()
            Log.write("start failed: \(error)")
            setState(.failed("\(error)"))
        }
    }

    /// Follows when each audio process starts or stops recording and playing.
    private func watchProcesses() {
        let ids = audioProcessObjects()
        processObservers = processObservers.filter { ids.contains($0.key) }
        for id in ids where processObservers[id] == nil {
            processObservers[id] = [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput].compactMap {
                try? AudioPropertyObserver(object: id, selector: $0, queue: queue) { [weak self] in self?.scheduleCallCheck() }
            }
        }
        scheduleCallCheck()
    }

    /// Waits for things to settle so a short recording (a dictation chime) doesn't restart the tap:
    /// that would cut the audio of every other app for a moment.
    private func scheduleCallCheck() {
        pendingCallCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkCalls() }
        pendingCallCheck = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func checkCalls() {
        let own = Bundle.main.bundleIdentifier
        let apps = wantCallsUncorrected
            ? audioProcessBundleIDs(inCall: true).filter { $0 != own && !wantExcludedApps.contains($0) }.sorted()
            : []
        guard apps != wantCallApps else { return }
        Log.write(apps.isEmpty ? "call ended: correcting all apps" : "call: \(apps) play uncorrected")
        wantCallApps = apps
        DispatchQueue.main.async { self.callApps = apps; self.onChange?() }
        scheduleReconcile()
    }

    private func watchSampleRate(of id: AudioObjectID) {
        guard rateObserver?.id != id else { return }
        rateObserver = (try? AudioPropertyObserver(object: id, selector: kAudioDevicePropertyNominalSampleRate,
                                                   queue: queue) { [weak self] in self?.scheduleReconcile() })
            .map { (id, $0) }
    }

    private func stopTap() {
        guard let passthrough else { return }
        passthrough.stop()
        self.passthrough = nil
        runningConfig = nil
        Log.write("stopped")
    }

    private func setState(_ new: State) {
        guard new != queueState else { return }
        queueState = new
        Log.write("state: \(new)")
        DispatchQueue.main.async {
            self.state = new
            self.onChange?()
        }
    }
}
