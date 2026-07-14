import SwiftUI
import GRDB
// Full album art header + track card list sorted by disc/track number.
// Tapping a track = play stub (fBasicPlayback). Long press = context menu.

struct AlbumDetailView: View {
    let album: Album
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [Track] = []
    @State private var contextTrack: Track? = nil
    @State private var showRemoveConfirm = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {

                    // Back button
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

                    // Album art — full size
                    AlbumArtView(album: album, size: 220)
                        .padding(.bottom, 20)

                    // Album title + artist
                    VStack(spacing: 4) {
                        Text(album.title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.sTextPrimary)
                            .multilineTextAlignment(.center)
                        Text(album.artistName)
                            .font(.system(size: 15))
                            .foregroundColor(.sBrass)
                        if let year = album.year {
                            Text(String(year))
                                .font(.system(size: 13))
                                .foregroundColor(.sTextMuted)
                        }
                        Text("\(tracks.count) \(tracks.count == 1 ? "track" : "tracks")")
                            .font(.system(size: 13))
                            .foregroundColor(.sTextMuted)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    // Track list
                    VStack(spacing: 8) {
                        ForEach(tracks) { track in
                            TrackCard(track: track, showAlbum: false)
                                .onLongPressGesture {
                                    contextTrack = track
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 48)
                }
            }
        }
        .onAppear { loadTracks() }
        .navigationBarHidden(true)
        .confirmationDialog(
            contextTrack?.title ?? "",
            isPresented: Binding(
                get: { contextTrack != nil },
                set: { if !$0 { contextTrack = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Add to Favorites") { contextTrack = nil }
            Button("Play on...") { contextTrack = nil }
            Button("Remove from Library", role: .destructive) {
                showRemoveConfirm = true
            }
            Button("Cancel", role: .cancel) { contextTrack = nil }
        }
        .alert("Remove \"\(contextTrack?.title ?? "")\"?",
               isPresented: $showRemoveConfirm) {
            Button("Remove", role: .destructive) {
                removeTrack(contextTrack)
                contextTrack = nil
            }
            Button("Cancel", role: .cancel) { contextTrack = nil }
        } message: {
            Text("This removes the track from your Sorriva library. The original file is not affected.")
        }
    }

    private func loadTracks() {
        tracks = (try? SorrivaDatabase.shared.tracks(albumId: album.id)) ?? []
    }

    private func removeTrack(_ track: Track?) {
        guard let track else { return }
        try? SorrivaDatabase.shared.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [track.id])
        }
        loadTracks()
    }
}

// MARK: - TrackCard
// Card row for a single track. Used in AlbumDetailView and TracksView.
// showAlbum = true shows artist · album subtitle; false shows artist only.

struct TrackCard: View {
    let track: Track
    var showAlbum: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            // Track number or music note
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.sCard)
                    .frame(width: 44, height: 44)
                if let num = track.trackNumber {
                    Text("\(num)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.sTextMuted)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 14))
                        .foregroundColor(.sTextMuted)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.sTextPrimary)
                    .lineLimit(1)
                Group {
                    if showAlbum {
                        Text("\(track.artistName) · \(track.albumTitle)")
                    } else {
                        Text(track.artistName)
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.sTextMuted)
                .lineLimit(1)
            }

            Spacer()

            // Format badge
            Text(track.fileFormat.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.sTextMuted)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.sSurface)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Image(systemName: "ellipsis")
                .font(.system(size: 16))
                .foregroundColor(.sTextMuted)
        }
        .padding(12)
        .background(Color.sCard)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
