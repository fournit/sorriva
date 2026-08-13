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

/// `StationLike` conformance is declared here rather than in RadioServiceAdapter.swift,
/// which must stay free of the persistence layer — see the protocol's own note.
extension Station: StationLike {}

struct Station: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "stations"

    var id: Int
    /// Which service this station belongs to — FK into `services`. Replaced `source`
    /// in v24; same values, but the library now enumerates services from the table
    /// rather than naming them literally in 22 places.
    var serviceId: String
    var name: String
    var logoURL: String?
    var streamURL: String?
    /// Sonos favorite metadata, verbatim. Non-nil only for stations imported from
    /// FV:2 — it carries the service token that makes a closed service playable and is
    /// handed back to the speaker exactly as read. See sonos-playback-contract.md §11.
    var resMD: String?
    /// The household this favorite was read from. NOT decoration: a refresh may only
    /// reconcile stations belonging to the household it just read, or refreshing at one
    /// location would delete the stations that exist only at another.
    var householdId: String?
    var isFavorite: Bool = false
    var cume: Int = 0       // iHeart cumulative audience — used for popularity sort
    var lastFetched: Int
    var updatedAt: Int

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let serviceId = Column(CodingKeys.serviceId)
        static let resMD = Column(CodingKeys.resMD)
        static let householdId = Column(CodingKeys.householdId)
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

// MARK: - ZoneLastPlaying
// The last thing the app knew a zone to be playing — station or local track.
//
// Distinct from ZoneState, which records the last station a zone was sent FROM
// SORRIVA and is written only by persistStationPlay. That single-writer gap is why a
// zone that received a transfer used to revert to an older station: nothing recorded
// what it actually ended up playing. This table is written by PlaybackStore whenever
// a zone's playback is declared, whatever the origin, so it is the durable form of
// "what was last playing here" and survives relaunch for every zone.
//
// Keyed by the Sonos zone id (RINCON) — the same key PlaybackStore uses — rather than
// the Sorriva device UUID, so no mapping is needed to restore it.

struct ZoneLastPlaying: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "zone_last_playing"

    var zoneId: String          // Sonos RINCON id
    var uri: String             // content URI this described
    var track: String
    var artist: String
    var albumName: String       // album title for local, station name for streams
    var artURL: String?         // remote artwork (stations)
    var albumId: String?        // local tracks — album UUID, re-fetched on restore for art
    var isLocal: Bool
    var updatedAt: Int

    static let databasePrimaryKey = ["zoneId"]
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

/// A music service. Rows for iHeart and SomaFM are seeded; rows for services arriving
/// via Sonos favorites are created on demand from the favorite's `sid` and
/// `<r:description>`.
struct Service: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "services"

    var id: String              // machine key — "siriusxm", "iheart"
    var name: String            // display — "SiriusXM"
    var logoURL: String?        // null until supplied; the UI falls back to the name
    var sonosServiceId: Int?    // Sonos's sid — how an incoming favorite finds its service
    var updatedAt: Int

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let sonosServiceId = Column(CodingKeys.sonosServiceId)
    }
}

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

// MARK: - LibrarySource

struct LibrarySource: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: String
    var type: String            // "smb" | "files"
    var displayName: String
    var host: String
    var share: String
    var rootPath: String
    var username: String?       // Migration window only — nil after v12
    var password: String?       // Migration window only — nil after v12
    var credentialRef: String?  // Keychain reference key — set after v12
    var lastScanned: Int?
    var trackCount: Int
    var scanState: String           // "idle" | "scanning" | "error" | "retrying" | "complete"
    var lastScanFileCount: Int?     // audio file count at last successful scan — change detection
    var lastScanTotalBytes: Int?    // aggregate file size at last successful scan — change detection
    var createdAt: Int
    var updatedAt: Int

    static let databaseTableName = "library_sources"

    enum Columns {
        static let id                 = Column(CodingKeys.id)
        static let type               = Column(CodingKeys.type)
        static let displayName        = Column(CodingKeys.displayName)
        static let host               = Column(CodingKeys.host)
        static let share              = Column(CodingKeys.share)
        static let rootPath           = Column(CodingKeys.rootPath)
        static let trackCount         = Column(CodingKeys.trackCount)
        static let scanState          = Column(CodingKeys.scanState)
        static let credentialRef      = Column(CodingKeys.credentialRef)
        static let lastScanned        = Column(CodingKeys.lastScanned)
        static let lastScanFileCount  = Column(CodingKeys.lastScanFileCount)
        static let lastScanTotalBytes = Column(CodingKeys.lastScanTotalBytes)
    }
}

