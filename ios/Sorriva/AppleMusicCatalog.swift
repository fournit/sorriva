import Foundation

// MARK: - AppleMusicCatalog
//
// Finding music in Apple's catalogue, over endpoints that need NO ACCOUNT AT ALL — no
// developer key, no MusicKit entitlement, no user sign-in. Measured 2026-08-18.
//
// WHY THIS IS THE WHOLE STORY FOR SEARCH. The ids these endpoints return are the SAME
// catalogue ids Sonos plays: `trackId=1387216792` came back for a song the speaker had
// addressed as `song%3a1387216792`, and a track found here and never touched by the
// household played on a speaker seconds later. So search and playback share one
// identifier space and neither needs credentials — see sonos-playback-contract.md §13.
//
// WHAT THIS CANNOT DO, so nobody reaches for it and is disappointed:
// - It is a RELEVANCE search, not a structured one. "Pat Metheny" returns a Jaco
//   Pastorius record, a Kronos Quartet album and an unrelated Japanese guitar record,
//   plus the same album twice under two ids. There is no "this artist's albums" call.
//   Correct browsing by artist needs MusicKit; see fMusicKitAdapter.
// - It reaches the iTunes Store catalogue, which is NOT identical to Apple Music's. One
//   album reported 9 tracks and returned 8, because some items are purchase-only.
//   `isStreamable` is carried through below, but treat it as a hint: the app must cope
//   with having an id that will not play.
// - 200 results per search, with NO paging, and roughly 20 requests a minute.
// - It knows nothing about the user's own library or playlists. That is MusicKit's job.

struct AppleAlbum: Identifiable, Hashable {
    let id: Int                 // collectionId — what a container address is built from
    let title: String
    let artist: String
    let artistId: Int?
    /// Cover art. The SIZE LIVES IN THE PATH, so one field serves every use — see
    /// `artworkURL(size:)`.
    let artworkBase: String?
    let year: String?
    let genre: String?
    let trackCount: Int
    let copyright: String?
    /// The full release date, for the footer under a track listing. `year` is kept because
    /// most rows only ever show the year, and deriving it at every call site would be worse.
    var releaseDate: Date? = nil

    /// Cover art at any edge length. Apple serves the same image scaled by rewriting the
    /// last path component; 100, 600, 1000 and 3000 were all verified to fetch.
    func artworkURL(size: Int) -> URL? {
        guard let base = artworkBase else { return nil }
        // ".../100x100bb.jpg" → ".../600x600bb.jpg". Rewriting only the final component
        // leaves the rest of the path — which is content-addressed — untouched.
        guard let slash = base.lastIndex(of: "/") else { return URL(string: base) }
        let stem = base[..<slash]
        return URL(string: "\(stem)/\(size)x\(size)bb.jpg")
    }
}

// MARK: - AppleSearchRelevance
//
// APPLE'S RAW SEARCH IS LOOSER THAN APPLE'S OWN APP. Measured 2026-08-20: searching
// "Pat Metheny" and paging returns albums by Ahn Trio, Fumiaki Miyamoto and California
// State University — records Metheny is not credited on at all. The Apple Music app does
// not show those. Tom, 2026-08-20: "it only delivers albums where pat metheny is listed."
//
// So the depth was never the problem; the FILTER was. Apple pages deep on purpose and
// narrows what it shows. This is that narrowing.
//
// THE RULE: every word of the query must appear somewhere in the item's own title or
// artist credit. Deliberately checks BOTH, so that searching an album title still works —
// filtering on artist alone would drop "Bright Size Life" from a title search.
//
// KNOWN LIMITS, so nobody is surprised later:
//   - It drops records where the artist is a genuine but uncredited contributor — a
//     compilation listing "Various Artists". Tom saw one such album in Apple's own results,
//     so Apple is doing something slightly richer than this with its credits data.
//   - A broad word search ("jazz") keeps only items with that word in the title or artist,
//     where Apple's relevance is doing semantic work this cannot reproduce.
// Both are the acceptable side of the trade: a short honest list beats a long noisy one.

enum AppleSearchRelevance {

    /// Whether an item genuinely answers the query.
    static func matches(_ query: String, _ title: String, _ artist: String) -> Bool {
        let words = tokens(query)
        guard !words.isEmpty else { return true }
        let haystack = fold(title + " " + artist)
        return words.allSatisfy { haystack.contains($0) }
    }

