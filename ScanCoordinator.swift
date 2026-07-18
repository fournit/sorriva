import Foundation
import SwiftUI
import Combine
import UIKit
import SMBClient

// MARK: - ScanCoordinator

@MainActor
final class ScanCoordinator: ObservableObject {

    static let shared = ScanCoordinator()

    // MARK: - Published state

    @Published var activeScanSourceId: String? = nil
    @Published var progress: ScanProgress? = nil
    @Published var lastReport: ScanReport? = nil
    @Published var pendingFullScanSource: LibrarySource? = nil
    @Published var interruptedScanSource: LibrarySource? = nil  // set when incomplete scan detected

    // MARK: - Private

    private let scanner = SMBScanner()
    private var scanTask: Task<Void, Never>? = nil

    private init() {}

    // MARK: - Public API

    /// Called when a new share is saved — queues confirmation alert.
    func scanNewSource(_ source: LibrarySource) {
        pendingFullScanSource = source
    }

    /// Called from confirmation alert — user confirmed full scan.
    func confirmAndScanSource(_ source: LibrarySource) {
        pendingFullScanSource = nil
        interruptedScanSource = nil
        startFullScan(source: source)
    }

    /// Manual "Scan Now" from ShareActionSheet — queues confirmation.
    func scanSource(_ source: LibrarySource) {
        pendingFullScanSource = source
    }

    /// Called when app foregrounds.
    /// Skips never-scanned sources (require confirmation).
    /// Detects interrupted scans and surfaces restart option.
    /// Runs incremental rescan for changed folders on completed sources.
    /// Restarts retry scheduler if pending skips exist and no scan is active.
    func checkForChanges() {
        sLog("SCAN: checkForChanges — scene became active")
        Task {
            let sources = (try? SorrivaDatabase.shared.allLibrarySources()) ?? []
            for source in sources {
                guard source.scanState != "scanning" else { continue }
                guard source.type == "smb" else { continue }

                if source.lastScanned == nil && source.scanState == "error" {
                    // Interrupted scan — surface restart option
                    interruptedScanSource = source
                    continue
                }

                guard source.lastScanned != nil else { continue }

                // Resume retry scheduler if pending skips exist and no scan is running
                let pendingSkips = (try? SorrivaDatabase.shared.pendingScanSkips(sourceId: source.id)) ?? []
                let pendingArt   = (try? SorrivaDatabase.shared.albumsNeedingEmbeddedArtRetry()) ?? []
                if !pendingSkips.isEmpty || !pendingArt.isEmpty {
                    sLog("SCAN: foregrounded with \(pendingSkips.count) pending track skips, \(pendingArt.count) pending art retries — resuming scheduler")
                    await ScanRetryScheduler.shared.start(source: source, scanner: scanner)
                }

                let changedFolders = await findChangedFolders(source: source)
                if !changedFolders.isEmpty {
                    sLog("SCAN: \(changedFolders.count) changed folder(s) in \(source.displayName)")
                    startIncrementalScan(source: source, folders: changedFolders)
                    await scanTask?.value
                }
            }
        }
    }

    // MARK: - Private scan starters

    private func startFullScan(source: LibrarySource) {
        if activeScanSourceId == source.id { scanTask?.cancel() }
        scanTask = Task { await runScan(source: source, folders: nil) }
    }

    private func startIncrementalScan(source: LibrarySource, folders: [String]) {
        if activeScanSourceId == source.id { scanTask?.cancel() }
        scanTask = Task { await runScan(source: source, folders: folders) }
    }

    private func runScan(source: LibrarySource, folders: [String]?) async {
        activeScanSourceId = source.id
        try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "scanning")

        // Prevent screen lock during scan
        UIApplication.shared.isIdleTimerDisabled = true

