import SwiftUI

// MARK: - ApplePlaylistDetailView
//
// One of Apple's curated playlists, and its tracks.
//
// PLAY USES THE CONTAINER, not the track list — the same reason albums do. Sonos expands the
// playlist through the service, so the playlist plays even when the track list is short,
// stale or empty. A missing track list must never disable Play.
//
// PROVEN 2026-08-20: two catalogue playlists built into container addresses expanded to 21
// and 50 tracks on a speaker that had never been given them, reporting real durations. See
// AppleMusicPlayback.playlistContainerURI.
//
// These are Apple's OWN playlists and are read-only. The user's personal playlists are a
// different thing needing a signed-in subscriber, and Sorriva's own editable mixed-source
// playlists are a different thing again — neither is this screen.

struct ApplePlaylistDetailView: View {
    let playlist: ApplePlaylist

    @EnvironmentObject private var discovery: ZoneDiscoveryService

    @State private var tracks: [AppleTrack] = []
    @State private var loading = true
    @State private var showZonePicker = false
    @State private var starting = false
    @State private var needsFavorite = false
    @State private var pendingTrack: AppleTrack?

    var body: some View {
        ZStack {
            LinearGradient(colors: [.sGradientTop, .sGradientMid, .sGradientBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header
                    trackList
                }
                .padding(.bottom, AppleLayout.bottomChrome)
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("Save a Sonos favourite first", isPresented: $needsFavorite) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Save any Apple Music album or playlist as a favourite in the Sonos app. "
                 + "Sorriva reads your household's Apple Music access from it. You only do "
                 + "this once.")
        }
        .sheet(isPresented: $showZonePicker) {
            ZonePickerSheet(title: playlist.name, subtitle: playlist.curator ?? "Playlist",
                            discovery: discovery, store: PlaybackStore.shared) { zone in
                showZonePicker = false
                Task { await playWhole(on: zone) }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $pendingTrack) { track in
            ZonePickerSheet(title: track.title, subtitle: track.artist,
                            discovery: discovery, store: PlaybackStore.shared) { zone in
                pendingTrack = nil
                Task { await play(track: track, on: zone) }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 12) {
            // 300pt, matching album detail — the two screens are the same kind of object.
            AppleArtworkView(url: playlist.artworkURL, fallbackLetter: playlist.name, size: 300)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(spacing: 4) {
                Text(playlist.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.sTextPrimary)
                    .multilineTextAlignment(.center)
                if let curator = playlist.curator {
                    Text(curator)
                        .font(.system(size: 14))
                        .foregroundColor(.sTextMuted)
                }
            }

            if let description = playlist.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(.sTextMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
            }

            Button {
                showZonePicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.sTextPrimary)
                .padding(.horizontal, 30)
                .padding(.vertical, 12)
                .background(Color.sCard)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            // NOT disabled on an empty track list — see the note at the top of this file.
            .disabled(starting)
            .padding(.top, 4)
        }
        .padding(.top, 12)
        .padding(.bottom, 22)
    }

    @ViewBuilder
    private var trackList: some View {
        if loading {
            ProgressView().tint(.sTextMuted).padding(.top, 20)
        } else if tracks.isEmpty {
            Text("Apple didn't return a track list for this playlist. It will still play.")
                .font(.system(size: 13))
                .foregroundColor(.sTextMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 13))
                            .foregroundColor(.sTextMuted)
                            .frame(width: 24, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.system(size: 15))
                                .foregroundColor(.sTextPrimary)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.system(size: 13))
                                .foregroundColor(.sTextMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if track.durationSeconds > 0 {
                            Text(String(format: "%d:%02d",
                                        track.durationSeconds / 60, track.durationSeconds % 60))
                                .font(.system(size: 13))
                                .foregroundColor(.sTextMuted)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                    .sorrivaContextMenu(title: track.title, subtitle: track.artist,
                                        actions: SorrivaContextActions.appleCatalogueItem {
                                            pendingTrack = track
                                        },
                                        sheetHeight: 200)
                }
                footer
            }
        }
    }

    /// "21 tracks · 1 hr 44 min" under the last track. No release date here — a curated
    /// playlist has no single one. Tom, 2026-08-20: "total tracks and total time should be
    /// at the bottom of playlists as well."
    @ViewBuilder
    private var footer: some View {
        if let line = AppleFormat.footer([
            AppleFormat.trackCount(tracks.count),
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

    // MARK: - Behaviour

    private func load() async {
        loading = true
        if let found = try? await AppleMusicKitSource.playlist(id: playlist.id) {
            tracks = found.tracks
        }
        loading = false
    }

    private func playWhole(on zone: SonosZone) async {
        starting = true
        defer { starting = false }
        guard let token = await AppleMusicPlayback.token(hosts: discovery.zones.map(\.host))
        else { needsFavorite = true; return }

        PlaybackStore.shared.declareTransport(zoneID: zone.id, playing: true)
        _ = await SonosCommands.playAppleMusicPlaylist(
            playlistId: playlist.id, title: playlist.name, token: token, on: zone)
    }

    private func play(track: AppleTrack, on zone: SonosZone) async {
        guard let token = await AppleMusicPlayback.token(hosts: discovery.zones.map(\.host))
        else { needsFavorite = true; return }
        PlaybackStore.shared.declareTransport(zoneID: zone.id, playing: true)
        _ = await SonosCommands.playAppleMusicTracks(
            [(id: track.id, title: track.title)], token: token, on: zone)
    }
}
