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
    func checkForChanges() {
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

                let changedFolders = await findChangedFolders(source: source)
                if !changedFolders.isEmpty {
                    print("SCAN: \(changedFolders.count) changed folder(s) in \(source.displayName)")
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
        guard !albums.isEmpty else { return }

        print("ARTWORK: folder pass — \(albums.count) albums in \(source.displayName)")

        do {
            let client = SMBClient(host: source.host)
            try await client.login(username: source.username ?? "", password: source.password ?? "")
            defer { Task { try? await client.logoff() } }
            try await client.connectShare(source.share)
            defer { Task { try? await client.disconnectShare() } }

            var found = 0
            for album in albums {
                guard !album.folderPath.isEmpty else { continue }

                // List folder contents
                guard let entries = try? await client.listDirectory(path: album.folderPath) else { continue }
                let entryNames = Set(entries.map { $0.name })

                // Find best art candidate
                var artFilePath: String? = nil
                for candidate in Self.artCandidates {
                    if entryNames.contains(candidate) {
                        artFilePath = album.folderPath == "/"
                            ? "/\(candidate)"
                            : "\(album.folderPath)/\(candidate)"
                        break
                    }
                }

                guard let artPath = artFilePath else { continue }

                // Download and save
                guard let imageData = try? await client.download(path: artPath),
                      let image = UIImage(data: imageData) else { continue }

                let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let artDir = docsDir.appendingPathComponent("artwork", isDirectory: true)
                try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)

                let fullURL  = artDir.appendingPathComponent("\(album.id)_full.jpg")
                let thumbURL = artDir.appendingPathComponent("\(album.id)_thumb.jpg")

                if let fullData  = resized(image, to: 600)?.jpegData(compressionQuality: 0.85),
                   let thumbData = resized(image, to: 100)?.jpegData(compressionQuality: 0.85) {
                    try? fullData.write(to: fullURL)
                    try? thumbData.write(to: thumbURL)
                    try? SorrivaDatabase.shared.updateAlbumArtwork(
                        albumId: album.id,
                        thumbPath: thumbURL.path,
                        fullPath: fullURL.path
                    )
                    found += 1
                    await MainActor.run {
                        NotificationCenter.default.post(name: .artworkDidUpdate, object: album.id)
                    }
                }

                // Small delay between downloads — avoid overwhelming NAS
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }

            print("ARTWORK: folder pass complete — \(found)/\(albums.count) found")

        } catch {
            print("ARTWORK: folder pass error — \(error.localizedDescription)")
        }
    }

    private func resized(_ image: UIImage, to maxDimension: CGFloat) -> UIImage? {
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
