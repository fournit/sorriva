# 02 — Sorriva Target Architecture

## 1. System shape

```text
SorrivaApp / LumvaraMusicHost
            |
      AppEnvironment
            |
  ScreenModels + PlaybackStore
            |
      Application Services
   |          |             |
Library   Playback      Household
Service   Coordinator   Context
   |          |             |
Repositories  SourceResolver
   |          |             |
MusicDomain   Endpoint Drivers
   |          |             |
GRDB/SMB/Keychain      Sonos/Local/Future
```

SorrivaApp and LumvaraMusicHost are composition shells. The shared music platform lives below them.

## 2. Target module boundaries

The first implementation may remain in one Xcode target while folders and interfaces are established. Split into Swift packages only when boundaries are stable and the split reduces build or ownership complexity.

### SorrivaApp

Owns:

- SwiftUI application lifecycle.
- Root navigation and product shell.
- AppEnvironment construction.
- Product-specific configuration.

Must not own:

- GRDB queries.
- Scanner logic.
- Sonos SOAP.
- Music-domain rules.

### AppEnvironment

A single instance constructed at application startup. It holds long-lived dependencies and provides them to screen models and services.

Initial shape:

```swift
@MainActor
final class SorrivaAppEnvironment: ObservableObject {
    let database: SorrivaDatabase
    let credentials: CredentialStore
    let libraryRepository: LibraryRepository
    let libraryService: LibraryService
    let householdContext: HouseholdContext
    let sonosDriver: SonosEndpointDriver
    let sourceResolver: SourceResolver
    let playbackCoordinator: PlaybackCoordinator
    let playbackStore: PlaybackStore
    let scanCoordinator: ScanCoordinator
}
```

Construction rules:

- No application-service singleton access from views.
- Existing singleton types may be injected temporarily but must not be newly referenced elsewhere.
- Environment construction is the sole composition root.

### ScreenModels

ScreenModels translate application state and domain objects into view-ready data and commands. They may depend on application services and stores, not infrastructure.

Initial screen models:

- ZonesScreenModel.
- NowPlayingScreenModel.
- LibraryScreenModel.
- AlbumDetailScreenModel.
- SettingsScreenModel.

### MusicDomain

Initial canonical models:

```swift
struct CanonicalArtistID: Hashable, Codable, Sendable { let rawValue: UUID }
struct CanonicalAlbumID: Hashable, Codable, Sendable { let rawValue: UUID }
struct CanonicalTrackID: Hashable, Codable, Sendable { let rawValue: UUID }
struct HouseholdID: Hashable, Codable, Sendable { let rawValue: String }
struct LibrarySourceID: Hashable, Codable, Sendable { let rawValue: UUID }
struct RepresentationID: Hashable, Codable, Sendable { let rawValue: UUID }
```

```swift
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
```

```swift
enum RepresentationKind: String, Codable, Sendable {
    case smbFile
    case localReplica
    case appleMusic
    case qobuz
    case tidal
}

struct TrackRepresentation: Identifiable, Sendable {
    let id: RepresentationID
    let trackID: CanonicalTrackID
    let sourceID: LibrarySourceID
    let householdID: HouseholdID?
    let kind: RepresentationKind
    let locator: String
    let availability: RepresentationAvailability
    let audio: AudioProperties?
}
```

For the first migration, existing Artist, Album, and Track database records can remain compatibility records. New canonical tables are introduced additively and linked to existing rows.

### LibraryRepository

Purpose: persistence boundary for music entities and representations.

Initial responsibilities:

- Read albums, artists, tracks, and source representations.
- Transactional reconciliation of discovered folders.
- Upsert by stable representation key.
- Maintain joins and denormalized counts.
- Expose domain models rather than GRDB rows to application services.

Prohibited:

- Network traversal.
- Endpoint control.
- SwiftUI state.

### LibraryService

Purpose: application-level library use cases.

Initial operations:

- listAlbums(filter/sort).
- listArtists(filter/sort).
- albumDetails(id).
- tracksForAlbum(id).
- search(query).
- requestScan(sourceID).
- sourceAvailability(sourceID).

### Scanner and importer

Target pipeline:

```text
LibrarySource
 -> SMBScanner traversal
 -> DiscoveredMediaFile[]
 -> FolderReconciler transaction
 -> Canonical entities + TrackRepresentation
 -> Scan result and diagnostics
```

`DiscoveredMediaFile` should contain:

- source ID.
- household ID.
- normalized relative path.
- stable representation key.
- file size and modification timestamp.
- parsed title, album, artist, album artist, track/disc number, genre.
- duration and audio properties.
- artwork discovery result.

Stable representation key for current SMB content:

```text
sourceID + normalized relative path
```

This is a representation identity, not canonical track identity.

### SourceResolver

Input:

- CanonicalTrackID.
- selected endpoint capabilities.
- active household.
- current connectivity and local-replica state.

Output:

```swift
struct PlayableSource: Sendable {
    let trackID: CanonicalTrackID
    let representationID: RepresentationID
    let kind: RepresentationKind
    let endpointLocator: EndpointMediaLocator
    let metadata: PlaybackMetadata
}
```

Initial priority for owned media:

1. Available SMB representation reachable by selected Sonos household.
2. Available local replica when using local-device playback.
3. No playable source -> typed error.

Do not encode future streaming priority until those services exist.