// MARK: - Artist
// One row per unique artist in the local library.
// sortName strips leading "The ", "A ", etc. for correct alphabetical sort.
// albumCount and trackCount are denormalized counters — updated after each scan.

struct Artist: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "artists"

    var id: String          // UUID string — Sorriva-generated
    var name: String        // Display name e.g. "The Beatles"
    var sortName: String    // Sort name e.g. "Beatles, The"
    var imageURL: String?   // null until fMetadataEnrichment pass
    var albumCount: Int     // denormalized — updated after scan
    var trackCount: Int     // denormalized — updated after scan
    var createdAt: Int
    var updatedAt: Int

    enum Columns {
        static let id         = Column(CodingKeys.id)
        static let name       = Column(CodingKeys.name)
        static let sortName   = Column(CodingKeys.sortName)
        static let imageURL   = Column(CodingKeys.imageURL)
        static let albumCount = Column(CodingKeys.albumCount)
        static let trackCount = Column(CodingKeys.trackCount)
        static let createdAt  = Column(CodingKeys.createdAt)
        static let updatedAt  = Column(CodingKeys.updatedAt)
    }
}

// MARK: - Album
// One row per unique album. Has one primary artist, but may have others via artist_albums.
// artPathThumb/artPathFull are local filesystem paths to cached artwork — null until enrichment pass.
// sortTitle strips leading "The ", "A ", etc. for correct alphabetical sort.

struct Album: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "albums"

    var id: String              // UUID string — Sorriva-generated
    var title: String           // Display title e.g. "Kind of Blue"
    var sortTitle: String       // Sort title e.g. "Kind of Blue" (stripped of leading articles)
    var primaryArtistId: String // FK → artists.id
    var artistName: String      // Denormalized — primary artist display name
    var year: Int?              // Parsed from tag — null if not present
    var genre: String?          // Parsed from tag — null if not present
    var artPathThumb: String?   // Local path to 100px cached artwork — null until enrichment pass
    var artPathFull: String?    // Local path to 600px cached artwork — null until enrichment pass
    var artworkWidth: Int?      // Pixel width of the current winning artwork — null until any pass finds art (v15)
    var artworkHeight: Int?     // Pixel height of the current winning artwork — null until any pass finds art (v15)
    var embeddedArtScanned: Bool    // True after embedded art pass has run — never runs again once set
    var artManualOverride: Bool     // True when user manually set artwork — blocks all automated art passes
    var embeddedArtFailed: Bool     // True when embedded art read errored (not genuine no-art) — triggers retry
    var embeddedArtRetryCount: Int  // Number of failed embedded art attempts — capped at 5
    var trackCount: Int         // Denormalized — updated after scan
    var sourceId: String        // FK → library_sources.id
    var folderPath: String      // SMB path to album folder — used for artwork discovery
    // Provenance for ONLINE matches only (v22). Null for folder and embedded art,
    // which come from the user's own files and have nothing to attest to. Exists
    // so a wrong cover can be found by query rather than by opening the JPEG.
    var artMatchedName: String?     // collectionName the provider returned
    var artMatchedArtist: String?   // artistName the provider returned
    var artMatchScore: Double?      // 0...1 — why the match was accepted
    var artSource: String?          // v23 — which pass supplied the image on screen
    var artBestRejectedScore: Double?  // v23 — best online score that missed the bar
    var createdAt: Int
    var updatedAt: Int

    enum Columns {
        static let id                  = Column(CodingKeys.id)
        static let title               = Column(CodingKeys.title)
        static let sortTitle           = Column(CodingKeys.sortTitle)
        static let primaryArtistId     = Column(CodingKeys.primaryArtistId)
        static let artistName          = Column(CodingKeys.artistName)
        static let year                = Column(CodingKeys.year)
        static let genre               = Column(CodingKeys.genre)
        static let artPathThumb        = Column(CodingKeys.artPathThumb)
        static let artPathFull         = Column(CodingKeys.artPathFull)
        static let artworkWidth        = Column(CodingKeys.artworkWidth)
        static let artworkHeight       = Column(CodingKeys.artworkHeight)
        static let embeddedArtScanned    = Column(CodingKeys.embeddedArtScanned)
        static let artManualOverride     = Column(CodingKeys.artManualOverride)
        static let embeddedArtFailed     = Column(CodingKeys.embeddedArtFailed)
        static let embeddedArtRetryCount = Column(CodingKeys.embeddedArtRetryCount)
        static let trackCount          = Column(CodingKeys.trackCount)
        static let sourceId            = Column(CodingKeys.sourceId)
        static let folderPath          = Column(CodingKeys.folderPath)
        static let artMatchedName      = Column(CodingKeys.artMatchedName)
        static let artMatchedArtist    = Column(CodingKeys.artMatchedArtist)
        static let artMatchScore       = Column(CodingKeys.artMatchScore)
        static let artSource           = Column(CodingKeys.artSource)
        static let artBestRejectedScore = Column(CodingKeys.artBestRejectedScore)
        static let createdAt           = Column(CodingKeys.createdAt)
        static let updatedAt           = Column(CodingKeys.updatedAt)
    }
}

