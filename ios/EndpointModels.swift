import Foundation

// MARK: - EndpointKind

enum EndpointKind: String, Sendable {
    case sonos
    case airPlay
    case local      // iPhone/iPad speaker
    case blueOS     // Future
}

// MARK: - EndpointID

struct EndpointID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String    // RINCON UUID for Sonos
    var description: String { rawValue }
}

// MARK: - EndpointCommand
// All commands the driver layer understands.
// Music-domain concepts (album, artist, track) are absent — drivers receive
// resolved locators only. Constitution I-005.

enum EndpointCommand: Sendable {
    case play
    case pause
    case skipNext
    case skipPrevious
    case seek(toSeconds: Int)
    case setVolume(Int)
    case setMemberVolume(memberID: String, volume: Int)
    case clearQueue
    case addToQueue(uri: String, metadata: String, title: String)
    case setTransportURI(uri: String, metadata: String)
    case group(coordinatorID: EndpointID, addMemberIDs: [EndpointID], removeMemberIDs: [EndpointID])
    case ungroup
    case transfer(toEndpointID: EndpointID)
    case registerShare(nasPath: String)
}

// MARK: - EndpointCommandResult

enum EndpointCommandResult: Sendable {
    case success
    case partialQueue(added: Int, requested: Int)
}

// MARK: - EndpointCommandError

enum EndpointCommandError: Error, Sendable {
    /// Network request timed out or connection refused.
    case timeout(underlying: Error?)
    /// Sonos returned a UPnP/SOAP error.
    case soapFault(code: Int, description: String)
    /// The endpoint is no longer in the zone list.
    case endpointUnavailable(id: EndpointID)
    /// The coordinator changed between command issue and execution.
    case topologyChanged
    /// Queue build completed with fewer tracks than requested.
    case partialQueue(added: Int, requested: Int)
    /// Command not supported by this endpoint or capability set.
    case unsupported(String)
    /// Unexpected failure not covered by the above.
    case unknown(String, underlying: Error?)
}

extension EndpointCommandError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .timeout:
            return "The endpoint did not respond in time."
        case .soapFault(let code, let desc):
            return "Sonos error \(code): \(desc)"
        case .endpointUnavailable(let id):
            return "Zone \(id) is no longer available."
        case .topologyChanged:
            return "The zone topology changed while executing the command."
        case .partialQueue(let added, let requested):
            return "Only \(added) of \(requested) tracks were queued."
        case .unsupported(let msg):
            return "Unsupported command: \(msg)"
        case .unknown(let msg, _):
            return "Unexpected error: \(msg)"
        }
    }
}

// MARK: - EndpointTopology (for WP-10 discovery use)

struct EndpointTopology: Sendable {
    let endpoints: [EndpointDescriptor]
}

struct EndpointDescriptor: Identifiable, Sendable {
    let id: EndpointID
    let name: String
    let host: String
    let kind: EndpointKind
    let groupMemberIDs: [EndpointID]
    let coordinatorID: EndpointID?
}

// MARK: - EndpointPlaybackState (for WP-10 state reporting)

struct EndpointPlaybackState: Sendable {
    let endpointID: EndpointID
    let isPlaying: Bool
    let volume: Int
    let currentTrackURI: String
    let elapsedSeconds: Int
    let durationSeconds: Int
    let trackTitle: String
    let artistName: String
}
