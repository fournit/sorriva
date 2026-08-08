import XCTest
#if SWIFT_PACKAGE
// Compiled into the FastTests target directly, so there is no module to import.
#else
@testable import Sorriva
#endif

// MARK: - ArtworkSelectionTests
// bArtworkSelectionNotBestWins. Covers the two pure, testable pieces of the
// redesign: ImageDimensionReader (header-only PNG/JPEG dimension parsing)
// and ArtworkBestWins (candidate selection + stored-area comparison). The
// pass orchestration itself (runFolderArtPass etc.) talks directly to
// SMBClient with no test seam yet — that's a separate future item
// (fScannerDatabaseInjection-style work), not attempted here.

final class ArtworkSelectionTests: XCTestCase {

    // MARK: - ImageDimensionReader

    private func loadFixture(_ name: String, ext: String) throws -> Data {
        // BUNDLE FIRST, SOURCE TREE SECOND — and the order is load-bearing.
        //
        // Under Xcode these tests run INSIDE THE SIMULATOR, which cannot read
        // /Users/... on the host, so a #filePath lookup fails there: #filePath is a
        // Mac path baked in at compile time. Under the FastTests package they run
        // natively on the Mac, where there is no resource bundle but the source tree
        // is right there. Neither mechanism works in both places; trying them in this
        // order does. Reversing them breaks the simulator run — that is exactly how
        // this file broke on 2026-08-08.
        //
        // resolvingSymlinksInPath matters for the fallback: in the package this file
        // is a symlink into SorrivaTests/, and resolving it lands beside the images.
        if let url = Bundle(for: ArtworkSelectionTests.self).url(forResource: name, withExtension: ext) {
            return try Data(contentsOf: url)
        }
        let dir = URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        let url = dir.appendingPathComponent("\(name).\(ext)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Missing fixture \(name).\(ext) — not in the test bundle, and not at \(dir.path).")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    func testPNGDimensionsReadCorrectly() throws {
        let data = try loadFixture("fixture_artwork_450x450", ext: "png")
        let dims = ImageDimensionReader.dimensions(data: data)
        XCTAssertEqual(dims?.width, 450)
        XCTAssertEqual(dims?.height, 450)
    }

    func testJPEGDimensionsReadCorrectly() throws {
        let data = try loadFixture("fixture_artwork_1000x882", ext: "jpg")
        let dims = ImageDimensionReader.dimensions(data: data)
        XCTAssertEqual(dims?.width, 1000)
        XCTAssertEqual(dims?.height, 882)
    }

    func testSmallJPEGDimensionsReadCorrectly() throws {
        let data = try loadFixture("fixture_artwork_200x200", ext: "jpg")
        let dims = ImageDimensionReader.dimensions(data: data)
        XCTAssertEqual(dims?.width, 200)
        XCTAssertEqual(dims?.height, 200)
    }

    func testHeaderOnlyReadStillWorks() throws {
        // The real folder pass only reads the first 16KB of each candidate,
        // not the whole file — confirm dimensions are still found from just
        // that much data, not only when given the complete file.
        let data = try loadFixture("fixture_artwork_1000x882", ext: "jpg")
        let header = data.prefix(16384)
        let dims = ImageDimensionReader.dimensions(data: header)
        XCTAssertEqual(dims?.width, 1000)
        XCTAssertEqual(dims?.height, 882)
    }

    func testGarbageDataReturnsNilWithoutCrashing() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFF])
        XCTAssertNil(ImageDimensionReader.dimensions(data: garbage))
    }

    func testEmptyDataReturnsNilWithoutCrashing() {
        XCTAssertNil(ImageDimensionReader.dimensions(data: Data()))
    }

    // MARK: - ArtworkBestWins

    func testLargestAreaWinsRegardlessOfFormat() {
        let candidates = [
            ArtworkBestWins.Candidate(name: "AlbumArt_small.jpg", width: 450, height: 450),
            ArtworkBestWins.Candidate(name: "Folder.jpg", width: 1000, height: 882),
            ArtworkBestWins.Candidate(name: "cover.png", width: 720, height: 634),
        ]
        let winner = ArtworkBestWins.selectWinner(candidates: candidates, storedWidth: nil, storedHeight: nil)
        XCTAssertEqual(winner?.name, "Folder.jpg", "1000×882 (882000px²) beats both other candidates.")
    }

    func testEqualAreaTieBreaksByFilenamePreference() {
        // cover.jpg and folder.jpg both 450×450 — cover should win per the
        // documented preference order (cover > folder > AlbumArt_* > other).
        let candidates = [
            ArtworkBestWins.Candidate(name: "folder.jpg", width: 450, height: 450),
            ArtworkBestWins.Candidate(name: "cover.jpg", width: 450, height: 450),
        ]
        let winner = ArtworkBestWins.selectWinner(candidates: candidates, storedWidth: nil, storedHeight: nil)
        XCTAssertEqual(winner?.name, "cover.jpg")
    }

    func testCandidateMustBeatStoredAreaToWin() {
        // A 450×450 folder candidate must NOT beat an already-stored 1000×882 —
        // this is the core defect the whole redesign fixes: the last pass to
        // run no longer wins unconditionally.
        let candidates = [
            ArtworkBestWins.Candidate(name: "AlbumArt_small.jpg", width: 450, height: 450),
        ]
        let winner = ArtworkBestWins.selectWinner(candidates: candidates, storedWidth: 1000, storedHeight: 882)
        XCTAssertNil(winner, "450×450 (202500px²) must not beat an already-stored 1000×882 (882000px²).")
    }

    func testCandidateBeatingStoredAreaWins() {
        let candidates = [
            ArtworkBestWins.Candidate(name: "Folder.jpg", width: 1200, height: 1200),
        ]
        let winner = ArtworkBestWins.selectWinner(candidates: candidates, storedWidth: 450, storedHeight: 450)
        XCTAssertEqual(winner?.name, "Folder.jpg", "1200×1200 must beat a stored 450×450.")
    }

    func testNoCandidatesReturnsNil() {
        let winner = ArtworkBestWins.selectWinner(candidates: [], storedWidth: nil, storedHeight: nil)
        XCTAssertNil(winner)
    }

    func testNonSquareAreasComparedCorrectly() {
        // Regression guard for the aspect-ratio question raised during design:
        // pure area comparison, not width or height alone. 450×398 has less
        // area than 450×450 despite sharing a dimension.
        let candidates = [
            ArtworkBestWins.Candidate(name: "wide.jpg", width: 450, height: 398),
            ArtworkBestWins.Candidate(name: "square.jpg", width: 450, height: 450),
        ]
        let winner = ArtworkBestWins.selectWinner(candidates: candidates, storedWidth: nil, storedHeight: nil)
        XCTAssertEqual(winner?.name, "square.jpg")
    }
}
