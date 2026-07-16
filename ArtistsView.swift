import SwiftUI
import GRDB

// MARK: - ArtistsView

struct ArtistsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tabState: SorrivaTabBarState
    @EnvironmentObject private var discovery: ZoneDiscoveryService
    @State private var artists: [Artist] = []
    @State private var artistToRemove: Artist? = nil
    @State private var showRemoveConfirm = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("Artists")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.sTextPrimary)
                    Spacer()
                    Color.clear.frame(width: 24, height: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 56)
                .padding(.bottom, 16)

                if artists.isEmpty {
                    Spacer()
                    Text("No artists yet\nScan a music library in Settings → Local Library")
                        .font(.system(size: 15))
                        .foregroundColor(.sTextMuted)
                        .multilineTextAlignment(.center)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(artists) { artist in
                                NavigationLink(destination: ArtistDetailView(artist: artist).environmentObject(discovery)) {
                                    VStack(spacing: 6) {
                                        ArtistAvatarView(artist: artist, size: 100)
                                        Text(artist.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.sTextPrimary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                        Text("\(artist.albumCount) \(artist.albumCount == 1 ? "album" : "albums")")
                                            .font(.system(size: 11))
                                            .foregroundColor(.sTextMuted)
                                    }
                                }
                                .buttonStyle(.plain)
                                .sorrivaContextMenu(
                                    title: artist.name,
                                    subtitle: "\(artist.albumCount) \(artist.albumCount == 1 ? "album" : "albums")",
                                    actions: SorrivaContextActions.artist(artist) {
                                        artistToRemove = artist
                                        showRemoveConfirm = true
                                    },
                                    sheetHeight: 250
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 32)
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { geo in
                        geo.contentOffset.y
                    } action: { oldY, newY in
                        let delta = newY - oldY
                        if delta > 8 { tabState.hide() }
                        else if delta < -8 { tabState.show() }
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            tabState.show()
            loadArtists()
        }
        .alert("Remove \"\(artistToRemove?.name ?? "")\"?",
               isPresented: $showRemoveConfirm) {
            Button("Remove", role: .destructive) {
                removeArtist(artistToRemove)
                artistToRemove = nil
            }
            Button("Cancel", role: .cancel) { artistToRemove = nil }
        } message: {
            Text("This removes the artist and all their albums and tracks from your Sorriva library. Original files are not affected.")
        }
    }

    private func loadArtists() {
        artists = (try? SorrivaDatabase.shared.allArtists()) ?? []
    }

    private func removeArtist(_ artist: Artist?) {
        guard let artist else { return }
        try? SorrivaDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tracks WHERE primaryArtistId = ?", arguments: [artist.id])
            try db.execute(sql: "DELETE FROM albums WHERE primaryArtistId = ?", arguments: [artist.id])
            try db.execute(sql: "DELETE FROM artists WHERE id = ?", arguments: [artist.id])
        }
        try? SorrivaDatabase.shared.deleteOrphanedAlbums()
        try? SorrivaDatabase.shared.deleteOrphanedArtists()
        NotificationCenter.default.post(name: .libraryDidUpdate, object: nil)
        loadArtists()
    }
}

// MARK: - ArtistDetailView

struct ArtistDetailView: View {
    let artist: Artist
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var discovery: ZoneDiscoveryService
    @State private var albums: [Album] = []

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.sTextPrimary)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 56)
                    .padding(.bottom, 20)

                    VStack(spacing: 10) {
                        ArtistAvatarView(artist: artist, size: 120)
                        Text(artist.name)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.sTextPrimary)
                            .multilineTextAlignment(.center)
                        Text("\(artist.albumCount) \(artist.albumCount == 1 ? "album" : "albums") · \(artist.trackCount) \(artist.trackCount == 1 ? "track" : "tracks")")
                            .font(.system(size: 13))
                            .foregroundColor(.sTextMuted)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)

                    if !albums.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Albums")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.sTextPrimary)
                                .padding(.horizontal, 16)

                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(albums) { album in
                                    NavigationLink(destination: AlbumDetailView(album: album).environmentObject(discovery)) {
                                        AlbumGridCard(album: album)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.bottom, 48)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear { loadAlbums() }
    }

    private func loadAlbums() {
        albums = (try? SorrivaDatabase.shared.albums(artistId: artist.id)) ?? []
    }
}
