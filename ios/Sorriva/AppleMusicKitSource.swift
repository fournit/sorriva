import Foundation
import MusicKit

// MARK: - AppleMusicKitSource
//
// THE ONLY FILE IN SORRIVA THAT IMPORTS MUSICKIT, and it must stay that way.
//
// `ios/FastTests` compiles for macOS and accepts Foundation-only files — the moment a file
// grows a framework dependency it drops out of the one-second test loop. So MusicKit lives
// here and NOTHING else sees it: this maps MusicKit's types to the plain value types in
// AppleMusicCatalog.swift at the boundary, and every screen downstream works in those.
//
// NAME COLLISIONS ARE REAL HERE. Sorriva has its own `Album`, `Artist` and `Track` GRDB
// models that shadow MusicKit's inside this module, so MusicKit's types must be written
// `MusicKit.Album`, `MusicKit.Artist` and so on. Leaving them bare compiles into a confusing
// type error rather than the obvious "wrong Album".
//
// WHY MUSICKIT AND NOT THE PUBLIC ENDPOINT. The public iTunes API reads the iTunes STORE
// catalogue, which genuinely disagrees with Apple Music's — measured 2026-08-18, one album
// reported 11 tracks and returned none while Sonos played all 11. MusicKit reads the Apple
// Music catalogue, so that class of bug goes away. It also returns artist artwork, which the
// public endpoint has no field for at all, and playlists, which it cannot return at all
// (`entity=playlist` is rejected outright — measured 2026-08-20).
//
// AUTHORIZATION, measured 2026-08-20 in the Simulator: `.authorized` with NO Apple Music
// subscription and NO signed-in Apple ID. The prompt is shown ONCE and the answer persists;
// what happens every launch is this silent call, not a dialog. Info.plist must carry
// NSAppleMusicUsageDescription or iOS terminates the app the first time it asks.
//
// IDS ARE THE SAME IDS SONOS PLAYS — the whole architecture rests on this, so it was
// measured rather than assumed (2026-08-20):
//   artist    113526                                  numeric
//   album     1523943125                              numeric, == the public collectionId
//   song      1523943437                              numeric, == the public trackId
//   playlist  pl.ebe2805581da4c409cb07eacd1c7d8ec     pl.-prefixed
// A playlist id taken straight from here was built into a Sonos address and played 21
// tracks on a speaker that had never been given it.

enum AppleMusicKitSource {

    // MARK: - Authorization

    /// What Sorriva needs to know about permission, without leaking a MusicKit type upward.
    enum Access: Equatable {
        case authorized
        /// The person said no, or the device forbids it. Both are dead ends for searching,
        /// and both are recoverable only in iOS Settings — so the UI must SAY that rather
        /// than showing an empty list that looks like a failed search.
        case denied
        case notDetermined
    }

    static var currentAccess: Access {
        map(MusicAuthorization.currentStatus)
    }

    /// Ask once. Returns immediately with the stored answer on every launch after the first.
    @discardableResult
    static func requestAccess() async -> Access {
        if case .authorized = currentAccess { return .authorized }
        return map(await MusicAuthorization.request())
    }

    private static func map(_ status: MusicAuthorization.Status) -> Access {
        switch status {
        case .authorized:     return .authorized
        case .notDetermined:  return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default:     return .denied
        }
    }

    // MARK: - Search

    /// Everything one search returns, already mapped.
    ///
    /// ONE REQUEST FILLS ALL FOUR LISTS. The screen's Artists/Albums/Songs/Playlists filter
    /// switches between these rather than re-querying, so changing tab costs nothing.
    struct Results: Equatable {
        var artists: [AppleArtist] = []
        var albums: [AppleAlbum] = []
        var songs: [AppleTrack] = []
        var playlists: [ApplePlaylist] = []

        var isEmpty: Bool {
            artists.isEmpty && albums.isEmpty && songs.isEmpty && playlists.isEmpty
        }
    }

