import XCTest
@testable import Sorriva

// MARK: - PlaybackReducerTests
//
// Covers `PlaybackStateReducer.reduce` — the function that decides what every zone card,
// mini player and Now Playing sheet displays.
//
// This is the highest-value place in the app to test and had no coverage at all. It is
// a pure static function: zones, contexts, declarations, last-playing, previous
// snapshots and `now` all come in as parameters, so no speaker, network or database is
// involved. Nearly every playback bug found in the field lived here, and each one below
// is written as the behaviour that was wrong, named after the defect it guards.
//
// What these tests CANNOT cover: what Sonos itself does. Phase C was built on a wrong
// assumption about grouping that no unit test would have caught — only querying the
// speakers settled it. Tests protect our logic; the hardware is the only source for its
// own behaviour.

@MainActor
final class PlaybackReducerTests: XCTestCase {

    // Fixed reference point so grace-window arithmetic is deterministic.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let iHeart = "hls-radio://http://stream.revma.ihrhls.com/zc7934/hls.m3u8"
    private let somaFM = "aac://http://ice2.somafm.com/bossa-128-aac"
    private let localURI = "x-file-cifs://AV-Server/Media/Artist/Album/01%20-%20Track.flac"

    // MARK: - Builders

    private func zone(_ id: String = "Z1",
                      name: String = "Living Room",
                      playing: Bool = true,
                      uri: String = "",
                      track: String = "",
                      artist: String = "",
                      volume: Int = 20,
                      elapsed: Int = 0,
                      duration: Int = 0,
                      idle: Bool = false) -> SonosZone {
        var z = SonosZone(id: id, name: name, host: "10.0.0.9",
                          isPlaying: playing, volume: volume)
        z.currentTrackURI = uri
        z.currentTrack = track
        z.currentArtist = artist
        z.elapsedSeconds = elapsed
        z.durationSeconds = duration
        z.idleState = idle
        return z
    }

    private func context(track: String = "", artist: String = "", album: String = "",
                         duration: Double = 0, artURL: String? = nil,
                         isLocal: Bool = false) -> PlaybackContext {
        PlaybackContext(track: track, artist: artist, albumName: album,
                        duration: duration, artAlbum: nil, artURL: artURL, isLocal: isLocal)
    }

    private func declaration(_ ctx: PlaybackContext, uri: String,
                             source: PlaybackDeclaration.Source = .app,
                             ageSeconds: TimeInterval = 0) -> PlaybackDeclaration {
        PlaybackDeclaration(context: ctx, uri: uri, source: source,
                            declaredAt: now.addingTimeInterval(-ageSeconds))
    }

    private func reduce(_ zones: [SonosZone],
                        contexts: [String: PlaybackContext] = [:],
                        declarations: [String: PlaybackDeclaration] = [:],
                        lastDeclarations: [String: PlaybackDeclaration] = [:],
                        previous: [ZonePlaybackSnapshot] = []) -> ZonePlaybackSnapshot {
        let out = PlaybackStateReducer.reduce(sonosZones: zones,
                                       contexts: contexts,
                                       declarations: declarations,
                                       lastDeclarations: lastDeclarations,
                                       previous: previous,
                                       now: now)
        return out[0]
    }

    // MARK: - Stream content: the app names the station, Sonos names the song
    // bStationTrackFrozenByDeclaration

    /// A station URI does not change while the songs do, so a declaration bound to it
    /// matched forever and pinned whatever was playing when the station started. Live
    /// repro: Sonos reporting Eurythmics then Prince while the app showed Chaka Khan.
    func testStreamFollowsLiveTrackWhileKeepingStationIdentity() {
        let z = zone(uri: iHeart, track: "Delirious", artist: "Prince")
        let declared = declaration(context(album: "Lost 80s", artURL: "logo.png"), uri: iHeart)

        let snap = reduce([z], declarations: ["Z1": declared])

        XCTAssertEqual(snap.trackTitle, "Delirious", "live track must come from Sonos")
        XCTAssertEqual(snap.artistName, "Prince")
        XCTAssertEqual(snap.albumName, "Lost 80s", "station identity must come from the app")
        XCTAssertEqual(snap.artURL, "logo.png")
    }

