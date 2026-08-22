import XCTest
#if SWIFT_PACKAGE
// Compiled into the FastTests target directly, so there is no module to import.
#else
@testable import Sorriva
#endif

// MARK: - ArtistInfoTests
//
// The pure parts of fetching an artist biography: matching a name to the right MusicBrainz
// artist, and turning three sources' markup into readable prose.
//
// Every payload here is shaped like the real ones, captured 2026-08-21. Nothing makes a
// network call — the transport is injected precisely so these can run in the fast suite.

final class ArtistInfoTests: XCTestCase {

    // MARK: - Matching
    //
    // THE WRONG ARTIST IS WORSE THAN NO ARTIST. "Pat Metheny", "Pat Metheny Group" and "Pat
    // Metheny Trio" are three MBIDs, and attaching the Group's biography to the man is a
    // silent error that looks entirely plausible on screen.

    private func payload(_ artists: [(String, String, Int, String)]) -> Data {
        let rows = artists.map { id, name, score, disamb in
            ["id": id, "name": name, "score": score, "disambiguation": disamb] as [String: Any]
        }
        return try! JSONSerialization.data(withJSONObject: ["artists": rows])
    }

    func testAnExactNameWinsOverAHigherScoringNeighbour() throws {
        // The real shape of a "Pat Metheny" search: three related artists, all plausible.
        let data = payload([
            ("66a7f1f8", "Pat Metheny Group", 100, ""),
            ("7daac7f9", "Pat Metheny", 95, ""),
            ("6a8bd368", "Pat Metheny Trio", 90, ""),
        ])
        let match = try XCTUnwrap(ArtistInfoService.bestMatch(from: data, wanted: "Pat Metheny"))
        XCTAssertEqual(match.name, "Pat Metheny")
        XCTAssertEqual(match.mbid, "7daac7f9", "the exact name must beat the higher score")
    }

    /// Measured 2026-08-21: MusicBrainz resolves unaccented input to the accented artist —
    /// "Nik Bartsch" returns Nik Bärtsch at score 100. The exact-match test must therefore
    /// fold accents, or it rejects a correct answer and falls through to the score rule.
    func testAccentedNamesMatchTheirUnaccentedQuery() throws {
        let data = payload([("abc", "Nik Bärtsch", 100, "Swiss pianist")])
        let match = try XCTUnwrap(ArtistInfoService.bestMatch(from: data, wanted: "Nik Bartsch"))
        XCTAssertEqual(match.name, "Nik Bärtsch")
        XCTAssertEqual(match.disambiguation, "Swiss pianist")
    }

    /// A "Eberhard Weber" query really does return Carl Maria von Weber, at score 47.
    func testAWeakMatchIsRefusedRatherThanGuessedAt() {
        let data = payload([("c2d17829", "Carl Maria von Weber", 47, "composer")])
        XCTAssertNil(ArtistInfoService.bestMatch(from: data, wanted: "Eberhard Weber"),
                     "a 47 is not a match; no bio beats the wrong composer's bio")
    }

    func testAConfidentNonExactMatchIsAccepted() throws {
        let data = payload([("3b1464ca", "Eberhard Weber", 100, "German double bassist")])
        let match = try XCTUnwrap(ArtistInfoService.bestMatch(from: data, wanted: "eberhard weber"))
        XCTAssertEqual(match.mbid, "3b1464ca")
    }

    func testAnEmptyDisambiguationIsNilRatherThanBlank() throws {
        let data = payload([("x", "Someone", 100, "")])
        let match = try XCTUnwrap(ArtistInfoService.bestMatch(from: data, wanted: "Someone"))
        XCTAssertNil(match.disambiguation, "a blank string would render as an empty subtitle")
    }

    // MARK: - What gets cached
    //
    // Tom, 2026-08-21: "i don't like the idea of storing the lesser of a bio." A single
    // unlucky fetch during a Discogs hiccup must not decide an artist's biography forever.

    func testGoodSourcesAreCachedAndTheFallbackIsNot() {
        XCTAssertTrue(ArtistInfoService.cacheable(.discogs))
        XCTAssertTrue(ArtistInfoService.cacheable(.wikipedia))
        XCTAssertFalse(ArtistInfoService.cacheable(.lastfm),
                       "a fallback is shown, never stored — the next visit must be able to upgrade it")
    }

    // MARK: - External links

