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

    // MARK: - In-memory image cache
    // NSCache is thread-safe and automatically evicted under memory pressure.
    // Keyed by albumId — separate caches for thumb and full so size-specific
    // eviction doesn't knock out the other size.
    // Bounded at 150 entries each (~15MB thumb, ~60MB full at typical JPEG sizes).
    private let thumbCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 150
        return c
    }()
    private let fullCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 150
        return c
    }()

    /// Evict a specific album from the in-memory cache — called when artwork is updated.
    func evictFromCache(albumId: String) {
        thumbCache.removeObject(forKey: albumId as NSString)
        fullCache.removeObject(forKey: albumId as NSString)
    }

    private init() {}

    // MARK: - Public API

    /// Fetch artwork for all albums that have no artwork at all yet.
    /// REVERTED 2026-07-27 from "just another best-wins candidate" back to
    /// gap-filling only, after a wrong iTunes match (weak/generic query,
    /// zero verification of match relevance — see bArtworkArtistQuery)
    /// overwrote correct existing folder artwork, since iTunes always claims
    /// 600×600 and that area comparison alone can't tell a right match from
    /// a wrong one. A wrong match can now only ever fill an empty slot,
    /// never destroy something that was already correct.
    /// Marker-driven and source-scoped (bArtworkPassNotResumable).
    ///
    /// Selection now also requires onlineArtAttempted == false. Without it,
    /// albums with no findable art were re-queried on EVERY pass forever —
    /// artPathThumb stays nil for those, so the "no existing art" gate alone
    /// never retires them, and each one costs a network round trip plus a 3s
    /// stagger. It also makes the pass resumable: a kill mid-pass leaves the
    /// albums already attempted marked, so a resume continues rather than
    /// starting over.
    ///
    /// Markers are reset at scan start for exactly the folders being scanned, so
    /// a rescanned album is retried and an untouched one is not.
    func fetchMissingArtwork(sourceId: String) async {
        let albums = (try? SorrivaDatabase.shared.albumsNeedingOnlineArtScan(sourceId: sourceId)) ?? []
        guard !albums.isEmpty else {
            sLog("ARTWORK: online fetch — nothing to fetch")
            return
        }

        sLog("ARTWORK: online fetch — \(albums.count) albums with no artwork yet")

        for album in albums {
            // Marked AFTER the attempt completes, so an album interrupted
            // mid-fetch stays unmarked and is retried on resume. fetchArtwork
            // swallows its own errors, so reaching this line means the attempt
            // finished — success, no match, or handled failure — all of which
            // count as attempted for this scan and must not be retried in a loop.
            await fetchArtwork(for: album)
            try? SorrivaDatabase.shared.markOnlineArtAttempted(albumId: album.id)
            // Stagger — 3 seconds between requests to respect iTunes API rate limit
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }

        sLog("ARTWORK: online fetch complete")
    }

    /// Fetch artwork for a single album. Called directly after a new source is added
    /// if we want to pre-warm a specific album.
    func fetchArtwork(for album: Album) async {
        // Skip if already cached — see fetchMissingArtwork for why this reverted
        // from a stored-area comparison back to a hard "no existing art" gate.
        guard album.artPathThumb == nil else { return }

        guard let url = searchURL(artist: album.artistName, album: album.title) else { return }

        do {
            let (data, _) = try await session.data(from: url)
            guard let artworkURL = parseArtworkURL(from: data) else {
                sLog("ARTWORK: no match — \(album.artistName) · \(album.title)")
                return
            }

            let thumbURL = artworkURL.replacingOccurrences(of: "100x100", with: "300x300")
            let fullURL  = artworkURL.replacingOccurrences(of: "100x100", with: "600x600")

            let thumbPath = try await downloadAndSave(urlString: thumbURL, albumId: album.id, suffix: "thumb")
            let fullPath  = try await downloadAndSave(urlString: fullURL,  albumId: album.id, suffix: "full")

            try? SorrivaDatabase.shared.updateAlbumArtworkWithDimensions(
                albumId: album.id, thumbPath: thumbPath, fullPath: fullPath, width: 600, height: 600
            )

            sLog("ARTWORK: online SAVED (600×600) — \(album.artistName) · \(album.title)")

            // Notify UI to reload artwork
            await MainActor.run {
                NotificationCenter.default.post(name: .artworkDidUpdate, object: album.id)
            }

        } catch {
            sLog("ARTWORK: error — \(album.artistName) · \(album.title): \(error.localizedDescription)")
        }
    }

    // MARK: - Image loading for UI

    /// Load thumbnail — checks in-memory cache first, falls back to disk.
    func thumbnail(for album: Album) -> UIImage? {
        let key = album.id as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let rel = album.artPathThumb else { return nil }
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let img = UIImage(contentsOfFile: docs.appendingPathComponent(rel).path) else { return nil }
        thumbCache.setObject(img, forKey: key)
        return img
    }

    /// Load full image — checks in-memory cache first, falls back to disk.
    func fullImage(for album: Album) -> UIImage? {
        let key = album.id as NSString
        if let cached = fullCache.object(forKey: key) { return cached }
        guard let rel = album.artPathFull else { return nil }
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let img = UIImage(contentsOfFile: docs.appendingPathComponent(rel).path) else { return nil }
        fullCache.setObject(img, forKey: key)
        return img
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

        return "artwork/\(albumId)_\(suffix).jpg"
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
                Task { await ArtworkCache.shared.evictFromCache(albumId: updatedId) }
                loadImage()
            }
        }
    }

    private func loadImage() {
        Task {
            let isThumb = size < 80
            // Check in-memory cache synchronously before hitting disk or DB
            let cached = await isThumb
                ? ArtworkCache.shared.thumbnail(for: album)
                : ArtworkCache.shared.fullImage(for: album)
            if let cached {
                await MainActor.run { image = cached }
                return
            }
            // Cache miss — re-fetch album from DB in case art path was just written
            let fresh = (try? SorrivaDatabase.shared.album(id: album.id)) ?? album
            let img = await isThumb
                ? ArtworkCache.shared.thumbnail(for: fresh)
                : ArtworkCache.shared.fullImage(for: fresh)
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
