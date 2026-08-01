import XCTest
import GRDB
@testable import Sorriva

// MARK: - AlbumGenreTests
// bAlbumGenreFromFirstTrack — v14 album_genres migration. Album.genre
// (single-value) is left untouched and unread by any UI; album_genres is
// now the authoritative multi-genre source, populated from the distinct
// genres actually present across an album's tracks at scan finalize.

final class AlbumGenreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-genre-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func copyFixture(_ resourceName: String, to destination: URL) throws {
        guard let url = Bundle(for: AlbumGenreTests.self)
            .url(forResource: resourceName, withExtension: "flac") else {
            XCTFail("Missing fixture resource \(resourceName).flac — add it to the SorrivaTests target.")
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

    private func fetchAlbums(sourceId: String) throws -> [Album] {
        try SorrivaDatabase.shared.dbQueue.read { db in
            try Album.filter(Album.Columns.sourceId == sourceId).fetchAll(db)
        }
    }

    // MARK: - Album spanning multiple genres records all of them

    func testAlbumSpanningMultipleGenresRecordsAllGenres() async throws {
        let sourceId = "genre-multi-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        let albumDir = tempDir.appendingPathComponent("MultiGenre-\(UUID().uuidString)", isDirectory: true)
        try copyFixture("fixture_t18_multi1", to: albumDir.appendingPathComponent("01 Track.flac"))
        try copyFixture("fixture_t18_multi2", to: albumDir.appendingPathComponent("02 Track.flac"))

        try await runScan(source: source)

        let albums = try fetchAlbums(sourceId: sourceId)
        XCTAssertEqual(albums.count, 1)

        let genres = try SorrivaDatabase.shared.albumGenres(albumId: albums.first!.id)
        XCTAssertEqual(Set(genres), Set(["Synth-Pop", "New Wave"]),
            "Both genres present across the album's tracks must be recorded — " +
            "no single-track-wins rollup that silently picks one.")
    }

    // MARK: - Single-genre album records exactly one genre

    func testSingleGenreAlbumRecordsOneGenre() async throws {
        let sourceId = "genre-single-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        let albumDir = tempDir.appendingPathComponent("ConsistentGenre-\(UUID().uuidString)", isDirectory: true)
        try copyFixture("fixture_t18_single1", to: albumDir.appendingPathComponent("01 Track.flac"))
        try copyFixture("fixture_t18_single2", to: albumDir.appendingPathComponent("02 Track.flac"))

        try await runScan(source: source)

        let albums = try fetchAlbums(sourceId: sourceId)
        let genres = try SorrivaDatabase.shared.albumGenres(albumId: albums.first!.id)

        XCTAssertEqual(genres, ["Rock"],
            "An album whose tracks all agree on genre must record exactly that one genre.")
    }

    // MARK: - Rescan clears stale genres rather than accumulating them

    func testRescanReplacesGenresRatherThanAccumulating() async throws {
        let sourceId = "genre-rescan-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        let albumDir = tempDir.appendingPathComponent("RescanGenre-\(UUID().uuidString)", isDirectory: true)
        try copyFixture("fixture_t18_single1", to: albumDir.appendingPathComponent("01 Track.flac"))

        try await runScan(source: source)
        let albums = try fetchAlbums(sourceId: sourceId)
        let albumId = albums.first!.id
        XCTAssertEqual(try SorrivaDatabase.shared.albumGenres(albumId: albumId), ["Rock"])

        // Retag the same file with a different genre and rescan.
        try copyFixture("fixture_t18_multi1", to: albumDir.appendingPathComponent("01 Track.flac"))
        try await runScan(source: source)

        let genresAfter = try SorrivaDatabase.shared.albumGenres(albumId: albumId)
        XCTAssertEqual(genresAfter, ["Synth-Pop"],
            "Rescanning must replace the album's genre set, not accumulate stale entries " +
            "from a previous tagging state.")
    }
}
