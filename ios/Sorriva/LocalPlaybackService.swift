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

    /// WP-14 S-007: Reset share registration cache.
    /// Called when Sonos coordinator changes or network is restored.
    /// Forces re-registration on next playback attempt.
    func resetShareRegistrations() {
        registeredShares = [:]
        sLog("LOCALPLAY: share registration cache cleared")
    }

    /// WP-14 S-007: Reset registrations for a specific coordinator host.
    /// Called when a specific zone's coordinator changes.
    func resetShareRegistrations(forHost host: String) {
        for key in registeredShares.keys {
            registeredShares[key]?.remove(host)
        }
        sLog("LOCALPLAY: share registration cleared for \(host)")
    }

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
            guard let source = (try? SorrivaDatabase.shared.allLibrarySources())?.first(where: { $0.id == track.sourceId }) else {
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
        // Set grace period before play — prevents zone card going inactive during switch
        NotificationCenter.default.post(name: .sorrivaSetPlaybackGrace,
            object: nil, userInfo: ["zoneID": zone.id])
        sLog("LOCALPLAY: URI — \(uri)")

        if let album = try? SorrivaDatabase.shared.album(id: track.albumId) {
            PlaybackContextService.shared.setLocalContext(zoneID: zone.id, uri: uri, track: track, album: album)
        }

        let host = zone.host
        let zoneID = zone.id
        let title = track.title
        await Task.detached {
            // A single track is queued exactly like an album — there is no direct path.
            //
            // Pointing SetAVTransportURI at an x-file-cifs:// file returns 200 and then
            // silently fails on some speakers: the transport never leaves STOPPED and the
            // following Play returns either 200-with-nothing or 500 errorCode=701. Whether
            // it works varies by speaker AND over time on the same speaker, which is why it
            // read as a wedged transport, a share problem, and a code regression before it
            // was measured. Verified 2026-08-05 on a speaker that had refused every direct
            // attempt for hours: a one-track queue played immediately.
            //
            // This is also what makes TRANSFER reliable — a destination inherits whatever
            // the transport holds, and a bare file URI travels badly.
            //
            // See engineering/sonos-playback-contract.md §3 — the authority for this.
            await SonosCommands.sendTransportAction(host: host, action: "Stop")
            await SonosCommands.removeAllTracksFromQueue(host: host)
            await SonosCommands.addURIToQueue(host: host, uri: uri)
            let queueURI = "x-rincon-queue:\(zoneID)#0"
            await SonosCommands.setAVTransportURIWithMetadata(host: host, streamURL: queueURI, didl: "")
            await SonosCommands.sendTransportAction(host: host, action: "Play")
            sLog("LOCALPLAY: single-track queue started — \(title)")
        }.value
        // Re-declare transport optimism now that the command has actually gone out.
        //
        // The window opened when playback was requested, before the queue was built — and
        // queueing is one AddURIToQueue call per track, so the time consumed scales with
        // queue length. Measured across 80 real playback starts: 10 tracks took 1.3s, 15
        // took 3.0s, 100 took 4.70s against a 5s window. At ~47ms per track the window is
        // exhausted somewhere past 100 tracks, after which the zone renders whatever Sonos
        // reports mid-start — a phantom pause, the same defect fixed in transferPlayback.
        //
        // Re-declaring here makes the window independent of queue size rather than merely
        // buying headroom: it starts when the command is issued, whether the queue held 3
        // tracks or 300. That matters before queue management lands and makes queue length
        // user-controlled and unbounded.
        PlaybackStore.shared.declareTransport(zoneID: zoneID, playing: true)
        // Fire-and-forget: confirm Sonos actually started rather than trusting the 200.
        Task.detached { await SonosCommands.verifyPlaybackStarted(host: host, context: title) }
    }

    // MARK: - Album queue

    private func playQueue(_ pairs: [(Track, LibrarySource)], on zone: SonosZone) async {
        sLog("LOCALPLAY: queueing \(pairs.count) tracks on \(zone.name)")
        // Set grace period before queue build — prevents zone card going inactive during switch
        NotificationCenter.default.post(name: .sorrivaSetPlaybackGrace,
            object: nil, userInfo: ["zoneID": zone.id])

        // Register full queue for context advancement
        var contextItems: [(uri: String, track: Track, album: Album)] = []
        for (track, source) in pairs {
            let uri = xFileCIFSURI(track: track, source: source)
            if let album = try? SorrivaDatabase.shared.album(id: track.albumId) {
                contextItems.append((uri: uri, track: track, album: album))
            }
        }
        PlaybackContextService.shared.setLocalQueue(zoneID: zone.id, items: contextItems)

        let host = zone.host
        let zoneID = zone.id
        let uris = pairs.map { xFileCIFSURI(track: $0.0, source: $0.1) }

        await Task.detached {
            // Stop first — see playSingleTrack: clearing the queue does not reset a
            // wedged transport, and a wedged zone 200s every command that follows.
            await SonosCommands.sendTransportAction(host: host, action: "Stop")
            // Clear existing queue first
            await SonosCommands.removeAllTracksFromQueue(host: host)

            // AddURIToQueue in loop — x-file-cifs requires single-track calls
            // No DIDL needed — Sonos reads metadata directly from the file
            for (idx, uri) in uris.enumerated() {
                await SonosCommands.addURIToQueue(host: host, uri: uri)
                sLog("LOCALPLAY: queued track \(idx + 1)/\(uris.count)")
            }

            // Point transport at queue and play
            let queueURI = "x-rincon-queue:\(zoneID)#0"
            await SonosCommands.setAVTransportURIWithMetadata(host: host, streamURL: queueURI, didl: "")
            await SonosCommands.sendTransportAction(host: host, action: "Play")
            sLog("LOCALPLAY: album queue started — \(uris.count) tracks")
        }.value
        // Re-declare transport optimism now that the command has actually gone out.
        //
        // The window opened when playback was requested, before the queue was built — and
        // queueing is one AddURIToQueue call per track, so the time consumed scales with
        // queue length. Measured across 80 real playback starts: 10 tracks took 1.3s, 15
        // took 3.0s, 100 took 4.70s against a 5s window. At ~47ms per track the window is
        // exhausted somewhere past 100 tracks, after which the zone renders whatever Sonos
        // reports mid-start — a phantom pause, the same defect fixed in transferPlayback.
        //
        // Re-declaring here makes the window independent of queue size rather than merely
        // buying headroom: it starts when the command is issued, whether the queue held 3
        // tracks or 300. That matters before queue management lands and makes queue length
        // user-controlled and unbounded.
        PlaybackStore.shared.declareTransport(zoneID: zoneID, playing: true)
        // Fire-and-forget: confirm Sonos actually started rather than trusting the 200.
        let queueLabel = "album queue (\(uris.count) tracks)"
        Task.detached { await SonosCommands.verifyPlaybackStarted(host: host, context: queueLabel) }
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
            // Sonos-facing host, not the phone-facing one — see SourceResolver.sonosHost.
            let nasPath = SourceResolver.sonosNASPath(for: source)
            sLog("LOCALPLAY: registering NAS share — \(nasPath) on \(coordinatorHost)")
            let driver = SonosEndpointDriver.shared
            do {
                try await driver.createObject(host: coordinatorHost, nasPath: nasPath)
                registered.insert(coordinatorHost)
                registeredShares[shareKey] = registered
            } catch {
                sLog("LOCALPLAY: share registration failed \(nasPath): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - URI construction
    // SMB path construction is confined to SourceResolver (WP-13).
    // LocalPlaybackService delegates to SourceResolver.xFileCIFSLocator.

    private func xFileCIFSURI(track: Track, source: LibrarySource) -> String {
        SourceResolver.xFileCIFSLocator(track: track, source: source)
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
