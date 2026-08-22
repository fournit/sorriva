import Foundation

// MARK: - ArtistInfoService
//
// An artist's biography, from sources that work for EVERY source of music. Tom, 2026-08-21:
// bios are "required as well for local playback" — so this is keyed on the artist, never on
// where the music came from. A NAS FLAC and an Apple Music album resolve identically.
//
// WHY NOT APPLE. MusicKit declares Artist.editorialNotes and never populates it. Measured
// 2026-08-21 on the Simulator with no account AND on Tom's phone with a live subscription:
// nil for artists and for albums, from both the search and the resource path. The field
// exists; nothing fills it. See bAppleArtistBioMissing.
//
// WHY NOT ROON'S SOURCE. Roon licenses TiVo/Rovi (AllMusic), which is a commercial contract
// rather than an API key. MusicBrainz hands us the AllMusic artist id for free, so if that
// licence were ever bought, it is a swap at the last step of this chain and nothing else
// changes.
//
// THE CHAIN, and the order is Tom's, made on measured evidence:
//
//     name → MusicBrainz mbid → external ids → Discogs   (independent prose)
//                                            → Wikipedia (current, authoritative)
//                                            → Last.fm   (last resort)
//
// LAST.FM IS A STALE WIKIPEDIA FORK, which is why it is last despite having the longest text.
// Measured on the same artists: its Pat Metheny bio still says he "is ... leader of the Pat
// Metheny Group", a band that ended in 2010, where Wikipedia says "was ... (1977–2010)".
// Common ancestry, frozen years ago. Long is not the same as right.
//
// COVERAGE, measured 2026-08-21, characters after cleanup:
//
//     artist            discogs   wikipedia   lastfm
//     Pat Metheny          2669         468     8482
//     Vanessa Daou          148         365     8684
//     Kenny Wheeler         183         495     1336
//     Julia Hülsmann        516         166       90
//     Nik Bärtsch            82         114     1570
//
// Nothing dominates, which is the whole reason this is layered rather than a single source.
//
// RATE LIMITS ARE THE HARD CONSTRAINT. MusicBrainz asks for one request a second and a real
// User-Agent; Discogs allows 25/min unauthenticated. This is safe per artist VIEWED and would
// get us blocked as a background sweep over a library. Do not batch it.

struct ArtistInfo: Equatable {
    let mbid: String?
    let name: String
    /// What MusicBrainz calls the artist apart from others of the same name — "German double
    /// bassist and composer". Useful on screen and essential for judging a match.
    let disambiguation: String?
    let bio: String?
    let bioSource: BioSource?

    enum BioSource: String, Equatable {
        case discogs, wikipedia, lastfm
    }
}

enum ArtistInfoService {

    /// Called by tests with a stub so no test ever makes a network call.
    typealias Fetch = (URL) async throws -> Data

    enum FetchError: Error {
        /// The service asked us to slow down. Distinct from a failure because it is worth
        /// retrying, and because silently treating it as "no data" is what hid it.
        case rateLimited
        case http(Int)
    }

    /// One request, with the status code actually checked.
    ///
    /// AN EARLIER VERSION RETURNED THE BODY WHATEVER THE STATUS, which meant a MusicBrainz
    /// 503 rate-limit page was parsed as JSON, failed, and became a silent nil. Measured
    /// 2026-08-21: the same endpoint returned 0 links for one artist and 12 for the next,
    /// seconds apart, and nothing in the app said why. Swallowing a throttle as "no data" is
    /// the worst possible reading of it.
    static var fetch: Fetch = { url in
        var request = URLRequest(url: url, timeoutInterval: 15)
        // MusicBrainz REJECTS requests without a descriptive User-Agent, and rate-limits by
        // it. This is a documented requirement, not politeness.
        request.setValue("Sorriva/1.0 ( https://sorriva.app )", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200...299: return data
        case 429, 503:  throw FetchError.rateLimited
        default:        throw FetchError.http(status)
        }
    }

    /// Fetch, and try once more after a pause if we were throttled.
    ///
    /// MusicBrainz allows roughly one request a second and answers a burst with a 503. One
    /// retry after a second is enough for a screen that asks about a single artist; it is
    /// NOT enough to make a library-wide sweep acceptable, and that remains something this
    /// service must never be used for.
    private static func fetchRetrying(_ url: URL) async -> Data? {
        do {
            return try await fetch(url)
        } catch FetchError.rateLimited {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            return try? await fetch(url)
        } catch {
            return nil
        }
    }

    // MARK: - Entry point

