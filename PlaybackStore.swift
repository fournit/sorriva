import SwiftUI
import Combine

// MARK: - PlaybackStore
// Single authoritative owner of all playback presentation state.
// Constitution reference: I-002, ADR-005.
//
// Only PlaybackStateReducer writes to this store.
// Views, screen models, and endpoint drivers observe only — never write directly.

@MainActor
final class PlaybackStore: ObservableObject {

    static let shared = PlaybackStore()

    @Published private(set) var zones: [ZonePlaybackSnapshot] = []
    @Published private(set) var selectedEndpointID: String?
    @Published private(set) var pendingCommand: PendingPlaybackCommand?
    @Published private(set) var issue: PlaybackIssue?

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: - Observation setup

    /// Wire the store to its upstream sources.
    /// Called once from SorrivaAppEnvironment.init.
    func observe(discovery: ZoneDiscoveryService,
                 playbackContext: PlaybackContextService) {
        // Reduce whenever either source updates
        Publishers.CombineLatest(
            discovery.$zones,
            playbackContext.$contexts
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] sonosZones, contexts in
            self?.reduce(sonosZones: sonosZones, contexts: contexts)
        }
        .store(in: &cancellables)
    }

    // MARK: - State mutations (internal only)

    func setPendingCommand(_ command: PendingPlaybackCommand?) {
        pendingCommand = command
    }

    func setIssue(_ issue: PlaybackIssue?) {
        self.issue = issue
    }

    func setSelectedEndpoint(_ id: String?) {
        selectedEndpointID = id
    }

    // MARK: - Convenience accessors

    func snapshot(for zoneID: String) -> ZonePlaybackSnapshot? {
        zones.first(where: { $0.id == zoneID })
    }

    var selectedSnapshot: ZonePlaybackSnapshot? {
        guard let id = selectedEndpointID else { return nil }
        return snapshot(for: id)
    }

    // MARK: - Reducer

    private func reduce(sonosZones: [SonosZone], contexts: [String: PlaybackContext]) {
        zones = PlaybackStateReducer.reduce(sonosZones: sonosZones, contexts: contexts)
    }
}

// MARK: - PlaybackStateReducer

enum PlaybackStateReducer {

    static func reduce(sonosZones: [SonosZone],
                       contexts: [String: PlaybackContext]) -> [ZonePlaybackSnapshot] {
        sonosZones.map { zone in
            let ctx = contexts[zone.id]
            let isLocal = ctx?.isLocal == true

            // Track display — local context wins over zone metadata
            let trackTitle: String
            let artistName: String
            let albumName: String
            let sourceLabel: String
            let artAlbum: Album?
            let artURL: String?

            if isLocal, let ctx {
                trackTitle  = ctx.track
                artistName  = ctx.artist
                albumName   = ctx.albumName
                sourceLabel = "Local Library"
                artAlbum    = ctx.artAlbum
                artURL      = nil
            } else {
                trackTitle  = zone.currentTrack
                artistName  = zone.currentArtist
                albumName   = zone.stationName
                sourceLabel = ""
                artAlbum    = nil
                artURL      = zone.stationLogoURL.isEmpty ? nil : zone.stationLogoURL
            }

            return ZonePlaybackSnapshot(
                id:             zone.id,
                name:           zone.name,
                host:           zone.host,
                isPlaying:      zone.isPlaying,
                volume:         zone.volume,
                isHDMI:         zone.isHDMI,
                idleState:      zone.idleState,
                trackTitle:     trackTitle,
                artistName:     artistName,
                albumName:      albumName,
                sourceLabel:    sourceLabel,
                isLocal:        isLocal,
                elapsedSeconds: zone.elapsedSeconds,
                durationSeconds: isLocal && ctx != nil
                    ? Int(ctx!.duration)
                    : zone.durationSeconds,
                artAlbum:       artAlbum,
                artURL:         artURL,
                groupMembers:   zone.groupMembers,
                coordinatorID:  nil,
                isAvailable:    !zone.idleState || zone.isPlaying
            )
        }
    }
}
