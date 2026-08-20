import XCTest
#if SWIFT_PACKAGE
// Compiled into the FastTests target directly, so there is no module to import.
#else
@testable import Sorriva
#endif

// MARK: - SonosCommandTests
//
// What Sorriva actually puts on the wire, asserted without a speaker.
//
// These became possible on 2026-08-09 when the sixteen hand-built URLRequests
// collapsed into SonosSOAP and SonosCommands.soap became injectable. Before that
// the only way to know what a command sent was to send it and watch a speaker.
//
// WHAT THESE COVER: one command at a time — the right action name, against the
// right service endpoint, carrying the right elements, with a sane timeout.
//
// WHAT THEY DO NOT COVER: SEQUENCES, which is where the expensive knowledge lives
// (sonos-playback-contract.md §3 — Stop, clear the queue, add one at a time, point
// at the queue, Play, then verify). That orchestration is in LocalPlaybackService,
// which pulls in SMBClient and the database, so it cannot run here. Those tests
// belong in the hosted suite and do not exist yet.

/// Records what would have been sent. Also the shape a sequence test would use —
/// `actions` is an ordered log, so asserting a sequence is asserting a list.
final class RecordingSOAPTransport: SonosSOAPTransport, @unchecked Sendable {

    struct Sent {
        let host: String
        let service: SonosService
        let action: String
        let innerXML: String
        let timeout: TimeInterval
    }

    private let lock = NSLock()
    private var _sent: [Sent] = []

    var sent: [Sent] { lock.lock(); defer { lock.unlock() }; return _sent }
    var actions: [String] { sent.map(\.action) }
    var last: Sent? { sent.last }

    /// The most recent send for a given action.
    ///
    /// Tests must use THIS rather than `last`. Under the hosted suite these tests run
    /// inside the running app, where ZoneDiscoveryService is polling real speakers
    /// through this same injected transport — 26 sends were recorded during a test
    /// that issued 8. Anything asserting on "the last thing sent" is racing the poll
    /// loop. The fast suite cannot reveal this, because no app is running there.
    func lastSend(_ action: String) -> Sent? { sent.last { $0.action == action } }

    /// Handed back to every caller. 200 with an empty body is the shape of a
    /// successful Sonos command — they carry no useful payload.
    var stubbedStatus = 200
    var stubbedBody = Data()

    func send(host: String, service: SonosService, action: String,
              innerXML: String, timeout: TimeInterval) async throws -> SonosSOAPResponse {
        lock.lock()
        _sent.append(Sent(host: host, service: service, action: action,
                          innerXML: innerXML, timeout: timeout))
        lock.unlock()
        return SonosSOAPResponse(status: stubbedStatus, body: stubbedBody)
    }
}

final class SonosCommandTests: XCTestCase {

    private var fake: RecordingSOAPTransport!
    private var realTransport: SonosSOAPTransport!

    override func setUp() {
        super.setUp()
        realTransport = SonosCommands.soap
        fake = RecordingSOAPTransport()
        SonosCommands.soap = fake
    }

    override func tearDown() {
        SonosCommands.soap = realTransport
        super.tearDown()
    }

    // MARK: - Endpoints
    //
    // Service and namespace are paired: send a ContentDirectory action to the
    // AVTransport endpoint and the speaker answers 500. Nothing in the type system
    // stops that pairing being wrong, so it is asserted here instead.

    func testTransportActionsGoToAVTransport() async {
        await SonosCommands.sendTransportAction(host: "10.0.0.9", action: "Play")
        XCTAssertEqual(fake.lastSend("Play")?.action, "Play")
        XCTAssertEqual(fake.lastSend("Play")?.service, .avTransport)
        XCTAssertEqual(fake.lastSend("Play")?.host, "10.0.0.9")
    }

    func testShareRegistrationGoesToContentDirectoryNotAVTransport() async {
        await SonosCommands.createObject(host: "10.0.0.9", nasPath: "//av-server/media/Music II")
        XCTAssertEqual(fake.lastSend("CreateObject")?.action, "CreateObject")
        XCTAssertEqual(fake.lastSend("CreateObject")?.service, .contentDirectory,
                       "CreateObject is a ContentDirectory action — sending it to AVTransport returns 500")
    }

