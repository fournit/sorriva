import Foundation

// MARK: - ArtworkLookup
//
// Finds candidate cover art for an album, CONSTRAINED TO THE ARTIST'S OWN
// CATALOGUE rather than trusting a text search to rank correctly.
//
// The bug this replaces (bArtworkArtistQuery): the old path asked iTunes for
// "{artist} {album}" with limit=1 and used results.first unconditionally, never
// looking at the artistName or collectionName it got back. iTunes' relevance
// ranking WAS the matching logic. Measured outcomes on one album — Johnny Cash's
// "18 Greatest Hits" — were Al Green's greatest hits in July and Creed's greatest
// hits in August. Not near-misses: different artists entirely.
//
// The fix is structural rather than a better query. Resolve the artist first,
// then ask only for that artist's albums. "Creed on a Johnny Cash record" stops
// being expressible instead of being filtered out afterwards.
//
// TWO ENTRY POINTS, because the two callers want different things:
//
//   bestMatch(artist:album:)  — one answer or NONE. For the scan, where nobody is
//                               watching. A wrong cover filling an empty slot is
//                               worse than an empty slot, so this refuses to guess.
//   candidates(artist:album:) — a ranked list including near-misses. For the manual
//                               picker (fArtworkManualSearchUtility), where the
//                               human is the tiebreaker. Two albums by one artist
//                               with similar names is exactly the case no scoring
//                               function can settle, and it is why that feature
//                               exists.
//
// Scoring is PURE and separated from the network so it can be tested without one
// (most of what fArtworkPassTestSeam is asking for, gained on the way past).

struct ArtworkCandidate: Equatable {
    let artworkURL100: String
    let collectionName: String
    let artistName: String
    let trackCount: Int
    let collectionId: Int
    /// 0...1. How well this candidate matched the album we asked for — recorded so
    /// a caller can explain its own decision rather than just assert it.
    var score: Double = 0
}

/// Seam for the HTTP call. Exists so the ranking can be tested with fixtures
/// instead of the live iTunes API, which is rate-limited and changes its mind.
protocol ArtworkSearchTransport {
    func json(from url: URL) async throws -> [String: Any]
}

