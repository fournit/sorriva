import Foundation
import SMBClient

// MARK: - ScanProgress
// Published by ScanCoordinator so any view can observe live scan status.

struct ScanProgress {
    var sourceId: String
    var sourceName: String
    var phase: ScanPhase
    var filesFound: Int
    var filesScanned: Int
    var currentFile: String

    enum ScanPhase {
        case statting       // quick file count + size pass
        case scanning       // full metadata read + index pass
        case finalizing     // updating counts, cleaning orphans
    }
}

// MARK: - ParsedMetadata
// Intermediate result from the tag parser — all fields optional since
// any tag field may be absent or malformed.

private struct ParsedMetadata {
    var title: String?
    var artist: String?
    var albumArtist: String?   // preferred over artist for album grouping
    var album: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var duration: Double?      // seconds
    var bitrate: Int?          // kbps
    var sampleRate: Int?       // Hz
}

// MARK: - SMBScanner
// Background actor — never touches UI directly.
// All DB writes go through SorrivaDatabase.shared.
// Progress updates are sent via a callback to ScanCoordinator (on main actor).

actor SMBScanner {

    // Audio extensions we index — lowercase
    private static let audioExtensions: Set<String> = [
        "flac", "mp3", "m4a", "aac", "wav", "aiff", "aif", "alac"
    ]

    // MARK: - Public API

    /// Quick stat pass — count audio files and sum sizes without reading content.
    /// Used by ScanCoordinator to detect changes since last scan.
    func statShare(source: LibrarySource) async throws -> (fileCount: Int, totalBytes: Int) {
        let client = SMBClient(host: source.host)
        try await client.login(username: source.username ?? "", password: source.password ?? "")
        defer { Task { try? await client.logoff() } }

        try await client.connectShare(source.share)
        defer { Task { try? await client.disconnectShare() } }

        return try await statDirectory(
            client: client,
            path: source.rootPath.isEmpty ? "/" : source.rootPath
        )
    }

    /// Full scan — walk share, parse metadata, write to SQLite.
    /// Calls progressHandler periodically so ScanCoordinator can publish updates.
    func scan(
        source: LibrarySource,
        progressHandler: @Sendable @escaping (ScanProgress) -> Void
    ) async throws {

        let client = SMBClient(host: source.host)
        try await client.login(username: source.username ?? "", password: source.password ?? "")
        defer { Task { try? await client.logoff() } }

        try await client.connectShare(source.share)
        defer { Task { try? await client.disconnectShare() } }

        let rootPath = source.rootPath.isEmpty ? "/" : source.rootPath

        // --- Phase 1: collect all audio file paths ---
        progressHandler(ScanProgress(
            sourceId: source.id,
            sourceName: source.displayName,
            phase: .statting,
            filesFound: 0,
            filesScanned: 0,
            currentFile: "Listing files…"
        ))

        var allFiles: [(path: String, size: Int)] = []
        try await collectAudioFiles(client: client, path: rootPath, results: &allFiles)

        let totalFiles = allFiles.count
        let totalBytes = allFiles.reduce(0) { $0 + $1.size }

        // --- Phase 2: read metadata + write to DB ---
        // Clear existing tracks for this source first — full rescan strategy.
        // Orphaned albums/artists are cleaned up in Phase 3.
        try SorrivaDatabase.shared.deleteTracks(sourceId: source.id)

        var scanned = 0
        var artistCache: [String: Artist] = [:]   // name → Artist (avoid redundant DB reads)
        var albumCache: [String: Album] = [:]      // "artistId|albumTitle" → Album

        for file in allFiles {
            let filename = (file.path as NSString).lastPathComponent
            let ext = (filename as NSString).pathExtension.lowercased()

            progressHandler(ScanProgress(
                sourceId: source.id,
                sourceName: source.displayName,
                phase: .scanning,
                filesFound: totalFiles,
                filesScanned: scanned,
                currentFile: filename
            ))

            // Read first 64KB via FileReader partial read with a 10s timeout.
            // A stalled SMB read would hang the entire scan without this guard.
            let headerData: Data? = await withTimeout(seconds: 10) {
                let reader = client.fileReader(path: file.path)
                let data = try await reader.read(offset: 0, length: 65536)
                try await reader.close()
                return data
            }

            // Parse metadata from header bytes
            var meta = ParsedMetadata()
            if let data = headerData {
                switch ext {
                case "mp3":
                    meta = parseID3v2(data: data)
                case "flac":
                    meta = parseVorbisComment(data: data)
                case "m4a", "aac", "alac":
                    meta = parseMP4Atoms(data: data)
                default:
                    break
                }
            }

            // Fall back to path structure for missing fields
            meta = fillFromPath(meta: meta, filePath: file.path, rootPath: rootPath)

            // Resolve/create artist
            let artistName = meta.albumArtist ?? meta.artist ?? "Unknown Artist"
            let artist = try resolveArtist(
                name: artistName,
                cache: &artistCache
            )

            // Resolve/create album
            let albumTitle = meta.album ?? "Unknown Album"
            let folderPath = (file.path as NSString).deletingLastPathComponent
            let album = try resolveAlbum(
                title: albumTitle,
                artist: artist,
                year: meta.year,
                genre: meta.genre,
                folderPath: folderPath,
                sourceId: source.id,
                cache: &albumCache
            )

            // Write track
            let trackTitle = meta.title ?? filenameWithoutExtension(filename)
            let now = Int(Date().timeIntervalSince1970)
            let track = Track(
                id: UUID().uuidString,
                title: trackTitle,
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

            // INSERT OR IGNORE — skip if filePath already exists (shouldn't happen
            // since we deleted tracks for this source above, but guards against races)
            if (try? SorrivaDatabase.shared.track(filePath: file.path)) == nil {
                try? SorrivaDatabase.shared.upsertTrack(track)
                try? SorrivaDatabase.shared.upsertTrackArtist(
                    trackId: track.id,
                    artistId: artist.id,
                    role: "primary"
                )
            }

            scanned += 1
        }

        // --- Phase 3: update denormalized counts, clean orphans ---
        progressHandler(ScanProgress(
            sourceId: source.id,
            sourceName: source.displayName,
            phase: .finalizing,
            filesFound: totalFiles,
            filesScanned: scanned,
            currentFile: "Finalizing…"
        ))

        try SorrivaDatabase.shared.deleteOrphanedAlbums()
        try SorrivaDatabase.shared.deleteOrphanedArtists()

        // Update denormalized counts for all affected artists and albums
        for artist in artistCache.values {
            try? SorrivaDatabase.shared.updateArtistCounts(artistId: artist.id)
        }
        for album in albumCache.values {
            try? SorrivaDatabase.shared.updateAlbumTrackCount(albumId: album.id)
        }

        // Stamp the source with final counts and fingerprint
        let finalTrackCount = try SorrivaDatabase.shared.trackCount(sourceId: source.id)
        try SorrivaDatabase.shared.updateScanComplete(
            sourceId: source.id,
            trackCount: finalTrackCount,
            fileCount: totalFiles,
            totalBytes: totalBytes
        )
    }

    // MARK: - Private helpers

    /// Recursive directory walk — collects (path, size) for all audio files.
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

    /// Stat pass — count + sum sizes without reading file content.
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

    /// Resolve or create an Artist record, using the in-memory cache to avoid
    /// redundant DB round-trips during a scan.
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

    /// Resolve or create an Album record, using the in-memory cache.
    private func resolveAlbum(
        title: String,
        artist: Artist,
        year: Int?,
        genre: String?,
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
            year: year,
            genre: genre,
            artPath: nil,
            trackCount: 0,
            sourceId: sourceId,
            folderPath: folderPath,
            createdAt: now,
            updatedAt: now
        )
        try SorrivaDatabase.shared.upsertAlbum(album)
        try SorrivaDatabase.shared.upsertArtistAlbum(
            artistId: artist.id,
            albumId: album.id,
            role: "primary"
        )
        cache[cacheKey] = album
        return album
    }

    // MARK: - Sort name

    /// Strip leading articles for alphabetical sort.
    /// "The Beatles" → "Beatles, The"
    /// "A Tribe Called Quest" → "Tribe Called Quest, A"
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

    private func filenameWithoutExtension(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }

    // MARK: - Path fallback

    /// Fill missing metadata fields from the file path structure.
    /// Expects: /root/Artist/Album/Track.flac or /root/Artist/Album/Disc N/Track.flac
    private func fillFromPath(meta: ParsedMetadata, filePath: String, rootPath: String) -> ParsedMetadata {
        var m = meta
        let relative = filePath.hasPrefix(rootPath)
            ? String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : filePath
        let components = relative.components(separatedBy: "/")

        // components[0] = Artist, components[1] = Album, components[last] = filename
        if m.albumArtist == nil && m.artist == nil && components.count >= 2 {
            m.artist = components[0]
        }
        if m.album == nil && components.count >= 3 {
            m.album = components[1]
        }
        if m.title == nil {
            let filename = components.last ?? ""
            var title = filenameWithoutExtension(filename)
            // Strip leading track number: "01 ", "01. ", "01 - "
            if let range = title.range(of: #"^\d{1,3}[\s.\-–]+\s*"#, options: .regularExpression) {
                title = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            m.title = title.isEmpty ? filenameWithoutExtension(filename) : title
        }
        if m.trackNumber == nil {
            let filename = components.last ?? ""
            if let match = filename.range(of: #"^(\d{1,3})"#, options: .regularExpression) {
                m.trackNumber = Int(filename[match])
            }
        }
        return m
    }

    // MARK: - ID3v2 parser (MP3, some AAC)

    private func parseID3v2(data: Data) -> ParsedMetadata {
        var meta = ParsedMetadata()
        guard data.count > 10 else { return meta }

        // Check ID3 header: "ID3" + version + flags + 4-byte syncsafe size
        guard data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return meta }

        let size = id3SyncsafeInt(data: data, offset: 6)
        guard size > 0, size + 10 <= data.count else { return meta }

        let version = data[3]  // ID3v2 major version: 3 or 4
        var offset = 10

        while offset + 10 < size + 10 {
            guard offset + 10 <= data.count else { break }

            // Frame ID: 4 bytes ASCII
            let frameID = String(bytes: data[offset..<offset+4], encoding: .isoLatin1) ?? ""
            guard !frameID.isEmpty && frameID != "\0\0\0\0" else { break }

            // Frame size: 4 bytes (syncsafe in v2.4, regular int in v2.3)
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
            case "TIT2": meta.title      = id3TextFrame(frameData)
            case "TPE1": meta.artist     = id3TextFrame(frameData)
            case "TPE2": meta.albumArtist = id3TextFrame(frameData)
            case "TALB": meta.album      = id3TextFrame(frameData)
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
        switch encoding {
        case 0:  return String(data: textData, encoding: .isoLatin1)?.trimmingCharacters(in: .controlCharacters)
        case 1:  return String(data: textData, encoding: .utf16)?.trimmingCharacters(in: .controlCharacters)
        case 2:  return String(data: textData, encoding: .utf16BigEndian)?.trimmingCharacters(in: .controlCharacters)
        case 3:  return String(data: textData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
        default: return String(data: textData, encoding: .isoLatin1)?.trimmingCharacters(in: .controlCharacters)
        }
    }

    /// Decode ID3 genre — may be numeric reference like "(17)" for "Rock"
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
    // FLAC structure: fLaC marker → metadata blocks.
    // COMMENT block type = 4. Each comment is "KEY=value" UTF-8.

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
                // Vorbis comment block
                let block = data[offset..<(offset+blockSize)]
                parseVorbisBlock(block: block, meta: &meta)
            }

            offset += blockSize
            if isLast || offset >= data.count { break }
        }
        return meta
    }

    private func parseVorbisBlock(block: Data, meta: inout ParsedMetadata) {
        // Rebase to zero-indexed Data so subscripts are safe regardless of slice origin
        let block = Data(block)
        var pos = 0
        guard pos + 4 <= block.count else { return }

        // Vendor string length (little-endian)
        let vendorLen = Int(block[pos]) | Int(block[pos+1]) << 8
                      | Int(block[pos+2]) << 16 | Int(block[pos+3]) << 24
        pos += 4 + vendorLen
        guard pos + 4 <= block.count else { return }

        // Comment count
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
                    case "ALBUMARTIST": meta.albumArtist = value
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
    // Walks the moov → udta → meta → ilst atom tree.
    // iTunes tags live in ilst as named child atoms.

    private func parseMP4Atoms(data: Data) -> ParsedMetadata {
        var meta = ParsedMetadata()
        guard data.count > 8 else { return meta }

        // Find moov atom in the first 64KB
        if let moovOffset = findAtom(name: "moov", data: data, offset: 0) {
            let moovSize = atomSize(data: data, offset: moovOffset)
            let moovEnd = min(moovOffset + moovSize, data.count)
            if let udtaOffset = findAtom(name: "udta", data: data, offset: moovOffset + 8, end: moovEnd) {
                let udtaSize = atomSize(data: data, offset: udtaOffset)
                let udtaEnd = min(udtaOffset + udtaSize, data.count)
                if let metaOffset = findAtom(name: "meta", data: data, offset: udtaOffset + 8, end: udtaEnd) {
                    let metaSize = atomSize(data: data, offset: metaOffset)
                    let metaEnd = min(metaOffset + metaSize, data.count)
                    // meta atom has a 4-byte version/flags field before children
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

            // Each ilst child contains a 'data' atom with the value
            if let dataOffset = findAtom(name: "data", data: data, offset: pos + 8, end: atomEnd) {
                let dataSize = atomSize(data: data, offset: dataOffset)
                // data atom: 4 size + 4 name + 4 type + 4 locale + value
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
                        // Binary: 2 bytes padding + 2 bytes track + 2 bytes total
                        if valueData.count >= 4 {
                            meta.trackNumber = Int(valueData[2]) << 8 | Int(valueData[3])
                        }
                    case "disk":
                        if valueData.count >= 4 {
                            meta.discNumber = Int(valueData[2]) << 8 | Int(valueData[3])
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

    // MARK: - Timeout helper

    /// Runs an async throwing closure with a timeout. Returns nil if it times out or throws.
    private func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                try? await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            // Return first result — either the operation or nil from timeout
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
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
