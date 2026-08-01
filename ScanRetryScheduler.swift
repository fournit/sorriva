import Foundation
import UIKit
import SMBClient

// MARK: - ScanRetryScheduler
// Runs after the full scan pipeline completes:
//   scan → folder art → iTunes art → 30s wait → embedded art → [this scheduler]
//
// Attempt schedule (5 total):
//   Pass 1: immediate (right after pipeline)
//   Pass 2: 2 minutes later
//   Pass 3: 10 minutes later
//   Pass 4: 30 minutes later
//   Pass 5: 60 minutes later
//
// Per pass:
//   1. retrySkippedTracks  — files that failed tag reads during the main scan
//   2. retryFailedEmbeddedArt — albums where embedded art read errored
//
// Scheduler stops when both queues are empty or exhausted at attempt 5.
// Rows are retained after attempt 5 for future admin review.
//
// Sleep uses wall-clock polling (5s heartbeat) so time suspended in background
// counts against the interval — the scheduler fires promptly on foreground re-entry.
//
// On app kill + relaunch: ScanCoordinator.checkForChanges() detects pending rows
// in DB and calls start() again to resume from the current attempt count.
// checkForChanges() checks isRunning before calling start() — prevents duplicate
// scheduler instances when app foregrounds mid-run.

actor ScanRetryScheduler {

    static let shared = ScanRetryScheduler()

    // Delays between passes (seconds): 2min, 10min, 30min, 60min
    private let retryDelays: [TimeInterval] = [30, 30, 30, 30]

    private var schedulerTask: Task<Void, Never>? = nil

    private init() {}

    // MARK: - Public API

    /// True when the scheduler has an active, non-cancelled task in flight.
    /// Used by ScanCoordinator.checkForChanges() to avoid restarting a running scheduler.
    var isRunning: Bool {
        guard let task = schedulerTask else { return false }
        return !task.isCancelled
    }

    private func scanLog(_ message: String) {
        sLog(message)
        ScanCoordinator.shared.appendStatus(message)
    }

    /// Start (or restart) the retry scheduler for a source.
    /// Cancels any in-flight task before starting — call isRunning first
    /// to avoid unnecessary restarts when the scheduler is already running.
    func start(source: LibrarySource, scanner: SMBScanner) async {
        schedulerTask?.cancel()

        // fScanSessionLogCorrelation — the scheduler outlives the scan pipeline
        // and can also be restarted independently after a kill, so it has to
        // re-establish the tag itself. Without this the retry lines carried no
        // session id after a relaunch, and could not be searched alongside the
        // scan that produced their queue (observed 2026-07-31).
        let sessionId = (try? SorrivaDatabase.shared.currentScanSessionId(sourceId: source.id)) ?? nil
        if let sessionId { ScanLogSession.begin(sessionId) }

        schedulerTask = Task {
            scanLog("RETRY: scheduler START for \(source.displayName)")

            // Pass 1 — immediate
            await runRetryPass(source: source, scanner: scanner, passNumber: 1)

            // Passes 2–5 — on backoff schedule
            for (idx, delay) in retryDelays.enumerated() {
                guard !Task.isCancelled else {
                    scanLog("RETRY: scheduler CANCELLED before pass \(idx + 2)")
                    break
                }

                // Check both queues before sleeping — bail early if already clear
                if await bothQueuesClear(sourceId: source.id) {
                    scanLog("RETRY: scheduler DONE — both queues clear after pass \(idx + 1)")
                    try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "complete")
                    scanLog("SCAN: state = complete for \(source.displayName)")
                    await MainActor.run {
                        NotificationCenter.default.post(name: .libraryDidUpdate, object: nil)
                    }
                    break
                }

                scanLog("RETRY: scheduler waiting \(Int(delay))s until pass \(idx + 2)")
                await wallClockSleep(seconds: delay, passNumber: idx + 2)

                guard !Task.isCancelled else {
                    scanLog("RETRY: scheduler CANCELLED during sleep before pass \(idx + 2)")
                    break
                }

                await runRetryPass(source: source, scanner: scanner, passNumber: idx + 2)
            }

            // Final state summary
            let tracksPending   = (try? SorrivaDatabase.shared.pendingScanSkips(sourceId: source.id))?.count ?? 0
            let tracksPermanent = (try? SorrivaDatabase.shared.permanentScanSkipCount(sourceId: source.id)) ?? 0
            let artPending      = (try? SorrivaDatabase.shared.albumsNeedingEmbeddedArtRetry())?.count ?? 0
            scanLog("RETRY: scheduler COMPLETE — \(tracksPending) tracks still pending, \(tracksPermanent) tracks permanent, \(artPending) art still pending")
            try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "complete")
            scanLog("SCAN: state = complete for \(source.displayName)")
            // Pipeline is genuinely over — clear the session so a later killed
            // run cannot be confused with this one, and close the log tag.
            try? SorrivaDatabase.shared.setCurrentScanSessionId(sourceId: source.id, sessionId: nil)
            ScanLogSession.end()
            await MainActor.run {
                NotificationCenter.default.post(name: .libraryDidUpdate, object: nil)
            }
        }
    }

    /// Cancel the scheduler — called if a new full scan starts mid-schedule.
    func cancel() {
        schedulerTask?.cancel()
        schedulerTask = nil
        scanLog("RETRY: scheduler cancelled")
    }

    // MARK: - Private

    private func runRetryPass(source: LibrarySource, scanner: SMBScanner, passNumber: Int) async {
        scanLog("RETRY: === PASS \(passNumber) START ===")
        await scanner.retrySkippedTracks(source: source)
        await retryFailedEmbeddedArt(source: source)
        scanLog("RETRY: === PASS \(passNumber) COMPLETE ===")
    }

    private func bothQueuesClear(sourceId: String) async -> Bool {
        let tracksDone = ((try? SorrivaDatabase.shared.pendingScanSkips(sourceId: sourceId)) ?? []).isEmpty
        let artDone    = ((try? SorrivaDatabase.shared.albumsNeedingEmbeddedArtRetry()) ?? []).isEmpty
        return tracksDone && artDone
    }

    /// Sleep using wall-clock polling so backgrounding doesn't extend the interval.
    private func wallClockSleep(seconds: TimeInterval, passNumber: Int) async {
        let target = Date().addingTimeInterval(seconds)
        while Date() < target {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s heartbeat
        }
        scanLog("RETRY: scheduler — pass \(passNumber) delay elapsed, firing")
    }

    // MARK: - Embedded art retry pass

    private func retryFailedEmbeddedArt(source: LibrarySource) async {
        let albums: [Album]
        do {
            albums = try SorrivaDatabase.shared.albumsNeedingEmbeddedArtRetry()
        } catch {
            scanLog("RETRY: embedded art — failed to fetch queue: \(error.localizedDescription)")
            return
        }
        guard !albums.isEmpty else {
            scanLog("RETRY: embedded art — no pending retries")
            return
        }

        scanLog("RETRY: embedded art START — \(albums.count) albums")
        var resolved = 0
        var stillFailing = 0

        // bScanRetryNoCircuitBreaker. If the NAS stops responding entirely,
        // every remaining album costs a full 15s timeout plus a reconnect for
        // nothing — at a large queue that is many minutes of hammering a server
        // that is already refusing service, and it buries real signal in the log.
        // Consecutive timeouts are the signal; an isolated failure is not.
        var consecutiveTimeouts = 0
        let timeoutCircuitBreaker = 5

        var client = SMBClient(host: source.host)
        do {
            try await client.login(username: source.loginCredentials.username, password: source.loginCredentials.password)
            try await client.connectShare(source.share)
        } catch {
            scanLog("RETRY: embedded art — SMB connect failed: \(error.localizedDescription)")
            return
        }

        for album in albums {
            // Heartbeat. lastPipelineProgress was previously updated only by the
            // scan progress callback and the artwork album loops, so from the
            // wedge watchdog's point of view the retry scheduler did not exist —
            // a hang here was invisible to it.
            ScanCoordinator.shared.notePipelineProgressExternal()

            let attemptNum = album.embeddedArtRetryCount + 1
            scanLog("RETRY: embedded art attempt \(attemptNum)/5 — \(album.artistName) · \(album.title)")

            let tracks = (try? SorrivaDatabase.shared.tracks(albumId: album.id)) ?? []
            var artFound = false
            var readErrored = false

            for track in tracks.prefix(3) {
                let ext = (track.filePath as NSString).pathExtension.lowercased()
                guard ["mp3", "flac", "m4a", "aac", "alac"].contains(ext) else { continue }

                do {
                    // Timed. Without this the retry pass hangs FOREVER on a dead
                    // session: SMBClient's async methods never check for
                    // cancellation, so an unresponsive read is not slow, it is
                    // permanent. Observed 2026-07-31 — a full 11,670-file scan
                    // completed successfully and then stalled here on the first
                    // album of the art retry, and every relaunch reproduced it
                    // because scanState 'retrying' restarts the scheduler, which
                    // hit the same album and stalled again. Unrecoverable without
                    // clearing the library.
                    //
                    // The scan's own artwork passes already had this treatment;
                    // the retry path did not.
                    let raw = try await Self.timedRead(client: client, path: track.filePath)

                    if let imageData = ScanCoordinator.extractArt(from: raw, ext: ext),
                       let image = UIImage(data: imageData),
                       let saved = saveArtwork(image: image, albumId: album.id) {
                        try? SorrivaDatabase.shared.updateAlbumArtwork(
                            albumId: album.id, thumbPath: saved.thumb, fullPath: saved.full
                        )
                        try? SorrivaDatabase.shared.markEmbeddedArtScanned(albumId: album.id)
                        await MainActor.run {
                            NotificationCenter.default.post(name: .artworkDidUpdate, object: album.id)
                        }
                        scanLog("RETRY: embedded art RESOLVED (attempt \(attemptNum)) — \(album.artistName) · \(album.title)")
                        artFound = true
                        resolved += 1
                        break
                    }
                } catch {
                    scanLog("RETRY: embedded art read error — \((track.filePath as NSString).lastPathComponent): \(error.localizedDescription)")
                    readErrored = true
                    if case RetryError.timeout = error {
                        consecutiveTimeouts += 1
                    }
                    try? await client.disconnectShare()
                    try? await client.logoff()
                    client.session.disconnect()
                    client = SMBClient(host: source.host)
                    if (try? await client.login(username: source.loginCredentials.username, password: source.loginCredentials.password)) != nil,
                       (try? await client.connectShare(source.share)) != nil {
                        scanLog("RETRY: embedded art — reconnected")
                    }
                }
            }

            if !artFound {
                if readErrored {
                    try? SorrivaDatabase.shared.markEmbeddedArtFailed(albumId: album.id)
                    if attemptNum >= 5 {
                        scanLog("RETRY: embedded art PERMANENT FAIL after 5 attempts — \(album.artistName) · \(album.title)")
                    } else {
                        scanLog("RETRY: embedded art attempt \(attemptNum) failed — \(album.artistName) · \(album.title)")
                    }
                } else {
                    try? SorrivaDatabase.shared.markEmbeddedArtScanned(albumId: album.id)
                    scanLog("RETRY: embedded art — no art in file — \(album.artistName) · \(album.title)")
                }
                stillFailing += 1
            }

            if !readErrored { consecutiveTimeouts = 0 }

            if consecutiveTimeouts >= timeoutCircuitBreaker {
                scanLog("RETRY: embedded art ABORTED — \(consecutiveTimeouts) consecutive timeouts, NAS not responding")
                scanLog("RETRY: remaining albums stay queued for the next pass")
                break
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        try? await client.disconnectShare()
        try? await client.logoff()
        // logoff() does NOT reach NWConnection.cancel() — only session.disconnect()
        // does. Without this the retry pass leaked one kernel flow entry per run
        // against the hard ~512 per-process ceiling
        // (bScanConnectionExhaustionOnRepeatedScans).
        client.session.disconnect()
        scanLog("RETRY: embedded art COMPLETE — \(resolved) resolved, \(stillFailing) still failing")
    }

    // MARK: - Timed read

    /// One 1MB read with a stall ceiling, mirroring SMBMediaSourceReader.readHeader.
    ///
    /// On timeout the connection is force-cancelled via session.disconnect() —
    /// the ONLY call that reaches NWConnection.cancel(). logoff() would send a
    /// frame and await a response on a connection that is unresponsive by
    /// definition, so the very call meant to break the hang could itself hang.
    private static func timedRead(client: SMBClient, path: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<Data, Error> = .failure(RetryError.timeout)

            Task.detached {
                do {
                    let reader = client.fileReader(path: path)
                    let data = try await reader.read(offset: 0, length: 1_048_576)
                    try? await reader.close()
                    result = .success(data)
                } catch {
                    result = .failure(error)
                }
                semaphore.signal()
            }

            DispatchQueue.global(qos: .utility).async {
                if semaphore.wait(timeout: .now() + 15) == .timedOut {
                    result = .failure(RetryError.timeout)
                    client.session.disconnect()
                }
                continuation.resume(with: result)
            }
        }
    }

    private enum RetryError: Error, CustomStringConvertible {
        case timeout
        var description: String { "read stalled — no response within 15s (session presumed dead)" }
    }

    // MARK: - Artwork save helpers

    private func saveArtwork(image: UIImage, albumId: String) -> (thumb: String, full: String)? {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let artDir  = docsDir.appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
        let fullURL  = artDir.appendingPathComponent("\(albumId)_full.jpg")
        let thumbURL = artDir.appendingPathComponent("\(albumId)_thumb.jpg")
        guard let fullData  = resized(image, to: 600)?.jpegData(compressionQuality: 0.85),
              let thumbData = resized(image, to: 300)?.jpegData(compressionQuality: 0.85) else { return nil }
        try? fullData.write(to: fullURL)
        try? thumbData.write(to: thumbURL)
        return (thumb: "artwork/\(albumId)_thumb.jpg", full: "artwork/\(albumId)_full.jpg")
    }

    private func resized(_ image: UIImage, to maxDimension: CGFloat) -> UIImage? {
        let size  = image.size
        let scale = min(maxDimension / size.width, maxDimension / size.height)
        if scale >= 1 { return image }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }
}
