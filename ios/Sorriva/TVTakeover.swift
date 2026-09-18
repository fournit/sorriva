import Foundation

// MARK: - TVTakeover
// One place for "would playing here interrupt a television?", and the words we say
// when it would. Foundation only, so it can be symlinked into ios/FastTests and
// covered by the one-second suite — do not add a SwiftUI import here. The alert
// itself lives in TVTakeoverAlert.swift.

enum TVTakeover {

    /// True when a zone is on its external input AND sound is actually coming out of it.
    ///
    /// BOTH halves are required, and the reason is measured — see
    /// server/static/docs/engineering/sonos-playback-contract.md §6a.
    ///
    ///   * `isHDMI` is a SOURCE fact: which input the speaker is on. Sonos holds the
    ///     TV input for HOURS after the television is switched off, so this alone
    ///     would put a dialog in front of every evening's listening.
    ///   * `idleState` is an ACTIVITY fact: Sonos's own "nothing is coming out of this
    ///     room" flag, from IdleState on the ZoneGroupMember. It is the ONLY thing that
    ///     tells a live TV from a held-but-silent input — over AVTransport the two are
    ///     byte-identical, same state, same status, same empty metadata.
    ///
    /// `idleState` is debounced ~20s at the speaker (deliberately: a room that flipped
    /// to idle during a quiet passage of dialogue would be worse than one that settles
    /// slowly). So this reads slightly stale in both directions, and the bias is toward
    /// asking, which is the safe side.
    static func isActive(_ zone: SonosZone) -> Bool {
        zone.isHDMI && !zone.idleState
    }

    /// Alert title. Named for the room, because the whole point is which room.
    static func title(zoneName: String) -> String {
        "\(zoneName) is actively playing TV audio"
    }

    /// Alert body. "Play", not "OK" — the button names the action it performs.
    static func message() -> String {
        "Press Play to play the new audio in the zone."
    }

    /// Title for the grouping case, where more than one room being added can be on TV.
    static func title(zoneNames: [String]) -> String {
        guard zoneNames.count > 1 else {
            return title(zoneName: zoneNames.first ?? "")
        }
        return "\(zoneNames.joined(separator: ", ")) are actively playing TV audio"
    }
}
