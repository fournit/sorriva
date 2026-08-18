import Foundation

// MARK: - SonosFavorites
//
// Reading the household's saved favorites off a speaker, over plain UPnP.
//
// WHY THIS EXISTS. SiriusXM publishes no third-party streaming access, and Spotify's
// Web API needs an approved business case rather than a registration — neither is
// reachable by a personal project. Their favorites are, because Sorriva never
// authenticates to anything: the credential lives in the speaker, put there by the
// Sonos app, and Sorriva only hands the speaker a reference to content the household
// already has rights to. See sonos-playback-contract.md §11 and fSonosFavoritesAsSource.
//
// STORE WHAT IS READ, VERBATIM. Measured 2026-08-11 as an A/B across two households:
// the account handle inside a favorite (`sn`, `flags`, the token) is NOT enforced — a
// favorite captured at one house played unchanged on the other, because the speaker
// resolves the service through its own linkage. So there is no reconstruction here and
// no per-household profile. `uri` and `metadata` go back to the speaker exactly as they
// arrived.
//
// PARSING IS SEPARATE FROM FETCHING on purpose. `parse` is pure and has tests against a
// real captured response; `fetch` is the thin part that talks to a speaker.

/// What kind of thing a favorite is.
///
/// Sonos distinguishes these and Sorriva did not, so an album, a playlist and a radio
/// channel were all "stations". The distinction is not cosmetic — an album has a fixed
/// order and an end, a playlist is a set, a broadcast never finishes — but only the
/// NAMING of it lands here. Behaviour that follows from the kind belongs with the queue
/// work (fPlaybackConductor), not bolted on ahead of it.
///
/// Measured across 47 favorites on 2026-08-17:
///   object.container.playlistContainer   → playlist   (Italo Disco, 80s Party)
///   object.container.album.musicAlbum    → album      (Getz/Gilberto)
///   object.item.audioItem.audioBroadcast → broadcast  (SiriusXM channels)
enum StationKind: String, CaseIterable {
    case album
    case playlist
    case broadcast
    /// A shape nobody has taught us about. Deliberately not guessed at — an unknown kind
    /// displays as it always did rather than being asserted into the wrong group.
    case unknown

    /// Sonos's `upnp:class` reduced to a kind. Matched on the meaningful SEGMENT rather
    /// than the whole string: the classes nest (`object.container.album.musicAlbum`) and
    /// providers append their own suffixes.
    static func fromUPnPClass(_ raw: String) -> StationKind {
        let s = raw.lowercased()
        if s.contains("album") { return .album }
        if s.contains("playlistcontainer") || s.contains("playlist") { return .playlist }
        if s.contains("audiobroadcast") || s.contains("broadcast") { return .broadcast }
        return .unknown
    }

    /// Shown beside the service name. Empty for a broadcast — "SiriusXM · Broadcast"
    /// tells the reader nothing they cannot see, where "Spotify · Album" does.
    var label: String {
        switch self {
        case .album:     return "Album"
        case .playlist:  return "Playlist"
        case .broadcast, .unknown: return ""
        }
    }
}

struct SonosFavorite: Equatable {
    /// What the user named it in the Sonos app — "CH 8 - 80s on 8".
    let title: String
    /// `<res>`, handed to SetAVTransportURI unchanged.
    let uri: String
    /// `<r:resMD>`, handed over as CurrentURIMetaData unchanged. Carries the service
    /// token; without it the URI will not play.
    let metadata: String
    /// The service's own artwork for this item. Sonos supplies none at playback time,
    /// so this is usually the only image available.
    let artURL: String?
    /// `<r:description>` — "SiriusXM", "Sonos Radio". What the user sees, and what a
    /// new `services` row is named after.
    let serviceName: String
    /// Sonos's own service number, parsed from `sid=` in the URI. The reliable key for
    /// matching a favorite to a service row; nil for favorites that carry no `sid`.
    let sonosServiceId: Int?
    /// Album, playlist or endless broadcast — read from `upnp:class`. See StationKind.
    let kind: StationKind
}

enum SonosFavorites {

    /// ObjectID for the household's saved favorites.
    static let favoritesObjectID = "FV:2"

    // MARK: - Parsing

