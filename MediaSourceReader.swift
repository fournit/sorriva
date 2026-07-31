import Foundation
import SMBClient

// MARK: - MediaSourceEntry
// One directory entry as reported by a MediaSourceReader. Mirrors the subset
// of SMBClient.Entry that SMBScanner actually needs — nothing more.

struct MediaSourceEntry: Sendable {
    let name: String
    let isDirectory: Bool
    let size: Int

    /// Last write time, used by change detection.
    ///
    /// fUnifiedScanWalkThenFilter: a folder is considered unchanged only if file
    /// count, total bytes AND newest modification time all match the stored
    /// stat. Count and bytes alone cannot see a tag-only edit — external taggers
    /// write into the FLAC PADDING block that exists for exactly that purpose,
    /// so the file size is identical afterward (bTagEditsNotDetected).
    ///
    /// This matters more under the unified model than the old one: a manual
    /// rescan used to re-read every header, which was the de facto workaround
    /// for retagging. Once manual and automatic share the same skip logic, that
    /// workaround is gone, so mtime is what keeps the model honest.
    let modifiedAt: Date
}

// MARK: - MediaSourceReader
// Seam extracted from SMBScanner so the scanner can be exercised against
// fixture files in tests, without a live NAS. Two responsibilities only —
// directory listing and reading file headers. Recursion, throttling,
// cancellation, tag parsing, and identity resolution all stay in SMBScanner;
// none of that belongs behind this seam.
//
// bScannerTestSeam — sorriva-scanner-handoff-2026-07-25.md §5.1

protocol MediaSourceReader: Sendable {
    /// List entries in a single directory (non-recursive). Caller builds full
    /// paths from `path` + each entry's `name`.
    func listDirectory(path: String) async throws -> [MediaSourceEntry]

    /// Read up to `byteCount` bytes from the start of the file at `path`.
    func readHeader(path: String, byteCount: Int) async throws -> Data
}

// MARK: - MediaSourceReaderError

enum MediaSourceReaderError: Error {
    case auth(name: String, underlying: Error)
    case share(name: String, underlying: Error)
    case read(name: String, underlying: Error)
    case timeout
    case unsupported
}

// MARK: - SMBMediaSourceReader
// Production implementation. Reproduces SMBScanner's existing I/O behavior
// exactly — these two connection patterns are empirically tuned for the
// UNAS Pro and must not change:
//   - listDirectory reuses ONE authenticated connection across the whole
//     walk (call closeWalkConnection() when the walk finishes).
//   - readHeader opens a brand-new SMBClient per call and tears it down
//     immediately after. The UNAS Pro drops sessions after two sequential
//     reads on one connection, so a persistent connection for tag reads
//     is not safe — this is why the two methods have different lifecycles.
//
// Implemented as an actor for safe concurrent access to walkClient from
// SMBScanner (itself an actor) without introducing a second layer of locking.

