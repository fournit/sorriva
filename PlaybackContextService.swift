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

    // Local queue registry — keyed by zoneID → [URI: (Track, Album)]
    // Set by LocalPlaybackService when queuing an album.
    // Used to advance context when Sonos reports a new TrackURI.
    private var localQueues: [String: [(uri: String, track: Track, album: Album)]] = [:]

    private var cancellables = Set<AnyCancellable>()
    private var observing = false
    private var previousZones: [String: SonosZone] = [:]

    private init() {}

    // MARK: - Zone observation

    func observe(_ discovery: ZoneDiscoveryService) {
        guard !observing else { return }
        observing = true
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
                // Zone went idle — clear local context and queue
                if zone.idleState {
                    contexts[zone.id] = nil
                    localQueues[zone.id] = nil
                    continue
                }

                // Check if Sonos has advanced to a new track URI in the local queue
                let uriChanged = zone.currentTrackURI != prev?.currentTrackURI
                if uriChanged && !zone.currentTrackURI.isEmpty {
                    advanceLocalContext(zoneID: zone.id, toURI: zone.currentTrackURI)
                }
                continue
            }

            let trackChanged  = zone.currentTrack != prev?.currentTrack
            let artistChanged = zone.currentArtist != prev?.currentArtist
            let logoChanged   = zone.stationLogoURL != prev?.stationLogoURL

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

    // MARK: - Local queue advancement

    /// Match the current Sonos TrackURI to the local queue and update context.
    /// Called on every poll when the zone is in local playback and URI changed.
    private func advanceLocalContext(zoneID: String, toURI: String) {
        guard let queue = localQueues[zoneID] else { return }

        // Normalize URI for matching — strip query params and trailing slashes
        let normalize: (String) -> String = { uri in
            uri.components(separatedBy: "?").first?
               .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? uri
        }
        let normalizedCurrent = normalize(toURI)

        if let match = queue.first(where: { normalize($0.uri) == normalizedCurrent }) {
            contexts[zoneID] = PlaybackContext(
                track: match.track.title,
                artist: match.track.artistName ?? match.album.artistName,
                albumName: match.album.title,
                duration: match.track.duration ?? 0,
                artAlbum: match.album,
                artURL: nil,
                isLocal: true
            )
        }
    }

    // MARK: - Local playback

    /// Set context for a single track. Clears any existing local queue for this zone.
    func setLocalContext(zoneID: String, track: Track, album: Album) {
        let apply = {
            self.localQueues[zoneID] = nil
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
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async { apply() } }
    }

    /// Register a full album queue so context can advance as Sonos moves through tracks.
    /// Also sets context to the first track immediately.
    func setLocalQueue(zoneID: String, items: [(uri: String, track: Track, album: Album)]) {
        let apply = {
            self.localQueues[zoneID] = items
            guard let first = items.first else { return }
            self.contexts[zoneID] = PlaybackContext(
                track: first.track.title,
                artist: first.track.artistName ?? first.album.artistName,
                albumName: first.album.title,
                duration: first.track.duration ?? 0,
                artAlbum: first.album,
                artURL: nil,
                isLocal: true
            )
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async { apply() } }
    }

    // MARK: - Testing support

    /// Directly trigger URI-based context advancement — for unit tests only.
    func simulateURIChange(zoneID: String, toURI: String) {
        advanceLocalContext(zoneID: zoneID, toURI: toURI)
    }

    func clearLocalContext(zoneID: String) {
        DispatchQueue.main.async {
            if self.contexts[zoneID]?.isLocal == true {
                self.contexts[zoneID] = nil
                self.localQueues[zoneID] = nil
            }
        }
    }
}
