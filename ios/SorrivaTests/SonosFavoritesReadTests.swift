import XCTest
#if SWIFT_PACKAGE
// Compiled into the FastTests target directly, so there is no module to import.
#else
@testable import Sorriva
#endif

// MARK: - SonosFavoritesReadTests
//
// Reading favorites without a Sonos system, by standing a fake speaker behind the
// SonosSOAP seam and feeding it a REAL captured Browse response.
//
// WHAT THESE COVER: the decision logic around the read — which host answers, how a
// silent system is told apart from an empty one, and that a refusing speaker does not
// end the search. That last one is why this file exists: on 2026-08-10 a single zone
// returned 500 to every ContentDirectory action while its neighbours answered
// normally, and believing it produced the conclusion that favorites were unreachable.
//
// WHAT THESE CANNOT COVER, and it must not be forgotten: whether SONOS ACCEPTS WHAT WE
// SEND. A fake transport returns 200 for anything. The bug that stopped SiriusXM
// playing on 2026-08-12 was metadata going onto the wire unescaped — a stub would have
// accepted it happily, exactly as tools/sonos.py did. UI and playback verification
// still need a real speaker.

/// A speaker that answers only for the hosts it is told to, so a test can express
/// "this one refuses, that one answers".
private final class StubSpeaker: SonosSOAPTransport, @unchecked Sendable {
    let answering: Set<String>
    let body: Data
    private let lock = NSLock()
    private var _asked: [String] = []
    var asked: [String] { lock.lock(); defer { lock.unlock() }; return _asked }

    init(answering: Set<String>, body: Data) {
        self.answering = answering
        self.body = body
    }

    func send(host: String, service: SonosService, action: String,
              innerXML: String, timeout: TimeInterval) async throws -> SonosSOAPResponse {
        lock.lock(); _asked.append("\(host)/\(action)"); lock.unlock()
        guard answering.contains(host) else {
            return SonosSOAPResponse(status: 500, body: Data())
        }
        if action == "GetHouseholdID" {
            let xml = "<CurrentHouseholdID>Sonos_test_household</CurrentHouseholdID>"
            return SonosSOAPResponse(status: 200, body: Data(xml.utf8))
        }
        return SonosSOAPResponse(status: 200, body: body)
    }
}

final class SonosFavoritesReadTests: XCTestCase {

    private var real: SonosSOAPTransport!

    override func setUp() {
        super.setUp()
        real = SonosCommands.soap
    }

    override func tearDown() {
        SonosCommands.soap = real
        super.tearDown()
    }

    private func fixtureData() throws -> Data {
        if let url = Bundle(for: type(of: self)).url(forResource: "favorites_fv2", withExtension: "xml") {
            return try Data(contentsOf: url)
        }
        let here = URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        return try Data(contentsOf: here.appendingPathComponent("Fixtures/favorites_fv2.xml"))
    }

    func testReadReturnsFavoritesAndHouseholdFromTheAnsweringSpeaker() async throws {
        SonosCommands.soap = StubSpeaker(answering: ["10.0.0.1"], body: try fixtureData())

        switch await SonosFavorites.read(hosts: ["10.0.0.1"]) {
        case .noSpeakerAnswered:
            XCTFail("a speaker answered but the read reported none")
        case .ok(let favorites, let household):
            XCTAssertEqual(favorites.count, 12, "the fixture holds 12 playable favorites")
            XCTAssertEqual(household, "Sonos_test_household")
        }
    }

    /// THE ONE THAT MATTERS. A speaker that refuses ContentDirectory must not end the
    /// search — measured 2026-08-10, one zone 500s while others on the same household
    /// answer normally.
    func testARefusingSpeakerDoesNotEndTheSearch() async throws {
        let stub = StubSpeaker(answering: ["10.0.0.9"], body: try fixtureData())
        SonosCommands.soap = stub

        switch await SonosFavorites.read(hosts: ["10.0.0.1", "10.0.0.5", "10.0.0.9"]) {
        case .noSpeakerAnswered:
            XCTFail("gave up on the first refusal instead of trying the others")
        case .ok(let favorites, _):
            XCTAssertEqual(favorites.count, 12)
            XCTAssertTrue(stub.asked.contains { $0.hasPrefix("10.0.0.1/") },
                          "the refusing speaker should still have been tried first")
        }
    }

    /// Silence and emptiness are different answers. Telling someone to go save favorites
    /// they already have is the worse of the two mistakes, so the caller must be able to
    /// tell them apart.
    func testNoSpeakerAnsweringIsDistinctFromAnEmptyHousehold() async throws {
        SonosCommands.soap = StubSpeaker(answering: [], body: try fixtureData())
        switch await SonosFavorites.read(hosts: ["10.0.0.1", "10.0.0.2"]) {
        case .noSpeakerAnswered: break   // correct
        case .ok: XCTFail("no speaker answered, yet the read reported success")
        }

        // A household that answers but has nothing saved is a real, reportable state.
        let emptyResult = "<Result></Result>"
        SonosCommands.soap = StubSpeaker(answering: ["10.0.0.1"], body: Data(emptyResult.utf8))
        switch await SonosFavorites.read(hosts: ["10.0.0.1"]) {
        case .noSpeakerAnswered:
            XCTFail("the speaker answered — an empty list is not silence")
        case .ok(let favorites, _):
            XCTAssertTrue(favorites.isEmpty)
        }
    }

    func testReadAsksContentDirectoryForTheFavoritesContainer() async throws {
        let stub = StubSpeaker(answering: ["10.0.0.1"], body: try fixtureData())
        SonosCommands.soap = stub
        _ = await SonosFavorites.read(hosts: ["10.0.0.1"])
        XCTAssertTrue(stub.asked.contains("10.0.0.1/Browse"),
                      "favorites come from a ContentDirectory Browse, not a transport action")
    }

    /// The service split is what the setup screens filter on, so it is worth asserting
    /// against the real capture rather than trusting the sid parser in isolation.
    func testTheCaptureSplitsIntoTheExpectedServices() async throws {
        SonosCommands.soap = StubSpeaker(answering: ["10.0.0.1"], body: try fixtureData())
        guard case .ok(let favorites, _) = await SonosFavorites.read(hosts: ["10.0.0.1"]) else {
            return XCTFail("expected the stub to answer")
        }
        XCTAssertEqual(favorites.filter { $0.sonosServiceId == 37 }.count, 8, "SiriusXM")
        XCTAssertEqual(favorites.filter { $0.sonosServiceId == 303 }.count, 4, "Sonos Radio")
    }
}