    static func tokens(_ s: String) -> [String] {
        fold(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Case- and accent-insensitive, so "Jobim" matches "Jobím" and "METHENY" matches
    /// "Metheny". The local library learned this lesson already; streaming metadata is worse.
    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

extension Array {
    /// Sort by a text field the way a reader expects a list to be sorted.
    ///
    /// `localizedStandardCompare` rather than a plain `<`: it is case-insensitive, and it
    /// orders embedded numbers numerically, so "Ep. 2" precedes "Ep. 10" instead of following
    /// it. Foundation-only, so this stays in the fast suite.
    func sortedByName(_ key: KeyPath<Element, String>) -> [Element] {
        sorted { $0[keyPath: key].localizedStandardCompare($1[keyPath: key]) == .orderedAscending }
    }
}

/// An artist, as a route to their music — not a profile page. Tom, 2026-08-20: Discover is
/// "for finding music, not roon like commentary on the artist."
///
/// `artworkURL` is why this comes from MusicKit rather than the public endpoint: the public
/// artist search carries no artwork field at all, so these rows would be blank squares.
struct AppleArtist: Identifiable, Hashable {
    let id: String              // numeric catalogue id, e.g. "113526"
    let name: String
    let artworkURL: String?
    let genre: String?
}

/// A catalogue playlist — Apple's own curated lists.
///
/// The id is `pl.`-prefixed rather than numeric, which is why this is a String while albums
/// and tracks are Int. Measured 2026-08-20: `pl.ebe2805581da4c409cb07eacd1c7d8ec` built into
/// a container address expanded to 21 tracks and played. See AppleMusicPlayback.playlistURI.
///
/// The user's OWN playlists are a different thing — they need a signed-in subscriber and are
/// not this type.
struct ApplePlaylist: Identifiable, Hashable {
    let id: String              // "pl.ebe2805581da4c409cb07eacd1c7d8ec"
    let name: String
    let curator: String?
    let artworkURL: String?
    let description: String?
}

struct AppleTrack: Identifiable, Hashable {
    let id: Int                 // trackId — the catalogue id Sonos plays
    let title: String
    let artist: String
    let trackNumber: Int
    let discNumber: Int
    let durationSeconds: Int
    /// Apple's own claim about whether this streams. A hint, not a guarantee — see the
    /// note at the top about the two catalogues differing.
    let isStreamable: Bool
    /// Cover art for the track's own album. Present on search and top-song results, where a
    /// row has no album header above it to supply one; a track inside an album listing does
    /// not need it, because every row there shares the cover already on screen.
    var artworkURL: String? = nil
}

enum AppleMusicCatalog {

    /// Apple caps a search at 200 and offers no offset, so asking for more is pointless.
    static let maxResults = 200

    private static let host = "https://itunes.apple.com"

    // MARK: - Search

    /// Albums matching a free-text term.
    ///
    /// Albums rather than songs deliberately: a song search returns 200 loose tracks with
    /// no structure, while albums are the unit a person browses and each one can be
    /// opened for its tracks.
    static func searchAlbums(_ term: String, limit: Int = 50) async throws -> [AppleAlbum] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let rows = try await get(path: "/search", query: [
            "term": trimmed,
            "entity": "album",
            "limit": String(min(limit, maxResults)),
        ])
        return rows.compactMap(album(from:))
    }

    // MARK: - Album detail

    /// One album and its tracks.
    ///
    /// Returns nil rather than throwing when the id is unknown — a stale id is an
    /// ordinary outcome, not an error worth an alert.
    static func album(id: Int) async throws -> (album: AppleAlbum, tracks: [AppleTrack])? {
        let rows = try await get(path: "/lookup", query: [
            "id": String(id),
            "entity": "song",
            "limit": String(maxResults),
        ])
        guard let head = rows.first(where: { $0["wrapperType"] as? String == "collection" }),
              let found = album(from: head)
        else { return nil }

        let tracks = rows
            .filter { $0["wrapperType"] as? String == "track" }
            .compactMap(track(from:))
            // Disc order then track order. Apple returns them ordered, but a multi-disc
            // set relies on it and sorting costs nothing.
            .sorted { ($0.discNumber, $0.trackNumber) < ($1.discNumber, $1.trackNumber) }
        return (found, tracks)
    }

    // MARK: - Parsing

    /// Not private so the fast suite can exercise it against captured payloads. The
    /// TRANSPORT stays private — tests must never make a network call.
    static func album(from row: [String: Any]) -> AppleAlbum? {
        guard let id = row["collectionId"] as? Int,
              let title = row["collectionName"] as? String
        else { return nil }
        return AppleAlbum(
            id: id,
            title: title,
            artist: row["artistName"] as? String ?? "",
            artistId: row["artistId"] as? Int,
            artworkBase: row["artworkUrl100"] as? String,
            year: (row["releaseDate"] as? String).map { String($0.prefix(4)) },
            genre: row["primaryGenreName"] as? String,
            trackCount: row["trackCount"] as? Int ?? 0,
            copyright: row["copyright"] as? String)
    }

    /// See the note on `album(from:)`.
    static func track(from row: [String: Any]) -> AppleTrack? {
        guard let id = row["trackId"] as? Int,
              let title = row["trackName"] as? String
        else { return nil }
        return AppleTrack(
            id: id,
            title: title,
            artist: row["artistName"] as? String ?? "",
            trackNumber: row["trackNumber"] as? Int ?? 0,
            discNumber: row["discNumber"] as? Int ?? 1,
            durationSeconds: ((row["trackTimeMillis"] as? Int) ?? 0) / 1000,
            isStreamable: row["isStreamable"] as? Bool ?? true)
    }

    // MARK: - Transport

    private static func get(path: String, query: [String: String]) async throws -> [[String: Any]] {
        var components = URLComponents(string: host + path)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["results"] as? [[String: Any]] ?? []
    }
}
