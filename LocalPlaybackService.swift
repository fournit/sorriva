import Foundation

// MARK: - LocalPlaybackService
// Orchestrates local library → Sonos playback via SorrivaHTTPServer.
// Starts the HTTP server if not running, constructs the track URI,
// builds DIDL-Lite metadata, and fires SetAVTransportURI + Play.
//
// Usage:
//   await LocalPlaybackService.shared.playTrack(track, on: zone)

@MainActor
final class LocalPlaybackService {

    static let shared = LocalPlaybackService()
    private init() {}

    // MARK: - Play a single track

    func playTrack(_ track: Track, on zone: SonosZone) async {
        print("LOCALPLAY: playTrack entered — \(track.title) on \(zone.name)")

        // 1. Start HTTP server if not already running
        if !SorrivaHTTPServer.shared.isRunning {
            do {
                try SorrivaHTTPServer.shared.start()
            } catch {
                print("LOCALPLAY: HTTP server failed to start — \(error.localizedDescription)")
                return
            }
        }

        // 2. Construct HTTP URI for this track — include file extension for Sonos MIME type detection
        guard let uri = SorrivaHTTPServer.shared.localURL(for: track.id, format: track.fileFormat) else {
            print("LOCALPLAY: could not construct URI — server not running or no WiFi")
            return
        }

        print("LOCALPLAY: playing \(track.title) on \(zone.name) — \(uri)")
        print("LOCALPLAY: zone host — \(zone.host)")

        // 3. Build DIDL-Lite metadata
        let metadata = buildDIDL(track: track)
        let host = zone.host

        // 4. Fire SOAP calls on a detached task — avoids main actor deadlock
        await Task.detached {
            print("LOCALPLAY: calling setAVTransportURIWithMetadata...")
            print("LOCALPLAY: URI = \(uri)")
            await ZoneDiscoveryService.setAVTransportURIWithMetadata(
                host: host,
                streamURL: uri,
                didl: metadata
            )
            print("LOCALPLAY: setAVTransportURIWithMetadata returned — calling Play...")
            await ZoneDiscoveryService.sendTransportAction(host: host, action: "Play")
            print("LOCALPLAY: play command sent")
        }.value
    }

    // MARK: - DIDL-Lite builder

    private func buildDIDL(track: Track) -> String {
        let title = escape(track.title)
        let artist = escape(track.artistName)
        let album = escape(track.albumTitle)

        // Duration: stored as seconds in DB — convert to HH:MM:SS for DIDL
        let duration = track.duration.map { formatDuration($0) } ?? "0:00:00"

        return """
        &lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; \
        xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; \
        xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;\
        &lt;item id=&quot;-1&quot; parentID=&quot;-1&quot; restricted=&quot;true&quot;&gt;\
        &lt;dc:title&gt;\(title)&lt;/dc:title&gt;\
        &lt;dc:creator&gt;\(artist)&lt;/dc:creator&gt;\
        &lt;upnp:album&gt;\(album)&lt;/upnp:album&gt;\
        &lt;upnp:duration&gt;\(duration)&lt;/upnp:duration&gt;\
        &lt;upnp:class&gt;object.item.audioItem.musicTrack&lt;/upnp:class&gt;\
        &lt;/item&gt;&lt;/DIDL-Lite&gt;
        """
    }

    private func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&",  with: "&amp;amp;")
            .replacingOccurrences(of: "\"", with: "&amp;quot;")
            .replacingOccurrences(of: "<",  with: "&amp;lt;")
            .replacingOccurrences(of: ">",  with: "&amp;gt;")
            .replacingOccurrences(of: "'",  with: "&amp;apos;")
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }
}
