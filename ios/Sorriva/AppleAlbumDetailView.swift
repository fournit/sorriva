import SwiftUI

// MARK: - AppleAlbumDetailView
//
// One album from Apple's catalogue, with its tracks, and a single action: play it on a
// zone. The track list comes from a public endpoint — no account, no MusicKit — which is
// why this is possible at all where Spotify's equivalent was not.
//
// PLAY IS THE ONLY CONTROL, on purpose. Saving, favouriting and adding to the library are
// the next slice; a screen that offers them before they persist anywhere would be lying.
//
// THE ALBUM IS PLAYED AS A CONTAINER, not as a list of tracks — because the track list
// is not always available. Measured 2026-08-18: the catalogue reported 11 tracks for
// Vanessa Daou's "Slow to Burn" and returned none, while Sonos resolved all 11 through
// the service. So the listing below is presentation, and its absence must NOT disable
// playback. Track-level enqueue still exists for playlists and mixed queues.

struct AppleAlbumDetailView: View {
    let album: AppleAlbum
    @EnvironmentObject private var discovery: ZoneDiscoveryService
    @Environment(\.dismiss) private var dismiss

    @State private var tracks: [AppleTrack] = []
    @State private var loading = true
    @State private var failed = false
    @State private var showZonePicker = false
    @State private var starting = false
    @State private var needsFavorite = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if loading {
                    ProgressView().tint(.sTextMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else if failed {
                    Text("Couldn't load this album.")
                        .font(.system(size: 13))
                        .foregroundColor(.sTextMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else if tracks.isEmpty {
                    Text("Apple doesn't list this album's tracks. It will still play.")
                        .font(.system(size: 13))
                        .foregroundColor(.sTextMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 32)
                } else {
                    trackList
                }
            }
            // 96, not 48. The tab bar and mini-player float ABOVE this scroll view rather
            // than inseting it, so the last tracks sat underneath them and read as clipped.
            // Tom, 2026-08-20: "tracks are buried behind the tab menu."
            .padding(.bottom, AppleLayout.bottomChrome)
        }
        .background(Color.clear)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("Apple Music needs setting up once", isPresented: $needsFavorite) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Save any Apple Music album or playlist as a favourite in the Sonos app, "
               + "then come back. Sorriva reads your household's Apple Music access from it — "
               + "the same one-time step SiriusXM and Spotify need.")
        }
        .sheet(isPresented: $showZonePicker) {
            ZonePickerSheet(title: album.title,
                            subtitle: album.artist,
                            discovery: discovery,
                            store: PlaybackStore.shared) { zone in
                showZonePicker = false
                play(on: zone)
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .center, spacing: 12) {
            // 300pt rather than 220. Tom, 2026-08-20: "album artwork on the album detail
            // page should be larger." Cached, because AsyncImage refetched this cover on
            // every appearance.
            AppleArtworkView(url: album.artworkURL(size: 600)?.absoluteString,
                             fallbackLetter: album.title, size: 300)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(spacing: 4) {
                Text(album.title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.sTextPrimary)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.sTextMuted)
            }

            Button {
                showZonePicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").font(.system(size: 13, weight: .semibold))
                    Text(starting ? "Starting…" : "Play")
                        .font(.system(size: 15, weight: .semibold))
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 11)
                .background(Color.sHighlight)
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            // NOT disabled when the track list is empty. Sonos can play albums the
            // public catalogue refuses to enumerate, and greying Play out for those hides
            // something that works.
            .disabled(starting)
            .opacity(starting ? 0.4 : 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    private var trackList: some View {
        VStack(spacing: 0) {
            ForEach(tracks) { track in
                HStack(spacing: 12) {
                    Text("\(track.trackNumber)")
                        .font(.system(size: 13))
                        .foregroundColor(.sTextMuted)
                        .frame(width: 24, alignment: .trailing)
                    Text(track.title)
                        .font(.system(size: 15))
                        .foregroundColor(.sTextPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(duration(track.durationSeconds))
                        .font(.system(size: 13))
                        .foregroundColor(.sTextMuted)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
                Divider().overlay(Color.sTextMuted.opacity(0.15)).padding(.leading, 56)
            }
            footer
        }
    }

    /// "12 March 1976 · 8 tracks · 38 min", under the last track — what Apple Music shows
    /// there. Tom, 2026-08-20. Omitted entirely when none of the three facts are known,
    /// rather than drawn as an empty line under the divider.
    ///
    /// The track count comes from the album rather than the fetched rows: Apple's own count
    /// and the rows it returns genuinely disagree, and the album's figure is the honest one.
    @ViewBuilder
    private var footer: some View {
        if let line = AppleFormat.footer([
            AppleFormat.releaseDate(album.releaseDate),
            AppleFormat.trackCount(album.trackCount > 0 ? album.trackCount : tracks.count),
            AppleFormat.duration(tracks.reduce(0) { $0 + $1.durationSeconds }),
        ]) {
            Text(line)
                .font(.system(size: 12))
                .foregroundColor(.sTextMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
        }
    }

    private var subtitle: String {
        [album.artist, album.year, album.genre]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func duration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Behaviour

    private func load() async {
        loading = true
        do {
            // MusicKit, not the public iTunes endpoint. The two catalogues genuinely
            // disagree — measured 2026-08-18, one album reported 11 tracks and returned
            // none while Sonos played all 11 — so reading the track list from a different
            // catalogue than the one Sonos plays is how that mismatch got in.
            if let found = try await AppleMusicKitSource.album(id: String(album.id)) {
                tracks = found.tracks
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
        loading = false
    }

    private func play(on zone: SonosZone) {
        starting = true
        Task {
            // The app declares what it just started, at the moment it acts — the one
            // moment it reliably knows the content and the zone together.
            PlaybackStore.shared.declareTransport(zoneID: zone.id, playing: true)
            guard let token = await AppleMusicPlayback.token(hosts: discovery.zones.map(\.host)) else {
                // Not an error to retry — the household simply has no Apple Music favorite
                // yet, and the token only exists inside one.
                needsFavorite = true
                starting = false
                return
            }
            let ok = await SonosCommands.playAppleMusicAlbum(
                collectionId: album.id, title: album.title, token: token, on: zone)
            if ok {
                // Declared from what we know now; the poll takes over within seconds and
                // reports the actual track, which may differ if the catalogue listing and
                // the service disagree about this album.
                let first = tracks.first
                let context = PlaybackContext(
                    track: first?.title ?? "", artist: album.artist, albumName: album.title,
                    duration: Double(first?.durationSeconds ?? 0), artAlbum: nil,
                    artURL: album.artworkURL(size: 600)?.absoluteString, isLocal: false)
                PlaybackStore.shared.declare(
                    zoneID: zone.id, context: context,
                    uri: AppleMusicPlayback.albumContainerURI(collectionId: album.id))
            }
            starting = false
        }
    }
}
