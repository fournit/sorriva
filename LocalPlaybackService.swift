import Foundation

// MARK: - LocalPlaybackService (working version — v0.0.21)
// This is the version that successfully played a full 9-minute FLAC track
// on Sonos Living Room (192.168.1.219) from UNAS Pro via iPhone HTTP server.
// Track: Never Let Me Down Again [Split Mix] — 73MB FLAC

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
        guard let track = tracks.first else { return }
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

        // 2. Construct HTTP URI — file extension required for Sonos MIME type (error 714 fix)
        guard let uri = SorrivaHTTPServer.shared.localURL(for: track.id, format: track.fileFormat) else {
            print("LOCALPLAY: could not construct URI — server not running or no WiFi")
            return
        }

        print("LOCALPLAY: playing \(track.title) on \(zone.name) — \(uri)")
        print("LOCALPLAY: zone host — \(zone.host)")

        // 3. Build DIDL-Lite metadata
        let metadata = buildDIDL(track: track)
        let host = zone.host

        // 4. Fire SOAP calls on detached task — avoids main actor deadlock
        await Task.detached {
            print("LOCALPLAY: calling setAVTransportURIWithMetadata...")
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
        let duration = track.duration.map { formatDuration($0) } ?? "0:00:00"

        return "&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;item id=&quot;-1&quot; parentID=&quot;-1&quot; restricted=&quot;true&quot;&gt;&lt;dc:title&gt;\(title)&lt;/dc:title&gt;&lt;dc:creator&gt;\(artist)&lt;/dc:creator&gt;&lt;upnp:album&gt;\(album)&lt;/upnp:album&gt;&lt;upnp:duration&gt;\(duration)&lt;/upnp:duration&gt;&lt;upnp:class&gt;object.item.audioItem.musicTrack&lt;/upnp:class&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;"
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