    /// Search the catalogue.
    ///
    /// ONE REQUEST PER TYPE, RUN CONCURRENTLY — and this is not a style choice, it is a
    /// correctness fix. MEASURED 2026-08-20:
    ///
    ///     "Pat Metheny", all four types in ONE request  → 1 artist
    ///     "Pat Metheny", artists only, same limit       → 3 artists
    ///         Pat Metheny · Pat Metheny Group · Pat Metheny Trio
    ///
    /// Asking for several types in a single `MusicCatalogSearchRequest` makes Apple collapse
    /// the per-type results hard — the multi-type call returned ONE artist while the Sonos
    /// app showed two and the public iTunes endpoint returned three. Tom spotted it from the
    /// missing "Pat Metheny Group".
    ///
    /// So: four requests, issued together with `async let` so the wall-clock cost is one
    /// round trip rather than four. Each gets the full limit, which is the whole point.
    ///
    /// APPLE CAPS A SINGLE REQUEST AT 25, and "apple music does not stop at one page" (Tom),
    /// so a full list means following `nextBatch()`. That is where the time goes: pages
    /// within a type are SEQUENTIAL, because each page's cursor comes from the one before.
    /// Four pages deep on four types is a visible wait — Tom, 2026-08-20: "that takes way
    /// too long."
    ///
    /// SO RESULTS ARRIVE IN TWO PHASES. The first page of all four types is fetched
    /// concurrently and handed back immediately through `onPartial` — one round trip, and
    /// the screen has something to draw. The remaining pages then fill in behind it. The
    /// list is useful in the time one request takes while still ending up complete.
    static let pageSize = 25

    /// Which list is being asked for. Declared here so the view can drive paging without
    /// importing MusicKit.
    enum Kind: CaseIterable {
        case artists, albums, songs, playlists
    }

    /// Start a search. Returns as soon as the FIRST page of each type is in — one round
    /// trip — and the session then loads more on demand as the user scrolls.
    static func beginSearch(_ term: String) async throws -> SearchSession {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = SearchSession(term: trimmed)
        guard !trimmed.isEmpty else { return session }
        await session.loadFirstPages()
        return session
    }

    // MARK: - SearchSession
    //
    // Holds the paging cursors for one search, so results arrive the way they do in the
    // Apple Music app and in Sonos: the first page immediately, more as you scroll.
    //
    // WHY THIS SHAPE, and it is the ordering decision made concrete. Any order SORTED BY US
    // needs every result in hand before the first row can be drawn — that is what made the
    // earlier build wait several seconds. Apple's own relevance order costs nothing, because
    // each page simply APPENDS: nothing above the fold ever moves. Sorting alphabetically
    // while paging would insert new items into the middle of the list under the reader's
    // finger, which is worse than either problem it solves.
    //
    // Tom, 2026-08-20, choosing this over alphabetical once the trade was clear.
    //
    // The cursors are MusicKit types and stay private, so the view holds this object without
    // importing MusicKit.
    @MainActor
    final class SearchSession {
        let term: String
        private(set) var results = Results()

        private var artistCursor: MusicItemCollection<MusicKit.Artist>?
        private var albumCursor: MusicItemCollection<MusicKit.Album>?
        private var songCursor: MusicItemCollection<MusicKit.Song>?
        private var playlistCursor: MusicItemCollection<MusicKit.Playlist>?

        private var loading: Set<Kind> = []
        private var exhausted: Set<Kind> = []

        init(term: String) { self.term = term }

        /// Whether another page is worth asking for. False once Apple says there is no next
        /// batch, so a list that has genuinely ended stops trying.
        func hasMore(_ kind: Kind) -> Bool {
            if exhausted.contains(kind) { return false }
            switch kind {
            case .artists:   return artistCursor?.hasNextBatch ?? false
            case .albums:    return albumCursor?.hasNextBatch ?? false
            case .songs:     return songCursor?.hasNextBatch ?? false
            case .playlists: return playlistCursor?.hasNextBatch ?? false
            }
        }