    /// Browse response in, playable favorites out.
    ///
    /// NOT EVERY FAVORITE IS PLAYABLE, and this is the filter that matters. "Discover
    /// Sonos Radio", "Sonos Presents" and "Trending Now" are browse shortcuts into a
    /// service, not items — they carry no `<res>` at all. Offering them and failing at
    /// play time would be the same broken promise as a play button on a dead transport.
    /// They are dropped here rather than downstream.
    static func parse(_ data: Data) -> [SonosFavorite] {
        guard let envelope = String(data: data, encoding: .utf8) else { return [] }
        // The DIDL payload arrives entity-encoded inside <Result>.
        guard let inner = tag("Result", in: envelope)?.decodingXMLEntities else { return [] }

        var out: [SonosFavorite] = []
        // Split on the item boundary rather than matching <item>…</item>: resMD
        // contains a NESTED <item>, so a non-greedy match ends at the wrong place.
        // That bug cost twenty minutes on 2026-08-10 and produced "metadata: none" for
        // an item that plainly had it.
        for chunk in inner.components(separatedBy: "<item id=\"FV:2/").dropFirst() {
            guard let title = tag("dc:title", in: chunk) else { continue }
            guard let res = tag("res", in: chunk, attributed: true), !res.isEmpty else { continue }
            let md = tag("r:resMD", in: chunk) ?? ""
            // READ FROM THE DECODED resMD, not from the chunk. Every favorite carries an
            // OUTER `<upnp:class>object.item.sonos-favorite`, which is literal text and
            // classifies nothing; the class saying what the favorite POINTS AT lives in
            // the nested resMD and is entity-encoded, so a literal search over the chunk
            // finds only the useless one. Decoding first is what makes the inner class
            // reachable at all.
            let decodedMD = md.decodingXMLEntities
            let kind = lastTag("upnp:class", in: decodedMD)
                .map { StationKind.fromUPnPClass($0) } ?? .unknown
            out.append(SonosFavorite(
                title: title.decodingXMLEntities,
                uri: res.decodingXMLEntities,
                metadata: md.decodingXMLEntities,
                artURL: tag("upnp:albumArtURI", in: chunk)?.decodingXMLEntities,
                serviceName: (tag("r:description", in: chunk) ?? "Sonos").decodingXMLEntities,
                sonosServiceId: sonosServiceId(from: res),
                kind: kind))
        }
        return out
    }

    /// The channel this favorite points at, independent of which household saved it.
    ///
    /// Everything before the `?` was byte-identical across two Sonos systems — measured
    /// 2026-08-11 on `CH 15 - Yacht Rock Radio`, where the same
    /// `channel-linear:9150cc82-…` carried `?sid=37&sn=4` at one house and
    /// `?sid=37&flags=8260&sn=3` at the other. The query string is the ACCOUNT HANDLE,
    /// and the handle is ignored by the speaker.
    ///
    /// So this is the library's identity for a station: match on it and the same channel
    /// saved in two houses is one row, not two that differ only in a number that does
    /// not matter. The full URI is still what gets played.
    static func channelIdentity(of uri: String) -> String {
        guard let q = uri.firstIndex(of: "?") else { return uri }
        return String(uri[uri.startIndex..<q])
    }

    /// The station name with SiriusXM's channel number removed.
    ///
    /// "CH 33 - 1st Wave" → "1st Wave". The number is Sonos's addition, not part of the
    /// station: the same channel started by Alexa reports plainly "Classic Rewind", and
    /// SiriusXM's own metadata carries no number either. Measured 2026-08-17 across a
    /// favorite-started and an Alexa-started zone. Tom's call — no channel numbers in the
    /// library or on screen.
    ///
    /// Applied wherever a favorite's title is STORED or DISPLAYED, so the two cannot
    /// disagree; the setup screen builds its rows from live favorites rather than from
    /// the library, so stripping in only one place would show the same station under two
    /// names on two screens.
    ///
    /// TEXT ONLY. The URI carries no number, and the metadata blob is passed back to
    /// Sonos byte for byte because it holds the service token — rewriting it is how a
    /// speaker comes to return 200 and play silence.
    ///
    /// Deliberately narrow: "CH" or "CH." followed by digits and a separator. A name that
    /// merely begins with letters and digits — "Channel 5", "CH2 Radio" — is untouched.
    static func displayTitle(_ title: String, serviceId: String) -> String {
        guard serviceId == "siriusxm" else { return title }
        let pattern = "^ch\\.?\\s*[0-9]+\\s*[-–—]\\s*"
        guard let r = title.range(of: pattern, options: [.regularExpression, .caseInsensitive])
        else { return title }
        let stripped = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? title : stripped
    }

