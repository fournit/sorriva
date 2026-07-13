import Foundation
import SwiftUI
import Combine

// MARK: - ScanCoordinator
// App-level singleton. Owns all scan lifecycle:
//   • Triggers immediate scan when a new source is saved
//   • Checks for changes on app foreground, rescans changed sources
//   • Publishes live progress so any view can observe status
//
// Never call SMBScanner directly from views — always go through ScanCoordinator.

@MainActor
final class ScanCoordinator: ObservableObject {

    static let shared = ScanCoordinator()

    // MARK: - Published state

    @Published var activeScanSourceId: String? = nil
    @Published var progress: ScanProgress? = nil

    // MARK: - Private

    private let scanner = SMBScanner()
    private var scanTask: Task<Void, Never>? = nil

    private init() {}

    // MARK: - Public API

    /// Called when a new share is saved. Starts a scan immediately.
    func scanNewSource(_ source: LibrarySource) {
        startScan(source: source)
    }

    /// Called when the app foregrounds. Stats all sources and rescans any that changed.
    func checkForChanges() {
        Task {
            let sources = (try? SorrivaDatabase.shared.allLibrarySources()) ?? []
            for source in sources {
                // Skip sources already being scanned
                guard source.scanState != "scanning" else { continue }
                guard source.type == "smb" else { continue }

                let changed = await hasChanged(source: source)
                if changed {
                    print("SCAN: \(source.displayName) changed — queuing rescan")
                    startScan(source: source)
                    // One scan at a time — wait for it to finish before checking next
                    await scanTask?.value
                }
            }
        }
    }

    /// Manual scan trigger — called from "Scan Now" in ShareActionSheet.
    func scanSource(_ source: LibrarySource) {
        startScan(source: source)
    }

    // MARK: - Private

    private func startScan(source: LibrarySource) {
        // Cancel any in-flight scan for the same source
        if activeScanSourceId == source.id {
            scanTask?.cancel()
        }

        scanTask = Task {
            await runScan(source: source)
        }
    }

    private func runScan(source: LibrarySource) async {
        activeScanSourceId = source.id
        try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "scanning")

        do {
            try await scanner.scan(source: source) { [weak self] scanProgress in
                Task { @MainActor [weak self] in
                    self?.progress = scanProgress
                }
            }
            print("SCAN: Completed — \(source.displayName)")
        } catch {
            print("SCAN: Failed — \(source.displayName): \(error)")
            try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "error")
        }

        // Post notification so LocalLibraryView reloads track counts
        NotificationCenter.default.post(name: .libraryDidUpdate, object: nil)

        if activeScanSourceId == source.id {
            activeScanSourceId = nil
            progress = nil
        }
    }

    /// Quick stat check — returns true if file count or total size changed since last scan.
    private func hasChanged(source: LibrarySource) async -> Bool {
        // Never scanned — always needs a scan
        guard let lastCount = source.lastScanFileCount,
              let lastBytes = source.lastScanTotalBytes else {
            return true
        }

        do {
            let current = try await scanner.statShare(source: source)
            return current.fileCount != lastCount || current.totalBytes != lastBytes
        } catch {
            print("SCAN: Stat failed for \(source.displayName): \(error)")
            return false  // Don't force a rescan on network error
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let libraryDidUpdate = Notification.Name("SorrivaLibraryDidUpdate")
}
