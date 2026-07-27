import Foundation
import SMBClient
import GRDB

// MARK: - ScanReport

struct ScanReport {
    var sourceId: String
    var sourceName: String
    var totalFiles: Int
    var tracksIndexed: Int
    var albumsFound: Int
    var artistsFound: Int
    var filesSkipped: Int
    var writeFailures: Int     // DB writes that failed even after immediate retry —
                                // queued into scan_skips, same recovery path as read failures
    var artworkFound: Int       // albums with art after all passes
    var tracksRetried: Int      // skips successfully resolved
    var permanentFailures: Int  // unresolvable after 5 attempts
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

// MARK: - FolderScanResult
// Result of statting a single folder — used for incremental change detection.

struct FolderScanResult {
    var folderPath: String
    var fileCount: Int
    var totalBytes: Int
}

// MARK: - ParsedMetadata

private struct ParsedMetadata: Sendable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var duration: Double?
    var bitrate: Int?
    var sampleRate: Int?
}

// MARK: - SMBScanner
// Background actor — handles both full scans and incremental folder scans.
// Tag reading uses session.read() at maxReadSize (8MB on UNAS) — the NAS
// requires reads at its negotiated maxReadSize or it stalls.
// Only the first 64KB of the response is used for tag parsing.

actor SMBScanner {

    static let audioExtensions: Set<String> = [
        "flac", "mp3", "m4a", "aac", "wav", "aiff", "aif", "alac"
    ]

    // MARK: - Test seam
    // bScannerTestSeam — production default produces the real SMB reader,
    // so the existing `SMBScanner()` call site in ScanCoordinator is unchanged.
    // Tests inject a fixture-backed reader instead.
    private let readerFactory: @Sendable (LibrarySource) -> MediaSourceReader

    init(readerFactory: @escaping @Sendable (LibrarySource) -> MediaSourceReader = { SMBMediaSourceReader(source: $0) }) {
        self.readerFactory = readerFactory
    }

    // MARK: - Public API

    /// Quick stat of all top-level album folders under source rootPath.
    /// Returns one FolderScanResult per immediate subfolder (album level).
    /// Used by ScanCoordinator for incremental change detection.
    func statFolders(source: LibrarySource) async throws -> [FolderScanResult] {
        let reader = readerFactory(source)
        let root = rootPath(source)
        let results = try await statTopLevelFolders(reader: reader, path: root)
        if let smbReader = reader as? SMBMediaSourceReader {
            await smbReader.closeWalkConnection()
        }
        return results
    }

    /// Full scan of entire source — used for initial load and manual "Scan Now".
    func scan(
        source: LibrarySource,
        progressHandler: @Sendable @escaping (ScanProgress) -> Void
    ) async throws {
        try await scanFolders(source: source, folderPaths: nil, progressHandler: progressHandler)
    }

    /// Incremental scan of specific folders — used when change detection finds new/changed folders.
    func scanChangedFolders(
        source: LibrarySource,
        folderPaths: [String],
        progressHandler: @Sendable @escaping (ScanProgress) -> Void
    ) async throws {
        try await scanFolders(source: source, folderPaths: folderPaths, progressHandler: progressHandler)
    }

    // MARK: - Core scan implementation

    private func scanFolders(
        source: LibrarySource,
        folderPaths: [String]?,   // nil = full scan
        progressHandler: @Sendable @escaping (ScanProgress) -> Void
    ) async throws {

        let scanStart = Date()
        let scanLabel = folderPaths == nil ? "full scan" : "incremental scan"
        scanLog("SCAN: START \(scanLabel) — \(source.displayName) at \(formatTime(scanStart))")

        // Phase 1: directory walk
        progressHandler(ScanProgress(
            sourceId: source.id, sourceName: source.displayName,
            phase: .statting, filesFound: 0, filesScanned: 0,
            currentFile: folderPaths == nil ? "Listing all files…" : "Listing changed folders…"
        ))

        // Keychain-aware credential resolution now happens inside the reader
        // (SMBMediaSourceReader.init), resolved once and reused for every read.
        let reader = readerFactory(source)

        let root = rootPath(source)
        var allFiles: [(path: String, size: Int)] = []

        if let paths = folderPaths {
            // Incremental — only walk specified folders
            for folder in paths {
                if Task.isCancelled {
                    scanLog("SCAN: cancelled during folder walk")
                    throw CancellationError()
                }
                try await collectAudioFiles(reader: reader, path: folder, results: &allFiles)
            }
        } else {
            // Full scan
            try await collectAudioFiles(reader: reader, path: root, results: &allFiles)
        }

        // Directory walk is complete — tear down the shared walk connection now.
        // Per-file header reads below each open their own fresh connection.
        if let smbReader = reader as? SMBMediaSourceReader {
            await smbReader.closeWalkConnection()
        }

        let totalFiles = allFiles.count
        let totalBytes = allFiles.reduce(0) { $0 + $1.size }

        scanLog("SCAN: using per-file SMBClient connections at 64KB")

        // For incremental scans, delete existing tracks for changed folders only.
        // For full scans, do NOT delete — use upsert with filePath as idempotency key.
        // This allows interrupted scans to resume without losing already-indexed data.
        if let paths = folderPaths {
            for folder in paths {
                try await deleteTracksInFolder(folder: folder, sourceId: source.id)
            }
        }

        var scanned = 0
        var skipped = 0
        var writeFailures = 0
        var skippedPaths: [String] = []  // collected during loop, written to DB after scan completes
        var artistCache: [String: Artist] = [:]
        var albumCache:  [String: Album]  = [:]

        // Pre-compute folder groups so we can write FolderStat as each folder completes
        let folderGroups = Dictionary(grouping: allFiles) { ($0.path as NSString).deletingLastPathComponent }
        var completedInFolder: [String: Int] = [:]

        for file in allFiles {
            // WP-14: Respect task cancellation between files
            if Task.isCancelled {
                scanLog("SCAN: cancelled at file \((file.path as NSString).lastPathComponent)")
                throw CancellationError()
            }

            let filename = (file.path as NSString).lastPathComponent
            let ext = (filename as NSString).pathExtension.lowercased()

            progressHandler(ScanProgress(
                sourceId: source.id, sourceName: source.displayName,
                phase: .scanning, filesFound: totalFiles,
                filesScanned: scanned, currentFile: filename
            ))

            // Per-file fresh connection — eliminates session degradation on UNAS Pro.
            // 100ms throttle gives NAS time to release each connection before the next opens.
            var meta = ParsedMetadata()
            let headerData = await readFileHeader(reader: reader, path: file.path, fileSize: file.size)
            if let data = headerData {
                let parsed = parseTagData(data: data, ext: ext)
                if parsed.title != nil || parsed.artist != nil || parsed.album != nil || parsed.duration != nil {
                    meta = parsed
                }
            } else {
                skipped += 1
                scanLog("SCAN: skip (read failed) — \(file.path)")
                skippedPaths.append(file.path)
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms throttle

            if (scanned + 1) % 50 == 0 {
                scanLog("SCAN: [\(scanned + 1)/\(totalFiles)] progress — \(skipped) skipped so far")
            }

            let folderPath = (file.path as NSString).deletingLastPathComponent
            let (track, trackArtist) = try buildTrack(
                meta: meta, filePath: file.path, fileSize: file.size,
                rootPath: root, source: source,
                artistCache: &artistCache, albumCache: &albumCache
            )

            // Idempotent upsert keyed on filePath (WP-02) — rescans update the
            // existing row in place instead of silently failing on the UNIQUE
            // constraint. A missing track is a missing track regardless of
            // whether a read or a write failed, so a write failure here gets
            // the same scan_skips retry queue read failures already use.
            let wrote = await writeTrackWithRetry(track, trackArtistId: trackArtist.id)
            if !wrote {
                writeFailures += 1
                try? SorrivaDatabase.shared.insertScanSkip(filePath: file.path, sourceId: source.id)
            }

            // Write FolderStat immediately when all files in a folder are processed.
            // This enables resume — completed folders won't rescan on next foreground check.
            completedInFolder[folderPath, default: 0] += 1
            if let folderFiles = folderGroups[folderPath],
               completedInFolder[folderPath] == folderFiles.count {
                let folderBytes = folderFiles.reduce(0) { $0 + $1.size }
                try? SorrivaDatabase.shared.upsertFolderStat(
                    sourceId: source.id,
                    folderPath: folderPath,
                    fileCount: folderFiles.count,
                    totalBytes: folderBytes
                )
                scanLog("SCAN: folder done (\(folderFiles.count) tracks) — \(folderPath)")

                // Notify UI progressively — library updates as each folder completes
                await MainActor.run {
                    NotificationCenter.default.post(name: .libraryDidUpdate, object: nil)
                }
            }
            scanned += 1
        }

        // Batch-write scan skips after all SMB connections are closed.
        // Writing inline during the scan loop caused concurrent session pressure on the NAS.
        if !skippedPaths.isEmpty {
            scanLog("SCAN: writing \(skippedPaths.count) skip record(s) to DB")
            for path in skippedPaths {
                try? SorrivaDatabase.shared.insertScanSkip(filePath: path, sourceId: source.id)
            }
        }

        // Phase 3: finalize
        progressHandler(ScanProgress(
            sourceId: source.id, sourceName: source.displayName,
            phase: .finalizing, filesFound: totalFiles,
            filesScanned: scanned, currentFile: "Finalizing…"
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
        let scanEnd = Date()
        let duration = String(format: "%.1fs", scanEnd.timeIntervalSince(scanStart))
        scanLog("SCAN: END \(source.displayName) at \(formatTime(scanEnd)) — \(duration) total, \(finalTrackCount) tracks, \(skipped) read-skipped, \(writeFailures) write-failed")
        let report = ScanReport(
            sourceId: source.id,
            sourceName: source.displayName,
            totalFiles: totalFiles,
            tracksIndexed: finalTrackCount,
            albumsFound: finalAlbumCount,
            artistsFound: artistCache.count,
            filesSkipped: skipped,
            writeFailures: writeFailures,
            artworkFound: 0,      // enriched by ScanCoordinator after artwork passes
            tracksRetried: 0,     // enriched by ScanCoordinator after retry scheduler
            permanentFailures: 0, // enriched by ScanCoordinator after retry scheduler
            completedAt: Date()
        )
        progressHandler(ScanProgress(
            sourceId: source.id, sourceName: source.displayName,
            phase: .complete, filesFound: totalFiles,
            filesScanned: scanned, currentFile: "", report: report
        ))
    }

    // MARK: - Directory walk

    /// Public wrapper for use by ScanCoordinator during change detection.
    /// Signature unchanged (still takes a connected SMBClient) so ScanCoordinator
    /// needs no changes — internally adapted onto the same reader-based walk
    /// used by the scanner's own scan/statFolders paths, so there is exactly
    /// one recursive directory-walk implementation.
    func collectAudioFilesPublic(
        client: SMBClient,
        path: String,
        results: inout [(path: String, size: Int)]
    ) async throws {
        let adapter = SMBClientListingOnlyReader(client: client)
        try await collectAudioFiles(reader: adapter, path: path, results: &results)
    }

    /// Normalizes a share-relative path to a single consistent form — one
    /// leading slash, no trailing slash, no accidental repeated slashes.
    /// filePath is the idempotency key for the whole scan; any inconsistency
    /// here would silently defeat both the UNIQUE constraint and
    /// upsertTrackIdempotent's lookup.
    private func normalizePath(_ path: String) -> String {
        var result = path
        while result.contains("//") { result = result.replacingOccurrences(of: "//", with: "/") }
        if !result.hasPrefix("/") { result = "/" + result }
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private func collectAudioFiles(
        reader: MediaSourceReader,
        path: String,
        results: inout [(path: String, size: Int)]
    ) async throws {
        let entries = try await reader.listDirectory(path: path)
        for entry in entries {
            let name = entry.name
            guard name != "." && name != ".." && !name.hasPrefix(".") else { continue }
            let fullPath = normalizePath(path == "/" ? "/\(name)" : "\(path)/\(name)")
            if entry.isDirectory {
                try await collectAudioFiles(reader: reader, path: fullPath, results: &results)
            } else {
                let ext = (name as NSString).pathExtension.lowercased()
                if Self.audioExtensions.contains(ext) {
                    results.append((path: fullPath, size: entry.size))
                }
            }
        }
    }

    private func statTopLevelFolders(
        reader: MediaSourceReader,
        path: String
    ) async throws -> [FolderScanResult] {
        var results: [FolderScanResult] = []
        let entries = try await reader.listDirectory(path: path)
        for entry in entries {
            let name = entry.name
            guard name != "." && name != ".." && !name.hasPrefix(".") else { continue }
            guard entry.isDirectory else { continue }
            let fullPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
            var files: [(path: String, size: Int)] = []
            try await collectAudioFiles(reader: reader, path: fullPath, results: &files)
            if !files.isEmpty {
                results.append(FolderScanResult(
                    folderPath: fullPath,
                    fileCount: files.count,
                    totalBytes: files.reduce(0) { $0 + $1.size }
                ))
            }
        }
        return results
    }

    /// Adapts an already-connected SMBClient for directory listing only —
    /// used solely by collectAudioFilesPublic so ScanCoordinator's
    /// change-detection path shares the same recursive walk as the scanner's
    /// own scan/statFolders paths. readHeader is never called through this
    /// adapter; collectAudioFilesPublic only lists directories.
    private struct SMBClientListingOnlyReader: MediaSourceReader {
        let client: SMBClient
        func listDirectory(path: String) async throws -> [MediaSourceEntry] {
            let entries = try await client.listDirectory(path: path)
            return entries.map {
                MediaSourceEntry(name: $0.name, isDirectory: $0.isDirectory, size: Int($0.size))
            }
        }
        func readHeader(path: String, byteCount: Int) async throws -> Data {
            throw MediaSourceReaderError.unsupported
        }
    }

    // MARK: - Track deletion helpers

    private func deleteTracksInFolder(folder: String, sourceId: String) async throws {
        try await SorrivaDatabase.shared.dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM tracks WHERE sourceId = ? AND filePath LIKE ?
            """, arguments: [sourceId, "\(folder)/%"])
        }
    }

    // MARK: - Artist / Album resolution

    /// Normalized matching key for artist identity — trims surrounding whitespace
    /// and folds case, so "Yazoo", "yazoo", and "Yazoo " resolve to a single artist
    /// row instead of three. Used for cache and lookup only; the display name keeps
    /// its original casing.
    private func artistKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func resolveArtist(name: String, cache: inout [String: Artist]) throws -> Artist {
        var displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if displayName.isEmpty { displayName = "Unknown Artist" }
        let key = artistKey(displayName)

        if let cached = cache[key] { return cached }
        if let existing = try SorrivaDatabase.shared.artist(namedNormalized: displayName) {
            cache[key] = existing
            return existing
        }
        let now = Int(Date().timeIntervalSince1970)
        let artist = Artist(
            id: UUID().uuidString, name: displayName,
            sortName: makeSortName(displayName),
            imageURL: nil, albumCount: 0, trackCount: 0,
            createdAt: now, updatedAt: now
        )
        try SorrivaDatabase.shared.upsertArtist(artist)
        cache[key] = artist
        return artist
    }

    private func resolveAlbum(
        title: String, artist: Artist, year: Int?, genre: String?,
        folderPath: String, sourceId: String,
        cache: inout [String: Album]
    ) throws -> Album {
        // Check in-memory cache by folderPath first — prevents splits from tag inconsistencies
        let folderKey = "folder|\(folderPath)"
        if let cached = cache[folderKey] { return cached }

        // DB lookup by folderPath — the sole deduplication key.
        //
        // The former title + artist fallback was removed deliberately. It merged
        // two folders into one album whenever their ALBUM tags matched, which the
        // data on disk never asserts. On a library where every compilation
        // resolves to the same "Various Artists" row, any two compilations sharing
        // an ALBUM tag collapsed into a single album. One folder is one album.
        if let existing = try SorrivaDatabase.shared.album(folderPath: folderPath) {
            cache[folderKey] = existing
            return existing
        }

        // Create new album
        let now = Int(Date().timeIntervalSince1970)
        let album = Album(
            id: UUID().uuidString, title: title,
            sortTitle: makeSortName(title),
            primaryArtistId: artist.id, artistName: artist.name,
            year: year, genre: genre,
            artPathThumb: nil, artPathFull: nil,
            embeddedArtScanned: false, artManualOverride: false,
            embeddedArtFailed: false, embeddedArtRetryCount: 0,
            trackCount: 0, sourceId: sourceId,
            folderPath: folderPath,
            createdAt: now, updatedAt: now
        )
        try SorrivaDatabase.shared.upsertAlbum(album)
        try SorrivaDatabase.shared.upsertArtistAlbum(
            artistId: artist.id, albumId: album.id, role: "primary"
        )
        cache[folderKey] = album
        return album
    }

    // MARK: - Path fallback

    private func fillFromPath(meta: ParsedMetadata, filePath: String, rootPath: String) -> ParsedMetadata {
        var m = meta
        let filename = (filePath as NSString).lastPathComponent
        let relative = filePath.hasPrefix(rootPath)
            ? String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : filePath
        var components = relative.components(separatedBy: "/").filter { !$0.isEmpty }
        if !components.isEmpty { components.removeLast() }

        // Collapse disc/CD subfolders
        var discNumber: Int? = m.discNumber
        if let last = components.last,
           let _ = last.range(of: #"^(disc|disk|cd|part)\s*\d+$"#,
                              options: [.regularExpression, .caseInsensitive]) {
            if discNumber == nil {
                discNumber = last.components(separatedBy: CharacterSet.decimalDigits.inverted)
                    .compactMap { Int($0) }.first
            }
            components.removeLast()
        }
        if m.discNumber == nil { m.discNumber = discNumber }

        // Strip track number from filename and get title
        var titleFromFilename = filenameWithoutExtension(filename)
        if m.trackNumber == nil {
            if let range = titleFromFilename.range(of: #"^(\d{1,3})[\s\.\-–_]+"#, options: .regularExpression) {
                // Standard: "01 - Title" or "01. Title"
                let numStr = String(titleFromFilename[range])
                    .trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
                m.trackNumber = Int(numStr)
                titleFromFilename = String(titleFromFilename[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if titleFromFilename.isEmpty { titleFromFilename = filenameWithoutExtension(filename) }
            } else {
                // Try "Artist - Album - NN - Title" pattern
                let parts = titleFromFilename.components(separatedBy: " - ")
                if parts.count >= 4, let trackNum = Int(parts[parts.count - 2].trimmingCharacters(in: .whitespaces)) {
                    m.trackNumber = trackNum
                    titleFromFilename = parts[parts.count - 1].trimmingCharacters(in: .whitespaces)
                } else if parts.count >= 2, let trackNum = Int(parts[parts.count - 2].trimmingCharacters(in: .whitespaces)) {
                    // "Artist - NN - Title"
                    m.trackNumber = trackNum
                    titleFromFilename = parts[parts.count - 1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        if m.title == nil { m.title = titleFromFilename }

        switch components.count {
        case 0:
            // Flat — try "Artist - Album - Title" filename pattern
            let parts = filenameWithoutExtension(filename).components(separatedBy: " - ")
            if parts.count >= 3 && m.artist == nil {
                m.artist = parts[0].trimmingCharacters(in: .whitespaces)
                if m.album == nil { m.album = parts[1].trimmingCharacters(in: .whitespaces) }
            }
        case 1:
            // Same guard as the default case below — if ALBUMARTIST was already
            // parsed from tags, don't overwrite the (legitimately absent) artist
            // with the folder name. Without this, a file with only an ALBUMARTIST
            // tag sitting directly in one folder at the share root (no separate
            // Artist folder above it) gets its track artist silently replaced by
            // the folder name instead of falling back to ALBUMARTIST.
            if m.albumArtist == nil && m.artist == nil { m.artist = components[0] }
        default:
            if m.albumArtist == nil && m.artist == nil { m.artist = components[components.count - 2] }
            if m.album == nil {
                var albumName = components[components.count - 1]
                // Strip leading "Artist - " prefix from album folder name
                // e.g. "Stan Getz - This Is Jazz 14" → "This Is Jazz 14"
                let artistName = m.albumArtist ?? m.artist ?? components[components.count - 2]
                let prefix = "\(artistName) - "
                if albumName.hasPrefix(prefix) {
                    albumName = String(albumName.dropFirst(prefix.count))
                }
                m.album = albumName
            }
        }

        return m
    }

    // MARK: - Folder artwork fetch

    // MARK: - Per-file header read via injected reader

    /// Read up to 64KB from the start of a file through the injected reader,
    /// translating I/O errors into the same log lines the scanner has always
    /// produced. Returns nil on any failure — callers already treat nil as skip.
    /// bScannerTestSeam — the actual connection handling now lives in
    /// SMBMediaSourceReader.readHeader; this wrapper only adds logging.
    private func readFileHeader(reader: MediaSourceReader, path: String, fileSize: Int) async -> Data? {
        let byteCount = min(65536, fileSize)
        do {
            return try await reader.readHeader(path: path, byteCount: byteCount)
        } catch let error as MediaSourceReaderError {
            let name = (path as NSString).lastPathComponent
            switch error {
            case .auth(_, let underlying):
                scanLog("SCAN: auth error — \(name): \(underlying.localizedDescription)")
            case .share(_, let underlying):
                scanLog("SCAN: share error for \(name): \(underlying.localizedDescription)")
            case .read(_, let underlying):
                scanLog("SCAN: read error — \(name): \(underlying.localizedDescription)")
            case .timeout:
                scanLog("SCAN: TIMEOUT 15s — \(path)")
            case .unsupported:
                scanLog("SCAN: readHeader unsupported for this reader — \(path)")
            }
            return nil
        } catch {
            scanLog("SCAN: read error — \(path): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Track construction and write (shared by main scan loop and retry pass)

    /// Resolve artist/album/track identity and construct a Track ready to
    /// upsert. Single place that builds a Track from parsed metadata — used
    /// by the main scan loop and by retrySkippedTracks for a skip whose row
    /// was never created due to an earlier write failure.
    private func buildTrack(
        meta rawMeta: ParsedMetadata,
        filePath: String,
        fileSize: Int,
        rootPath root: String,
        source: LibrarySource,
        artistCache: inout [String: Artist],
        albumCache: inout [String: Album]
    ) throws -> (track: Track, trackArtist: Artist) {
        let filename = (filePath as NSString).lastPathComponent
        let ext = (filename as NSString).pathExtension.lowercased()
        let meta = fillFromPath(meta: rawMeta, filePath: filePath, rootPath: root)

        // Album artist and track artist are resolved independently.
        // ALBUMARTIST governs the album; ARTIST governs the track.
        // On a compilation these differ — ALBUMARTIST is "Various Artists"
        // while each track carries its own performer. Falling back to the
        // other field only when the preferred one is absent.
        let albumArtistName = meta.albumArtist ?? meta.artist ?? "Unknown Artist"
        let trackArtistName = meta.artist ?? meta.albumArtist ?? "Unknown Artist"
        let albumArtist = try resolveArtist(name: albumArtistName, cache: &artistCache)
        let trackArtist = (trackArtistName == albumArtistName)
            ? albumArtist
            : try resolveArtist(name: trackArtistName, cache: &artistCache)

        let albumTitle = meta.album ?? "Unknown Album"
        let folderPath = (filePath as NSString).deletingLastPathComponent
        let album = try resolveAlbum(
            title: albumTitle, artist: albumArtist, year: meta.year,
            genre: meta.genre, folderPath: folderPath,
            sourceId: source.id, cache: &albumCache
        )

        let now = Int(Date().timeIntervalSince1970)
        let track = Track(
            id: UUID().uuidString,
            title: meta.title ?? filenameWithoutExtension(filename),
            albumId: album.id,
            albumTitle: album.title,
            primaryArtistId: trackArtist.id,
            artistName: trackArtist.name,
            trackNumber: meta.trackNumber,
            discNumber: meta.discNumber,
            year: meta.year ?? album.year,
            genre: meta.genre ?? album.genre,
            duration: meta.duration,
            fileFormat: ext == "aif" ? "aiff" : ext,
            filePath: filePath,
            fileSize: fileSize,
            bitrate: meta.bitrate,
            sampleRate: meta.sampleRate,
            sourceId: source.id,
            createdAt: now,
            updatedAt: now
        )
        return (track, trackArtist)
    }

    /// Write a track (and its artist join row) with a short immediate retry
    /// for transient failures (SQLite briefly busy/locked from concurrent
    /// access — the common case). Returns false only after 3 attempts still
    /// fail, so the caller can queue it into scan_skips: a track missing
    /// because of a write failure gets the same second chance as one missing
    /// because of a read failure, through the same retry mechanism.
    private func writeTrackWithRetry(_ track: Track, trackArtistId: String) async -> Bool {
        for attempt in 1...3 {
            do {
                // upsertTrackIdempotent may persist under a DIFFERENT id than
                // track.id if this filePath already has a row (rescan) — use
                // the id it actually returns, not the caller's, or the
                // track_artists insert below violates its FK on tracks.id.
                let persisted = try SorrivaDatabase.shared.upsertTrackIdempotent(track)
                try SorrivaDatabase.shared.upsertTrackArtist(
                    trackId: persisted.id, artistId: trackArtistId, role: "primary"
                )
                return true
            } catch {
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                } else {
                    scanLog("SCAN: write failed after 3 attempts — \(track.filePath): \(error)")
                }
            }
        }
        return false
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// Parse tag metadata from raw file header bytes.
    private func parseTagData(data: Data, ext: String) -> ParsedMetadata {
        switch ext {
        case "mp3":  return parseID3v2(data: data)
        case "flac": return parseVorbisComment(data: data)
        case "m4a", "aac", "alac": return parseMP4Atoms(data: data)
        case "wav", "aif", "aiff": return parseWAVDuration(data: data, ext: ext)
        default: return ParsedMetadata()
        }
    }

    // MARK: - WAV / AIFF duration parser

    private func parseWAVDuration(data: Data, ext: String) -> ParsedMetadata {
        var meta = ParsedMetadata()
        guard data.count > 44 else { return meta }

        if ext == "wav" {
            // WAV RIFF header: "RIFF" + fileSize(4) + "WAVE" + "fmt "(4) + chunkSize(4)
            // fmt chunk: audioFormat(2) + channels(2) + sampleRate(4) + byteRate(4) + blockAlign(2) + bitsPerSample(2)
            guard data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46 else { return meta }
            guard data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45 else { return meta }

            // Find fmt chunk
            var offset = 12
            while offset + 8 <= data.count {
                let chunkID = String(bytes: data[offset..<offset+4], encoding: .isoLatin1) ?? ""
                let chunkSize = Int(data[offset+4]) | Int(data[offset+5]) << 8
                             | Int(data[offset+6]) << 16 | Int(data[offset+7]) << 24
                if chunkID == "fmt " && offset + 8 + chunkSize <= data.count && chunkSize >= 16 {
                    let sampleRate = Int(data[offset+12]) | Int(data[offset+13]) << 8
                                   | Int(data[offset+14]) << 16 | Int(data[offset+15]) << 24
                    let byteRate   = Int(data[offset+16]) | Int(data[offset+17]) << 8
                                   | Int(data[offset+18]) << 16 | Int(data[offset+19]) << 24
                    // Find data chunk for size
                    var dOffset = offset + 8 + chunkSize
                    while dOffset + 8 <= data.count {
                        let dID = String(bytes: data[dOffset..<dOffset+4], encoding: .isoLatin1) ?? ""
                        let dSize = Int(data[dOffset+4]) | Int(data[dOffset+5]) << 8
                                  | Int(data[dOffset+6]) << 16 | Int(data[dOffset+7]) << 24
                        if dID == "data" && byteRate > 0 {
                            meta.duration = Double(dSize) / Double(byteRate)
                            return meta
                        }
                        dOffset += 8 + dSize
                    }
                    // Fallback: use file size from RIFF header
                    if byteRate > 0 && sampleRate > 0 {
                        let fileSize = Int(data[4]) | Int(data[5]) << 8
                                     | Int(data[6]) << 16 | Int(data[7]) << 24
                        meta.duration = Double(fileSize) / Double(byteRate)
                    }
                    return meta
                }
                offset += 8 + chunkSize
            }
        } else {
            // AIFF: "FORM" + size(4) + "AIFF" + "COMM" chunk
            guard data[0] == 0x46, data[1] == 0x4F, data[2] == 0x52, data[3] == 0x4D else { return meta }
            var offset = 12
            while offset + 8 <= data.count {
                let chunkID = String(bytes: data[offset..<offset+4], encoding: .isoLatin1) ?? ""
                let chunkSize = Int(data[offset+4]) << 24 | Int(data[offset+5]) << 16
                             | Int(data[offset+6]) << 8  | Int(data[offset+7])
                if chunkID == "COMM" && offset + 8 + 18 <= data.count {
                    // numSampleFrames at offset+10 (4 bytes), sampleRate at offset+14 (80-bit IEEE float)
                    let numFrames = Int(data[offset+10]) << 24 | Int(data[offset+11]) << 16
                                  | Int(data[offset+12]) << 8  | Int(data[offset+13])
                    // 80-bit extended: exponent at [14-15], mantissa at [16-23]
                    let exp = Int(data[offset+14] & 0x7F) << 8 | Int(data[offset+15])
                    let mant = UInt64(data[offset+16]) << 56 | UInt64(data[offset+17]) << 48
                             | UInt64(data[offset+18]) << 40 | UInt64(data[offset+19]) << 32
                    let sampleRate = Double(mant) * pow(2.0, Double(exp - 16383 - 63))
                    if sampleRate > 0 && numFrames > 0 {
                        meta.duration = Double(numFrames) / sampleRate
                    }
                    return meta
                }
                offset += 8 + chunkSize + (chunkSize % 2)
            }
        }
        return meta
    }

    // MARK: - ID3v2 parser (MP3)

    private func parseID3v2(data: Data) -> ParsedMetadata {
        var meta = ParsedMetadata()
        guard data.count > 10 else { return meta }
        guard data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return meta }

        let size = id3SyncsafeInt(data: data, offset: 6)
        guard size > 0, size + 10 <= data.count else { return meta }

        let version = data[3]
        var offset = 10

        while offset + 10 < size + 10 {
            guard offset + 10 <= data.count else { break }
            let frameID = String(bytes: data[offset..<offset+4], encoding: .isoLatin1) ?? ""
            guard !frameID.isEmpty && frameID != "\0\0\0\0" else { break }

            let frameSize: Int
            if version >= 4 {
                frameSize = id3SyncsafeInt(data: data, offset: offset + 4)
            } else {
                frameSize = Int(data[offset+4]) << 24 | Int(data[offset+5]) << 16
                         | Int(data[offset+6]) << 8  | Int(data[offset+7])
            }
            guard frameSize > 0, offset + 10 + frameSize <= data.count else { break }

            let frameData = data[(offset+10)..<(offset+10+frameSize)]

            switch frameID {
            case "TIT2": meta.title       = id3TextFrame(frameData)
            case "TPE1": meta.artist      = id3TextFrame(frameData)
            case "TPE2": meta.albumArtist = id3TextFrame(frameData)
            case "TALB": meta.album       = id3TextFrame(frameData)
            case "TDRC", "TYER":
                if let s = id3TextFrame(frameData) { meta.year = Int(s.prefix(4)) }
            case "TRCK":
                if let s = id3TextFrame(frameData) {
                    meta.trackNumber = Int(s.components(separatedBy: "/").first ?? s)
                }
            case "TPOS":
                if let s = id3TextFrame(frameData) {
                    meta.discNumber = Int(s.components(separatedBy: "/").first ?? s)
                }
            case "TCON": meta.genre = id3Genre(id3TextFrame(frameData))
            case "TLEN":
                // TLEN = track length in milliseconds
                if let s = id3TextFrame(frameData), let ms = Double(s), ms > 0 {
                    meta.duration = ms / 1000.0
                }
            default: break
            }
            offset += 10 + frameSize
        }
        return meta
    }

    private func id3TextFrame(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let encoding = data.first ?? 0
        let textData = data.dropFirst()
        let str: String?
        switch encoding {
        case 0:  str = String(data: textData, encoding: .isoLatin1)
        case 1:  str = String(data: textData, encoding: .utf16)
        case 2:  str = String(data: textData, encoding: .utf16BigEndian)
        case 3:  str = String(data: textData, encoding: .utf8)
        default: str = String(data: textData, encoding: .isoLatin1)
        }
        return str?.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespaces)
    }

    private func id3Genre(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        if let match = raw.range(of: #"^\((\d+)\)"#, options: .regularExpression) {
            let numStr = raw[match].dropFirst().dropLast()
            if let num = Int(numStr), num < Self.id3Genres.count {
                return Self.id3Genres[num]
            }
        }
        return raw.isEmpty ? nil : raw
    }

    private func id3SyncsafeInt(data: Data, offset: Int) -> Int {
        guard offset + 3 < data.count else { return 0 }
        return Int(data[offset]) << 21 | Int(data[offset+1]) << 14
             | Int(data[offset+2]) << 7 | Int(data[offset+3])
    }

    // MARK: - Vorbis Comment parser (FLAC)

    private func parseVorbisComment(data: Data) -> ParsedMetadata {
        var meta = ParsedMetadata()
        guard data.count > 4 else { return meta }
        guard data[0] == 0x66, data[1] == 0x4C, data[2] == 0x61, data[3] == 0x43 else { return meta }

        var offset = 4
        while offset + 4 <= data.count {
            let blockHeader = data[offset]
            let isLast = (blockHeader & 0x80) != 0
            let blockType = blockHeader & 0x7F
            let blockSize = Int(data[offset+1]) << 16 | Int(data[offset+2]) << 8 | Int(data[offset+3])
            offset += 4

            if blockType == 0 && blockSize >= 18 && offset + blockSize <= data.count {
                // STREAMINFO block (18 bytes) — use offset-relative indexing into data
                // data[offset+0..1]  = min block size
                // data[offset+2..3]  = max block size
                // data[offset+4..6]  = min frame size
                // data[offset+7..9]  = max frame size
                // data[offset+10..12] = sample rate (20 bits) | channels (3) | bitsPerSample (5)
                // data[offset+13..17] = total samples (36 bits)
                let sampleRate = (Int(data[offset+10]) << 12)
                              | (Int(data[offset+11]) << 4)
                              | (Int(data[offset+12]) >> 4)
                let totalSamples = (Int(data[offset+13] & 0x0F) << 32)
                                 | (Int(data[offset+14]) << 24)
                                 | (Int(data[offset+15]) << 16)
                                 | (Int(data[offset+16]) << 8)
                                 |  Int(data[offset+17])
                if sampleRate > 0 && totalSamples > 0 {
                    meta.duration = Double(totalSamples) / Double(sampleRate)
                }
            } else if blockType == 4 && offset + blockSize <= data.count {
                // VORBIS_COMMENT block — text tags
                let block = Data(data[offset..<(offset+blockSize)])
                parseVorbisBlock(block: block, meta: &meta)
            }

            offset += blockSize
            if isLast || offset >= data.count { break }
        }
        return meta
    }

    private func parseVorbisBlock(block: Data, meta: inout ParsedMetadata) {
        var pos = 0
        guard pos + 4 <= block.count else { return }
        let vendorLen = Int(block[pos]) | Int(block[pos+1]) << 8
                      | Int(block[pos+2]) << 16 | Int(block[pos+3]) << 24
        pos += 4 + vendorLen
        guard pos + 4 <= block.count else { return }
        let commentCount = Int(block[pos]) | Int(block[pos+1]) << 8
                         | Int(block[pos+2]) << 16 | Int(block[pos+3]) << 24
        pos += 4
        for _ in 0..<commentCount {
            guard pos + 4 <= block.count else { break }
            let len = Int(block[pos]) | Int(block[pos+1]) << 8
                    | Int(block[pos+2]) << 16 | Int(block[pos+3]) << 24
            pos += 4
            guard pos + len <= block.count else { break }
            if let comment = String(data: block[pos..<(pos+len)], encoding: .utf8) {
                let parts = comment.components(separatedBy: "=")
                if parts.count >= 2 {
                    let key = parts[0].uppercased()
                    let value = parts.dropFirst().joined(separator: "=")
                    switch key {
                    case "TITLE":       meta.title       = value
                    case "ARTIST":      meta.artist      = value
                    case "ALBUMARTIST", "ALBUM ARTIST": meta.albumArtist = value
                    case "ALBUM":       meta.album       = value
                    case "DATE", "YEAR": meta.year       = Int(value.prefix(4))
                    case "TRACKNUMBER":
                        meta.trackNumber = Int(value.components(separatedBy: "/").first ?? value)
                    case "DISCNUMBER":
                        meta.discNumber = Int(value.components(separatedBy: "/").first ?? value)
                    case "GENRE":       meta.genre       = value
                    default: break
                    }
                }
            }
            pos += len
        }
    }

    // MARK: - MP4 atom parser (M4A, AAC, ALAC)

    private func parseMP4Atoms(data: Data) -> ParsedMetadata {
        var meta = ParsedMetadata()
        guard data.count > 8 else { return meta }
        if let moovOffset = findAtom(name: "moov", data: data, offset: 0) {
            let moovSize = atomSize(data: data, offset: moovOffset)
            let moovEnd = min(moovOffset + moovSize, data.count)

            // mvhd atom — contains duration in timescale units
            if let mvhdOffset = findAtom(name: "mvhd", data: data, offset: moovOffset + 8, end: moovEnd),
               mvhdOffset + 28 <= data.count {
                let version = data[mvhdOffset + 8]
                if version == 0 {
                    // 32-bit: timescale at offset 12, duration at offset 16
                    let timescale = Int(data[mvhdOffset+20]) << 24 | Int(data[mvhdOffset+21]) << 16
                                  | Int(data[mvhdOffset+22]) << 8  | Int(data[mvhdOffset+23])
                    let duration  = Int(data[mvhdOffset+24]) << 24 | Int(data[mvhdOffset+25]) << 16
                                  | Int(data[mvhdOffset+26]) << 8  | Int(data[mvhdOffset+27])
                    if timescale > 0 && duration > 0 {
                        meta.duration = Double(duration) / Double(timescale)
                    }
                } else if version == 1 && mvhdOffset + 36 <= data.count {
                    // 64-bit: timescale at offset 20, duration at offset 24
                    let timescale = Int(data[mvhdOffset+28]) << 24 | Int(data[mvhdOffset+29]) << 16
                                  | Int(data[mvhdOffset+30]) << 8  | Int(data[mvhdOffset+31])
                    let durHi = Int(data[mvhdOffset+32]) << 24 | Int(data[mvhdOffset+33]) << 16
                    let durLo = Int(data[mvhdOffset+34]) << 8  | Int(data[mvhdOffset+35])
                    let duration = (durHi << 16) | durLo
                    if timescale > 0 && duration > 0 {
                        meta.duration = Double(duration) / Double(timescale)
                    }
                }
            }

            if let udtaOffset = findAtom(name: "udta", data: data, offset: moovOffset + 8, end: moovEnd) {
                let udtaSize = atomSize(data: data, offset: udtaOffset)
                let udtaEnd = min(udtaOffset + udtaSize, data.count)
                if let metaOffset = findAtom(name: "meta", data: data, offset: udtaOffset + 8, end: udtaEnd) {
                    let metaSize = atomSize(data: data, offset: metaOffset)
                    let metaEnd = min(metaOffset + metaSize, data.count)
                    if let ilstOffset = findAtom(name: "ilst", data: data, offset: metaOffset + 12, end: metaEnd) {
                        let ilstSize = atomSize(data: data, offset: ilstOffset)
                        let ilstEnd = min(ilstOffset + ilstSize, data.count)
                        parseIlst(data: data, offset: ilstOffset + 8, end: ilstEnd, meta: &meta)
                    }
                }
            }
        }
        return meta
    }

    private func parseIlst(data: Data, offset: Int, end: Int, meta: inout ParsedMetadata) {
        var pos = offset
        while pos + 8 < end {
            let size = atomSize(data: data, offset: pos)
            guard size >= 8 else { break }
            let name = atomName(data: data, offset: pos)
            let atomEnd = min(pos + size, end)
            if let dataOffset = findAtom(name: "data", data: data, offset: pos + 8, end: atomEnd) {
                let dataSize = atomSize(data: data, offset: dataOffset)
                let valueOffset = dataOffset + 16
                let valueEnd = min(dataOffset + dataSize, atomEnd)
                if valueOffset < valueEnd {
                    let valueData = data[valueOffset..<valueEnd]
                    let str = String(data: valueData, encoding: .utf8)
                    switch name {
                    case "©nam": meta.title       = str
                    case "©ART": meta.artist      = str
                    case "aART": meta.albumArtist = str
                    case "©alb": meta.album       = str
                    case "©day":
                        if let s = str { meta.year = Int(s.prefix(4)) }
                    case "trkn":
                        if valueData.count >= 4 {
                            meta.trackNumber = Int(valueData[valueData.startIndex.advanced(by: 2)]) << 8
                                             | Int(valueData[valueData.startIndex.advanced(by: 3)])
                        }
                    case "disk":
                        if valueData.count >= 4 {
                            meta.discNumber = Int(valueData[valueData.startIndex.advanced(by: 2)]) << 8
                                            | Int(valueData[valueData.startIndex.advanced(by: 3)])
                        }
                    case "©gen", "gnre": meta.genre = str
                    default: break
                    }
                }
            }
            pos += size
        }
    }

    private func findAtom(name: String, data: Data, offset: Int, end: Int? = nil) -> Int? {
        let limit = end ?? data.count
        var pos = offset
        while pos + 8 <= limit {
            let size = atomSize(data: data, offset: pos)
            guard size >= 8 else { break }
            if atomName(data: data, offset: pos) == name { return pos }
            pos += size
        }
        return nil
    }

    private func atomSize(data: Data, offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return Int(data[offset]) << 24 | Int(data[offset+1]) << 16
             | Int(data[offset+2]) << 8 | Int(data[offset+3])
    }

    private func atomName(data: Data, offset: Int) -> String {
        guard offset + 8 <= data.count else { return "" }
        return String(bytes: data[(offset+4)..<(offset+8)], encoding: .isoLatin1) ?? ""
    }

    // MARK: - Helpers

    private func rootPath(_ source: LibrarySource) -> String {
        source.rootPath.isEmpty ? "/" : source.rootPath
    }

    private func filenameWithoutExtension(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
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

    // MARK: - Scan skip retry pass

    /// Retry tag reads for files that failed during the main scan.
    /// Called by ScanRetryScheduler after the full pipeline completes.
    /// On success: updates the track record with recovered tags, marks skip resolved.
    /// On failure: increments attempt count. After 5 total attempts the row is retained
    /// with attemptCount = 5 for future admin review — no further retries attempted.
    nonisolated private func scanLog(_ message: String) {
        sLog(message)
        ScanCoordinator.shared.appendStatus(message)
    }

    func retrySkippedTracks(source: LibrarySource) async {
        let skips: [ScanSkip]
        do {
            skips = try SorrivaDatabase.shared.pendingScanSkips(sourceId: source.id)
        } catch {
            scanLog("RETRY: tracks — failed to fetch pending skips: \(error.localizedDescription)")
            return
        }
        guard !skips.isEmpty else {
            scanLog("RETRY: tracks — no pending skips for \(source.displayName)")
            return
        }

        scanLog("RETRY: tracks START — \(skips.count) pending for \(source.displayName)")
        // Keychain-aware resolution now happens inside the reader.
        let reader = readerFactory(source)
        let root = rootPath(source)
        var artistCache: [String: Artist] = [:]
        var albumCache: [String: Album] = [:]
        var resolved = 0
        var stillFailing = 0

        for skip in skips {
            let filename = (skip.filePath as NSString).lastPathComponent
            let ext = (filename as NSString).pathExtension.lowercased()
            let attemptNum = skip.attemptCount + 1

            scanLog("RETRY: track attempt \(attemptNum)/5 — \(filename)")

            let existingTrack = try? SorrivaDatabase.shared.track(filePath: skip.filePath)
            let fileSize = existingTrack?.fileSize ?? 65536

            let headerData = await readFileHeader(reader: reader, path: skip.filePath, fileSize: fileSize)

            if let data = headerData {
                let parsed = parseTagData(data: data, ext: ext)
                let hasUsefulTags = parsed.title != nil || parsed.artist != nil
                                 || parsed.album != nil || parsed.duration != nil
                if hasUsefulTags {
                    if existingTrack != nil {
                        // Read-failure origin — row already exists with fallback
                        // metadata, backfill the real tags now that they're readable.
                        try? SorrivaDatabase.shared.updateTrackTags(
                            filePath: skip.filePath,
                            title: parsed.title,
                            artistName: parsed.artist ?? parsed.albumArtist,
                            trackNumber: parsed.trackNumber,
                            discNumber: parsed.discNumber,
                            year: parsed.year,
                            genre: parsed.genre,
                            duration: parsed.duration
                        )
                    } else {
                        // Write-failure origin — no row was ever created. Build one
                        // fresh from these newly-parsed tags, same as the main scan.
                        do {
                            let (track, trackArtist) = try buildTrack(
                                meta: parsed, filePath: skip.filePath, fileSize: fileSize,
                                rootPath: root, source: source,
                                artistCache: &artistCache, albumCache: &albumCache
                            )
                            _ = await writeTrackWithRetry(track, trackArtistId: trackArtist.id)
                        } catch {
                            scanLog("RETRY: track insert failed — \(filename): \(error)")
                        }
                    }
                    try? SorrivaDatabase.shared.resolveScanSkip(filePath: skip.filePath)
                    scanLog("RETRY: track RESOLVED (attempt \(attemptNum)) — \(filename)")
                    resolved += 1
                } else {
                    // Read succeeded but no tags — genuine content issue (e.g. AIFF with no metadata)
                    try? SorrivaDatabase.shared.incrementScanSkip(filePath: skip.filePath)
                    if attemptNum >= 5 {
                        scanLog("RETRY: track PERMANENT FAIL (no tags after 5 attempts) — \(filename)")
                    } else {
                        scanLog("RETRY: track attempt \(attemptNum) — read ok but no tags — \(filename)")
                    }
                    stillFailing += 1
                }
            } else {
                // Read error — transient NAS issue, don't count against attempt limit
                scanLog("RETRY: track attempt \(attemptNum) failed (read error) — \(filename)")
                stillFailing += 1
            }

            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms between files
        }

        let permanent = (try? SorrivaDatabase.shared.permanentScanSkipCount(sourceId: source.id)) ?? 0
        scanLog("RETRY: tracks COMPLETE — \(resolved) resolved, \(stillFailing) still failing, \(permanent) permanent")
    }

    // MARK: - ID3 genre table

    private static let id3Genres: [String] = [
        "Blues","Classic Rock","Country","Dance","Disco","Funk","Grunge","Hip-Hop",
        "Jazz","Metal","New Age","Oldies","Other","Pop","R&B","Rap","Reggae","Rock",
        "Techno","Industrial","Alternative","Ska","Death Metal","Pranks","Soundtrack",
        "Euro-Techno","Ambient","Trip-Hop","Vocal","Jazz+Funk","Fusion","Trance",
        "Classical","Instrumental","Acid","House","Game","Sound Clip","Gospel","Noise",
        "AlternRock","Bass","Soul","Punk","Space","Meditative","Instrumental Pop",
        "Instrumental Rock","Ethnic","Gothic","Darkwave","Techno-Industrial","Electronic",
        "Pop-Folk","Eurodance","Dream","Southern Rock","Comedy","Cult","Gangsta","Top 40",
        "Christian Rap","Pop/Funk","Jungle","Native American","Cabaret","New Wave",
        "Psychedelic","Rave","Showtunes","Trailer","Lo-Fi","Tribal","Acid Punk",
        "Acid Jazz","Polka","Retro","Musical","Rock & Roll","Hard Rock"
    ]
}
