# 01 — Sorriva AI Engineering Constitution

## Authority and audience

This file is the highest-authority engineering instruction set for Sorriva. Its primary consumers are ChatGPT, Claude, and future coding agents. The human product owner controls product direction, priorities, acceptance, and release decisions. AI agents own implementation design, coding, testing, migrations, diagnostics, and code review within the constraints below.

When instructions conflict, use this precedence:

1. Explicit current instruction from the product owner.
2. This Constitution.
3. Architecture.md.
4. Decisions.md.
5. Implementation_Plan.md.
6. Current repository behavior.

Do not reinterpret settled product direction unless the product owner explicitly reopens it.

## Product mission

Build Sorriva as a complete, local-first music product that works independently in a home without a backend server or Lumvara appliance. Build the same music platform so Lumvara can host and present it without creating a second music engine.

The immediate release objective is an in-house daily-driver product using the current capabilities: owned music on NAS/SMB storage, local library browsing, Sonos discovery and control, queue playback, Now Playing, artwork, metadata, zones, grouping, and existing radio functions.

## Non-negotiable product principles

### P-001 — Standalone first
Sorriva must remain fully functional without Lumvara, a cloud service, or a backend server.

### P-002 — One music platform
Sorriva owns the reusable music platform. Lumvara composes and hosts it. Do not duplicate music domain, library, playback, queue, or endpoint logic inside Lumvara.

### P-003 — Canonical owned library
The normal canonical owned library resides on NAS, SMB, or external storage. A mobile-device copy is an offline replica, not the primary identity of the track.

### P-004 — Ship in months
Prefer the smallest durable architecture that supports current capabilities and known product direction. Do not build speculative service integrations or generalized frameworks before they are needed.

### P-005 — Prove architecture through the product
Structural changes required by the target architecture should be implemented in the in-house build. Do not postpone foundational corrections merely to preserve existing structure.

## Architectural invariants

### I-001 — Canonical music identity
Every logical track has one canonical identity independent of its storage path or service representation. Physical paths, downloaded copies, and streaming-service references are representations of the track.

### I-002 — One playback-state owner
PlaybackStore is the sole owner of application playback state. Views, screen models, endpoint drivers, and services may observe or submit events; they must not maintain competing authoritative playback state.

### I-003 — Views do not access infrastructure
SwiftUI views must not read or write GRDB, SMB, SOAP, HTTP, Keychain, or discovery APIs directly.

Required flow:

```text
View -> ScreenModel -> Application Service -> Domain/Repository/Driver
```

### I-004 — MusicDomain is pure
MusicDomain may depend on Foundation. It must not import SwiftUI, GRDB, SMB libraries, Sonos types, HTTP server types, UIKit, or application services.

### I-005 — Endpoint drivers are protocol adapters
Endpoint drivers understand endpoint operations and capabilities: load, play, pause, seek, queue URI, volume, mute, grouping, topology, and transport state. They do not own artist, album, playlist, search, favorites, or library semantics.

### I-006 — Source resolution is late
UI and application services request playback by canonical track identity. SourceResolver chooses a playable representation only when preparing playback for a selected endpoint.

### I-007 — Scanner discovers; importer reconciles
SMBScanner discovers media files and extracts technical/tag metadata. Reconciliation/import logic maps discovered media to canonical music entities and representations. Scanner traversal must not become the canonical identity engine.

### I-008 — Additive persistence migration
Schema evolution is additive by default. Migration failure must never silently delete the database. Destructive rebuild requires explicit user action or an intentionally approved recovery path.

### I-009 — No silent critical failures
Do not use `try?` where failure can corrupt library state, queue state, migrations, credentials, or playback correctness. Errors must be propagated, logged with context, and reflected in user-visible status where action is needed.

### I-010 — UI is replaceable
The planned PassioneUI redesign must not require rewriting scanner, library, domain, playback coordination, or endpoint drivers.

### I-011 — Existing proven code is retained when sound
Default to wrap, extract, or adapt existing scanner, GRDB, Sonos SOAP, queue, artwork, and retry code. Replace only where correctness or architecture requires replacement.

### I-012 — Household context is explicit
Household/property context must not be inferred from a globally selected Sonos device. Library sources, endpoint discovery, availability, and playback selection must be scoped through an explicit HouseholdID.

## Scope controls for the in-house release

Included now:

- Stable SMB source configuration and scanning.
- Correct repeat scans and incremental scans.
- Library browsing by albums, artists, and tracks.
- Artwork extraction and caching.
- Sonos discovery, topology, grouping, volume, transport, queue loading, and transfer.
- Correct Now Playing metadata and progress.
- Existing radio features.
- Recoverable failures and operational logging.
- Structural foundation: AppEnvironment, PlaybackStore, screen models, application services, endpoint-driver seam, canonical identity seam.

Deferred until explicitly promoted:

- Apple Music, Qobuz, and Tidal.
- BluOS.
- Cloud synchronization.
- Multi-user profiles.
- AI semantic search and recommendations.
- Voice assistants.
- Remote access services.

## Engineering operating rules

1. Read these five engineering documents before changing architecture.
2. Inspect the current implementation before proposing replacement.
3. Work in dependency order defined in Implementation_Plan.md.
4. Every change must include a completion test or acceptance check.
5. Keep compatibility shims temporary and named as such.
6. Update Status_and_Roadmap.md after each completed work package.
7. Add or amend an ADR when a permanent boundary changes.
8. Never create a second playback state cache to solve a UI issue.
9. Never expose SMB credentials outside the credential provider.
10. Never couple Lumvara types into reusable music modules.

## Definition of done for an engineering work package

A package is done only when:

- The code compiles for the supported target.
- The named regression test or manual acceptance check passes.
- Error behavior is defined.
- No prohibited dependency is introduced.
- Temporary migration code is documented.
- Status_and_Roadmap.md records the result and next dependency.
