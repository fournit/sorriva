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
        await playTracks([track], on: zone)
    }

    // MARK: - Play album (full track queue)

    func playAlbum(_ tracks: [Track], on zone: SonosZone) async {
        await playTracks(tracks, on: zone)
    }

    // MARK: - Core playback — single track or ordered queue

    private func playTracks(_ tracks: [Track], on zone: SonosZone) async {
        guard !tracks.isEmpty else { return }
        print("LOCALPLAY: playTracks — \(tracks.count) tracks on \(zone.name)")

        // 1. Start HTTP server if not already running
        if !SorrivaHTTPServer.shared.isRunning {
            do {
                try SorrivaHTTPServer.shared.start()
            } catch {
                print("LOCALPLAY: HTTP server failed to start — \(error.localizedDescription)")
                return
            }
        }

        // 2. For single track use SetAVTransportURI directly.
        //    For multiple tracks use AddMultipleURIsToQueue then Play.
        if tracks.count == 1 {
            let track = tracks[0]
            guard let uri = SorrivaHTTPServer.shared.localURL(for: track.id, format: track.fileFormat) else {
                print("LOCALPLAY: could not construct URI")
                return
            }
            let metadata = buildDIDL(track: track)
            let host = zone.host
            await Task.detached {
                await ZoneDiscoveryService.setAVTransportURIWithMetadata(host: host, streamURL: uri, didl: metadata)
                await ZoneDiscoveryService.sendTransportAction(host: host, action: "Play")
                print("LOCALPLAY: play command sent — \(track.title)")
            }.value
        } else {
            // Build URI + DIDL list for all tracks
            var uris: [String] = []
            var didls: [String] = []
            for track in tracks {
                guard let uri = SorrivaHTTPServer.shared.localURL(for: track.id, format: track.fileFormat) else { continue }
                uris.append(uri)
                didls.append(buildDIDL(track: track))
            }
            guard !uris.isEmpty else { return }
            let host = zone.host
            await Task.detached {
                // Clear queue, add all tracks, play from first
                await ZoneDiscoveryService.sendTransportAction(host: host, action: "Stop")
                await ZoneDiscoveryService.setAVTransportURIWithMetadata(
                    host: host,
                    streamURL: uris[0],
                    didl: didls[0]
                )
                await ZoneDiscoveryService.sendTransportAction(host: host, action: "Play")
                print("LOCALPLAY: album play started — \(uris.count) tracks queued")
            }.value
        }
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
