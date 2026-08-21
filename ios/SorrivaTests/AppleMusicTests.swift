import XCTest
#if SWIFT_PACKAGE
// Compiled into the FastTests target directly, so there is no module to import.
#else
@testable import Sorriva
#endif

// MARK: - AppleMusicTests
//
// The catalogue layer and the address Sorriva hands to a speaker. Payloads below are
// REAL — copied from itunes.apple.com responses captured 2026-08-18, not invented — and
// nothing here touches the network: the transport stays private and the parsers are
// exercised directly.
//
// The address assertions matter most. Every string checked here was proven on hardware:
// a track found through the public catalogue, addressed by a URI built from these rules,
// played on a speaker that had never been given it. If these tests go red, the app is
// building something that will not play.

final class AppleMusicTests: XCTestCase {

    // MARK: - Album parsing

    /// Straight from the `Offramp` lookup response.
    private let offramp: [String: Any] = [
        "wrapperType": "collection",
        "collectionId": 1523943961,
        "collectionName": "Offramp",
        "artistName": "Pat Metheny Group",
        "artistId": 115059,
        "primaryGenreName": "Jazz",
        "releaseDate": "1982-05-03T07:00:00Z",
        "trackCount": 8,
        "copyright": "℗ 1983 ECM Records GmbH",
        "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music124/v4/49/b1/9c/x.jpg/100x100bb.jpg",
    ]

    func testAlbumParsesTheFieldsAScreenNeeds() throws {
        let album = try XCTUnwrap(AppleMusicCatalog.album(from: offramp))
        XCTAssertEqual(album.id, 1523943961)
        XCTAssertEqual(album.title, "Offramp")
        XCTAssertEqual(album.artist, "Pat Metheny Group")
        XCTAssertEqual(album.year, "1982", "the year, not the whole timestamp")
        XCTAssertEqual(album.genre, "Jazz")
        XCTAssertEqual(album.trackCount, 8)
    }

    func testARowThatIsNotAnAlbumIsRejectedRatherThanHalfBuilt() {
        XCTAssertNil(AppleMusicCatalog.album(from: ["collectionName": "no id"]))
        XCTAssertNil(AppleMusicCatalog.album(from: ["collectionId": 1]))
        XCTAssertNil(AppleMusicCatalog.album(from: [:]))
    }

    // MARK: - Artwork

    /// One field serves every size because the dimensions live in the path. 100, 600,
    /// 1000 and 3000 were all verified to fetch a real image.
    func testArtworkSizeIsRewrittenInThePath() throws {
        let album = try XCTUnwrap(AppleMusicCatalog.album(from: offramp))
        XCTAssertEqual(album.artworkURL(size: 600)?.absoluteString,
                       "https://is1-ssl.mzstatic.com/image/thumb/Music124/v4/49/b1/9c/x.jpg/600x600bb.jpg")
        XCTAssertEqual(album.artworkURL(size: 3000)?.absoluteString,
                       "https://is1-ssl.mzstatic.com/image/thumb/Music124/v4/49/b1/9c/x.jpg/3000x3000bb.jpg")
    }

    func testAnAlbumWithNoArtworkYieldsNoURLRatherThanABrokenOne() {
        let bare = AppleMusicCatalog.album(from: ["collectionId": 1, "collectionName": "x"])
        XCTAssertNil(bare?.artworkURL(size: 600))
    }

    // MARK: - Track parsing

    func testTrackParsesAndConvertsDuration() throws {
        let track = try XCTUnwrap(AppleMusicCatalog.track(from: [
            "wrapperType": "track",
            "trackId": 1523944188,
            "trackName": "Au Lait",
            "artistName": "Pat Metheny Group",
            "trackNumber": 3,
            "discNumber": 1,
            "trackTimeMillis": 513920,
            "isStreamable": true,
        ]))
        XCTAssertEqual(track.id, 1523944188)
        XCTAssertEqual(track.trackNumber, 3)
        XCTAssertEqual(track.durationSeconds, 513, "milliseconds to seconds")
    }

    /// Some catalogue items are purchase-only and will not stream — the app has to be
    /// able to see that rather than discovering it when playback fails.
    func testStreamableIsCarriedThroughAndDefaultsOptimistically() throws {
        let no = try XCTUnwrap(AppleMusicCatalog.track(from: [
            "trackId": 1, "trackName": "x", "isStreamable": false]))
        XCTAssertFalse(no.isStreamable)

        let absent = try XCTUnwrap(AppleMusicCatalog.track(from: ["trackId": 2, "trackName": "y"]))
        XCTAssertTrue(absent.isStreamable, "absent means unknown; assume playable and cope if not")
    }