    func testLinksAreKeyedByRelationType() throws {
        let json: [String: Any] = ["relations": [
            ["type": "discogs", "url": ["resource": "https://www.discogs.com/artist/20185"]],
            ["type": "wikidata", "url": ["resource": "https://www.wikidata.org/wiki/Q380430"]],
            ["type": "allmusic", "url": ["resource": "https://www.allmusic.com/artist/mn0000179698"]],
        ]]
        let links = ArtistInfoService.links(from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(links["discogs"], "https://www.discogs.com/artist/20185")
        XCTAssertEqual(links["wikidata"], "https://www.wikidata.org/wiki/Q380430")
        // Kept deliberately: if TiVo/AllMusic is ever licensed, the id is already here and
        // the change is a swap at the last step of the chain.
        XCTAssertEqual(links["allmusic"], "https://www.allmusic.com/artist/mn0000179698")
    }

    func testTrailingIdHandlesTrailingSlashesAndMissingValues() {
        XCTAssertEqual(ArtistInfoService.trailingId(of: "https://www.discogs.com/artist/20185"), "20185")
        XCTAssertEqual(ArtistInfoService.trailingId(of: "https://www.wikidata.org/wiki/Q380430/"), "Q380430")
        XCTAssertNil(ArtistInfoService.trailingId(of: nil))
        XCTAssertNil(ArtistInfoService.trailingId(of: "/"))
    }

    // MARK: - Discogs cleanup
    //
    // Real markup from Pat Metheny's profile, which is where this was first seen.

    func testDiscogsBareReferenceCodesAreRemovedEntirely() {
        let raw = "Over his three-year stint with vibraphone great [a256558], the young Missouri native"
        let out = ArtistBioText.clean(raw, from: .discogs)
        // This asserted the stranded space when it was first written, which encoded the very
        // artifact it should have caught — the reference goes AND the gap it leaves closes.
        XCTAssertEqual(out, "Over his three-year stint with vibraphone great, the young Missouri native")
        XCTAssertFalse(out!.contains("[a256558]"), "a bare id has no display text and must go")
    }

    /// The named form carries real prose after the `=` and must survive.
    func testDiscogsNamedReferencesKeepTheirName() {
        XCTAssertEqual(ArtistBioText.clean("worked with [a=Gary Burton] early on", from: .discogs),
                       "worked with Gary Burton early on")
        XCTAssertEqual(ArtistBioText.clean("signed to [l=ECM Records]", from: .discogs),
                       "signed to ECM Records")
    }

    /// Discogs writes `[r=54828]` for a RELEASE, and the value after `=` is an id rather than
    /// a name. Keeping it produced Grammy citations reading "Best Jazz Fusion Performance for
    /// 54828" on Pat Metheny's page — seen on device 2026-08-21.
    func testDiscogsNumericNamedReferencesAreRemovedNotKept() {
        XCTAssertEqual(
            ArtistBioText.clean("Best Jazz Fusion Performance for [r=54828]", from: .discogs),
            "Best Jazz Fusion Performance for")
        // The alphabetic form is still a name and still survives.
        XCTAssertEqual(ArtistBioText.clean("with [a=Gary Burton]", from: .discogs),
                       "with Gary Burton")
    }

    /// Removing a reference strands the space that preceded it against the next punctuation:
    /// "the younger brother of flugelhorn player ." and "vibraphone great , the young
    /// Missouri native". Both seen on device 2026-08-21.
    func testSpaceStrandedByAReferenceIsClosedUp() {
        XCTAssertEqual(
            ArtistBioText.clean("He is the younger brother of flugelhorn player [a123].",
                                from: .discogs),
            "He is the younger brother of flugelhorn player.")
        XCTAssertEqual(
            ArtistBioText.clean("his stint with vibraphone great [a256558], the young native",
                                from: .discogs),
            "his stint with vibraphone great, the young native")
    }

    /// The tidy-up must not eat legitimate spacing in prose that arrived clean.
    func testNormalSpacingIsNotMangled() {
        let raw = "He led the group (1977–2010), won 20 Grammys, and toured widely."
        XCTAssertEqual(ArtistBioText.clean(raw, from: .wikipedia), raw)
    }

    func testDiscogsBBCodeIsStrippedButItsTextKept() {
        XCTAssertEqual(ArtistBioText.clean("[b]Pat Metheny[/b] is a [i]guitarist[/i]", from: .discogs),
                       "Pat Metheny is a guitarist")
        XCTAssertEqual(ArtistBioText.clean("see [url=https://patmetheny.com]his site[/url]", from: .discogs),
                       "see his site")
    }

    // MARK: - Last.fm cleanup

    func testLastFmHTMLAndTrailingLinkAreRemoved() {
        let raw = "<p>Pat Metheny is an American jazz guitarist.</p>\n"
                + "<a href=\"https://www.last.fm/music/Pat+Metheny\">Read more on Last.fm</a>"
        XCTAssertEqual(ArtistBioText.clean(raw, from: .lastfm),
                       "Pat Metheny is an American jazz guitarist.")
    }

    func testLastFmLicenceBoilerplateIsRemoved() {
        let raw = "A biography.\n\nUser-contributed text is available under the Creative Commons"
        XCTAssertEqual(ArtistBioText.clean(raw, from: .lastfm), "A biography.")
    }

    // MARK: - Wikipedia

    /// The extracts endpoint is asked for `explaintext`, so there is nothing to strip. This
    /// pins that we do NOT mangle prose that arrived clean — an over-eager scrubber would eat
    /// the brackets in "Bright Size Life (1976)".
    func testWikipediaProseIsLeftAlone() {
        let raw = "Patrick Bruce Metheny is an American jazz guitarist and composer."
        XCTAssertEqual(ArtistBioText.clean(raw, from: .wikipedia), raw)
    }

    func testWikipediaBracketsSurviveCleanup() {
        let raw = "He led the Pat Metheny Group (1977–2010) and won 20 Grammy Awards."
        XCTAssertEqual(ArtistBioText.clean(raw, from: .wikipedia), raw)
    }

    // MARK: - Shared

    func testEmptyAndWhitespaceOnlyBiosBecomeNil() {
        XCTAssertNil(ArtistBioText.clean(nil, from: .discogs))
        XCTAssertNil(ArtistBioText.clean("", from: .wikipedia))
        XCTAssertNil(ArtistBioText.clean("   \n\n  ", from: .lastfm))
        // TheAudioDB returned exactly this for Pat Metheny — an artist row with an empty bio.
        XCTAssertNil(ArtistBioText.clean("[a123]", from: .discogs),
                     "markup that cleans away to nothing is not a biography")
    }

    func testParagraphBreaksSurviveButRunsOfBlankLinesCollapse() {
        let raw = "First paragraph.\n\n\n\nSecond paragraph."
        XCTAssertEqual(ArtistBioText.clean(raw, from: .wikipedia),
                       "First paragraph.\n\nSecond paragraph.")
    }

    // MARK: - Parsing the source payloads

    func testWikipediaExtractIsReadFromAnUnknownPageId() throws {
        // The page id is the key and is not known ahead of time, so the parser must not
        // depend on it.
        let json: [String: Any] = ["query": ["pages": [
            "296412": ["pageid": 296412, "title": "Pat Metheny", "extract": "A jazz guitarist."]
        ]]]
        let text = ArtistInfoService.wikipediaText(from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(text, "A jazz guitarist.")
    }

    func testWikidataSitelinkResolvesToAnArticleTitle() throws {
        let json: [String: Any] = ["entities": ["Q380430": ["sitelinks": [
            "enwiki": ["site": "enwiki", "title": "Pat Metheny"],
            "dewiki": ["site": "dewiki", "title": "Pat Metheny"],
        ]]]]
        let title = ArtistInfoService.wikipediaTitle(
            from: try JSONSerialization.data(withJSONObject: json), qid: "Q380430")
        XCTAssertEqual(title, "Pat Metheny")
    }

    func testLastFmBioContentIsRead() throws {
        let json: [String: Any] = ["artist": ["bio": ["content": "<p>Some prose.</p>"]]]
        let raw = ArtistInfoService.lastFmText(from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(ArtistBioText.clean(raw, from: .lastfm), "Some prose.")
    }

    func testMalformedPayloadsReturnNilRatherThanThrowing() {
        let junk = Data("not json".utf8)
        XCTAssertNil(ArtistInfoService.bestMatch(from: junk, wanted: "x"))
        XCTAssertNil(ArtistInfoService.wikipediaText(from: junk))
        XCTAssertNil(ArtistInfoService.lastFmText(from: junk))
        XCTAssertTrue(ArtistInfoService.links(from: junk).isEmpty)
    }
}
