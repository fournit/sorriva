import SwiftUI

// MARK: - DiscoverView
//
// LIBRARY IS WHAT YOU HAVE; DISCOVER IS HOW YOU FIND WHAT YOU DO NOT. Tom, 2026-08-18.
// This tab was reserved for Deriva, and that was too narrow: searching a service's
// catalogue, querying your own library by criteria, and AI ranging across both are the
// same activity with different engines. Deriva becomes one mode in here rather than the
// whole screen — which also means it inherits a populated tab instead of justifying a
// blank one.
//
// The first tenant is Apple Music catalogue search. It needs NO account of any kind: the
// catalogue endpoints are public, and the ids they return are the ids Sonos plays. See
// AppleMusicCatalog and sonos-playback-contract.md §13.
//
// Deliberately absent: saving, favouriting, adding to a library. This screen finds
// something and plays it. Everything else is later.

struct DiscoverView: View {
    @EnvironmentObject private var discovery: ZoneDiscoveryService
    @EnvironmentObject private var tabState: SorrivaTabBarState

    @State private var term: String = ""
    @State private var albums: [AppleAlbum] = []
    @State private var searching = false
    @State private var searched = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SorrivaWordmark()
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)
            .padding(.bottom, 16)

            searchField
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            content
        }
        .background(Color.clear)
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(.sTextMuted)
            TextField("Search Apple Music", text: $term)
                .font(.system(size: 15))
                .foregroundColor(.sTextPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { runSearch() }
            if !term.isEmpty {
                Button {
                    term = ""; albums = []; searched = false; failed = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.sTextMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var content: some View {
        if searching {
            Spacer()
            ProgressView().tint(.sTextMuted)
            Spacer()
        } else if failed {
            message("Couldn't reach Apple Music",
                    "Check your connection and try again.")
        } else if searched && albums.isEmpty {
            message("Nothing found", "Try a different artist or album.")
        } else if albums.isEmpty {
            message("Find something to play",
                    "Search Apple Music by artist or album. Playback needs an Apple Music subscription on your Sonos.")
        } else {
            List {
                ForEach(albums) { album in
                    NavigationLink {
                        AppleAlbumDetailView(album: album)
                            .environmentObject(discovery)
                    } label: {
                        AppleAlbumRow(album: album)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.sTextPrimary)
            Text(detail)
                .font(.system(size: 13))
                .foregroundColor(.sTextMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Behaviour

    private func runSearch() {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searching = true; failed = false
        Task {
            do {
                albums = try await AppleMusicCatalog.searchAlbums(query)
            } catch {
                albums = []; failed = true
            }
            searched = true
            searching = false
        }
    }
}

// MARK: - AppleAlbumRow

private struct AppleAlbumRow: View {
    let album: AppleAlbum

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: album.artworkURL(size: 200)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6).fill(Color.sSurface)
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.sTextPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.sTextMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        [album.artist, album.year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
