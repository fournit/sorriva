import Foundation
import SwiftUI
import Combine
import UIKit

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

        Task.detached { await ArtworkCache.shared.fetchMissingArtwork() }
    }

    private func handleProgress(_ p: ScanProgress) {
        if p.phase == .complete {
            lastReport = p.report
        } else {
            progress = p
        }
    }

    // MARK: - Incremental change detection

    private func findChangedFolders(source: LibrarySource) async -> [String] {
        do {
            let currentStats = try await scanner.statFolders(source: source)
            let storedStats  = try SorrivaDatabase.shared.folderStats(sourceId: source.id)
            let storedMap    = Dictionary(uniqueKeysWithValues: storedStats.map { ($0.folderPath, $0) })

            var changed: [String] = []
            for current in currentStats {
                if let stored = storedMap[current.folderPath] {
                    if current.fileCount != stored.fileCount || current.totalBytes != stored.totalBytes {
                        changed.append(current.folderPath)
                    }
                } else {
                    changed.append(current.folderPath)
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
