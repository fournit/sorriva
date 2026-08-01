import Foundation

// MARK: - PlaybackCoordinator
// Owns application playback intent and orchestration.
// Architecture doc: PlaybackCoordinator section. Pattern B.
//
// Lifecycle for every command:
// 1. Set pending state on PlaybackStore
// 2. Execute via LocalPlaybackService or SonosEndpointDriver
// 3. Confirm via endpoint refresh — or roll back with PlaybackIssue

@MainActor
final class PlaybackCoordinator {

    static let shared = PlaybackCoordinator()

    // Dependencies — set by SorrivaAppEnvironment after construction
    var discovery: ZoneDiscoveryService?
    var localPlayback: LocalPlaybackService?
    var sonosDriver: SonosEndpointDriver?
    var store: PlaybackStore?

    private init() {}

    // MARK: - Public API

    /// Submit a playback intent. Sets pending state, executes, confirms or rolls back.
    func submit(_ intent: PlaybackIntent) {
        Task { await execute(intent) }
    }

    // MARK: - Execution

    private func execute(_ intent: PlaybackIntent) async {
        let correlationID = UUID()
        let zoneID = intent.zoneID

        // 1. Set pending state
        store?.setPendingCommand(PendingPlaybackCommand(
            correlationID: correlationID,
            zoneID: zoneID,
            kind: intent.commandKind
        ))
        store?.setIssue(nil)

        do {
            try await route(intent)
            // 3a. Success — trigger immediate poll to confirm state
            await refreshZone(zoneID: zoneID)
            store?.setPendingCommand(nil)
        } catch let error as EndpointCommandError {
            store?.setPendingCommand(nil)
            await handleCommandError(error, zoneID: zoneID)
        } catch {
            store?.setPendingCommand(nil)
            store?.setIssue(.unknown(error.localizedDescription))
            sLog("COORDINATOR: unexpected error — \(error.localizedDescription)")
        }
    }

    // MARK: - Routing

    private func route(_ intent: PlaybackIntent) async throws {
        guard let discovery else { throw EndpointCommandError.unknown("Discovery not wired", underlying: nil) }
        guard let driver = sonosDriver else { throw EndpointCommandError.unknown("Driver not wired", underlying: nil) }

        let zoneID = intent.zoneID

        switch intent {

        case .playTrack(let track, _):
            guard let zone = discovery.zones.first(where: { $0.id == zoneID }) else {
                throw EndpointCommandError.endpointUnavailable(id: EndpointID(rawValue: zoneID))
            }
            await localPlayback?.playTrack(track, on: zone)

        case .playAlbum(let tracks, _):
            guard let zone = discovery.zones.first(where: { $0.id == zoneID }) else {
                throw EndpointCommandError.endpointUnavailable(id: EndpointID(rawValue: zoneID))
            }
            await localPlayback?.playAlbum(tracks, on: zone)

        case .pause:
            try await driver.sendTransportAction(
                host: try resolveHost(zoneID: zoneID, discovery: discovery),
                action: "Pause"
            )

        case .resume:
            try await driver.sendTransportAction(
                host: try resolveHost(zoneID: zoneID, discovery: discovery),
                action: "Play"
            )

        case .skipNext:
            try await driver.sendTransportAction(
                host: try resolveHost(zoneID: zoneID, discovery: discovery),
                action: "Next"
            )

        case .skipPrevious:
            try await driver.sendTransportAction(
                host: try resolveHost(zoneID: zoneID, discovery: discovery),
                action: "Previous"
            )

        case .seek(_, let seconds):
            try await driver.sendSeek(
                host: try resolveHost(zoneID: zoneID, discovery: discovery),
                seconds: seconds
            )

        case .setVolume(_, let volume):
            try await driver.sendSetVolume(
                host: try resolveHost(zoneID: zoneID, discovery: discovery),
                volume: volume
            )

        case .groupZones(let coordID, let addIDs, let removeIDs):
            guard let coordinator = discovery.zones.first(where: { $0.id == coordID }) else {
                throw EndpointCommandError.endpointUnavailable(id: EndpointID(rawValue: coordID))
            }
            // Remove zones
            for id in removeIDs {
                let host = try resolveHost(zoneID: id, discovery: discovery)
                try await driver.becomeCoordinator(host: host)
            }
            // Add zones
            for id in addIDs {
                let host = try resolveHost(zoneID: id, discovery: discovery)
                try await driver.addMember(
                    coordinatorHost: coordinator.host,
                    memberHost: host,
                    memberUUID: coordID
                )
            }
            // Refresh topology
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            discovery.refresh()

        case .ungroupZone:
            guard let zone = discovery.zones.first(where: { $0.id == zoneID }) else { return }
            for member in zone.groupMembers {
                try await driver.becomeCoordinator(host: member.host)
            }

        case .transferPlayback(let fromID, let toID):
            guard let source = discovery.zones.first(where: { $0.id == fromID }),
                  let dest   = discovery.zones.first(where: { $0.id == toID }) else {
                throw EndpointCommandError.endpointUnavailable(id: EndpointID(rawValue: zoneID))
            }
            try await driver.addMember(
                coordinatorHost: source.host,
                memberHost: dest.host,
                memberUUID: fromID
            )
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            try await driver.becomeCoordinator(host: source.host)
        }
    }

    // MARK: - Error handling

    private func handleCommandError(_ error: EndpointCommandError, zoneID: String) async {
        sLog("COORDINATOR: command failed — \(error.localizedDescription)")
        switch error {
        case .partialQueue(let added, let requested):
            store?.setIssue(.partialQueue(added: added, requested: requested))
        case .endpointUnavailable(let id):
            store?.setIssue(.zoneUnavailable(zoneID: id.rawValue))
        case .topologyChanged:
            // Trigger rediscovery and surface issue
            store?.setIssue(.commandFailed(zoneID: zoneID, reason: "Zone topology changed. Try again."))
            discovery?.startDiscovery()
        case .soapFault(let code, let desc):
            store?.setIssue(.commandFailed(zoneID: zoneID, reason: "Sonos error \(code): \(desc)"))
        case .timeout:
            store?.setIssue(.commandFailed(zoneID: zoneID, reason: "Zone did not respond. Check network."))
        default:
            store?.setIssue(.commandFailed(zoneID: zoneID, reason: error.localizedDescription))
        }
    }

    // MARK: - Helpers

    private func resolveHost(zoneID: String, discovery: ZoneDiscoveryService) throws -> String {
        if let zone = discovery.zones.first(where: { $0.id == zoneID }) {
            return zone.host
        }
        throw EndpointCommandError.endpointUnavailable(id: EndpointID(rawValue: zoneID))
    }

    private func refreshZone(zoneID: String) async {
        discovery?.refresh()
    }
}
