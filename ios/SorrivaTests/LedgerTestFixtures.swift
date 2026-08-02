import Foundation
@testable import Sorriva

// MARK: - LedgerTestFixtures
// Builds a real directory of real FLAC files on disk for the ledger tests.
//
// The files are synthesized rather than stubbed, and SMBScanner's actual
// parseVorbisComment runs against them. That matters: a fixture that returned
// canned metadata would pass whether or not the parser worked, and the tests
// would prove nothing about the path they claim to cover.
//
// They are minimal but structurally valid — "fLaC" magic, a STREAMINFO block
// carrying sample rate and total samples so duration parses, and a
// VORBIS_COMMENT block with the tags. That is everything the scanner reads from
// the first 64KB; no audio frames are needed because the scanner never decodes.

enum LedgerTestFixtures {

    // MARK: - Tree construction

    struct Spec {
        let folder: String          // relative, e.g. "Miles Davis/Kind of Blue"
        let trackTitles: [String]
        var artist: String = "Test Artist"
        var album: String = "Test Album"
    }

    /// Default tree: 3 folders, 9 files. Small enough that a test runs in
    /// milliseconds, large enough that "kill at file 4" leaves a real remainder.
    static let defaultSpecs: [Spec] = [
        Spec(folder: "Miles Davis/Kind of Blue",
             trackTitles: ["So What", "Freddie Freeloader", "Blue in Green"],
             artist: "Miles Davis", album: "Kind of Blue"),
        Spec(folder: "Daft Punk/Discovery",
             trackTitles: ["One More Time", "Aerodynamic", "Digital Love"],
             artist: "Daft Punk", album: "Discovery"),
        Spec(folder: "Portishead/Dummy",
             trackTitles: ["Mysterons", "Sour Times", "Strangers"],
             artist: "Portishead", album: "Dummy"),
    ]

    /// Create a fixture tree in a unique temp directory. Caller deletes it in
    /// tearDown.
    @discardableResult
    static func makeTree(specs: [Spec] = defaultSpecs) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorriva-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for spec in specs {
            let dir = root.appendingPathComponent(spec.folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (idx, title) in spec.trackTitles.enumerated() {
                let name = String(format: "%02d %@.flac", idx + 1, sanitize(title))
                let data = flacFile(title: title, artist: spec.artist,
                                    album: spec.album, trackNumber: idx + 1)
                try data.write(to: dir.appendingPathComponent(name))
            }
        }
        return root
    }

    /// Add one folder to an existing tree — the "new folder appeared" case.
    @discardableResult
    static func addFolder(to root: URL, spec: Spec) throws -> URL {
        let dir = root.appendingPathComponent(spec.folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (idx, title) in spec.trackTitles.enumerated() {
            let name = String(format: "%02d %@.flac", idx + 1, sanitize(title))
            let data = flacFile(title: title, artist: spec.artist,
                                album: spec.album, trackNumber: idx + 1)
            try data.write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    static func removeFolder(_ relativePath: String, from root: URL) throws {
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(relativePath, isDirectory: true))
    }

    /// Change a file's modification time WITHOUT changing its size.
    ///
    /// This is the tag-edit case (bTagEditsNotDetected): external taggers write
    /// into the FLAC padding block, so file count and total bytes are unchanged
    /// and only mtime moves. Verified on device 2026-07-31 with a real Mp3tag
    /// edit; this reproduces it deterministically.
    static func touchPreservingSize(_ fileURL: URL, secondsInFuture: TimeInterval = 120) throws {
        let sizeBefore = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? -1
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(secondsInFuture)],
            ofItemAtPath: fileURL.path)
        let sizeAfter = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? -2
        precondition(sizeBefore == sizeAfter,
                     "touchPreservingSize must not change file size")
    }