        fileprivate func loadFirstPages() async {
            async let a = firstPage(term, MusicKit.Artist.self) { $0.artists }
            async let b = firstPage(term, MusicKit.Album.self) { $0.albums }
            async let s = firstPage(term, MusicKit.Song.self) { $0.songs }
            async let p = firstPage(term, MusicKit.Playlist.self) { $0.playlists }
            let (ar, al, so, pl) = await (a, b, s, p)

            artistCursor = ar; albumCursor = al; songCursor = so; playlistCursor = pl
            results = Results(
                artists: mapArtists(ar),
                albums: mapAlbums(al),
                songs: mapSongs(so),
                playlists: mapPlaylists(pl))
        }

        /// Fetch and append the next page of one type. Safe to call repeatedly — a second
        /// call while one is in flight is ignored, which matters because a scroll can fire
        /// the trigger several times.
        func loadMore(_ kind: Kind) async {
            guard !loading.contains(kind), hasMore(kind) else { return }
            loading.insert(kind)
            defer { loading.remove(kind) }

            switch kind {
            case .artists:
                guard let cursor = artistCursor,
                      let next = try? await cursor.nextBatch(), !next.isEmpty
                else { exhausted.insert(kind); return }
                artistCursor = next
                results.artists.append(contentsOf: mapArtists(next))
            case .albums:
                guard let cursor = albumCursor,
                      let next = try? await cursor.nextBatch(), !next.isEmpty
                else { exhausted.insert(kind); return }
                albumCursor = next
                results.albums.append(contentsOf: mapAlbums(next))
            case .songs:
                guard let cursor = songCursor,
                      let next = try? await cursor.nextBatch(), !next.isEmpty
                else { exhausted.insert(kind); return }
                songCursor = next
                results.songs.append(contentsOf: mapSongs(next))
            case .playlists:
                guard let cursor = playlistCursor,
                      let next = try? await cursor.nextBatch(), !next.isEmpty
                else { exhausted.insert(kind); return }
                playlistCursor = next
                results.playlists.append(contentsOf: mapPlaylists(next))
            }
        }

        // Mapping keeps Apple's order — see the note at the top of this class. The FILTER
        // still applies: it removes records the searched artist is not credited on, which is
        // what makes a Sorriva search look like an Apple Music one rather than a superset.
        private func mapArtists(_ c: MusicItemCollection<MusicKit.Artist>?) -> [AppleArtist] {
            (c ?? []).compactMap(artist(from:))
        }
        private func mapAlbums(_ c: MusicItemCollection<MusicKit.Album>?) -> [AppleAlbum] {
            (c ?? []).compactMap(album(from:))
                .filter { AppleSearchRelevance.matches(term, $0.title, $0.artist) }
        }
        private func mapSongs(_ c: MusicItemCollection<MusicKit.Song>?) -> [AppleTrack] {
            (c ?? []).compactMap(track(from:))
                .filter { AppleSearchRelevance.matches(term, $0.title, $0.artist) }
        }
        private func mapPlaylists(_ c: MusicItemCollection<MusicKit.Playlist>?) -> [ApplePlaylist] {
            (c ?? []).compactMap(playlist(from:))
        }
    }

    /// The first page of one type. Returns nil rather than throwing: one type failing — a
    /// rate limit, a transient error — must not blank the other three.
    fileprivate static func firstPage<T: MusicCatalogSearchable, R>(
        _ term: String,
        _ type: T.Type,
        _ pick: (MusicCatalogSearchResponse) -> MusicItemCollection<R>
    ) async -> MusicItemCollection<R>? {
        var request = MusicCatalogSearchRequest(term: term, types: [type])
        request.limit = pageSize
        guard let response = try? await request.response() else { return nil }
        return pick(response)
    }


    // MARK: - Detail

