import Foundation
import SMBClient

// MARK: - LocalPlaybackService
// Orchestrates local library → Sonos/Bluesound playback.
//
// Transport routing:
//   Sonos / Bluesound zones → x-file-cifs:// direct NAS playback
//     - NAS share registered via CreateObject once per source
//     - AddURIToQueue (single) in loop — AddMultipleURIsToQueue rejects x-file-cifs
//     - DIDL with duration declared per track — prevents Sonos aggressive prefetch
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

        // Build DIDL with duration before entering detached task
        let didl = await Self.buildTrackDIDL(track: track, uri: uri, source: source)
        let host = zone.host
        await Task.detached {
            await ZoneDiscoveryService.setAVTransportURIWithMetadata(host: host, streamURL: uri, didl: didl)
            await ZoneDiscoveryService.sendTransportAction(host: host, action: "Play")
            sLog("LOCALPLAY: play command sent — \(track.title)")
        }.value
    }

    // MARK: - Album queue

    private func playQueue(_ pairs: [(Track, LibrarySource)], on zone: SonosZone) async {
        sLog("LOCALPLAY: queueing \(pairs.count) tracks on \(zone.name)")

        // Pre-build URIs and DIDLs on MainActor before entering detached task
        // DIDL with duration prevents Sonos aggressive prefetch on zero-duration tracks
        var queueItems: [(uri: String, didl: String, title: String)] = []
        var contextItems: [(uri: String, track: Track, album: Album)] = []

        for (track, source) in pairs {
            let uri = xFileCIFSURI(track: track, source: source)
            let didl = await Self.buildTrackDIDL(track: track, uri: uri, source: source)
            queueItems.append((uri: uri, didl: didl, title: track.title))
            // Build context queue for PlaybackContextService URI-based advancement
            if let album = try? SorrivaDatabase.shared.album(id: track.albumId) {
                contextItems.append((uri: uri, track: track, album: album))
            }
        }

        // Register full queue so context advances as Sonos moves through tracks
        PlaybackContextService.shared.setLocalQueue(zoneID: zone.id, items: contextItems)

        let host = zone.host
        let zoneID = zone.id

        await Task.detached {
            // Clear existing queue
            await ZoneDiscoveryService.removeAllTracksFromQueue(host: host)

            // AddURIToQueue in loop — x-file-cifs requires single-track calls
            for (idx, item) in queueItems.enumerated() {
                await ZoneDiscoveryService.addURIToQueue(host: host, uri: item.uri, didl: item.didl)
                sLog("LOCALPLAY: queued track \(idx + 1)/\(queueItems.count) — \(item.title)")
            }

            // Point transport at queue and play
            let queueURI = "x-rincon-queue:\(zoneID)#0"
            await ZoneDiscoveryService.setAVTransportURIWithMetadata(host: host, streamURL: queueURI, didl: "")
            await ZoneDiscoveryService.sendTransportAction(host: host, action: "Play")
            sLog("LOCALPLAY: album queue started — \(queueItems.count) tracks")
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
        let path = track.filePath.hasPrefix("/") ? track.filePath : "/\(track.filePath)"
        return "x-file-cifs://\(source.host)/\(source.share)\(path)"
    }

    // MARK: - DIDL construction

    /// Build DIDL-Lite metadata for a local track.
    /// Includes duration when available — prevents Sonos aggressive prefetch.
    /// For FLAC tracks with no duration in DB, attempts a quick SMB read of STREAMINFO.
    /// For other formats with no duration, omits the duration attribute entirely —
    /// Sonos handles missing duration better than zero duration.
    private nonisolated static func buildTrackDIDL(track: Track, uri: String, source: LibrarySource) async -> String {
        let escapedTitle = track.title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let escapedURI = uri.replacingOccurrences(of: "&", with: "&amp;")

        var seconds = track.duration ?? 0
        let ext = (track.filePath as NSString).pathExtension.lowercased()

        // For FLAC with missing duration — quick SMB read to parse STREAMINFO
        if seconds == 0 && ext == "flac" {
            if let fetched = await fetchFLACDuration(track: track, source: source) {
                seconds = fetched
                sLog("LOCALPLAY: FLAC duration fetched on-the-fly — \(track.title): \(Int(seconds))s")
            }
        }

        // Omit duration attribute when unknown — zero duration causes Sonos to skip the track
        let durationAttr = seconds > 0
            ? " duration=&quot;\(formatDuration(Int(seconds)))&quot;"
            : ""

        return "&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;item id=&quot;-1&quot; parentID=&quot;-1&quot; restricted=&quot;true&quot;&gt;&lt;dc:title&gt;\(escapedTitle)&lt;/dc:title&gt;&lt;upnp:class&gt;object.item.audioItem.musicTrack&lt;/upnp:class&gt;&lt;res\(durationAttr) protocolInfo=&quot;x-file-cifs:*:application/octet-stream:*&quot;&gt;\(escapedURI)&lt;/res&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;"
    }

    /// Quick SMB read of first 64KB to parse FLAC STREAMINFO for duration.
    /// Only called for FLAC tracks where duration is missing from DB.
    private nonisolated static func fetchFLACDuration(track: Track, source: LibrarySource) async -> Double? {
        do {
            let client = SMBClient(host: source.host)
            let creds = source.resolvedCredentials
            try await client.login(username: creds.username.isEmpty ? "guest" : creds.username, password: creds.password)
            try await client.connectShare(source.share)
            let reader = client.fileReader(path: track.filePath)
            let data = try await reader.read(offset: 0, length: 65536)
            try? await reader.close()
            try? await client.disconnectShare()
            try? await client.logoff()
            return parseFLACStreamInfo(data: data)
        } catch {
            sLog("LOCALPLAY: FLAC duration fetch failed — \(track.title): \(error.localizedDescription)")
            return nil
        }
    }

    /// Parse FLAC STREAMINFO block to extract total duration in seconds.
    private nonisolated static func parseFLACStreamInfo(data: Data) -> Double? {
        guard data.count > 4,
              data[0] == 0x66, data[1] == 0x4C,
              data[2] == 0x61, data[3] == 0x43 else { return nil }
        var offset = 4
        while offset + 4 <= data.count {
            let blockHeader = data[offset]
            let blockType   = blockHeader & 0x7F
            let blockSize   = Int(data[offset+1]) << 16 | Int(data[offset+2]) << 8 | Int(data[offset+3])
            offset += 4
            if blockType == 0 && blockSize >= 18 && offset + blockSize <= data.count {
                let sampleRate   = (Int(data[offset+10]) << 12)
                                 | (Int(data[offset+11]) << 4)
                                 | (Int(data[offset+12]) >> 4)
                let totalSamples = (Int(data[offset+13] & 0x0F) << 32)
                                 | (Int(data[offset+14]) << 24)
                                 | (Int(data[offset+15]) << 16)
                                 | (Int(data[offset+16]) << 8)
                                 |  Int(data[offset+17])
                guard sampleRate > 0, totalSamples > 0 else { return nil }
                return Double(totalSamples) / Double(sampleRate)
            }
            offset += blockSize
            if (blockHeader & 0x80) != 0 { break }
        }
        return nil
    }

    /// Format seconds as h:mm:ss for DIDL duration attribute.
    private nonisolated static func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }
}