    /// Sonos reports an empty title between songs. Blanking there would flash on every
    /// track boundary, so the previous track is held (the no-blank rule, section 6).
    func testStreamHoldsPreviousTrackWhenSonosReportsEmptyTitle() {
        let z = zone(uri: iHeart, track: "", artist: "")
        let declared = declaration(context(album: "Lost 80s"), uri: iHeart)
        let earlier = reduce([zone(uri: iHeart, track: "Delirious", artist: "Prince")],
                             declarations: ["Z1": declared])

        let snap = reduce([z], declarations: ["Z1": declared], previous: [earlier])

        XCTAssertEqual(snap.trackTitle, "Delirious", "must hold, not blank, between songs")
        XCTAssertEqual(snap.artistName, "Prince")
        XCTAssertEqual(snap.albumName, "Lost 80s")
    }

    /// The opposite case, and the reason the fix branches on content kind: Sonos has
    /// neither the title nor the art for a NAS file, so a local declaration owns all of
    /// it. Layering zone fields on top here would corrupt a correct local track.
    func testLocalDeclarationIsNotOverwrittenByZoneFields() {
        let z = zone(uri: localURI, track: "WRONG", artist: "WRONG")
        let declared = declaration(
            context(track: "Uptown East", artist: "Special EFX",
                    album: "Collection", duration: 320, isLocal: true),
            uri: localURI)

        let snap = reduce([z], declarations: ["Z1": declared])

        XCTAssertEqual(snap.trackTitle, "Uptown East")
        XCTAssertEqual(snap.artistName, "Special EFX")
        XCTAssertTrue(snap.isLocal)
        XCTAssertEqual(snap.sourceLabel, "Local Library")
    }

    // MARK: - URI binding — the safety guarantee (section 3)

    /// Resolved metadata displays only while its URI matches what Sonos reports. Once
    /// the URI moves on and the grace window expires, the declaration is stale.
    func testDeclarationIgnoredWhenURIMovedOnAndGraceExpired() {
        let z = zone(uri: somaFM)
        let stale = declaration(context(album: "Lost 80s"), uri: iHeart, ageSeconds: 30)

        let snap = reduce([z],
                          contexts: ["Z1": context(album: "Bossa Beyond")],
                          declarations: ["Z1": stale])

        XCTAssertEqual(snap.albumName, "Bossa Beyond", "stale declaration must not display")
    }

    /// Immediately after our own command Sonos has not caught up. The grace window is
    /// what stops the card blanking between the command and the first confirming poll.
    func testAppDeclarationHonouredWithinGraceBeforeSonosCatchesUp() {
        let z = zone(uri: iHeart)
        let fresh = declaration(context(album: "Bossa Beyond"), uri: somaFM, ageSeconds: 1)

        let snap = reduce([z],
                          contexts: ["Z1": context(album: "Lost 80s")],
                          declarations: ["Z1": fresh])

        XCTAssertEqual(snap.albumName, "Bossa Beyond", "our own command holds briefly")
    }

    /// An `.external` declaration is a detection result, not a command we issued, so
    /// there is nothing to wait for and it gets no grace. This is why entries restored
    /// at launch are marked external — a memory must never outrank live state.
    func testExternalDeclarationGetsNoGracePeriod() {
        let z = zone(uri: iHeart)
        let restored = declaration(context(album: "Bossa Beyond"), uri: somaFM,
                                   source: .external, ageSeconds: 1)

        let snap = reduce([z],
                          contexts: ["Z1": context(album: "Lost 80s")],
                          declarations: ["Z1": restored])

        XCTAssertEqual(snap.albumName, "Lost 80s", "external claims never outrank polling")
    }

    // MARK: - Stopped zones — Sonos outranks our memory
    // bStoredLastPlayingOutranksResolvedContent

    /// Sonos keeps reporting the URI a stopped zone is parked on, so it can always say
    /// what a zone last played. The stored copy used to win outright and the resolved
    /// answer was computed every poll and discarded.
    func testStoppedZonePrefersResolvedContentOverStoredLastPlaying() {
        let z = zone(playing: false, uri: iHeart)
        let remembered = declaration(context(album: "Bossa Beyond"), uri: somaFM,
                                     ageSeconds: 3600)

        let snap = reduce([z],
                          contexts: ["Z1": context(album: "Lost 80s")],
                          lastDeclarations: ["Z1": remembered])

        XCTAssertEqual(snap.albumName, "Lost 80s", "the speaker's answer wins")
    }

    /// Matters most for content started in the Sonos app, which the store has no record
    /// of at all: it showed correctly while playing, then reverted on stop.
    func testStoppedZoneShowsExternallyStartedContentRatherThanOurOwnMemory() {
        let z = zone(playing: false, uri: somaFM)
        let ourOldMemory = declaration(context(album: "Lost 80s"), uri: iHeart,
                                       ageSeconds: 7200)

        let snap = reduce([z],
                          contexts: ["Z1": context(album: "Bossa Beyond")],
                          lastDeclarations: ["Z1": ourOldMemory])

        XCTAssertEqual(snap.albumName, "Bossa Beyond")
    }

