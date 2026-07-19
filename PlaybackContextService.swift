import Foundation
import Combine
import SwiftUI

// MARK: - PlaybackContext
// Snapshot of what's playing on a zone — single source of truth for all UI surfaces.
// For local tracks: populated by LocalPlaybackService at play time with full DB metadata.
// For stations/Connect: populated by PlaybackContextService from zone poll changes.

struct PlaybackContext {
    var track: String           // Track title
    var artist: String          // Artist name
    var albumName: String       // Album name
    var duration: Double        // Seconds — from DB for local tracks, 0 for stations
    var artAlbum: Album?        // Non-nil for local tracks — passed directly to AlbumArtView
    var artURL: String?         // Non-nil for stations/Connect — remote logo/art URL
    var isLocal: Bool           // True = local file playback via LocalPlaybackService
}

// MARK: - PlaybackContextService
// Observed via @EnvironmentObject throughout the view hierarchy.
// Zone cards, mini player, now playing, and track list all read from here.
// No per-view DB calls — local track metadata is resolved once at play time.

final class PlaybackContextService: ObservableObject {

    static let shared = PlaybackContextService()

    @Published var contexts: [String: PlaybackContext] = [:]

    private var cancellables = Set<AnyCancellable>()
    private var previousZones: [String: SonosZone] = [:]

    private init() {}

    // MARK: - Zone observation

    func observe(_ discovery: ZoneDiscoveryService) {
        discovery.$zones
            .receive(on: DispatchQueue.main)
            .sink { [weak self] zones in
                self?.handleZoneUpdate(zones)
            }
            .store(in: &cancellables)
    }

    private func handleZoneUpdate(_ zones: [SonosZone]) {
        for zone in zones {
            let prev = previousZones[zone.id]

            if let existing = contexts[zone.id], existing.isLocal {
                if zone.idleState {
                    contexts[zone.id] = nil
                }
                continue
            }

            let trackChanged = zone.currentTrack != prev?.currentTrack
            let artistChanged = zone.currentArtist != prev?.currentArtist
            let logoChanged = zone.stationLogoURL != prev?.stationLogoURL

            if trackChanged || artistChanged || logoChanged || prev == nil {
                if zone.isPlaying || !zone.currentTrack.isEmpty {
                    contexts[zone.id] = PlaybackContext(
                        track: zone.currentTrack,
                        artist: zone.currentArtist,
                        albumName: zone.stationName,
                        duration: 0,
                        artAlbum: nil,
                        artURL: zone.stationLogoURL.isEmpty ? nil : zone.stationLogoURL,
                        isLocal: false
                    )
                } else if !zone.isPlaying && zone.currentTrack.isEmpty {
                    contexts[zone.id] = nil
                }
            }
        }

        let activeIDs = Set(zones.map { $0.id })
        for id in contexts.keys where !activeIDs.contains(id) {
            contexts[id] = nil
        }

        previousZones = Dictionary(uniqueKeysWithValues: zones.map { ($0.id, $0) })
    }

    // MARK: - Local playback

    func setLocalContext(zoneID: String, track: Track, album: Album) {
        DispatchQueue.main.async {
            self.contexts[zoneID] = PlaybackContext(
                track: track.title,
                artist: track.artistName ?? album.artistName,
                albumName: album.title,
                duration: track.duration ?? 0,
                artAlbum: album,
                artURL: nil,
                isLocal: true
            )
        }
    }

    func clearLocalContext(zoneID: String) {
        DispatchQueue.main.async {
            if self.contexts[zoneID]?.isLocal == true {
                self.contexts[zoneID] = nil
            }
        }
    }
}