    func testVolumeGoesToRenderingControlOnTheMasterChannel() async {
        await SonosCommands.sendSetVolume(host: "10.0.0.9", volume: 14)
        XCTAssertEqual(fake.lastSend("SetVolume")?.service, .renderingControl)
        XCTAssertEqual(fake.lastSend("SetVolume")?.action, "SetVolume")
        XCTAssertTrue(fake.lastSend("SetVolume")!.innerXML.contains("<Channel>Master</Channel>"))
        XCTAssertTrue(fake.lastSend("SetVolume")!.innerXML.contains("<DesiredVolume>14</DesiredVolume>"))
    }

    // MARK: - Queue path
    //
    // sonos-playback-contract.md §3. Local files play via the queue and never by
    // pointing SetAVTransportURI at the file.

    func testQueuedURIIsCarriedInEnqueuedURI() async {
        await SonosCommands.addURIToQueue(host: "10.0.0.9",
                                          uri: "x-file-cifs://av-server/media/Music II/a/b/01 Track.flac")
        XCTAssertEqual(fake.lastSend("AddURIToQueue")?.action, "AddURIToQueue")
        XCTAssertTrue(fake.lastSend("AddURIToQueue")!.innerXML.contains("<EnqueuedURI>x-file-cifs://"))
        XCTAssertTrue(fake.lastSend("AddURIToQueue")!.innerXML.contains("01 Track.flac"),
                      "spaces are legal in x-file-cifs and must not be encoded away")
    }

    /// An unescaped ampersand breaks the XML envelope, so the speaker rejects the
    /// whole command rather than the one track. Real libraries are full of them —
    /// "Simon & Garfunkel", "AC/DC & Friends".
    func testAmpersandInAURIIsEscapedForXML() async {
        await SonosCommands.addURIToQueue(host: "10.0.0.9",
                                          uri: "x-file-cifs://nas/media/Simon & Garfunkel/01.flac")
        let xml = fake.lastSend("AddURIToQueue")!.innerXML
        XCTAssertTrue(xml.contains("Simon &amp; Garfunkel"), "got: \(xml)")
        XCTAssertFalse(xml.contains("Simon & Garfunkel"), "a bare & terminates the envelope early")
    }

    func testClearingTheQueueTargetsTheRightAction() async {
        await SonosCommands.removeAllTracksFromQueue(host: "10.0.0.9")
        XCTAssertEqual(fake.lastSend("RemoveAllTracksFromQueue")?.action, "RemoveAllTracksFromQueue")
        XCTAssertEqual(fake.lastSend("RemoveAllTracksFromQueue")?.service, .avTransport)
    }

    // MARK: - Shuffle and repeat
    //
    // Sonos keeps play mode as sticky speaker state: measured 2026-08-19, SHUFFLE
    // survives RemoveAllTracksFromQueue untouched. Sorriva's rule is that shuffle and
    // repeat last only for the queue they were set for, so the clear has to reset it —
    // and the clear is the one place every load path passes through. Contract §14.

    func testClearingTheQueueAlsoResetsShuffleAndRepeat() async {
        await SonosCommands.removeAllTracksFromQueue(host: "10.0.0.9")
        let reset = fake.lastSend("SetPlayMode")
        XCTAssertNotNil(reset, "clearing the queue must normalise the mode, or shuffling "
                             + "one album silently shuffles whatever is played next")
        XCTAssertTrue(reset!.innerXML.contains("<NewPlayMode>NORMAL</NewPlayMode>"),
                      "got: \(reset!.innerXML)")
    }

