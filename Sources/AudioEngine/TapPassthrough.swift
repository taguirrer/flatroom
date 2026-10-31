import Accelerate
import CoreAudio
import Foundation

/// Captures every process's audio headed for one output device (except ours), mutes the
/// original, and plays it back to the same device through a private aggregate device.
/// This is the skeleton the correction filter will plug into: `process` is where DSP goes.
public final class TapPassthrough {
    public struct Stats {
        public var cycles: UInt64 = 0
        public var frames: UInt64 = 0
        /// Cycles where tap and output frame counts differed (should stay 0: same clock).
        public var mismatchedCycles: UInt64 = 0
        public var inputPeak: Float = 0
        public var outputPeak: Float = 0
    }

    /// Output volume, applied after the correction. `current` ramps to `target` within one buffer.
    struct Gain {
        var target: Float = 1
        var current: Float = 0  // fade in on start
    }

    public let device: AudioDevice
    public private(set) var tapFormat = AudioStreamBasicDescription()
    /// Directory with `fir_<rate>.wav` files; nil (or no file for the rate) means plain passthrough.
    public var filterDirectory: URL?
    /// Apps left out of the tap (e.g. a DAW): their audio reaches the device directly, uncorrected
    /// and without our latency. Matched by bundle ID, so it holds across app launches.
    public var excludedBundleIDs: [String] = []
    public private(set) var engine: ConvolutionEngine?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let stats = UnsafeMutablePointer<Stats>.allocate(capacity: 1)
    private let gain = UnsafeMutablePointer<Gain>.allocate(capacity: 1)
    private var log: (String) -> Void

    public init(device: AudioDevice, log: @escaping (String) -> Void = { print($0) }) {
        self.device = device
        self.log = log
        stats.initialize(to: Stats())
        gain.initialize(to: Gain())
    }

    deinit {
        stop()
        stats.deallocate()
        gain.deallocate()
    }

    /// Linear output gain (0 = silence, 1 = unity). Safe to call from any thread.
    public func setOutputGain(_ value: Float) {
        gain.pointee.target = max(0, value)
    }

