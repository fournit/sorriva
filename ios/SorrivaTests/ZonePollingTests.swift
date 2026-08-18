import XCTest
#if SWIFT_PACKAGE
// Compiled into the FastTests target directly, so there is no module to import.
#else
@testable import Sorriva
#endif

// MARK: - ZonePollingTests
//
// Covers the polling path that FEEDS PlaybackStateReducer — parseTopology and
// updateZoneFromPositionInfo. Until now it had no coverage at all, while the
// reducer above it had 29 tests. That imbalance was not harmless: three defects
// in two days lived down here and every one was found by Tom looking at a room
// rather than by a test.
//
//   bZoneShowsStaleStationWhenTVTakesOver — the isHDMI half. The reducer handled
//     an HDMI-flagged zone correctly; the poll wiped the flag whenever the zone
//     was not playing, so during a TV warm-up the card flickered between the TV
//     icon and the last station. A reducer test asserting "an HDMI zone shows TV"
//     passes happily while the poll ensures no zone stays flagged long enough to
//     matter.
//   bGroupChangesMadeOutsideSorrivaAreNeverSeen — group membership only refreshed
//     after Sorriva's OWN commands.
//
// Fixtures in Fixtures/ are REAL SOAP responses captured from Tom's household on
// 2026-08-08 with tools/sonos.py, not hand-written approximations. The one
// exception is positioninfo_hdmi.xml, reassembled from the response body recorded
// during the live TV investigation the same day because the television was not on
// when the rest were captured — same bytes, different provenance, said out loud
// here so nobody mistakes it for a capture.

