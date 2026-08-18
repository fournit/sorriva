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
    /// Needed because one service — SiriusXM — can only be matched by name when the
    /// stream was not started from a favorite. See `matches(uri:station:)`.
    var name: String { get }
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

    /// Where this service's now-playing TEXT comes from. Defaulted, so adding an adapter
    /// does not force a decision about metadata before it has been measured.
    var nowPlaying: NowPlayingSource { get }

    /// Does this service publish a cover for the song currently playing?
    ///
    /// A SEPARATE QUESTION FROM `nowPlaying`, and it was a mistake to treat them as one.
    /// Modelling the choice as either/or forced every service into one of two shapes,
    /// and SiriusXM is neither: the song text is in `r:streamContent` while the artwork
    /// is in `upnp:albumArtURI` in the metadata block. Picking `streamContent` for it
    /// therefore threw the artwork away silently — measured on Garage 2026-08-17,
    /// playing 1st Wave, where the cover was sitting in the same response the whole time.
    ///
    /// Defaults to false rather than reading the field for everyone: iHeart publishes
    /// none, and SomaFM's has never been checked for whether it is a per-song cover or
    /// its channel logo. Turning it on blind would quietly replace curated station art.
    var providesTrackArt: Bool { get }

    /// Does this playing URI refer to this stored station?
    ///
    /// The default — both sides reduced to the same key — is right whenever a service
    /// names a channel the same way wherever it appears. SiriusXM does not: a favorite
    /// carries a channel UUID, while a session started by Alexa hands the speaker a raw
    /// stream whose only channel marker is a slug in the path. One channel, two
    /// identifier spaces, so no key function can match them and the comparison has to
    /// reach the station itself. Measured 2026-08-17; see SiriusXMAdapter.
    func matches(uri: String, station: StationLike) -> Bool
}

extension RadioServiceAdapter {
    var nowPlaying: NowPlayingSource { .streamContent }
    var providesTrackArt: Bool { false }

    func matches(uri: String, station: StationLike) -> Bool {
        guard station.serviceId == source,
              let key = stationKey(for: uri),
              let stored = station.streamURL, !stored.isEmpty
        else { return false }
        return stationKey(for: stored) == key
    }
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
    var providesTrackArt: Bool { true }

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

// MARK: - Spotify

/// Spotify, reached through the household's saved favorites.
///
/// THE ONLY SERVICE SO FAR THAT IS NOT A STREAM. A Spotify favorite is a CONTAINER
/// (`x-rincon-cpcontainer:…spotify%3Aplaylist%3A…`) which expands into the Sonos queue
/// when played, so what is LOADED afterwards is `x-rincon-queue:RINCON_…#0` — an address
/// naming no service at all. The per-song URI is the only thing left that identifies
/// Spotify, which is why the registry falls back to the track URI below.
///
/// Measured on Patio 2026-08-16:
///
///     TrackURI  x-sonos-spotify:spotify%3atrack%3a7J1uxwnxfQLu4APicE5Rnj?sid=12&…
///     favorite  x-rincon-cpcontainer:1006206cspotify%3Aplaylist%3A37i9dQZF1DZ06evNZZ5dTG?…
///
/// Both shapes are claimed. The track id is the identity for now-playing; the playlist id
/// is what a stored favorite matches on.
struct SpotifyAdapter: RadioServiceAdapter {
    let source = "spotify"

    /// `r:streamContent` is present but EMPTY; the song, artist, album and cover are all
    /// in the track metadata block. Measured: dc:title "Billie Jean", dc:creator
    /// "Michael Jackson", upnp:album "Thriller".
    var nowPlaying: NowPlayingSource { .trackMetadata }
    var providesTrackArt: Bool { true }

