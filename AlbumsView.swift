import SwiftUI
import GRDB

// MARK: - AlbumsView
// Full-screen albums grid — 3 columns, sorted A-Z by default.
// Pushed via NavigationLink from LibraryView — lives inside the main NavigationView.

struct AlbumsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [Album] = []
    @State private var sortMode: AlbumSortMode = .title
    @State private var contextAlbum: Album? = nil
    @State private var showRemoveConfirm = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    enum AlbumSortMode: String, CaseIterable {
        case title  = "A–Z"
        case artist = "Artist"
        case recent = "Recent"
    }

    private var sortedAlbums: [Album] {
        switch sortMode {
        case .title:  return albums.sorted { $0.sortTitle < $1.sortTitle }
        case .artist: return albums.sorted { $0.artistName < $1.artistName }
        case .recent: return albums.sorted { $0.createdAt > $1.createdAt }
        }
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("Albums")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.sTextPrimary)
                    Spacer()
                    Color.clear.frame(width: 24, height: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 56)
                .padding(.bottom, 12)

                // Sort chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(AlbumSortMode.allCases, id: \.self) { mode in
                            SortChip(label: mode.rawValue, isSelected: sortMode == mode) {
                                sortMode = mode
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 12)

                if albums.isEmpty {
                    Spacer()
                    Text("No albums yet\nScan a music library in Settings → Local Library")
                        .font(.system(size: 15))
                        .foregroundColor(.sTextMuted)
                        .multilineTextAlignment(.center)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(sortedAlbums) { album in
                                NavigationLink(destination: AlbumDetailView(album: album)) {
                                    AlbumGridCard(album: album)
                                }
                                .buttonStyle(.plain)
                                .onLongPressGesture { contextAlbum = album }
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
        .onAppear { loadAlbums() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidUpdate)) { _ in loadAlbums() }
        .confirmationDialog(
            contextAlbum?.title ?? "",
            isPresented: Binding(get: { contextAlbum != nil }, set: { if !$0 { contextAlbum = nil } }),
            titleVisibility: .visible
        ) {
            Button("Add to Favorites") { contextAlbum = nil }
            Button("Play on...") { contextAlbum = nil }
            Button("Remove from Library", role: .destructive) { showRemoveConfirm = true }
            Button("Cancel", role: .cancel) { contextAlbum = nil }
        }
        .alert("Remove \"\(contextAlbum?.title ?? "")\"?", isPresented: $showRemoveConfirm) {
            Button("Remove", role: .destructive) { removeAlbum(contextAlbum); contextAlbum = nil }
            Button("Cancel", role: .cancel) { contextAlbum = nil }
        } message: {
            Text("This removes the album from your Sorriva library. Original files are not affected.")
        }
        .navigationViewStyle(.stack)
        }
    }

    private func loadAlbums() {
        albums = (try? SorrivaDatabase.shared.allAlbums()) ?? []
    }

    private func removeAlbum(_ album: Album?) {
        guard let album else { return }
        try? SorrivaDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tracks WHERE albumId = ?", arguments: [album.id])
            try db.execute(sql: "DELETE FROM albums WHERE id = ?", arguments: [album.id])
        }
        try? SorrivaDatabase.shared.deleteOrphanedArtists()
        NotificationCenter.default.post(name: .libraryDidUpdate, object: nil)
    }
}

// MARK: - AlbumGridCard

struct AlbumGridCard: View {
    let album: Album
    private let size: CGFloat = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumArtView(album: album, size: size)
            Text(album.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.sTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(album.artistName)
                .font(.system(size: 11))
                .foregroundColor(.sTextMuted)
                .lineLimit(1)
        }
    }
}

// MARK: - SortChip

struct SortChip: View {
    let label: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .sTextSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isSelected ? Color.sAccent : Color.sSurface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
