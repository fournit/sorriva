import SwiftUI

// MARK: - AppleSongAlbumView
//
// Tapping a SONG in a result list opens the ALBUM it belongs to. Tom, 2026-08-20: "From Track
// listing tapping the track brings you to album detail and long press brings up context menu
// with Play on..."
//
// The album id is not in the search results — MusicKit exposes the album as a relationship
// that has to be asked for — so it is resolved here, at the moment of the tap. One request
// when you tap, rather than one per row while you type.
//
// This is a resolver, not a screen: it shows a spinner and then becomes AppleAlbumDetailView.

struct AppleSongAlbumView: View {
    let song: AppleTrack

    @EnvironmentObject private var discovery: ZoneDiscoveryService

    @State private var album: AppleAlbum?
    @State private var loading = true

    var body: some View {
        Group {
            if let album {
                AppleAlbumDetailView(album: album)
                    .environmentObject(discovery)
            } else {
                ZStack {
                    LinearGradient(colors: [.sGradientTop, .sGradientMid, .sGradientBottom],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                    if loading {
                        ProgressView().tint(.sTextMuted)
                    } else {
                        // A song can exist without a reachable album — a single, or an item
                        // whose album is not in this storefront. Say so rather than spinning.
                        VStack(spacing: 10) {
                            Text("No album for this song")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.sTextPrimary)
                            Text("Apple Music didn't return an album for “\(song.title)”. "
                                 + "You can still play the song from the search results.")
                                .font(.system(size: 13))
                                .foregroundColor(.sTextMuted)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 40)
                    }
                }
                .navigationTitle(song.title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            if let found = try? await AppleMusicKitSource.album(forSong: String(song.id)) {
                album = found.album
            }
            loading = false
        }
    }
}