    func stationKey(for uri: String) -> String? {
        let lower = uri.lowercased()
        guard lower.contains("spotify") else { return nil }
        var body = lower
        if let query = body.firstIndex(of: "?") { body = String(body[..<query]) }
        // The id follows the last encoded colon, whether the payload is a track or a
        // playlist and however many times it has been percent-encoded (a container's
        // albumArtURI nests the encoding twice).
        guard let marker = body.range(of: "%3a", options: .backwards) else { return nil }
        let id = String(body[marker.upperBound...])
        return id.isEmpty ? nil : id
    }
}

// MARK: - SiriusXM

/// SiriusXM, reached through the household's saved favorites.
///
/// THE HARDEST OF THE FAVORITES-BACKED SERVICES, because a channel arrives under two
/// unrelated identifiers depending on who started it. Measured 2026-08-17 across three
/// zones:
///
///     stored favorite   x-sonosapi-stream:channel-linear%3A65f04311-…?sid=37&flags=8260&sn=3
///     Sonos app / app   x-sonosapi-hls:channel-linear%3a65f04311-…?sid=37&flags=8200&sn=4
///     Alexa             hls-radio://…/AAC_Audio/classicrewind/classicrewind_variant_short_v4.m3u8
///
/// The first two are the SAME channel — same UUID, differing only in scheme, case and
/// the account handle after `?`. That is a plain key match, and it is why this needed no
/// event subscription in the end.
///
/// Alexa's is the awkward one: no UUID anywhere, just a channel SLUG in the path. It
/// cannot be reduced to the same key as the favorite, so it is matched against the
/// station's NAME instead — see `matches(uri:station:)`.
///
/// DO NOT DISPLAY THIS SERVICE'S `dc:title`. On an Alexa session it is
/// `classicrewind_variant_short_v4.m3u8` — the manifest filename, the same trap that put
/// `hls.m3u8` on a zone card. Names come from the stations table.
struct SiriusXMAdapter: RadioServiceAdapter {
    let source = "siriusxm"

    /// THE SERVICE THAT BROKE THE EITHER/OR MODEL. Song text comes from
    /// `r:streamContent` — "TYPE=SNG|TITLE No New Tale To Tell|ARTIST Love & Rockets|
    /// ALBUM Earth, Sun, Moon" — so `nowPlaying` stays on the default, while the cover
    /// arrives separately in `upnp:albumArtURI` (albumart.siriusxm.com). Measured on
    /// Garage 2026-08-17.
    ///
    /// A session started by ALEXA carries no artwork at all, and no channel id either;
    /// those fall back to the station logo from the imported favorite, which is correct.
    var providesTrackArt: Bool { true }

    /// The channel UUID, namespaced by which SiriusXM id space it came from so a linear
    /// channel and an "xtra" channel sharing a UUID could never collide.
    func stationKey(for uri: String) -> String? {
        var body = uri.lowercased()
        if let query = body.firstIndex(of: "?") { body = String(body[..<query]) }
        for space in ["channel-linear", "channel-xtra"] {
            guard let r = body.range(of: "\(space)%3a") else { continue }
            let id = String(body[r.upperBound...])
            return id.isEmpty ? nil : "\(space):\(id)"
        }
        return nil
    }

    /// The channel slug from a raw SiriusXM stream — the directory above the manifest.
    ///
    ///     …/AAC_Audio/classicrewind/classicrewind_variant_short_v4.m3u8  →  classicrewind
    func slug(for uri: String) -> String? {
        guard RadioURI.host(uri).contains("siriusxm.com") else { return nil }
        let parts = RadioURI.pathComponents(uri)
        guard let manifestIndex = parts.lastIndex(where: { $0.hasSuffix(".m3u8") }),
              manifestIndex > 0 else { return nil }
        let candidate = parts[manifestIndex - 1]
        return candidate.isEmpty ? nil : candidate
    }