    /// Order matters and is not cosmetic: a mode set BEFORE the clear would be wiped by
    /// nothing, but the assertion that matters is the reverse — NORMAL is the only value
    /// Sonos accepts while the queue is empty, so the reset has to follow the clear
    /// rather than race it.
    func testTheResetFollowsTheClearRatherThanPrecedingIt() async {
        await SonosCommands.removeAllTracksFromQueue(host: "10.0.0.9")
        let clearIdx = fake.actions.firstIndex(of: "RemoveAllTracksFromQueue")
        let modeIdx  = fake.actions.firstIndex(of: "SetPlayMode")
        XCTAssertNotNil(clearIdx)
        XCTAssertNotNil(modeIdx)
        XCTAssertLessThan(clearIdx!, modeIdx!)
    }

    func testSetPlayModeCarriesTheSonosValueNotSorrivasTwoSwitches() async {
        await SonosCommands.setPlayMode(host: "10.0.0.9", mode: .shuffleNoRepeat)
        let sent = fake.lastSend("SetPlayMode")!
        XCTAssertEqual(sent.service, .avTransport)
        XCTAssertTrue(sent.innerXML.contains("<NewPlayMode>SHUFFLE_NOREPEAT</NewPlayMode>"),
                      "got: \(sent.innerXML)")
    }

    func testReadingPlayModeUsesGetTransportSettings() async {
        _ = await SonosCommands.playMode(host: "10.0.0.9")
        XCTAssertEqual(fake.lastSend("GetTransportSettings")?.service, .avTransport)
    }

    func testPointingAtTheQueueUsesSetAVTransportURI() async {
        await SonosCommands.setAVTransportURIWithMetadata(
            host: "10.0.0.9", streamURL: "x-rincon-queue:RINCON_ABC123#0", didl: "")
        XCTAssertEqual(fake.lastSend("SetAVTransportURI")?.action, "SetAVTransportURI")
        XCTAssertTrue(fake.lastSend("SetAVTransportURI")!.innerXML.contains("x-rincon-queue:RINCON_ABC123#0"))
    }

    // MARK: - Metadata escaping
    //
    // The bug this guards was invisible for months because every caller passed an empty
    // DIDL. The first real content — a Sonos favorite's resMD — broke the envelope and
    // SiriusXM silently would not play, while the tools script that escaped the same
    // string worked. Found 2026-08-12.

    private var sampleDIDL: String {
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"
        + "<item id=\"1\"><dc:title>CH 8 - 80s on 8</dc:title>"
        + "<desc id=\"cdudn\">SA_RINCON9479_X_#Svc9479-db2b2c51-Token</desc></item></DIDL-Lite>"
    }

    func testMetadataIsEscapedBeforeItEntersTheEnvelope() async {
        await SonosCommands.setAVTransportURIWithMetadata(
            host: "10.0.0.9", streamURL: "x-sonosapi-stream:foo?sid=37", didl: sampleDIDL)
        let xml = fake.lastSend("SetAVTransportURI")!.innerXML
        XCTAssertTrue(xml.contains("&lt;DIDL-Lite"),
                      "raw XML inside CurrentURIMetaData breaks the envelope — the speaker rejects it")
        XCTAssertFalse(xml.contains("<DIDL-Lite"),
                       "metadata went in unescaped")
        XCTAssertTrue(xml.contains("SA_RINCON9479"), "the service token must survive escaping")
    }

    func testQueuedMetadataIsEscapedToo() async {
        await SonosCommands.addURIToQueue(
            host: "10.0.0.9", uri: "x-rincon-cpcontainer:abc", didl: sampleDIDL)
        let xml = fake.lastSend("AddURIToQueue")!.innerXML
        XCTAssertTrue(xml.contains("&lt;DIDL-Lite"))
        XCTAssertFalse(xml.contains("<DIDL-Lite"))
    }

    /// setAVTransportURI builds its OWN DIDL already escaped. Running that through the
    /// escaper too would double-encode it and the speaker would see literal "&lt;".
    func testSelfBuiltMetadataIsNotDoubleEscaped() async {
        await SonosCommands.setAVTransportURI(
            host: "10.0.0.9", streamURL: "http://example.com/s", stationName: "Jazz & Blues")
        let xml = fake.lastSend("SetAVTransportURI")!.innerXML
        XCTAssertTrue(xml.contains("&lt;DIDL-Lite"), "expected the pre-escaped form")
        XCTAssertFalse(xml.contains("&amp;lt;"), "double-encoded — the speaker sees literal markup")
    }

