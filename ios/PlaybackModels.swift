import Foundation

// MARK: - ZonePlaybackSnapshot
// Complete view-ready snapshot of a zone's playback state.
// Produced by PlaybackStateReducer from SonosZone + PlaybackContext.
// All three surfaces (ZoneCard, MiniPlayer, NowPlaying) read from this.

struct ZonePlaybackSnapshot: Identifiable, Equatable, Sendable {
    let id: String              // Zone RINCON UUID
    let name: String            // Display name e.g. "Living Room"
    let host: String            // IPv4 for commands

    // Transport
    let isPlaying: Bool
    let volume: Int
    let isHDMI: Bool
    let idleState: Bool

    // Track display — merged from PlaybackContext (local) or SonosZone (stream)
    let trackTitle: String
    let artistName: String
    let albumName: String       // Album title for local, station name for streams
    let sourceLabel: String     // "Local Library (Lossless)" | "Spotify" | "" etc.
    let isLocal: Bool

    // Position — from SonosZone.elapsedSeconds / durationSeconds
    let elapsedSeconds: Int
    let durationSeconds: Int

    // Artwork
    let artAlbum: Album?        // Non-nil for local tracks
    let artURL: String?         // Non-nil for streams

    // Group
    let groupMembers: [SonosGroupMember]
    let coordinatorID: String?

    // Availability
    let isAvailable: Bool

    var progress: Double {
        durationSeconds > 0 ? Double(elapsedSeconds) / Double(durationSeconds) : 0
    }

    static func == (lhs: ZonePlaybackSnapshot, rhs: ZonePlaybackSnapshot) -> Bool {
        lhs.id == rhs.id &&
        lhs.isPlaying == rhs.isPlaying &&
        lhs.volume == rhs.volume &&
        lhs.isHDMI == rhs.isHDMI &&
        lhs.idleState == rhs.idleState &&
        lhs.trackTitle == rhs.trackTitle &&
        lhs.artistName == rhs.artistName &&
        lhs.albumName == rhs.albumName &&
        lhs.sourceLabel == rhs.sourceLabel &&
        lhs.isLocal == rhs.isLocal &&
        lhs.elapsedSeconds == rhs.elapsedSeconds &&
        lhs.durationSeconds == rhs.durationSeconds &&
        lhs.artAlbum?.id == rhs.artAlbum?.id &&
        lhs.artURL == rhs.artURL &&
        lhs.groupMembers == rhs.groupMembers &&
        lhs.coordinatorID == rhs.coordinatorID
    }
}

// MARK: - PlaybackDeclaration
// An authoritative statement of what a zone is playing, made by whoever caused
// the change. Sonos owns the URI; the app owns naming that URI (Sonos often
// cannot — empty stream titles, no local album art). A declaration is honoured
// only while its URI still matches the URI Sonos currently reports; on mismatch
// it is invalidated. That binding is what prevents stale names from displaying.
// See HANDOFF-playbackstore-design.md sections 3-5.

struct PlaybackDeclaration {
    /// Display metadata this declaration resolves — track, artist, album, artwork.
    let context: PlaybackContext
    /// The content URI this metadata describes. The reconciliation key.
    let uri: String
    /// Who declared it. `.app` is trusted over polling while its URI matches;
    /// `.external` is a detection result and is freely replaceable.
    let source: Source
    /// When it was declared. Bounds the grace window in the precedence rule.
    let declaredAt: Date

    enum Source {
        case app
        case external
    }
}

// MARK: - TransportIntent
// The app's optimistic claim about a zone's TRANSPORT — playing or not — for the short
// window between issuing a command and Sonos confirming it.
//
// Distinct from PlaybackDeclaration, which claims CONTENT. The two are not co-extensive:
// pausing a zone changes transport while making no claim about what is loaded, and
// grouping changes topology without changing content. That is why this cannot simply be
// folded into the declaration.
//
// Replaces `SonosZone.playingUntil`, which recorded the same fact in the zone struct —
// one truth in two places, with the drift that always follows: the grace was 5s in one
// call site and 6s in the others, against a declarationGrace of 5, and nobody chose that.
struct TransportIntent {
    /// What the app asked the zone to do.
    let isPlaying: Bool
    /// When it was asked. Bounds the optimism window, using `declarationGrace`.
    let declaredAt: Date
}

// MARK: - PendingPlaybackCommand
// Optimistic command state — set when a command is issued, cleared on confirmation.

struct PendingPlaybackCommand: Equatable {
    let correlationID: UUID
    let zoneID: String
    let kind: CommandKind

    enum CommandKind: Equatable {
        case play
        case pause
        case skip
        case seek
        case volume(Int)
        case group
        case ungroup
        case transfer
        case loadQueue
    }
}

// MARK: - PlaybackIssue
// Surfaced to UI when a command fails or state becomes inconsistent.

enum PlaybackIssue: Equatable {
    case commandFailed(zoneID: String, reason: String)
    case partialQueue(added: Int, requested: Int)
    case zoneUnavailable(zoneID: String)
    case unknown(String)
}
