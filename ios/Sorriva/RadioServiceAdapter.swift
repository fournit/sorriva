import Foundation

// MARK: - RadioServiceAdapter
// Identifies which station a Sonos stream URI refers to.
//
// WHY PER-SERVICE RATHER THAN ONE GENERIC RULE:
// Providers shape their URIs differently, and the differences are not variations on a
// theme — they are unrelated problems. iHeart appends session tokens that rotate on
// every poll (rj-tok, init_id, streamid, playedFrom). SomaFM load-balances one channel
// across ice1/ice2/ice4, so the host is not part of a station's identity. The transport
// scheme depends on whether Sorriva or the Sonos app started playback, and schemes nest
// (aac://http://). A single normalisation routine covering all of that accumulates one
// exception per provider, and every new exception risks regressing the others.
//
// Each service, however, already has an EXACT identifier: iHeart a station code
// (zc8681), SomaFM a channel slug (secretagent). An adapter extracts that identifier
// from any URI shape its own service produces, and the SAME function is applied to the
// stored URL — so the two are compared as canonical keys rather than as strings that
// happen to resemble each other.
//
// Adding a provider means writing one adapter and leaving every other service alone.
// See engineering/radio-service-integration.md for the integration checklist.

/// Where a service publishes the song playing right now.
///
/// There is no universal answer, and guessing produced three different meanings for one
/// field. iHeart and SomaFM fill `r:streamContent` — a flat "TITLE x|ARTIST y" string —
/// and put a filename or a channel slug in `dc:title`. Sonos Radio does the opposite:
/// `r:streamContent` is absent entirely and the real song, artist and per-track artwork
/// live in the DIDL track metadata. Reading `dc:title` globally is what once put
/// "hls.m3u8" on a zone card; NOT reading it is why Sonos Radio showed no track at all.
/// So the service decides, and a service nobody has taught us about keeps the old
/// behaviour rather than a new guess.
enum NowPlayingSource {
    /// `r:streamContent`. No artwork — these services supply none per song.
    case streamContent
    /// `dc:title`, `dc:creator`, `upnp:albumArtURI` from the track metadata block.
    case trackMetadata
}

/// The minimum a matcher needs to know about a stored station.
///
/// Declared here, and satisfied by the database's `Station`, so that this file stays
/// clear of the database layer. The adapters are pure URI logic; naming the concrete
/// GRDB record here would pull the whole persistence stack into the fast test package,
/// which exists precisely to run without it.
protocol StationLike {
    var serviceId: String { get }
    var streamURL: String? { get }
}

protocol RadioServiceAdapter {
    /// The `stations.serviceId` value this adapter owns.
    var source: String { get }

    /// The canonical station identifier within this service, or nil when the URI does
    /// not belong to it.
    ///
    /// Must return the same key for every URI shape the service produces — the URI
    /// Sonos reports during playback and the URL we stored at browse time alike.
    func stationKey(for uri: String) -> String?

    /// Where this service's now-playing comes from. Defaulted, so adding an adapter
    /// does not force a decision about metadata before it has been measured.
    var nowPlaying: NowPlayingSource { get }
}

extension RadioServiceAdapter {
    var nowPlaying: NowPlayingSource { .streamContent }
}

// MARK: - Shared URI helpers
// Transport-level parsing only. Anything that requires knowing how a particular
// provider names its stations belongs in that provider's adapter, not here.

enum RadioURI {

    /// Strip nested transport schemes and any query string.
    ///
    /// Everything before the host is transport detail (`aac://`, `hls-radio://`,
    /// `x-rincon-mp3radio://`, and these nest), and everything after `?` is session
    /// state that changes between polls.
    ///
    ///     aac://http://ice2.somafm.com/secretagent-128-aac  →  ice2.somafm.com/secretagent-128-aac
    static func hostAndPath(_ raw: String) -> String {
        var s = raw.lowercased()
        while let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if let query = s.firstIndex(of: "?") { s = String(s[..<query]) }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    static func host(_ raw: String) -> String {
        let combined = hostAndPath(raw)
        guard let slash = combined.firstIndex(of: "/") else { return combined }
        return String(combined[..<slash])
    }

    static func pathComponents(_ raw: String) -> [String] {
        let combined = hostAndPath(raw)
        guard let slash = combined.firstIndex(of: "/") else { return [] }
        return String(combined[combined.index(after: slash)...])
            .split(separator: "/")
            .map(String.init)
    }
}

// MARK: - iHeartRADIO

struct IHeartRadioAdapter: RadioServiceAdapter {
    let source = "iheart"

    /// iHeart streams are `…/<stationCode>/hls.m3u8`, where the station code (zc8681)
    /// is the identity and the manifest filename is identical for every station. The
    /// query string carries rotating session tokens and is discarded by `hostAndPath`.
    func stationKey(for uri: String) -> String? {
        let host = RadioURI.host(uri)
        guard host.contains("ihrhls.com") || host.contains("revma") || host.contains("iheart")
        else { return nil }

        let parts = RadioURI.pathComponents(uri)
        if let code = parts.first(where: {
            $0.hasPrefix("zc") && $0.dropFirst(2).allSatisfy(\.isNumber)
        }) {
            return code
        }
        // Unrecognised layout — fall back to the first segment that is not the manifest.
        return parts.first { !$0.isEmpty && !$0.hasSuffix(".m3u8") && !$0.hasSuffix(".m3u") }
    }
}

// MARK: - SomaFM

struct SomaFMAdapter: RadioServiceAdapter {
    let source = "somafm"

