import Foundation

// MARK: - PlayMode
//
// Sonos models shuffle and repeat as ONE field with six values, not two switches.
// Sorriva presents two switches, because that is how everybody thinks about it, so
// this file is the translation between the two.
//
// Measured off the speaker's own /xml/AVTransport1.xml on 2026-08-19 and recorded in
// server/static/docs/engineering/sonos-playback-contract.md §14. Two traps live here:
//
//   1. `SHUFFLE` means shuffle + repeat-ALL, not shuffle alone. Shuffle without repeat
//      is `SHUFFLE_NOREPEAT`. Getting these two the wrong way round is the obvious bug.
//   2. A queue must already be loaded or `SetPlayMode` is refused with errorCode 712 —
//      EXCEPT for `.normal`, which is always valid. That exception is what lets the
//      queue clear reset the mode; see SonosCommands.removeAllTracksFromQueue.
//
// Foundation-only, deliberately: this file is symlinked into ios/FastTests so the
// mapping is tested on the Mac in milliseconds. Do not give it a UI dependency.

enum PlayMode: String, CaseIterable, Sendable {
    case normal            = "NORMAL"
    case repeatAll         = "REPEAT_ALL"
    case repeatOne         = "REPEAT_ONE"
    case shuffleNoRepeat   = "SHUFFLE_NOREPEAT"
    case shuffleRepeatAll  = "SHUFFLE"
    case shuffleRepeatOne  = "SHUFFLE_REPEAT_ONE"

    /// What Sorriva's repeat control offers. Sonos has no separate field for it.
    enum Repeat: String, CaseIterable, Sendable {
        case off, all, one

        /// Order the UI cycles through on each tap.
        var next: Repeat {
            switch self {
            case .off: return .all
            case .all: return .one
            case .one: return .off
            }
        }
    }

    // MARK: - Two switches in, one Sonos value out

    init(shuffle: Bool, repeatMode: Repeat) {
        switch (shuffle, repeatMode) {
        case (false, .off): self = .normal
        case (false, .all): self = .repeatAll
        case (false, .one): self = .repeatOne
        case (true,  .off): self = .shuffleNoRepeat
        case (true,  .all): self = .shuffleRepeatAll
        case (true,  .one): self = .shuffleRepeatOne
        }
    }

    // MARK: - One Sonos value in, two switches out

    var isShuffled: Bool {
        switch self {
        case .normal, .repeatAll, .repeatOne:
            return false
        case .shuffleNoRepeat, .shuffleRepeatAll, .shuffleRepeatOne:
            return true
        }
    }

    var repeatMode: Repeat {
        switch self {
        case .normal, .shuffleNoRepeat:            return .off
        case .repeatAll, .shuffleRepeatAll:        return .all
        case .repeatOne, .shuffleRepeatOne:        return .one
        }
    }

    /// Parse what `GetTransportSettings` reported. An unrecognised value is treated as
    /// `.normal` rather than trusted — a mode Sorriva cannot name is one it cannot draw,
    /// and claiming shuffle is on when it might not be is the worse of the two errors.
    init(reported: String) {
        self = PlayMode(rawValue: reported.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? .normal
    }
}