    // MARK: - The address and metadata Sonos is given
    //
    // ALL MEASURED ON HARDWARE 2026-08-18. An earlier version of this file asserted the
    // OPPOSITE of the res rule below, because a failed first attempt was blamed on the
    // wrong variable. See sonos-playback-contract.md §13.

    private let token = "SA_RINCON52231_X_#Svc52231-e60e984c-Token"

    func testTheTrackAddressIsTheCatalogueId() {
        XCTAssertEqual(AppleMusicPlayback.trackURI(catalogueId: 1443195687),
                       "x-sonos-http:song%3a1443195687.mp4?sid=204&flags=8232&sn=5")
    }

    // MARK: - Search relevance
    //
    // MEASURED 2026-08-20. Apple's raw catalogue search is looser than Apple's own app:
    // paging "Pat Metheny" returned records by Ahn Trio, Fumiaki Miyamoto and California
    // State University, which Metheny is not credited on. Tom: "it only delivers albums
    // where pat metheny is listed." These pin the narrowing rule.

    func testAnAlbumCreditedToTheSearchedArtistIsKept() {
        XCTAssertTrue(AppleSearchRelevance.matches("Pat Metheny", "80/81", "Pat Metheny"))
        XCTAssertTrue(AppleSearchRelevance.matches("Pat Metheny", "American Garage",
                                                   "Pat Metheny Group"))
        // A shared credit still counts — this is a real Metheny record.
        XCTAssertTrue(AppleSearchRelevance.matches("Pat Metheny", "Beyond the Missouri Sky",
                                                   "Charlie Haden & Pat Metheny"))
    }

    /// The three that actually came back from Apple and should not have been shown.
    func testAnAlbumTheArtistIsNotCreditedOnIsDropped() {
        XCTAssertFalse(AppleSearchRelevance.matches("Pat Metheny",
                                                    "Lullaby for My Favorite Insomniac",
                                                    "Ahn Trio"))
        XCTAssertFalse(AppleSearchRelevance.matches("Pat Metheny", "Ao No Kaori",
                                                    "Fumiaki Miyamoto"))
        XCTAssertFalse(AppleSearchRelevance.matches("Pat Metheny",
                                                    "ACDA 2011 National Convention",
                                                    "California State University"))
    }

    /// The rule checks title AND artist, so searching an ALBUM name still works. Filtering
    /// on the artist credit alone would have thrown this away.
    func testSearchingAnAlbumTitleStillMatches() {
        XCTAssertTrue(AppleSearchRelevance.matches("Bright Size Life", "Bright Size Life",
                                                   "Pat Metheny"))
        XCTAssertFalse(AppleSearchRelevance.matches("Bright Size Life", "Kin (<-->)",
                                                    "Pat Metheny"))
    }

    /// Streaming metadata is inconsistently accented and cased; the local library learned
    /// this already.
    func testMatchingIgnoresCaseAndAccents() {
        XCTAssertTrue(AppleSearchRelevance.matches("jobim", "Wave", "Antônio Carlos Jobím"))
        XCTAssertTrue(AppleSearchRelevance.matches("METHENY", "80/81", "Pat Metheny"))
    }

    /// Word order should not matter, and punctuation should not split a match.
    func testWordOrderAndPunctuationDoNotDefeatAMatch() {
        XCTAssertTrue(AppleSearchRelevance.matches("metheny pat", "80/81", "Pat Metheny"))
        XCTAssertTrue(AppleSearchRelevance.matches("  Pat   Metheny  ", "80/81", "Pat Metheny"))
    }

    /// An empty query must not filter everything away — the caller guards it, but a filter
    /// that silently empties the list on a blank term is the wrong default.
    func testAnEmptyQueryMatchesEverything() {
        XCTAssertTrue(AppleSearchRelevance.matches("", "anything", "anyone"))
        XCTAssertTrue(AppleSearchRelevance.matches("   ", "anything", "anyone"))
    }

    // MARK: - Playlists
    //
    // MEASURED ON HARDWARE 2026-08-20, and this shape had never been proven before. The
    // contract recorded it from a favorite, but only the song and album addresses had ever
    // been BUILT from parts and played. Two were, on Garage, muted:
    //   pl.f4d106fed2bd41149aaacabb233eb5eb → 50 tracks, real duration 0:03:04
    //   pl.ebe2805581da4c409cb07eacd1c7d8ec → 21 tracks, real duration 0:04:52
    // The second id came from MusicKit, which proves the whole chain end to end.

    private let playlistId = "pl.ebe2805581da4c409cb07eacd1c7d8ec"

