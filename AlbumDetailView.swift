import SwiftUI
import GRDB
// Full album art header + track card list sorted by disc/track number.
// Tapping a track = play stub (fBasicPlayback). Long press = context menu.

struct AlbumDetailView: View {
    let album: Album
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var discovery: ZoneDiscoveryService
    @AppStorage("sorriva.selectedZoneID") private var selectedZoneID: String = ""
    @State private var tracks: [Track] = []
    @State private var trackToRemove: Track? = nil
    @State private var showRemoveConfirm = false
    @State private var activeSheet: ActiveSheet? = nil
    @State private var isFavorite = false

    private enum ActiveSheet: Identifiable {
        case trackPicker(Track)
        case albumPicker

        var id: String {
            switch self {
            case .trackPicker(let t): return "track-\(t.id)"
            case .albumPicker: return "album"
            }
        }
    }

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
                    .padding(.bottom, 20)

                    // MARK: — Action bar: Play, Favorite, Add to Playlist
                    HStack(spacing: 12) {

                        // Play button — tap plays on selected zone, long press picks zone
                        Button(action: {
                            guard let zone = discovery.zones.first(where: { $0.id == selectedZoneID })
                                    ?? discovery.zones.first else { return }
                            PlaybackCoordinator.shared.submit(.playAlbum(tracks, zoneID: zone.id))
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Play")
                                    .font(.system(size: 15, weight: .bold))
                                    .tracking(0.2)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 13)
                            .background(Color.sAccent)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                activeSheet = .albumPicker
                            }
                        )

                        Spacer()

                        // Favorite
                        Button(action: { isFavorite.toggle() }) {
                            Image(systemName: isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 19))
                                .foregroundColor(isFavorite ? .sBrass : .sTextSecondary)
                                .frame(width: 44, height: 44)
                                .background(Color.sSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)

                        // Add to Playlist (stub)
                        Button(action: {}) {
                            Image(systemName: "text.badge.plus")
                                .font(.system(size: 19))
                                .foregroundColor(.sTextSecondary)
                                .frame(width: 44, height: 44)
                                .background(Color.sSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    // Track list
                    VStack(spacing: 8) {
                        ForEach(tracks) { track in
                            TrackCard(track: track, showAlbum: false)
                                .onTapGesture {
                                    activeSheet = .trackPicker(track)
                                }
                                .sorrivaContextMenu(
                                    title: track.title,
                                    subtitle: album.artistName,
                                    album: album,
                                    actions: SorrivaContextActions.track(track, album: album,
                                        onPlayOn: {
                                            activeSheet = .trackPicker(track)
                                        }) {
                                        trackToRemove = track
                                        showRemoveConfirm = true
                                    },
                                    sheetHeight: 300
                                )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 48)
                }
            }
        }
        .onAppear { loadTracks() }
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
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .trackPicker(let track):
                ZonePickerSheet(
                    title: track.title,
                    subtitle: "\(track.artistName) · \(album.title)",
                    discovery: discovery,
                    store: PlaybackStore.shared,
                    selectedZoneID: nil
                ) { zone in
                    activeSheet = nil
                    Task {
                        PlaybackCoordinator.shared.submit(.playTrack(track, zoneID: zone.id))
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)

            case .albumPicker:
                ZonePickerSheet(
                    title: album.title,
                    subtitle: album.artistName,
                    discovery: discovery,
                    store: PlaybackStore.shared,
                    selectedZoneID: selectedZoneID.isEmpty ? nil : selectedZoneID
                ) { zone in
                    activeSheet = nil
                    Task {
                        PlaybackCoordinator.shared.submit(.playAlbum(tracks, zoneID: zone.id))
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func loadTracks() {
        tracks = LibraryService.shared.tracksForAlbum(album.id)
    }

    private func removeTrack(_ track: Track?) {
        guard let track else { return }
        LibraryService.shared.removeTrack(track)
        loadTracks()
    }
}

// MARK: - TrackCard
// Card row for a single track. Used in AlbumDetailView and TracksView.
// showAlbum = true shows artist · album subtitle; false shows artist only.

struct TrackCard: View {
    let track: Track
    var showAlbum: Bool = true
    var album: Album? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Artwork (TracksView) or track number (AlbumDetailView)
            if showAlbum, let album = album {
                AlbumArtView(album: album, size: 44)
            } else {
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
                .frame(width: 44, height: 44)
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
                .foregroundColor(.sTextSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.sSurface)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Duration
            if let duration = track.duration {
                Text(formatDuration(duration))
                    .font(.system(size: 11))
                    .foregroundColor(.sTextPrimary)
                    .monospacedDigit()
            }

            Image(systemName: "ellipsis")
                .font(.system(size: 16))
                .foregroundColor(.sTextMuted)
        }
        .padding(12)
        .background(Color.sCard)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
