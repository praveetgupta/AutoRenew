import Foundation

public enum Log {
    private static let queue = DispatchQueue(label: "com.autorenew.log")
    private static let suppressionLock = NSLock()
    private static var suppressed = false

    public static var logURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return library.appendingPathComponent("Logs/AutoRenew.log")
    }

    /// Runs `body` with logging turned off. Tests drive real code paths with fake devices, and
    /// their invented names landing in the diagnostic log would mislead anyone reading it after a
    /// genuine failure.
    public static func quiet<T>(_ body: () throws -> T) rethrows -> T {
        suppressionLock.lock()
        suppressed = true
        suppressionLock.unlock()
        defer {
            queue.sync {}   // let anything already queued drain before logging resumes
            suppressionLock.lock()
            suppressed = false
            suppressionLock.unlock()
        }
        return try body()
    }

    private static var isSuppressed: Bool {
        suppressionLock.lock()
        defer { suppressionLock.unlock() }
        return suppressed
    }

    public static func event(_ message: String) {
        guard !isSuppressed else { return }
        queue.async {
            write(message)
        }
    }

    private static func write(_ message: String) {
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded(url)
        let line = "[\(logFormatter.string(from: Date()))] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 2_000_000 else { return }
        let old = url.deletingPathExtension().appendingPathExtension("log.old")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    private static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
