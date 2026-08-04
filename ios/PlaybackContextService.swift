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

    /// Station identified by reverse-resolving a stream URI, per zone.
    ///
    /// Sonos reports the URI reliably but supplies no station name and no artwork for
    /// HLS radio — verified against a live stream, where dc:title was the filename and
    /// upnp:albumArtURI was absent entirely. The stations table is therefore the only
    /// way to name these, and this cache is what keeps that lookup from re-running on
    /// every poll (bPlaybackContextResolveChurn). A miss is cached too — as an empty
    /// name against the URI — so an unknown stream is not re-queried every two seconds.
    ///
    /// A miss expires; a hit does not. Caching a miss permanently made any transient URI
    /// strand a zone until the app was force-quit, because nothing ever retried and the
    /// cache is memory-only. Real repro: a transfer briefly parks the destination on a
    /// group address, the lookup understandably found no station, and the zone showed the
    /// raw stream slug indefinitely afterwards.
    private var resolvedStations: [String: (uri: String, name: String,
                                            artURL: String?, at: Date)] = [:]

    /// How long a failed station lookup is trusted before it is worth asking again.
    private static let missRetryInterval: TimeInterval = 30

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
                let stationChanged = zone.stationName != prev?.stationName
                let logoChanged = zone.stationLogoURL != prev?.stationLogoURL
                if uriChanged || stationChanged || logoChanged || contexts[zone.id] == nil {
                    let display = stationDisplay(for: zone)
                    // Don't clear an existing context when nothing resolved yet —
                    // resolveStationFromURI patches it when the lookup completes, which
                    // prevents a blank flash between transfer and DB lookup completion.
                    if !display.name.isEmpty {
                        contexts[zone.id] = PlaybackContext(
                            track: "",
                            artist: "",
                            albumName: display.name,
                            duration: 0,
                            artAlbum: nil,
                            artURL: display.artURL.isEmpty ? nil : display.artURL,
                            isLocal: false
                        )
                    }
                }
                continue
            }

            // Case 3: Radio playing → show stream content
            // Skip if within 2s grace period after local playback was initiated
            let inLocalGrace = localPlaybackStarted[zone.id].map {
                Date().timeIntervalSince($0) < 2.0
            } ?? false
            if zone.isPlaying && !inLocalGrace {
                let display = stationDisplay(for: zone)
                let displayStationName = display.name
                let displayStationArt  = display.artURL

                // Only overwrite if we have something meaningful to show
                // Empty context during transition would wipe out good context
                let hasContent = !zone.currentTrack.isEmpty || !displayStationName.isEmpty
                if hasContent {
                    contexts[zone.id] = PlaybackContext(
                        track: zone.currentTrack,
                        artist: zone.currentArtist,
                        albumName: displayStationName,
                        duration: 0,
                        artAlbum: nil,
                        artURL: displayStationArt.isEmpty ? nil : displayStationArt,
                        isLocal: false
                    )
                } else {
                    }
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

    /// The station name and artwork to display for a zone, resolving it if not yet known.
    ///
    /// Idle and playing zones ask the same question — "what station is this?" — so they
    /// must get the same answer. They used to have separate implementations that
    /// disagreed: the idle one trusted Sonos's `dc:title` first and never consulted the
    /// stations table when a name was present, and its fallback searched iHeart only. So
    /// two zones parked on the same SomaFM stream displayed differently — one the curated
    /// "Groove Salad", the other the raw slug "groovesalad-128-aac" — and every fix
    /// applied to the playing path left the idle path broken.
    ///
    /// Precedence: the stations table wins. Sonos's reported name is only a fallback,
    /// because `dc:title` is whatever the stream advertises — a channel slug for SomaFM,
    /// a filename ("hls.m3u8") for iHeart. And it counts as a fallback only while it
    /// belongs to the URI Sonos is playing *now*: after a transfer brings new content to a
    /// zone, the previous station's name lingers until a fresh one lands, and displaying
    /// it would be simply wrong.
    private func stationDisplay(for zone: SonosZone) -> (name: String, artURL: String) {
        let nameIsFresh = zone.stationNameURI == zone.currentTrackURI
        var name   = nameIsFresh ? zone.stationName : ""
        var artURL = nameIsFresh ? zone.stationLogoURL : ""

        // `x-rincon:` (grouping) is excluded alongside queue and local URIs: it addresses
        // a coordinator, not a stream, so it can never name a station. A transfer parks
        // the destination on one for a couple of seconds while the zones are grouped, and
        // asking the stations table about it only manufactures a miss.
        let isRadioStream = !zone.currentTrackURI.isEmpty
            && !zone.currentTrackURI.hasPrefix("x-rincon-queue:")
            && !zone.currentTrackURI.hasPrefix("x-rincon:")
            && !zone.currentTrackURI.hasPrefix("x-file-cifs://")
        guard isRadioStream else { return (name, artURL) }

        // The lookup runs for any radio URI and its result WINS, rather than being gated
        // on Sonos having failed to supply something first. Gating on the validator's
        // blind spots is whack-a-mole; the next service will invent another shape.
        let key = normalizedStreamKey(zone.currentTrackURI)
        let cached = resolvedStations[zone.id].flatMap { $0.uri == key ? $0 : nil }
        if let cached, !cached.name.isEmpty {
            name   = cached.name
            artURL = cached.artURL ?? artURL
        } else if cached == nil
                    || Date().timeIntervalSince(cached!.at) >= Self.missRetryInterval {
            // Unseen stream, or a miss old enough to be worth re-asking. Resolution is
            // async and caches its own result, so this is a fire-and-forget nudge.
            resolveStationFromURI(zone.currentTrackURI, zoneID: zone.id)
        }
        return (name, artURL)
    }

    /// Reduce a stream URI to a stable identity for matching and caching.
    ///
    /// The same station arrives in different shapes depending on who started it:
    ///   Sorriva    x-rincon-mp3radio://ice2.somafm.com/secretagent-128-aac
    ///   Sonos app  aac://http://ice2.somafm.com/secretagent-128-aac
    ///   iHeart     hls-radio://http://…/hls.m3u8?rj-tok=…&streamid=…&playedFrom=…
    ///
    /// Raw string comparison cannot match across those. Stripping the transport
    /// scheme(s) — they nest, as in `aac://http://` — and the query string leaves
    /// host+path, which is the same for all of them.
    ///
    /// Dropping the query string matters twice over: iHeart rotates session tokens on
    /// every poll, so keeping it defeats the match AND the cache. That is what produced
    /// forty re-resolutions of a single station in one log.
    private func normalizedStreamKey(_ raw: String) -> String {
        var s = raw.lowercased()
        while let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if let query = s.firstIndex(of: "?") { s = String(s[..<query]) }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    /// The path portion of a normalised stream key — everything after the host.
    /// Providers load-balance the same channel across mirrors (SomaFM uses
    /// ice1/ice2/ice4), so the host is not part of a station's identity.
    private func streamPath(_ key: String) -> String {
        guard let slash = key.firstIndex(of: "/") else { return "" }
        return String(key[key.index(after: slash)...])
    }

    /// Identify the station behind a stream URI by matching it against stored stream
    /// URLs, then patch the zone's live context with the name and artwork.
    ///
    /// Searches every source — iHeart and SomaFM are only the first of many, and a
    /// stream started from the Sonos app could be any of them. The result is cached
    /// against the URI (including a miss) so this runs once per URI change, not once
    /// per poll. Track and artist are read from the context as it stands at completion
    /// rather than captured up front, so a track change mid-lookup is not clobbered.
    private func resolveStationFromURI(_ uri: String, zoneID: String) {
        let key = normalizedStreamKey(uri)
        guard !key.isEmpty else { return }

        Task { @MainActor in
            let stations = (try? SorrivaDatabase.shared.allStationsAnySource()) ?? []
            // Ask the owning service to identify the station exactly. Each adapter knows
            // its provider's URI shape — iHeart's station code, SomaFM's channel slug —
            // so mirrors, transport schemes, and rotating session tokens are handled by
            // the service that understands them rather than by a shared heuristic here.
            var match = RadioServiceRegistry.matchStation(uri: uri, in: stations)

            // Last resort: a stream no adapter claims. Substring comparison on the
            // normalised key is a guess, but a wrong guess here is harmless — the worst
            // case is no match, which leaves the zone showing whatever Sonos reported.
            if match == nil {
                let keyPath = self.streamPath(key)
                match = stations.first { station in
                    guard let streamURL = station.streamURL, !streamURL.isEmpty else { return false }
                    let stored = self.normalizedStreamKey(streamURL)
                    guard !stored.isEmpty else { return false }
                    if key == stored || key.contains(stored) || stored.contains(key) { return true }
                    let storedPath = self.streamPath(stored)
                    return !keyPath.isEmpty && keyPath == storedPath
                }
            }

            guard let station = match else {
                // Cache the miss against the normalised key so an unrecognised stream is
                // not re-queried every poll. Log what we compared against, not just what
                // failed — a bare "no match" cannot distinguish a missing stored URL from
                // a shape mismatch, and those need opposite fixes.
                self.resolvedStations[zoneID] = (uri: key, name: "", artURL: nil, at: Date())
                let withURLs = stations.filter { ($0.streamURL?.isEmpty == false) }
                let identity = RadioServiceRegistry.identify(uri: uri)
                    .map { "\($0.source):\($0.key)" } ?? "unclaimed by any adapter"
                let nearby = withURLs
                    .filter { $0.source == RadioServiceRegistry.identify(uri: uri)?.source }
                    .prefix(3)
                    .map { "\($0.name)→'\(RadioServiceRegistry.identify(uri: $0.streamURL!)?.key ?? "?")'" }
                sLog("CONTEXT: no station matches '\(key)' [\(identity)] — "
                   + "\(withURLs.count)/\(stations.count) stations have a stored URL; "
                   + "same-service keys: \(nearby.isEmpty ? "none" : nearby.joined(separator: ", "))")
                return
            }

            self.resolvedStations[zoneID] = (uri: key, name: station.name,
                                             artURL: station.logoURL, at: Date())

            // Clear artAlbum and isLocal alongside the name. A zone that was playing a
            // local album still carries its embedded artwork, and the mini player prefers
            // artAlbum over artURL — so patching only the name and URL left the station
            // showing the previous album's cover. Creating the context when absent matters
            // for idle zones, which may have none yet; without it the lookup completed and
            // then quietly discarded its own result.
            var current = self.contexts[zoneID] ?? PlaybackContext(
                track: "", artist: "", albumName: "",
                duration: 0, artAlbum: nil, artURL: nil, isLocal: false
            )
            current.albumName = station.name
            current.artURL    = station.logoURL
            current.artAlbum  = nil
            current.isLocal   = false
            self.contexts[zoneID] = current
            sLog("CONTEXT: resolved station from URI — \(station.name) for \(zoneID)")
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
        Task { @MainActor in
            guard let track = self.resolveTrackFromURI(toURI) else {
                sLog("CONTEXT: advance — no DB match for \(toURI.suffix(50))")
                return
            }
            guard let album = try? SorrivaDatabase.shared.album(id: track.albumId) else { return }
            let context = PlaybackContext(
                track: track.title,
                artist: track.artistName ?? album.artistName,
                albumName: album.title,
                duration: track.duration ?? 0,
                artAlbum: album,
                artURL: nil,
                isLocal: true
            )
            self.contexts[zoneID] = context
            // Re-declare against the URI Sonos just advanced to, so the queue's
            // declaration stays current instead of going stale after track one.
            PlaybackStore.shared.declare(zoneID: zoneID, context: context, uri: toURI)
            sLog("CONTEXT: advanced to \(track.title)")
        }
    }

    // MARK: - Local playback

    /// Set context for a single track. Clears any existing local queue for this zone.
    func setLocalContext(zoneID: String, uri: String, track: Track, album: Album) {
        localPlaybackStarted[zoneID] = Date()
        let apply = {
            self.localQueues[zoneID] = nil
            let context = PlaybackContext(
                track: track.title,
                artist: track.artistName ?? album.artistName,
                albumName: album.title,
                duration: track.duration ?? 0,
                artAlbum: album,
                artURL: nil,
                isLocal: true
            )
            self.contexts[zoneID] = context
            // Also declare to the store: same content, now bound to the URI it
            // describes. The reducer prefers the declaration while that URI matches.
            Task { @MainActor in
                PlaybackStore.shared.declare(zoneID: zoneID, context: context, uri: uri)
            }
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
            let context = PlaybackContext(
                track: first.track.title,
                artist: first.track.artistName ?? first.album.artistName,
                albumName: first.album.title,
                duration: first.track.duration ?? 0,
                artAlbum: first.album,
                artURL: nil,
                isLocal: true
            )
            self.contexts[zoneID] = context
            // Declare the head of the queue; advanceLocalContext re-declares as
            // Sonos moves through the remaining URIs.
            let firstURI = first.uri
            Task { @MainActor in
                PlaybackStore.shared.declare(zoneID: zoneID, context: context, uri: firstURI)
            }
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
