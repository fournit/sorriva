import Foundation
@testable import Sorriva

// MARK: - FixtureMediaSourceReader
// Test-only MediaSourceReader implementation backed by a local directory of
// real fixture files, instead of a live SMB share. Lets SMBScanner's actual
// production code run under XCTest.
//
// bScannerTestSeam — sorriva-scanner-handoff-2026-07-25.md §5.1

final class FixtureMediaSourceReader: MediaSourceReader, @unchecked Sendable {

    private let rootURL: URL

    // MARK: - Interruption hooks (fScanLedgerUnitTests)
    //
    // A scan interrupted at a precise, repeatable point is the only way to test
    // resume without a real app kill. These closures are called before each
    // read/list; throwing from one simulates the process dying at exactly that
    // file, every run, with no timing games.
    //
    // The counters also serve as assertions in their own right: a rescan of an
    // unchanged library should perform ZERO header reads, and readCount proves
    // it rather than inferring from elapsed time.

    private let lock = NSLock()
    private var _readCount = 0
    private var _listCount = 0
    private var _readPaths: [String] = []

    /// Called before each header read. Throw to simulate a mid-scan kill.
    var beforeRead: ((_ path: String, _ callNumber: Int) throws -> Void)?

    /// Called before each directory listing. Throw to simulate a kill during
    /// the walk, which is a different failure window — the walk runs before any
    /// file is read, so there is no partial result to keep.
    var beforeList: ((_ path: String, _ callNumber: Int) throws -> Void)?

    // Counter access goes through SYNCHRONOUS helpers.
    //
    // NSLock.lock() is unavailable from an async context in Swift 6 — the
    // compiler cannot prove the lock is not held across a suspension point.
    // Keeping every acquire/release inside a non-async function satisfies that
    // and is also simply correct: nothing here awaits while holding it.

    /// Header reads performed since construction.
    var readCount: Int { withLock { _readCount } }

    /// Directory listings performed since construction.
    var listCount: Int { withLock { _listCount } }

    /// Every path read, in order. Lets a test assert WHICH files were touched,
    /// not merely how many.
    var readPaths: [String] { withLock { _readPaths } }

    func resetCounters() {
        withLock { () -> Void in
            _readCount = 0
            _listCount = 0
            _readPaths = []
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Bump the read counter and return the call number, synchronously.
    private func noteRead(_ path: String) -> Int {
        withLock { () -> Int in
            _readCount += 1
            _readPaths.append(path)
            return _readCount
        }
    }

    private func noteList() -> Int {
        withLock { () -> Int in
            _listCount += 1
            return _listCount
        }
    }

    /// Make the Nth read FAIL (1-based) — a read error, not a kill.
    ///
    /// The scanner catches read failures, records a `skipped` outcome with a
    /// reason, and carries on. So this simulates a bad file or an unresponsive
    /// NAS, NOT the app dying.
    func failReadNumber(_ n: Int, error: Error = MediaSourceReaderError.timeout) {
        beforeRead = { _, call in if call == n { throw error } }
    }

    /// Simulate the app being KILLED after N successful reads.
    ///
    /// This is a genuinely different thing from a read failure, and conflating
    /// the two produced two false test failures on 2026-08-02: `failReadNumber`
    /// was used to mean "kill here", but the scan simply recorded that file as
    /// skipped and ran to completion, leaving nothing outstanding to resume.
    ///
    /// Cancelling the enclosing task is faithful, because cancellation is what
    /// the scan loop actually checks — `if Task.isCancelled { throw
    /// CancellationError() }` at the top of each file — so the loop stops mid-
    /// pass and the remaining ledger rows stay `planned`, exactly as they would
    /// after a real termination.
    func cancelScanAfterReads(_ n: Int) {
        beforeRead = { _, call in
            guard call > n else { return }
            // Cancel the TASK, do not throw. readFileHeader has a catch-all that
            // turns any thrown error into a recorded read failure, so throwing
            // here would be swallowed and the scan would run to completion —
            // which is precisely the mistake that produced two false failures.
            //
            // The fixture's readHeader is called directly from the scan task, so
            // the current task IS the scan. Cancelling it makes the loop's
            // `if Task.isCancelled { throw CancellationError() }` fire at the
            // next file, stopping the pass with rows still `planned`.
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    /// - Parameter rootURL: local directory standing in for the SMB share root.
    ///   Paths passed to listDirectory/readHeader use the same shape SMBScanner
    ///   already produces — a leading "/" relative to the share root, e.g.
    ///   "/TestArtist/TestAlbum/01 Track One.flac".
    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private func absoluteURL(for path: String) -> URL {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return relative.isEmpty ? rootURL : rootURL.appendingPathComponent(relative)
    }

    func listDirectory(path: String) async throws -> [MediaSourceEntry] {
        let listCall = noteList()
        try beforeList?(path, listCall)

        let dirURL = absoluteURL(for: path)
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        )
        // Sorted for deterministic test ordering — FileManager.contentsOfDirectory
        // makes no ordering guarantee otherwise, which would make any test that
        // depends on processing order (e.g. "first occurrence wins") flaky.
        let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try sorted.map { url in
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            )
            return MediaSourceEntry(
                name: url.lastPathComponent,
                isDirectory: values.isDirectory ?? false,
                size: values.fileSize ?? 0,
                // Real filesystem mtime, not a stub — a fixture that fabricated
                // this would not exercise the change detection it exists to
                // verify. LedgerTestFixtures.touchPreservingSize moves it while
                // holding size constant, which is the tag-edit case.
                modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            )
        }
    }

    func readHeader(path: String, byteCount: Int) async throws -> Data {
        let readCall = noteRead(path)
        try beforeRead?(path, readCall)

        let fileURL = absoluteURL(for: path)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        return handle.readData(ofLength: byteCount)
    }
}

// MARK: - FixtureInterrupt

/// Errors a fixture can be told to throw.
///
/// `killed` stands in for the process dying mid-scan. `timeout` maps onto the
/// real MediaSourceReaderError.timeout so the ledger records failureKind
/// `.timeout` — which matters, because a timeout deliberately does NOT consume
/// a retry attempt while a content failure does.
enum FixtureInterrupt: Error {
    case killed
}