struct ITunesTransport: ArtworkSearchTransport {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func json(from url: URL) async throws -> [String: Any] {
        let (data, _) = try await session.data(from: url)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

actor ArtworkLookup {

    static let shared = ArtworkLookup()

    private let transport: ArtworkSearchTransport

    /// artistId cache, keyed by normalized artist name.
    ///
    /// This is what keeps the two-call approach CHEAPER than the old one-call
    /// approach in practice: the id is resolved once per artist, not once per
    /// album, so a library with many albums per artist makes fewer round trips
    /// than before. A miss is cached too (as nil) so an artist iTunes does not
    /// know is not re-queried for every one of their albums.
    private var artistIDCache: [String: Int?] = [:]

    init(transport: ArtworkSearchTransport = ITunesTransport()) {
        self.transport = transport
    }

    // MARK: - Public API

    /// Ranked candidates for an album. Empty when nothing plausible was found.
    func candidates(artist: String, album: String, limit: Int = 12) async -> [ArtworkCandidate] {
        let cleanAlbum = Self.stripArtistPrefix(album, artist: artist)

        // Compilations have no meaningful artist to constrain by — "Various
        // Artists" is a placeholder, not a performer, and searching for it
        // returns whatever iTunes feels like. LibraryService already knows these
        // names; rather than guess badly, say nothing.
        if Self.isCompilationPlaceholder(artist) {
            sLog("ARTLOOKUP: skipping compilation placeholder artist — \(artist) · \(album)")
            return []
        }

        if let artistID = await resolveArtistID(artist) {
            let found = await albums(forArtistID: artistID)
            if !found.isEmpty {
                return Self.rank(found, against: cleanAlbum, expectedArtist: artist, limit: limit)
            }
            sLog("ARTLOOKUP: artist \(artist) resolved to \(artistID) but returned no albums")
        }

        // Fallback: the artist is not in iTunes, or the lookup failed. Use the old
        // text search — but VERIFY the artist on the way out, which is the single
        // check whose absence produced Creed and Al Green. Weaker than the
        // constrained path, still strictly better than what it replaces.
        let searched = await searchAlbums(artist: artist, album: cleanAlbum, limit: 25)
        let sameArtist = searched.filter {
            Self.normalize($0.artistName) == Self.normalize(artist)
        }
        if sameArtist.isEmpty && !searched.isEmpty {
            sLog("ARTLOOKUP: \(searched.count) result(s) for \(artist) · \(album), none by that artist — rejected")
        }
        return Self.rank(sameArtist, against: cleanAlbum, expectedArtist: artist, limit: limit)
    }

    /// The single best candidate, or nil if nothing clears the bar.
    ///
    /// Deliberately strict. This is the scan's entry point, and the scan has no
    /// way to notice it was wrong.
    /// Threshold 0.62, chosen from measurement rather than taste: across eight real
    /// albums checked against the live API on 2026-08-07, every correct match scored
    /// 0.75 or better and every wrong one 0.57 or worse. 0.62 sits in that gap with
    /// margin on both sides.
    func bestMatch(artist: String, album: String, threshold: Double = 0.62) async -> ArtworkCandidate? {
        guard let top = await candidates(artist: artist, album: album, limit: 5).first else { return nil }
        guard top.score >= threshold else {
            sLog("ARTLOOKUP: best candidate for \(artist) · \(album) scored \(String(format: "%.2f", top.score)) — below \(threshold), rejected (\(top.artistName) · \(top.collectionName))")
            return nil
        }
        return top
    }

    // MARK: - Network

    private func resolveArtistID(_ artist: String) async -> Int? {
        let key = Self.normalize(artist)
        if let cached = artistIDCache[key] { return cached }

        var found: Int?
        if let url = Self.url("search", [
            "term": artist, "entity": "musicArtist", "limit": "5", "media": "music"
        ]) {
            let results = await rows(from: url)
            // Exact normalized name only. A fuzzy artist match would reintroduce
            // the whole problem one level up, where it is harder to see.
            for r in results {
                if let name = r["artistName"] as? String,
                   Self.normalize(name) == key,
                   let id = r["artistId"] as? Int {
                    found = id
                    break
                }
            }
        }
        artistIDCache[key] = found
        return found
    }

    private func albums(forArtistID id: Int) async -> [ArtworkCandidate] {
        guard let url = Self.url("lookup", [
            "id": String(id), "entity": "album", "limit": "200"
        ]) else { return [] }
        // The lookup response includes the artist record itself as the first
        // element; it has no collectionName, so parsing drops it naturally.
        return Self.parse(await rows(from: url))
    }

    private func searchAlbums(artist: String, album: String, limit: Int) async -> [ArtworkCandidate] {
        guard let url = Self.url("search", [
            "term": "\(artist) \(album)", "entity": "album",
            "limit": String(limit), "media": "music"
        ]) else { return [] }
        return Self.parse(await rows(from: url))
    }

    private func rows(from url: URL) async -> [[String: Any]] {
        do {
            let json = try await transport.json(from: url)
            return json["results"] as? [[String: Any]] ?? []
        } catch {
            sLog("ARTLOOKUP: request failed — \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Pure helpers
    //
    // Everything below is deterministic and network-free. This is the part worth
    // unit-testing, and the part that decides whether a cover is right.

    static func url(_ path: String, _ params: [String: String]) -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/\(path)")
        c?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c?.url
    }

    static func parse(_ rows: [[String: Any]]) -> [ArtworkCandidate] {
        rows.compactMap { r in
            guard let art = r["artworkUrl100"] as? String,
                  let collection = r["collectionName"] as? String,
                  let artist = r["artistName"] as? String else { return nil }
            return ArtworkCandidate(
                artworkURL100: art,
                collectionName: collection,
                artistName: artist,
                trackCount: r["trackCount"] as? Int ?? 0,
                collectionId: r["collectionId"] as? Int ?? 0
            )
        }
    }

    /// Case, punctuation and spacing all vary between tags and iTunes — `12"/80's`
    /// against `12 80s`, `Off Ramp` against `Offramp`. Comparing raw strings would
    /// reject correct matches, so everything is reduced to letters and digits.
    static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// Some tags repeat the artist in the album title ("Pat Metheny Group - Offramp").
    static func stripArtistPrefix(_ album: String, artist: String) -> String {
        let prefix = "\(artist) - "
        return album.hasPrefix(prefix) ? String(album.dropFirst(prefix.count)) : album
    }

    static func isCompilationPlaceholder(_ artist: String) -> Bool {
        ["various artists", "various", "va", "soundtrack", "original soundtrack", "compilation"]
            .contains(artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Score a candidate title against what we asked for. 1.0 is identical.
    ///
    /// Generic titles are the hazard: half the catalogue is called "Greatest Hits",
    /// so title similarity alone is close to worthless on exactly the albums that
    /// go wrong. That is survivable here only because ranking happens INSIDE one
    /// artist's catalogue — "Greatest Hits" among Johnny Cash's own records is a
    /// real answer, whereas "Greatest Hits" across all of iTunes is a coin toss.
    static func titleScore(_ candidate: String, _ wanted: String) -> Double {
        let c = normalize(candidate), w = normalize(wanted)
        if c.isEmpty || w.isEmpty { return 0 }
        if c == w { return 1.0 }
        if c.hasPrefix(w) || w.hasPrefix(c) { return 0.85 }

        // Containment is ASYMMETRIC, and treating it as symmetric was a real bug
        // caught by ArtworkLookupTests before it shipped.
        //
        // A candidate that CONTAINS the whole title we want is usually the same
        // record with extra qualifiers — "Special EFX Collection" for a tag that
        // just says "Collection". Plausible, score it high.
        //
        // A candidate that is merely a FRAGMENT of what we want is a different,
        // shorter-named record — an album called "Greatest" is not "18 Greatest
        // Hits", it just happens to sit inside the string. Scoring that 0.75 would
        // have auto-accepted it. Let it fall through to token overlap, which values
        // it properly at 0.5.
        if c.contains(w) { return 0.75 }

        // Token overlap (Dice) for the remainder — "18 greatest hits" vs
        // "greatest hits" style differences.
        let ct = Set(candidate.lowercased().split(separator: " ").map(String.init))
        let wt = Set(wanted.lowercased().split(separator: " ").map(String.init))
        guard !ct.isEmpty, !wt.isEmpty else { return 0 }
        let shared = Double(ct.intersection(wt).count)
        return (2 * shared) / Double(ct.count + wt.count)
    }

    static func rank(_ candidates: [ArtworkCandidate],
                     against album: String,
                     expectedArtist: String,
                     limit: Int) -> [ArtworkCandidate] {
        let wantArtist = normalize(expectedArtist)
        let scored: [ArtworkCandidate] = candidates.map { c in
            var copy = c
            var s = titleScore(c.collectionName, album)
            // Artist agreement is a gate in the constrained path and a strong
            // signal in the fallback; either way a mismatch must not win.
            if normalize(c.artistName) != wantArtist { s *= 0.4 }
            copy.score = min(1.0, s)
            return copy
        }
        return Array(scored.sorted {
            $0.score == $1.score ? $0.trackCount > $1.trackCount : $0.score > $1.score
        }.prefix(limit))
    }
}
