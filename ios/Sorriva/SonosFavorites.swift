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
            out.append(SonosFavorite(
                title: title.decodingXMLEntities,
                uri: res.decodingXMLEntities,
                metadata: md.decodingXMLEntities,
                artURL: tag("upnp:albumArtURI", in: chunk)?.decodingXMLEntities,
                serviceName: (tag("r:description", in: chunk) ?? "Sonos").decodingXMLEntities,
                sonosServiceId: sonosServiceId(from: res)))
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
        guard reply.ok else { return [] }
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