    public func start() throws {
        let ownProcess = try? currentProcessObject()
        let excluded = ownProcess.map { $0 == kAudioObjectUnknown ? [] : [$0] } ?? []

        let tapDescription = CATapDescription(excludingProcesses: excluded, deviceUID: device.uid, stream: 0)
        if #available(macOS 26.0, *), !excludedBundleIDs.isEmpty {
            // Name ourselves too, in case the bundle list takes precedence over the process list:
            // tapping our own output would feed it back into the tap.
            tapDescription.bundleIDs = excludedBundleIDs + [Bundle.main.bundleIdentifier].compactMap { $0 }
        }
        tapDescription.name = "Flatroom tap"
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        // Muted only while we read it: if we crash or stop, the original audio comes back.
        tapDescription.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "AudioHardwareCreateProcessTap")
        tapFormat = try getValue(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        log("tap \(tapID) excluding=\(excluded) \(excludedBundleIDs) format: \(Int(tapFormat.mSampleRate)) Hz, \(tapFormat.mChannelsPerFrame) ch")

        if let filterDirectory {
            do {
                let firs = try FIRSet.load(directory: filterDirectory, sampleRate: tapFormat.mSampleRate)
                engine = ConvolutionEngine(firs: firs, channelCount: Int(tapFormat.mChannelsPerFrame))
                log("filter \(filterDirectory.lastPathComponent): \(firs.channels.count) ch x \(firs.channels[0].count) taps, gain \(firs.gainDB) dB")
            } catch {
                log("no filter for \(Int(tapFormat.mSampleRate)) Hz (\(error.localizedDescription)); passthrough only")
            }
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Flatroom (\(device.name))",
            kAudioAggregateDeviceUIDKey: "flatroom.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: false,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                  "AudioHardwareCreateAggregateDevice")

        // The aggregate's input = the device's own input streams, then the tap stream(s).
        let inputStreams: [AudioObjectID] = try getArray(aggregateID, kAudioDevicePropertyStreams,
                                                         scope: kAudioObjectPropertyScopeInput)
        let skip = min(device.inputStreams, inputStreams.count)
        let stats = self.stats
        let gain = self.gain
        let engine = self.engine

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            TapPassthrough.process(input: input, output: output, skipInputBuffers: skip, engine: engine,
                                   gain: gain, stats: stats)
        }, "AudioDeviceCreateIOProcIDWithBlock")

        disableDeviceInputs(streamCount: inputStreams.count, skip: skip)
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        log("running: aggregate \(aggregateID), \(inputStreams.count) input streams (skipping \(skip) from \(device.name))")
    }

    public func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        engine = nil
    }

    /// Returns counters since start; peaks are reset on every call.
    public func readStats() -> Stats {
        let snapshot = stats.pointee
        stats.pointee.inputPeak = 0
        stats.pointee.outputPeak = 0
        return snapshot
    }

    /// We only need the tap, so ask the HAL not to run the device's own input streams
    /// (avoids opening the interface's preamps/mic inputs).
    private func disableDeviceInputs(streamCount: Int, skip: Int) {
        guard let procID, streamCount > 0, skip > 0 else { return }
        var addr = address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        let headerSize = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        var size = UInt32(headerSize + streamCount * MemoryLayout<UInt32>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(streamCount), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        var status = AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, raw)
        if status == noErr {
            for i in 0..<skip {
                raw.storeBytes(of: UInt32(0), toByteOffset: headerSize + i * MemoryLayout<UInt32>.size, as: UInt32.self)
            }
            status = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, size, raw)
        }
        log(status == noErr ? "device inputs disabled for our IOProc"
                            : "could not disable device inputs (\(CoreAudioError(what: "stream usage", status: status)))")
    }

    // MARK: Real-time thread: no allocation, no locks, no logging.

    private static func process(input: UnsafePointer<AudioBufferList>,
                                output: UnsafeMutablePointer<AudioBufferList>,
                                skipInputBuffers: Int,
                                engine: ConvolutionEngine?,
                                gain: UnsafeMutablePointer<Gain>,
                                stats: UnsafeMutablePointer<Stats>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        var inPeak: Float = 0
        var outPeak: Float = 0
        var frames = 0
        var mismatched = false
        let gainFrom = gain.pointee.current, gainTo = gain.pointee.target

        // Walk output channels in order and copy the tap channel with the same global index.
        var tapBuffer = skipInputBuffers
        var tapChannel = 0
        for (index, out) in outputs.enumerated() {
            guard let outData = out.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outCh = Int(out.mNumberChannels)
            let outFrames = Int(out.mDataByteSize) / (MemoryLayout<Float>.size * max(outCh, 1))
            frames = max(frames, outFrames)
            vDSP_vclr(outData, 1, vDSP_Length(outFrames * outCh))

            for ch in 0..<outCh {
                while tapBuffer < inputs.count, tapChannel >= Int(inputs[tapBuffer].mNumberChannels) {
                    tapBuffer += 1
                    tapChannel = 0
                }
                guard tapBuffer < inputs.count,
                      let inData = inputs[tapBuffer].mData?.assumingMemoryBound(to: Float.self) else { break }
                let inCh = Int(inputs[tapBuffer].mNumberChannels)
                let inFrames = Int(inputs[tapBuffer].mDataByteSize) / (MemoryLayout<Float>.size * inCh)
                if inFrames != outFrames { mismatched = true }
                let n = min(inFrames, outFrames)
                // Strided copy (gain 1): interleaved channel `tapChannel` → interleaved channel `ch`.
                var unity: Float = 1
                vDSP_vsmul(inData + tapChannel, inCh, &unity, outData + ch, outCh, vDSP_Length(n))
                tapChannel += 1
            }

            // Correction runs in place on the device's first (interleaved) output stream, the one
            // the tap mirrors; interfaces that split their outputs into several streams keep the rest as is.
            if let engine, index == 0, outCh == engine.channelCount {
                engine.process(outData, outData, frames: outFrames)
            }

            // Volume: ramp from the current to the target gain across this buffer (no zipper noise).
            if gainFrom != 1 || gainTo != 1, outFrames > 0 {
                var step = (gainTo - gainFrom) / Float(outFrames)
                for ch in 0..<outCh {
                    var start = gainFrom
                    vDSP_vrampmul(outData + ch, outCh, &start, &step, outData + ch, outCh, vDSP_Length(outFrames))
                }
            }

            var peak: Float = 0
            vDSP_maxmgv(outData, 1, &peak, vDSP_Length(outFrames * outCh))
            outPeak = max(outPeak, peak)
        }

        for i in skipInputBuffers..<inputs.count {
            guard let data = inputs[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
            var peak: Float = 0
            vDSP_maxmgv(data, 1, &peak, vDSP_Length(Int(inputs[i].mDataByteSize) / MemoryLayout<Float>.size))
            inPeak = max(inPeak, peak)
        }

        gain.pointee.current = gainTo
        stats.pointee.cycles &+= 1
        stats.pointee.frames &+= UInt64(frames)
        if mismatched { stats.pointee.mismatchedCycles &+= 1 }
        stats.pointee.inputPeak = max(stats.pointee.inputPeak, inPeak)
        stats.pointee.outputPeak = max(stats.pointee.outputPeak, outPeak)
    }
}
