import Foundation

// MARK: - LocalPlaybackService
// Orchestrates local library → Sonos/Bluesound playback.
//
// Transport routing:
//   Sonos / Bluesound zones → x-file-cifs:// direct NAS playback
//     - NAS share registered via CreateObject once per source
//     - AddURIToQueue (single) in loop — AddMultipleURIsToQueue rejects x-file-cifs
//     - Sonos manages its own queue; app not needed after queuing
//     - Screen can be locked; phone calls do not interrupt
//
//   AirPlay-only zones → HTTP server (SorrivaHTTPServer) — fallback, not yet implemented
//
// x-file-cifs URI format: x-file-cifs://[host]/[share]/[relative-path]
// Example: x-file-cifs://av-server/media/Music II/Artist/Album/01 Track.flac
// Spaces are allowed in x-file-cifs URIs — do NOT percent-encode them.

@MainActor
final class LocalPlaybackService {

    static let shared = LocalPlaybackService()
    private init() {}

    // Track which NAS shares have been registered with Sonos this session
    // Key: "host/share" → Set of coordinator hosts it's been registered with
    private var registeredShares: [String: Set<String>] = [:]

    // MARK: - Public API

    func playTrack(_ track: Track, on zone: SonosZone) async {
        await playTracks([track], on: zone)
    }

    func playAlbum(_ tracks: [Track], on zone: SonosZone) async {
        await playTracks(tracks, on: zone)
    }

    // MARK: - Core playback

    private func playTracks(_ tracks: [Track], on zone: SonosZone) async {
        guard !tracks.isEmpty else { return }
        sLog("LOCALPLAY: playTracks — \(tracks.count) track(s) on \(zone.name)")

        // Build (track, source) pairs — each track knows its sourceId
        var trackSourcePairs: [(Track, LibrarySource)] = []
        for track in tracks {
            guard let source = try? SorrivaDatabase.shared.librarySource(id: track.sourceId) else {
                sLog("LOCALPLAY: skipping \(track.title) — source not found")
                continue
            }
            trackSourcePairs.append((track, source))
        }
        guard !trackSourcePairs.isEmpty else {
            sLog("LOCALPLAY: no tracks with valid sources — aborting")
            return
        }

        // Register all unique NAS shares with Sonos coordinator
        let coordinatorHost = zone.host
        await registerSharesIfNeeded(sources: trackSourcePairs.map { $0.1 }, coordinatorHost: coordinatorHost)

        if trackSourcePairs.count == 1 {
            await playSingleTrack(trackSourcePairs[0].0, source: trackSourcePairs[0].1, on: zone)
        } else {
            await playQueue(trackSourcePairs, on: zone)
        }
    }

    // MARK: - Single track

    private func playSingleTrack(_ track: Track, source: LibrarySource, on zone: SonosZone) async {
        let uri = xFileCIFSURI(track: track, source: source)
        sLog("LOCALPLAY: single track — \(track.title)")
        sLog("LOCALPLAY: URI — \(uri)")

        if let album = try? SorrivaDatabase.shared.album(id: track.albumId) {
            PlaybackContextService.shared.setLocalContext(zoneID: zone.id, track: track, album: album)
        }

        let host = zone.host
        await Task.detached {
            await ZoneDiscoveryService.setAVTransportURIWithMetadata(host: host, streamURL: uri, didl: "")
            await ZoneDiscoveryService.sendTransportAction(host: host, action: "Play")
            sLog("LOCALPLAY: play command sent — \(track.title)")
        }.value
    }

    // MARK: - Album queue

    private func playQueue(_ pairs: [(Track, LibrarySource)], on zone: SonosZone) async {
        sLog("LOCALPLAY: queueing \(pairs.count) tracks on \(zone.name)")

        // Set context for first track
        let firstTrack = pairs[0].0
        if let album = try? SorrivaDatabase.shared.album(id: firstTrack.albumId) {
            PlaybackContextService.shared.setLocalContext(zoneID: zone.id, track: firstTrack, album: album)
        }

        let host = zone.host
        let zoneID = zone.id
        let uris = pairs.map { xFileCIFSURI(track: $0.0, source: $0.1) }

        await Task.detached {
            // Clear existing queue
            await ZoneDiscoveryService.removeAllTracksFromQueue(host: host)

            // AddURIToQueue in loop — x-file-cifs requires single-track calls
            for (idx, uri) in uris.enumerated() {
                await ZoneDiscoveryService.addURIToQueue(host: host, uri: uri)
                sLog("LOCALPLAY: queued track \(idx + 1)/\(uris.count)")
            }

            // Point transport at queue and play
            let queueURI = "x-rincon-queue:\(zoneID)#0"
            await ZoneDiscoveryService.setAVTransportURIWithMetadata(host: host, streamURL: queueURI, didl: "")
            await ZoneDiscoveryService.sendTransportAction(host: host, action: "Play")
            sLog("LOCALPLAY: album queue started — \(uris.count) tracks")
        }.value
    }

    // MARK: - NAS share registration

    private func registerSharesIfNeeded(sources: [LibrarySource], coordinatorHost: String) async {
        // Deduplicate by host+share
        var seen = Set<String>()
        let unique = sources.filter { source in
            let key = "\(source.host)/\(source.share)"
            return seen.insert(key).inserted
        }

        for source in unique {
            let shareKey = "\(source.host)/\(source.share)"
            var registered = registeredShares[shareKey] ?? []
            guard !registered.contains(coordinatorHost) else {
                sLog("LOCALPLAY: share already registered — \(shareKey) on \(coordinatorHost)")
                continue
            }
            // nasPath format: //hostname/share  e.g. //av-server/media/Music II
            let nasPath = "//\(source.host)/\(source.share)"
            sLog("LOCALPLAY: registering NAS share — \(nasPath) on \(coordinatorHost)")
            await ZoneDiscoveryService.createObject(host: coordinatorHost, nasPath: nasPath)
            registered.insert(coordinatorHost)
            registeredShares[shareKey] = registered
        }
    }

    // MARK: - URI construction

    /// Build x-file-cifs:// URI for a track.
    /// Format: x-file-cifs://[host]/[share]/[filePath]
    /// filePath from DB is relative to share root, starts with /
    /// e.g. filePath = "/Music II/Artist/Album/01 Track.flac"
    /// source.share = "media"
    /// result = x-file-cifs://av-server/media/Music II/Artist/Album/01 Track.flac
    private func xFileCIFSURI(track: Track, source: LibrarySource) -> String {
        // filePath starts with "/" and includes the share subfolder
        // e.g. /Music II/Pat Metheny/...
        // We need: x-file-cifs://host/share + filePath
        // But filePath already includes the top-level folder that IS part of the registered path
        // Registered path: //av-server/media/Music II
        // filePath: /Music II/Pat Metheny/...
        // So URI = x-file-cifs://av-server/media + filePath
        // = x-file-cifs://av-server/media/Music II/Pat Metheny/...
        let path = track.filePath.hasPrefix("/") ? track.filePath : "/\(track.filePath)"
        return "x-file-cifs://\(source.host)/\(source.share)\(path)"
    }
}
