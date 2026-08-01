# 03 — Sorriva Implementation Plan

## Objective

Transform the current codebase into the target architecture while preserving current capability and reaching a stable in-house daily-driver release quickly.

## Work-package rules

- Complete packages in dependency order.
- Each package must compile before the next begins.
- Do not combine correctness fixes with broad UI redesign.
- Temporary adapters must be named `Legacy...Adapter` or documented in Status_and_Roadmap.md.

## WP-01 — Baseline and safety net

Affected files:

- Sorriva.xcodeproj.
- SorrivaDatabase.swift.
- SMBScanner.swift.
- LocalPlaybackService.swift.
- ZoneDiscoveryService.swift.
- PlaybackContextService.swift.

Tasks:

1. Create a test target.
2. Add a disposable database factory.
3. Add fixtures for one source, two albums, duplicate scan, changed metadata, and deleted file.
4. Add structured log categories: database, scan, playback, discovery, credentials.
5. Record a baseline build and manual smoke test.

Acceptance:

- Test target runs locally.
- Existing app launches and performs a scan/playback smoke test.

## WP-02 — Fix scanner identity and persistence errors

Affected files:

- SMBScanner.swift.
- SorrivaDatabase.swift.
- DatabaseModels.swift.
- ScanCoordinator.swift.

Implementation:

1. Add database method `track(sourceID:normalizedFilePath:)`.
2. Normalize all scanned paths once.
3. Reuse existing Track.id during rescans.
4. Replace scan-path `try?` writes with thrown errors.
5. Reconcile TrackArtist and ArtistAlbum joins deterministically.
6. Put each folder reconciliation in one GRDB transaction.
7. Update FolderStat only after successful transaction.
8. Report failed file/folder counts in ScanReport.

Tests:

- Full scan twice leaves identical row counts and IDs.
- Metadata change updates the existing track.
- Deleted file is removed on changed-folder reconciliation.
- Failed write does not mark folder complete.

## WP-03 — Safe migration recovery

Affected files:

- SorrivaDatabase.swift.
- SettingsView.swift or new RecoveryView.

Implementation:

1. Remove automatic database deletion after migration failure.
2. Copy database and WAL/SHM files to a timestamped backup before migration.
3. Persist a recovery diagnostic.
4. Start in read-only/recovery mode when migration cannot complete.
5. Provide explicit rebuild action for rescan-safe data.

Acceptance:

- Forced migration failure preserves original database.
- User receives actionable recovery state.

## WP-04 — Keychain credential storage

Affected files:

- DatabaseModels.swift.
- SorrivaDatabase.swift.
- AddSMBSourceView.swift.
- SMBScanner.swift.
- LocalPlaybackService.swift.
- new CredentialStore.swift.

Implementation:

1. Define `CredentialStore` protocol.
2. Implement KeychainCredentialStore.
3. Add credentialRef to LibrarySource.
4. Migrate existing username/password values to Keychain.
5. Clear plaintext values after verified migration.
6. Resolve credentials only at SMB connection/share-registration boundaries.

Tests:

- Add/edit/delete source manages Keychain item.
- Existing source migration retains connectivity.
- Database contains no plaintext password.

## WP-05 — Fix playback metadata correctness

Affected files:

- PlaybackContextService.swift.
- LocalPlaybackService.swift.
- ZoneDiscoveryService.swift.
- MiniPlayerView.swift.
- NowPlayingView.swift.

Implementation:

1. Stop pinning first-track local context until idle.
2. Match endpoint queue metadata/URI to current Track or representation.
3. Update metadata on each queue transition.
4. Make `observe()` idempotent.
5. Add an explicit unmatched-external-media fallback.

Tests:

- Play three-track album; metadata advances 1 -> 2 -> 3.
- Pause/resume does not reset metadata.
- External Sonos playback displays endpoint metadata.

## WP-06 — Consolidate playback polling

Affected files:

- ZoneDiscoveryService.swift.
- NowPlayingView.swift.
- ContentView.swift.

Implementation:

1. Remove `startPolling()` and direct GetPositionInfo calls from NowPlayingView.
2. Centralize polling in the playback state pipeline.
3. Add command-triggered immediate refresh.
4. Apply adaptive interval: faster while playing/visible, slower while idle/backgrounded.
5. Back off individual endpoints on repeated network failure.

Acceptance:

- One poller exists.
- Now Playing progress remains responsive.
- Leaving/re-entering Now Playing does not create extra timers.

## WP-07 — Introduce AppEnvironment

New files:

- SorrivaAppEnvironment.swift.

Affected files:

- SorrivaApp.swift.
- ContentView.swift.
- service singleton call sites.

Implementation:

