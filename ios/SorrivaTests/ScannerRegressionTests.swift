import XCTest
import GRDB
@testable import Sorriva

// MARK: - ScannerRegressionTests
// Regression guards for the 2026-07-25 artist/album fixes (shipped v0.0.37),
// driving the real SMBScanner through FixtureMediaSourceReader — tests 6-14
// from sorriva-scanner-handoff-2026-07-25.md §5.2. All expected to PASS —
// these lock in behavior that already shipped, unlike ScannerIdentityTests'
// tests 1-2 which reproduced an unfixed defect.
//
// Each test uses its own unique temp directory and folder names (embedding a
// UUID) so tests never collide on the global tracks.filePath / albums
// folderPath keys within the same test-run process — see ScannerIdentityTests
// for why this matters (SorrivaDatabase.shared is one file per process, not
// per test method).

final class ScannerRegressionTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-regression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func copyFixture(_ resourceName: String, to destination: URL) throws {
        guard let url = Bundle(for: ScannerRegressionTests.self)
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

    private func fetchTracks(sourceId: String) throws -> [Track] {
        try SorrivaDatabase.shared.dbQueue.read { db in
            try Track.filter(Track.Columns.sourceId == sourceId).fetchAll(db)
        }
    }

    private func fetchAlbums(sourceId: String) throws -> [Album] {
        try SorrivaDatabase.shared.dbQueue.read { db in
            try Album.filter(Album.Columns.sourceId == sourceId).fetchAll(db)
        }
    }

    // MARK: - Test 6: compilation track keeps own artist

