import Foundation

// MARK: - LocalPlaybackService
// Orchestrates local library → Sonos playback via SorrivaHTTPServer.
// Single track: SetAVTransportURI + Play (empty DIDL — Sonos plays to EOF).
// Multiple tracks: enqueue 2 tracks at a time, add next track when current starts playing.
// This prevents Sonos from prefetching the entire album at once and skipping early.

@MainActor
final class LocalPlaybackService {

    static let shared = LocalPlaybackService()
    private init() {
        observeTrackStart()
    }

    // MARK: - Internal queue state
    private var queuedTracks: [Track] = []
    private var currentQueueIndex: Int = 0
    private var lastEnqueuedIndex: Int = 1  // track 2 is enqueued at start (index 1)
    private var activeZoneHost: String = ""
    private var activeZoneID: String = ""

    func playTrack(_ track: Track, on zone: SonosZone) async {
        await playTracks([track], on: zone)
    }

    func playAlbum(_ tracks: [Track], on zone: SonosZone) async {
        await playTracks(tracks, on: zone)
    }

    private func playTracks(_ tracks: [Track], on zone: SonosZone) async {
        guard !tracks.isEmpty else { return }
        sLog("LOCALPLAY: playTracks — \(tracks.count) track(s) on \(zone.name)")

        // 1. Start HTTP server if not already running
        if !SorrivaHTTPServer.shared.isRunning {
            do {
                try SorrivaHTTPServer.shared.start()
            } catch {
                sLog("LOCALPLAY: HTTP server failed to start — \(error.localizedDescription)")
                return
            }
        }

        if tracks.count == 1 {
            // MARK: Single track — SetAVTransportURI + Play (empty DIDL, proven working)
            let track = tracks[0]
            guard let uri = SorrivaHTTPServer.shared.localURL(for: track.id, format: track.fileFormat) else {
                sLog("LOCALPLAY: could not construct URI — server not running or no WiFi")
                return
            }
            sLog("LOCALPLAY: single track — \(track.title) — \(uri)")
            SorrivaHTTPServer.shared.setCurrentTrack(id: track.id, duration: track.duration)
            if let album = try? SorrivaDatabase.shared.album(id: track.albumId) {
                PlaybackContextService.shared.setLocalContext(zoneID: zone.id, track: track, album: album)
            }
            let host = zone.host
            await Task.detached {
                await ZoneDiscoveryService.setAVTransportURIWithMetadata(host: host, streamURL: uri, didl: "")
                await ZoneDiscoveryService.sendTransportAction(host: host, action: "Play")
                sLog("LOCALPLAY: play command sent — \(track.title)")
            }.value

        } else {
            // MARK: Multi-track — enqueue first 2 tracks, add more as playback advances
            queuedTracks = tracks
            currentQueueIndex = 0
            lastEnqueuedIndex = 0  // only track 1 enqueued at start
            activeZoneHost = zone.host
            activeZoneID = zone.id

            // Build URI for first track only — add next track when current starts streaming
            let initialTracks = Array(tracks.prefix(1))
            var uris: [String] = []
            var didls: [String] = []
            for track in initialTracks {
                guard let uri = SorrivaHTTPServer.shared.localURL(for: track.id, format: track.fileFormat) else {
                    sLog("LOCALPLAY: skipping \(track.title) — could not construct URI")
                    continue
                }
                uris.append(uri)
                didls.append(buildQueueDIDL(track: track, uri: uri))
            }
            guard !uris.isEmpty else {
                sLog("LOCALPLAY: no valid URIs — aborting")
                return
            }

            sLog("LOCALPLAY: queueing first \(uris.count) of \(tracks.count) tracks on \(zone.name)")
            SorrivaHTTPServer.shared.setCurrentTrack(id: tracks[0].id, duration: tracks[0].duration)
            if let album = try? SorrivaDatabase.shared.album(id: tracks[0].albumId) {
                PlaybackContextService.shared.setLocalContext(zoneID: zone.id, track: tracks[0], album: album)
            }
            let host = zone.host
            let zoneID = zone.id
            await Task.detached {
                await ZoneDiscoveryService.removeAllTracksFromQueue(host: host)
                await ZoneDiscoveryService.addMultipleURIsToQueue(host: host, uris: uris, didls: didls)
                let queueURI = "x-rincon-queue:\(zoneID)#0"
                await ZoneDiscoveryService.setAVTransportURIWithMetadata(host: host, streamURL: queueURI, didl: "")
                await ZoneDiscoveryService.sendTransportAction(host: host, action: "Play")
                sLog("LOCALPLAY: album started — 1 track in queue, \(tracks.count - 1) pending")
            }.value
        }
    }