    /// Which tiers are worth keeping.
    ///
    /// Tom, 2026-08-21: "i don't like the idea of storing the lesser of a bio." Last.fm is a
    /// stale Wikipedia fork and its entries are sometimes not biographies at all — one came
    /// back as a forty-line discography under a German heading. Showing that once is
    /// tolerable; freezing it into the database forever is not, because a single unlucky
    /// fetch during a Discogs hiccup would decide that artist's biography permanently.
    ///
    /// So a fallback is displayed and NOT written, and the next visit tries the good sources
    /// again and upgrades itself.
    static func cacheable(_ source: ArtistInfo.BioSource) -> Bool {
        switch source {
        case .discogs, .wikipedia: return true
        case .lastfm:              return false
        }
    }

    /// Cache hooks, INERT BY DEFAULT and installed at launch by ArtistInfoCache.
    ///
    /// This file must stay Foundation-only: `ios/FastTests` compiles it directly for macOS,
    /// which is what keeps the whole service in the one-second test loop. Reaching for
    /// SorrivaDatabase here broke that immediately — GRDB is not in that target and the
    /// suite stopped compiling. So the database lives behind these closures, on the far side
    /// of the boundary.
    ///
    /// Inert defaults also mean the service works with no cache at all, which is exactly
    /// what the tests want.
    static var cacheRead: (String) -> ArtistInfo? = { _ in nil }
    static var cacheWrite: (ArtistInfo) -> Void = { _ in }

    static func lookup(name: String) async -> ArtistInfo? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let match = await musicBrainzArtist(named: trimmed)

        // A stored biography short-circuits the whole chain. The MusicBrainz lookup above
        // still runs because the mbid IS the cache key — but that is one request rather than
        // five, and it is the cheap one.
        if let mbid = match?.mbid, let cached = cacheRead(mbid), cached.bio != nil {
            return cached
        }

        var bio: String?
        var source: ArtistInfo.BioSource?

        if let match {
            let links = await externalLinks(mbid: match.mbid)
            // CONCURRENTLY, then preferred in Tom's order. Chaining them meant the Wikipedia
            // request only started once Discogs had finished failing, which on a throttled
            // MusicBrainz turned a slow lookup into a very slow one.
            async let discogs = discogsProfile(from: links["discogs"])
            async let wikipedia = wikipediaExtract(from: links["wikidata"])
            if let text = await discogs {
                bio = text; source = .discogs
            } else if let text = await wikipedia {
                bio = text; source = .wikipedia
            }
        }

        // Last.fm needs no mbid — it matches by name — which is why it can still answer when
        // the identifier chain fails entirely.
        if bio == nil, let text = await lastFmBio(name: match?.name ?? trimmed) {
            bio = text; source = .lastfm
        }

        guard match != nil || bio != nil else { return nil }
        let info = ArtistInfo(mbid: match?.mbid,
                              name: match?.name ?? trimmed,
                              disambiguation: match?.disambiguation,
                              bio: bio,
                              bioSource: source)

