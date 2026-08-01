import Foundation

// MARK: - SorrivaLogger
// Debug log facility for playback diagnostics.
// Writes timestamped entries to Documents/sorriva-debug.log.
// Rotates to sorriva-debug-prev.log at 1MB — keeps total under 2MB.
// Export via Settings → Debug → Share Log.

// MARK: - ScanLogSession
// fScanSessionLogCorrelation.
//
// A scan writes under three prefixes — SCAN, ARTWORK and RETRY — with nothing
// tying them to a run. Neither Console's filter nor a text search can express
// "SCAN or ARTWORK or RETRY", so following one scan meant three separate
// searches and manual interleaving by timestamp.
//
// Tagging those three categories with the run's short session id turns that into
// one search:
//
//     SCAN [3A10C9D2]: filter — skipping 104 file(s) in 9 unchanged folders
//     ARTWORK [3A10C9D2]: embedded [1/2] — Special EFX · Collection
//     RETRY [3A10C9D2]: === PASS 1 START ===
//
// The tag goes AFTER the category, not before, so existing habits still work:
// searching "SCAN" still finds scan lines, "3A10C9D2" finds the whole run, and
// "ARTWORK [3A10C9D2]" finds one phase of one run. Category stays first so the
// log still reads in aligned columns.
//
// A resumed scan reuses the interrupted run's session id, so a single search
// spans the original attempt, the kill, and the resume — the sequence that is
// hardest to follow otherwise.

enum ScanLogSession {
    /// Task-local, NOT a single global.
    ///
    /// It was a global, and a second scan starting while the first was still in
    /// its artwork phase called begin() and clobbered the first scan's tag. The
    /// 2026-08-01 phase 1 run shows it plainly: three separate runs where the id
    /// changes partway through (A04FDA45 -> 85A3A2FB) and the artwork audit line
    /// comes out untagged entirely. The ledger was correct throughout; only the
    /// log became unsearchable, which defeats the one property
    /// fScanSessionLogCorrelation exists to provide.
    ///
    /// A task-local is scoped to the task that binds it and to that task's
    /// children, so two concurrent pipelines cannot interfere by construction —
    /// no locking, no ownership rules to get wrong.
    @TaskLocal static var current: String?

    /// Fallback for log calls made from outside any bound task — DispatchQueue
    /// closures and other non-structured contexts, where a task-local reads as
    /// nil. Correct in the common single-scan case and harmless otherwise,
    /// since the task-local always wins when present.
    private static let lock = NSLock()
    private static var ambient: String?

    /// Categories that belong to a scan run. Everything else (ZONES, CONTEXT,
    /// PROBE) is unrelated and stays untagged rather than adding noise.
    ///
    /// LEDGER is included deliberately: those lines ARE the audit summary, and
    /// an untagged summary is unsearchable in precisely the way this tagging
    /// exists to prevent. They were omitted when LEDGER was added as a category
    /// after this list was written.
    private static let taggedPrefixes = ["SCAN: ", "ARTWORK: ", "RETRY: ", "LEDGER: "]

    static func shortId(_ sessionId: String) -> String {
        String(sessionId.prefix(8)).uppercased()
    }

    /// Run `operation` with every SCAN/ARTWORK/RETRY line inside it — including
    /// in child tasks — tagged with this session.
    static func with<T>(_ sessionId: String, operation: () async -> T) async -> T {
        await $current.withValue(shortId(sessionId)) {
            await operation()
        }
    }

    static func begin(_ sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        ambient = shortId(sessionId)
    }

    static func end() {
        lock.lock(); defer { lock.unlock() }
        ambient = nil
    }

    /// Rewrites "SCAN: foo" as "SCAN [3A10C9D2]: foo" while a run is active.
    /// Returns the message unchanged when no run is active or the category is
    /// not part of the pipeline.
    static func decorate(_ message: String) -> String {
        let id: String?
        if let scoped = current {
            id = scoped
        } else {
            lock.lock(); id = ambient; lock.unlock()
        }
        guard let id else { return message }
        for prefix in taggedPrefixes where message.hasPrefix(prefix) {
            let category = String(prefix.dropLast(2))   // strip ": "
            let body = String(message.dropFirst(prefix.count))
            return "\(category) [\(id)]: \(body)"
        }
        return message
    }
}

#if DEBUG

final class SorrivaLogger {

    static let shared = SorrivaLogger()

    private let logFileName     = "sorriva-debug.log"
    private let prevLogFileName = "sorriva-debug-prev.log"
    // Raised from 256KB for full-library scan runs. A 11,670-file scan emits
    // roughly 5,000 lines (one per folder-done, one per album resolved, progress
    // every 50, plus both artwork passes iterating ~562 albums) — around 650KB,
    // so 256KB would rotate two or three times mid-scan and lose the beginning,
    // which is exactly the part that shows how the run started.
    //
    // The original 256KB was chosen to keep export and in-app viewing responsive.
    // 8MB is comfortably past any single scan but is a large file to share, so
    // this is a deliberate trade for the current phase rather than a permanent
    // default. See the log-handling options discussed 2026-07-31: on-demand
    // upload to the share, multi-file rotation, or verbosity levels.
    private let maxBytes        = 8 * 1024 * 1024
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
        // Session tagging applied centrally so every existing call site gets it
        // without change — SCAN, ARTWORK and RETRY lines are emitted from four
        // different files.
        let tagged = ScanLogSession.decorate(message)
        let line = "[\(timestamp())] \(tagged)\n"
        print(tagged)
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
        // Rotation is SIZE-driven only — see write(). It deliberately does NOT
        // happen on launch.
        //
        // It used to. That meant the log was discarded at exactly the moment it
        // mattered most: relaunching after a crash or a kill moved everything to
        // the prev file and opened an empty one, so exporting immediately after
        // an interruption showed nothing. This made every kill/resume test
        // unobservable and cost real debugging time on 2026-07-29 and
        // 2026-07-30 (bLogRotatesOnLaunchDestroyingCrashEvidence). Diagnostics
        // that erase themselves on failure are worse than no diagnostics,
        // because they look like evidence of nothing happening.
        //
        // Cost of appending instead: the log spans multiple launches. The launch
        // marker below makes boundaries obvious, and 256KB still bounds it.
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logURL)
        fileHandle?.seekToEndOfFile()
        if let data = "[\(timestamp())] ===== APP LAUNCH =====\n".data(using: .utf8) {
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
        // Force to disk on every line. Without this, anything still sitting in
        // the file buffer is lost when the app is killed — which is precisely
        // the scenario the log exists to explain. The cost is one fsync per
        // line on a utility queue; at scan volumes that is not measurable
        // against the SMB reads happening alongside it.
        try? fileHandle?.synchronize()
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