1. Construct database, credentials, scanner, discovery, playback, and repositories in one environment.
2. Inject environment/store objects at root.
3. Leave legacy singleton shims only where immediate conversion is unsafe.
4. Prohibit new singleton references.

Acceptance:

- App has one composition root.
- Zones and Now Playing operate from injected dependencies.

## WP-08 — Introduce PlaybackStore

New files:

- PlaybackStore.swift.
- PlaybackModels.swift.

Affected files:

- ZoneDiscoveryService.swift.
- PlaybackContextService.swift.
- ContentView.swift.
- ZonesView.swift.
- MiniPlayerView.swift.
- NowPlayingView.swift.

Implementation:

1. Define snapshots and pending-command state.
2. Reduce endpoint state into PlaybackStore.
3. Move selected household/endpoint to store or HouseholdContext.
4. Convert views to read store only.
5. Deprecate presentation state owned by ZoneDiscoveryService and PlaybackContextService.

Acceptance:

- Zones, mini-player, and Now Playing render from the same snapshot.
- No duplicated authoritative playback state remains.

## WP-09 — Typed Sonos command boundary

New files:

- AudioEndpointDriver.swift.
- SonosEndpointDriver.swift.
- EndpointModels.swift.

Affected files:

- ZoneDiscoveryService.swift.
- LocalPlaybackService.swift.

Implementation:

1. Wrap current Sonos implementation without rewriting protocol mechanics.
2. Define typed EndpointCommand and EndpointCommandResult.
3. Return typed failures: timeout, SOAP fault, unavailable endpoint, topology changed, unsupported capability, partial queue.
4. Route playback commands through the driver.
5. Keep discovery parsing and share registration behind the driver boundary.

Tests:

- Mock driver can run PlaybackCoordinator tests.
- Partial AddURIToQueue failure is surfaced.
- Topology change triggers refresh/retry policy.

## WP-10 — PlaybackCoordinator and command lifecycle

New files:

- PlaybackCoordinator.swift.
- PlaybackIntent.swift.

Implementation:

1. Accept play track/album and transport intents.
2. Set pending state in PlaybackStore.
3. Resolve sources.
4. Execute driver commands.
5. Confirm through endpoint refresh or roll back with PlaybackIssue.
6. Add queue progress/cancellation.

Acceptance:

- UI receives pending, confirmed, and failed states.
- Partial queues are not reported as success.

## WP-11 — LibraryRepository and LibraryService

New files:

- LibraryRepository.swift.
- GRDBLibraryRepository.swift.
- LibraryService.swift.

Affected files:

- AlbumsView.swift.
- ArtistsView.swift.
- TracksView.swift.
- AlbumDetailView.swift.
- LibraryView.swift.

Implementation:

1. Move new GRDB reads behind repository methods.
2. Convert one vertical slice: Albums -> AlbumDetail.
3. Add screen models.
4. Continue until views contain no direct dbQueue/database query logic.

Acceptance:

- Album browse and detail operate through service/repository.
- No new direct DB calls in views.

## WP-12 — Canonical identity and representations

New files:

- MusicDomain IDs/models.
- migration for music_tracks and track_representations.
- LegacyMusicMapper.swift.

Implementation:

1. Add canonical tables additively.
2. Backfill one canonical track for each existing Track.
3. Backfill SMB representation using sourceID + normalized path.
4. Add legacy ID mapping.
5. Change playback request API to CanonicalTrackID.
6. Preserve existing UI using compatibility mapping until migrated.

Acceptance:

- Existing library is fully mapped.
- Playback starts from CanonicalTrackID.
- File paths are not used as application-level identity.

## WP-13 — SourceResolver

New files:

- SourceResolver.swift.
- PlayableSource.swift.

Implementation:

1. Resolve canonical track to available SMB representation for selected household/endpoint.
2. Produce endpoint-neutral locator.
3. Sonos driver converts locator to x-file-cifs URI.
4. Return typed no-source and unreachable-source failures.

Acceptance:

- Album and track playback no longer construct SMB paths in views/application services.

## WP-14 — In-house release hardening

Tasks:

- Sonos topology candidate failover.
- Rediscovery after network changes.
- Idempotent NAS share registration and verification.
- Scan cancellation/resume.
- Diagnostics export.
- Background/foreground recovery.
- Performance profiling for large libraries.

Release gate:

- Seven consecutive days of in-house use without database rebuild.
- Repeat scans are idempotent.
- Album metadata advances correctly.
- Network/NAS/Sonos interruptions recover without relaunch where feasible.
- Critical failures produce actionable diagnostics.

## WP-15 — UI redesign

Begin only after the in-house release gate.

Order:

1. PassioneUI tokens/components.
2. Product shell and navigation.
3. Zones and mini-player.
4. Now Playing and queue.
5. Library, album, artist, tracks.
6. Search.

Business services and state stores remain unchanged during this wave.
