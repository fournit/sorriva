import Foundation

// MARK: - SorrivaLogger
// Debug log facility for playback diagnostics.
// Active in DEBUG builds only — no-ops in release.
// Writes timestamped entries to Documents/sorriva-debug.log.
// Rotates to sorriva-debug-prev.log at 5MB.
// Export via Settings → Debug → Share Log.

#if DEBUG

final class SorrivaLogger {

    static let shared = SorrivaLogger()

    private let logFileName = "sorriva-debug.log"
    private let prevLogFileName = "sorriva-debug-prev.log"
    private let maxBytes = 5 * 1024 * 1024  // 5MB
    private let queue = DispatchQueue(label: "sorriva.logger", qos: .utility)
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
        openLog()
    }

    // MARK: - Public

    func log(_ message: String) {
        let line = "[\(timestamp())] \(message)\n"
        print(message)  // Still print to Xcode console
        queue.async { [weak self] in
            self?.write(line)
        }
    }

    var logFileURL: URL { logURL }

    func clearLog() {
        queue.async { [weak self] in
            guard let self else { return }
            self.fileHandle?.closeFile()
            self.fileHandle = nil
            try? FileManager.default.removeItem(at: self.logURL)
            try? FileManager.default.removeItem(at: self.prevLogURL)
            self.openLog()
            self.write("[\(self.timestamp())] Log cleared\n")
        }
    }

    // MARK: - Private

    private func openLog() {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logURL)
        fileHandle?.seekToEndOfFile()
        write("[\(timestamp())] --- Sorriva log opened ---\n")
    }

    private func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }

        // Rotate if over 5MB
        if let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxBytes {
            fileHandle?.closeFile()
            fileHandle = nil
            try? FileManager.default.removeItem(at: prevLogURL)
            try? FileManager.default.moveItem(at: logURL, to: prevLogURL)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: logURL)
            fileHandle?.seekToEndOfFile()
            write("[\(timestamp())] --- Log rotated ---\n")
        }

        fileHandle?.write(data)
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

// No-ops in release builds
func sLog(_ message: String) {}

#endif