actor SMBMediaSourceReader: MediaSourceReader {

    private let host: String
    private let share: String
    private let username: String
    private let password: String

    private var walkClient: SMBClient?

    init(source: LibrarySource) {
        self.host = source.host
        self.share = source.share
        let creds = source.resolvedCredentials
        self.username = creds.username
        self.password = creds.password
    }

    // MARK: - Directory listing (one shared connection)

    func listDirectory(path: String) async throws -> [MediaSourceEntry] {
        let client = try await connectedWalkClient()
        let entries = try await client.listDirectory(path: path)
        return entries.map {
            // SMBClient.File exposes lastWriteTime as a Date, derived from the
            // SMB2 FileStat the directory query already returns — no extra
            // round trip, and no fork needed.
            MediaSourceEntry(
                name: $0.name,
                isDirectory: $0.isDirectory,
                size: Int($0.size),
                modifiedAt: $0.lastWriteTime
            )
        }
    }

    private func connectedWalkClient() async throws -> SMBClient {
        if let existing = walkClient { return existing }
        let client = SMBClient(host: host)
        try await client.login(username: username.isEmpty ? "guest" : username, password: password)
        try await client.connectShare(share)
        walkClient = client
        return client
    }

    /// Call once the directory walk is finished. Mirrors the `defer`-based
    /// teardown that used to live inline in SMBScanner.scanFolders/statFolders.
    func closeWalkConnection() async {
        guard let client = walkClient else { return }
        try? await client.disconnectShare()
        try? await client.logoff()
        client.session.disconnect()
        walkClient = nil
    }

    // MARK: - Header read (fresh connection per call)

    nonisolated func readHeader(path: String, byteCount: Int) async throws -> Data {
        let host = self.host
        let share = self.share
        let username = self.username
        let password = self.password
        let name = (path as NSString).lastPathComponent

        // Created here, outside Task.detached, so both the background work AND
        // the timeout handler below can reach the same client instance. This is
        // what makes force-cancellation on timeout possible.
        let client = SMBClient(host: host)

        return try await withCheckedThrowingContinuation { continuation in
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<Data, Error> = .failure(MediaSourceReaderError.timeout)

            Task.detached {
                // Each stage caught separately — a single catch-all previously
                // reported auth and share-connect failures as read failures,
                // making STATUS_LOGON_FAILURE from the server look like a file problem.
                do {
                    try await client.login(username: username.isEmpty ? "guest" : username, password: password)
                } catch {
                    // Explicit cleanup even on auth failure — login() can still have
                    // established the underlying connection before the server
                    // rejected credentials, so there may be a real connection to
                    // release here, not just a no-op.
                    try? await client.logoff()
                    client.session.disconnect()
                    result = .failure(MediaSourceReaderError.auth(name: name, underlying: error))
                    semaphore.signal()
                    return
                }

                do {
                    try await client.connectShare(share)
                } catch {
                    try? await client.logoff()
                    client.session.disconnect()
                    result = .failure(MediaSourceReaderError.share(name: name, underlying: error))
                    semaphore.signal()
                    return
                }

                do {
                    let reader = client.fileReader(path: path)
                    let readLength = UInt32(byteCount)
                    let data = try await reader.read(offset: 0, length: readLength)
                    try? await reader.close()
                    result = .success(data)
                } catch {
                    result = .failure(MediaSourceReaderError.read(name: name, underlying: error))
                }

                try? await client.disconnectShare()
                try? await client.logoff()
                // THE fix for bScanConnectionExhaustionOnRepeatedScans.
                //
                // SMBClient never calls NWConnection.cancel() anywhere in the
                // library: Session.disconnect() is the only path that reaches it
                // and nothing invokes it, SMBClient exposes no wrapper for it,
                // and there is no deinit on Connection/Session/SMBClient. So
                // logoff() sends the SMB2 LOGOFF frame and zeroes sessionId while
                // leaving the TCP connection open — every read leaked one kernel
                // flow entry against a hard per-process ceiling of exactly 512.
                //
                // `session` is a public property and Session.disconnect() is
                // public, so the seam is reachable without forking. Measured
                // 2026-07-29: identical churn harness failed at exactly 512
                // without this line, and completed 600 connections with it.
                //
                // It also eliminated the unexplained session stalls (previously
                // ~1 per 90 connections, zero across 600 after this change) —
                // the NAS was almost certainly refusing service to a client
                // holding hundreds of abandoned sockets.
                client.session.disconnect()
                semaphore.signal()
            }

            DispatchQueue.global(qos: .utility).async {
                if semaphore.wait(timeout: .now() + 15) == .timedOut {
                    result = .failure(MediaSourceReaderError.timeout)
                    // The Task.detached above is still running at this point — Swift
                    // Task cancellation is cooperative and SMBClient's own async
                    // methods never check for it, so simply abandoning the task
                    // would leave it (and its connection) running indefinitely if
                    // the underlying network operation is genuinely hung, not just
                    // slow. Force-cancelling the connection directly is reliable
                    // regardless: NWConnection.cancel() completes any outstanding
                    // receive/send with an error, which unblocks whatever the stuck
                    // task is awaiting, letting it exit and run its own (now
                    // redundant) cleanup.
                    //
                    // session.disconnect() replaces the previous logoff() here.
                    // logoff() sends an SMB2 frame and awaits a response, which on
                    // a genuinely hung connection may never arrive — so the very
                    // call meant to break the hang could itself hang. disconnect()
                    // goes straight to NWConnection.cancel(): synchronous, no
                    // round-trip, no live session required. It is also the only
                    // call that actually releases the kernel flow entry.
                    //
                    // Deliberately NOT counted via noteReleased() here: the
                    // detached task above is still alive and will run its own
                    // teardown (which does count) once cancel() unblocks its
                    // read. Counting in both places would double-count. If a
                    // detached task ever fails to complete, the balance will show
                    // it as outstanding — which is exactly what we want to see.
                    client.session.disconnect()
                }
                continuation.resume(with: result)
            }
        }
    }
}