// MARK: - Track
// One row per audio file. Belongs to one Album and one LibrarySource.
// filePath is the full SMB path — unique per track.
// duration is in seconds (Double) matching AVFoundation convention.
// bitrate is in kbps, sampleRate in Hz.

struct Track: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "tracks"

    var id: String              // UUID string — Sorriva-generated
    var title: String
    var albumId: String         // FK → albums.id
    var albumTitle: String      // Denormalized — album display title
    var primaryArtistId: String // FK → artists.id
    var artistName: String      // Denormalized — primary artist display name
    var trackNumber: Int?       // Parsed from tag or leading digits in filename
    var discNumber: Int?        // Parsed from tag — null if single-disc or not tagged
    var year: Int?              // Parsed from tag — null if not present
    var genre: String?          // Parsed from tag — null if not present
    var duration: Double?       // Seconds — parsed from tag header
    var fileFormat: String      // Lowercase extension: "flac" | "mp3" | "m4a" | "wav" | "aiff"
    var filePath: String        // Full SMB path — unique constraint in DB
    var fileSize: Int?          // Bytes
    var bitrate: Int?           // kbps — parsed from tag header
    var sampleRate: Int?        // Hz — parsed from tag header
    var sourceId: String        // FK → library_sources.id
    var createdAt: Int
    var updatedAt: Int

    enum Columns {
        static let id              = Column(CodingKeys.id)
        static let title           = Column(CodingKeys.title)
        static let albumId         = Column(CodingKeys.albumId)
        static let albumTitle      = Column(CodingKeys.albumTitle)
        static let primaryArtistId = Column(CodingKeys.primaryArtistId)
        static let artistName      = Column(CodingKeys.artistName)
        static let trackNumber     = Column(CodingKeys.trackNumber)
        static let discNumber      = Column(CodingKeys.discNumber)
        static let year            = Column(CodingKeys.year)
        static let genre           = Column(CodingKeys.genre)
        static let duration        = Column(CodingKeys.duration)
        static let fileFormat      = Column(CodingKeys.fileFormat)
        static let filePath        = Column(CodingKeys.filePath)
        static let fileSize        = Column(CodingKeys.fileSize)
        static let bitrate         = Column(CodingKeys.bitrate)
        static let sampleRate      = Column(CodingKeys.sampleRate)
        static let sourceId        = Column(CodingKeys.sourceId)
        static let createdAt       = Column(CodingKeys.createdAt)
        static let updatedAt       = Column(CodingKeys.updatedAt)
    }
}

