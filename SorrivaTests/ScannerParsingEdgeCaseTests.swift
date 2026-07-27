import XCTest
import GRDB
@testable import Sorriva

// MARK: - ScannerParsingEdgeCaseTests
// Tests 15-17 from sorriva-scanner-handoff-2026-07-25.md §5.2 — FLAC parsing
// edge cases, distinct in kind from ScannerRegressionTests' artist/album
// identity tests. Test 16 is EXPECTED TO FAIL — it documents a known,
// unfixed parser limitation rather than reproducing something to fix this
// session (tracked separately behind fScanFailureUtility).

final class ScannerParsingEdgeCaseTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-parsing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func copyFixture(_ resourceName: String, to destination: URL) throws {
        guard let url = Bundle(for: ScannerParsingEdgeCaseTests.self)
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

    // MARK: - Test 15: WMP-style YEAR field parsed (not just DATE)

    func testYearTagParsedFromNonStandardYEARField() async throws {
        let sourceId = "reg15-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        let albumDir = tempDir.appendingPathComponent("YearField-\(UUID().uuidString)", isDirectory: true)
        try copyFixture("fixture_t15_year_field", to: albumDir.appendingPathComponent("01 Some Track.flac"))

        try await runScan(source: source)

        let tracks = try fetchTracks(sourceId: sourceId)
        XCTAssertEqual(tracks.first?.year, 2007,
            "A WMP-style YEAR=2007 Vorbis comment (no DATE field) must still be parsed as the year.")
    }

    // MARK: - Test 16: PICTURE block preceding VORBIS_COMMENT — EXPECTED TO FAIL

    /// Documents a known, unfixed parser limitation, not a regression to fix
    /// this session. The scanner reads only the first 64KB of each file as
    /// its "header." When an embedded PICTURE block larger than 64KB is
    /// placed before VORBIS_COMMENT in the file (some taggers/DAWs do this),
    /// the block-walking loop in parseVorbisComment correctly detects
    /// offset >= data.count and exits — without a crash, but also without
    /// ever reaching the tags, since VORBIS_COMMENT physically sits beyond
    /// the 64KB window. title/artist/album all come back nil and the track
    /// silently falls back to folder/filename-derived metadata instead.
    /// Tracked behind fScanFailureUtility — this test is expected to fail
    /// until that work is scheduled and done.
    func testTagsFoundWhenPictureBlockPrecedesVorbisComment() async throws {
        let sourceId = "reg16-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        let albumDir = tempDir.appendingPathComponent("PictureFirst-\(UUID().uuidString)", isDirectory: true)
        try copyFixture("fixture_t16_picture_before_tags", to: albumDir.appendingPathComponent("01 Some Track.flac"))

        try await runScan(source: source)

        let tracks = try fetchTracks(sourceId: sourceId)
        XCTAssertEqual(tracks.first?.title, "Some Track",
            "KNOWN FAILURE (fScanFailureUtility): tags beyond a >64KB PICTURE block " +
            "preceding VORBIS_COMMENT are not reached by the 64KB header read window. " +
            "This assertion documents the gap — it is expected to fail today.")
        XCTAssertEqual(tracks.first?.artistName, "Test Artist",
            "Same known limitation as above — artist tag unreachable within the read window.")
    }

    // MARK: - Test 17: duration parsed correctly from STREAMINFO

    /// Regression guard for a previously-fixed Swift bug where STREAMINFO
    /// parsing indexed into a Data slice using its original (non-base-zero)
    /// offsets. Current parseVorbisComment indexes directly into the full
    /// buffer with absolute offsets throughout, not a sub-slice, so this is
    /// not currently affected — this test exists to keep it that way.
    func testFlacDurationParsedFromStreamInfo() async throws {
        let sourceId = "reg17-\(UUID().uuidString)"
        let source = makeTestSource(id: sourceId)
        try SorrivaDatabase.shared.upsertLibrarySource(source)

        // Reuses an existing 1-second fixture from ScannerRegressionTests —
        // no need for a dedicated audio file just to check duration parsing.
        let albumDir = tempDir.appendingPathComponent("Duration-\(UUID().uuidString)", isDirectory: true)
        try copyFixture("fixture_t6_compilation", to: albumDir.appendingPathComponent("01 Track.flac"))

        try await runScan(source: source)

        let tracks = try fetchTracks(sourceId: sourceId)
        let duration = try XCTUnwrap(tracks.first?.duration)
        XCTAssertEqual(duration, 1.0, accuracy: 0.05,
            "Duration must be parsed correctly from STREAMINFO's total-samples/sample-rate fields.")
    }
}