        do {
            if let folders = folders {
                try await scanner.scanChangedFolders(source: source, folderPaths: folders) { [weak self] p in
                    Task { @MainActor [weak self] in self?.handleProgress(p) }
                }
            } else {
                try await scanner.scan(source: source) { [weak self] p in
                    Task { @MainActor [weak self] in self?.handleProgress(p) }
                }
            }
            print("SCAN: Completed — \(source.displayName)")
        } catch {
            print("SCAN: Failed — \(source.displayName): \(error)")
            try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "error")
        }

        // Restore screen lock
        UIApplication.shared.isIdleTimerDisabled = false

        NotificationCenter.default.post(name: .libraryDidUpdate, object: nil)

        if activeScanSourceId == source.id {
            activeScanSourceId = nil
            progress = nil
        }

        Task.detached { [weak self] in
            guard let self else { return }
            await self.runFolderArtPass(source: source)
            await ArtworkCache.shared.fetchMissingArtwork()
            // Wait 30s for iOS to reclaim sockets from scan and folder/iTunes passes
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await self.runEmbeddedArtPass(source: source)
            // Kick retry scheduler — runs track retry then embedded art retry on backoff schedule
            sLog("SCAN: pipeline complete — starting retry scheduler for \(source.displayName)")
            await ScanRetryScheduler.shared.start(source: source, scanner: self.scanner)
        }
    }

    private func handleProgress(_ p: ScanProgress) {
        if p.phase == .complete {
            lastReport = p.report
        } else {
            progress = p
        }
    }

    // MARK: - Folder artwork pass

    private static let artCandidates = [
        "AlbumArtLarge.jpg", "folder.jpg", "cover.jpg", "front.jpg", "AlbumArtSmall.jpg",
        "AlbumArtLarge.png", "folder.png", "cover.png", "front.png"
    ]

    private func runFolderArtPass(source: LibrarySource) async {
        let albums = (try? SorrivaDatabase.shared.albums(sourceId: source.id)) ?? []
        guard !albums.isEmpty else {
            sLog("ARTWORK: folder pass — nothing to scan")
            return
        }

        sLog("ARTWORK: folder pass START — \(albums.count) albums in \(source.displayName)")
        var found = 0

        // One persistent connection for the entire pass — same architecture as embedded art pass.
        // Per-album fresh connections flood the NAS and exhaust the socket pool.
        var client = SMBClient(host: source.host)
        do {
            try await client.login(username: source.username ?? "", password: source.password ?? "")
            try await client.connectShare(source.share)
        } catch {
            sLog("ARTWORK: folder pass — failed to connect: \(error.localizedDescription)")
            return
        }

        for (idx, album) in albums.enumerated() {
            guard !album.artManualOverride else {
                sLog("ARTWORK: folder [\(idx+1)/\(albums.count)] SKIP manual override — \(album.title)")
                continue
            }
            guard !album.folderPath.isEmpty else {
                sLog("ARTWORK: folder [\(idx+1)/\(albums.count)] SKIP no folder path — \(album.title)")
                continue
            }

            sLog("ARTWORK: folder [\(idx+1)/\(albums.count)] checking — \(album.artistName) · \(album.title)")

            var imageData: Data? = nil

            do {
                let entries = try await client.listDirectory(path: album.folderPath)
                let entryNames = Set(entries.map { $0.name })

                var artFilePath: String? = nil
                for candidate in ScanCoordinator.artCandidates {
                    if entryNames.contains(candidate) {
                        artFilePath = album.folderPath == "/"
                            ? "/\(candidate)"
                            : "\(album.folderPath)/\(candidate)"
                        break
                    }
                }

                if let artPath = artFilePath {
                    sLog("ARTWORK: folder [\(idx+1)/\(albums.count)] downloading \((artPath as NSString).lastPathComponent)")
                    imageData = try await client.download(path: artPath)
                } else {
                    sLog("ARTWORK: folder [\(idx+1)/\(albums.count)] no art file found")
                }
            } catch {
                sLog("ARTWORK: folder [\(idx+1)/\(albums.count)] error — \(error.localizedDescription)")
                // Reconnect and continue to next album
                try? await client.disconnectShare()
                try? await client.logoff()
                client = SMBClient(host: source.host)
                if (try? await client.login(username: source.username ?? "", password: source.password ?? "")) != nil,
                   (try? await client.connectShare(source.share)) != nil {
                    sLog("ARTWORK: folder — reconnected")
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }

            if let data = imageData, let image = UIImage(data: data) {
                let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let artDir = docsDir.appendingPathComponent("artwork", isDirectory: true)
                try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
                let fullURL  = artDir.appendingPathComponent("\(album.id)_full.jpg")
                let thumbURL = artDir.appendingPathComponent("\(album.id)_thumb.jpg")
                if let fullData  = resized(image, to: 600)?.jpegData(compressionQuality: 0.85),
                   let thumbData = resized(image, to: 300)?.jpegData(compressionQuality: 0.85) {
                    try? fullData.write(to: fullURL)
                    try? thumbData.write(to: thumbURL)
                    try? SorrivaDatabase.shared.updateAlbumArtwork(
                        albumId: album.id,
                        thumbPath: "artwork/\(album.id)_thumb.jpg",
                        fullPath: "artwork/\(album.id)_full.jpg"
                    )
                    found += 1
                    sLog("ARTWORK: folder [\(idx+1)/\(albums.count)] SAVED — \(album.artistName) · \(album.title)")
                    await MainActor.run {
                        NotificationCenter.default.post(name: .artworkDidUpdate, object: album.id)
                    }
                }
            }

            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms between albums
        }

        try? await client.disconnectShare()
        try? await client.logoff()
        sLog("ARTWORK: folder pass COMPLETE — \(found)/\(albums.count) found")
    }

    func resized(_ image: UIImage, to maxDimension: CGFloat) -> UIImage? {
        let size = image.size
        let scale = min(maxDimension / size.width, maxDimension / size.height)
        if scale >= 1 { return image }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }

    private func runEmbeddedArtPass(source: LibrarySource) async {
        let albums = (try? SorrivaDatabase.shared.albumsNeedingEmbeddedArtScan()) ?? []
        guard !albums.isEmpty else {
            sLog("ARTWORK: embedded pass — nothing to scan")
            return
        }

        sLog("ARTWORK: embedded pass START — \(albums.count) albums")
        var found = 0

        // One persistent connection for the entire pass
        var client = SMBClient(host: source.host)
        do {
            try await client.login(username: source.username ?? "", password: source.password ?? "")
            try await client.connectShare(source.share)
        } catch {
            sLog("ARTWORK: embedded pass — failed to connect: \(error.localizedDescription)")
            return
        }

        for (idx, album) in albums.enumerated() {
            guard !album.folderPath.isEmpty else {
                try? SorrivaDatabase.shared.markEmbeddedArtScanned(albumId: album.id)
                continue
            }

            let tracks = (try? SorrivaDatabase.shared.tracks(albumId: album.id)) ?? []
            guard !tracks.isEmpty else {
                try? SorrivaDatabase.shared.markEmbeddedArtScanned(albumId: album.id)
                continue
            }

            sLog("ARTWORK: embedded [\(idx+1)/\(albums.count)] — \(album.artistName) · \(album.title)")

            var artFound = false
            var artReadErrored = false  // true if any track read threw an error (vs genuine no-art)

            for track in tracks.prefix(3) {
                let ext = (track.filePath as NSString).pathExtension.lowercased()
                guard ["mp3", "flac", "m4a", "aac", "alac"].contains(ext) else { continue }

                var imageData: Data? = nil
                do {
                    let reader = client.fileReader(path: track.filePath)
                    let raw = try await reader.read(offset: 0, length: 1048576)
                    try? await reader.close()
                    imageData = Self.extractArt(from: raw, ext: ext)
                } catch {
                    sLog("ARTWORK: embedded read error — \((track.filePath as NSString).lastPathComponent): \(error.localizedDescription)")
                    artReadErrored = true
                    // Reconnect on error
                    try? await client.disconnectShare()
                    try? await client.logoff()
                    client = SMBClient(host: source.host)
                    if (try? await client.login(username: source.username ?? "", password: source.password ?? "")) != nil,
                       (try? await client.connectShare(source.share)) != nil {
                        sLog("ARTWORK: embedded — reconnected")
                    }
                    continue
                }

                if let data = imageData, let image = UIImage(data: data) {
                    let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let artDir = docsDir.appendingPathComponent("artwork", isDirectory: true)
                    try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
                    let fullURL  = artDir.appendingPathComponent("\(album.id)_full.jpg")
                    let thumbURL = artDir.appendingPathComponent("\(album.id)_thumb.jpg")
                    if let fullData  = resized(image, to: 600)?.jpegData(compressionQuality: 0.85),
                       let thumbData = resized(image, to: 300)?.jpegData(compressionQuality: 0.85) {
                        try? fullData.write(to: fullURL)
                        try? thumbData.write(to: thumbURL)
                        try? SorrivaDatabase.shared.updateAlbumArtwork(
                            albumId: album.id,
                            thumbPath: "artwork/\(album.id)_thumb.jpg",
                            fullPath: "artwork/\(album.id)_full.jpg"
                        )
                        try? SorrivaDatabase.shared.markEmbeddedArtScanned(albumId: album.id)
                        found += 1
                        artFound = true
                        sLog("ARTWORK: embedded SAVED — \(album.artistName) · \(album.title)")
                        await MainActor.run {
                            NotificationCenter.default.post(name: .artworkDidUpdate, object: album.id)
                        }
                        break
                    }
                }
            }

            if !artFound {
                if artReadErrored {
                    // Read error — not genuinely artless. Queue for retry.
                    try? SorrivaDatabase.shared.markEmbeddedArtFailed(albumId: album.id)
                    sLog("ARTWORK: embedded FAILED (queued for retry) — \(album.artistName) · \(album.title)")
                } else {
                    // No read errors — file simply has no embedded art. Mark done permanently.
                    try? SorrivaDatabase.shared.markEmbeddedArtScanned(albumId: album.id)
                    sLog("ARTWORK: embedded — no art in file — \(album.artistName) · \(album.title)")
                }
            }

            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms between albums
        }

        try? await client.disconnectShare()
        try? await client.logoff()
        sLog("ARTWORK: embedded pass COMPLETE — \(found)/\(albums.count) found")
    }

    nonisolated static func extractArt(from data: Data, ext: String) -> Data? {
        switch ext {
        case "mp3": return extractID3Art(data: data)
        case "flac": return extractFlacArt(data: data)
        case "m4a", "aac", "alac": return extractMP4Art(data: data)
        default: return nil
        }
    }

    private nonisolated static func extractID3Art(data: Data) -> Data? {
        guard data.count > 10, data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return nil }
        let tagSize = (Int(data[6]) << 21) | (Int(data[7]) << 14) | (Int(data[8]) << 7) | Int(data[9])
        let version = data[3]
        var offset = 10
        while offset + 10 < min(tagSize + 10, data.count) {
            let frameID = String(bytes: data[offset..<offset+4], encoding: .isoLatin1) ?? ""
            if frameID == "\0\0\0\0" { break }
            let frameSize: Int
            if version >= 4 {
                frameSize = (Int(data[offset+4]) << 21) | (Int(data[offset+5]) << 14) | (Int(data[offset+6]) << 7) | Int(data[offset+7])
            } else {
                frameSize = (Int(data[offset+4]) << 24) | (Int(data[offset+5]) << 16) | (Int(data[offset+6]) << 8) | Int(data[offset+7])
            }
            guard frameSize > 0, offset + 10 + frameSize <= data.count else { break }
            if frameID == "APIC" {
                let frameData = Data(data[(offset+10)..<(offset+10+frameSize)]) // base-zero copy
                // Skip encoding byte, mime type, null, pic type, description, null
                var pos = 1
                while pos < frameData.count && frameData[pos] != 0 { pos += 1 }
                pos += 2 // skip null and picture type
                while pos < frameData.count && frameData[pos] != 0 { pos += 1 }
                pos += 1 // skip null after description
                if pos < frameData.count {
                    return Data(frameData[pos...])
                }
            }
            offset += 10 + frameSize
        }
        return nil
    }

    private nonisolated static func extractFlacArt(data: Data) -> Data? {
        guard data.count > 4, data[0] == 0x66, data[1] == 0x4C, data[2] == 0x61, data[3] == 0x43 else { return nil }
        var offset = 4
        while offset + 4 <= data.count {
            let blockHeader = data[offset]
            let isLast = (blockHeader & 0x80) != 0
            let blockType = blockHeader & 0x7F
            let blockSize = (Int(data[offset+1]) << 16) | (Int(data[offset+2]) << 8) | Int(data[offset+3])
            offset += 4
            if blockType == 6 && offset + blockSize <= data.count {
                let block = Data(data[offset..<(offset+blockSize)]) // base-zero copy
                guard block.count == blockSize else { offset += blockSize; if isLast { break }; continue }
                var pos = 4 // skip picture type
                guard pos + 4 <= block.count else { offset += blockSize; if isLast { break }; continue }
                let mimeLen = (Int(block[pos]) << 24) | (Int(block[pos+1]) << 16) | (Int(block[pos+2]) << 8) | Int(block[pos+3]); pos += 4
                guard pos + mimeLen + 4 <= block.count else { offset += blockSize; if isLast { break }; continue }
                pos += mimeLen
                let descLen = (Int(block[pos]) << 24) | (Int(block[pos+1]) << 16) | (Int(block[pos+2]) << 8) | Int(block[pos+3]); pos += 4
                guard pos + descLen + 20 <= block.count else { offset += blockSize; if isLast { break }; continue }
                pos += descLen + 16 // skip desc, width, height, color depth, indexed colors
                let dataLen = (Int(block[pos]) << 24) | (Int(block[pos+1]) << 16) | (Int(block[pos+2]) << 8) | Int(block[pos+3]); pos += 4
                guard pos + dataLen <= block.count else { offset += blockSize; if isLast { break }; continue }
                return Data(block[pos..<(pos+dataLen)])
            }
            offset += blockSize
            if isLast { break }
        }
        return nil
    }

    private nonisolated static func extractMP4Art(data: Data) -> Data? {
        // Find moov → udta → meta → ilst → covr → data
        func atomSize(_ d: Data, _ o: Int) -> Int {
            guard o + 4 <= d.count else { return 0 }
            return (Int(d[o]) << 24) | (Int(d[o+1]) << 16) | (Int(d[o+2]) << 8) | Int(d[o+3])
        }
        func atomName(_ d: Data, _ o: Int) -> String {
            guard o + 8 <= d.count else { return "" }
            return String(bytes: d[(o+4)..<(o+8)], encoding: .isoLatin1) ?? ""
        }
        func findAtom(_ name: String, _ d: Data, _ start: Int, _ end: Int) -> Int? {
            var pos = start
            while pos + 8 <= end {
                let size = atomSize(d, pos)
                guard size >= 8 else { break }
                if atomName(d, pos) == name { return pos }
                pos += size
            }
            return nil
        }
        let end = data.count
        guard let moov = findAtom("moov", data, 0, end) else { return nil }
        let moovEnd = min(moov + atomSize(data, moov), end)
        guard let udta = findAtom("udta", data, moov+8, moovEnd) else { return nil }
        let udtaEnd = min(udta + atomSize(data, udta), end)
        guard let meta = findAtom("meta", data, udta+8, udtaEnd) else { return nil }
        let metaEnd = min(meta + atomSize(data, meta), end)
        guard let ilst = findAtom("ilst", data, meta+12, metaEnd) else { return nil }
        let ilstEnd = min(ilst + atomSize(data, ilst), end)
        guard let covr = findAtom("covr", data, ilst+8, ilstEnd) else { return nil }
        let covrEnd = min(covr + atomSize(data, covr), end)
        guard let dataAtom = findAtom("data", data, covr+8, covrEnd) else { return nil }
        let valueOffset = dataAtom + 16
        let valueEnd = min(dataAtom + atomSize(data, dataAtom), covrEnd)
        guard valueOffset < valueEnd else { return nil }
        return Data(data[valueOffset..<valueEnd])
    }

    // MARK: - Incremental change detection

    private func findChangedFolders(source: LibrarySource) async -> [String] {
        do {
            let storedStats = try SorrivaDatabase.shared.folderStats(sourceId: source.id)
            guard !storedStats.isEmpty else { return [] }

            let client = SMBClient(host: source.host)
            try await client.login(username: source.username ?? "", password: source.password ?? "")
            defer { Task { try? await client.logoff() } }
            try await client.connectShare(source.share)
            defer { Task { try? await client.disconnectShare() } }

            var changed: [String] = []
            for stored in storedStats {
                var files: [(path: String, size: Int)] = []
                try? await scanner.collectAudioFilesPublic(client: client, path: stored.folderPath, results: &files)
                if files.count != stored.fileCount || files.reduce(0, { $0 + $1.size }) != stored.totalBytes {
                    changed.append(stored.folderPath)
                }
            }
            return changed
        } catch {
            print("SCAN: stat failed for \(source.displayName): \(error)")
            return []
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let libraryDidUpdate = Notification.Name("SorrivaLibraryDidUpdate")
}
