import SwiftUI

// MARK: - AppleMusicSearchView — Apple-only content
//
// The first dive out of the Discover hub. Everything here is Apple's catalogue and nothing
// else: "you tap and then you are into Apple only content" (Tom, 2026-08-19).
//
// SECTIONS, NOT TABS. Results are shelves stacked vertically — Artists, Albums, Songs,
// Playlists — each a header with a rail and a "See all", the same shape the Library uses for
// its own rows. Tom, 2026-08-20: "match our library format as well as what apple does."
//
// WHAT THIS REPLACED, and why the replacement is better rather than merely different: a row
// of filter pills, where three of the four result types were hidden behind a tap and the
// pills carried counts that became meaningless once results paged on scroll. Sections show
// every type at once and need no count to explain themselves.
//
// NO SIMILAR ARTISTS HERE. It needs one artist to be similar TO, and this screen may have
// matched three. It appears on the artist page, where the question has an answer.
//
// THE INTERACTION RULE IS UNIFORM (Tom, 2026-08-20): a TAP navigates to a detail screen; a
// LONG PRESS opens the context menu carrying "Play on…".
//
// WHY THERE IS NO SAVE. Nothing persists — Apple Music has no rows anywhere in Sorriva until
// the schema slice lands. Offering a save that silently forgets would be worse than none.

struct AppleMusicSearchView: View {
    @EnvironmentObject private var discovery: ZoneDiscoveryService

    @State private var term = ""
    @State private var results = AppleMusicKitSource.Results()
    @State private var searching = false
    @State private var searched = false
    @State private var failed = false
    @State private var access: AppleMusicKitSource.Access = .notDetermined
    @State private var pending: PendingPlay?

    @State private var seeAllAlbums: AppleArtistDetailView.SeeAll<AppleAlbum>?
    @State private var seeAllSongs: AppleArtistDetailView.SeeAll<AppleTrack>?
    @State private var seeAllPlaylists: AppleArtistDetailView.SeeAll<ApplePlaylist>?
    @State private var seeAllArtists: AppleArtistDetailView.SeeAll<AppleArtist>?

