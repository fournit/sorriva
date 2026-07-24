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

    /// Sonos endpoint driver — typed command execution for all Sonos zones.
    /// Constitution reference: I-005, ADR-007, ADR-008.
    let sonosDriver: SonosEndpointDriver = .shared

    /// Source resolver — resolves canonical track identity to playable representation.
    /// Constitution reference: I-006, ADR-006, WP-13.
    let sourceResolver: SourceResolver = .shared

    /// Library service — application-level library use cases.
    /// Constitution reference: LibraryService section, I-003.
    let libraryService: LibraryService = .shared

    /// Playback coordinator — owns command lifecycle, pending/confirmed/failed states.
    /// Constitution reference: Pattern B, WP-10.
    let playbackCoordinator: PlaybackCoordinator = .shared

    /// Authoritative playback state store — single source of truth for all UI.
    /// Constitution reference: I-002, ADR-005.
    @Published var playbackStore: PlaybackStore = .shared

    // MARK: - Init

    init() {
        // Database initializes on first access — migrations run here.
        _ = database

        // Reset any sources stuck in "scanning" from a previous interrupted session.
        resetStaleScanStates()

        // Wire playback context to discovery.
        playbackContext.observe(discovery)

        // Wire SonosEndpointDriver to discovery for host lookup.
        sonosDriver.discovery = discovery

        // Wire PlaybackCoordinator to its dependencies.
        playbackCoordinator.discovery    = discovery
        playbackCoordinator.localPlayback = LocalPlaybackService.shared
        playbackCoordinator.sonosDriver  = sonosDriver
        playbackCoordinator.store        = playbackStore

        // Wire PlaybackStore to both upstream sources.
        playbackStore.observe(discovery: discovery, playbackContext: playbackContext)

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
