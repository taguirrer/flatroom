import AudioEngine
import Foundation

// Usage: TapTest [--device <name substring>] [--seconds N] [--log <file>]
//                [--filter <dir>] [--ab <seconds>] [--exclude <bundle ID>]...
// Runs the tap passthrough on one output device (default: the system output) and prints stats once per second.
// With --filter the correction is applied; --ab alternates correction/bypass (level-matched)
// every N seconds and shows a notification on each switch.

var deviceQuery: String?
var seconds = 20.0
var logURL: URL?
var filterURL: URL?
var abInterval: Double?
var excludedBundleIDs: [String] = []

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--device": deviceQuery = args.next()
    case "--seconds": seconds = Double(args.next() ?? "") ?? seconds
    case "--log": logURL = args.next().map { URL(fileURLWithPath: $0) }
    case "--filter": filterURL = args.next().map { URL(fileURLWithPath: $0) }
    case "--ab": abInterval = Double(args.next() ?? "")
    case "--exclude": args.next().map { excludedBundleIDs.append($0) }
    default: break
    }
}

func notify(_ text: String) {
    let script = "display notification \"\(text)\" with title \"Flatroom\""
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    try? task.run()
}

if let logURL { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
let logHandle = logURL.flatMap { try? FileHandle(forWritingTo: $0) }

func log(_ message: String) {
    let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
    FileHandle.standardOutput.write(Data(line.utf8))
    logHandle?.write(Data(line.utf8))
}

func dB(_ x: Float) -> String { x > 0 ? String(format: "%.1f dBFS", 20 * log10(x)) : "-inf" }

do {
    let devices = try AudioDevice.all()
    devices.forEach { log("device \($0)") }
    log("default output: \(try AudioDevice.defaultOutput().name)")

    let systemOutput = try AudioDevice.defaultOutput()
    guard let device = deviceQuery.map({ query in
        devices.first { $0.outputChannels > 0 && $0.name.localizedCaseInsensitiveContains(query) }
    }) ?? systemOutput else {
        log("no output device matching '\(deviceQuery ?? "")'")
        exit(1)
    }
    log("target: \(device)")

    let passthrough = TapPassthrough(device: device, log: log)
    passthrough.filterDirectory = filterURL
    passthrough.excludedBundleIDs = excludedBundleIDs
    try passthrough.start()

    for signo in [SIGINT, SIGTERM] {
        signal(signo) { _ in exit(0) }
    }

    let begin = Date()
    let end = begin.addingTimeInterval(seconds)
    var lastState: Bool?
    if passthrough.engine != nil { notify("Correction ON") }
    while Date() < end {
        Thread.sleep(forTimeInterval: 1)
        if let abInterval, let engine = passthrough.engine {
            let bypass = Int(Date().timeIntervalSince(begin) / abInterval) % 2 == 1
            if bypass != lastState {
                engine.bypass = bypass
                lastState = bypass
                let label = bypass ? "Correction OFF (bypass)" : "Correction ON"
                log("== \(label)")
                notify(label)
            }
        }
        let s = passthrough.readStats()
        let state = passthrough.engine.map { $0.bypass ? "bypass" : "corr" } ?? "thru"
        log("[\(state)] cycles=\(s.cycles) frames=\(s.frames) mismatched=\(s.mismatchedCycles) in=\(dB(s.inputPeak)) out=\(dB(s.outputPeak))")
    }
    passthrough.stop()
    log("stopped cleanly")
} catch {
    log("error: \(error)")
    exit(1)
}
