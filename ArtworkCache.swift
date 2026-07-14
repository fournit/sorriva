import Foundation
import UIKit

// MARK: - ArtworkCache
// Fetches album artwork from iTunes Search API and caches to device storage.
// Called during scan finalization — runs in background, staggered to respect API limits.
//
// Storage layout:
//   {documentsDir}/artwork/{albumId}_thumb.jpg  — 300px thumbnail
//   {documentsDir}/artwork/{albumId}_full.jpg   — 600px full size
//
// iTunes Search API is free, no auth required.
// Rate limit: ~20 requests/minute — we stagger at 3s intervals.
// Source priority (per product spec): embedded tags → MusicBrainz CAA → iTunes Search API.
// This implementation covers iTunes Search API only — the fallback tier.
// Embedded tag extraction and MusicBrainz CAA are deferred to deep scanner (iPad/ATV).

actor ArtworkCache {

    static let shared = ArtworkCache()

    private let session = URLSession.shared
    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Public API

    /// Fetch artwork for all albums that don't have it yet.
    /// Called after scan completes — runs staggered in background.
    func fetchMissingArtwork() async {
        let albums = (try? SorrivaDatabase.shared.albumsWithoutArtwork()) ?? []
        guard !albums.isEmpty else { return }

        print("ARTWORK: fetching art for \(albums.count) albums")

        for album in albums {
            await fetchArtwork(for: album)
            // Stagger — 3 seconds between requests to respect iTunes API rate limit
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }

        print("ARTWORK: fetch complete")
    }

    /// Fetch artwork for a single album. Called directly after a new source is added
    /// if we want to pre-warm a specific album.
    func fetchArtwork(for album: Album) async {
        // Skip if already cached
        if album.artPathThumb != nil { return }

        guard let url = searchURL(artist: album.artistName, album: album.title) else { return }

        do {
            let (data, _) = try await session.data(from: url)
            guard let artworkURL = parseArtworkURL(from: data) else {
                print("ARTWORK: no match — \(album.artistName) · \(album.title)")
                return
            }

            let thumbURL = artworkURL.replacingOccurrences(of: "100x100", with: "300x300")
            let fullURL  = artworkURL.replacingOccurrences(of: "100x100", with: "600x600")

            let thumbPath = try await downloadAndSave(urlString: thumbURL, albumId: album.id, suffix: "thumb")
            let fullPath  = try await downloadAndSave(urlString: fullURL,  albumId: album.id, suffix: "full")

            try? SorrivaDatabase.shared.updateAlbumArtwork(
                albumId: album.id,
                thumbPath: thumbPath,
                fullPath: fullPath
            )

            print("ARTWORK: cached — \(album.artistName) · \(album.title)")

            // Notify UI to reload artwork
            await MainActor.run {
                NotificationCenter.default.post(name: .artworkDidUpdate, object: album.id)
            }

        } catch {
            print("ARTWORK: error — \(album.artistName) · \(album.title): \(error.localizedDescription)")
        }
    }

    // MARK: - Image loading for UI

    /// Load thumbnail from disk. Returns nil if not yet cached.
    func thumbnail(for album: Album) -> UIImage? {
        guard let path = album.artPathThumb else { return nil }
        return UIImage(contentsOfFile: path)
    }

    /// Load full image from disk. Returns nil if not yet cached.
    func fullImage(for album: Album) -> UIImage? {
        guard let path = album.artPathFull else { return nil }
        return UIImage(contentsOfFile: path)
    }

    // MARK: - Private

    private func searchURL(artist: String, album: String) -> URL? {
        // Strip leading "Artist - " prefix from album title if present
        // e.g. "Stan Getz - This Is Jazz 14" → "This Is Jazz 14"
        let prefix = "\(artist) - "
        let cleanAlbum = album.hasPrefix(prefix) ? String(album.dropFirst(prefix.count)) : album
        let query = "\(artist) \(cleanAlbum)"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=album&limit=1&media=music")
    }

    private func parseArtworkURL(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let artworkUrl = first["artworkUrl100"] as? String else {
            return nil
        }
        return artworkUrl
    }

    private func downloadAndSave(urlString: String, albumId: String, suffix: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw ArtworkError.invalidURL
        }

        let (data, _) = try await session.data(from: url)

        let dir = artworkDirectory()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let filePath = dir.appendingPathComponent("\(albumId)_\(suffix).jpg")
        try data.write(to: filePath)

        return filePath.path
    }

    private func artworkDirectory() -> URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("artwork")
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let artworkDidUpdate = Notification.Name("SorrivaArtworkDidUpdate")
}

// MARK: - Errors

private enum ArtworkError: Error {
    case invalidURL
}

// MARK: - SwiftUI Image helper

import SwiftUI

/// AsyncImage-style view that loads from ArtworkCache first, then falls back to placeholder.
struct AlbumArtView: View {
    let album: Album
    let size: CGFloat
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
            } else {
                AlbumArtPlaceholder(letter: album.title.first.map(String.init) ?? "?", size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.089))
        .onAppear { loadImage() }
        .onReceive(NotificationCenter.default.publisher(for: .artworkDidUpdate)) { note in
            if let updatedId = note.object as? String, updatedId == album.id {
                loadImage()
            }
        }
    }

    private func loadImage() {
        Task {
            let img = await ArtworkCache.shared.thumbnail(for: album)
            await MainActor.run { image = img }
        }
    }
}

/// Circular artist avatar placeholder — initial letter on dark surface.
struct ArtistAvatarView: View {
    let artist: Artist
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.sCard)
                .frame(width: size, height: size)
            Text(artist.name.first.map(String.init) ?? "?")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundColor(.sBrass)
        }
        .frame(width: size, height: size)
    }
}

/// Shared placeholder — dark card surface with brass initial letter.
struct AlbumArtPlaceholder: View {
    let letter: String
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.089)
                .fill(Color.sCard)
                .frame(width: size, height: size)
            Text(letter.uppercased())
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundColor(.sBrass)
        }
        .frame(width: size, height: size)
    }
}
