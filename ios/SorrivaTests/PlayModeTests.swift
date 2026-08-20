import XCTest
#if SWIFT_PACKAGE
// Compiled into the FastTests target directly, so there is no module to import.
#else
@testable import Sorriva
#endif

// MARK: - PlayModeTests
//
// The mapping between Sorriva's two switches and Sonos's one six-valued field.
//
// This is worth testing precisely because it looks trivial. Sonos's `SHUFFLE` means
// shuffle + repeat-ALL, not shuffle alone — so the one-line mistake anybody would make
// is wiring shuffle-with-no-repeat to `SHUFFLE`, which silently turns on repeat as well.
// A round-trip test catches that class of error without a speaker.
//
// Values verified against the speaker's own /xml/AVTransport1.xml on 2026-08-19; see
// server/static/docs/engineering/sonos-playback-contract.md §14.

final class PlayModeTests: XCTestCase {

    // MARK: - Two switches → one Sonos value

    func testEveryCombinationMapsToTheDocumentedSonosValue() {
        XCTAssertEqual(PlayMode(shuffle: false, repeatMode: .off), .normal)
        XCTAssertEqual(PlayMode(shuffle: false, repeatMode: .all), .repeatAll)
        XCTAssertEqual(PlayMode(shuffle: false, repeatMode: .one), .repeatOne)
        XCTAssertEqual(PlayMode(shuffle: true,  repeatMode: .off), .shuffleNoRepeat)
        XCTAssertEqual(PlayMode(shuffle: true,  repeatMode: .all), .shuffleRepeatAll)
        XCTAssertEqual(PlayMode(shuffle: true,  repeatMode: .one), .shuffleRepeatOne)
    }

    /// The specific trap. `SHUFFLE` is shuffle + repeat-all; shuffle alone is
    /// `SHUFFLE_NOREPEAT`. Wiring these the obvious way round turns on repeat when the
    /// user only asked for shuffle, and nothing in the UI would reveal it.
    func testShuffleWithoutRepeatIsNotTheValueCalledSHUFFLE() {
        XCTAssertEqual(PlayMode(shuffle: true, repeatMode: .off).rawValue, "SHUFFLE_NOREPEAT")
        XCTAssertEqual(PlayMode(shuffle: true, repeatMode: .all).rawValue, "SHUFFLE")
    }

    // MARK: - One Sonos value → two switches

    func testEveryModeRoundTripsBackToTheSwitchesThatBuiltIt() {
        for shuffle in [true, false] {
            for repeatMode in PlayMode.Repeat.allCases {
                let mode = PlayMode(shuffle: shuffle, repeatMode: repeatMode)
                XCTAssertEqual(mode.isShuffled, shuffle,
                               "\(mode.rawValue) should report shuffle=\(shuffle)")
                XCTAssertEqual(mode.repeatMode, repeatMode,
                               "\(mode.rawValue) should report repeat=\(repeatMode)")
            }
        }
    }

    func testAllSixSonosValuesAreCovered() {
        // If Sonos ever grows a seventh, this fails rather than silently mapping it away.
        XCTAssertEqual(PlayMode.allCases.count, 6)
        let built = Set([true, false].flatMap { shuffle in
            PlayMode.Repeat.allCases.map { PlayMode(shuffle: shuffle, repeatMode: $0) }
        })
        XCTAssertEqual(built, Set(PlayMode.allCases),
                       "the two switches must be able to express every Sonos value")
    }

    // MARK: - Parsing what the speaker reported

    func testParsesEveryValueTheSpeakerCanReport() {
        for mode in PlayMode.allCases {
            XCTAssertEqual(PlayMode(reported: mode.rawValue), mode)
        }
    }

    func testToleratesSurroundingWhitespaceFromTheXML() {
        XCTAssertEqual(PlayMode(reported: "  SHUFFLE\n"), .shuffleRepeatAll)
    }

    /// An unknown mode falls back to `.normal` rather than being trusted. Drawing
    /// shuffle as ON is a claim about the speaker; when the answer is unreadable, the
    /// honest default is the one that claims nothing.
    func testUnknownValueFallsBackToNormalRatherThanClaimingShuffle() {
        XCTAssertEqual(PlayMode(reported: ""), .normal)
        XCTAssertEqual(PlayMode(reported: "REPEAT_TWICE"), .normal)
        XCTAssertFalse(PlayMode(reported: "garbage").isShuffled)
    }

    // MARK: - The UI's repeat cycle

    func testRepeatCyclesOffAllOneAndBackToOff() {
        XCTAssertEqual(PlayMode.Repeat.off.next, .all)
        XCTAssertEqual(PlayMode.Repeat.all.next, .one)
        XCTAssertEqual(PlayMode.Repeat.one.next, .off)
    }

    func testThreeTapsOnRepeatReturnsToWhereItStarted() {
        var mode = PlayMode.Repeat.off
        for _ in 0..<3 { mode = mode.next }
        XCTAssertEqual(mode, .off)
    }
}
