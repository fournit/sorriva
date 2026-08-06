import Foundation

// MARK: - AudioEndpointDriver
// Protocol seam for all audio endpoint implementations.
// Constitution I-005, Architecture doc EndpointDriver section, ADR-007.
//
// Drivers understand endpoint operations only — no music domain concepts.
// They receive resolved URIs and metadata, not album/artist/track objects.

protocol AudioEndpointDriver: Sendable {

    var kind: EndpointKind { get }

    /// Execute a command against an endpoint.
    /// Throws EndpointCommandError on failure.
    /// Returns EndpointCommandResult to surface partial success (e.g. partialQueue).
    func execute(
        _ command: EndpointCommand,
        on endpointID: EndpointID
    ) async throws -> EndpointCommandResult

    /// Fetch current playback state for a single endpoint.
    func state(for endpointID: EndpointID) async throws -> EndpointPlaybackState

    /// Discover available endpoints in the current network context.
    func discoverEndpoints() async throws -> EndpointTopology
}
