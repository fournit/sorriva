import XCTest
#if SWIFT_PACKAGE
// Compiled into the FastTests target directly, so there is no module to import.
#else
@testable import Sorriva
#endif

// MARK: - SonosFavoritesTests
//
// Asserted against favorites_fv2.xml — a REAL Browse response captured 2026-08-12 from
// a live household, not a hand-written sample. It contains both URI schemes, both
// services, and the two unplayable browse shortcuts, which is exactly why it was
// captured rather than invented.

final class SonosFavoritesTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        // Bundle first, source tree second — the simulator cannot read host paths.
        if let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "xml") {
            return try Data(contentsOf: url)
        }
        let here = URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        return try Data(contentsOf: here.appendingPathComponent("Fixtures/\(name).xml"))
    }

    private func favorites() throws -> [SonosFavorite] {
        SonosFavorites.parse(try fixture("favorites_fv2"))
    }

    /// The household has 14 favorites; 12 are playable. "Discover Sonos Radio" and
    /// "Sonos Presents" are browse shortcuts into a service and carry no <res> — they
    /// must never reach the selectable list, because offering something that cannot
    /// play is the same broken promise as a play button on a dead transport.
    func testBrowseShortcutsWithNoResAreDropped() throws {
        let favs = try favorites()
        XCTAssertEqual(favs.count, 12, "expected the two <res>-less shortcuts to be filtered")
        XCTAssertNil(favs.first { $0.title == "Discover Sonos Radio" })
        XCTAssertNil(favs.first { $0.title == "Sonos Presents" })
    }

    /// The token in resMD is what makes a closed service playable. A favorite parsed
    /// without it would return 200 and then not play — the worst failure shape there is.
    func testEveryPlayableFavoriteCarriesItsMetadata() throws {
        for f in try favorites() {
            XCTAssertFalse(f.uri.isEmpty, "\(f.title) has no URI")
            XCTAssertTrue(f.metadata.contains("<desc"),
                          "\(f.title) lost its resMD desc block — it will not play")
        }
    }

    /// METADATA MUST SURVIVE TWO ROUNDS OF DECODING, which is the subtle part of this
    /// parser. The Browse response entity-encodes the DIDL payload inside <Result>, and
    /// each favorite's resMD is encoded AGAIN within that. So resMD is decoded once as
    /// part of the payload and once as a field, and only after the second pass does it
    /// become the real XML carrying the service token.
    ///
    /// Get that wrong and the token arrives as literal "&lt;desc&gt;..." — the speaker
    /// returns 200 and then does not play, which is the worst failure shape available.
    /// A mutation replacing the chunk split with a naive <item>…</item> match did NOT
    /// break this, and that is correct rather than a gap: the nested <item> only exists
    /// after the second decode, so it cannot truncate a chunk taken before it.
    func testMetadataSurvivesDoubleDecodingAndCarriesTheToken() throws {
        let siriusXM = try XCTUnwrap(try favorites().first { $0.serviceName == "SiriusXM" })
        XCTAssertTrue(siriusXM.metadata.contains("SA_RINCON"),
                      "the service token must arrive decoded — without it the URI returns 200 and does not play")
        XCTAssertTrue(siriusXM.metadata.contains("<desc"),
                      "still entity-encoded: the second decode pass did not run")
        XCTAssertFalse(siriusXM.metadata.contains("&lt;desc"),
                      "metadata decoded only once — the speaker would receive escaped markup")
    }

    /// Two services, two different URI schemes. Storing verbatim is what lets one code
    /// path serve both — there is no per-scheme handling anywhere.
    func testBothServicesAndBothSchemesSurvive() throws {
        let favs = try favorites()
        let sirius = favs.filter { $0.serviceName == "SiriusXM" }
        let radio  = favs.filter { $0.serviceName == "Sonos Radio" }
        XCTAssertEqual(sirius.count, 8)
        XCTAssertFalse(radio.isEmpty)
        XCTAssertTrue(sirius.allSatisfy { $0.uri.hasPrefix("x-sonosapi-stream:") })
        XCTAssertTrue(radio.allSatisfy { $0.uri.hasPrefix("x-sonosapi-radio:") })
    }

    /// sid is how a favorite finds its service row without string-matching a display
    /// name that Sonos could relabel at any time.
    func testServiceIdIsReadFromTheURI() throws {
        let favs = try favorites()
        XCTAssertTrue(favs.filter { $0.serviceName == "SiriusXM" }.allSatisfy { $0.sonosServiceId == 37 })
        XCTAssertTrue(favs.filter { $0.serviceName == "Sonos Radio" }.allSatisfy { $0.sonosServiceId == 303 })
    }

    func testSonosServiceIdIsNilWhenTheURICarriesNone() {
        XCTAssertNil(SonosFavorites.sonosServiceId(from: "x-rincon-mp3radio://example.com/stream"))
        XCTAssertEqual(SonosFavorites.sonosServiceId(from: "x-sonosapi-stream:foo?sid=37&sn=3"), 37)
        XCTAssertEqual(SonosFavorites.sonosServiceId(from: "x-sonosapi-radio:sonos%3A3013?sid=303&flags=28780&sn=1"), 303)
    }

    /// Artwork is usually the only image available — Sonos supplies none at playback.
    func testArtworkIsCapturedWhenPresent() throws {
        let sirius = try XCTUnwrap(try favorites().first { $0.serviceName == "SiriusXM" })
        let art = try XCTUnwrap(sirius.artURL)
        XCTAssertTrue(art.hasPrefix("http"), "got \(art)")
    }

    /// Titles are the user's own words and arrive entity-encoded. A station called
    /// "Rock & Roll" must not surface as "Rock &amp; Roll" in the library.
    func testEntitiesAreDecodedInTitles() throws {
        for f in try favorites() {
            XCTAssertFalse(f.title.contains("&amp;"), "undecoded entity in \(f.title)")
            XCTAssertFalse(f.title.contains("&#"), "undecoded numeric entity in \(f.title)")
        }
    }

    // MARK: - Channel identity
    //
    // The library holds one row per CHANNEL, not one per household. Measured
    // 2026-08-11: the same channel carried ?sid=37&sn=4 at one house and
    // ?sid=37&flags=8260&sn=3 at another, identical before the "?". Matching on the
    // full URI produced two rows for one channel.

    func testChannelIdentityIgnoresTheAccountHandle() {
        let home = "x-sonosapi-stream:channel-linear%3A9150cc82-af5c-3be3-d170-0e81d87375a8?sid=37&sn=4"
        let away = "x-sonosapi-stream:channel-linear%3A9150cc82-af5c-3be3-d170-0e81d87375a8?sid=37&flags=8260&sn=3"
        XCTAssertEqual(SonosFavorites.channelIdentity(of: home),
                       SonosFavorites.channelIdentity(of: away),
                       "same channel, two households — must be one station")
        XCTAssertEqual(SonosFavorites.channelIdentity(of: home),
                       "x-sonosapi-stream:channel-linear%3A9150cc82-af5c-3be3-d170-0e81d87375a8")
    }

    func testDifferentChannelsRemainDistinct() {
        let a = "x-sonosapi-stream:channel-linear%3Aaaaa?sid=37&sn=3"
        let b = "x-sonosapi-stream:channel-linear%3Abbbb?sid=37&sn=3"
        XCTAssertNotEqual(SonosFavorites.channelIdentity(of: a), SonosFavorites.channelIdentity(of: b))
    }

    func testIdentityOfAURIWithNoQueryIsItself() {
        let plain = "x-rincon-mp3radio://ice2.somafm.com/groovesalad"
        XCTAssertEqual(SonosFavorites.channelIdentity(of: plain), plain)
    }

    /// Every favorite in the fixture must produce a distinct identity — if two
    /// collapsed together, importing them would silently drop one.
    func testFixtureFavoritesAllHaveDistinctIdentities() throws {
        let ids = try favorites().map { SonosFavorites.channelIdentity(of: $0.uri) }
        XCTAssertEqual(Set(ids).count, ids.count, "two favorites share an identity")
    }

    func testGarbageParsesToNothingRatherThanCrashing() {
        XCTAssertTrue(SonosFavorites.parse(Data()).isEmpty)
        XCTAssertTrue(SonosFavorites.parse(Data("not xml".utf8)).isEmpty)
        XCTAssertTrue(SonosFavorites.parse(Data("<s:Envelope><Result></Result></s:Envelope>".utf8)).isEmpty)
    }
}
