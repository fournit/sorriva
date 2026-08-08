import XCTest
@testable import Sorriva

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
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try Data(contentsOf: here.appendingPathComponent("Fixtures/\(name).xml"))
    }

    // MARK: - parseTopology

    func testTopologyParsesGroupsAndIdentifiesCoordinators() throws {
        let zones = ZoneDiscoveryService().parseTopology(data: try fixture("zonegroupstate"))
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
        let list = try XCTUnwrap(ZoneDiscoveryService().parseTopology(data: try fixture("zonegroupstate")))
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
        let list = try XCTUnwrap(ZoneDiscoveryService().parseTopology(data: try fixture("zonegroupstate_grouped")))
        let listening = try XCTUnwrap(list.first { $0.name == "Listening Room" })
        XCTAssertEqual(listening.groupMembers.map(\.name), ["Workout"],
                       "Workout was grouped into Listening Room when this was captured")
        XCTAssertFalse(try XCTUnwrap(listening.groupMembers.first).host.isEmpty,
                       "a member needs a host or it cannot be commanded")
    }

    func testAGroupedZoneIsNotAlsoAStandaloneZone() throws {
        let list = try XCTUnwrap(ZoneDiscoveryService().parseTopology(data: try fixture("zonegroupstate_grouped")))
        // A member belongs to its coordinator's zone and must NOT appear as a zone of
        // its own, or the UI shows the same speaker twice and offers to control it
        // independently while it is following someone else.
        XCTAssertNil(list.first { $0.name == "Workout" },
                     "Workout is a member of Listening Room here, not a zone in its own right")
    }

    func testGroupingIsVisibleAsADifferenceBetweenTheTwoCaptures() throws {
        let svc = ZoneDiscoveryService()
        let apart = try XCTUnwrap(svc.parseTopology(data: try fixture("zonegroupstate")))
        let together = try XCTUnwrap(svc.parseTopology(data: try fixture("zonegroupstate_grouped")))
        // The whole point of bGroupChangesMadeOutsideSorrivaAreNeverSeen: the payload
        // Sorriva already fetches every 15 seconds DOES carry the change. Two real
        // captures, one grouped and one not, differing exactly where they should.
        XCTAssertNotNil(apart.first { $0.name == "Workout" }, "standalone in the first capture")
        XCTAssertNil(together.first { $0.name == "Workout" }, "grouped away in the second")
        XCTAssertEqual(together.count, apart.count - 1,
                       "grouping two zones yields one fewer zone")
    }

    func testTopologyCarriesIdleState() throws {
        let list = try XCTUnwrap(ZoneDiscoveryService().parseTopology(data: try fixture("zonegroupstate")))
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
        let svc = ZoneDiscoveryService()
        XCTAssertNil(svc.parseTopology(data: Data()), "empty data must not parse")
        XCTAssertNil(svc.parseTopology(data: Data("not xml at all".utf8)))
        // A truncated response is the realistic failure — a timeout mid-transfer.
        XCTAssertNil(svc.parseTopology(data: Data("<s:Envelope><ZoneGroupState>".utf8)))
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
        let svc = ZoneDiscoveryService()
        let apart = try XCTUnwrap(svc.parseTopology(data: try fixture("zonegroupstate")))
        let together = try XCTUnwrap(svc.parseTopology(data: try fixture("zonegroupstate_grouped")))

        // The app is holding the ungrouped world; Sonos now reports the grouped one.
        // This is exactly what happens when a TV takes a room, or somebody groups from
        // the Sonos app — and what Sorriva used to miss entirely.
        let merged = ZoneDiscoveryService.mergeTopology(parsed: together, into: apart)
        XCTAssertNil(merged.first { $0.name == "Workout" },
                     "Workout joined a group and must stop being a zone of its own")
        let listening = try XCTUnwrap(merged.first { $0.name == "Listening Room" })
        XCTAssertEqual(listening.groupMembers.map(\.name), ["Workout"])
    }

    func testMergeSeesAnUngroupToo() throws {
        let svc = ZoneDiscoveryService()
        let apart = try XCTUnwrap(svc.parseTopology(data: try fixture("zonegroupstate")))
        let together = try XCTUnwrap(svc.parseTopology(data: try fixture("zonegroupstate_grouped")))
        // The other direction — Sonos ungrouping on TV autoplay is precisely this.
        let merged = ZoneDiscoveryService.mergeTopology(parsed: apart, into: together)
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

        let merged = ZoneDiscoveryService.mergeTopology(parsed: [fresh], into: live)
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
        let merged = ZoneDiscoveryService.mergeTopology(parsed: [], into: live)
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
        let svc = ZoneDiscoveryService()
        let parsed = try XCTUnwrap(svc.parseTopology(data: try fixture("zonegroupstate")))
        let merged = ZoneDiscoveryService.mergeTopology(parsed: parsed, into: [])
        let names = merged.map(\.name)
        XCTAssertEqual(names, names.sorted(), "zones must come back alphabetical, got \(names)")
    }

    /// Order must not depend on what the app happened to be holding beforehand.
    func testMergeSortsRegardlessOfExistingOrder() throws {
        let svc = ZoneDiscoveryService()
        let parsed = try XCTUnwrap(svc.parseTopology(data: try fixture("zonegroupstate")))
        let scrambled = Array(parsed.reversed())
        let merged = ZoneDiscoveryService.mergeTopology(parsed: scrambled, into: scrambled)
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

        let merged = ZoneDiscoveryService.mergeTopology(parsed: [fresh], into: [live])
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

        let merged = ZoneDiscoveryService.mergeTopology(parsed: [fresh], into: [live])
        XCTAssertTrue(merged[0].groupMembers.isEmpty,
                      "topology is authoritative for membership, the poll only for volume")
    }

    func testMergeAcceptsAZoneItHasNeverSeen() {
        // A speaker powered on mid-session has no prior state to carry forward.
        let fresh = SonosZone(id: "NEW", name: "Kitchen", host: "10.0.0.50",
                              isPlaying: false, volume: 10)
        let merged = ZoneDiscoveryService.mergeTopology(parsed: [fresh], into: [])
        XCTAssertEqual(merged.map(\.name), ["Kitchen"])
    }

    // MARK: - updateZoneFromPositionInfo

    private func service(withZone id: String) -> ZoneDiscoveryService {
        let svc = ZoneDiscoveryService()
        svc.zones = [SonosZone(id: id, name: "Test Room", host: "10.0.0.9",
                               isPlaying: true, volume: 20)]
        return svc
    }

    func testHDMIPositionInfoFlagsTheZoneAsTV() throws {
        let svc = service(withZone: "Z1")
        svc.updateZoneFromPositionInfo(zoneID: "Z1", positionData: try fixture("positioninfo_hdmi"))
        XCTAssertTrue(svc.zones[0].isHDMI, "an htastream URI must flag the zone as HDMI")
        XCTAssertEqual(svc.zones[0].currentTrack, "TV")
    }

    func testStationPositionInfoDoesNotFlagHDMI() throws {
        let svc = service(withZone: "Z1")
        svc.updateZoneFromPositionInfo(zoneID: "Z1", positionData: try fixture("positioninfo_station"))
        XCTAssertFalse(svc.zones[0].isHDMI)
        XCTAssertTrue(svc.zones[0].currentTrackURI.contains("radio"),
                      "got \(svc.zones[0].currentTrackURI)")
    }

    func testLocalFilePositionInfoDoesNotFlagHDMI() throws {
        let svc = service(withZone: "Z1")
        svc.updateZoneFromPositionInfo(zoneID: "Z1", positionData: try fixture("positioninfo_local"))
        XCTAssertFalse(svc.zones[0].isHDMI)
        XCTAssertTrue(svc.zones[0].currentTrackURI.hasPrefix("x-file-cifs://"),
                      "got \(svc.zones[0].currentTrackURI)")
    }

    /// Leaving the TV input can only mean the URI ceasing to be an htastream URI.
    func testMovingFromHDMIToAStationClearsTheFlag() throws {
        let svc = service(withZone: "Z1")
        svc.updateZoneFromPositionInfo(zoneID: "Z1", positionData: try fixture("positioninfo_hdmi"))
        XCTAssertTrue(svc.zones[0].isHDMI)
        svc.updateZoneFromPositionInfo(zoneID: "Z1", positionData: try fixture("positioninfo_station"))
        XCTAssertFalse(svc.zones[0].isHDMI, "a non-HDMI URI must clear the flag")
    }

    /// THE FLICKER. Which input is selected is a SOURCE fact; whether sound is
    /// coming out is an ACTIVITY fact. A TV negotiates HDMI before audio flows, so
    /// the playing state oscillates during warm-up. The poll used to clear isHDMI
    /// on every cycle that landed on "not playing", and the card flickered between
    /// the TV icon and the last station for the whole warm-up.
    func testAnIdleHDMIZoneStaysFlaggedAsTV() throws {
        let svc = service(withZone: "Z1")
        svc.updateZoneFromPositionInfo(zoneID: "Z1", positionData: try fixture("positioninfo_hdmi"))
        svc.zones[0].isPlaying = false
        svc.zones[0].idleState = true
        svc.updateZoneFromPositionInfo(zoneID: "Z1", positionData: try fixture("positioninfo_hdmi"))
        XCTAssertTrue(svc.zones[0].isHDMI,
                      "a zone parked on its TV input is still on its TV input when silent")
    }

    func testPositionInfoForAnUnknownZoneIsIgnored() throws {
        let svc = service(withZone: "Z1")
        svc.updateZoneFromPositionInfo(zoneID: "NOPE", positionData: try fixture("positioninfo_hdmi"))
        XCTAssertFalse(svc.zones[0].isHDMI, "a response for another zone must not bleed across")
    }
}