    func testCompilationTrackKeepsOwnArtist() async throws {
        let sourceId = "reg6-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        let albumDir = tempDir.appendingPathComponent("Compilation-\(UUID().uuidString)", isDirectory: true)
        try copyFixture("fixture_t6_compilation", to: albumDir.appendingPathComponent("01 Situation.flac"))

        try await runScan(source: source)

        let tracks = try fetchTracks(sourceId: sourceId)
        let albums = try fetchAlbums(sourceId: sourceId)

        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.artistName, "Yazoo",
            "Track artist must be the performer (ARTIST tag), not the album artist.")
        XCTAssertEqual(albums.first?.artistName, "Various Artists",
            "Album artist must be ALBUMARTIST, distinct from the track's own artist.")
    }

    // MARK: - Test 7: track artist falls back to album artist when absent

    func testTrackArtistFallsBackToAlbumArtistWhenAbsent() async throws {
        let sourceId = "reg7-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        let albumDir = tempDir.appendingPathComponent("AlbumArtistOnly-\(UUID().uuidString)", isDirectory: true)
        try copyFixture("fixture_t7_albumartist_only", to: albumDir.appendingPathComponent("01 Some Track.flac"))

        try await runScan(source: source)

        let tracks = try fetchTracks(sourceId: sourceId)
        let albums = try fetchAlbums(sourceId: sourceId)

        XCTAssertEqual(tracks.first?.artistName, "The Blue Nile",
            "With no ARTIST tag, the track must fall back to ALBUMARTIST.")
        XCTAssertEqual(albums.first?.artistName, "The Blue Nile")
    }

    // MARK: - Test 8: album artist falls back to track artist when absent (inverse of 7)

    func testAlbumArtistFallsBackToArtistWhenAbsent() async throws {
        let sourceId = "reg8-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        let albumDir = tempDir.appendingPathComponent("ArtistOnly-\(UUID().uuidString)", isDirectory: true)
        try copyFixture("fixture_t8_artist_only", to: albumDir.appendingPathComponent("01 Some Track.flac"))

        try await runScan(source: source)

        let tracks = try fetchTracks(sourceId: sourceId)
        let albums = try fetchAlbums(sourceId: sourceId)

        XCTAssertEqual(tracks.first?.artistName, "Prefab Sprout")
        XCTAssertEqual(albums.first?.artistName, "Prefab Sprout",
            "With no ALBUMARTIST tag, the album must fall back to ARTIST.")
    }

    // MARK: - Test 9: artist name matching is case- and whitespace-insensitive

    func testArtistNameMatchingIsCaseAndWhitespaceInsensitive() async throws {
        let sourceId = "reg9-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        // Filenames sorted alphabetically ensure deterministic scan order —
        // FixtureMediaSourceReader.listDirectory sorts entries for this reason.
        let dir = tempDir.appendingPathComponent("CaseTest-\(UUID().uuidString)", isDirectory: true)
        try copyFixture("fixture_t9_01_original", to: dir.appendingPathComponent("01_original.flac"))
        try copyFixture("fixture_t9_02_lowercase", to: dir.appendingPathComponent("02_lowercase.flac"))
        try copyFixture("fixture_t9_03_trailing", to: dir.appendingPathComponent("03_trailing.flac"))

        try await runScan(source: source)

        let tracks = try fetchTracks(sourceId: sourceId)
        XCTAssertEqual(tracks.count, 3, "All three tracks should be scanned.")

        let artistIds = Set(tracks.map(\.primaryArtistId))
        XCTAssertEqual(artistIds.count, 1,
            "\"Yazoo\", \"yazoo\", and \"Yazoo \" must resolve to exactly one artist row.")

        let artist = try await SorrivaDatabase.shared.dbQueue.read { db in
            try Artist.filter(Artist.Columns.id == artistIds.first!).fetchOne(db)
        }
        XCTAssertEqual(artist?.name, "Yazoo",
            "Display name should be taken from the first occurrence scanned (01_original.flac).")
    }

    // MARK: - Test 10: empty-after-trim artist becomes "Unknown Artist"

    func testArtistNameEmptyAfterTrimBecomesUnknown() async throws {
        let sourceId = "reg10-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        let albumDir = tempDir.appendingPathComponent("EmptyArtist-\(UUID().uuidString)", isDirectory: true)
        try copyFixture("fixture_t10_empty_artist", to: albumDir.appendingPathComponent("01 Some Track.flac"))

        try await runScan(source: source)

        let tracks = try fetchTracks(sourceId: sourceId)
        XCTAssertEqual(tracks.first?.artistName, "Unknown Artist")

        let artists = try await SorrivaDatabase.shared.dbQueue.read { db in try Artist.fetchAll(db) }
        XCTAssertFalse(artists.contains { $0.name.trimmingCharacters(in: .whitespaces).isEmpty },
            "No artist row should ever have an empty (whitespace-only) display name.")
    }

    // MARK: - Test 11: compilation placeholders hidden from artist browse

    @MainActor
    func testCompilationPlaceholdersHiddenFromArtistBrowse() throws {
        // DB-only — no scan needed. Seed artist rows directly, matching how
        // LibraryService.listArtists() and albumsForArtist() are expected to behave.
        let names = ["VA", "Various", "Various Artists", "Yazoo-\(UUID().uuidString)"]
        var seededIds: [String: String] = [:]

        try SorrivaDatabase.shared.dbQueue.write { db in
            for name in names {
                let id = UUID().uuidString
                let now = Int(Date().timeIntervalSince1970)
                let artist = Artist(
                    id: id, name: name, sortName: name,
                    imageURL: nil, albumCount: 0, trackCount: 0,
                    createdAt: now, updatedAt: now
                )
                try artist.save(db)
                seededIds[name] = id
            }
        }

        let service = LibraryService(repository: GRDBLibraryRepository(database: .shared))
        let visible = service.listArtists().map(\.name)

        for hiddenName in ["VA", "Various", "Various Artists"] {
            XCTAssertFalse(visible.contains(hiddenName),
                "\"\(hiddenName)\" must be hidden from artist browse.")
        }
        XCTAssertTrue(visible.contains(where: { $0.hasPrefix("Yazoo-") }),
            "A real artist name must still appear in the browse list.")

        // Hidden rows must still resolve when queried directly (e.g. from an album's artist link).
        for hiddenName in ["VA", "Various", "Various Artists"] {
            let id = seededIds[hiddenName]!
            // No crash / no special-casing needed — albumsForArtist has no name filter.
            _ = service.albumsForArtist(id)
        }
    }

    // MARK: - Test 12: two folders, identical album tags, remain separate albums

    func testTwoFoldersWithIdenticalAlbumTagsRemainSeparateAlbums() async throws {
        let sourceId = "reg12-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        let folderA = tempDir.appendingPathComponent("FolderA-\(UUID().uuidString)", isDirectory: true)
        let folderB = tempDir.appendingPathComponent("FolderB-\(UUID().uuidString)", isDirectory: true)
        try copyFixture("fixture_t12_folderA", to: folderA.appendingPathComponent("01 Track.flac"))
        try copyFixture("fixture_t12_folderB", to: folderB.appendingPathComponent("01 Track.flac"))

        try await runScan(source: source)

        let albums = try fetchAlbums(sourceId: sourceId)
        XCTAssertEqual(albums.count, 2,
            "Identical ALBUM/ALBUMARTIST tags in two different folders must remain two separate albums " +
            "— folderPath is the sole dedup key (regression guard for fAlbumSplitInvestigation closure).")
    }

    // MARK: - Test 13: one folder always resolves to one album, regardless of tag content

    func testSameFolderAlwaysResolvesToOneAlbum() async throws {
        let sourceId = "reg13-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        let folder = tempDir.appendingPathComponent("SameFolder-\(UUID().uuidString)", isDirectory: true)
        try copyFixture("fixture_t13_track1", to: folder.appendingPathComponent("01 Track.flac"))
        try copyFixture("fixture_t13_track2", to: folder.appendingPathComponent("02 Track.flac"))

        try await runScan(source: source)

        let albums = try fetchAlbums(sourceId: sourceId)
        let tracks = try fetchTracks(sourceId: sourceId)

        XCTAssertEqual(albums.count, 1,
            "Two tracks in the same folder with DIFFERENT ALBUM tags must still resolve to one album.")
        XCTAssertEqual(tracks.count, 2)
        XCTAssertTrue(tracks.allSatisfy { $0.albumId == albums.first?.id },
            "Both tracks must belong to the same single album row.")
    }

    // MARK: - Test 14: multi-disc sibling folders remain separate albums

    func testMultiDiscFoldersRemainSeparateAlbums() async throws {
        let sourceId = "reg14-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        let base = tempDir.appendingPathComponent("MultiDisc-\(UUID().uuidString)", isDirectory: true)
        try copyFixture("fixture_t14_cd1", to: base.appendingPathComponent("CD1/01 Track.flac"))
        try copyFixture("fixture_t14_cd2", to: base.appendingPathComponent("CD2/01 Track.flac"))
        try copyFixture("fixture_t14_cd3", to: base.appendingPathComponent("CD3/01 Track.flac"))

        try await runScan(source: source)

        let albums = try fetchAlbums(sourceId: sourceId)
        XCTAssertEqual(albums.count, 3,
            "CD1/CD2/CD3 sibling folders must remain three separate albums — no programmatic " +
            "collapse of multi-disc folder structures (product decision, not a defect).")
    }
}