### PlaybackCoordinator

Owns application playback intent and orchestration.

Responsibilities:

- Accept play track/album/queue requests using canonical IDs.
- Ask SourceResolver for playable sources.
- Convert resolved sources into endpoint queue items.
- Execute endpoint commands.
- Apply pending/confirmed/failed command lifecycle to PlaybackStore.
- Refresh endpoint state after commands.
- Detect and report partial queue construction.

Does not:

- Perform SOAP directly.
- Query SwiftUI selection state.
- Store credentials.

### PlaybackStore

Authoritative state model:

```swift
@MainActor
final class PlaybackStore: ObservableObject {
    @Published private(set) var selectedHouseholdID: HouseholdID?
    @Published private(set) var selectedEndpointID: EndpointID?
    @Published private(set) var zones: [ZonePlaybackSnapshot] = []
    @Published private(set) var activeQueue: PlaybackQueueSnapshot?
    @Published private(set) var pendingCommand: PendingPlaybackCommand?
    @Published private(set) var issue: PlaybackIssue?
}
```

`ZonePlaybackSnapshot` includes:

- endpoint and group identity.
- transport state.
- canonical track ID when matched.
- display metadata.
- position and duration.
- volume and mute.
- members and coordinator.
- availability.
- last confirmation timestamp.

Only PlaybackCoordinator and endpoint-state reducers may mutate the store.

### EndpointDriver

Protocol seam:

```swift
protocol AudioEndpointDriver: Sendable {
    var kind: EndpointKind { get }
    func discover(in household: HouseholdID) async throws -> EndpointTopology
    func state(for endpoint: EndpointID) async throws -> EndpointPlaybackState
    func execute(_ command: EndpointCommand) async throws -> EndpointCommandResult
}
```

`SonosEndpointDriver` wraps existing ZoneDiscoveryService, SOAP helpers, queue loading, share registration, and topology parsing during migration. The first goal is not a rewrite; it is to place a stable boundary around proven Sonos behavior.

### HouseholdContext

Owns:

- active HouseholdID.
- available households.
- mapping of library sources and endpoint systems to households.
- persisted user selection.

No global zone selection may substitute for household identity.

## 3. Persistence model

### Existing tables retained initially

- households.
- devices.
- stations.
- zone_state.
- genres and station joins.
- library_sources.
- artists.
- albums.
- tracks.
- artist_albums.
- track_artists.
- scan_skips.
- folder_stats.

### Additive canonical tables

Recommended migration names and purpose:

```sql
CREATE TABLE music_artists (...);
CREATE TABLE music_albums (...);
CREATE TABLE music_tracks (...);
CREATE TABLE track_representations (...);
CREATE TABLE legacy_track_map (...);
```

Minimum `track_representations` fields:

- id TEXT PRIMARY KEY.
- track_id TEXT NOT NULL.
- source_id TEXT NOT NULL.
- household_id TEXT NULL.
- kind TEXT NOT NULL.
- locator TEXT NOT NULL.
- normalized_locator TEXT NOT NULL.
- file_size INTEGER NULL.
- modified_at DATETIME NULL.
- duration REAL NULL.
- availability TEXT NOT NULL.
- last_verified_at DATETIME NULL.
- UNIQUE(source_id, normalized_locator).

Do not remove existing `tracks.filePath` in the first release. Map it to a representation and migrate call sites incrementally.

## 4. Correctness changes required in current implementation

### Scanner upsert

Current risk: SMBScanner creates new UUIDs and writes Track records while the database primary key is `id` and uniqueness is tied to `filePath`. Repeated full scans can collide, fail silently, and leave joins stale.

Required behavior:

1. Normalize source-relative file path.
2. Lookup existing track/representation by `(sourceID, normalized path)`.
3. Reuse existing ID when present.
4. Upsert track and joins in one transaction.
5. Propagate all failures.
6. Mark FolderStat complete only after commit.

### Migration recovery

Replace automatic database deletion with:

- migration backup.
- migration error log.
- recovery state.
- explicit rebuild command only for rescan-safe data.

### Credentials

Move SMB username/password to Keychain. `library_sources` stores a credential reference, not the secret.

### Playback metadata advancement

Remove the rule in PlaybackContextService that pins local album context to the first track until idle. Each endpoint position/metadata update must reconcile to the current queue item and update PlaybackStore.

### Polling

Remove polling from NowPlayingView. One playback-state pipeline owns polling and command-triggered refresh.

### Command results

Replace fire-and-forget `Void` command helpers with typed results and failures.

## 5. Concurrency model

- MainActor: PlaybackStore, screen models, SwiftUI bindings.
- Scanner actor: SMB traversal and metadata extraction.
- Endpoint discovery/polling actor: network loops and topology refresh.
- Repository/database: GRDB writer transactions; no long network operations inside transactions.
- PlaybackCoordinator: actor or isolated service; emits store updates on MainActor.

## 6. UI architecture

PassioneUI contains visual primitives and theme only. SorrivaMusicUI contains reusable music screens and screen models. SorrivaApp and Lumvara provide shells, navigation integration, and product-specific surfaces.

Initial migration order:

1. Zones + mini-player.
2. Now Playing.
3. Library shell.
4. Album and artist detail.
5. Search and queue.

The in-house release may use existing visuals while these state boundaries are installed.
