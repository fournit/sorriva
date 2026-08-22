import SwiftUI

// MARK: - AppleArtistDetailView — shelves, not tabs
//
// The artist page is a stack of SECTIONS, each a header with a rail underneath, matching the
// Library's own rows and Apple Music's artist page. Tom, 2026-08-20: "match our library
// format as well as what apple does."
//
// APPLE MODELS THE SHELVES, WE DO NOT GUESS THEM. `albums`, `singles`, `compilationAlbums`
// and `appearsOnAlbums` are four separate relationships, so a compilation the artist merely
// plays on lands in Appears On rather than polluting Albums. That is why the credit filter
// used on search results is NOT applied here — Apple's own separation is better than our
// string match, and using both would hide records twice.
//
// AN EMPTY SHELF IS OMITTED, never drawn empty. Apple returns nothing for plenty of artists
// and a row of blank space reads as broken.
//
// Deliberately still absent: shuffle and repeat, which Tom deferred until the queue concept
// exists (fShuffleRepeat), and upcoming concerts, which MusicKit does not expose at all.

struct AppleArtistDetailView: View {
    /// Scroll target for the biography section.
    private static let aboutAnchor = "about"

    let artist: AppleArtist

    @EnvironmentObject private var discovery: ZoneDiscoveryService

    @State private var detail: AppleMusicKitSource.ArtistDetail?
    @State private var loading = true
    @State private var aboutExpanded = false
    /// Biography and identity from outside Apple — see ArtistInfoService.
    @State private var info: ArtistInfo?
    @State private var loadingBio = true
    @State private var pending: PendingPlay?
    /// Held so the More/Less control can put the reader back on the paragraph after a
    /// collapse — see the note there.
    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        ZStack {
            LinearGradient(colors: [.sGradientTop, .sGradientMid, .sGradientBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // THE SCROLL TARGET LIVES INSIDE THE HERO, 70pt up from its bottom.
                        //
                        // Anchoring to the `about` section itself did not work: its height is
                        // mid-animation while the scroll resolves, so the target moved under
                        // the scroll and landed wherever the paragraph happened to be that
                        // frame. Anchoring to the hero's bottom edge worked but put the first
                        // line of the biography UNDER THE STATUS BAR, because the hero
                        // deliberately ignores the top safe area — so "top of the viewport" is
                        // behind the notch.
                        //
                        // 70pt of headroom leaves the bottom sliver of the photograph showing
                        // and the text clear of the clock.
                        hero
                            .overlay(alignment: .bottom) {
                                Color.clear
                                    .frame(height: 1)
                                    .offset(y: -70)
                                    .id(Self.aboutAnchor)
                            }
                        about
                        shelves
                    }
                    .padding(.bottom, AppleLayout.bottomChrome)
                }
                .onAppear { scrollProxy = proxy }
            }
        }
        .ignoresSafeArea(edges: .top)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        // COLLAPSING HAS TO MOVE THE READER, expanding does not. Scroll offset is measured
        // from the top of the CONTENT, so removing several paragraphs from above the fold
        // leaves you as far down a page that just got shorter — somewhere in the shelves,
        // with nothing explaining why.
        //
        // AND IT MUST HAPPEN AFTER THE RELAYOUT. Scrolling in the same action that toggles
        // the state resolves the target against the still-expanded paragraph, which lands on
        // its BOTTOM once it shrinks — the first attempt did exactly that. onChange runs once
        // the new layout exists, so the anchor means what it says.
        .onChange(of: aboutExpanded) { _, expanded in
            guard !expanded else { return }
            // NO ANIMATION ON EITHER SIDE OF THIS. Three earlier attempts animated the
            // collapse and then scrolled — and each landed somewhere different, because
            // scrollTo resolves against whatever the layout happens to be that frame while
            // several hundred points of text are still shrinking. First it landed at the
            // bottom of the old paragraph, then at the top of Albums.
            //
            // Collapsing instantly makes the target unambiguous: the layout is final before
            // the scroll is asked for. Losing the collapse animation is a small price for a
            // control that goes where it says.
            scrollProxy?.scrollTo(Self.aboutAnchor, anchor: .top)
        }
        // "See all" hands the destination the rows the shelf already fetched, rather than
        // re-querying for what is sitting in memory.
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
            AppleSeeAllView(title: group.title, items: group.items) { track in
                NavigationLink {
                    AppleSongAlbumView(song: track).environmentObject(discovery)
                } label: {
                    AppleResultRow(title: track.title, subtitle: track.artist,
                                   artworkURL: track.artworkURL,
                                   trailing: AppleFormat.trackLength(track.durationSeconds))
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
        .navigationDestination(item: $seeAllArtists) { group in
            AppleSeeAllView(title: group.title, items: group.items) { other in
                NavigationLink {
                    AppleArtistDetailView(artist: other).environmentObject(discovery)
                } label: {
                    AppleResultRow(title: other.name, subtitle: other.genre ?? "Artist",
                                   artworkURL: other.artworkURL, circular: true)
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

    // MARK: - Header

    /// FULL-BLEED HERO, modelled on Apple Music's own artist page (Tom supplied a screenshot,
    /// 2026-08-20: "the artist info on top is a bit small... see if we can do something like
    /// that"). The photo runs edge to edge and under the status bar, the name sits large over
    /// its bottom-left, and Play is a circle bottom-right.
    ///
    /// The scrim is what makes this safe rather than pretty: artist photography is arbitrary,
    /// and white text over an unknown image is unreadable often enough that the gradient is
    /// load-bearing, not decoration.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            heroImage

            LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)

            HStack(alignment: .bottom, spacing: 12) {
                Text(artist.name)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)

                Spacer(minLength: 8)

                Button { playArtist() } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Color(hex: "#FC3C44")))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(height: heroHeight)
        .clipped()
    }

    private var heroHeight: CGFloat { 400 }

    @ViewBuilder
    private var heroImage: some View {
        if let url = artist.artworkURL.flatMap(URL.init(string:)) {
            CachedAsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.sSurface
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight)
            .clipped()
        } else {
            AlbumArtPlaceholder(letter: String(artist.name.prefix(1)).uppercased(),
                                size: heroHeight)
                .frame(maxWidth: .infinity)
                .frame(height: heroHeight)
                .clipped()
        }
    }

    /// The hero's Play button. An artist is not itself playable, so this asks for a zone and
    /// then plays their first album — the same meaning "Play on…" already has for an artist.
    private func playArtist() {
        pending = .artist(artist)
    }

    /// The editorial paragraph. Clamped to three lines with a "more" control, because these
    /// run long and would otherwise push every shelf below the fold.
    @ViewBuilder
    private var about: some View {
        if loadingBio && info?.bio == nil {
            // A SKELETON, not a spinner. The bio is a chain of up to five requests against
            // rate-limited services and can take seconds; without something here, "still
            // fetching" and "there is no biography" look identical, which is exactly how this
            // read as broken while it was in fact working. Tom, 2026-08-21: "show the row for
            // bio and something to indicate it is loading; an island in a subdued color,
            // pulsating."
            //
            // Shaped like the paragraph it is replacing — three lines, last one short — so the
            // page does not jump when the real text lands.
            BioSkeleton()
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 24)
        } else if let text = info?.bio, !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                // PRIMARY, not muted. This is body copy several paragraphs long sitting under
                // a dark hero image — at muted weight Tom found it "near impossible to read".
                // Muted is right for a one-line subtitle and wrong for prose.
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(.sTextPrimary)
                    .lineSpacing(3)
                    .lineLimit(aboutExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(aboutExpanded ? "Less" : "More") {
                        // Expanding animates; collapsing does not — see the onChange above.
                        if aboutExpanded {
                            aboutExpanded = false
                        } else {
                            withAnimation { aboutExpanded = true }
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.sHighlight)
                    .buttonStyle(.plain)

                    Spacer()

                    // ATTRIBUTED, on purpose. These are other people's words under other
                    // people's licences, and the reader deserves to know whether they are
                    // reading Discogs or Wikipedia — the two do not agree, and Last.fm is
                    // years out of date.
                    if let source = info?.bioSource {
                        Text(credit(source))
                            .font(.system(size: 11))
                            .foregroundColor(.sTextMuted)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 24)
        }
    }

    private func credit(_ source: ArtistInfo.BioSource) -> String {
        switch source {
        case .discogs:   return "via Discogs"
        case .wikipedia: return "via Wikipedia"
        case .lastfm:    return "via Last.fm"
        }
    }

    // MARK: - Shelves

    @ViewBuilder
    private var shelves: some View {
        if loading && detail == nil {
            HStack { Spacer(); ProgressView().tint(.sTextMuted); Spacer() }
                .padding(.top, 40)
        } else if let detail {
            albumShelf("Albums", detail.albums)
            albumShelf("Singles & EPs", detail.singles)
            albumShelf("Compilations", detail.compilations)
            topSongsShelf(detail.topSongs)
            albumShelf("Appears On", detail.appearsOn)
            playlistShelf(detail.playlists)
            similarShelf(detail.similar)
        }
    }

    @ViewBuilder
    private func albumShelf(_ title: String, _ albums: [AppleAlbum]) -> some View {
        if !albums.isEmpty {
            LibraryRow(title: title, onSeeAll: { seeAllAlbums = SeeAll(title: title, items: albums) }) {
                AppleShelfRail(items: albums) { album in
                    NavigationLink {
                        AppleAlbumDetailView(album: album).environmentObject(discovery)
                    } label: {
                        AppleAlbumCard(title: album.title,
                                       subtitle: album.year ?? album.artist,
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
    private func topSongsShelf(_ tracks: [AppleTrack]) -> some View {
        if !tracks.isEmpty {
            LibraryRow(title: "Top Songs", onSeeAll: { seeAllSongs = SeeAll(title: "Top Songs", items: tracks) }) {
                AppleSongGrid(tracks: tracks) { index, track in
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
    private func playlistShelf(_ playlists: [ApplePlaylist]) -> some View {
        if !playlists.isEmpty {
            LibraryRow(title: "Playlists", onSeeAll: { seeAllPlaylists = SeeAll(title: "Playlists", items: playlists) }) {
                AppleShelfRail(items: playlists) { playlist in
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

    /// Tapping a similar artist opens THEIR page, which loads its own similar artists — so
    /// the shelf is a way to keep walking outward rather than a dead end.
    @ViewBuilder
    private func similarShelf(_ artists: [AppleArtist]) -> some View {
        if !artists.isEmpty {
            LibraryRow(title: "Similar Artists", onSeeAll: { seeAllArtists = SeeAll(title: "Similar Artists", items: artists) }) {
                AppleShelfRail(items: artists) { other in
                    NavigationLink {
                        AppleArtistDetailView(artist: other).environmentObject(discovery)
                    } label: {
                        AppleArtistCircle(name: other.name, subtitle: other.genre,
                                          artworkURL: other.artworkURL)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - See all

    /// navigationDestination(item:) needs Hashable, and a bare array is not Identifiable —
    /// so each shelf's "See all" payload gets a small wrapper carrying its own title.
    struct SeeAll<Item: Hashable>: Identifiable, Hashable {
        let id = UUID()
        let title: String
        let items: [Item]
    }

    @State private var seeAllAlbums: SeeAll<AppleAlbum>?
    @State private var seeAllSongs: SeeAll<AppleTrack>?
    @State private var seeAllPlaylists: SeeAll<ApplePlaylist>?
    @State private var seeAllArtists: SeeAll<AppleArtist>?

    // MARK: - Behaviour

    private func load() async {
        loading = true
        detail = try? await AppleMusicKitSource.artistDetail(id: artist.id)
        loading = false

        // The biography comes from OUTSIDE Apple, and deliberately after the shelves rather
        // than with them. MusicKit declares editorialNotes and never fills it — measured with
        // and without a subscription — so this is Discogs, then Wikipedia, then Last.fm.
        //
        // Separate and last because it is a chain of up to five requests against rate-limited
        // services, and the music must not wait on prose.
        loadingBio = true
        info = await ArtistInfoService.lookup(name: artist.name)
        loadingBio = false
    }
}


// MARK: - BioSkeleton

/// The placeholder shown while an artist biography is being fetched.
///
/// Deliberately subdued and slow: this sits under a large photograph, and anything brighter or
/// faster reads as an alert rather than as patience.
private struct BioSkeleton: View {
    @State private var pulsing = false

    /// Line widths as fractions of the container — an uneven last line is what makes this read
    /// as a paragraph rather than as a loading bar.
    private let widths: [CGFloat] = [1.0, 0.96, 0.62]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, fraction in
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.sTextMuted)
                        .frame(width: geo.size.width * fraction, height: 10)
                }
                .frame(height: 10)
            }
        }
        .opacity(pulsing ? 0.28 : 0.12)
        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulsing)
        .onAppear { pulsing = true }
        .accessibilityLabel("Looking up biography")
    }
}