    // MARK: - Grouping
    //
    // §6. A member joins by being told to point at the coordinator, and the command
    // goes to the MEMBER — sending it to the coordinator does nothing.

    func testJoiningAGroupAddressesTheMemberNotTheCoordinator() async {
        await SonosCommands.addMember(coordinatorHost: "10.0.0.1",
                                      memberHost: "10.0.0.2",
                                      memberUUID: "RINCON_COORD")
        XCTAssertEqual(fake.lastSend("SetAVTransportURI")?.host, "10.0.0.2",
                       "the join is sent to the member; the coordinator is named in the URI")
        XCTAssertTrue(fake.lastSend("SetAVTransportURI")!.innerXML.contains("x-rincon:RINCON_COORD"))
    }

    func testLeavingAGroupUsesBecomeCoordinator() async {
        await SonosCommands.becomeCoordinator(host: "10.0.0.2")
        XCTAssertEqual(fake.lastSend("BecomeCoordinatorOfStandaloneGroup")?.action, "BecomeCoordinatorOfStandaloneGroup")
        XCTAssertEqual(fake.lastSend("BecomeCoordinatorOfStandaloneGroup")?.host, "10.0.0.2")
    }

    // MARK: - Timeouts
    //
    // Regression guard for the defect that motivated SonosSOAP: addURIToQueue and
    // createObject carried NO timeoutInterval, so they inherited URLSession's
    // 60-second default. Both sit on the local-file path, so an unreachable speaker
    // froze the start of an album for a full minute. This asserts the property
    // rather than those two cases, so a seventeenth command cannot reintroduce it.

    func testNoCommandCanHangOnTheDefaultTimeout() async {
        await SonosCommands.sendTransportAction(host: "h", action: "Play")
        await SonosCommands.removeAllTracksFromQueue(host: "h")
        await SonosCommands.addURIToQueue(host: "h", uri: "x-file-cifs://nas/a.flac")
        await SonosCommands.createObject(host: "h", nasPath: "//nas/media")
        await SonosCommands.setAVTransportURIWithMetadata(host: "h", streamURL: "x-rincon-queue:R#0", didl: "")
        await SonosCommands.sendSetVolume(host: "h", volume: 10)
        await SonosCommands.becomeCoordinator(host: "h")
        await SonosCommands.addMember(coordinatorHost: "h", memberHost: "m", memberUUID: "R")

        // Deliberately NOT an equality check on the count. In the hosted suite the app's
        // own poll loop is sending through this transport too, so the total is whatever
        // the app happened to do meanwhile. Asserting the PROPERTY over everything
        // recorded is both immune to that and strictly stronger — the app's own commands
        // get checked as well.
        for expected in ["Play", "RemoveAllTracksFromQueue", "AddURIToQueue", "CreateObject",
                         "SetAVTransportURI", "SetVolume", "BecomeCoordinatorOfStandaloneGroup"] {
            XCTAssertNotNil(fake.lastSend(expected), "\(expected) never reached the transport")
        }
        for s in fake.sent {
            XCTAssertLessThanOrEqual(s.timeout, SonosTimeout.bulk,
                                     "\(s.action) would wait \(s.timeout)s — the URLSession default is 60")
            XCTAssertGreaterThan(s.timeout, 0, "\(s.action) has no timeout at all")
        }
    }

    /// A read that has to come back before the UI can show anything gets the short
    /// timeout; work the speaker has to perform gets longer.
    func testReadsAreQuickerThanActions() async {
        await SonosCommands.sendTransportAction(host: "h", action: "Play")
        let play = fake.last!.timeout
        await SonosCommands.addURIToQueue(host: "h", uri: "x-file-cifs://nas/a.flac")
        let enqueue = fake.last!.timeout
        XCTAssertLessThanOrEqual(play, enqueue)
    }
}
