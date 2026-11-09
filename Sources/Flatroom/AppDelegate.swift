import AppKit
import AudioEngine
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var controller: CorrectionController!
    private let volumeKeys = VolumeKeys()
    private let hud = VolumeHUD()
    private let musicRate = MusicSampleRate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let filters = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Flatroom/Filters")
        try? FileManager.default.createDirectory(at: filters, withIntermediateDirectories: true)
        controller = CorrectionController(filtersURL: filters)
        controller.onChange = { [weak self] in self?.refreshIcon() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        Log.write("launched, filters: \(controller.filters)")
        controller.start()

        // Only when the interface is the system output; otherwise the keys stay with macOS.
        volumeKeys.shouldHandle = { [weak self] in
            guard let controller = self?.controller else { return false }
            return controller.isRunning && controller.isSystemOutput
        }
        volumeKeys.onKey = { [weak self] key, fine in self?.handle(key, fine: fine) }
        volumeKeys.start()

        musicRate.onRate = { [weak self] rate in self?.controller.matchSourceRate(rate) }
        musicRate.start()
    }

    // Opening Flatroom through a symlink (the Homebrew install in ~/Applications) can hand the
    // link itself to the app as a document. Flatroom opens no documents, so ignore it; without
    // this AppKit shows "cannot open files in the symbolic link format".
    func application(_ application: NSApplication, open urls: [URL]) {
        Log.write("ignored open request: \(urls.map(\.path))")
    }

    // MARK: Volume

    private func handle(_ key: VolumeKeys.Key, fine: Bool) {
        let step: Float = fine ? 1 / 64 : 1 / 16
        switch key {
        case .mute:
            controller.muted.toggle()
        case .up, .down:
            let delta = key == .up ? step : -step
            // Snap to the step grid like macOS, then move one step.
            let snapped = (controller.volume / step).rounded() * step
            controller.volume = min(1, max(0, snapped + delta))
            controller.muted = false
        }
        hud.show(volume: controller.volume, muted: controller.muted)
    }

    @objc private func volumeSliderChanged(_ sender: NSSlider) {
        controller.volume = Float(sender.doubleValue)
        controller.muted = false
    }

    private func volumeItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 30))
        let icon = NSImageView(frame: NSRect(x: 18, y: 7, width: 18, height: 16))
        icon.image = NSImage(systemSymbolName: controller.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                             accessibilityDescription: "Volume")
        icon.contentTintColor = .secondaryLabelColor
        let slider = NSSlider(value: Double(controller.muted ? 0 : controller.volume), minValue: 0, maxValue: 1,
                              target: self, action: #selector(volumeSliderChanged(_:)))
        slider.frame = NSRect(x: 42, y: 5, width: 200, height: 20)
        slider.isContinuous = true
        view.addSubview(icon)
        view.addSubview(slider)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    func applicationWillTerminate(_ notification: Notification) {
        musicRate.stop()
        controller.stopForQuit()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        controller.reloadFilters()

        menu.addItem(disabledItem(statusText()))
        if case let .running(device, _, _) = controller.state, !controller.isSystemOutput {
            menu.addItem(disabledItem("The system output has no profile: correcting apps that play to \(device)"))
        }
        if !controller.callApps.isEmpty {
            let names = controller.callApps.map(appName).joined(separator: ", ")
            menu.addItem(disabledItem("In a call: \(names) plays directly, no correction or latency"))
        }
        if controller.isRunning {
            for id in audioProcessBundleIDs() where CorrectionController.isMeasurementApp(id) {
                menu.addItem(disabledItem(controller.excludedApps.contains(id)
                    ? "\(appName(id)) plays directly: ready to measure the room"
                    : "\(appName(id)) plays corrected: to measure the room, add it to Uncorrected apps"))
            }
        }
        if let peak = controller.peakSinceLastCheck(), peak > 0 {
            let db = 20 * log10(peak)
            menu.addItem(disabledItem(String(format: "Output peak: %.1f dBFS%@", db, db > -0.1 ? "  ⚠︎ clipping" : "")))
        }
        menu.addItem(.separator())

        menu.addItem(disabledItem(String(format: "Volume: %@", volumeText())))
        menu.addItem(volumeItem())
        menu.addItem(.separator())

        menu.addItem(item("Correction enabled", #selector(toggleEnabled), state: controller.enabled))
        let bypass = item("Compare without correction (bypass)", #selector(toggleBypass), state: controller.bypass)
        bypass.isEnabled = controller.enabled
        menu.addItem(bypass)

        menu.addItem(profilesItem())
        menu.addItem(excludedAppsItem())
        menu.addItem(item("Calls without correction (automatic)", #selector(toggleCallsUncorrected),
                          state: controller.callsUncorrected))
        menu.addItem(item("Automatic sample rate (Apple Music)", #selector(toggleAutoSampleRate),
                          state: controller.autoSampleRate))

        menu.addItem(.separator())
        menu.addItem(item("Open at login", #selector(toggleLoginItem),
                          state: SMAppService.mainApp.status == .enabled))
        menu.addItem(item("Show log…", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    private func volumeText() -> String {
        let gain = CorrectionController.gain(volume: controller.volume, muted: controller.muted)
        return gain > 0 ? String(format: "%.0f dB", 20 * log10(gain)) : "muted"
    }

    private func statusText() -> String {
        switch controller.state {
        case .disabled: return "Correction disabled"
        case .waiting(let why): return "Waiting — \(why)"
        case .starting: return "Starting… (may ask for audio permission)"
        case let .running(device, rate, latency):
            let mode = controller.bypass ? "BYPASS" : "Correcting"
            let khz = (Double(rate) / 1000).formatted(.number.precision(.fractionLength(0...1)))
            return "\(mode) · \(device) · \(khz) kHz · \(latency) ms"
        case .failed(let error): return "Error: \(error)"
        }
    }

    private func refreshIcon() {
        let symbol: String
        switch controller.state {
        case .running: symbol = controller.bypass ? "waveform.circle" : "waveform"
        case .failed: symbol = "exclamationmark.triangle"
        case .starting: symbol = "ellipsis"
        default: symbol = "waveform.slash"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Flatroom")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = statusText()

        // The interface's clock rate next to the icon while correcting, e.g. "44,1" or "96".
        if case let .running(_, rate, _) = controller.state {
            let khz = Double(rate) / 1000
            let text = khz.formatted(.number.precision(.fractionLength(0...1)))
            statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .baselineOffset: 0.5,
            ])
            statusItem.button?.imagePosition = .imageLeading
        } else {
            statusItem.button?.title = ""
            statusItem.button?.imagePosition = .imageOnly
        }
    }

    private func item(_ title: String, _ action: Selector, state: Bool? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let state { item.state = state ? .on : .off }
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        controller.enabled.toggle()
        refreshIcon()
    }

    @objc private func toggleBypass() {
        controller.bypass.toggle()
        refreshIcon()
    }

    /// One entry per output device: which filter it uses ("No correction" or one of the filters).
    /// The filter belongs to the speakers and room behind the device, so the same one can serve
    /// several interfaces wired to the same monitors.
    private func profilesItem() -> NSMenuItem {
        var corrected: String?
        if case let .running(device, _, _) = controller.state { corrected = device }
        let devices = ((try? AudioDevice.all()) ?? []).filter {
            $0.outputChannels >= 2 && !$0.uid.hasPrefix("flatroom.")
        }

        let submenu = NSMenu()
        submenu.addItem(disabledItem("Filter per output (✓ = correcting now)"))
        for device in devices {
            let current = controller.deviceFilters[device.uid]
            let choices = NSMenu()
            for name in [nil] + controller.filters.map(Optional.some) {
                let entry = item(name ?? "No correction", #selector(selectProfile(_:)), state: name == current)
                entry.representedObject = [device.uid, name ?? ""]
                choices.addItem(entry)
            }
            let entry = NSMenuItem(title: "\(device.name): \(current ?? "no correction")", action: nil, keyEquivalent: "")
            entry.state = device.name == corrected ? .on : .off
            entry.submenu = choices
            submenu.addItem(entry)
        }

        if controller.filters.isEmpty {
            submenu.addItem(disabledItem("No filters yet: import one to start"))
        }
        submenu.addItem(.separator())
        submenu.addItem(item("Import Filter…", #selector(importFilter)))
        submenu.addItem(item("Show Filters Folder", #selector(showFiltersFolder)))

        let parent = NSMenuItem(title: "Output profiles", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        controller.deviceFilters[pair[0]] = pair[1].isEmpty ? nil : pair[1]
    }

    /// Builds a filter from impulse-response WAVs (e.g. REW's "Export filter impulse response").
    @objc private func importFilter() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Import Filter"
        panel.message = "Choose the filter's impulse response: one WAV, or one per sample rate (192 kHz gives the best result)."
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls

        let alert = NSAlert()
        alert.messageText = "Filter name"
        alert.informativeText = "Shown in Output profiles. Importing again with the same name replaces it."
        let field = NSTextField(string: urls[0].deletingPathExtension().lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.hasPrefix(".") else { return }

        let folder = controller.filtersURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Build it aside, then swap it in, so the engine never loads a half-written filter.
            let staging = folder.appendingPathComponent(".import-\(UUID().uuidString)")
            let target = folder.appendingPathComponent(name)
            do {
                try FilterImport.importFilter(from: urls, to: staging)
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
                } else {
                    try FileManager.default.moveItem(at: staging, to: target)
                }
                Log.write("imported filter \(name) from \(urls.map(\.lastPathComponent))")
                DispatchQueue.main.async { self?.controller.reloadFilters(replaced: name) }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                Log.write("import failed: \(error)")
                DispatchQueue.main.async { NSAlert(error: error).runModal() }
            }
        }
    }

    @objc private func showFiltersFolder() {
        NSWorkspace.shared.open(controller.filtersURL)
    }

    /// Apps that play straight to the interface: the ones already chosen plus any app that has
    /// opened audio, so a DAW shows up here once it has been launched.
    private func excludedAppsItem() -> NSMenuItem {
        let workspace = NSWorkspace.shared
        let own = Bundle.main.bundleIdentifier
        var candidates = controller.excludedApps
        for id in audioProcessBundleIDs() where id != own && !candidates.contains(id)
            && workspace.urlForApplication(withBundleIdentifier: id) != nil {
            candidates.append(id)
        }
        let submenu = NSMenu()
        submenu.addItem(disabledItem("Play directly: no correction, no latency"))
        for id in candidates.sorted(by: { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }) {
            let entry = item(appName(id), #selector(toggleExcludedApp(_:)), state: controller.excludedApps.contains(id))
            entry.representedObject = id
            if let url = workspace.urlForApplication(withBundleIdentifier: id) {
                let icon = workspace.icon(forFile: url.path)
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
            }
            submenu.addItem(entry)
        }

        let names = controller.excludedApps.map(appName)
        let title = names.isEmpty ? "Uncorrected apps" : "Uncorrected: \(names.joined(separator: ", "))"
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    /// "Google Chrome" for both com.google.Chrome and its helper (which is what plays a web call).
    private func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
            .replacingOccurrences(of: #" Helper( \(.*\))?$"#, with: "", options: .regularExpression)
    }

    @objc private func toggleExcludedApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if let index = controller.excludedApps.firstIndex(of: id) {
            controller.excludedApps.remove(at: index)
        } else {
            controller.excludedApps.append(id)
        }
    }

    @objc private func toggleCallsUncorrected() {
        controller.callsUncorrected.toggle()
    }

    @objc private func toggleAutoSampleRate() {
        controller.autoSampleRate.toggle()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("login item: \(error)")
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Flatroom.log"))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
