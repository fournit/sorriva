import Foundation
import Combine
import SwiftUI
import GRDB

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
    private var zoneHosts: [String: String] = [:]  // zoneID → host, for Sonos queue fetch
    private var localPlaybackStarted: [String: Date] = [:]  // zoneID → when local playback initiated

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

            // Pure stateless derivation — no transition detection.
            // Derive context fresh from what Sonos reports right now.
            // Truth is whatever Sonos says.

            // Case 1: x-file-cifs:// URI → local file
            if !zone.currentTrackURI.isEmpty
                && zone.currentTrackURI.hasPrefix("x-file-cifs://") {
                let uriChanged = zone.currentTrackURI != prev?.currentTrackURI
                let hasLocalContext = contexts[zone.id]?.isLocal == true
                if !hasLocalContext || uriChanged {
                    zoneHosts[zone.id] = zone.host
                    resolveLocalURI(zone.currentTrackURI, forZoneID: zone.id)
                }
                continue
            }

            // Case 2: Idle with radio URI → show station
            let uriIsRadio = !zone.currentTrackURI.isEmpty
                && !zone.currentTrackURI.hasPrefix("x-rincon-queue:")
            if !zone.isPlaying && uriIsRadio {
                let uriChanged = zone.currentTrackURI != prev?.currentTrackURI
                if uriChanged || contexts[zone.id] == nil {
                    contexts[zone.id] = PlaybackContext(
                        track: "", artist: "",
                        albumName: zone.stationName.isEmpty ? "Radio" : zone.stationName,
                        duration: 0, artAlbum: nil,
                        artURL: zone.stationLogoURL.isEmpty ? nil : zone.stationLogoURL,
                        isLocal: false
                    )
                    resolveStationURI(zone.currentTrackURI, zoneID: zone.id,
                                      stationName: zone.stationName,
                                      stationLogoURL: zone.stationLogoURL)
                }
                continue
            }

            // Case 3: Radio playing → show stream content
            // Skip if within 2s grace period after local playback was initiated
            let inLocalGrace = localPlaybackStarted[zone.id].map {
                Date().timeIntervalSince($0) < 2.0
            } ?? false
            if zone.isPlaying && !inLocalGrace {
                contexts[zone.id] = PlaybackContext(
                    track: zone.currentTrack,
                    artist: zone.currentArtist,
                    albumName: zone.stationName,
                    duration: 0,
                    artAlbum: nil,
                    artURL: zone.stationLogoURL.isEmpty ? nil : zone.stationLogoURL,
                    isLocal: false
                )
                continue
            }

            // Case 4: Nothing — leave last known context visible
            // Don't clear — Sonos may be mid-transition between sources
        }

        // Remove contexts for zones no longer in topology
        let activeIDs = Set(zones.map { $0.id })
        for id in Array(contexts.keys) where !activeIDs.contains(id) {
            contexts[id] = nil
            localQueues[id] = nil
        }

        previousZones = Dictionary(uniqueKeysWithValues: zones.map { ($0.id, $0) })
    }

    // MARK: - Station URI resolution

    /// Resolve an idle radio zone — show station name/logo from DB or zone state.
    private func resolveStationURI(_ uri: String, zoneID: String,
                                   stationName: String, stationLogoURL: String) {
        // Use what ZoneDiscoveryService already restored from zone_state
        if !stationName.isEmpty {
            contexts[zoneID] = PlaybackContext(
                track: "",
                artist: "",
                albumName: stationName,
                duration: 0,
                artAlbum: nil,
                artURL: stationLogoURL.isEmpty ? nil : stationLogoURL,
                isLocal: false
            )
            sLog("CONTEXT: restored idle station \(stationName) for \(zoneID)")
            return
        }

        // Try to find station in DB by matching stream URL
        Task { @MainActor in
            let allStations = (try? SorrivaDatabase.shared.allStations(source: "iheart")) ?? []
            let match = allStations.first { station in
                guard let streamURL = station.streamURL else { return false }
                return uri.contains(streamURL) || streamURL.contains(uri)
            }
            if let station = match {
                self.contexts[zoneID] = PlaybackContext(
                    track: "",
                    artist: "",
                    albumName: station.name,
                    duration: 0,
                    artAlbum: nil,
                    artURL: station.logoURL,
                    isLocal: false
                )
                sLog("CONTEXT: resolved idle station \(station.name) for \(zoneID)")
            }
        }
    }

    // MARK: - Local URI resolution

    /// Resolve a x-file-cifs:// URI to track metadata from the database.
    /// Called when a zone is found playing local content on launch or after zone change.
    private func resolveLocalURI(_ uri: String, forZoneID zoneID: String) {
        // Record when local playback started — grace period prevents radio context overwrite
        localPlaybackStarted[zoneID] = Date()
        // Mark as local immediately to prevent re-entry, but preserve existing display
        // if we already have context — avoids blank flash during async DB lookup
        if contexts[zoneID] == nil {
            contexts[zoneID] = PlaybackContext(
                track: "", artist: "", albumName: "",
                duration: 0, artAlbum: nil, artURL: nil, isLocal: true
            )
        } else {
            // Keep existing context visible, just mark isLocal
            var existing = contexts[zoneID]!
            existing = PlaybackContext(
                track: existing.track, artist: existing.artist,
                albumName: existing.albumName, duration: existing.duration,
                artAlbum: existing.artAlbum, artURL: existing.artURL,
                isLocal: true
            )
            contexts[zoneID] = existing
        }
        Task { @MainActor in
            // Step 1: resolve current track from URI for immediate display
            guard let currentTrack = resolveTrackFromURI(uri) else {
                sLog("CONTEXT: no track found for URI \(uri.prefix(60))")
                return
            }
            guard let album = try? SorrivaDatabase.shared.album(id: currentTrack.albumId) else { return }

            contexts[zoneID] = PlaybackContext(
                track: currentTrack.title,
                artist: currentTrack.artistName ?? album.artistName,
                albumName: album.title,
                duration: currentTrack.duration ?? 0,
                artAlbum: album,
                artURL: nil,
                isLocal: true
            )
            sLog("CONTEXT: resolved local URI for \(zoneID) → \(currentTrack.title)")

            // Step 2: fetch Sonos queue to populate localQueues for track advancement
            guard let host = self.zoneHosts[zoneID], !host.isEmpty else {
                sLog("CONTEXT: no host for \(zoneID) — cannot fetch queue")
                return
            }
            await fetchSonosQueue(host: host, zoneID: zoneID)
        }
    }

    /// Extract file path from x-file-cifs:// URI and look up track in DB.
    private func resolveTrackFromURI(_ uri: String) -> Track? {
        let decoded = uri
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .removingPercentEncoding ?? uri

        let parts = decoded.components(separatedBy: "/")
        // x-file-cifs://host/share/path → drop first 4 components
        guard parts.count > 4 else { return nil }
        let filePath = "/" + parts.dropFirst(4).joined(separator: "/")
        sLog("CONTEXT: looking up filePath: \(filePath)")

        return try? SorrivaDatabase.shared.dbQueue.read { db in
            try Track.filter(sql: "filePath LIKE ?", arguments: ["%\(filePath)"]).fetchOne(db)
        }
    }

    /// Fetch Sonos queue via ContentDirectory Browse and populate localQueues.
    private func fetchSonosQueue(host: String, zoneID: String) async {
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
              <ObjectID>Q:0</ObjectID>
              <BrowseFlag>BrowseDirectChildren</BrowseFlag>
              <Filter>*</Filter>
              <StartingIndex>0</StartingIndex>
              <RequestedCount>100</RequestedCount>
              <SortCriteria></SortCriteria>
            </u:Browse>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaServer/ContentDirectory/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData

        let statusCode: Int
        let xml: String
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            xml = String(data: data, encoding: .utf8) ?? ""
            sLog("CONTEXT: Sonos queue Browse status=\(statusCode) bytes=\(data.count)")
            if statusCode != 200 {
                sLog("CONTEXT: queue fetch non-200: \(xml.prefix(200))")
                return
            }
        } catch {
            sLog("CONTEXT: queue fetch error: \(error.localizedDescription)")
            return
        }

        // Extract res (URI) elements from DIDL response
        var queueURIs: [String] = []
        var searchRange = xml.startIndex..<xml.endIndex
        while let resStart = xml.range(of: "<res", range: searchRange),
              let resEnd   = xml.range(of: "</res>", range: resStart.upperBound..<xml.endIndex) {
            let resTag = String(xml[resStart.lowerBound..<resEnd.upperBound])
            // Extract URI from between > and </res>
            if let openEnd = resTag.range(of: ">"),
               let closeStart = resTag.range(of: "</res>") {
                let rawURI = String(resTag[openEnd.upperBound..<closeStart.lowerBound])
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&apos;", with: "'")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                if rawURI.hasPrefix("x-file-cifs://") {
                    queueURIs.append(rawURI)
                }
            }
            searchRange = resEnd.upperBound..<xml.endIndex
        }

        sLog("CONTEXT: Sonos queue has \(queueURIs.count) local tracks")
        guard !queueURIs.isEmpty else { return }

        // Resolve each URI to a Track + Album
        var items: [(uri: String, track: Track, album: Album)] = []
        for uri in queueURIs {
            guard let track = resolveTrackFromURI(uri),
                  let album = try? SorrivaDatabase.shared.album(id: track.albumId) else { continue }
            items.append((uri: uri, track: track, album: album))
        }

        guard !items.isEmpty else { return }
        localQueues[zoneID] = items
        sLog("CONTEXT: populated localQueue for \(zoneID) with \(items.count) tracks")
    }

    // MARK: - Local queue advancement

    /// Resolve new TrackURI directly from DB and update context.
    /// Called when Sonos advances to a new track URI during local playback.
    private func advanceLocalContext(zoneID: String, toURI: String) {
        sLog("CONTEXT: track advanced for \(zoneID) — resolving \(toURI.suffix(50))")
        Task { @MainActor in
            guard let track = self.resolveTrackFromURI(toURI) else {
                sLog("CONTEXT: advance — no DB match for \(toURI.suffix(50))")
                return
            }
            guard let album = try? SorrivaDatabase.shared.album(id: track.albumId) else { return }
            self.contexts[zoneID] = PlaybackContext(
                track: track.title,
                artist: track.artistName ?? album.artistName,
                albumName: album.title,
                duration: track.duration ?? 0,
                artAlbum: album,
                artURL: nil,
                isLocal: true
            )
            sLog("CONTEXT: advanced to \(track.title)")
        }
    }

    // MARK: - Local playback

    /// Set context for a single track. Clears any existing local queue for this zone.
    func setLocalContext(zoneID: String, track: Track, album: Album) {
        localPlaybackStarted[zoneID] = Date()
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
        sLog("CONTEXT: setLocalQueue called for \(zoneID) with \(items.count) items")
        localPlaybackStarted[zoneID] = Date()
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