    /// `sid=37` out of `x-sonosapi-stream:channel-linear%3A…?sid=37&flags=8260&sn=3`.
    /// Absent on some favorites, which is why it is optional rather than defaulted.
    static func sonosServiceId(from uri: String) -> Int? {
        guard let r = uri.range(of: "sid=") else { return nil }
        let digits = uri[r.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    // MARK: - Fetching

    /// Read the favorites from one speaker.
    ///
    /// NOT EVERY SPEAKER ANSWERS. Measured 2026-08-10: one zone returned 500 to every
    /// ContentDirectory action while others on the same household answered normally,
    /// and its device description omits services that demonstrably work. Callers should
    /// try another speaker rather than concluding the household has no favorites — that
    /// wrong conclusion nearly ended the feature.
    static func fetch(host: String) async throws -> [SonosFavorite] {
        let reply = try await SonosCommands.soap.send(
            host: host,
            service: .contentDirectory,
            action: "Browse",
            innerXML: """
                  <ObjectID>\(favoritesObjectID)</ObjectID>
                  <BrowseFlag>BrowseDirectChildren</BrowseFlag>
                  <Filter>*</Filter>
                  <StartingIndex>0</StartingIndex>
                  <RequestedCount>200</RequestedCount>
                  <SortCriteria></SortCriteria>
            """,
            timeout: SonosTimeout.action)
        // THROWS on a refusal rather than returning an empty list. A speaker that will
        // not answer and a household with nothing saved are different answers, and
        // collapsing them into [] is what let `read` report "reachable, nothing saved"
        // when nothing had answered at all — the app would then tell the user to save
        // favorites they already have. Caught by a unit test on 2026-08-12, not by
        // anyone using it.
        guard reply.ok else { throw SonosSOAPError.badHost("\(host) refused Browse (\(reply.status))") }
        return parse(reply.body)
    }

    /// The result of trying to read favorites, which the UI must distinguish.
    ///
    /// "You have no SiriusXM favorites saved" and "we could not reach your Sonos
    /// system" look identical if both return an empty list, and telling someone to go
    /// save favorites they already have is the worse of the two mistakes.
    enum ReadResult {
        case ok([SonosFavorite], householdId: String?)
        case noSpeakerAnswered
    }

    /// Try each host until one answers, because not every speaker will.
    ///
    /// Measured 2026-08-10: one zone returned 500 to every ContentDirectory action —
    /// including GetSearchCapabilities — while others in the same household answered
    /// normally, and its device description omits services that demonstrably work on
    /// it. Asking a single speaker and believing its refusal is what produced the
    /// conclusion that favorites were unreachable, which nearly ended the feature.
    static func read(hosts: [String]) async -> ReadResult {
        for host in hosts {
            guard let favorites = try? await fetch(host: host), !favorites.isEmpty else { continue }
            let household = await SonosCommands.householdId(host: host)
            return .ok(favorites, householdId: household)
        }
        // Every host either failed or returned nothing. One more pass to tell those
        // apart: a household with genuinely zero favorites is a real, reportable state.
        for host in hosts where (try? await fetch(host: host)) != nil {
            return .ok([], householdId: await SonosCommands.householdId(host: host))
        }
        return .noSpeakerAnswered
    }

    // MARK: - Helpers

    /// The LAST occurrence of a tag. Needed because a favorite nests a second DIDL item
    /// inside its resMD, and the inner one is the meaningful one for `upnp:class`.
    private static func lastTag(_ name: String, in xml: String) -> String? {
        var result: String?
        var searchFrom = xml.startIndex
        while let open = xml.range(of: "<\(name)>", range: searchFrom..<xml.endIndex),
              let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) {
            result = String(xml[open.upperBound..<close.lowerBound])
            searchFrom = close.upperBound
        }
        return result
    }

    private static func tag(_ name: String, in xml: String, attributed: Bool = false) -> String? {
        let openPattern = attributed ? "<\(name)" : "<\(name)>"
        guard let openStart = xml.range(of: openPattern) else { return nil }
        let afterOpen: String.Index
        if attributed {
            guard let close = xml.range(of: ">", range: openStart.upperBound..<xml.endIndex) else { return nil }
            afterOpen = close.upperBound
        } else {
            afterOpen = openStart.upperBound
        }
        guard let end = xml.range(of: "</\(name)>", range: afterOpen..<xml.endIndex) else { return nil }
        return String(xml[afterOpen..<end.lowerBound])
    }
}

extension String {
    /// The five predefined XML entities. `&amp;` LAST — decoding it first would turn
    /// `&amp;lt;` into `<` instead of the literal `&lt;` it represents.
    var decodingXMLEntities: String {
        var s = self
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }
}
