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

actor ScanRetryScheduler {

    static let shared = ScanRetryScheduler()

    // Delays between passes (seconds): 2min, 10min, 30min, 60min
    private let retryDelays: [TimeInterval] = [120, 600, 1800, 3600]

    private var schedulerTask: Task<Void, Never>? = nil

    private init() {}

    // MARK: - Public API

    /// Start (or restart) the retry scheduler for a source.
    /// Safe to call multiple times — cancels any in-flight task first.
    func start(source: LibrarySource, scanner: SMBScanner) async {
        schedulerTask?.cancel()

        schedulerTask = Task {
            sLog("RETRY: scheduler START for \(source.displayName)")

            // Pass 1 — immediate
            await runRetryPass(source: source, scanner: scanner, passNumber: 1)

            // Passes 2–5 — on backoff schedule
            for (idx, delay) in retryDelays.enumerated() {
                guard !Task.isCancelled else {
                    sLog("RETRY: scheduler CANCELLED before pass \(idx + 2)")
                    break
                }

                // Check both queues before sleeping — bail early if already clear
                if await bothQueuesClear(sourceId: source.id) {
                    sLog("RETRY: scheduler DONE — both queues clear after pass \(idx + 1)")
                    break
                }

                sLog("RETRY: scheduler waiting \(Int(delay))s until pass \(idx + 2)")
                await wallClockSleep(seconds: delay, passNumber: idx + 2)

                guard !Task.isCancelled else {
                    sLog("RETRY: scheduler CANCELLED during sleep before pass \(idx + 2)")
                    break
                }

                await runRetryPass(source: source, scanner: scanner, passNumber: idx + 2)
            }

            // Final state summary
            let tracksPending  = (try? SorrivaDatabase.shared.pendingScanSkips(sourceId: source.id))?.count ?? 0
            let tracksPermanent = (try? SorrivaDatabase.shared.permanentScanSkipCount(sourceId: source.id)) ?? 0
            let artPending     = (try? SorrivaDatabase.shared.albumsNeedingEmbeddedArtRetry())?.count ?? 0
            sLog("RETRY: scheduler COMPLETE — \(tracksPending) tracks still pending, \(tracksPermanent) tracks permanent, \(artPending) art still pending")
        }
    }

    /// Cancel the scheduler — called if a new full scan starts mid-schedule.
    func cancel() {
        schedulerTask?.cancel()
        schedulerTask = nil
        sLog("RETRY: scheduler cancelled")
    }

    // MARK: - Private

    private func runRetryPass(source: LibrarySource, scanner: SMBScanner, passNumber: Int) async {
        sLog("RETRY: === PASS \(passNumber) START ===")
        await scanner.retrySkippedTracks(source: source)
        await retryFailedEmbeddedArt(source: source)
        sLog("RETRY: === PASS \(passNumber) COMPLETE ===")
    }

    private func bothQueuesClear(sourceId: String) async -> Bool {
        let tracksDone = ((try? SorrivaDatabase.shared.pendingScanSkips(sourceId: sourceId)) ?? []).isEmpty
        let artDone    = ((try? SorrivaDatabase.shared.albumsNeedingEmbeddedArtRetry()) ?? []).isEmpty
        return tracksDone && artDone
    }

    /// Sleep using wall-clock polling so backgrounding doesn't extend the interval.
    /// Logs every 15 seconds so we can trace scheduler state in the debug log.
    private func wallClockSleep(seconds: TimeInterval, passNumber: Int) async {
        let target = Date().addingTimeInterval(seconds)
        var nextLog = Date().addingTimeInterval(15)
        while Date() < target {
            guard !Task.isCancelled else { return }
            let remaining = Int(target.timeIntervalSinceNow)
            if Date() >= nextLog {
                sLog("RETRY: scheduler — pass \(passNumber) waiting, \(remaining)s remaining")
                nextLog = Date().addingTimeInterval(15)
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s heartbeat
        }
        sLog("RETRY: scheduler — pass \(passNumber) delay elapsed, firing")
    }

    // MARK: - Embedded art retry pass

    private func retryFailedEmbeddedArt(source: LibrarySource) async {
        let albums: [Album]
        do {
            albums = try SorrivaDatabase.shared.albumsNeedingEmbeddedArtRetry()
        } catch {
            sLog("RETRY: embedded art — failed to fetch queue: \(error.localizedDescription)")
            return
        }
        guard !albums.isEmpty else {
            sLog("RETRY: embedded art — no pending retries")
            return
        }

        sLog("RETRY: embedded art START — \(albums.count) albums")
        var resolved = 0
        var stillFailing = 0

        var client = SMBClient(host: source.host)
        do {
            try await client.login(username: source.username ?? "", password: source.password ?? "")
            try await client.connectShare(source.share)
        } catch {
            sLog("RETRY: embedded art — SMB connect failed: \(error.localizedDescription)")
            return
        }

        for album in albums {
            let attemptNum = album.embeddedArtRetryCount + 1
            sLog("RETRY: embedded art attempt \(attemptNum)/5 — \(album.artistName) · \(album.title)")

            let tracks = (try? SorrivaDatabase.shared.tracks(albumId: album.id)) ?? []
            var artFound = false
            var readErrored = false

            for track in tracks.prefix(3) {
                let ext = (track.filePath as NSString).pathExtension.lowercased()
                guard ["mp3", "flac", "m4a", "aac", "alac"].contains(ext) else { continue }

                do {
                    let reader = client.fileReader(path: track.filePath)
                    let raw = try await reader.read(offset: 0, length: 1048576)
                    try? await reader.close()

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
                        sLog("RETRY: embedded art RESOLVED (attempt \(attemptNum)) — \(album.artistName) · \(album.title)")
                        artFound = true
                        resolved += 1
                        break
                    }
                    // Read succeeded, no art in file — don't set readErrored
                } catch {
                    sLog("RETRY: embedded art read error — \((track.filePath as NSString).lastPathComponent): \(error.localizedDescription)")
                    readErrored = true
                    // Reconnect
                    try? await client.disconnectShare()
                    try? await client.logoff()
                    client = SMBClient(host: source.host)
                    if (try? await client.login(username: source.username ?? "", password: source.password ?? "")) != nil,
                       (try? await client.connectShare(source.share)) != nil {
                        sLog("RETRY: embedded art — reconnected")
                    }
                }
            }

            if !artFound {
                if readErrored {
                    // Still erroring — increment retry count (markEmbeddedArtFailed handles the cap at 5)
                    try? SorrivaDatabase.shared.markEmbeddedArtFailed(albumId: album.id)
                    if attemptNum >= 5 {
                        sLog("RETRY: embedded art PERMANENT FAIL after 5 attempts — \(album.artistName) · \(album.title)")
                    } else {
                        sLog("RETRY: embedded art attempt \(attemptNum) failed — \(album.artistName) · \(album.title)")
                    }
                } else {
                    // No read error but no art found — file genuinely has no embedded art, stop retrying
                    try? SorrivaDatabase.shared.markEmbeddedArtScanned(albumId: album.id)
                    sLog("RETRY: embedded art — no art in file — \(album.artistName) · \(album.title)")
                }
                stillFailing += 1
            }

            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms between albums
        }

        try? await client.disconnectShare()
        try? await client.logoff()
        sLog("RETRY: embedded art COMPLETE — \(resolved) resolved, \(stillFailing) still failing")
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