// MARK: - ArtistAlbum
// Many-to-many between artists and albums.
// role: "primary" for the main artist, "featured" for collaborators.

struct ArtistAlbum: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "artist_albums"

    var artistId: String    // FK → artists.id
    var albumId: String     // FK → albums.id
    var role: String        // "primary" | "featured"

    static let databasePrimaryKey = ["artistId", "albumId"]

    enum Columns {
        static let artistId = Column(CodingKeys.artistId)
        static let albumId  = Column(CodingKeys.albumId)
        static let role     = Column(CodingKeys.role)
    }
}

// MARK: - TrackArtist
// Many-to-many between tracks and artists.
// role: "primary" for the main artist, "featured" for collaborators.

struct TrackArtist: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "track_artists"

    var trackId: String     // FK → tracks.id
    var artistId: String    // FK → artists.id
    var role: String        // "primary" | "featured"

    static let databasePrimaryKey = ["trackId", "artistId"]

    enum Columns {
        static let trackId  = Column(CodingKeys.trackId)
        static let artistId = Column(CodingKeys.artistId)
        static let role     = Column(CodingKeys.role)
    }
}

// MARK: - ScanSkip
// Records audio files that failed tag reads during scan.
// Retry pass runs after the full scan pipeline (scan → folder art → iTunes art → embedded art).
// Up to 5 attempts total. Rows are retained after attempt 5 (resolved = false, attemptCount = 5)
// for future admin review. resolved = true means the file was successfully recovered.

struct ScanSkip: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "scan_skips"

    var filePath: String        // Primary key — full SMB path of the failed file
    var sourceId: String        // FK → library_sources.id
    var attemptCount: Int       // Number of retry attempts made (0 = not yet retried)
    var lastAttemptAt: Int      // Unix timestamp of most recent attempt
    var resolved: Bool          // True when tags were successfully recovered

    enum Columns {
        static let filePath      = Column(CodingKeys.filePath)
        static let sourceId      = Column(CodingKeys.sourceId)
        static let attemptCount  = Column(CodingKeys.attemptCount)
        static let lastAttemptAt = Column(CodingKeys.lastAttemptAt)
        static let resolved      = Column(CodingKeys.resolved)
    }
}

// MARK: - FolderStat
// Per-folder scan fingerprint — used for incremental rescan detection.
// One row per scanned folder per source. Updated after each successful scan.
// On app foreground, statShare compares current dir stats against these rows
// and only rescans folders where fileCount or totalBytes changed.

struct FolderStat: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "folder_stats"

    var id: String          // UUID string — Sorriva-generated
    var sourceId: String    // FK → library_sources.id
    var folderPath: String  // SMB path of the folder e.g. "/Music II/Depeche Mode/Remixes 81-04"
    var fileCount: Int      // Audio file count at last successful scan
    var totalBytes: Int     // Aggregate file size at last successful scan
    var scannedAt: Int      // Unix timestamp of last successful scan

    enum Columns {
        static let id         = Column(CodingKeys.id)
        static let sourceId   = Column(CodingKeys.sourceId)
        static let folderPath = Column(CodingKeys.folderPath)
        static let fileCount  = Column(CodingKeys.fileCount)
        static let totalBytes = Column(CodingKeys.totalBytes)
        static let scannedAt  = Column(CodingKeys.scannedAt)
    }
}

// MARK: - ArtworkSource
//
// Which pass supplied the cover currently on screen (v23). Distinct from the
// embeddedArtScanned / folderArtScanned / onlineArtAttempted markers, which record
// which passes RAN — a question nobody was asking. The artwork review list ranks
// albums by doubt, and "where did this come from" is half of that judgement: art
// from the user's own files is trustworthy in a way an internet match is not.
enum ArtworkSource: String {
    case embedded   // ID3/FLAC picture frame in the audio file itself
    case folder     // cover.jpg and friends beside the tracks
    case online     // matched against a provider — see artMatchedName / artMatchScore
    case manual     // the user chose it; beats every automated pass
}
