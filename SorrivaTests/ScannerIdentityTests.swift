import XCTest
import GRDB
@testable import Sorriva

// MARK: - ScannerIdentityTests
// Drives the REAL SMBScanner through FixtureMediaSourceReader — not a test
// double reimplementing scanner logic. This is what ScannerTests.swift's
// existing four "WP-02 acceptance" tests do not do; see
// sorriva-scanner-handoff-2026-07-25.md §4 for why that matters.
//
// SorrivaDatabase.shared is safe to use directly here: its init detects
// XCTestConfigurationFilePath and routes to an isolated, unique temp-directory
// sqlite file per test run, never the real device library.

final class ScannerIdentityTests: XCTestCase {

    private var tempDir: URL!

    private var albumFolderName: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-fixture-\(UUID().uuidString)", isDirectory: true)
        // Unique per test method — tracks.filePath has a GLOBAL unique constraint,
        // not scoped per sourceId. SorrivaDatabase.shared is one sqlite file for
        // the whole test run (all test methods share it), so two tests using the
        // identical literal path string would collide even under different
        // sourceIds. A real NAS scan would never produce two identical absolute
        // paths, so this uniqueness is just making the fixture realistic.
        albumFolderName = "TestAlbum-\(UUID().uuidString)"
        let albumDir = tempDir.appendingPathComponent("TestArtist/\(albumFolderName!)", isDirectory: true)
        try FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)

        try copyFixture("fixture_track1", to: albumDir.appendingPathComponent("01 Track One.flac"))
        try copyFixture("fixture_track2", to: albumDir.appendingPathComponent("02 Track Two.flac"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func copyFixture(_ resourceName: String, to destination: URL) throws {
        guard let url = Bundle(for: ScannerIdentityTests.self).url(forResource: resourceName, withExtension: "flac") else {
            XCTFail("Missing fixture resource \(resourceName).flac — add it to the SorrivaTests target as a bundled resource.")
            return
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
    }

    private func makeTestSource(id: String) -> LibrarySource {
        TestDatabase.makeSource(id: id, displayName: "Fixture NAS", host: "fixture", share: "fixture", rootPath: "/")
    }

    private func fetchTracks(sourceId: String) throws -> [Track] {
        try SorrivaDatabase.shared.dbQueue.read { db in
            try Track.filter(Track.Columns.sourceId == sourceId).fetchAll(db)
        }
    }

    // MARK: - Test 2 (primary reproduction) — sorriva-scanner-handoff-2026-07-25.md §5.2

    /// Scans once, edits a fixture's ARTIST tag on disk, rescans, and asserts
    /// the change is picked up.
    ///
    /// FAILS TODAY. tracks.filePath has a `.notNull().unique()` constraint
    /// (v6 migration). SMBScanner mints a fresh UUID for Track.id on every
    /// scan and calls the non-idempotent upsertTrack (a bare INSERT). On
    /// rescan, the second INSERT for the same filePath violates the UNIQUE
    /// constraint, throws, and `try?` swallows it silently — the updated
    /// artist name is dropped and the stale value from pass 1 persists.
    /// This is the reproduction the WP-02 fix (upsertTrackIdempotent as the
    /// production call) must turn green.
    func testScannerRescanUpdatesChangedTags() async throws {
        let sourceId = "fixture-rescan-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        let scanner = SMBScanner(readerFactory: { [tempDir] _ in
            FixtureMediaSourceReader(rootURL: tempDir!)
        })

        try await scanner.scan(source: source, progressHandler: { _ in })

        let firstPass = try fetchTracks(sourceId: sourceId)
        guard let trackOneBefore = firstPass.first(where: { $0.filePath.hasSuffix("01 Track One.flac") }) else {
            XCTFail("Expected track '01 Track One.flac' after first scan")
            return
        }
        XCTAssertEqual(trackOneBefore.artistName, "Test Artist")

        // Simulate an external tagger editing the ARTIST field on disk, then rescan.
        let albumDir = tempDir.appendingPathComponent("TestArtist/\(albumFolderName!)", isDirectory: true)
        try copyFixture("fixture_track1_v2", to: albumDir.appendingPathComponent("01 Track One.flac"))

        try await scanner.scan(source: source, progressHandler: { _ in })

        let secondPass = try fetchTracks(sourceId: sourceId)
        guard let trackOneAfter = secondPass.first(where: { $0.filePath.hasSuffix("01 Track One.flac") }) else {
            XCTFail("Expected track '01 Track One.flac' after second scan")
            return
        }

        XCTAssertEqual(
            trackOneAfter.artistName, "Test Artist Updated",
            "Rescanning should pick up the changed ARTIST tag. If this fails with the OLD " +
            "artist name, SMBScanner is still calling the non-idempotent upsertTrack — the " +
            "rescan's INSERT is silently failing on the filePath UNIQUE constraint."
        )
        XCTAssertEqual(trackOneAfter.id, trackOneBefore.id,
            "Track identity must survive a tag update — same file, same row.")
    }

    // MARK: - Documents current (accidental) behavior — NOT proof WP-02 works

    /// Scans an UNCHANGED fixture tree twice. Currently passes, but only
    /// because the second pass's duplicate INSERT is silently dropped by the
    /// filePath UNIQUE constraint + `try?` — the row from pass 1 is simply
    /// never touched again, so its id trivially "survives." This is NOT
    /// evidence of correct idempotent upsert; testScannerRescanUpdatesChangedTags
    /// above is the test that actually distinguishes correct behavior from
    /// this accidental-silence failure mode. Kept as a regression guard for
    /// row count only, not as a WP-02 acceptance test.
    func testScannerFullScanTwiceOnUnchangedFixtureKeepsSameRowCount() async throws {
        let sourceId = "fixture-twice-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        let scanner = SMBScanner(readerFactory: { [tempDir] _ in
            FixtureMediaSourceReader(rootURL: tempDir!)
        })

        try await scanner.scan(source: source, progressHandler: { _ in })
        let firstPass = try fetchTracks(sourceId: sourceId)
        XCTAssertEqual(firstPass.count, 2)

        try await scanner.scan(source: source, progressHandler: { _ in })
        let secondPass = try fetchTracks(sourceId: sourceId)

        XCTAssertEqual(secondPass.count, 2,
            "No duplicate rows after rescanning an unchanged tree.")
        XCTAssertEqual(
            Set(firstPass.map(\.id)), Set(secondPass.map(\.id)),
            "IDs unchanged — currently true only because the duplicate INSERT is silently " +
            "dropped, not because of real idempotent upsert. See testScannerRescanUpdatesChangedTags."
        )
    }
}