    /// One album with its track list.
    ///
    /// A MISSING TRACK LIST MUST NEVER DISABLE PLAY. The album still plays as a container —
    /// Sonos expands it through the service — which is the whole reason
    /// `playAppleMusicAlbum` exists. Measured on an album whose public track list came back
    /// empty while the speaker resolved all 11 tracks.
    static func album(id: String) async throws -> (album: AppleAlbum, tracks: [AppleTrack])? {
        let request = MusicCatalogResourceRequest<MusicKit.Album>(
            matching: \.id, equalTo: MusicItemID(id))
        guard let found = try await request.response().items.first else { return nil }
        guard let mapped = album(from: found) else { return nil }

        let detailed = try? await found.with([.tracks])
        let tracks = (detailed?.tracks ?? []).compactMap(track(from:))
        return (mapped, tracks)
    }

    /// The album a song belongs to.
    ///
    /// Tom's rule, 2026-08-20: tapping a track in a result list opens the ALBUM, not a track
    /// screen. Search results carry no album id — MusicKit exposes the album as a
    /// relationship that has to be asked for — so this resolves it on demand, one request at
    /// the moment of the tap rather than N requests while typing.
    static func album(forSong id: String) async throws -> (album: AppleAlbum, tracks: [AppleTrack])? {
        let request = MusicCatalogResourceRequest<MusicKit.Song>(
            matching: \.id, equalTo: MusicItemID(id))
        guard let song = try await request.response().items.first else { return nil }
        guard let albumId = try await song.with([.albums]).albums?.first?.id.rawValue else { return nil }
        return try await album(id: albumId)
    }

    // MARK: - Artist page
    //
    // APPLE MODELS THE SHELVES ITSELF, which is the important part. `albums` and
    // `appearsOnAlbums` are SEPARATE relationships — the compilation an artist plays on but
    // is not credited for lives in the second one. That is exactly the case Tom found in
    // search results, and it means the artist page needs no text-matching filter at all: the
    // relationship IS the filter, and it is Apple's rather than ours.
    //
    // Read out of the MusicKit SDK interface rather than remembered. NOT AVAILABLE, so
    // nobody hunts for them: upcoming concerts (Apple Music shows them; MusicKit does not
    // expose them) and "Essential Albums" (editorial curation with no relationship behind it).

