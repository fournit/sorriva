import Foundation

// MARK: - LocalPlaybackService
// Orchestrates local library → Sonos playback via SorrivaHTTPServer.
// Single track: SetAVTransportURI + Play (empty DIDL — Sonos plays to EOF).
// Multiple tracks: RemoveAllTracksFromQueue + AddMultipleURIsToQueue + play from queue.

@MainActor
final class LocalPlaybackService {

    static let shared = LocalPlaybackService()
    private init() {}

    func playTrack(_ track: Track, on zone: SonosZone) async {
        await playTracks([track], on: zone)
    }

    func playAlbum(_ tracks: [Track], on zone: SonosZone) async {
        await playTracks(tracks, on: zone)
    }

    private func playTracks(_ tracks: [Track], on zone: SonosZone) async {
        guard !tracks.isEmpty else { return }
        print("LOCALPLAY: playTracks — \(tracks.count) track(s) on \(zone.name)")

        // 1. Start HTTP server if not already running
        if !SorrivaHTTPServer.shared.isRunning {
            do {
                try SorrivaHTTPServer.shared.start()
            } catch {
                print("LOCALPLAY: HTTP server failed to start — \(error.localizedDescription)")
                return
            }
        }

        if tracks.count == 1 {
            // MARK: Single track — SetAVTransportURI + Play (empty DIDL, proven working)
            let track = tracks[0]
            guard let uri = SorrivaHTTPServer.shared.localURL(for: track.id, format: track.fileFormat) else {
                print("LOCALPLAY: could not construct URI — server not running or no WiFi")
                return
            }
            print("LOCALPLAY: single track — \(track.title) — \(uri)")
            let host = zone.host
            await Task.detached {
                await ZoneDiscoveryService.setAVTransportURIWithMetadata(host: host, streamURL: uri, didl: "")
                await ZoneDiscoveryService.sendTransportAction(host: host, action: "Play")
                print("LOCALPLAY: play command sent — \(track.title)")
            }.value

        } else {
            // MARK: Multi-track — build URI + DIDL list, enqueue all, play from queue
            var uris: [String] = []
            var didls: [String] = []
            for track in tracks {
                guard let uri = SorrivaHTTPServer.shared.localURL(for: track.id, format: track.fileFormat) else {
                    print("LOCALPLAY: skipping \(track.title) — could not construct URI")
                    continue
                }
                uris.append(uri)
                didls.append(buildQueueDIDL(track: track, uri: uri))
            }
            guard !uris.isEmpty else {
                print("LOCALPLAY: no valid URIs — aborting")
                return
            }

            print("LOCALPLAY: queueing \(uris.count) tracks on \(zone.name)")
            let host = zone.host
            let zoneID = zone.id
            await Task.detached {
                // Clear existing queue
                await ZoneDiscoveryService.removeAllTracksFromQueue(host: host)
                // Enqueue all tracks
                await ZoneDiscoveryService.addMultipleURIsToQueue(host: host, uris: uris, didls: didls)
                // Point transport at queue and play
                let queueURI = "x-rincon-queue:\(zoneID)#0"
                await ZoneDiscoveryService.setAVTransportURIWithMetadata(host: host, streamURL: queueURI, didl: "")
                await ZoneDiscoveryService.sendTransportAction(host: host, action: "Play")
                print("LOCALPLAY: album queue started — \(uris.count) tracks")
            }.value
        }
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
        print("LOCALPLAY: DIDL — \(track.title) duration=\(track.duration.map { formatDuration($0) } ?? "nil")")

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
