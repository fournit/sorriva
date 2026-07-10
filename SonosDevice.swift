import Foundation

// MARK: - SonosDevice
// Represents a single Sonos speaker discovered on the local network.
// Identity is keyed on UUID (stable across IP changes and reboots).

struct SonosDevice: Identifiable, Equatable {
    let id: String          // RINCON UUID — stable hardware identity
    let name: String        // Zone name e.g. "Office", "Living Room"
    let host: String        // Current IP address — may change, use UUID for identity
    let port: Int           // Always 1400 for Sonos UPnP

    var groupCoordinatorID: String?   // UUID of group coordinator (nil if this device IS coordinator)
    var transportState: TransportState
    var isCoordinator: Bool { groupCoordinatorID == nil || groupCoordinatorID == id }

    enum TransportState: String, Equatable {
        case playing     = "PLAYING"
        case paused      = "PAUSED_PLAYBACK"
        case stopped     = "STOPPED"
        case transitioning = "TRANSITIONING"
        case unknown

        var isActive: Bool {
            self == .playing || self == .transitioning
        }
    }

    // Computed: base URL for UPnP control
    var baseURL: URL? {
        URL(string: "http://\(host):\(port)")
    }
}

// MARK: - SonosGroup
// A logical group of one coordinator and zero or more members.
// All zone cards in the Playing section represent groups (even single-speaker "groups").

struct SonosGroup: Identifiable {
    let coordinatorID: String
    var members: [SonosDevice]

    var id: String { coordinatorID }

    var coordinator: SonosDevice? {
        members.first { $0.id == coordinatorID }
    }

    var name: String {
        if members.count == 1 {
            return coordinator?.name ?? "Unknown"
        }
        let names = members.map { $0.name }.sorted()
        return names.joined(separator: " + ")
    }

    var isActive: Bool {
        coordinator?.transportState.isActive ?? false
    }
}