        if let source, cacheable(source), info.mbid != nil, info.bio != nil {
            cacheWrite(info)
        }
        return info
    }

    // MARK: - MusicBrainz

    struct Match: Equatable {
        let mbid: String
        let name: String
        let disambiguation: String?
        let score: Int
    }

    /// The best MusicBrainz match for a name, or nil when nothing is confident enough.
    ///
    /// A PLAIN QUERY, NOT A FIELD-SCOPED PHRASE. `artist:"Eberhard Weber"` returns NOTHING
    /// while `Eberhard Weber` returns him at score 100 — measured 2026-08-21, and it silently
    /// lost three artists from a coverage test before it was spotted. Do not "improve" this
    /// into a scoped query.
    ///
    /// Accents resolve on their own: "Nik Bartsch" matches Nik Bärtsch, "Julia Hulsmann"
    /// matches Julia Hülsmann. So no folding is needed here.
    static func musicBrainzArtist(named name: String) async -> Match? {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://musicbrainz.org/ws/2/artist?query=\(encoded)&fmt=json&limit=5")
        else { return nil }
        guard let data = await fetchRetrying(url) else { return nil }
        return bestMatch(from: data, wanted: name)
    }

    /// Not private so the fast suite can exercise it against captured payloads.
    ///
    /// THE WRONG ARTIST IS WORSE THAN NO ARTIST. "Pat Metheny", "Pat Metheny Group" and "Pat
    /// Metheny Trio" are three different MBIDs, and attaching the Group's biography to the man
    /// is a silent, plausible-looking error. So an exact name match always wins over a higher
    /// score, and anything below the threshold is refused rather than guessed at.
    static func bestMatch(from data: Data, wanted: String) -> Match? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["artists"] as? [[String: Any]]
        else { return nil }

        let candidates: [Match] = rows.compactMap { row in
            guard let id = row["id"] as? String, let name = row["name"] as? String
            else { return nil }
            let d = row["disambiguation"] as? String
            return Match(mbid: id, name: name,
                         disambiguation: (d?.isEmpty == false) ? d : nil,
                         score: row["score"] as? Int ?? 0)
        }

        let target = fold(wanted)
        if let exact = candidates.first(where: { fold($0.name) == target }) { return exact }
        // No exact name — take the top hit only if MusicBrainz is confident. 90 is high enough
        // to exclude "Carl Maria von Weber" for a "Eberhard Weber" query, which scored 47.
        return candidates.first.flatMap { $0.score >= 90 ? $0 : nil }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The artist's links to other databases, keyed by relation type.
    static func externalLinks(mbid: String) async -> [String: String] {
        guard let url = URL(string: "https://musicbrainz.org/ws/2/artist/\(mbid)?inc=url-rels&fmt=json"),
              let data = await fetchRetrying(url)
        else { return [:] }
        return links(from: data)
    }

    static func links(from data: Data) -> [String: String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let relations = json["relations"] as? [[String: Any]]
        else { return [:] }
        var out: [String: String] = [:]
        for r in relations {
            guard let type = r["type"] as? String,
                  let resource = (r["url"] as? [String: Any])?["resource"] as? String
            else { continue }
            out[type] = resource        // first wins; duplicates are alternate mirrors
        }
        return out
    }

    // MARK: - Discogs

    static func discogsProfile(from urlString: String?) async -> String? {
        guard let id = trailingId(of: urlString),
              let url = URL(string: "https://api.discogs.com/artists/\(id)"),
              let data = await fetchRetrying(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return ArtistBioText.clean(json["profile"] as? String, from: .discogs)
    }

    // MARK: - Wikipedia

    /// Wikidata is the hop from a MusicBrainz artist to a Wikipedia article title.
    static func wikipediaExtract(from wikidataURL: String?) async -> String? {
        guard let qid = trailingId(of: wikidataURL),
              let entityURL = URL(string: "https://www.wikidata.org/w/api.php?action=wbgetentities"
                                  + "&ids=\(qid)&props=sitelinks&format=json"),
              let entityData = await fetchRetrying(entityURL),
              let title = wikipediaTitle(from: entityData, qid: qid),
              let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              // exintro + explaintext gives the LEAD SECTION as plain prose — no markup, no
              // headings, no discography tables. The cleanup here is choosing this endpoint
              // rather than stripping an article afterwards.
              let extractURL = URL(string: "https://en.wikipedia.org/w/api.php?action=query"
                                   + "&prop=extracts&exintro=1&explaintext=1&redirects=1"
                                   + "&format=json&titles=\(encoded)"),
              let extractData = await fetchRetrying(extractURL)
        else { return nil }
        return ArtistBioText.clean(wikipediaText(from: extractData), from: .wikipedia)
    }

    static func wikipediaTitle(from data: Data, qid: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = json["entities"] as? [String: Any],
              let entity = entities[qid] as? [String: Any],
              let sitelinks = entity["sitelinks"] as? [String: Any],
              let en = sitelinks["enwiki"] as? [String: Any]
        else { return nil }
        return en["title"] as? String
    }

    static func wikipediaText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any],
              let page = pages.values.compactMap({ $0 as? [String: Any] }).first
        else { return nil }
        return page["extract"] as? String
    }

    // MARK: - Last.fm

    static func lastFmBio(name: String) async -> String? {
        guard !Secrets.lastFmAPIKey.isEmpty,
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://ws.audioscrobbler.com/2.0/?method=artist.getinfo"
                            + "&artist=\(encoded)&api_key=\(Secrets.lastFmAPIKey)&format=json"),
              let data = await fetchRetrying(url)
        else { return nil }
        return ArtistBioText.clean(lastFmText(from: data), from: .lastfm)
    }

    static func lastFmText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artist = json["artist"] as? [String: Any],
              let bio = artist["bio"] as? [String: Any]
        else { return nil }
        return bio["content"] as? String
    }

    // MARK: - Helpers

    /// The last path component of a URL — a Discogs artist id, a Wikidata QID.
    static func trailingId(of urlString: String?) -> String? {
        guard let s = urlString?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              let last = s.split(separator: "/").last, !last.isEmpty
        else { return nil }
        return String(last)
    }
}