    var body: some View {
        ZStack {
            LinearGradient(colors: [.sGradientTop, .sGradientMid, .sGradientBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                searchField
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                content
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // Asked on entry, so the screen works before you type. The system shows this ONCE
        // ever — afterwards iOS returns the stored answer and nothing appears.
        .task { access = await AppleMusicKitSource.requestAccess() }
        .navigationDestination(item: $seeAllArtists) { group in
            AppleSeeAllView(title: group.title, items: group.items) { artist in
                NavigationLink {
                    AppleArtistDetailView(artist: artist).environmentObject(discovery)
                } label: {
                    AppleResultRow(title: artist.name, subtitle: artist.genre ?? "Artist",
                                   artworkURL: artist.artworkURL, circular: true)
                }
            }
        }
        .navigationDestination(item: $seeAllAlbums) { group in
            AppleSeeAllView(title: group.title, items: group.items) { album in
                NavigationLink {
                    AppleAlbumDetailView(album: album).environmentObject(discovery)
                } label: {
                    AppleResultRow(title: album.title,
                                   subtitle: [album.artist, album.year]
                                    .compactMap { $0 }.filter { !$0.isEmpty }
                                    .joined(separator: " · "),
                                   artworkURL: album.artworkURL(size: 200)?.absoluteString)
                }
            }
        }
        .navigationDestination(item: $seeAllSongs) { group in
            AppleSeeAllView(title: group.title, items: group.items) { song in
                NavigationLink {
                    AppleSongAlbumView(song: song).environmentObject(discovery)
                } label: {
                    AppleResultRow(title: song.title, subtitle: song.artist,
                                   artworkURL: song.artworkURL,
                                   trailing: AppleFormat.trackLength(song.durationSeconds))
                }
            }
        }
        .navigationDestination(item: $seeAllPlaylists) { group in
            AppleSeeAllView(title: group.title, items: group.items) { playlist in
                NavigationLink {
                    ApplePlaylistDetailView(playlist: playlist).environmentObject(discovery)
                } label: {
                    AppleResultRow(title: playlist.name,
                                   subtitle: playlist.curator ?? "Playlist",
                                   artworkURL: playlist.artworkURL)
                }
            }
        }
        .sheet(item: $pending) { play in
            ZonePickerSheet(title: play.title, subtitle: play.subtitle,
                            discovery: discovery, store: PlaybackStore.shared) { zone in
                pending = nil
                Task { await AppleMusicPlay.start(play, on: zone, hosts: discovery.zones.map(\.host)) }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            // Template-rendered so it takes the tint. The supplied wordmark is BLACK
            // artwork — drawn as-is it would be invisible on this gradient.
            Image("AppleMusicWordmark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 22)
                .foregroundColor(.sTextPrimary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(.sTextMuted)
            TextField("Artists, albums, songs, playlists", text: $term)
                .font(.system(size: 15))
                .foregroundColor(.sTextPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { runSearch() }
            if !term.isEmpty {
                Button {
                    term = ""
                    results = AppleMusicKitSource.Results()
                    searched = false; failed = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.sTextMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch access {
        case .denied:
            // Deliberately explicit. An empty list here reads as "Apple Music is broken" or
            // "nothing matched", when the only fix lives in iOS Settings.
            message("Apple Music access is off",
                    "Sorriva needs permission to search Apple's catalogue. Turn it on in "
                    + "iOS Settings → Privacy & Security → Media & Apple Music.")
        case .notDetermined:
            Spacer()
            ProgressView().tint(.sTextMuted)
            Spacer()
        case .authorized:
            authorizedContent
        }
    }

    @ViewBuilder
    private var authorizedContent: some View {
        if searching {
            Spacer()
            ProgressView().tint(.sTextMuted)
            Spacer()
        } else if failed {
            message("Couldn't reach Apple Music", "Check your connection and try again.")
        } else if searched && results.isEmpty {
            message("Nothing found", "Try a different artist, album or song.")
        } else if !searched {
            message("Find something to play",
                    "Search Apple Music by artist, album, song or playlist. Playing needs an "
                    + "Apple Music subscription on your Sonos.")
        } else {
            resultShelves
        }
    }

    private var resultShelves: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                artistShelf
                albumShelf
                songShelf
                playlistShelf
            }
            .padding(.bottom, AppleLayout.bottomChrome)
        }
    }

    // MARK: - Shelves

    @ViewBuilder
    private var artistShelf: some View {
        if !results.artists.isEmpty {
            LibraryRow(title: "Artists",
                       onSeeAll: { seeAllArtists = .init(title: "Artists", items: results.artists) }) {
                AppleShelfRail(items: results.artists) { artist in
                    NavigationLink {
                        AppleArtistDetailView(artist: artist).environmentObject(discovery)
                    } label: {
                        AppleArtistCircle(name: artist.name, subtitle: artist.genre,
                                          artworkURL: artist.artworkURL)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var albumShelf: some View {
        if !results.albums.isEmpty {
            LibraryRow(title: "Albums",
                       onSeeAll: { seeAllAlbums = .init(title: "Albums", items: results.albums) }) {
                AppleShelfRail(items: results.albums) { album in
                    NavigationLink {
                        AppleAlbumDetailView(album: album).environmentObject(discovery)
                    } label: {
                        AppleAlbumCard(title: album.title,
                                       subtitle: album.artist,
                                       artworkURL: album.artworkURL(size: 300)?.absoluteString)
                    }
                    .buttonStyle(.plain)
                    .sorrivaContextMenu(title: album.title, subtitle: album.artist,
                                        imageURL: album.artworkURL(size: 200)?.absoluteString,
                                        actions: SorrivaContextActions.appleCatalogueItem {
                                            pending = .album(album)
                                        },
                                        sheetHeight: 200)
                }
            }
        }
    }

    @ViewBuilder
    private var songShelf: some View {
        if !results.songs.isEmpty {
            LibraryRow(title: "Songs",
                       onSeeAll: { seeAllSongs = .init(title: "Songs", items: results.songs) }) {
                AppleSongGrid(tracks: results.songs) { index, track in
                    NavigationLink {
                        AppleSongAlbumView(song: track).environmentObject(discovery)
                    } label: {
                        AppleSongCell(track: track, index: index)
                    }
                    .buttonStyle(.plain)
                    .sorrivaContextMenu(title: track.title, subtitle: track.artist,
                                        imageURL: track.artworkURL,
                                        actions: SorrivaContextActions.appleCatalogueItem {
                                            pending = .song(track)
                                        },
                                        sheetHeight: 200)
                }
            }
        }
    }

    @ViewBuilder
    private var playlistShelf: some View {
        if !results.playlists.isEmpty {
            LibraryRow(title: "Playlists",
                       onSeeAll: { seeAllPlaylists = .init(title: "Playlists", items: results.playlists) }) {
                AppleShelfRail(items: results.playlists) { playlist in
                    NavigationLink {
                        ApplePlaylistDetailView(playlist: playlist).environmentObject(discovery)
                    } label: {
                        AppleAlbumCard(title: playlist.name,
                                       subtitle: playlist.curator ?? "Playlist",
                                       artworkURL: playlist.artworkURL)
                    }
                    .buttonStyle(.plain)
                    .sorrivaContextMenu(title: playlist.name, subtitle: playlist.curator,
                                        imageURL: playlist.artworkURL,
                                        actions: SorrivaContextActions.appleCatalogueItem {
                                            pending = .playlist(playlist)
                                        },
                                        sheetHeight: 200)
                }
            }
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.sTextPrimary)
            Text(detail)
                .font(.system(size: 13))
                .foregroundColor(.sTextMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Behaviour

    private func runSearch() {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searching = true; failed = false
        Task {
            do {
                // ONE ROUND TRIP TO FIRST PAINT. Each shelf shows the first page; "See all"
                // is where the full list lives. Waiting on deeper pages before drawing
                // anything is what made this slow.
                let session = try await AppleMusicKitSource.beginSearch(query)
                results = session.results
            } catch {
                results = AppleMusicKitSource.Results()
                failed = true
            }
            searched = true
            searching = false
        }
    }
}

// MARK: - PendingPlay

/// What a long press asked to play. Identifiable so one `sheet(item:)` serves every row type.
enum PendingPlay: Identifiable {
    case album(AppleAlbum)
    case song(AppleTrack)
    case playlist(ApplePlaylist)
    case artist(AppleArtist)

    var id: String {
        switch self {
        case .album(let a):    return "al-\(a.id)"
        case .song(let s):     return "sg-\(s.id)"
        case .playlist(let p): return "pl-\(p.id)"
        case .artist(let a):   return "ar-\(a.id)"
        }
    }

    var title: String {
        switch self {
        case .album(let a):    return a.title
        case .song(let s):     return s.title
        case .playlist(let p): return p.name
        case .artist(let a):   return a.name
        }
    }

    var subtitle: String {
        switch self {
        case .album(let a):    return a.artist
        case .song(let s):     return s.artist
        case .playlist(let p): return p.curator ?? "Playlist"
        case .artist(let a):   return a.genre ?? "Artist"
        }
    }
}

// MARK: - AppleResultRow

/// One result in a full-height list — the "See all" screens and anywhere a rail is the wrong
/// shape. Shared so those lists cannot drift apart.
struct AppleResultRow: View {
    let title: String
    let subtitle: String
    var artworkURL: String?
    var circular: Bool = false
    var trailing: String?

    var body: some View {
        HStack(spacing: 12) {
            AppleArtworkView(url: artworkURL, fallbackLetter: title, size: 56)
                .clipShape(circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.sTextPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.sTextMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 13))
                    .foregroundColor(.sTextMuted)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
