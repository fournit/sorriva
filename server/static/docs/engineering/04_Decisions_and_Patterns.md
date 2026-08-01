# 04 — Sorriva Architecture Decisions and Approved Patterns

## ADR-001 — Sorriva owns the music platform

Status: Accepted.

Decision: Shared music-domain, library, playback, and endpoint code belongs to the Sorriva platform. Lumvara composes it through a host layer.

Consequence: No independent Lumvara music engine.

## ADR-002 — Sorriva is standalone

Status: Accepted.

Decision: Core operation requires no cloud service, backend server, or Lumvara appliance.

Consequence: Local persistence, scanning, discovery, and control remain complete in the standalone composition.

## ADR-003 — NAS/external storage is canonical for owned media

Status: Accepted.

Decision: Device downloads are replicas. Track identity is not based on the phone or tablet copy.

## ADR-004 — Canonical track identity is separate from representation

Status: Accepted.

Decision: A logical track has one CanonicalTrackID and one or more TrackRepresentations.

Consequence: SMB path uniqueness identifies a representation, not music identity.

## ADR-005 — PlaybackStore is authoritative

Status: Accepted.

Decision: All playback presentation reads from PlaybackStore. Endpoint updates and commands reduce into it.

Consequence: Remove direct playback polling and local state caches from views.

## ADR-006 — Source resolution occurs at playback time

Status: Accepted.

Decision: UI and queues carry canonical IDs. SourceResolver chooses a representation when preparing endpoint playback.

## ADR-007 — Endpoint drivers are music-agnostic

Status: Accepted.

Decision: Drivers consume endpoint commands and media locators. They do not browse albums or resolve artists.

## ADR-008 — Existing Sonos mechanics are wrapped, not rewritten

Status: Accepted.

Decision: Preserve SOAP, topology parsing, grouping, x-file-cifs playback, and queue behavior while introducing a driver boundary.

## ADR-009 — Additive migration

Status: Accepted.

Decision: Canonical tables are added beside current tables. Existing Track/Album/Artist rows remain during migration.

## ADR-010 — Keychain owns secrets

Status: Accepted.

Decision: LibrarySource stores credential references only. SMB passwords are migrated to Keychain.

## ADR-011 — One composition root

Status: Accepted.

Decision: SorrivaAppEnvironment constructs long-lived services and stores. Views do not fetch global services.

## ADR-012 — Packages follow capabilities, but package extraction is timed

Status: Accepted.

Decision: Establish logical boundaries immediately. Split Swift packages only after APIs stabilize; avoid package churn during correctness work.

## Approved implementation patterns

### Pattern A — Screen interaction

```text
SwiftUI View
 -> ScreenModel
 -> Application Service
 -> Repository or Coordinator
```

Views may format layout and forward user intent. They do not query GRDB or call endpoint protocols.

### Pattern B — Playback command

```text
View
 -> ScreenModel
 -> PlaybackCoordinator
 -> PlaybackStore pending state
 -> SourceResolver
 -> EndpointDriver
 -> Endpoint refresh
 -> PlaybackStore confirmed/failed state
```

### Pattern C — Endpoint state update

```text
Discovery/Poller Actor
 -> EndpointPlaybackState
 -> PlaybackStateReducer
 -> PlaybackStore
 -> all playback UI
```

### Pattern D — Library scan

```text
SMBScanner
 -> DiscoveredMediaFile batch
 -> FolderReconciler
 -> single database transaction
 -> scan result
```

### Pattern E — Legacy migration seam

```text
Legacy database row
 -> LegacyMusicMapper
 -> canonical domain object
```

Compatibility mapping is temporary. New application APIs use canonical IDs.

### Pattern F — Typed failure

Do not return Boolean or Void when recovery depends on the reason. Use enums with associated context and preserve the underlying error in diagnostics.

### Pattern G — Optimistic command

1. Record pending command with correlation ID.
2. Apply only safe optimistic presentation changes.
3. Execute command.
4. Confirm from endpoint state.
5. Roll back or mark issue on timeout/failure.

### Pattern H — Household scoping

Every source and endpoint lookup receives HouseholdID explicitly. Persisted selected zone is subordinate to selected household.

## Prohibited patterns

- New business-logic singletons.
- Direct GRDB access from SwiftUI.
- Endpoint SOAP calls from views.
- File paths as public track IDs.
- Duplicate playback timers.
- `try?` around critical persistence.
- Automatic destructive database reset.
- Storing SMB password in SQLite.
- Lumvara imports in reusable music modules.
- Building future provider abstractions with no current caller.
