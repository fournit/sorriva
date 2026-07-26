import Foundation
import SMBClient

// MARK: - MediaSourceEntry
// One directory entry as reported by a MediaSourceReader. Mirrors the subset
// of SMBClient.Entry that SMBScanner actually needs — nothing more.

struct MediaSourceEntry: Sendable {
    let name: String
    let isDirectory: Bool
    let size: Int
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
            MediaSourceEntry(name: $0.name, isDirectory: $0.isDirectory, size: Int($0.size))
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
        walkClient = nil
    }

    // MARK: - Header read (fresh connection per call)

    nonisolated func readHeader(path: String, byteCount: Int) async throws -> Data {
        let host = self.host
        let share = self.share
        let username = self.username
        let password = self.password

        return try await withCheckedThrowingContinuation { continuation in
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<Data, Error> = .failure(MediaSourceReaderError.timeout)

            Task.detached {
                let name = (path as NSString).lastPathComponent
                let client = SMBClient(host: host)

                // Each stage caught separately — a single catch-all previously
                // reported auth and share-connect failures as read failures,
                // making STATUS_LOGON_FAILURE from the server look like a file problem.
                do {
                    try await client.login(username: username.isEmpty ? "guest" : username, password: password)
                } catch {
                    result = .failure(MediaSourceReaderError.auth(name: name, underlying: error))
                    semaphore.signal()
                    return
                }

                do {
                    try await client.connectShare(share)
                } catch {
                    try? await client.logoff()
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
                semaphore.signal()
            }

            DispatchQueue.global(qos: .utility).async {
                if semaphore.wait(timeout: .now() + 15) == .timedOut {
                    result = .failure(MediaSourceReaderError.timeout)
                }
                continuation.resume(with: result)
            }
        }
    }
}
