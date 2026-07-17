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

    // MARK: - Public API

    /// Quick stat of all top-level album folders under source rootPath.
    /// Returns one FolderScanResult per immediate subfolder (album level).
    /// Used by ScanCoordinator for incremental change detection.
    func statFolders(source: LibrarySource) async throws -> [FolderScanResult] {
        let client = SMBClient(host: source.host)
        try await client.login(username: source.username ?? "", password: source.password ?? "")
        defer { Task { try? await client.logoff() } }
        try await client.connectShare(source.share)
        defer { Task { try? await client.disconnectShare() } }

        let root = rootPath(source)
        return try await statTopLevelFolders(client: client, path: root)
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
        print("SCAN: START \(scanLabel) — \(source.displayName) at \(formatTime(scanStart))")

        // Phase 1: directory walk
        progressHandler(ScanProgress(
            sourceId: source.id, sourceName: source.displayName,
            phase: .statting, filesFound: 0, filesScanned: 0,
            currentFile: folderPaths == nil ? "Listing all files…" : "Listing changed folders…"
        ))

        let walkClient = SMBClient(host: source.host)
        try await walkClient.login(username: source.username ?? "", password: source.password ?? "")
        defer { Task { try? await walkClient.logoff() } }
        try await walkClient.connectShare(source.share)
        defer { Task { try? await walkClient.disconnectShare() } }

        let root = rootPath(source)
        var allFiles: [(path: String, size: Int)] = []

        if let paths = folderPaths {
            // Incremental — only walk specified folders
            for folder in paths {
                try await collectAudioFiles(client: walkClient, path: folder, results: &allFiles)
            }
        } else {
            // Full scan
            try await collectAudioFiles(client: walkClient, path: root, results: &allFiles)
        }

        let totalFiles = allFiles.count
        let totalBytes = allFiles.reduce(0) { $0 + $1.size }

        print("SCAN: using per-file SMBClient connections at 64KB")

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
        var artistCache: [String: Artist] = [:]
        var albumCache:  [String: Album]  = [:]

        // Pre-compute folder groups so we can write FolderStat as each folder completes
        let folderGroups = Dictionary(grouping: allFiles) { ($0.path as NSString).deletingLastPathComponent }
        var completedInFolder: [String: Int] = [:]

        for file in allFiles {
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
            let headerData = await readFileWithFreshConnection(
                host: source.host,
                share: source.share,
                username: source.username ?? "",
                password: source.password ?? "",
                path: file.path,
                fileSize: Int(file.size)
            )
            if let data = headerData {
                let parsed = parseTagData(data: data, ext: ext)
                if parsed.title != nil || parsed.artist != nil || parsed.album != nil || parsed.duration != nil {
                    meta = parsed
                }
            } else {
                skipped += 1
                print("SCAN: SKIP — \(file.path)")
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms throttle

            if (scanned + 1) % 50 == 0 {
                print("SCAN: [\(scanned + 1)/\(totalFiles)] progress — \(skipped) skipped so far")
            }

            // Fill missing fields from path structure
            meta = fillFromPath(meta: meta, filePath: file.path, rootPath: root)

            let artistName = meta.albumArtist ?? meta.artist ?? "Unknown Artist"
            let artist = try resolveArtist(name: artistName, cache: &artistCache)
            let albumTitle = meta.album ?? "Unknown Album"
            let folderPath = (file.path as NSString).deletingLastPathComponent
            let album = try resolveAlbum(
                title: albumTitle, artist: artist, year: meta.year,
                genre: meta.genre, folderPath: folderPath,
                sourceId: source.id, cache: &albumCache
            )

            let now = Int(Date().timeIntervalSince1970)
            let track = Track(
                id: UUID().uuidString,
                title: meta.title ?? filenameWithoutExtension(filename),
                albumId: album.id,
                albumTitle: album.title,
                primaryArtistId: artist.id,
                artistName: artist.name,
                trackNumber: meta.trackNumber,
                discNumber: meta.discNumber,
                year: meta.year ?? album.year,
                genre: meta.genre ?? album.genre,
                duration: meta.duration,
                fileFormat: ext == "aif" ? "aiff" : ext,
                filePath: file.path,
                fileSize: file.size,
                bitrate: meta.bitrate,
                sampleRate: meta.sampleRate,
                sourceId: source.id,
                createdAt: now,
                updatedAt: now
            )

            // Always upsert — filePath is the idempotency key.
            // If track already exists from a previous scan, this updates it in place.
            try? SorrivaDatabase.shared.upsertTrack(track)
            try? SorrivaDatabase.shared.upsertTrackArtist(
                trackId: track.id, artistId: artist.id, role: "primary"
            )

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
                print("SCAN: folder done (\(folderFiles.count) tracks) — \(folderPath)")

                // Notify UI progressively — library updates as each folder completes
                await MainActor.run {
                    NotificationCenter.default.post(name: .libraryDidUpdate, object: nil)
                }
            }
            scanned += 1
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
        print("SCAN: END \(source.displayName) at \(formatTime(scanEnd)) — \(duration) total, \(finalTrackCount) tracks, \(skipped) skipped")
        let report = ScanReport(
            sourceId: source.id,
            sourceName: source.displayName,
            totalFiles: totalFiles,
            tracksIndexed: finalTrackCount,
            albumsFound: finalAlbumCount,
            artistsFound: artistCache.count,
            filesSkipped: skipped,
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
    func collectAudioFilesPublic(
        client: SMBClient,
        path: String,
        results: inout [(path: String, size: Int)]
    ) async throws {
        try await collectAudioFiles(client: client, path: path, results: &results)
    }

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

    private func statTopLevelFolders(
        client: SMBClient,
        path: String
    ) async throws -> [FolderScanResult] {
        var results: [FolderScanResult] = []
        let entries = try await client.listDirectory(path: path)
        for entry in entries {
            let name = entry.name
            guard name != "." && name != ".." && !name.hasPrefix(".") else { continue }
            guard entry.isDirectory else { continue }
            let fullPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
            var files: [(path: String, size: Int)] = []
            try await collectAudioFiles(client: client, path: fullPath, results: &files)
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

    // MARK: - Track deletion helpers

    private func deleteTracksInFolder(folder: String, sourceId: String) async throws {
        try await SorrivaDatabase.shared.dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM tracks WHERE sourceId = ? AND filePath LIKE ?
            """, arguments: [sourceId, "\(folder)/%"])
        }
    }

    // MARK: - Artist / Album resolution

    private func resolveArtist(name: String, cache: inout [String: Artist]) throws -> Artist {
        if let cached = cache[name] { return cached }
        if let existing = try SorrivaDatabase.shared.artist(named: name) {
            cache[name] = existing
            return existing
        }
        let now = Int(Date().timeIntervalSince1970)
        let artist = Artist(
            id: UUID().uuidString, name: name,
            sortName: makeSortName(name),
            imageURL: nil, albumCount: 0, trackCount: 0,
            createdAt: now, updatedAt: now
        )
        try SorrivaDatabase.shared.upsertArtist(artist)
        cache[name] = artist
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

        // DB lookup by folderPath — authoritative deduplication key
        if let existing = try SorrivaDatabase.shared.album(folderPath: folderPath) {
            cache[folderKey] = existing
            cache["\(artist.id)|\(existing.title)"] = existing
            return existing
        }

        // Fallback: lookup by title + artist
        let titleKey = "\(artist.id)|\(title)"
        if let cached = cache[titleKey] { return cached }
        if let existing = try SorrivaDatabase.shared.album(title: title, artistId: artist.id) {
            cache[folderKey] = existing
            cache[titleKey] = existing
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
            trackCount: 0, sourceId: sourceId,
            folderPath: folderPath,
            createdAt: now, updatedAt: now
        )
        try SorrivaDatabase.shared.upsertAlbum(album)
        try SorrivaDatabase.shared.upsertArtistAlbum(
            artistId: artist.id, albumId: album.id, role: "primary"
        )
        cache[folderKey] = album
        cache[titleKey] = album
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
            if m.artist == nil { m.artist = components[0] }
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

    // MARK: - Per-file fresh connection read

    private func readFileWithFreshConnection(
        host: String, share: String,
        username: String, password: String,
        path: String, fileSize: Int
    ) async -> Data? {
        return await withCheckedContinuation { continuation in
            let semaphore = DispatchSemaphore(value: 0)
            var result: Data? = nil

            Task.detached {
                do {
                    let client = SMBClient(host: host)
                    try await client.login(username: username.isEmpty ? "guest" : username, password: password)
                    try await client.connectShare(share)
                    let reader = client.fileReader(path: path)
                    let readLength = UInt32(min(65536, fileSize))
                    let data = try await reader.read(offset: 0, length: readLength)
                    try? await reader.close()
                    try? await client.disconnectShare()
                    try? await client.logoff()
                    result = data
                } catch {
                    print("SCAN: read error — \((path as NSString).lastPathComponent): \(error.localizedDescription)")
                }
                semaphore.signal()
            }

            DispatchQueue.global(qos: .utility).async {
                if semaphore.wait(timeout: .now() + 15) == .timedOut {
                    print("SCAN: TIMEOUT 15s — \(path)")
                }
                continuation.resume(returning: result)
            }
        }
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
                // STREAMINFO block — extract sample rate and total samples for duration
                // Bytes 10-13 (within block): min block size(16) + max block size(16) + min frame(24) + max frame(24) + sample rate(20) + channels(3) + bits(5) = start of sample rate at bit 80 = byte 10
                // Layout: [0-1]=minBlockSize [2-3]=maxBlockSize [4-6]=minFrameSize [7-9]=maxFrameSize
                //         [10-12 bits 0-19]=sampleRate [12 bits 20-22]=channels [12 bits 23-27]=bitsPerSample
                //         [12 bit 28 .. 16 bit 43]=totalSamples (36 bits)
                let b = data[offset..<(offset+blockSize)]
                let sampleRate = (Int(b[10]) << 12) | (Int(b[11]) << 4) | (Int(b[12]) >> 4)
                // Total samples: 36 bits starting at bit 108 (byte 13 bit 4)
                let totalSamples = (Int(b[13] & 0x0F) << 32)
                    | (Int(b[14]) << 24)
                    | (Int(b[15]) << 16)
                    | (Int(b[16]) << 8)
                    | Int(b[17])
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
