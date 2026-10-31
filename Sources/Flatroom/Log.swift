import Foundation

/// Appends timestamped lines to ~/Library/Logs/Flatroom.log. At 1 MB the log moves to
/// Flatroom.log.1 (replacing the previous one) and starts over, so it never takes more than 2 MB.
enum Log {
    private static let maxBytes: UInt64 = 1 << 20
    private static let queue = DispatchQueue(label: "flatroom.log")
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Flatroom.log")
    // Only touched on `queue`.
    nonisolated(unsafe) private static var handle: FileHandle? = open()

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.async {
            if let size = try? handle?.offset(), size >= maxBytes { rotate() }
            handle?.write(Data(line.utf8))
        }
    }

    private static func open() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }

    private static func rotate() {
        try? handle?.close()
        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        handle = open()
    }
}
