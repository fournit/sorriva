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
    let onTapTrack: () -> Void
    let onTapZone: () -> Void

    private var zone: SonosZone? {
        guard let id = selectedZoneID else { return nil }
        return discovery.zones.first(where: { $0.id == id })
    }

    private var isPlaying: Bool { zone?.isPlaying ?? false }

    private var trackName: String {
        if let z = zone {
            if !z.currentTrack.isEmpty { return z.currentTrack }
            if !z.stationName.isEmpty { return z.stationName }
            if isPlaying { return "Playing" }
        }
        return "Nothing playing"
    }

    private var artistName: String {
        if let z = zone {
            if !z.currentArtist.isEmpty { return z.currentArtist }
            if !z.currentTrack.isEmpty, !z.stationName.isEmpty { return z.stationName }
        }
        return zone?.name ?? "Select a zone"
    }

    private var artURL: String { zone?.stationLogoURL ?? "" }

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
                    Group {
                        if !artURL.isEmpty, let url = URL(string: artURL) {
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
                }) {
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