    /// Reduce a station name to the shape SiriusXM uses in its stream paths.
    /// "Classic Rewind" → "classicrewind". Applied to BOTH sides so the comparison is
    /// symmetric rather than a guess about their formatting.
    static func nameKey(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    func matches(uri: String, station: StationLike) -> Bool {
        guard station.serviceId == source else { return false }

        // Tier 1 — the channel id. Exact, and covers everything started from a favorite.
        if let key = stationKey(for: uri),
           let stored = station.streamURL, !stored.isEmpty,
           stationKey(for: stored) == key {
            return true
        }

        // Tier 2 — a raw stream with only a slug. A heuristic, deliberately confined to
        // this adapter: it compares the slug against the station's name, which is sound
        // for SiriusXM because its channel names are unique, and would NOT be sound as a
        // general rule (two iHeart stations already share a name).
        //
        // This is why the channel-number prefix is stripped at import: with "CH 25 - "
        // still attached, "ch25classicrewind" could never equal "classicrewind".
        if let slug = slug(for: uri), !slug.isEmpty {
            return Self.nameKey(slug) == Self.nameKey(station.name)
        }
        return false
    }
}

// MARK: - Registry

enum RadioServiceRegistry {

    /// Order is irrelevant — adapters are mutually exclusive by host.
    static let adapters: [RadioServiceAdapter] = [
        IHeartRadioAdapter(),
        SomaFMAdapter(),
        SonosRadioAdapter(),
        SpotifyAdapter(),
        SiriusXMAdapter(),
    ]

    /// Where to read now-playing for what a zone is currently playing.
    ///
    /// THE LOADED URI IS ASKED FIRST because it is the station, and for Sonos Radio the
    /// track URI is a per-song `x-sonos-http:` address identifying no service at all.
    ///
    /// THE TRACK URI IS THE FALLBACK, for queue-based content. A Spotify playlist expands
    /// into the queue, leaving `x-rincon-queue:RINCON_…#0` loaded — which names no
    /// service, so asking only the loaded URI meant Spotify silently read `r:streamContent`
    /// and showed no song at all. Local files also play from the queue, and their
    /// `x-file-cifs://` track URI is claimed by nobody, so they keep the shipped path.
    ///
    /// Falls back to `r:streamContent` for anything unclaimed, so a service without an
    /// adapter behaves exactly as it did before this existed.
    static func nowPlayingSource(forLoadedURI loaded: String,
                                 trackURI: String = "") -> NowPlayingSource {
        adapter(forLoadedURI: loaded, trackURI: trackURI)?.nowPlaying ?? .streamContent
    }

    /// Whether the service playing here publishes a cover per song. Unknown services say
    /// no, so nothing new appears on screen until an adapter has been measured.
    static func providesTrackArt(forLoadedURI loaded: String, trackURI: String = "") -> Bool {
        adapter(forLoadedURI: loaded, trackURI: trackURI)?.providesTrackArt ?? false
    }

    /// The adapter that owns what a zone is playing.
    ///
    /// The loaded URI is asked first because it is the station. The track URI is the
    /// fallback for queue-based content, where the loaded address (`x-rincon-queue:`)
    /// names no service at all — see the note on the two Spotify shapes.
    static func adapter(forLoadedURI loaded: String,
                        trackURI: String = "") -> RadioServiceAdapter? {
        for adapter in adapters where adapter.stationKey(for: loaded) != nil { return adapter }
        for adapter in adapters where !trackURI.isEmpty && adapter.stationKey(for: trackURI) != nil {
            return adapter
        }
        return nil
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

    /// The station a URI refers to, decided by the service that owns it.
    ///
    /// Each adapter is ASKED rather than having a key extracted from it. For most
    /// services that is the same thing — the default `matches` reduces both sides to one
    /// key, so a mirror change, a nested scheme or a rotated token cannot prevent a
    /// match, and two stations cannot accidentally collide.
    ///
    /// It stopped being the same thing with SiriusXM. This used to bail out whenever
    /// `identify` produced no key, which is exactly the Alexa case: a raw stream URL with
    /// no channel id in it at all. The adapter can still recognise it by other means, so
    /// the decision belongs to the adapter rather than to a key this function extracts
    /// on its behalf.
    ///
    /// Every adapter checks `serviceId` before answering, so asking all of them cannot
    /// produce a cross-service match.
    static func matchStation<S: StationLike>(uri: String, in stations: [S]) -> S? {
        for adapter in adapters {
            if let hit = stations.first(where: { adapter.matches(uri: uri, station: $0) }) {
                return hit
            }
        }
        return nil
    }
}
