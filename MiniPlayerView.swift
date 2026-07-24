import SwiftUI

// MARK: - MiniPlayerView
// Persistent collapsed playback bar. Two rows:
//   Row 1: zone picker | art | artist               volume | play/pause
//   Row 2:               track name (full width)
//
// Volume icon tap → opens Now Playing (same as tapping art/artist)
// Zone icon tap → opens ZonePickerSheet

struct MiniPlayerView: View {
    @Binding var selectedZoneID: String?
    @ObservedObject var discovery: ZoneDiscoveryService
    @ObservedObject var store: PlaybackStore
    let onTapTrack: () -> Void
    let onTapZone: () -> Void

    private var snapshot: ZonePlaybackSnapshot? {
        guard let id = selectedZoneID else { return nil }
        return store.snapshot(for: id)
    }

    private var isPlaying: Bool { snapshot?.isPlaying ?? false }

    private var trackName: String {
        guard let s = snapshot else { return "Nothing playing" }
        if !s.trackTitle.isEmpty { return s.trackTitle }
        if !s.albumName.isEmpty { return s.albumName }
        if s.isPlaying { return "Playing" }
        return "Nothing playing"
    }

    private var artistName: String {
        guard let s = snapshot else { return "Select a zone" }
        if !s.artistName.isEmpty { return s.artistName }
        return s.name
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.sSeparator)

            HStack(spacing: 10) {

                // Zone picker — spans full height
                Button(action: onTapZone) {
                    Image(systemName: "hifispeaker.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.sTextMuted)
                        .frame(width: 32)
                }
                .buttonStyle(.plain)

                // Art — spans full height
                Button(action: onTapTrack) {
                    let s = snapshot
                    let artKey = "\(s?.artAlbum?.id ?? "")-\(s?.artURL ?? "")"
                    Group {
                        if let album = s?.artAlbum {
                            AlbumArtView(album: album, size: 44)
                                .id(album.id)
                        } else if let urlStr = s?.artURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                            CachedAsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let img):
                                    img.resizable().scaledToFill()
                                default:
                                    artPlaceholder
                                }
                            }
                        } else {
                            artPlaceholder
                        }
                    }
                    .id(artKey)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                // Track + Artist stacked, tap → Now Playing
                Button(action: onTapTrack) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trackName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                            .lineLimit(1)
                        Text(artistName)
                            .font(.system(size: 12))
                            .foregroundColor(.sTextSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                // Volume icon — tap → Now Playing
                Button(action: onTapTrack) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.sTextPrimary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                // Play / Pause
                Button(action: {
                    if let id = selectedZoneID {
                        discovery.togglePlayPause(zoneID: id)
                    }
                }) {  // command still routed through discovery — PlaybackCoordinator in WP-10
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.sTextPrimary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(selectedZoneID == nil)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 28)
            .background(Color.sGradientBottom.opacity(0.97))
        }
        // Store updates trigger view refresh automatically via @ObservedObject
    }

    private var artPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.sCard)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 14))
                    .foregroundColor(.sTextMuted)
            )
    }
}