    /// The artist biography, longest form first.
    ///
    /// Apple genuinely has no notes for many artists — this returns nil honestly rather than
    /// substituting a genre string, and the page omits the section when it does.
    private static func notes(_ a: MusicKit.Artist) -> String? {
        let text = a.editorialNotes?.standard
            ?? a.editorialNotes?.short
            ?? a.editorialNotes?.tagline
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Everything the artist page draws. Each shelf is optional because Apple returns
    /// nothing for plenty of artists, and an empty shelf must be omitted rather than shown.
    struct ArtistDetail {
        var artist: AppleArtist
        var about: String?
        var albums: [AppleAlbum] = []
        var singles: [AppleAlbum] = []
        var compilations: [AppleAlbum] = []
        var topSongs: [AppleTrack] = []
        var appearsOn: [AppleAlbum] = []
        var playlists: [ApplePlaylist] = []
        var similar: [AppleArtist] = []
    }

    /// Fetch one artist and every shelf in a single relationship request.
    ///
    /// `with()` takes several relationships at once, so this is ONE round trip rather than
    /// seven. The shelves still appear as the page draws them; what does not happen is seven
    /// separate waits.
    static func artistDetail(id: String) async throws -> ArtistDetail? {
        let request = MusicCatalogResourceRequest<MusicKit.Artist>(
            matching: \.id, equalTo: MusicItemID(id))
        guard let found = try await request.response().items.first,
              let mapped = artist(from: found)
        else { return nil }

        var detail = ArtistDetail(artist: mapped)

        // Read the notes from the BASE artist, before the relationship fetch. They are a
        // plain property rather than a relationship, and taking them only off the `with()`
        // result meant a failed relationship load silently took the biography with it.
        detail.about = notes(found)

        let full = try? await found.with([
            .albums, .singles, .compilationAlbums, .topSongs,
            .appearsOnAlbums, .playlists, .similarArtists,
        ])
        guard let full else { return detail }

        // Prefer the fuller copy when it arrives, but never downgrade to nil.
        detail.about = notes(full) ?? detail.about
        detail.albums = (full.albums ?? []).compactMap(album(from:))
        detail.singles = (full.singles ?? []).compactMap(album(from:))
        detail.compilations = (full.compilationAlbums ?? []).compactMap(album(from:))
        detail.topSongs = (full.topSongs ?? []).compactMap(track(from:))
        detail.appearsOn = (full.appearsOnAlbums ?? []).compactMap(album(from:))
        detail.playlists = (full.playlists ?? []).compactMap(playlist(from:))
        detail.similar = (full.similarArtists ?? []).compactMap(artist(from:))
        return detail
    }

    /// One playlist with its tracks.
    static func playlist(id: String) async throws -> (playlist: ApplePlaylist, tracks: [AppleTrack])? {
        let request = MusicCatalogResourceRequest<MusicKit.Playlist>(
            matching: \.id, equalTo: MusicItemID(id))
        guard let found = try await request.response().items.first else { return nil }
        guard let mapped = playlist(from: found) else { return nil }

        let detailed = try? await found.with([.tracks])
        let tracks = (detailed?.tracks ?? []).compactMap(track(from:))
        return (mapped, tracks)
    }

    // MARK: - Mapping

    /// Artwork as a URL string at a given edge length. MusicKit builds the URL for us rather
    /// than exposing a template, so the size is chosen here rather than at display time.
    private static func artwork(_ art: Artwork?, size: Int) -> String? {
        art?.url(width: size, height: size)?.absoluteString
    }

    static func artist(from a: MusicKit.Artist) -> AppleArtist? {
        AppleArtist(id: a.id.rawValue,
                    name: a.name,
                    // 1000, not 400 — this same URL backs the full-bleed hero on the artist
                    // page, where a 400px image is visibly soft across the whole screen.
                    artworkURL: artwork(a.artwork, size: 1000),
                    genre: a.genreNames?.first)
    }

    static func album(from a: MusicKit.Album) -> AppleAlbum? {
        // The catalogue id is numeric, verified 2026-08-20 — and it is the same number the
        // Sonos container address is built from. A non-numeric id means this is a LIBRARY
        // album rather than a catalogue one, which cannot be addressed this way, so it is
        // dropped rather than shown as something that will fail to play.
        guard let id = Int(a.id.rawValue) else { return nil }
        return AppleAlbum(
            id: id,
            title: a.title,
            artist: a.artistName,
            artistId: nil,
            artworkBase: artwork(a.artwork, size: 600),
            year: a.releaseDate.map { String(Calendar.current.component(.year, from: $0)) },
            genre: a.genreNames.first,
            trackCount: a.trackCount,
            copyright: a.copyright,
            releaseDate: a.releaseDate)
    }

    static func track(from s: MusicKit.Song) -> AppleTrack? {
        guard let id = Int(s.id.rawValue) else { return nil }
        return AppleTrack(
            id: id,
            title: s.title,
            artist: s.artistName,
            trackNumber: s.trackNumber ?? 0,
            discNumber: s.discNumber ?? 1,
            durationSeconds: Int(s.duration ?? 0),
            isStreamable: true,
            artworkURL: artwork(s.artwork, size: 200))
    }

    /// A playlist's entries are `Track`, an enum over song and music-video. Only songs are
    /// addressable as Apple Music tracks, so videos are dropped.
    static func track(from t: MusicKit.Track) -> AppleTrack? {
        guard case .song(let s) = t else { return nil }
        return track(from: s)
    }

    static func playlist(from p: MusicKit.Playlist) -> ApplePlaylist? {
        ApplePlaylist(id: p.id.rawValue,
                      name: p.name,
                      curator: p.curatorName,
                      artworkURL: artwork(p.artwork, size: 600),
                      description: p.standardDescription ?? p.shortDescription)
    }
}
