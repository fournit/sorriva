import XCTest
#if SWIFT_PACKAGE
// Compiled into the FastTests target directly, so there is no module to import.
#else
@testable import Sorriva
#endif

// MARK: - TVTakeoverTests
// The guard that stops Sorriva taking a room away from a television.
//
// The whole feature turns on ONE predicate, and the interesting half of it is the
// second clause. isHDMI alone looks like the obvious test and is wrong: Sonos holds
// the TV input for HOURS after the set is switched off (playback contract §6a), so a
// guard written on isHDMI alone would put a dialog in front of every evening's
// listening. idleState is Sonos's own "nothing is coming out of this room" flag and is
// the only thing that tells a live TV from a held-but-silent input.

final class TVTakeoverTests: XCTestCase {

    private func zone(name: String = "Living Room",
                      hdmi: Bool,
                      idle: Bool,
                      playing: Bool = true) -> SonosZone {
        var z = SonosZone(id: "RINCON_TEST", name: name, host: "10.0.0.9",
                          isPlaying: playing, volume: 20)
        z.isHDMI = hdmi
        z.idleState = idle
        return z
    }

    func testTVMakingSoundWarns() {
        XCTAssertTrue(TVTakeover.isActive(zone(hdmi: true, idle: false)),
                      "a zone on its TV input with audio flowing is the case this exists for")
    }

    func testInputHeldButSilentDoesNotWarn() {
        XCTAssertFalse(TVTakeover.isActive(zone(hdmi: true, idle: true)),
                       "the TV input sticks for hours after the set is off — warning here would cry wolf")
    }

    func testZonePlayingMusicDoesNotWarn() {
        XCTAssertFalse(TVTakeover.isActive(zone(hdmi: false, idle: false)),
                       "interrupting music is ordinary and must not prompt")
    }

    func testIdleZoneDoesNotWarn() {
        XCTAssertFalse(TVTakeover.isActive(zone(hdmi: false, idle: true, playing: false)))
    }

    // The transport's own isPlaying is deliberately NOT part of the predicate: an HDMI
    // zone reports PLAYING whether the television is on or off, so it carries no signal
    // here. Asserting it keeps a future "simplification" from adding it back.
    func testTransportPlayingIsNotPartOfTheTest() {
        XCTAssertTrue(TVTakeover.isActive(zone(hdmi: true, idle: false, playing: false)))
        XCTAssertFalse(TVTakeover.isActive(zone(hdmi: true, idle: true, playing: true)))
    }

    // MARK: - Starting volume

    // A fresh UserDefaults per test — the real suite must never be written by a test run.
    private func emptyDefaults(_ name: String = #function) -> UserDefaults {
        let d = UserDefaults(suiteName: "tvtakeover.\(name)")!
        d.removePersistentDomain(forName: "tvtakeover.\(name)")
        return d
    }

    func testDefaultsToSevenWithNothingStored() {
        XCTAssertEqual(TVTakeover.startingVolume(for: zone(hdmi: true, idle: false),
                                                 defaults: emptyDefaults()), 7,
                       "a fresh install gets the behaviour without visiting Settings")
    }

    func testAppliesEvenWhenTheTVIsSilent() {
        // Deliberately WIDER than isActive. An input held since a film that finished an
        // hour ago has left the television's level behind just the same.
        XCTAssertEqual(TVTakeover.startingVolume(for: zone(hdmi: true, idle: true),
                                                 defaults: emptyDefaults()), 7)
    }

    func testLeavesNonTVRoomsAlone() {
        XCTAssertNil(TVTakeover.startingVolume(for: zone(hdmi: false, idle: false),
                                               defaults: emptyDefaults()),
                     "a room already playing music keeps whatever volume it is at")
    }

    func testTurningTheSettingOffLeavesTheVolumeAlone() {
        let d = emptyDefaults()
        d.set(false, forKey: TVTakeover.volumeEnabledKey)
        XCTAssertNil(TVTakeover.startingVolume(for: zone(hdmi: true, idle: false), defaults: d))
    }

    func testStoredLevelIsUsed() {
        let d = emptyDefaults()
        d.set(14, forKey: TVTakeover.volumeLevelKey)
        XCTAssertEqual(TVTakeover.startingVolume(for: zone(hdmi: true, idle: false), defaults: d), 14)
    }

    func testStoredLevelIsClampedToTheRange() {
        let low = emptyDefaults("low")
        low.set(0, forKey: TVTakeover.volumeLevelKey)
        XCTAssertEqual(TVTakeover.startingVolume(for: zone(hdmi: true, idle: false), defaults: low), 1)

        let high = emptyDefaults("high")
        high.set(90, forKey: TVTakeover.volumeLevelKey)
        XCTAssertEqual(TVTakeover.startingVolume(for: zone(hdmi: true, idle: false), defaults: high), 30,
                       "a stored level must never send a soundbar to 90")
    }

    // bool(forKey:) returns false for an absent key, which would read as "switched off"
    // and silently disable the feature for everyone who never opened Settings.
    func testAbsentToggleIsOnNotOff() {
        let d = emptyDefaults()
        XCTAssertNil(d.object(forKey: TVTakeover.volumeEnabledKey))
        XCTAssertNotNil(TVTakeover.startingVolume(for: zone(hdmi: true, idle: false), defaults: d))
    }

    func testTitleNamesTheRoom() {
        XCTAssertEqual(TVTakeover.title(zoneName: "Living Room"),
                       "Living Room is actively playing TV audio")
    }

    func testMessageNamesTheButton() {
        XCTAssertEqual(TVTakeover.message(),
                       "Press Play to play the new audio in the zone.")
    }

    func testMultipleRoomsAreListedAndTakePluralVerb() {
        XCTAssertEqual(TVTakeover.title(zoneNames: ["Living Room", "Den"]),
                       "Living Room, Den are actively playing TV audio")
    }

    func testSingleRoomInListUsesTheSingularTitle() {
        XCTAssertEqual(TVTakeover.title(zoneNames: ["Den"]),
                       "Den is actively playing TV audio")
    }
}
