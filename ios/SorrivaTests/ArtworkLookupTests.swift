import XCTest
@testable import Sorriva

// Tests for the PURE half of ArtworkLookup — normalization, title scoring, and
// ranking. No network: these are the parts that decide whether a cover is right,
// and they should be checkable without asking Apple.
//
// The cases are drawn from measured reality rather than invented. Every album
// named here was run against the live iTunes API on 2026-08-07, and the scores
// asserted below are the ones that decided accept-or-reject in that run.

final class ArtworkLookupTests: XCTestCase {

    // MARK: - normalize

    func testNormalizeStripsPunctuationCaseAndSpacing() {
        // "12\"/80's: Pop" and "Off Ramp" are real tags from the test library.
        // Raw string comparison rejects both against their iTunes spellings, which
        // is why normalization exists rather than being a nicety.
        XCTAssertEqual(ArtworkLookup.normalize("Off Ramp"), "offramp")
        XCTAssertEqual(ArtworkLookup.normalize("Offramp"), "offramp")
        XCTAssertEqual(ArtworkLookup.normalize("Remixes 81-04"), "remixes8104")
        XCTAssertEqual(ArtworkLookup.normalize("Remixes 81>04"), "remixes8104")
        XCTAssertEqual(ArtworkLookup.normalize("12\"/80's: Pop"), "1280spop")
    }

    // MARK: - titleScore

    func testExactAndNearMatchesScoreHigh() {
        XCTAssertEqual(ArtworkLookup.titleScore("Kind of Blue", "Kind of Blue"), 1.0)
        // Measured: these two pairs both scored 1.0 against the live API because
        // normalization collapses the difference.
        XCTAssertEqual(ArtworkLookup.titleScore("Offramp", "Off Ramp"), 1.0)
        XCTAssertEqual(ArtworkLookup.titleScore("Remixes 81>04", "Remixes 81-04"), 1.0)
    }

    func testCandidateContainingTheWholeWantedTitleIsAccepted() {
        // "Special EFX Collection" vs the tag "Collection" — a real accept at 0.75.
        // The candidate is a SUPERSET of what we asked for, which usually means the
        // same record with the artist or an edition tacked on.
        let s = ArtworkLookup.titleScore("Special EFX Collection", "Collection")
        XCTAssertEqual(s, 0.75)
        XCTAssertGreaterThanOrEqual(s, 0.62, "containment must still clear the scan threshold")
    }

    func testCandidateThatIsMerelyAFragmentIsNotAccepted() {
        // The bug this test was written to catch. "Greatest" sits inside "18 Greatest
        // Hits", and scoring containment symmetrically gave it 0.75 — an album called
        // "Greatest" would have been auto-accepted for a different record entirely.
        // A fragment is weak evidence and must fall through to token overlap.
        let s = ArtworkLookup.titleScore("Greatest", "18 Greatest Hits")
        XCTAssertLessThan(s, 0.62, "a fragment of the wanted title must not be auto-accepted")
    }

    func testGenericHitsTitlesScoreBelowThreshold() {
        // The case the whole change exists for. "18 Greatest Hits" is not in Apple's
        // Johnny Cash catalogue, so the nearest real records are other compilations.
        // Every one of them must land BELOW the 0.55 acceptance bar, or the scan
        // silently adopts the wrong cover again.
        // Both the short forms and the exact strings the live API returned, since
        // the "(feat. ...)" suffixes were what accidentally masked the containment
        // bug the first time these were written.
        for candidate in ["Super Hits", "The Hits", "Sings the Greatest Hits",
                          "Greatest Hits - Finest Performances", "Greatest",
                          "Sings the Greatest Hits (feat. The Tennessee Two)",
                          "Greatest (feat. The Tennessee Two)"] {
            let s = ArtworkLookup.titleScore(candidate, "18 Greatest Hits")
            XCTAssertLessThan(s, 0.62,
                              "\(candidate) scored \(s) — would be auto-accepted for 18 Greatest Hits")
        }
    }

    func testEmptyTitlesScoreZero() {
        XCTAssertEqual(ArtworkLookup.titleScore("", "Aja"), 0)
        XCTAssertEqual(ArtworkLookup.titleScore("Aja", ""), 0)
    }