    /// `0006` for a playlist against `0004` for an album — the same split Spotify's own
    /// favorites show. Getting this wrong is silent: Sonos returns 200 and plays nothing.
    func testThePlaylistAddressUsesTheContainerPrefixForPlaylistsNotAlbums() {
        XCTAssertEqual(
            AppleMusicPlayback.playlistContainerURI(playlistId: playlistId),
            "x-rincon-cpcontainer:00060000playlist%3apl.ebe2805581da4c409cb07eacd1c7d8ec?sid=204&flags=0&sn=5")
    }

    /// Playlist ids are `pl.`-prefixed rather than numeric — the one Apple id space that is
    /// not a number, which is why ApplePlaylist.id is a String while albums and tracks are Int.
    func testThePlaylistIdIsCarriedVerbatimIncludingItsPrefix() {
        XCTAssertTrue(AppleMusicPlayback.playlistObjectId(playlistId: playlistId)
                        .hasSuffix(playlistId),
                      "the pl. prefix is part of the id, not decoration to strip")
    }

    /// Same `<res>` rule as tracks and albums — see the note above.
    func testThePlaylistMetadataCarriesNoResElementAndIsAPlaylistContainer() {
        let didl = AppleMusicPlayback.playlistDIDL(playlistId: playlistId,
                                                   title: "Pat Metheny Essentials",
                                                   token: token)
        XCTAssertFalse(didl.contains("<res"),
                       "a <res> element makes Sonos store an opaque octet-stream, no duration")
        XCTAssertTrue(didl.contains("object.container.playlistContainer"),
                      "an album class on a playlist container is the silent-failure case")
        XCTAssertTrue(didl.contains(token), "containers require the household token")
    }

    /// A playlist name can carry an ampersand, and an unescaped one breaks the SOAP body.
    func testAPlaylistTitleIsXMLEscaped() {
        let didl = AppleMusicPlayback.playlistDIDL(playlistId: playlistId,
                                                   title: "Rock & Roll", token: token)
        XCTAssertTrue(didl.contains("Rock &amp; Roll"))
        XCTAssertFalse(didl.contains("Rock & Roll"))
    }

    /// THE RULE THAT LOOKS WRONG. Supplying a `<res>` element makes Sonos take our word
    /// for the resource: it stores `application/octet-stream` and reports TrackDuration
    /// 0:00:00 forever. Omit it, and Sonos resolves the track through the service and
    /// returns the real mime type and length. Its own favorite metadata carries no
    /// `<res>` either — which is what finally gave it away.
    func testTheMetadataCarriesNoResElement() {
        let didl = AppleMusicPlayback.didl(catalogueId: 1443195687,
                                           title: "Waltz for Debby", token: token)
        XCTAssertFalse(didl.contains("<res"),
                       "a <res> element makes Sonos store an opaque octet-stream, no duration")
        XCTAssertFalse(didl.contains("duration="), "Sonos supplies the duration; ours is discarded")
    }

    /// The object id and the token together are what make Sonos resolve through the
    /// service. Drop either and the item comes back as octet-stream.
    func testTheMetadataCarriesTheObjectIdAndTheToken() {
        let didl = AppleMusicPlayback.didl(catalogueId: 1443195687, title: "x", token: token)
        XCTAssertTrue(didl.contains("<item id=\"10032028song%3a1443195687\""))
        XCTAssertTrue(didl.contains(token))
        XCTAssertTrue(didl.contains("<upnp:class>object.item.audioItem.musicTrack</upnp:class>"))
    }

    /// Same class of bug that stopped SiriusXM playing on 2026-08-12 — metadata
    /// interpolated raw into XML.
    func testTitlesAreEscapedBeforeEnteringTheEnvelope() {
        let didl = AppleMusicPlayback.didl(catalogueId: 1, title: "Salt & \"Pepper\" <live>",
                                           token: token)
        XCTAssertTrue(didl.contains("Salt &amp; &quot;Pepper&quot; &lt;live&gt;"))
        XCTAssertFalse(didl.contains("Salt & \""), "a raw ampersand malforms the envelope")
    }

    // MARK: - Finding the household token

    /// One saved favorite is enough — every favorite of a service embeds the same cdudn.
    func testTheTokenIsFoundInAnyFavoriteThatCarriesIt() {
        let spotify = "<desc id=\"cdudn\">SA_RINCON3079_X_#Svc3079-5bc962e7-Token</desc>"
        let apple = "<desc id=\"cdudn\">\(token)</desc>"
        XCTAssertEqual(AppleMusicPlayback.token(from: [spotify, apple]), token)
    }

