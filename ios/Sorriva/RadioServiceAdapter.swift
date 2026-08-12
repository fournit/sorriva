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

protocol RadioServiceAdapter {
    /// The `stations.serviceId` value this adapter owns.
    var source: String { get }

    /// The canonical station identifier within this service, or nil when the URI does
    /// not belong to it.
    ///
    /// Must return the same key for every URI shape the service produces — the URI
    /// Sonos reports during playback and the URL we stored at browse time alike.
    func stationKey(for uri: String) -> String?
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

// MARK: - Registry

enum RadioServiceRegistry {

    /// Order is irrelevant — adapters are mutually exclusive by host.
    static let adapters: [RadioServiceAdapter] = [
        IHeartRadioAdapter(),
        SomaFMAdapter(),
    ]

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
    static func matchStation(uri: String, in stations: [Station]) -> Station? {
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