    /// The one job the stored copy still does: a zone Sonos cannot describe, such as a
    /// speaker back from a power cut with an empty transport.
    func testStoppedZoneFallsBackToLastPlayingWhenNothingResolved() {
        let z = zone(playing: false, uri: "")
        let remembered = declaration(context(track: "Juno", album: "Groove Salad"),
                                     uri: somaFM, ageSeconds: 3600)

        let snap = reduce([z], lastDeclarations: ["Z1": remembered])

        XCTAssertEqual(snap.albumName, "Groove Salad")
        XCTAssertEqual(snap.trackTitle, "Juno")
    }

    /// Guards the Phase C decision, which was closed as a negative result: a grouped
    /// member never receives the stream and Sonos restores its own queue on separation,
    /// so what it reports is what will actually play. Showing the group's content would
    /// describe something the speaker will not do.
    func testSeparatedZoneShowsItsOwnRestoredContentNotTheGroups() {
        let separated = zone("Garage", name: "Garage", playing: false, uri: iHeart)
        let groupContent = declaration(context(album: "Bossa Beyond"), uri: somaFM,
                                       ageSeconds: 5)

        let snap = reduce([separated],
                          contexts: ["Garage": context(album: "Lost 80s")],
                          lastDeclarations: ["Garage": groupContent])

        XCTAssertEqual(snap.albumName, "Lost 80s", "its own restored queue, not the group's")
    }

    // MARK: - No-blank rule (section 6)

    /// An actively-playing zone never renders empty content.
    func testPlayingZoneWithNothingResolvedHoldsPreviousContent() {
        let earlier = reduce([zone(uri: iHeart, track: "Delirious", artist: "Prince")],
                             contexts: ["Z1": context(track: "Delirious", artist: "Prince",
                                                      album: "Lost 80s")])
        let z = zone(uri: iHeart)

        let snap = reduce([z], previous: [earlier])

        XCTAssertEqual(snap.albumName, "Lost 80s")
        XCTAssertEqual(snap.trackTitle, "Delirious")
    }

    /// A zone that has genuinely never played anything renders empty rather than
    /// inventing content — the no-blank rule holds a last-known value, it does not
    /// fabricate one.
    func testZoneWithNoHistoryAtAllRendersEmpty() {
        let snap = reduce([zone(playing: false)])

        XCTAssertEqual(snap.trackTitle, "")
        XCTAssertEqual(snap.albumName, "")
        XCTAssertFalse(snap.isLocal)
    }

    // MARK: - Transport and duration

    /// Transport is Sonos's to own and passes through untouched.
    func testTransportFieldsComeFromSonosUnchanged() {
        let z = zone(uri: iHeart, volume: 42, elapsed: 75, duration: 0, idle: false)

        let snap = reduce([z], contexts: ["Z1": context(album: "Lost 80s")])

        XCTAssertTrue(snap.isPlaying)
        XCTAssertEqual(snap.volume, 42)
        XCTAssertEqual(snap.elapsedSeconds, 75)
        XCTAssertTrue(snap.isAvailable)
    }

    /// A live stream has no duration. Sonos reports zero and that is correct.
    func testStreamDurationAlwaysComesFromSonos() {
        let z = zone(uri: iHeart, duration: 0)

        let snap = reduce([z], contexts: ["Z1": context(album: "Lost 80s", duration: 999)])

        XCTAssertEqual(snap.durationSeconds, 0, "a stream has no total time")
    }

    /// bAiffDurationNotParsed fallback: a file the scanner could not measure still shows
    /// a total time, because Sonos reads the file itself.
    func testLocalDurationFallsBackToSonosWhenScannerFoundNone() {
        let z = zone(uri: localURI, duration: 284)
        let declared = declaration(context(track: "Track", album: "Album",
                                           duration: 0, isLocal: true), uri: localURI)

        let snap = reduce([z], declarations: ["Z1": declared])

        XCTAssertEqual(snap.durationSeconds, 284, "Sonos fills the gap the scanner left")
    }

    /// When the scanner did measure it, the scanned value is preferred.
    func testLocalDurationPrefersScannedValue() {
        let z = zone(uri: localURI, duration: 999)
        let declared = declaration(context(track: "Track", album: "Album",
                                           duration: 320, isLocal: true), uri: localURI)

        let snap = reduce([z], declarations: ["Z1": declared])

        XCTAssertEqual(snap.durationSeconds, 320)
    }