    /// A household with no Apple Music favorite is a REPORTABLE STATE, not an error.
    /// Returning another service's token would be far worse than returning nothing.
    func testAnotherServicesTokenIsNeverMistakenForAppleMusic() {
        XCTAssertNil(AppleMusicPlayback.token(from: [
            "<desc>SA_RINCON3079_X_#Svc3079-5bc962e7-Token</desc>",
            "<desc>SA_RINCON9479_X_#Svc9479-4f5dfd4b-Token</desc>"]))
        XCTAssertNil(AppleMusicPlayback.token(from: []))
    }

    /// The service number is derivable rather than discoverable — sid × 256 + 7 held for
    /// every linked service in the household.
    func testTheServiceNumberFollowsTheHouseholdPattern() {
        XCTAssertEqual(AppleMusicPlayback.serviceId * 256 + 7, 52231)
    }

    // MARK: - Recognising what is playing
    //
    // THE SKIP BUG. Without an adapter claiming these URIs the service fell back to
    // r:streamContent, which Apple Music leaves EMPTY, and the no-blank rule then held
    // the PREVIOUS song's title, artist and cover through every skip. Reported from the
    // room 2026-08-18. The first track looked right only because the app's own
    // declaration was still inside its grace window.

    func testAppleMusicIsRecognisedInBothIdentifierSpaces() {
        let a = AppleMusicAdapter()
        XCTAssertEqual(a.stationKey(for: "x-sonos-http:song%3a358211473.mp4?sid=204&flags=8232&sn=5"),
                       "song:358211473")
        XCTAssertEqual(a.stationKey(for: "x-sonos-http:librarytrack%3ai.MoxKqdpsDk4Mg.mp4?sid=204&flags=8232&sn=5"),
                       "librarytrack:i.moxkqdpsdk4mg")
    }

    /// x-sonos-http: is a GENERIC Sonos transport — Sonos Radio uses it too, under a
    /// different service id. Claiming the scheme alone would make this adapter answer for
    /// a service it knows nothing about.
    func testAppleMusicDoesNotClaimAnotherServiceOnTheSameScheme() {
        let a = AppleMusicAdapter()
        XCTAssertNil(a.stationKey(for: "x-sonos-http:sonos%3a4375c80b-DZR%3a28.mp4?sid=303&flags=32"))
        XCTAssertNil(a.stationKey(for: "x-file-cifs://nas/Music/track.flac"))
        XCTAssertNil(a.stationKey(for: "x-sonosapi-radio:sonos%3a158291?sid=303"))
    }

    /// The whole point of the adapter: text and artwork come from the track metadata,
    /// never from the empty streamContent field.
    func testAppleMusicReadsTheTrackMetadataBlock() {
        let uri = "x-sonos-http:song%3a358211473.mp4?sid=204&flags=8232&sn=5"
        XCTAssertEqual(RadioServiceRegistry.nowPlayingSource(forLoadedURI: "x-rincon-queue:RINCON_1#0",
                                                            trackURI: uri), .trackMetadata)
        XCTAssertTrue(RadioServiceRegistry.providesTrackArt(forLoadedURI: "x-rincon-queue:RINCON_1#0",
                                                           trackURI: uri))
    }

    /// An Apple Music track belongs to an album, and the card's subtitle is the only
    /// place to say so — otherwise the right song shows over a blank line.
    func testTheAlbumNameIsReadFromTheTrackMetadata() {
        var zone = SonosZone(id: "Z1", name: "Garage", host: "10.0.0.9", isPlaying: true, volume: 0)
        zone.currentStationURI = "x-rincon-queue:RINCON_1#0"
        zone.currentTrackURI = "x-sonos-http:song%3a358211473.mp4?sid=204&flags=8232&sn=5"
        let data = Data("""
        <s:Envelope><s:Body><u:GetPositionInfoResponse><TrackMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;
        &lt;r:streamContent&gt;&lt;/r:streamContent&gt;
        &lt;dc:title&gt;Sneak a Peek&lt;/dc:title&gt;&lt;dc:creator&gt;Euge Groove&lt;/dc:creator&gt;
        &lt;upnp:album&gt;Just Feels Right&lt;/upnp:album&gt;
        &lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData></u:GetPositionInfoResponse></s:Body></s:Envelope>
        """.utf8)
        let after = SonosTopology.applyPositionInfo(to: zone, data: data)
        XCTAssertEqual(after.currentTrack, "Sneak a Peek")
        XCTAssertEqual(after.currentArtist, "Euge Groove")
        XCTAssertEqual(after.currentAlbum, "Just Feels Right")
    }

}
