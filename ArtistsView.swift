import SwiftUI
import GRDB

// MARK: - ArtistsView

struct ArtistsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var artists: [Artist] = []
    @State private var contextArtist: Artist? = nil

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationView {
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
                                NavigationLink(destination: ArtistDetailView(artist: artist)) {
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
                                .onLongPressGesture { contextArtist = artist }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 32)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear { loadArtists() }
        .confirmationDialog(
            contextArtist?.name ?? "",
            isPresented: Binding(get: { contextArtist != nil }, set: { if !$0 { contextArtist = nil } }),
            titleVisibility: .visible
        ) {
            Button("Add to Favorites") { contextArtist = nil }
            Button("Play on...") { contextArtist = nil }
            Button("Cancel", role: .cancel) { contextArtist = nil }
        }
        .navigationViewStyle(.stack)
        }
    }

    private func loadArtists() {
        artists = (try? SorrivaDatabase.shared.allArtists()) ?? []
    }
}

// MARK: - ArtistDetailView

struct ArtistDetailView: View {
    let artist: Artist
    @Environment(\.dismiss) private var dismiss
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
                                    NavigationLink(destination: AlbumDetailView(album: album)) {
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