    // MARK: - ranking

    private func candidate(_ artist: String, _ album: String, tracks: Int = 10) -> ArtworkCandidate {
        ArtworkCandidate(artworkURL100: "https://example.invalid/100x100.jpg",
                         collectionName: album, artistName: artist,
                         trackCount: tracks, collectionId: 1)
    }

    func testWrongArtistIsPenalisedBelowThreshold() {
        // The exact live failure: a search for Johnny Cash's "18 Greatest Hits"
        // returned Creed's "Greatest Hits" first, and the old code took it. Even
        // with a perfect title, a different artist must not win.
        let ranked = ArtworkLookup.rank(
            [candidate("Creed", "18 Greatest Hits")],
            against: "18 Greatest Hits", expectedArtist: "Johnny Cash", limit: 5)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertLessThan(ranked[0].score, 0.62,
                          "a perfect title by the wrong artist must not clear the bar")
    }

    func testRightArtistOutranksWrongArtistWithIdenticalTitle() {
        let ranked = ArtworkLookup.rank(
            [candidate("Creed", "Greatest Hits"),
             candidate("Johnny Cash", "Greatest Hits")],
            against: "Greatest Hits", expectedArtist: "Johnny Cash", limit: 5)
        XCTAssertEqual(ranked.first?.artistName, "Johnny Cash")
    }

    func testTiesBreakOnTrackCount() {
        let ranked = ArtworkLookup.rank(
            [candidate("Pat Metheny", "We Live Here", tracks: 3),
             candidate("Pat Metheny", "We Live Here", tracks: 9)],
            against: "We Live Here", expectedArtist: "Pat Metheny", limit: 5)
        XCTAssertEqual(ranked.first?.trackCount, 9)
    }

    func testRankRespectsLimit() {
        let many = (1...20).map { candidate("Johnny Cash", "Album \($0)") }
        XCTAssertEqual(ArtworkLookup.rank(many, against: "Album 1",
                                          expectedArtist: "Johnny Cash", limit: 5).count, 5)
    }

    // MARK: - guards

    func testCompilationPlaceholdersAreRecognised() {
        // A compilation has no artist to constrain by, so the online pass declines
        // rather than searching for the literal words "Various Artists".
        for name in ["Various Artists", "various", "VA", "Soundtrack", "  Various Artists  "] {
            XCTAssertTrue(ArtworkLookup.isCompilationPlaceholder(name), "\(name) should be a placeholder")
        }
        XCTAssertFalse(ArtworkLookup.isCompilationPlaceholder("Johnny Cash"))
        XCTAssertFalse(ArtworkLookup.isCompilationPlaceholder("Various Production"))
    }

    func testArtistPrefixIsStrippedFromAlbumTitle() {
        // Real tag from the test library: the folder and tag both carry the artist.
        XCTAssertEqual(
            ArtworkLookup.stripArtistPrefix("Pat Metheny Group - Offramp", artist: "Pat Metheny Group"),
            "Offramp")
        XCTAssertEqual(ArtworkLookup.stripArtistPrefix("Offramp", artist: "Pat Metheny Group"), "Offramp")
    }

    func testSearchURLIsWellFormed() {
        let url = ArtworkLookup.url("search", ["term": "Johnny Cash", "entity": "musicArtist"])
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.hasPrefix("https://itunes.apple.com/search?"))
        XCTAssertTrue(url!.absoluteString.contains("Johnny%20Cash"))
    }

    // MARK: - parsing

    func testParseSkipsRowsMissingRequiredFields() {
        // The artist lookup response includes the ARTIST record as its first element,
        // which has no collectionName. It must drop out rather than become a
        // candidate with an empty title.
        let rows: [[String: Any]] = [
            ["artistName": "Johnny Cash", "artistId": 70936],                       // artist record
            ["artistName": "Johnny Cash", "collectionName": "At Folsom Prison",
             "artworkUrl100": "https://example.invalid/a.jpg", "trackCount": 16, "collectionId": 5],
        ]
        let parsed = ArtworkLookup.parse(rows)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].collectionName, "At Folsom Prison")
        XCTAssertEqual(parsed[0].trackCount, 16)
    }
}