    // MARK: - Track start notification — enqueue next track when current starts playing

    private func observeTrackStart() {
        NotificationCenter.default.addObserver(
            forName: SorrivaHTTPServer.trackDidStartNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let trackId = notification.userInfo?[SorrivaHTTPServer.trackIdKey] as? String else { return }
            Task { @MainActor in
                await self.handleTrackStart(trackId: trackId)
            }
        }
    }

    private func handleTrackStart(trackId: String) async {
        guard !queuedTracks.isEmpty, !activeZoneHost.isEmpty else { return }

        // Find which track just started
        guard let idx = queuedTracks.firstIndex(where: { $0.id == trackId }) else { return }
        currentQueueIndex = idx
        let advancedTrack = queuedTracks[idx]
        if let album = try? SorrivaDatabase.shared.album(id: advancedTrack.albumId) {
            PlaybackContextService.shared.setLocalContext(zoneID: activeZoneID, track: advancedTrack, album: album)
        }

        // Enqueue the next track — only if we haven't already enqueued it
        let nextToEnqueue = idx + 1
        guard nextToEnqueue < queuedTracks.count else {
            sLog("LOCALPLAY: track \(idx + 1)/\(queuedTracks.count) started — no more tracks to enqueue")
            return
        }

        // Prevent duplicate enqueuing
        guard nextToEnqueue > lastEnqueuedIndex else {
            sLog("LOCALPLAY: track \(idx + 1)/\(queuedTracks.count) started — track \(nextToEnqueue + 1) already enqueued")
            return
        }
        lastEnqueuedIndex = nextToEnqueue

        let track = queuedTracks[nextToEnqueue]
        guard let uri = SorrivaHTTPServer.shared.localURL(for: track.id, format: track.fileFormat) else {
            sLog("LOCALPLAY: could not build URI for \(track.title)")
            return
        }
        let didl = buildQueueDIDL(track: track, uri: uri)
        let host = activeZoneHost

        sLog("LOCALPLAY: track \(idx + 1)/\(queuedTracks.count) started — enqueuing \(track.title) (\(nextToEnqueue + 1)/\(queuedTracks.count))")

        await Task.detached {
            await ZoneDiscoveryService.addMultipleURIsToQueue(host: host, uris: [uri], didls: [didl])
        }.value
    }

    // MARK: - DIDL builder for queue (requires <res> element so Sonos knows track URI)

    private func buildQueueDIDL(track: Track, uri: String) -> String {
        let title = escapeXML(track.title)
        let artist = escapeXML(track.artistName)
        let album = escapeXML(track.albumTitle)
        let escapedURI = escapeXML(uri)
        let mime = mimeType(for: track.fileFormat)
        let protocolInfo = "http-get:*:\(mime):*"

        // Duration only if available — omitting is safer than sending 0:00:00
        let durationAttr = track.duration.map { " duration=&quot;\(formatDuration($0))&quot;" } ?? ""
        sLog("LOCALPLAY: DIDL — \(track.title) duration=\(track.duration.map { formatDuration($0) } ?? "nil")")

        return "&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;item id=&quot;-1&quot; parentID=&quot;-1&quot; restricted=&quot;true&quot;&gt;&lt;dc:title&gt;\(title)&lt;/dc:title&gt;&lt;dc:creator&gt;\(artist)&lt;/dc:creator&gt;&lt;upnp:album&gt;\(album)&lt;/upnp:album&gt;&lt;upnp:class&gt;object.item.audioItem.musicTrack&lt;/upnp:class&gt;&lt;res protocolInfo=&quot;\(protocolInfo)&quot;\(durationAttr)&gt;\(escapedURI)&lt;/res&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;"
    }

    private func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&",  with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<",  with: "&lt;")
            .replacingOccurrences(of: ">",  with: "&gt;")
            .replacingOccurrences(of: "'",  with: "&apos;")
    }

    private func mimeType(for fileFormat: String) -> String {
        switch fileFormat.lowercased() {
        case "flac":         return "audio/flac"
        case "mp3":          return "audio/mpeg"
        case "m4a", "aac",
             "alac":         return "audio/mp4"
        case "wav":          return "audio/wav"
        case "aiff", "aif":  return "audio/aiff"
        default:             return "application/octet-stream"
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }
}
