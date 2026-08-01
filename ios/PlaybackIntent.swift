import Foundation

// MARK: - PlaybackIntent
// Typed representation of a user's playback request.
// UI and screen models submit intents to PlaybackCoordinator.
// Coordinators never receive SonosZone directly — they receive IDs.

enum PlaybackIntent: Sendable {

    // MARK: - Local library playback
    case playTrack(Track, zoneID: String)
    case playAlbum([Track], zoneID: String)

    // MARK: - Transport
    case pause(zoneID: String)
    case resume(zoneID: String)
    case skipNext(zoneID: String)
    case skipPrevious(zoneID: String)
    case seek(zoneID: String, toSeconds: Int)
    case setVolume(zoneID: String, volume: Int)

    // MARK: - Zone management
    case groupZones(coordinatorID: String, addIDs: [String], removeIDs: [String])
    case ungroupZone(zoneID: String)
    case transferPlayback(fromZoneID: String, toZoneID: String)

    // MARK: - Convenience

    var zoneID: String {
        switch self {
        case .playTrack(_, let id): return id
        case .playAlbum(_, let id): return id
        case .pause(let id): return id
        case .resume(let id): return id
        case .skipNext(let id): return id
        case .skipPrevious(let id): return id
        case .seek(let id, _): return id
        case .setVolume(let id, _): return id
        case .groupZones(let id, _, _): return id
        case .ungroupZone(let id): return id
        case .transferPlayback(let id, _): return id
        }
    }

    var commandKind: PendingPlaybackCommand.CommandKind {
        switch self {
        case .playTrack, .playAlbum: return .loadQueue
        case .pause: return .pause
        case .resume: return .play
        case .skipNext: return .skip
        case .skipPrevious: return .skip
        case .seek: return .seek
        case .setVolume(_, let v): return .volume(v)
        case .groupZones: return .group
        case .ungroupZone: return .ungroup
        case .transferPlayback: return .transfer
        }
    }
}
