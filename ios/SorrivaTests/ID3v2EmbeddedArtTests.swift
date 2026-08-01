import XCTest
import GRDB
@testable import Sorriva

// MARK: - ID3v2EmbeddedArtTests
// Regression guard for a real, previously-unknown parser bug found via a
// live library scan (2026-07-27): parseID3v2's upfront guard rejected the
// ENTIRE file whenever the declared ID3 tag size (which includes embedded
// artwork) exceeded the scanner's 64KB header-read window — even though the
// actual text frames (TIT2/TALB/TPE2/etc.) are almost always near the front
// of the tag, well within reach. This affected any MP3 with embedded cover
// art over ~64KB, which is routine output from EAC/dbPoweramp rips — not a
// rare edge case like the analogous FLAC PICTURE-before-VORBIS_COMMENT gap
// (ScannerParsingEdgeCaseTests test 16), which stays documented as a known
// limitation. This one was fixed outright.
//
// Fixture is a real MP3 (trimmed to 100KB; the scanner never reads past the
// first 64KB regardless of file size, and the trim preserves those bytes
// byte-for-byte) with a genuine ID3v2.3 tag: TIT2, TALB, TRCK, TIT1, COMM,
// six WM/* PRIV frames (classic Windows Media Player CD-rip artifacts),
// TPUB, TPE2 (album artist — no TPE1 track artist present), TPOS, and a
// ~327KB embedded APIC cover image that pushes the declared tag size to
// ~331KB, well past the 64KB window.

final class ID3v2EmbeddedArtTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("id3-embedded-art-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func copyFixture(_ resourceName: String, withExtension ext: String, to destination: URL) throws {
        guard let url = Bundle(for: ID3v2EmbeddedArtTests.self)
            .url(forResource: resourceName, withExtension: ext) else {
            XCTFail("Missing fixture resource \(resourceName).\(ext) — add it to the SorrivaTests target.")
            return
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
    }

    private func makeTestSource(id: String) -> LibrarySource {
        TestDatabase.makeSource(id: id, displayName: "Fixture NAS", host: "fixture", share: "fixture", rootPath: "/")
    }

    private func runScan(source: LibrarySource) async throws {
        let scanner = SMBScanner(readerFactory: { [tempDir] _ in
            FixtureMediaSourceReader(rootURL: tempDir!)
        })
        try await scanner.scan(source: source, progressHandler: { _ in })
    }

    private func fetchTracks(sourceId: String) throws -> [Track] {
        try SorrivaDatabase.shared.dbQueue.read { db in
            try Track.filter(Track.Columns.sourceId == sourceId).fetchAll(db)
        }
    }

    func testTagsFoundDespiteLargeEmbeddedArtPushingDeclaredSizePast64KB() async throws {
        let sourceId = "id3-art-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        let albumDir = tempDir.appendingPathComponent("MetheanyAlbum-\(UUID().uuidString)", isDirectory: true)
        try copyFixture("fixture_mp3_large_embedded_art", withExtension: "mp3",
            to: albumDir.appendingPathComponent("03 Track.mp3"))

        try await runScan(source: source)

        let tracks = try fetchTracks(sourceId: sourceId)
        guard let track = tracks.first else {
            XCTFail("Expected one track after scan")
            return
        }

        XCTAssertEqual(track.title, "The Girls Next Door",
            "TIT2 sits well within the first 602 bytes of the tag — must be reached " +
            "regardless of the ~331KB declared total tag size from the embedded APIC frame.")
        XCTAssertEqual(track.albumTitle, "We Live Here")
        XCTAssertEqual(track.trackNumber, 3)
        XCTAssertEqual(track.discNumber, 1)
        XCTAssertEqual(track.artistName, "Pat Metheny Group",
            "No TPE1 frame is present in this file, only TPE2 (album artist) — " +
            "must fall back correctly, same as the equivalent FLAC ALBUMARTIST-only case.")
    }
}
