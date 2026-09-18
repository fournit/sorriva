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

    // MARK: - Starting volume when taking a room off its TV input

    // A soundbar's volume is whatever the television left it at, and that is not a music
    // level. Measured 2026-09-17 on the household: the Living Room Arc Ultra sat at 6
    // straight after a film, where the rooms playing music sat at 12. Taking the room
    // without touching the volume therefore starts music almost inaudible — the failure
    // is quietness, not a blast, which is why a fixed default is safe here.
    //
    // Keyed on isHDMI ALONE, deliberately wider than isActive above. The volume is wrong
    // whether or not the television is still making sound: an input held since a film
    // that finished an hour ago has left the level behind just the same.

    static let volumeEnabledKey = "sorriva.tvVolumeOverrideEnabled"
    static let volumeLevelKey   = "sorriva.tvStartingVolume"
    static let defaultVolume    = 7
    static let volumeRange      = 1...30

    /// The volume to set before starting playback in this zone, or nil to leave it alone.
    ///
    /// Absent defaults mean ON at `defaultVolume` — a fresh install gets the behaviour
    /// without having to visit Settings. `object(forKey:)` rather than `bool(forKey:)`
    /// because the latter cannot tell "switched off" from "never set".
    static func startingVolume(for zone: SonosZone,
                               defaults: UserDefaults = .standard) -> Int? {
        guard zone.isHDMI else { return nil }
        if let stored = defaults.object(forKey: volumeEnabledKey) as? Bool, stored == false {
            return nil
        }
        let level = defaults.object(forKey: volumeLevelKey) as? Int ?? defaultVolume
        return min(max(level, volumeRange.lowerBound), volumeRange.upperBound)
    }

    /// Title for the grouping case, where more than one room being added can be on TV.
    static func title(zoneNames: [String]) -> String {
        guard zoneNames.count > 1 else {
            return title(zoneName: zoneNames.first ?? "")
        }
        return "\(zoneNames.joined(separator: ", ")) are actively playing TV audio"
    }
}
