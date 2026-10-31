import Foundation

/// Reports the sample rate of each track Apple Music starts playing, so the interface can run at
/// the track's own rate instead of macOS converting it. Music logs it when it builds the audio
/// queue for a new format ("Creating AudioQueue with format:'qlac', …, sampleRate:96000, …"); we
/// follow the unified log with `log stream`, which needs no special permission.
final class MusicSampleRate {
    var onRate: ((Double) -> Void)?

    private var process: Process?
    private var buffer = ""
    private var stopped = false

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    private func launch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = ["stream", "--style", "compact", "--predicate",
                          #"process == "Music" AND eventMessage CONTAINS "Creating AudioQueue with format""#]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(String(decoding: data, as: UTF8.self)) }
        }
        // `log stream` shouldn't exit on its own; if it does, start it again.
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard let self, !self.stopped else { return }
                Log.write("Music sample-rate follower: log stream exited, restarting")
                self.launch()
            }
        }
        do {
            try task.run()
            process = task
        } catch {
            Log.write("Music sample-rate follower: \(error)")
        }
    }

    private func consume(_ text: String) {
        buffer += text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if let range = line.range(of: #"sampleRate:\d+"#, options: .regularExpression),
               let rate = Double(line[range].dropFirst("sampleRate:".count)), rate > 0 {
                onRate?(rate)
            }
        }
    }
}
