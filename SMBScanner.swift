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

        // Phase 2: open dedicated read connection at negotiated maxReadSize
        // Must be separate from walk connection — session state is exhausted after directory walk
        let readClient = SMBClient(host: source.host)
        try await readClient.login(username: source.username ?? "", password: source.password ?? "")
        defer { Task { try? await readClient.logoff() } }
        try await readClient.connectShare(source.share)
        defer { Task { try? await readClient.disconnectShare() } }

        let readSize = readClient.session.maxReadSize
        print("SCAN: maxReadSize = \(readSize) bytes (\(readSize / 1024 / 1024)MB)")

        // For incremental scans, delete existing tracks for these folders only
        if let paths = folderPaths {
            for folder in paths {
                try await deleteTracksInFolder(folder: folder, sourceId: source.id)
            }
        } else {
            // Full scan — clear everything
            try SorrivaDatabase.shared.deleteTracks(sourceId: source.id)
            try SorrivaDatabase.shared.deleteFolderStats(sourceId: source.id)
        }

        var scanned = 0
        var skipped = 0
        var artistCache: [String: Artist] = [:]
        var albumCache:  [String: Album]  = [:]

        for file in allFiles {
            let filename = (file.path as NSString).lastPathComponent
            let ext = (filename as NSString).pathExtension.lowercased()

            progressHandler(ScanProgress(
                sourceId: source.id, sourceName: source.displayName,
                phase: .scanning, filesFound: totalFiles,
                filesScanned: scanned, currentFile: filename
            ))

            // Read tags — skip WAV/AIFF (rarely have usable embedded tags)
            var meta = ParsedMetadata()
            if ext != "wav" && ext != "aif" && ext != "aiff" {
                if let headerData = await readHeader(session: readClient.session,
                                                     path: file.path,
                                                     readSize: readSize) {
                    switch ext {
                    case "mp3":
                        meta = parseID3v2(data: headerData)
                    case "flac":
                        meta = parseVorbisComment(data: headerData)
                    case "m4a", "aac", "alac":
                        meta = parseMP4Atoms(data: headerData)
                    default:
                        break
                    }
                } else {
                    skipped += 1
                }
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

        // Update folder stats for scanned folders
        let scannedFolders = Dictionary(grouping: allFiles) { file in
            (file.path as NSString).deletingLastPathComponent
        }
        for (folder, files) in scannedFolders {
            let count = files.count
            let bytes = files.reduce(0) { $0 + $1.size }
            try? SorrivaDatabase.shared.upsertFolderStat(
                sourceId: source.id, folderPath: folder,
                fileCount: count, totalBytes: bytes
            )
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

    // MARK: - Tag reading via Session.read() at maxReadSize

    /// Read file header using Session directly.
    /// The UNAS Pro requires reads at maxReadSize (8MB) — smaller reads stall.
    /// We request maxReadSize but only use the first 64KB for tag parsing.
    /// Uses DispatchSemaphore for reliable timeout — immune to cooperative thread blocking.
    private func readHeader(session: Session, path: String, readSize: UInt32) async -> Data? {
        let smbPath = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "\\")

        return await withCheckedContinuation { continuation in
            let semaphore = DispatchSemaphore(value: 0)
            var result: Data? = nil

            Task.detached {
                do {
                    let createResponse = try await session.create(
                        desiredAccess: [.genericRead],
                        fileAttributes: [],
                        shareAccess: [.read],
                        createDisposition: .open,
                        createOptions: [],
                        name: smbPath
                    )
                    let readResponse = try await session.read(
                        fileId: createResponse.fileId,
                        offset: 0,
                        length: readSize
                    )
                    _ = try? await session.close(fileId: createResponse.fileId)
                    // Take only first 64KB for tag parsing
                    let buf = readResponse.buffer
                    result = buf.count > 65536 ? Data(buf.prefix(65536)) : buf
                } catch {
                    print("SCAN: read error [\(error.localizedDescription)] — \(smbPath)")
                }
                semaphore.signal()
            }

            DispatchQueue.global(qos: .utility).async {
                // 60s timeout — 8MB over WiFi typically takes 5-15s
                if semaphore.wait(timeout: .now() + 60) == .timedOut {
                    print("SCAN: TIMEOUT 60s — \(smbPath)")
                }
                continuation.resume(returning: result)
            }
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
        let key = "\(artist.id)|\(title)"
        if let cached = cache[key] { return cached }
        if let existing = try SorrivaDatabase.shared.album(title: title, artistId: artist.id) {
            cache[key] = existing
            return existing
        }
        let now = Int(Date().timeIntervalSince1970)
        let album = Album(
            id: UUID().uuidString, title: title,
            sortTitle: makeSortName(title),
            primaryArtistId: artist.id, artistName: artist.name,
            year: year, genre: genre,
            artPathThumb: nil, artPathFull: nil,
            trackCount: 0, sourceId: sourceId,
            folderPath: folderPath,
            createdAt: now, updatedAt: now
        )
        try SorrivaDatabase.shared.upsertAlbum(album)
        try SorrivaDatabase.shared.upsertArtistAlbum(
            artistId: artist.id, albumId: album.id, role: "primary"
        )
        cache[key] = album
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
                let numStr = String(titleFromFilename[range])
                    .trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
                m.trackNumber = Int(numStr)
                titleFromFilename = String(titleFromFilename[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if titleFromFilename.isEmpty { titleFromFilename = filenameWithoutExtension(filename) }
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
            if m.album == nil { m.album = components[components.count - 1] }
        }

        return m
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
            if blockType == 4 && offset + blockSize <= data.count {
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
