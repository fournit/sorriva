import SwiftUI

// MARK: - Apple Music shelves
//
// The pieces the Apple Music screens are built from: a horizontal rail of album cards, a
// rail of artist circles, a two-column song grid, and the full-screen list behind "See all".
//
// SHARED ON PURPOSE. Search results and the artist page draw the same shelves from the same
// components, so the two screens cannot drift apart — the mistake the Library made by
// inlining the same artist cell twice at two different sizes.
//
// The section header itself is `LibraryRow`, already in LibraryView: bold title, chevron,
// "See all". Reused rather than reproduced, so an Apple shelf and a Library shelf are
// visibly the same object. Tom, 2026-08-20: "match our library format as well as what apple
// does."

// MARK: - Layout constants

enum AppleLayout {
    /// How much of the bottom of the screen the floating chrome covers.
    ///
    /// The tab bar and mini-player float ABOVE content rather than inseting it, so every
    /// scrolling Apple screen has to leave room or its last row is unreadable. 96 was the
    /// first guess and was too short — the album footer sat behind the bar. Measured off the
    /// running app: the bar starts around 165pt from the bottom, so this leaves a margin.
    static let bottomChrome: CGFloat = 180
}

// MARK: - AppleAlbumCard

/// One album in a horizontal rail — cover, title, subtitle beneath.
struct AppleAlbumCard: View {
    let title: String
    let subtitle: String
    let artworkURL: String?
    var size: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AppleArtworkView(url: artworkURL, fallbackLetter: title, size: size)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.sTextPrimary)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.sTextMuted)
                .lineLimit(1)
        }
        .frame(width: size)
        .contentShape(Rectangle())
    }
}

// MARK: - AppleArtistCircle

struct AppleArtistCircle: View {
    let name: String
    let subtitle: String?
    let artworkURL: String?
    var size: CGFloat = 110

    var body: some View {
        VStack(spacing: 6) {
            AppleArtworkView(url: artworkURL, fallbackLetter: name, size: size)
                .clipShape(Circle())
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.sTextPrimary)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.sTextMuted)
                    .lineLimit(1)
            }
        }
        .frame(width: size)
        .contentShape(Rectangle())
    }
}

// MARK: - AppleSongCell

/// One song in the two-column grid. Deliberately compact — the grid shows six at a time, so
/// the row has to survive being half a screen wide.
struct AppleSongCell: View {
    let track: AppleTrack
    var index: Int?

    var body: some View {
        HStack(spacing: 10) {
            if let index {
                Text("\(index)")
                    .font(.system(size: 12))
                    .foregroundColor(.sTextMuted)
                    .frame(width: 16, alignment: .trailing)
            }
            AppleArtworkView(url: track.artworkURL, fallbackLetter: track.title, size: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.sTextPrimary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 11))
                    .foregroundColor(.sTextMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - AppleArtworkView

/// Artwork with a placeholder, cached. Uses CachedAsyncImage rather than AsyncImage because
/// rails recycle their cells and a plain AsyncImage refetches the same cover every time,
/// which is what made the old Discover list flicker.
struct AppleArtworkView: View {
    let url: String?
    let fallbackLetter: String
    let size: CGFloat

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url) {
                CachedAsyncImage(url: parsed) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
    }

    private var placeholder: some View {
        AlbumArtPlaceholder(letter: String(fallbackLetter.prefix(1)).uppercased(), size: size)
    }
}

// MARK: - AppleShelfRail

/// A horizontal rail under a section header. Generic so albums, playlists and artists all
/// use one scroll container with one set of insets.
struct AppleShelfRail<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(items) { item in cell(item) }
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - AppleSongGrid

/// Top songs as a two-column grid, three rows deep — the shape Tom sketched, and the shape
/// Apple Music uses. Falls back to however many there are when Apple returns fewer.
struct AppleSongGrid<Cell: View>: View {
    let tracks: [AppleTrack]
    var rows: Int = 3
    @ViewBuilder let cell: (Int, AppleTrack) -> Cell

    /// Column width, deliberately well short of the screen so the next column is genuinely
    /// READABLE at the right edge rather than a sliver — its artwork and the start of its
    /// title both show. A first attempt used width − 76, which on a 402pt phone left 326pt
    /// for the column and a peek too small to register. Tom, 2026-08-20: "you made the
    /// columns wider so now you don't even see the second column except for a little peak."
    ///
    /// A fraction rather than a fixed inset, so it holds on an iPad and on the small phones.
    private var columnWidth: CGFloat { UIScreen.main.bounds.width * 0.65 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(52), spacing: 10), count: rows),
                      spacing: 16) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    cell(index + 1, track)
                        .frame(width: columnWidth, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - AppleSeeAllView

/// The full list behind a "See all". One screen serves every shelf: it is handed already
/// fetched rows rather than a query, because the shelf that opened it already has them.
struct AppleSeeAllView<Item: Identifiable, Row: View>: View {
    let title: String
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        ZStack {
            LinearGradient(colors: [.sGradientTop, .sGradientMid, .sGradientBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            List {
                ForEach(items) { item in
                    row(item)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: AppleLayout.bottomChrome) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - AppleMusicPlay
//
// Starting playback of anything Apple, from anywhere. Shared because search results, the
// artist page, album detail and playlist detail all offer the same "Play on…" and must not
// each grow their own copy of the token lookup and the optimistic declare.

enum AppleMusicPlay {

    /// Play whatever the long press asked for, on the chosen zone.
    ///
    /// Returns false when the household has no Apple Music token — which is not a failure to
    /// retry, it means no Apple Music favourite has been saved in the Sonos app yet.
    @discardableResult
    static func start(_ play: PendingPlay, on zone: SonosZone, hosts: [String]) async -> Bool {
        guard let token = await AppleMusicPlayback.token(hosts: hosts) else { return false }

        PlaybackStore.shared.declareTransport(zoneID: zone.id, playing: true)

        switch play {
        case .album(let a):
            return await SonosCommands.playAppleMusicAlbum(
                collectionId: a.id, title: a.title, token: token, on: zone)
        case .playlist(let p):
            return await SonosCommands.playAppleMusicPlaylist(
                playlistId: p.id, title: p.name, token: token, on: zone)
        case .song(let s):
            return await SonosCommands.playAppleMusicTracks(
                [(id: s.id, title: s.title)], token: token, on: zone)
        case .artist(let artist):
            // An artist is not itself playable. Their first album is what "play this artist"
            // can honestly mean without a radio station to start.
            guard let detail = try? await AppleMusicKitSource.artistDetail(id: artist.id),
                  let first = detail.albums.first
            else { return false }
            return await SonosCommands.playAppleMusicAlbum(
                collectionId: first.id, title: first.title, token: token, on: zone)
        }
    }
}

// MARK: - Formatting

enum AppleFormat {

    /// "38 min", "1 hr 44 min" — the footer under a track listing.
    static func duration(_ seconds: Int) -> String? {
        guard seconds > 0 else { return nil }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    /// "12 March 1976".
    static func releaseDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: date)
    }

    /// "8 tracks", "1 track".
    static func trackCount(_ n: Int) -> String? {
        guard n > 0 else { return nil }
        return "\(n) track\(n == 1 ? "" : "s")"
    }

    /// The footer line itself — the parts that exist, joined. Returns nil when nothing is
    /// known, so the caller can omit the row rather than draw an empty separator.
    static func footer(_ parts: [String?]) -> String? {
        let kept = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: " · ")
    }

    /// "3:52".
    static func trackLength(_ seconds: Int) -> String? {
        guard seconds > 0 else { return nil }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