    // MARK: - Transport optimism
    // Replaces SonosZone.playingUntil. The app claims a zone's transport for a short
    // window after issuing a command, so the card does not flash idle while Sonos catches
    // up. Distinct from a content declaration: pausing changes transport and claims
    // nothing about content.

    private func intent(_ playing: Bool, ageSeconds: TimeInterval = 0) -> TransportIntent {
        TransportIntent(isPlaying: playing, declaredAt: now.addingTimeInterval(-ageSeconds))
    }

    private func reduceT(_ zones: [SonosZone],
                         intents: [String: TransportIntent],
                         contexts: [String: PlaybackContext] = [:],
                         previous: [ZonePlaybackSnapshot] = []) -> ZonePlaybackSnapshot {
        PlaybackStateReducer.reduce(sonosZones: zones, contexts: contexts,
                                    transportIntents: intents, previous: previous, now: now)[0]
    }

    /// The window exists so a zone doesn't read as idle between our command and Sonos
    /// confirming it — the transport equivalent of the declaration grace.
    func testFreshPlayIntentHoldsZonePlayingWhileSonosStillSaysStopped() {
        let z = zone(playing: false, uri: iHeart)

        let snap = reduceT([z], intents: ["Z1": intent(true, ageSeconds: 1)],
                           contexts: ["Z1": context(album: "Lost 80s")])

        XCTAssertTrue(snap.isPlaying, "our own command holds until Sonos catches up")
    }

    /// Optimism is bounded. Past the window Sonos wins, or a command that silently failed
    /// would leave a zone permanently claiming to play.
    func testExpiredPlayIntentYieldsToSonos() {
        let z = zone(playing: false, uri: iHeart)

        let snap = reduceT([z], intents: ["Z1": intent(true, ageSeconds: 30)],
                           contexts: ["Z1": context(album: "Lost 80s")])

        XCTAssertFalse(snap.isPlaying, "expired optimism must not outlive the truth")
    }

    /// Pause is the case that cannot be folded into a content declaration — it changes
    /// transport and says nothing about what is loaded.
    func testFreshPauseIntentHoldsZoneStoppedWhileSonosStillSaysPlaying() {
        let z = zone(playing: true, uri: iHeart)

        let snap = reduceT([z], intents: ["Z1": intent(false, ageSeconds: 1)],
                           contexts: ["Z1": context(album: "Lost 80s")])

        XCTAssertFalse(snap.isPlaying, "a pause we issued holds too, not just a play")
    }

    /// No claim means no interference: Sonos's value passes through untouched.
    func testNoIntentLeavesSonosTransportUntouched() {
        let playing = reduceT([zone(playing: true, uri: iHeart)], intents: [:],
                              contexts: ["Z1": context(album: "Lost 80s")])
        let stopped = reduceT([zone(playing: false, uri: iHeart)], intents: [:],
                              contexts: ["Z1": context(album: "Lost 80s")])

        XCTAssertTrue(playing.isPlaying)
        XCTAssertFalse(stopped.isPlaying)
    }

    /// Intents are per zone — one zone's command must not move another.
    func testTransportIntentDoesNotLeakBetweenZones() {
        let a = zone("A", name: "Patio", playing: false, uri: somaFM)
        let b = zone("B", name: "Master Bedroom", playing: false, uri: iHeart)

        let out = PlaybackStateReducer.reduce(
            sonosZones: [a, b],
            contexts: ["A": context(album: "Bossa Beyond"), "B": context(album: "Lost 80s")],
            transportIntents: ["A": intent(true, ageSeconds: 1)],
            now: now)

        XCTAssertTrue(out.first(where: { $0.id == "A" })!.isPlaying)
        XCTAssertFalse(out.first(where: { $0.id == "B" })!.isPlaying, "B made no claim")
    }

    // MARK: - Isolation

    /// Zones must not borrow each other's content. Two zones on the same station with
    /// different declarations is the shape that produced two cards disagreeing.
    func testZonesResolveIndependently() {
        let a = zone("A", name: "Patio", uri: somaFM)
        let b = zone("B", name: "Master Bedroom", uri: iHeart)

        let out = PlaybackStateReducer.reduce(
            sonosZones: [a, b],
            contexts: ["A": context(album: "Bossa Beyond"),
                       "B": context(album: "Lost 80s")],
            now: now)

        XCTAssertEqual(out.first(where: { $0.id == "A" })?.albumName, "Bossa Beyond")
        XCTAssertEqual(out.first(where: { $0.id == "B" })?.albumName, "Lost 80s")
    }
}