    /// Rewrite a file with different content AND a different size — the
    /// "file genuinely changed" case, which count/bytes alone would catch.
    static func rewrite(_ fileURL: URL, title: String, artist: String,
                        album: String, trackNumber: Int, extraPadding: Int = 512) throws {
        var data = flacFile(title: title, artist: artist, album: album,
                            trackNumber: trackNumber)
        data.append(Data(repeating: 0, count: extraPadding))
        try data.write(to: fileURL)
    }

    static func files(in root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root,
                                                     includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "flac" }.sorted {
            $0.path < $1.path
        }
    }

    // MARK: - FLAC synthesis

    /// A structurally valid minimal FLAC file.
    ///
    /// Layout, matching SMBScanner.parseVorbisComment exactly:
    ///   "fLaC"
    ///   block header (1 byte type | last-flag, 3 bytes big-endian length)
    ///   STREAMINFO   (type 0, 34 bytes) — sample rate + total samples => duration
    ///   VORBIS_COMMENT (type 4, last)  — TITLE / ARTIST / ALBUM / TRACKNUMBER
    static func flacFile(title: String, artist: String, album: String,
                         trackNumber: Int,
                         sampleRate: Int = 44_100,
                         durationSeconds: Int = 180) -> Data {
        var out = Data("fLaC".utf8)

        // --- STREAMINFO, type 0, not last ---
        var info = Data()
        info.append(contentsOf: [0x10, 0x00])              // min block size 4096
        info.append(contentsOf: [0x10, 0x00])              // max block size 4096
        info.append(contentsOf: [0x00, 0x00, 0x00])        // min frame size
        info.append(contentsOf: [0x00, 0x00, 0x00])        // max frame size

        // 20 bits sample rate | 3 bits (channels-1) | 5 bits (bitsPerSample-1)
        // then 36 bits total samples. The parser reads bytes 10..17 of the block.
        let totalSamples = sampleRate * durationSeconds
        let channelsMinus1 = 1                              // stereo
        let bitsMinus1 = 15                                 // 16-bit
        let packed = (UInt64(sampleRate) << 44)
                   | (UInt64(channelsMinus1) << 41)
                   | (UInt64(bitsMinus1) << 36)
                   |  UInt64(totalSamples)
        for shift in stride(from: 56, through: 0, by: -8) {
            info.append(UInt8((packed >> UInt64(shift)) & 0xFF))
        }
        info.append(Data(repeating: 0, count: 16))          // MD5 signature
        out.append(blockHeader(type: 0, size: info.count, isLast: false))
        out.append(info)

        // --- VORBIS_COMMENT, type 4, last ---
        var comment = Data()
        let vendor = Data("Sorriva test fixture".utf8)
        comment.append(le32(UInt32(vendor.count)))
        comment.append(vendor)

        let tags = [
            "TITLE=\(title)",
            "ARTIST=\(artist)",
            "ALBUM=\(album)",
            "ALBUMARTIST=\(artist)",
            "TRACKNUMBER=\(trackNumber)",
            "DATE=2020",
            "GENRE=Test",
        ]
        comment.append(le32(UInt32(tags.count)))
        for tag in tags {
            let d = Data(tag.utf8)
            comment.append(le32(UInt32(d.count)))
            comment.append(d)
        }
        out.append(blockHeader(type: 4, size: comment.count, isLast: true))
        out.append(comment)

        // Pad so files are a plausible size and the header read has room.
        out.append(Data(repeating: 0, count: 2048))
        return out
    }

    // MARK: - Helpers

    /// Metadata block header: high bit = last-block flag, low 7 = type,
    /// then 24-bit BIG-endian length.
    private static func blockHeader(type: UInt8, size: Int, isLast: Bool) -> Data {
        var d = Data()
        d.append(isLast ? (type | 0x80) : type)
        d.append(UInt8((size >> 16) & 0xFF))
        d.append(UInt8((size >> 8) & 0xFF))
        d.append(UInt8(size & 0xFF))
        return d
    }

    /// Vorbis comment lengths are LITTLE-endian, unlike the block header.
    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
              UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-")
    }
}
