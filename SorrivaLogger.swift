import Foundation

// MARK: - SorrivaLogger
// Debug log facility for playback diagnostics.
// Writes timestamped entries to Documents/sorriva-debug.log.
// Rotates to sorriva-debug-prev.log at 1MB — keeps total under 2MB.
// Export via Settings → Debug → Share Log.

#if DEBUG

final class SorrivaLogger {

    static let shared = SorrivaLogger()

    private let logFileName     = "sorriva-debug.log"
    private let prevLogFileName = "sorriva-debug-prev.log"
    private let maxBytes        = 1 * 1024 * 1024  // 1MB — keeps log accessible
    private let queue           = DispatchQueue(label: "sorriva.logger", qos: .utility)
    private var fileHandle: FileHandle?

    private lazy var logURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(logFileName)
    }()
    private lazy var prevLogURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(prevLogFileName)
    }()

    private init() {
        queue.async { [weak self] in self?.openLog() }
    }

    // MARK: - Public

    func log(_ message: String) {
        let line = "[\(timestamp())] \(message)\n"
        print(message)
        queue.async { [weak self] in self?.write(line) }
    }

    var logFileURL: URL { logURL }

    func clearLog() {
        queue.async { [weak self] in
            guard let self else { return }
            fileHandle?.closeFile()
            fileHandle = nil
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: prevLogURL)
            openLog()
        }
    }

    // MARK: - Private

    private func openLog() {
        // Truncate on open if already over limit — prevents lock on export
        if let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxBytes {
            rotate()
            return
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logURL)
        fileHandle?.seekToEndOfFile()
        if let data = "[\(timestamp())] --- Sorriva log opened ---\n".data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    private func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        // Rotate if over limit — non-recursive
        if let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxBytes {
            rotate()
        }
        fileHandle?.write(data)
    }

    private func rotate() {
        fileHandle?.closeFile()
        fileHandle = nil
        try? FileManager.default.removeItem(at: prevLogURL)
        try? FileManager.default.moveItem(at: logURL, to: prevLogURL)
        let dir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else { return }
        fileHandle = try? FileHandle(forWritingTo: logURL)
        fileHandle?.seekToEndOfFile()
        if let data = "[\(timestamp())] --- Log rotated ---\n".data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}

// MARK: - Convenience global function

func sLog(_ message: String) {
    SorrivaLogger.shared.log(message)
}

#else

func sLog(_ message: String) {}

#endif
