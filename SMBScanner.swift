import Foundation
import SMBClient

// MARK: - ScanReport

struct ScanReport {
    var sourceId: String
    var sourceName: String
    var totalFiles: Int
    var tracksIndexed: Int
    var albumsFound: Int
    var artistsFound: Int
    var completedAt: Date
}

// MARK: - ScanProgress

struct ScanProgress {
    var sourceId: String
    var sourceName: String
    var phase: ScanPhase
    var filesFound: Int
    var filesScanned: Int
    var currentFile: String
    var report: ScanReport? = nil

    enum ScanPhase {
        case statting
        case scanning
        case finalizing
        case complete
    }
}

// MARK: - SMBScanner
// Background actor — path-based metadata only.
// Fast, NAS-agnostic, no file reads required.
// Tag enrichment deferred to Apple TV scanner (future).

actor SMBScanner {

    private static let audioExtensions: Set<String> = [
        "flac", "mp3", "m4a", "aac", "wav", "aiff", "aif", "alac"
    ]

    // Disc/CD subfolder patterns — these collapse into the parent album
    private static let discFolderPattern = #"^(disc|disk|cd|part)\s*\d+$"#

    // MARK: - Public API

    func statShare(source: LibrarySource) async throws -> (fileCount: Int, totalBytes: Int) {
        let client = SMBClient(host: source.host)
        try await client.login(username: source.username ?? "", password: source.password ?? "")
        defer { Task { try? await client.logoff() } }
        try await client.connectShare(source.share)
        defer { Task { try? await client.disconnectShare() } }
        return try await statDirectory(client: client, path: rootPath(source))
    }

    func scan(
        source: LibrarySource,
        progressHandler: @Sendable @escaping (ScanProgress) -> Void
    ) async throws {

        let client = SMBClient(host: source.host)
        try await client.login(username: source.username ?? "", password: source.password ?? "")
        defer { Task { try? await client.logoff() } }
        try await client.connectShare(source.share)
        defer { Task { try? await client.disconnectShare() } }

        let root = rootPath(source)

        // Phase 1: collect all audio file paths
        progressHandler(ScanProgress(
            sourceId: source.id, sourceName: source.displayName,
            phase: .statting, filesFound: 0, filesScanned: 0, currentFile: "Listing files…"
        ))

        var allFiles: [(path: String, size: Int)] = []
        try await collectAudioFiles(client: client, path: root, results: &allFiles)

        let totalFiles = allFiles.count
        let totalBytes = allFiles.reduce(0) { $0 + $1.size }

        // Phase 2: parse metadata from paths + write to DB
        try SorrivaDatabase.shared.deleteTracks(sourceId: source.id)

        var scanned = 0
        var artistCache: [String: Artist] = [:]
        var albumCache: [String: Album] = [:]

        for file in allFiles {
            let filename = (file.path as NSString).lastPathComponent
            let ext = (filename as NSString).pathExtension.lowercased()

            progressHandler(ScanProgress(
                sourceId: source.id, sourceName: source.displayName,
                phase: .scanning, filesFound: totalFiles,
                filesScanned: scanned, currentFile: filename
            ))

            let meta = parseFromPath(filePath: file.path, rootPath: root)
            let artistName = meta.artist
            let artist = try resolveArtist(name: artistName, cache: &artistCache)
            let album = try resolveAlbum(
                title: meta.album, artist: artist,
                folderPath: (file.path as NSString).deletingLastPathComponent,
                sourceId: source.id, cache: &albumCache
            )

            let now = Int(Date().timeIntervalSince1970)
            let track = Track(
                id: UUID().uuidString,
                title: meta.title,
                albumId: album.id,
                albumTitle: album.title,
                primaryArtistId: artist.id,
                artistName: artist.name,
                trackNumber: meta.trackNumber,
                discNumber: meta.discNumber,
                year: nil,
                genre: nil,
                duration: nil,
                fileFormat: ext == "aif" ? "aiff" : ext,
                filePath: file.path,
                fileSize: file.size,
                bitrate: nil,
                sampleRate: nil,
                sourceId: source.id,
                createdAt: now,
                updatedAt: now
            )

            if (try? SorrivaDatabase.shared.track(filePath: file.path)) == nil {
                try? SorrivaDatabase.shared.upsertTrack(track)
                try? SorrivaDatabase.shared.upsertTrackArtist(
                    trackId: track.id, artistId: artist.id, role: "primary"
                )
            }
            scanned += 1
        }

        // Phase 3: finalize
        progressHandler(ScanProgress(
            sourceId: source.id, sourceName: source.displayName,
            phase: .finalizing, filesFound: totalFiles, filesScanned: scanned, currentFile: "Finalizing…"
        ))

        try SorrivaDatabase.shared.deleteOrphanedAlbums()
        try SorrivaDatabase.shared.deleteOrphanedArtists()

        for artist in artistCache.values {
            try? SorrivaDatabase.shared.updateArtistCounts(artistId: artist.id)
        }
        for album in albumCache.values {
            try? SorrivaDatabase.shared.updateAlbumTrackCount(albumId: album.id)
        }

        let finalTrackCount = try SorrivaDatabase.shared.trackCount(sourceId: source.id)
        try SorrivaDatabase.shared.updateScanComplete(
            sourceId: source.id, trackCount: finalTrackCount,
            fileCount: totalFiles, totalBytes: totalBytes
        )

        let finalAlbumCount = try SorrivaDatabase.shared.albums(sourceId: source.id).count
        let report = ScanReport(
            sourceId: source.id,
            sourceName: source.displayName,
            totalFiles: totalFiles,
            tracksIndexed: finalTrackCount,
            albumsFound: finalAlbumCount,
            artistsFound: artistCache.count,
            completedAt: Date()
        )
        progressHandler(ScanProgress(
            sourceId: source.id, sourceName: source.displayName,
            phase: .complete, filesFound: totalFiles, filesScanned: scanned,
            currentFile: "", report: report
        ))
    }

    // MARK: - Path metadata parser

    private struct PathMeta {
        var artist: String
        var album: String
        var title: String
        var trackNumber: Int?
        var discNumber: Int?
    }

    /// Derive artist/album/title/track from folder structure.
    ///
    /// Expected layouts (relative to rootPath):
    ///   Artist/Album/01 Track.flac
    ///   Artist/Album/CD 1/01 Track.flac       → disc folder collapsed, album = Album
    ///   Artist - Album - 01 Track.mp3          → flat folder, parse from filename
    ///   Various Artists/Compilation/01 Track.flac
    private func parseFromPath(filePath: String, rootPath: String) -> PathMeta {
        let filename = (filePath as NSString).lastPathComponent
        let nameNoExt = (filename as NSString).deletingPathExtension

        // Get path components relative to root
        let relative = filePath
            .hasPrefix(rootPath)
            ? String(filePath.dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : filePath
        var components = relative.components(separatedBy: "/")
            .filter { !$0.isEmpty }

        // Remove filename from components
        if !components.isEmpty { components.removeLast() }

        // Collapse disc/CD subfolders — if last component matches disc pattern, remove it
        // and extract disc number
        var discNumber: Int? = nil
        if let last = components.last,
           let _ = last.range(of: Self.discFolderPattern,
                              options: [.regularExpression, .caseInsensitive]) {
            // Extract number from disc folder name
            if let num = last.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap({ Int($0) }).first {
                discNumber = num
            }
            components.removeLast()
        }

        // Parse track number from filename: leading digits + separator
        var trackNumber: Int? = nil
        var titleFromFilename = nameNoExt
        if let range = nameNoExt.range(of: #"^(\d{1,3})[\s\.\-–_]+"#,
                                        options: .regularExpression) {
            let numStr = String(nameNoExt[range])
                .trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
            trackNumber = Int(numStr)
            titleFromFilename = String(nameNoExt[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if titleFromFilename.isEmpty { titleFromFilename = nameNoExt }
        }

        // Determine artist/album based on folder depth
        switch components.count {
        case 0:
            // Flat — everything in filename: "Artist - Album - 01 Title"
            let parts = nameNoExt.components(separatedBy: " - ")
            if parts.count >= 3 {
                let artist = parts[0].trimmingCharacters(in: .whitespaces)
                let album = parts[1].trimmingCharacters(in: .whitespaces)
                var title = parts[2...].joined(separator: " - ")
                    .trimmingCharacters(in: .whitespaces)
                // Strip leading track number from title portion
                if let r = title.range(of: #"^\d{1,3}[\s\.\-–_]+"#,
                                        options: .regularExpression) {
                    let numStr = String(title[r])
                        .trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
                    trackNumber = Int(numStr)
                    title = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                return PathMeta(artist: artist, album: album,
                                title: title.isEmpty ? nameNoExt : title,
                                trackNumber: trackNumber, discNumber: discNumber)
            } else if parts.count == 2 {
                return PathMeta(artist: parts[0].trimmingCharacters(in: .whitespaces),
                                album: "Unknown Album",
                                title: titleFromFilename,
                                trackNumber: trackNumber, discNumber: discNumber)
            } else {
                return PathMeta(artist: "Unknown Artist", album: "Unknown Album",
                                title: titleFromFilename,
                                trackNumber: trackNumber, discNumber: discNumber)
            }

        case 1:
            // One folder: Artist/Track or Album/Track
            // Treat folder as artist, no album
            return PathMeta(artist: components[0], album: "Unknown Album",
                            title: titleFromFilename,
                            trackNumber: trackNumber, discNumber: discNumber)

        default:
            // Two+ folders: Artist/Album/Track (standard)
            let artist = components[components.count - 2]
            let album = components[components.count - 1]
            return PathMeta(artist: artist, album: album,
                            title: titleFromFilename,
                            trackNumber: trackNumber, discNumber: discNumber)
        }
    }

    // MARK: - Directory walk

    private func collectAudioFiles(
        client: SMBClient,
        path: String,
        results: inout [(path: String, size: Int)]
    ) async throws {
        let entries = try await client.listDirectory(path: path)
        for entry in entries {
            let name = entry.name
            guard name != "." && name != ".." && !name.hasPrefix(".") else { continue }
            let fullPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
            if entry.isDirectory {
                try await collectAudioFiles(client: client, path: fullPath, results: &results)
            } else {
                let ext = (name as NSString).pathExtension.lowercased()
                if Self.audioExtensions.contains(ext) {
                    results.append((path: fullPath, size: Int(entry.size)))
                }
            }
        }
    }

    private func statDirectory(
        client: SMBClient,
        path: String
    ) async throws -> (fileCount: Int, totalBytes: Int) {
        var fileCount = 0
        var totalBytes = 0
        let entries = try await client.listDirectory(path: path)
        for entry in entries {
            let name = entry.name
            guard name != "." && name != ".." && !name.hasPrefix(".") else { continue }
            let fullPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
            if entry.isDirectory {
                let sub = try await statDirectory(client: client, path: fullPath)
                fileCount += sub.fileCount
                totalBytes += sub.totalBytes
            } else {
                let ext = (name as NSString).pathExtension.lowercased()
                if Self.audioExtensions.contains(ext) {
                    fileCount += 1
                    totalBytes += Int(entry.size)
                }
            }
        }
        return (fileCount, totalBytes)
    }

    // MARK: - Artist / Album resolution

    private func resolveArtist(
        name: String,
        cache: inout [String: Artist]
    ) throws -> Artist {
        if let cached = cache[name] { return cached }
        if let existing = try SorrivaDatabase.shared.artist(named: name) {
            cache[name] = existing
            return existing
        }
        let now = Int(Date().timeIntervalSince1970)
        let artist = Artist(
            id: UUID().uuidString,
            name: name,
            sortName: makeSortName(name),
            imageURL: nil,
            albumCount: 0,
            trackCount: 0,
            createdAt: now,
            updatedAt: now
        )
        try SorrivaDatabase.shared.upsertArtist(artist)
        cache[name] = artist
        return artist
    }

    private func resolveAlbum(
        title: String,
        artist: Artist,
        folderPath: String,
        sourceId: String,
        cache: inout [String: Album]
    ) throws -> Album {
        let cacheKey = "\(artist.id)|\(title)"
        if let cached = cache[cacheKey] { return cached }
        if let existing = try SorrivaDatabase.shared.album(title: title, artistId: artist.id) {
            cache[cacheKey] = existing
            return existing
        }
        let now = Int(Date().timeIntervalSince1970)
        let album = Album(
            id: UUID().uuidString,
            title: title,
            sortTitle: makeSortName(title),
            primaryArtistId: artist.id,
            artistName: artist.name,
            year: nil,
            genre: nil,
            artPath: nil,
            trackCount: 0,
            sourceId: sourceId,
            folderPath: folderPath,
            createdAt: now,
            updatedAt: now
        )
        try SorrivaDatabase.shared.upsertAlbum(album)
        try SorrivaDatabase.shared.upsertArtistAlbum(
            artistId: artist.id, albumId: album.id, role: "primary"
        )
        cache[cacheKey] = album
        return album
    }

    // MARK: - Helpers

    private func rootPath(_ source: LibrarySource) -> String {
        source.rootPath.isEmpty ? "/" : source.rootPath
    }

    private func makeSortName(_ name: String) -> String {
        let prefixes = ["The ", "A ", "An "]
        for prefix in prefixes {
            if name.hasPrefix(prefix) {
                let rest = String(name.dropFirst(prefix.count))
                return "\(rest), \(prefix.trimmingCharacters(in: .whitespaces))"
            }
        }
        return name
    }
}