    /// SomaFM channels are identified by a slug. The host varies (ice1/ice2/ice4 are
    /// mirrors of the same channel) and the filename carries a bitrate/codec suffix,
    /// so both are stripped:
    ///
    ///     ice2.somafm.com/secretagent-128-aac  →  secretagent
    ///     ice4.somafm.com/bossa-128-aac        →  bossa
    ///
    /// A bare trailing number is deliberately NOT stripped — `sf1033` is a real channel
    /// (SF 10-33), and removing digits would reduce it to `sf`. That means a stored
    /// playlist URL of the form `somafm.com/secretagent130.pls` will not match; if that
    /// shape turns up in the data, handle it here rather than in the matcher.
    func stationKey(for uri: String) -> String? {
        guard RadioURI.host(uri).contains("somafm.com") else { return nil }
        guard var slug = RadioURI.pathComponents(uri).last, !slug.isEmpty else { return nil }

        if let dot = slug.lastIndex(of: "."), dot != slug.startIndex {
            slug = String(slug[..<dot])
        }
        // Trailing "-128-aac" / "-256-mp3" / "-128". Anchored so hyphenated channel
        // names survive intact.
        if let suffix = slug.range(of: "-[0-9]+(-[a-z0-9]+)?$", options: .regularExpression) {
            slug = String(slug[..<suffix.lowerBound])
        }
        return slug.isEmpty ? nil : slug
    }
}

// MARK: - Sonos Radio

/// Sonos Radio, reached through the household's saved favorites.
///
/// Unlike iHeart and SomaFM, nothing here is an HTTP stream URL — there is no host and
/// no path, so the shared `RadioURI` helpers do not apply. A station is a numeric id
/// inside the scheme itself:
///
///     x-sonosapi-radio:sonos%3A158291?sid=303&flags=28780&sn=1   (stored favorite)
///     x-sonosapi-radio:sonos%3a158291?sid=303&flags=0&sn=1       (reported at playback)
///
/// Measured 2026-08-13 on the Office speaker: those two forms differ in the case of the
/// percent-encoded colon AND in `flags` (28780 vs 0), for the same station. Only the id
/// is identity; everything after `?` is the account handle, which the speaker ignores.
///
/// THE PAYLOAD PREFIX IS LOAD-BEARING, not decoration. SiriusXM also reports `x-sonosapi-radio:` URIs,
/// with a `channel-xtra%3a<uuid>` payload — so matching the scheme alone would make this
/// adapter claim SiriusXM's streams and answer for a service it knows nothing about.
struct SonosRadioAdapter: RadioServiceAdapter {
    let source = "sonosradio"

    /// Sonos Radio leaves `r:streamContent` empty and puts the song, the artist and a
    /// per-track image in the track metadata instead. Verified against a live stream:
    /// dc:title "My Hood", dc:creator "RAY BLK", art on sonosradio.imgix.net.
    var nowPlaying: NowPlayingSource { .trackMetadata }

    private static let scheme = "x-sonosapi-radio:"
    private static let payloadPrefix = "sonos%3a"

    func stationKey(for uri: String) -> String? {
        let lower = uri.lowercased()
        guard lower.hasPrefix(Self.scheme) else { return nil }
        var body = String(lower.dropFirst(Self.scheme.count))
        if let query = body.firstIndex(of: "?") { body = String(body[..<query]) }
        guard body.hasPrefix(Self.payloadPrefix) else { return nil }
        let id = String(body.dropFirst(Self.payloadPrefix.count))
        return id.isEmpty ? nil : id
    }
}

// MARK: - Registry

enum RadioServiceRegistry {

    /// Order is irrelevant — adapters are mutually exclusive by host.
    static let adapters: [RadioServiceAdapter] = [
        IHeartRadioAdapter(),
        SomaFMAdapter(),
        SonosRadioAdapter(),
    ]

    /// Where to read now-playing for whatever is LOADED on a zone.
    ///
    /// Asked of the loaded URI, never the track URI: for Sonos Radio the track URI is a
    /// per-song `x-sonos-http:` address that identifies no service at all.
    ///
    /// Falls back to `r:streamContent` for anything unclaimed, so a service without an
    /// adapter behaves exactly as it did before this existed.
    static func nowPlayingSource(forLoadedURI uri: String) -> NowPlayingSource {
        for adapter in adapters where adapter.stationKey(for: uri) != nil {
            return adapter.nowPlaying
        }
        return .streamContent
    }

    /// Which service owns this URI, and its station key within that service.
    static func identify(uri: String) -> (source: String, key: String)? {
        for adapter in adapters {
            if let key = adapter.stationKey(for: uri) {
                return (adapter.source, key)
            }
        }
        return nil
    }

    /// The station a URI refers to, matched exactly within its own service.
    ///
    /// Both sides are reduced to canonical keys by the same adapter, so a mirror
    /// change, a different transport scheme, or a rotated session token cannot
    /// prevent a match — and two different stations cannot accidentally match.
    static func matchStation<S: StationLike>(uri: String, in stations: [S]) -> S? {
        guard let (source, key) = identify(uri: uri),
              let adapter = adapters.first(where: { $0.source == source })
        else { return nil }

        return stations.first { station in
            guard station.serviceId == source,
                  let stored = station.streamURL, !stored.isEmpty
            else { return false }
            return adapter.stationKey(for: stored) == key
        }
    }
}
