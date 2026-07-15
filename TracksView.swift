import SwiftUI
import GRDB
// Full-screen track card list. Sort by A-Z, Artist, Album, or Recent.
// Long press shows context menu.

struct TracksView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tabState: SorrivaTabBarState
    @State private var tracks: [Track] = []
    @State private var sortMode: TrackSortMode = .title
    @State private var trackToRemove: Track? = nil
    @State private var showRemoveConfirm = false

    enum TrackSortMode: String, CaseIterable {
        case title  = "A–Z"
        case artist = "Artist"
        case album  = "Album"
        case recent = "Recent"
    }

    private var sortedTracks: [Track] {
        switch sortMode {
        case .title:  return tracks.sorted { $0.title < $1.title }
        case .artist: return tracks.sorted { $0.artistName < $1.artistName }
        case .album:  return tracks.sorted { $0.albumTitle < $1.albumTitle }
        case .recent: return tracks.sorted { $0.createdAt > $1.createdAt }
        }
    }

    var body: some View {
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
                    Text("Tracks")
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
                        ForEach(TrackSortMode.allCases, id: \.self) { mode in
                            SortChip(label: mode.rawValue, isSelected: sortMode == mode) {
                                sortMode = mode
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 12)

                if tracks.isEmpty {
                    Spacer()
                    Text("No tracks yet\nScan a music library in Settings → Local Library")
                        .font(.system(size: 15))
                        .foregroundColor(.sTextMuted)
                        .multilineTextAlignment(.center)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(sortedTracks) { track in
                                TrackCard(track: track, showAlbum: true)
                                    .sorrivaContextMenu(
                                        title: track.title,
                                        subtitle: "\(track.artistName) · \(track.albumTitle)",
                                        actions: SorrivaContextActions.track(track) {
                                            trackToRemove = track
                                            showRemoveConfirm = true
                                        },
                                        sheetHeight: 260
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
        .onAppear {
            tabState.show()
            loadTracks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidUpdate)) { _ in
            loadTracks()
        }
        .navigationBarHidden(true)
        .alert("Remove \"\(trackToRemove?.title ?? "")\"?",
               isPresented: $showRemoveConfirm) {
            Button("Remove", role: .destructive) {
                removeTrack(trackToRemove)
                trackToRemove = nil
            }
            Button("Cancel", role: .cancel) { trackToRemove = nil }
        } message: {
            Text("This removes the track from your Sorriva library. The original file is not affected.")
        }
    }

    private func loadTracks() {
        tracks = (try? SorrivaDatabase.shared.allTracks()) ?? []
    }

    private func removeTrack(_ track: Track?) {
        guard let track else { return }
        try? SorrivaDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [track.id])
        }
        loadTracks()
    }
}