@MainActor
final class ZonePollingTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "xml")
        if let url { return try Data(contentsOf: url) }
        // Bundled resources are not always wired up in a synchronized-folder target;
        // fall back to the source tree so the suite runs either way.
        // resolvingSymlinksInPath matters: under the FastTests package this file is
        // a symlink to this one, and resolving it lands back in SorrivaTests/ where
        // Fixtures/ actually lives.
        let here = URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        return try Data(contentsOf: here.appendingPathComponent("Fixtures/\(name).xml"))
    }

    // MARK: - parseTopology

    func testTopologyParsesGroupsAndIdentifiesCoordinators() throws {
        let zones = SonosTopology.parse(data: try fixture("zonegroupstate"))
        let list = try XCTUnwrap(zones)
        XCTAssertFalse(list.isEmpty, "a real household response must yield zones")

        // Every zone is its group's coordinator and carries a routable host.
        for z in list {
            XCTAssertFalse(z.id.isEmpty, "zone with no UUID")
            XCTAssertFalse(z.name.isEmpty, "zone \(z.id) has no name")
            XCTAssertFalse(z.host.isEmpty, "zone \(z.name) has no host — commands would fail")
        }
        // Names are unique: a bonded home theatre must collapse to ONE zone, not one
        // per speaker. Living Room is an Arc Ultra plus four surrounds.
        let names = list.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate zone names: \(names)")
    }

    func testTopologyExcludesBondedSatellitesFromGroupMembers() throws {
        let list = try XCTUnwrap(SonosTopology.parse(data: try fixture("zonegroupstate")))
        // Surrounds and subs are bonded hardware, not group members a user can
        // manage. If they leak into groupMembers the UI offers to ungroup a speaker
        // that physically cannot leave.
        //
        // Living Room is the sharp case: an Arc Ultra with four bonded satellites and
        // two subs, alone in its group. It must yield ONE zone with ZERO members.
        let living = try XCTUnwrap(list.first { $0.name == "Living Room" })
        XCTAssertTrue(living.groupMembers.isEmpty,
                      "bonded satellites leaked in as group members: \(living.groupMembers.map(\.name))")
        XCTAssertEqual(list.filter { $0.name == "Living Room" }.count, 1,
                       "a bonded home theatre must collapse to one zone")

        // HONEST COVERAGE NOTE: this does NOT exercise the parser's inSatellite
        // guard. In this household satellites arrive as <Satellite> elements, which
        // the parser never treats as members in the first place, and they are also
        // Invisible="1" so the visibility filter would catch them anyway. Disabling
        // the guard was mutation-tested on 2026-08-08 and killed nothing. The guard
        // defends against a shape this hardware does not produce — leave it, but do
        // not believe it is covered.
    }

    // MARK: - Group membership
    //
    // bGroupChangesMadeOutsideSorrivaAreNeverSeen. The capture above has every zone
    // standalone, so it cannot show group membership being parsed at all. This
    // fixture was captured with Workout deliberately grouped into Listening Room
    // (nominated test zones, volume held at zero) and restored immediately after.

    func testTopologyPopulatesGroupMembers() throws {
        let list = try XCTUnwrap(SonosTopology.parse(data: try fixture("zonegroupstate_grouped")))
        let listening = try XCTUnwrap(list.first { $0.name == "Listening Room" })
        XCTAssertEqual(listening.groupMembers.map(\.name), ["Workout"],
                       "Workout was grouped into Listening Room when this was captured")
        XCTAssertFalse(try XCTUnwrap(listening.groupMembers.first).host.isEmpty,
                       "a member needs a host or it cannot be commanded")
    }

    func testAGroupedZoneIsNotAlsoAStandaloneZone() throws {
        let list = try XCTUnwrap(SonosTopology.parse(data: try fixture("zonegroupstate_grouped")))
        // A member belongs to its coordinator's zone and must NOT appear as a zone of
        // its own, or the UI shows the same speaker twice and offers to control it
        // independently while it is following someone else.
        XCTAssertNil(list.first { $0.name == "Workout" },
                     "Workout is a member of Listening Room here, not a zone in its own right")
    }

    func testGroupingIsVisibleAsADifferenceBetweenTheTwoCaptures() throws {
        let apart = try XCTUnwrap(SonosTopology.parse(data: try fixture("zonegroupstate")))
        let together = try XCTUnwrap(SonosTopology.parse(data: try fixture("zonegroupstate_grouped")))
        // The whole point of bGroupChangesMadeOutsideSorrivaAreNeverSeen: the payload
        // Sorriva already fetches every 15 seconds DOES carry the change. Two real
        // captures, one grouped and one not, differing exactly where they should.
        XCTAssertNotNil(apart.first { $0.name == "Workout" }, "standalone in the first capture")
        XCTAssertNil(together.first { $0.name == "Workout" }, "grouped away in the second")
        XCTAssertEqual(together.count, apart.count - 1,
                       "grouping two zones yields one fewer zone")
    }

    func testTopologyCarriesIdleState() throws {
        let list = try XCTUnwrap(SonosTopology.parse(data: try fixture("zonegroupstate")))
        // IdleState is the ONLY way to tell a live input from a selected one — see
        // sonos-playback-contract.md 6a. If parsing drops it every zone silently
        // defaults to false and a TV that has gone quiet becomes indistinguishable
        // from one that is playing.
        //
        // The capture caught a useful moment: Living Room was on its TV input with
        // audio flowing (IdleState=0) while the whole rest of the house was idle.
        // Asserting the SPLIT is what makes this a test — asserting the field merely
        // exists would pass on a parser that returned a constant.
        XCTAssertEqual(list.count, 9, "nine groups in the capture")
        let living = try XCTUnwrap(list.first { $0.name == "Living Room" })
        XCTAssertFalse(living.idleState, "Living Room was playing TV audio when this was captured")
        for z in list where z.name != "Living Room" {
            XCTAssertTrue(z.idleState, "\(z.name) was idle in the capture")
        }
    }

    func testTopologyRejectsRubbishWithoutCrashing() {
        XCTAssertNil(SonosTopology.parse(data: Data()), "empty data must not parse")
        XCTAssertNil(SonosTopology.parse(data: Data("not xml at all".utf8)))
        // A truncated response is the realistic failure — a timeout mid-transfer.
        XCTAssertNil(SonosTopology.parse(data: Data("<s:Envelope><ZoneGroupState>".utf8)))
    }

    // MARK: - mergeTopology
    //
    // bGroupChangesMadeOutsideSorrivaAreNeverSeen. Topology owns identity and
    // structure; the 2s transport poll owns activity. The merge is the contract
    // between them, and it has to be a merge rather than an assignment because
    // grouping changes HOW MANY zones exist — a zone that joins a group stops being
    // a zone and becomes a member of one.

    private func zoneWithState(_ id: String, _ name: String,
                               playing: Bool = true, volume: Int = 33,
                               track: String = "Song", hdmi: Bool = false) -> SonosZone {
        var z = SonosZone(id: id, name: name, host: "10.0.0.9", isPlaying: playing, volume: volume)
        z.currentTrack = track
        z.currentTrackURI = "hls-radio://example"
        z.isHDMI = hdmi
        z.elapsedSeconds = 42
        z.capabilities = ["eq", "volume", "mute", "bass"]
        z.dbDeviceId = "db-\(id)"
        return z
    }

    func testMergeAdoptsGroupStructureFromTopology() throws {
        let apart = try XCTUnwrap(SonosTopology.parse(data: try fixture("zonegroupstate")))
        let together = try XCTUnwrap(SonosTopology.parse(data: try fixture("zonegroupstate_grouped")))

        // The app is holding the ungrouped world; Sonos now reports the grouped one.
        // This is exactly what happens when a TV takes a room, or somebody groups from
        // the Sonos app — and what Sorriva used to miss entirely.
        let merged = SonosTopology.merge(parsed: together, into: apart)
        XCTAssertNil(merged.first { $0.name == "Workout" },
                     "Workout joined a group and must stop being a zone of its own")
        let listening = try XCTUnwrap(merged.first { $0.name == "Listening Room" })
        XCTAssertEqual(listening.groupMembers.map(\.name), ["Workout"])
    }

    func testMergeSeesAnUngroupToo() throws {
        let apart = try XCTUnwrap(SonosTopology.parse(data: try fixture("zonegroupstate")))
        let together = try XCTUnwrap(SonosTopology.parse(data: try fixture("zonegroupstate_grouped")))
        // The other direction — Sonos ungrouping on TV autoplay is precisely this.
        let merged = SonosTopology.merge(parsed: apart, into: together)
        XCTAssertNotNil(merged.first { $0.name == "Workout" }, "Workout left the group")
        let listening = try XCTUnwrap(merged.first { $0.name == "Listening Room" })
        XCTAssertTrue(listening.groupMembers.isEmpty)
    }

    /// THE REASON THIS IS A MERGE. Topology carries no transport state, so a naive
    /// assignment would blank every zone's track, volume and playing state for the
    /// 15-second window until the next transport poll refilled them.
    func testMergePreservesTransportStateTopologyDoesNotKnow() throws {
        let live = [zoneWithState("A", "Garage", playing: true, volume: 33, track: "Delirious", hdmi: true)]
        var fresh = SonosZone(id: "A", name: "Garage", host: "10.0.0.9", isPlaying: false, volume: 0)
        fresh.idleState = true

        let merged = SonosTopology.merge(parsed: [fresh], into: live)
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].isPlaying, "playing is the transport poll's fact, not topology's")
        XCTAssertEqual(merged[0].volume, 33)
        XCTAssertEqual(merged[0].currentTrack, "Delirious")
        XCTAssertEqual(merged[0].elapsedSeconds, 42)
        XCTAssertTrue(merged[0].isHDMI, "which input a zone is on must survive a topology refresh")
        XCTAssertEqual(merged[0].capabilities, ["eq", "volume", "mute", "bass"],
                       "capabilities come from the devices table and are not in the payload")
        XCTAssertEqual(merged[0].dbDeviceId, "db-A")
        XCTAssertTrue(merged[0].idleState, "idleState IS topology's fact and must be taken from it")
    }

    /// A timed-out or truncated response parses to nothing. Applying that would clear
    /// every zone in the app — the hazard that kept full topology refreshes off the
    /// poll loop in the first place, and the reason this guard exists.
    func testMergeRefusesToActOnAnEmptyParse() {
        let live = [zoneWithState("A", "Garage"), zoneWithState("B", "Patio")]
        let merged = SonosTopology.merge(parsed: [], into: live)
        XCTAssertEqual(merged.count, 2, "an empty parse must never clear the zone list")
        XCTAssertEqual(merged.map(\.name), ["Garage", "Patio"])
    }

    /// THE REGRESSION THIS EXISTS TO CATCH. `zones` is a display-ready list and has
    /// always been alphabetical, but that invariant lived as a `.sorted` at each
    /// assignment site plus a comment on the property. Adding a new assignment site —
    /// the 15-second merge, 2026-08-08 — silently broke it, and because that poll
    /// replaces the list constantly the ordering survived only until the first tick.
    /// Zone cards, the transfer picker and the group picker all went unordered.
    ///
    /// Sorting inside the merge puts the rule in one place; asserting it here means the
    /// next person to add an assignment site cannot quietly lose it again.
    func testMergeReturnsZonesAlphabetically() throws {
        let parsed = try XCTUnwrap(SonosTopology.parse(data: try fixture("zonegroupstate")))
        let merged = SonosTopology.merge(parsed: parsed, into: [])
        let names = merged.map(\.name)
        XCTAssertEqual(names, names.sorted(), "zones must come back alphabetical, got \(names)")
    }

    /// Order must not depend on what the app happened to be holding beforehand.
    func testMergeSortsRegardlessOfExistingOrder() throws {
        let parsed = try XCTUnwrap(SonosTopology.parse(data: try fixture("zonegroupstate")))
        let scrambled = Array(parsed.reversed())
        let merged = SonosTopology.merge(parsed: scrambled, into: scrambled)
        let names = merged.map(\.name)
        XCTAssertEqual(names, names.sorted(), "a reversed input must still come back sorted")
    }

    /// Members arrive from TopologyParser with no volume — the struct default of 0,
    /// which the UI draws as MUTED. The merge must carry their real levels forward the
    /// same way it carries the zone's own, or every refresh silences the sliders until
    /// the next poll refills them. That cycling is what Tom saw on Master Bedroom and
    /// Master Bath while the speakers sat steady at 14 and 18.
    func testMergePreservesGroupMemberVolumes() {
        var member = SonosGroupMember(id: "M1", name: "Master Bedroom", host: "10.0.0.11")
        member.volume = 14
        var live = SonosZone(id: "A", name: "Living Room", host: "10.0.0.9",
                             isPlaying: true, volume: 9)
        live.groupMembers = [member]

        // What topology hands back: the same member, volume unset.
        var fresh = SonosZone(id: "A", name: "Living Room", host: "10.0.0.9",
                              isPlaying: false, volume: 0)
        fresh.groupMembers = [SonosGroupMember(id: "M1", name: "Master Bedroom", host: "10.0.0.11")]

        let merged = SonosTopology.merge(parsed: [fresh], into: [live])
        XCTAssertEqual(merged[0].groupMembers.first?.volume, 14,
                       "a member's volume must survive a topology refresh")
    }

    /// ...but topology still decides WHO is in the group. A member that has left must
    /// not be resurrected just because we remember how loud it was.
    func testMergeDoesNotResurrectADepartedMember() {
        var gone = SonosGroupMember(id: "M1", name: "Workout", host: "10.0.0.11")
        gone.volume = 30
        var live = SonosZone(id: "A", name: "Living Room", host: "10.0.0.9",
                             isPlaying: true, volume: 9)
        live.groupMembers = [gone]

        var fresh = SonosZone(id: "A", name: "Living Room", host: "10.0.0.9",
                              isPlaying: false, volume: 0)
        fresh.groupMembers = []

        let merged = SonosTopology.merge(parsed: [fresh], into: [live])
        XCTAssertTrue(merged[0].groupMembers.isEmpty,
                      "topology is authoritative for membership, the poll only for volume")
    }

    func testMergeAcceptsAZoneItHasNeverSeen() {
        // A speaker powered on mid-session has no prior state to carry forward.
        let fresh = SonosZone(id: "NEW", name: "Kitchen", host: "10.0.0.50",
                              isPlaying: false, volume: 10)
        let merged = SonosTopology.merge(parsed: [fresh], into: [])
        XCTAssertEqual(merged.map(\.name), ["Kitchen"])
    }

    // MARK: - updateZoneFromPositionInfo

    private func testZone(_ id: String) -> SonosZone {
        SonosZone(id: id, name: "Test Room", host: "10.0.0.9",
                  isPlaying: true, volume: 20)
    }

    func testHDMIPositionInfoFlagsTheZoneAsTV() throws {
        var zone = testZone("Z1")
        zone = SonosTopology.applyPositionInfo(to: zone, data: try fixture("positioninfo_hdmi"))
        XCTAssertTrue(zone.isHDMI, "an htastream URI must flag the zone as HDMI")
        XCTAssertEqual(zone.currentTrack, "TV")
    }

    func testStationPositionInfoDoesNotFlagHDMI() throws {
        var zone = testZone("Z1")
        zone = SonosTopology.applyPositionInfo(to: zone, data: try fixture("positioninfo_station"))
        XCTAssertFalse(zone.isHDMI)
        XCTAssertTrue(zone.currentTrackURI.contains("radio"),
                      "got \(zone.currentTrackURI)")
    }

    func testLocalFilePositionInfoDoesNotFlagHDMI() throws {
        var zone = testZone("Z1")
        zone = SonosTopology.applyPositionInfo(to: zone, data: try fixture("positioninfo_local"))
        XCTAssertFalse(zone.isHDMI)
        XCTAssertTrue(zone.currentTrackURI.hasPrefix("x-file-cifs://"),
                      "got \(zone.currentTrackURI)")
    }

    /// Leaving the TV input can only mean the URI ceasing to be an htastream URI.
    func testMovingFromHDMIToAStationClearsTheFlag() throws {
        var zone = testZone("Z1")
        zone = SonosTopology.applyPositionInfo(to: zone, data: try fixture("positioninfo_hdmi"))
        XCTAssertTrue(zone.isHDMI)
        zone = SonosTopology.applyPositionInfo(to: zone, data: try fixture("positioninfo_station"))
        XCTAssertFalse(zone.isHDMI, "a non-HDMI URI must clear the flag")
    }

    /// THE FLICKER. Which input is selected is a SOURCE fact; whether sound is
    /// coming out is an ACTIVITY fact. A TV negotiates HDMI before audio flows, so
    /// the playing state oscillates during warm-up. The poll used to clear isHDMI
    /// on every cycle that landed on "not playing", and the card flickered between
    /// the TV icon and the last station for the whole warm-up.
    func testAnIdleHDMIZoneStaysFlaggedAsTV() throws {
        var zone = testZone("Z1")
        zone = SonosTopology.applyPositionInfo(to: zone, data: try fixture("positioninfo_hdmi"))
        zone.isPlaying = false
        zone.idleState = true
        zone = SonosTopology.applyPositionInfo(to: zone, data: try fixture("positioninfo_hdmi"))
        XCTAssertTrue(zone.isHDMI,
                      "a zone parked on its TV input is still on its TV input when silent")
    }

    // MARK: - Station identity (GetMediaInfo)
    //
    // Sonos Radio reports a PER-TRACK TrackURI while the station lives only in
    // CurrentURI. Matching a station on the track URI missed every time, the no-blank
    // rule held the previous content, and a zone playing Brit Soul went on claiming
    // Lost 80s. Measured 2026-08-13 against a live speaker.

    private func mediaInfo(currentURI: String) -> Data {
        Data("""
        <?xml version="1.0"?><s:Envelope><s:Body><u:GetMediaInfoResponse>
        <NrTracks>1</NrTracks><CurrentURI>\(currentURI)</CurrentURI>
        <CurrentURIMetaData></CurrentURIMetaData></u:GetMediaInfoResponse></s:Body></s:Envelope>
        """.utf8)
    }

    func testLoadedURIIsReadFromMediaInfo() {
        let zone = SonosTopology.applyMediaInfo(
            to: testZone("Z1"),
            data: mediaInfo(currentURI: "x-sonosapi-radio:sonos%3a158291?sid=303&amp;flags=0&amp;sn=1"))
        XCTAssertEqual(zone.currentStationURI,
                       "x-sonosapi-radio:sonos%3a158291?sid=303&flags=0&sn=1",
                       "entities must be decoded — the query is part of the stored URI")
    }

    /// THE FIX. A station lookup must use what is LOADED, never which track is playing.
    func testIdentityPrefersTheLoadedURIOverTheTrackURI() {
        var zone = testZone("Z1")
        zone.currentTrackURI = "x-sonos-http:sonos%3a4375c80bc6059732560f2c94d4eaaa20-DZR%3a28"
        XCTAssertEqual(zone.stationIdentityURI, zone.currentTrackURI,
                       "with nothing loaded reported, the track URI is all there is")

        zone = SonosTopology.applyMediaInfo(
            to: zone, data: mediaInfo(currentURI: "x-sonosapi-radio:sonos%3a158291?sid=303"))
        XCTAssertEqual(zone.stationIdentityURI, "x-sonosapi-radio:sonos%3a158291?sid=303",
                       "once Sonos names what is loaded, that is the station's identity")
    }

    /// iHeart and SomaFM report the same URI in both places, which is why this went
    /// unnoticed for months — those services keep working unchanged.
    func testDirectlyAddressedServicesAreUnaffected() {
        var zone = testZone("Z1")
        let stream = "x-rincon-mp3radio://ice2.somafm.com/groovesalad-128-aac"
        zone.currentTrackURI = stream
        zone = SonosTopology.applyMediaInfo(to: zone, data: mediaInfo(currentURI: stream))
        XCTAssertEqual(zone.stationIdentityURI, stream)
    }

    func testMediaInfoWithoutACurrentURILeavesTheZoneAlone() {
        var zone = testZone("Z1")
        zone.currentTrackURI = "x-file-cifs://nas/a.flac"
        let after = SonosTopology.applyMediaInfo(to: zone, data: Data("garbage".utf8))
        XCTAssertEqual(after.currentStationURI, "")
        XCTAssertEqual(after.stationIdentityURI, "x-file-cifs://nas/a.flac")
    }

    /// A topology refresh must not wipe it — same rule as every other transport fact.
    func testMergePreservesTheLoadedURI() {
        var live = testZone("Z1")
        live = SonosTopology.applyMediaInfo(
            to: live, data: mediaInfo(currentURI: "x-sonosapi-radio:sonos%3a158291"))
        let fresh = SonosZone(id: "Z1", name: "Test Room", host: "10.0.0.9",
                              isPlaying: false, volume: 20)
        let merged = SonosTopology.merge(parsed: [fresh], into: [live])
        XCTAssertEqual(merged.first?.currentStationURI, "x-sonosapi-radio:sonos%3a158291")
    }

    // MARK: - Per-service now-playing
    //
    // Sonos Radio leaves r:streamContent EMPTY and publishes the song, the artist and a
    // per-track cover in the DIDL track metadata. iHeart and SomaFM do the opposite, and
    // put a filename or a channel slug in dc:title — which is why reading dc:title
    // globally once put "hls.m3u8" on a zone card. The service decides. Measured against
    // the Office speaker 2026-08-13.

    private func sonosRadioPosition(title: String = "My Hood",
                                    creator: String = "RAY BLK",
                                    art: String = "https://sonosradio.imgix.net/station-images/78208e79") -> Data {
        Data("""
        <?xml version="1.0"?><s:Envelope><s:Body><u:GetPositionInfoResponse>
        <Track>1</Track><TrackDuration>0:00:00</TrackDuration>
        <TrackMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;&lt;dc:title&gt;\(title)&lt;/dc:title&gt;
        &lt;dc:creator&gt;\(creator)&lt;/dc:creator&gt;
        &lt;upnp:albumArtURI&gt;\(art)&lt;/upnp:albumArtURI&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>
        <TrackURI>x-sonos-http:sonos%3a4375c80bc6059732560f2c94d4eaaa20-DZR%3a28</TrackURI>
        <RelTime>0:01:23</RelTime></u:GetPositionInfoResponse></s:Body></s:Envelope>
        """.utf8)
    }

    private func sonosRadioZone() -> SonosZone {
        var zone = testZone("Z1")
        zone.currentStationURI = "x-sonosapi-radio:sonos%3a158291?sid=303&flags=0&sn=1"
        return zone
    }

    func testSonosRadioReportsTrackArtistAndPerTrackArt() {
        let zone = SonosTopology.applyPositionInfo(to: sonosRadioZone(), data: sonosRadioPosition())
        XCTAssertEqual(zone.currentTrack, "My Hood")
        XCTAssertEqual(zone.currentArtist, "RAY BLK")
        XCTAssertEqual(zone.currentTrackArtURL,
                       "https://sonosradio.imgix.net/station-images/78208e79",
                       "the per-song cover is the whole point — a station logo is a stand-in")
    }

    /// THE REGRESSION GUARD. dc:title for iHeart is the manifest filename.
    func testStreamContentServicesStillIgnoreTrackMetadata() {
        var zone = testZone("Z1")
        zone.currentStationURI = "hls-radio://http://stream.revma.ihrhls.com/zc7934/hls.m3u8"
        let data = Data("""
        <?xml version="1.0"?><s:Envelope><s:Body><u:GetPositionInfoResponse>
        <TrackMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;&lt;dc:title&gt;hls.m3u8&lt;/dc:title&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>
        <r:streamContent>TITLE Sweet Dreams|ARTIST Eurythmics</r:streamContent>
        </u:GetPositionInfoResponse></s:Body></s:Envelope>
        """.utf8)
        let after = SonosTopology.applyPositionInfo(to: zone, data: data)
        XCTAssertEqual(after.currentTrack, "Sweet Dreams", "must come from r:streamContent")
        XCTAssertNotEqual(after.currentTrack, "hls.m3u8")
        XCTAssertTrue(after.currentTrackArtURL.isEmpty, "iHeart publishes no per-track art")
    }

    /// A cover must not outlive the service that supplied it.
    func testSwitchingToAStreamContentServiceClearsPerTrackArt() {
        var zone = SonosTopology.applyPositionInfo(to: sonosRadioZone(), data: sonosRadioPosition())
        XCTAssertFalse(zone.currentTrackArtURL.isEmpty)

        zone.currentStationURI = "x-rincon-mp3radio://ice2.somafm.com/groovesalad-128-aac"
        zone = SonosTopology.applyPositionInfo(to: zone, data: Data("""
        <s:Envelope><s:Body><u:GetPositionInfoResponse>
        <r:streamContent>Nine Inch Nails - La Mer</r:streamContent>
        </u:GetPositionInfoResponse></s:Body></s:Envelope>
        """.utf8))
        XCTAssertTrue(zone.currentTrackArtURL.isEmpty,
                      "Sonos Radio's cover must not survive onto a SomaFM stream")
    }

    /// Sonos reports an empty title between songs; blanking on that flickers the card.
    func testAnEmptyTitleBetweenSongsHoldsThePreviousTrack() {
        var zone = SonosTopology.applyPositionInfo(to: sonosRadioZone(), data: sonosRadioPosition())
        zone = SonosTopology.applyPositionInfo(
            to: zone, data: sonosRadioPosition(title: "", creator: "", art: ""))
        XCTAssertEqual(zone.currentTrack, "My Hood")
        XCTAssertEqual(zone.currentArtist, "RAY BLK")
        XCTAssertTrue(zone.currentTrackArtURL.isEmpty,
                      "artwork is NOT held — a cover outliving its song is worse than none")
    }

    func testMergePreservesPerTrackArt() {
        let live = SonosTopology.applyPositionInfo(to: sonosRadioZone(), data: sonosRadioPosition())
        let fresh = SonosZone(id: "Z1", name: "Test Room", host: "10.0.0.9",
                              isPlaying: false, volume: 20)
        let merged = SonosTopology.merge(parsed: [fresh], into: [live])
        XCTAssertEqual(merged.first?.currentTrackArtURL,
                       "https://sonosradio.imgix.net/station-images/78208e79")
    }

    // MARK: - Sonos Radio adapter

    func testSonosRadioAdapterMatchesAcrossCaseAndFlags() {
        let adapter = SonosRadioAdapter()
        let stored = adapter.stationKey(for: "x-sonosapi-radio:sonos%3A158291?sid=303&flags=28780&sn=1")
        let live   = adapter.stationKey(for: "x-sonosapi-radio:sonos%3a158291?sid=303&flags=0&sn=1")
        XCTAssertEqual(stored, "158291")
        XCTAssertEqual(stored, live, "case and flags differ for the same station — measured")
    }

    /// SiriusXM ALSO reports x-sonosapi-radio: URIs. Claiming them would make this adapter
    /// answer for a service it knows nothing about.
    func testSonosRadioAdapterDoesNotClaimSiriusXM() {
        let adapter = SonosRadioAdapter()
        XCTAssertNil(adapter.stationKey(
            for: "x-sonosapi-radio:channel-xtra%3a282bae89-735a-c222-526d-d217cc615681?sid=37"))
        XCTAssertNil(adapter.stationKey(
            for: "x-sonosapi-stream:channel-linear%3A7a642de7-c33f-a628-efb2-3d94a829d17b?sid=37"))
    }

    func testNowPlayingSourceIsPerServiceAndDefaultsSafely() {
        XCTAssertEqual(RadioServiceRegistry.nowPlayingSource(
            forLoadedURI: "x-sonosapi-radio:sonos%3a158291?sid=303"), .trackMetadata)
        XCTAssertEqual(RadioServiceRegistry.nowPlayingSource(
            forLoadedURI: "hls-radio://http://stream.revma.ihrhls.com/zc7934/hls.m3u8"), .streamContent)
        // An unclaimed URI keeps the behaviour that shipped, rather than a new guess.
        XCTAssertEqual(RadioServiceRegistry.nowPlayingSource(
            forLoadedURI: "x-sonosapi-hls:something-nobody-has-taught-us"), .streamContent)
    }

    // MARK: - Spotify
    //
    // Spotify is the first service that is not a stream. A favorite is a CONTAINER that
    // expands into the Sonos queue, so what is LOADED afterwards is x-rincon-queue: —
    // an address naming no service. Asking only the loaded URI meant Spotify fell through
    // to r:streamContent, which it leaves EMPTY, so the card showed no song at all.
    // Captured from Patio 2026-08-16.

    private func spotifyPosition() -> Data {
        Data("""
        <?xml version="1.0"?><s:Envelope><s:Body><u:GetPositionInfoResponse>
        <Track>2</Track><TrackDuration>0:04:53</TrackDuration>
        <TrackMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;
        &lt;r:streamContent&gt;&lt;/r:streamContent&gt;
        &lt;upnp:albumArtURI&gt;/getaa?s=1&amp;amp;u=x-sonos-spotify%3aspotify%253atrack%253a7J1uxwnxfQLu4APicE5Rnj&lt;/upnp:albumArtURI&gt;
        &lt;dc:title&gt;Billie Jean&lt;/dc:title&gt;&lt;dc:creator&gt;Michael Jackson&lt;/dc:creator&gt;
        &lt;upnp:album&gt;Thriller&lt;/upnp:album&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>
        <TrackURI>x-sonos-spotify:spotify%3atrack%3a7J1uxwnxfQLu4APicE5Rnj?sid=12&amp;flags=8232&amp;sn=2</TrackURI>
        <RelTime>0:03:05</RelTime></u:GetPositionInfoResponse></s:Body></s:Envelope>
        """.utf8)
    }

    private func spotifyZone() -> SonosZone {
        // host matters here: Spotify's cover is resolved against the speaker.
        var zone = SonosZone(id: "Z1", name: "Test Room", host: "192.168.1.194",
                             isPlaying: true, volume: 20)
        zone.currentStationURI = "x-rincon-queue:RINCON_804AF2A73E9901400#0"
        zone.currentTrackURI = "x-sonos-spotify:spotify%3atrack%3a7J1uxwnxfQLu4APicE5Rnj?sid=12"
        return zone
    }

    func testSpotifyReportsTrackArtistFromTheTrackBlock() {
        let zone = SonosTopology.applyPositionInfo(to: spotifyZone(), data: spotifyPosition())
        XCTAssertEqual(zone.currentTrack, "Billie Jean")
        XCTAssertEqual(zone.currentArtist, "Michael Jackson")
    }

    /// Spotify's cover is served by the SPEAKER, not the service — a relative path.
    /// Left relative it is a broken image that looks like a metadata bug.
    func testSpotifyRelativeArtIsResolvedAgainstTheSpeaker() {
        let zone = SonosTopology.applyPositionInfo(to: spotifyZone(), data: spotifyPosition())
        XCTAssertTrue(zone.currentTrackArtURL.hasPrefix("http://192.168.1.194:1400/getaa?"),
                      "got \(zone.currentTrackArtURL)")
    }

    /// Sonos Radio's art is already absolute and must not be rewritten.
    func testAbsoluteArtIsLeftAlone() {
        let zone = SonosTopology.applyPositionInfo(to: sonosRadioZone(), data: sonosRadioPosition())
        XCTAssertEqual(zone.currentTrackArtURL,
                       "https://sonosradio.imgix.net/station-images/78208e79")
    }

    /// THE ROUTING RULE. The loaded URI wins; the track URI is only consulted when no
    /// adapter claims what is loaded.
    func testQueueContentIsIdentifiedByItsTrackURI() {
        XCTAssertEqual(RadioServiceRegistry.nowPlayingSource(
            forLoadedURI: "x-rincon-queue:RINCON_804AF2A73E9901400#0",
            trackURI: "x-sonos-spotify:spotify%3atrack%3a7J1uxwnxfQLu4APicE5Rnj?sid=12"),
            .trackMetadata)
    }

    /// Local albums play from the queue too. Nothing claims x-file-cifs://, so local
    /// playback keeps the path it has always had.
    func testLocalQueuePlaybackIsUnaffectedByTheTrackURIFallback() {
        XCTAssertEqual(RadioServiceRegistry.nowPlayingSource(
            forLoadedURI: "x-rincon-queue:RINCON_804AF2A73E9901400#0",
            trackURI: "x-file-cifs://nas/Music/track.flac"),
            .streamContent)
    }

    /// The fallback must not let a track URI override a station that IS identified.
    func testTheLoadedURIOutranksTheTrackURI() {
        XCTAssertEqual(RadioServiceRegistry.nowPlayingSource(
            forLoadedURI: "hls-radio://http://stream.revma.ihrhls.com/zc7934/hls.m3u8",
            trackURI: "x-sonos-spotify:spotify%3atrack%3aabc"),
            .streamContent, "iHeart is loaded — its own field choice wins")
    }

    func testSpotifyAdapterClaimsBothTrackAndPlaylistShapes() {
        let a = SpotifyAdapter()
        XCTAssertEqual(a.stationKey(for: "x-sonos-spotify:spotify%3atrack%3a7J1uxwnxfQ?sid=12"),
                       "7j1uxwnxfq")
        XCTAssertEqual(a.stationKey(for: "x-rincon-cpcontainer:1006206cspotify%3Aplaylist%3A37i9dQZ?sid=12"),
                       "37i9dqz")
        XCTAssertNil(a.stationKey(for: "x-file-cifs://nas/Music/track.flac"))
        XCTAssertNil(a.stationKey(for: "x-sonosapi-radio:sonos%3a158291?sid=303"))
    }

    // MARK: - SiriusXM
    //
    // One channel arrives under two unrelated identifiers depending on who started it.
    // All three shapes captured from live speakers 2026-08-17.

    private struct FakeStation: StationLike {
        var serviceId: String
        var streamURL: String?
        var name: String
    }

    private let sxmStored = "x-sonosapi-stream:channel-linear%3A65f04311-3581-256c-97b9-279838d6ff5e?sid=37&flags=8260&sn=3"
    private let sxmPlaying = "x-sonosapi-hls:channel-linear%3a65f04311-3581-256c-97b9-279838d6ff5e?sid=37&flags=8200&sn=4"
    private let sxmAlexa = "hls-radio://https://live-ftc-prod-device.streaming.siriusxm.com/v1/763a31_1786065831/sec-0/AAC_Audio/classicrewind/classicrewind_variant_short_v4.m3u8"

    /// THE FIX. Stored and playing differ by scheme, by the case of the encoded colon,
    /// and by the account handle — and are the same channel.
    func testSiriusXMChannelSurvivesTheSchemeChange() {
        let a = SiriusXMAdapter()
        XCTAssertEqual(a.stationKey(for: sxmStored), a.stationKey(for: sxmPlaying))
        XCTAssertEqual(a.stationKey(for: sxmStored),
                       "channel-linear:65f04311-3581-256c-97b9-279838d6ff5e")
    }

    func testSiriusXMMatchesAFavoriteStartedChannel() {
        let station = FakeStation(serviceId: "siriusxm", streamURL: sxmStored, name: "1st Wave")
        XCTAssertNotNil(RadioServiceRegistry.matchStation(uri: sxmPlaying, in: [station]))
    }

    /// Alexa hands the speaker a raw stream with NO channel id — only a slug in the path.
    /// Matched against the station name instead, which is why the channel-number prefix
    /// has to come off at import.
    func testSiriusXMMatchesAnAlexaStartedStreamByName() {
        let station = FakeStation(serviceId: "siriusxm",
                                  streamURL: "x-sonosapi-stream:channel-linear%3A7a642de7-c33f?sid=37",
                                  name: "Classic Rewind")
        XCTAssertNotNil(RadioServiceRegistry.matchStation(uri: sxmAlexa, in: [station]),
                        "slug 'classicrewind' should match the station name")

        let prefixed = FakeStation(serviceId: "siriusxm",
                                   streamURL: station.streamURL,
                                   name: "CH 25 - Classic Rewind")
        XCTAssertNil(RadioServiceRegistry.matchStation(uri: sxmAlexa, in: [prefixed]),
                     "with the channel number still attached the name match cannot work")
    }

    /// The slug tier must not reach past its own service.
    func testSiriusXMDoesNotClaimOtherServices() {
        let a = SiriusXMAdapter()
        XCTAssertNil(a.stationKey(for: "x-sonosapi-radio:sonos%3a158291?sid=303"))
        XCTAssertNil(a.stationKey(for: "x-sonos-spotify:spotify%3atrack%3aabc?sid=12"))
        XCTAssertNil(a.slug(for: "hls-radio://http://stream.revma.ihrhls.com/zc7934/hls.m3u8"))

        let iheart = FakeStation(serviceId: "iheart",
                                 streamURL: "hls-radio://http://stream.revma.ihrhls.com/zc7934/hls.m3u8",
                                 name: "Classic Rewind")
        XCTAssertNil(RadioServiceRegistry.matchStation(uri: sxmAlexa, in: [iheart]),
                     "a same-named station on another service must not be claimed")
    }

    /// SiriusXM splits what every other service keeps together: the song text is in
    /// r:streamContent and the COVER is in upnp:albumArtURI. Modelling those as one
    /// choice meant picking streamContent and silently losing the artwork. Captured from
    /// Garage playing 1st Wave, 2026-08-17.
    func testSiriusXMTakesTextFromStreamContentAndArtFromTheMetadata() {
        var zone = SonosZone(id: "Z1", name: "Garage", host: "192.168.1.137",
                             isPlaying: true, volume: 0)
        zone.currentStationURI = sxmPlaying
        let data = Data("""
        <?xml version="1.0"?><s:Envelope><s:Body><u:GetPositionInfoResponse>
        <TrackMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;
        &lt;r:streamContent&gt;TYPE=SNG|TITLE No New Tale To Tell|ARTIST Love &amp;amp; Rockets|ALBUM Earth, Sun, Moon&lt;/r:streamContent&gt;
        &lt;upnp:albumArtURI&gt;http://albumart.siriusxm.com/albumart/0130/WBCALT_NDCA-000099327-001_m.jpg&lt;/upnp:albumArtURI&gt;
        &lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>
        </u:GetPositionInfoResponse></s:Body></s:Envelope>
        """.utf8)
        zone = SonosTopology.applyPositionInfo(to: zone, data: data)
        XCTAssertEqual(zone.currentTrack, "No New Tale To Tell", "text from r:streamContent")
        XCTAssertEqual(zone.currentArtist, "Love & Rockets")
        XCTAssertEqual(zone.currentTrackArtURL,
                       "https://albumart.siriusxm.com/albumart/0130/WBCALT_NDCA-000099327-001_m.jpg",
                       "art from upnp:albumArtURI in the SAME response, upgraded to TLS")
    }

    /// The default stays off. iHeart publishes no cover, and SomaFM's field has never
    /// been checked — reading it blind could replace curated station art.
    func testServicesWithoutMeasuredArtworkGetNone() {
        var zone = testZone("Z1")
        zone.currentStationURI = "hls-radio://http://stream.revma.ihrhls.com/zc7934/hls.m3u8"
        let data = Data("""
        <s:Envelope><s:Body><u:GetPositionInfoResponse><TrackMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;
        &lt;upnp:albumArtURI&gt;http://example.com/should-not-be-read.jpg&lt;/upnp:albumArtURI&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>
        <r:streamContent>TITLE Sweet Dreams|ARTIST Eurythmics</r:streamContent>
        </u:GetPositionInfoResponse></s:Body></s:Envelope>
        """.utf8)
        zone = SonosTopology.applyPositionInfo(to: zone, data: data)
        XCTAssertEqual(zone.currentTrack, "Sweet Dreams")
        XCTAssertTrue(zone.currentTrackArtURL.isEmpty,
                      "iHeart is not declared as publishing per-song art")
    }

    /// REMOTE HTTP ARTWORK IS BLOCKED by App Transport Security and renders blank —
    /// measured on Garage 2026-08-17, where the zone card lost its artwork entirely.
    /// Upgraded to TLS rather than dropped: the same hosts answer over https with the
    /// identical image.
    func testRemoteHTTPArtworkIsUpgradedToHTTPS() {
        var zone = SonosZone(id: "Z1", name: "Garage", host: "192.168.1.137",
                             isPlaying: true, volume: 0)
        zone.currentStationURI = sxmPlaying
        let data = Data("""
        <s:Envelope><s:Body><u:GetPositionInfoResponse><TrackMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;
        &lt;r:streamContent&gt;TITLE Song|ARTIST Band&lt;/r:streamContent&gt;
        &lt;upnp:albumArtURI&gt;http://pri.art.prod.streaming.siriusxm.com/images/chan/45/x.jpg&lt;/upnp:albumArtURI&gt;
        &lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData></u:GetPositionInfoResponse></s:Body></s:Envelope>
        """.utf8)
        zone = SonosTopology.applyPositionInfo(to: zone, data: data)
        XCTAssertEqual(zone.currentTrackArtURL,
                       "https://pri.art.prod.streaming.siriusxm.com/images/chan/45/x.jpg")
        XCTAssertEqual(zone.currentTrack, "Song", "the text is still good")
    }

    /// HTTPS from anywhere is fine, and so is HTTP from the speaker itself — that is how
    /// Spotify's covers arrive and it is what the local-network exception is for.
    func testHTTPSAnywhereAndHTTPFromTheSpeakerAreAccepted() {
        XCTAssertEqual(
            SonosTopology.applyPositionInfo(to: sonosRadioZone(), data: sonosRadioPosition())
                .currentTrackArtURL,
            "https://sonosradio.imgix.net/station-images/78208e79")

        let spotify = SonosTopology.applyPositionInfo(to: spotifyZone(), data: spotifyPosition())
        XCTAssertTrue(spotify.currentTrackArtURL.hasPrefix("http://192.168.1.194:1400/getaa?"),
                      "the speaker's own art is local HTTP and must survive")
    }

    func testArtworkIsDeclaredPerService() {
        XCTAssertTrue(RadioServiceRegistry.providesTrackArt(forLoadedURI: sxmPlaying))
        XCTAssertTrue(RadioServiceRegistry.providesTrackArt(
            forLoadedURI: "x-sonosapi-radio:sonos%3a158291?sid=303"))
        XCTAssertFalse(RadioServiceRegistry.providesTrackArt(
            forLoadedURI: "hls-radio://http://stream.revma.ihrhls.com/zc7934/hls.m3u8"))
        XCTAssertFalse(RadioServiceRegistry.providesTrackArt(
            forLoadedURI: "x-sonosapi-hls:something-nobody-has-taught-us"))
    }

    // MARK: - Channel numbers

    func testChannelNumberIsStrippedFromSiriusXMNames() {
        XCTAssertEqual(SonosFavorites.displayTitle("CH 33 - 1st Wave", serviceId: "siriusxm"), "1st Wave")
        XCTAssertEqual(SonosFavorites.displayTitle("CH 25 - Classic Rewind", serviceId: "siriusxm"), "Classic Rewind")
        XCTAssertEqual(SonosFavorites.displayTitle("Ch. 8 – 80s on 8", serviceId: "siriusxm"), "80s on 8")
    }

    /// Deliberately narrow. A name that merely begins with letters and digits is a name.
    func testNamesThatOnlyLookLikeAChannelNumberSurvive() {
        for name in ["Channel 5", "CH2 Radio", "1st Wave", "Chill 33"] {
            XCTAssertEqual(SonosFavorites.displayTitle(name, serviceId: "siriusxm"), name)
        }
    }

    /// Other services are not SiriusXM and must not be rewritten.
    func testOnlySiriusXMNamesAreStripped() {
        XCTAssertEqual(SonosFavorites.displayTitle("CH 33 - 1st Wave", serviceId: "sonosradio"),
                       "CH 33 - 1st Wave")
    }

    // testPositionInfoForAnUnknownZoneIsIgnored moved to ZoneServiceLookupTests on
    // 2026-08-08. It asserts on the zone LOOKUP, which stayed in ZoneDiscoveryService
    // when the parsing moved to SonosTopology — so it needs a live service and cannot
    // run in the FastTests package.
}
