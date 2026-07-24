import Foundation

// MARK: - Canonical Identity Types
// Architecture doc: MusicDomain section. Constitution I-001, I-004.
// MusicDomain depends on Foundation only — no SwiftUI, GRDB, SMB, Sonos, UIKit.
//
// These are logical identities — independent of storage path or service representation.
// Physical paths, downloaded copies, and streaming-service references are representations.

// MARK: - Typed IDs

struct CanonicalArtistID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID
    var description: String { rawValue.uuidString }
    init(_ uuid: UUID = UUID()) { rawValue = uuid }
    init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        rawValue = uuid
    }
}

struct CanonicalAlbumID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID
    var description: String { rawValue.uuidString }
    init(_ uuid: UUID = UUID()) { rawValue = uuid }
    init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        rawValue = uuid
    }
}

struct CanonicalTrackID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID
    var description: String { rawValue.uuidString }
    init(_ uuid: UUID = UUID()) { rawValue = uuid }
    init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        rawValue = uuid
    }
}

struct HouseholdID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String
    var description: String { rawValue }
    init(_ value: String) { rawValue = value }
}

struct LibrarySourceID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID
    var description: String { rawValue.uuidString }
    init(_ uuid: UUID = UUID()) { rawValue = uuid }
    init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        rawValue = uuid
    }
}

struct RepresentationID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID
    var description: String { rawValue.uuidString }
    init(_ uuid: UUID = UUID()) { rawValue = uuid }
    init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        rawValue = uuid
    }
}

// MARK: - Canonical Domain Models

struct MusicArtist: Identifiable, Sendable {
    let id: CanonicalArtistID
    var name: String
    var sortName: String
}

struct MusicAlbum: Identifiable, Sendable {
    let id: CanonicalAlbumID
    var title: String
    var sortTitle: String
    var primaryArtistID: CanonicalArtistID?
    var year: Int?
    var genre: String?
}

struct MusicTrack: Identifiable, Sendable {
    let id: CanonicalTrackID
    var title: String
    var albumID: CanonicalAlbumID?
    var primaryArtistID: CanonicalArtistID?
    var trackNumber: Int?
    var discNumber: Int?
    var duration: TimeInterval?
    var sortTitle: String?
}

// MARK: - Representation

enum RepresentationKind: String, Codable, Sendable {
    case smbFile        // x-file-cifs:// on NAS
    case localReplica   // Downloaded copy on device
    case appleMusic     // Apple Music (MusicKit)
    case qobuz          // Qobuz Connect
    case tidal          // Tidal Connect
}

enum RepresentationAvailability: String, Codable, Sendable {
    case available
    case unavailable    // Source offline or not reachable
    case unknown        // Not yet verified
}

struct TrackRepresentation: Identifiable, Sendable {
    let id: RepresentationID
    let trackID: CanonicalTrackID
    let sourceID: LibrarySourceID
    let householdID: HouseholdID?
    let kind: RepresentationKind
    let locator: String             // Raw locator (e.g. SMB relative path)
    let normalizedLocator: String   // Lowercase, normalized — unique key with sourceID
    let fileSize: Int?
    let modifiedAt: Date?
    let duration: TimeInterval?
    var availability: RepresentationAvailability
    var lastVerifiedAt: Date?
}

// MARK: - Audio properties

struct AudioProperties: Sendable {
    let format: String      // "flac" | "mp3" | "m4a" | "wav" | "aiff"
    let bitrate: Int?       // kbps
    let sampleRate: Int?    // Hz
    let bitDepth: Int?      // bits
}
