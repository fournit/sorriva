import XCTest
@testable import Sorriva

// MARK: - ZoneServiceLookupTests
//
// The one part of the position-info path that is NOT pure, and therefore the one
// part that cannot live in the FastTests package.
//
// When SonosTopology was extracted on 2026-08-08, updateZoneFromPositionInfo split
// in two: the parsing (pure, moved, 21 tests now run in ~1.5s on the Mac) and the
// lookup-and-write-back (needs a live ZoneDiscoveryService and its `zones` array,
// stays here). This file is the second half.
//
// It is deliberately tiny. If it grows, that is a signal that logic is creeping
// back into the service instead of into SonosTopology.

@MainActor
final class ZoneServiceLookupTests: XCTestCase {

    /// Bundle first, source tree second — identical to ZonePollingTests.fixture, and
    /// the order matters. These tests run inside the simulator, which cannot read
    /// /Users/... on the host, so a #filePath lookup alone fails there.
    private func fixture(_ name: String) throws -> Data {
        if let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "xml") {
            return try Data(contentsOf: url)
        }
        let here = URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        return try Data(contentsOf: here.appendingPathComponent("Fixtures/\(name).xml"))
    }

    /// A response is addressed to one zone. Applying it to whichever zone happens to
    /// be first, or to none at all silently, are both wrong — and the second is what
    /// a missing guard would look like in the field: a TV in one room marking a
    /// different room as HDMI.
    func testPositionInfoForAnUnknownZoneIsIgnored() throws {
        let svc = ZoneDiscoveryService()
        svc.zones = [SonosZone(id: "Z1", name: "Test Room", host: "10.0.0.9",
                               isPlaying: true, volume: 20)]

        svc.updateZoneFromPositionInfo(zoneID: "NOPE",
                                       positionData: try fixture("positioninfo_hdmi"))

        XCTAssertFalse(svc.zones[0].isHDMI, "a response for another zone must not bleed across")
        XCTAssertEqual(svc.zones.count, 1, "and must not invent a zone either")
    }

    /// The write-back half: a response addressed to a zone that IS present must land
    /// on that zone. Without this, the guard above could pass by doing nothing at all.
    func testPositionInfoForAKnownZoneIsApplied() throws {
        let svc = ZoneDiscoveryService()
        svc.zones = [SonosZone(id: "Z1", name: "Test Room", host: "10.0.0.9",
                               isPlaying: true, volume: 20)]

        svc.updateZoneFromPositionInfo(zoneID: "Z1",
                                       positionData: try fixture("positioninfo_hdmi"))

        XCTAssertTrue(svc.zones[0].isHDMI, "the response was addressed to this zone")
    }
}
