import Foundation
import GRDB

// MARK: - Household
// Represents a Sonos (or future BluOS) household on the local network.
// hhid is the Sonos household ID from the Bonjour TXT record.

struct Household: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "households"

    var id: String              // Sonos hhid — stable household identifier
    var sonosName: String?      // Name from Sonos system (if available)
    var userName: String?       // Sorriva user override (set in Settings)
    var lastSeen: Int           // Unix timestamp
    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var syncedAt: Int?

    var displayName: String {
        userName ?? sonosName ?? id
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let sonosName = Column(CodingKeys.sonosName)
        static let userName = Column(CodingKeys.userName)
        static let lastSeen = Column(CodingKeys.lastSeen)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }
}

// MARK: - Device
// Source-agnostic device record. Works for Sonos, BluOS, AirPlay.
// capabilities is a JSON-encoded [String] — drives UI feature visibility.

struct Device: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "devices"

    var id: String              // Sorriva UUID (stable across renames/IP changes)
    var householdId: String     // FK → households.id
    var source: String          // "sonos" | "bluesound" | "airplay"
    var sourceId: String        // RINCON UUID (Sonos), MAC (BluOS), etc.
    var modelName: String?      // "Sonos Arc Ultra", "Bluesound Node", etc.
    var sourceName: String?     // Zone name from device API (e.g. "Living Room")
    var userName: String?       // Sorriva user override
    var capabilitiesJSON: String // JSON-encoded [String]
    var firstSeen: Int
    var updatedAt: Int
    var deletedAt: Int?
    var syncedAt: Int?

    // Decoded capabilities array
    var capabilities: [String] {
        (try? JSONDecoder().decode([String].self, from: capabilitiesJSON.data(using: .utf8) ?? Data())) ?? []
    }

    func hasCapability(_ cap: String) -> Bool {
        capabilities.contains(cap)
    }

    var displayName: String {
        userName ?? sourceName ?? sourceId
    }

    // Capabilities by model — expandable as we add devices
    static func capabilitiesForModel(_ modelName: String) -> [String] {
        let name = modelName.lowercased()
        var caps: [String] = ["eq", "volume", "mute"]

        if name.contains("arc") {
            caps += ["hdmi", "night_sound", "speech_enhancement", "subwoofer", "height_channel"]
        }
        if name.contains("beam") {
            caps += ["hdmi", "night_sound", "speech_enhancement"]
        }
        if name.contains("playbar") || name.contains("playbase") {
            caps += ["hdmi", "night_sound", "speech_enhancement"]
        }
        if name.contains("sub") {
            caps = ["subwoofer_satellite"]
        }

        return caps
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let householdId = Column(CodingKeys.householdId)
        static let sourceId = Column(CodingKeys.sourceId)
        static let source = Column(CodingKeys.source)
        static let modelName = Column(CodingKeys.modelName)
        static let sourceName = Column(CodingKeys.sourceName)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }
}

// MARK: - Station
// Radio station catalog — iHeart for now, source-agnostic schema.

struct Station: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "stations"

    var id: Int
    var source: String
    var name: String
    var logoURL: String?
    var streamURL: String?
    var isFavorite: Bool = false
    var cume: Int = 0       // iHeart cumulative audience — used for popularity sort
    var lastFetched: Int
    var updatedAt: Int

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let source = Column(CodingKeys.source)
        static let name = Column(CodingKeys.name)
        static let logoURL = Column(CodingKeys.logoURL)
        static let streamURL = Column(CodingKeys.streamURL)
        static let isFavorite = Column(CodingKeys.isFavorite)
        static let cume = Column(CodingKeys.cume)
        static let lastFetched = Column(CodingKeys.lastFetched)
    }
}

// MARK: - ZoneState
// Persists last-used station per zone — survives app restarts.

struct ZoneState: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "zone_state"

    var deviceId: String        // FK → devices.id (Sorriva UUID)
    var stationId: Int?         // FK → stations.id
    var stationName: String?    // Cached station name (denormalized for fast display)
    var stationLogoURL: String? // Cached logo URL
    var lastUsed: Int
    var updatedAt: Int

    static let databasePrimaryKey = ["deviceId"]
    static var databaseDecodingUserInfo: [CodingUserInfoKey: Any] = [:]
}

// MARK: - Genre
// Canonical genre taxonomy based on AllMusic hierarchy.
// Parent genres have parentId = nil. Subgenres point to their parent.
// imageURL is null until fGenreImages is resolved (Phase 6).

struct Genre: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "genres"

    var id: String          // slug e.g. "pop-rock", "jazz", "jazz-fusion"
    var name: String        // display name e.g. "Pop/Rock", "Jazz", "Fusion"
    var parentId: String?   // FK → genres.id, null for top-level genres
    var sortOrder: Int      // controls display sequence within parent
    var imageURL: String?   // null until fGenreImages resolved

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let parentId = Column(CodingKeys.parentId)
        static let sortOrder = Column(CodingKeys.sortOrder)
        static let imageURL = Column(CodingKeys.imageURL)
    }
}

// MARK: - StationGenre
// Many-to-many between stations and genres.
// A station can belong to multiple genres (e.g. "Classic Hits" → pop-rock + decades).

struct StationGenre: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "station_genres"

    var stationId: Int      // FK → stations.id
    var genreId: String     // FK → genres.id

    static let databasePrimaryKey = ["stationId", "genreId"]

    enum Columns {
        static let stationId = Column(CodingKeys.stationId)
        static let genreId = Column(CodingKeys.genreId)
    }
}

// MARK: - GenreSourceXref
// Maps canonical Sorriva genre IDs to each service's genre identifier.
// sourceGenreId: service's internal numeric/opaque ID (null if none)
// sourceGenreName: service's human-readable genre string / search keyword
//
// Examples:
//   iHeart:       sourceGenreId=nil,  sourceGenreName="rock"
//   Spotify:      sourceGenreId="6",  sourceGenreName="Rock"
//   Last.fm:      sourceGenreId=nil,  sourceGenreName="rock"
//   Apple Music:  sourceGenreId="21", sourceGenreName="Rock"

struct GenreSourceXref: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "genre_source_xref"

    var genreId: String         // FK → genres.id
    var source: String          // "iheart" | "somafm" | "spotify" | "applemusic" | "lastfm"
    var sourceGenreId: String?  // service's internal ID (null if service uses names only)
    var sourceGenreName: String // service's genre string / search keyword

    static let databasePrimaryKey = ["genreId", "source"]

    enum Columns {
        static let genreId = Column(CodingKeys.genreId)
        static let source = Column(CodingKeys.source)
        static let sourceGenreId = Column(CodingKeys.sourceGenreId)
        static let sourceGenreName = Column(CodingKeys.sourceGenreName)
    }
}
