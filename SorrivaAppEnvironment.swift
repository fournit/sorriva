import SwiftUI
import Combine
import GRDB

// MARK: - SorrivaAppEnvironment
// Single composition root. Constructed once at app launch in SorrivaApp.
// All long-lived services live here and are injected via @EnvironmentObject.
//
// Constitution reference: ADR-011 — One composition root.
// No application-service singleton access from views after WP-07.
// Existing singletons are referenced here during the migration window —
// they will be replaced with protocol-backed instances in WP-09 onwards.

@MainActor
final class SorrivaAppEnvironment: ObservableObject {

    // MARK: - Services

    /// Shared database — singleton retained during migration window.
    let database: SorrivaDatabase = .shared

    /// Credential store — Keychain-backed, singleton retained during migration window.
    let credentials: KeychainCredentialStore = .shared

    /// Zone discovery and Sonos control — single instance for the app session.
    /// @Published so SwiftUI reacts when discovery publishes zone changes.
    @Published var discovery: ZoneDiscoveryService = ZoneDiscoveryService()

    /// Playback presentation context — single source for track/artist/album display.
    @Published var playbackContext: PlaybackContextService = .shared

    /// Scan coordinator — orchestrates SMB scanning, artwork, and retry passes.
    @Published var scanCoordinator: ScanCoordinator = .shared

    /// Tab bar state — owns selected tab and navigation state.
    @Published var tabState: SorrivaTabBarState = SorrivaTabBarState()

    // MARK: - Init

    init() {
        // Database initializes on first access — migrations run here.
        _ = database

        // Reset any sources stuck in "scanning" from a previous interrupted session.
        resetStaleScanStates()

        // Wire playback context to discovery.
        playbackContext.observe(discovery)

        // Prefetch station logos into URLCache so Library loads instantly.
        prefetchStationLogos()
    }

    // MARK: - Startup tasks

    private func resetStaleScanStates() {
        let sources = (try? database.allLibrarySources()) ?? []
        for source in sources {
            if source.scanState == "scanning" {
                try? database.updateScanState(sourceId: source.id, state: "error")
            }
        }
    }

    private func prefetchStationLogos() {
        Task.detached(priority: .background) { [database] in
            let iheart = (try? database.allStations(source: "iheart")) ?? []
            let somafm = (try? database.allStations(source: "somafm")) ?? []
            let urls = (iheart + somafm)
                .compactMap { $0.logoURL }
                .compactMap { URL(string: $0) }

            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask {
                        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
                        guard URLCache.shared.cachedResponse(for: request) == nil else { return }
                        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return }
                        let cached = CachedURLResponse(response: response, data: data)
                        URLCache.shared.storeCachedResponse(cached, for: request)
                    }
                }
            }
        }
    }
}
