# Sorriva — Authoritative PlaybackStore Design (Implementation Spec)

**Date:** 2026-08-03 · **Status:** agreed with Tom, ready to implement phase-by-phase
**Companion to:** `HANDOFF-playbackstore-architecture.md` — read that first for the
problem history and the list of *rejected* patches (do not re-propose them).

This document is the spec the PlaybackStore work is built against. It is
**design-gated**: the model is agreed, but the items in §13 are still open and
must be confirmed with Tom before the relevant phase begins. Working discipline
from the architecture handoff carries forward: diagnose → propose exact change →
explicit confirmation → code; one file at a time; verify against a real repro,
not reasoning.

---

## 1. Problem

`PlaybackStore` is **read-only / purely derived**. It has no authoritative "this
zone is now playing X" declaration. It merges two upstream sources that drift
apart — `PlaybackContextService.contexts` (the app's inferred memory) and
`ZoneDiscoveryService.zones` (what Sonos reports) — with **no provenance** on any
field. This is the root cause of the live "ghosts": wrong current/previously-
playing track, wrong artwork, zones not updating. Full chronology and the
confirmed root cause are in the architecture handoff §2–3.

## 2. Core principle — split content-truth from transport-truth

`SonosZone` today conflates two kinds of truth across ~19 write sites with no
marker for which is which:

| Content truth (WHAT is playing) | Transport truth (HOW/WHERE) |
|---|---|
| track, artist, album, stationName, artwork, currentTrackURI | isPlaying, volume, elapsedSeconds, durationSeconds, idleState, groupMembers |
| App resolves (Sonos often can't) | Sonos owns; polling reports it |

The redesign separates them: **content becomes *declared*; transport stays
*polled*.** The reducer combines them each tick — content from declarations,
transport from `SonosZone`.

## 3. Authority boundary — the safety guarantee

- **Sonos is authoritative for the URI and all transport state.** `GetPositionInfo`
  / `GetMediaInfo` return `CurrentURI` reliably (even when the title is empty).
  Polling **stays** and is load-bearing — every tick reports the current URI +
  transport.
- **The app is authoritative for resolving that URI into display metadata**
  (name/artist/album/artwork) — because Sonos frequently can't (empty stream
  titles; never has local album/art).
- **INVARIANT (the guarantee against wrong info):** resolved metadata is
  displayed **only while its URI matches the URI Sonos currently reports.** On
  mismatch it is invalidated. The old code let `stationName` float free of any
  URI — that is exactly why it showed stale names; binding to the URI removes
  the failure mode.

The app never claims a zone is playing something Sonos doesn't confirm by URI.

## 4. The declaration

`PlaybackDeclaration` = today's `PlaybackContext` payload
(track/artist/albumName/duration/artAlbum/artURL/isLocal) **plus the three
things it currently lacks**:

- `uri: String` — the content URI this metadata resolves; the reconciliation key.
- `source: .app | .external` — provenance.
- `declaredAt: Date` — recency.

**Owned by `PlaybackStore`** (fulfils I-002 / ADR-005 — the store becomes the
single authority for content truth). Local playback already declares via
`setLocalContext` / `setLocalQueue`; **generalise that existing pattern** to
station/transfer/group/ungroup. `PlaybackContext` is promoted into the
declaration payload.

## 5. Reconciliation / precedence rule (the reducer)

Per zone, let `D` = its declaration, `U` = `zone.currentTrackURI`:

1. `D.source == .app` and `U == D.uri` → **use D. Polling cannot override.**
2. `D.source == .app`, `U != D.uri`, within the grace window → **keep D**
   (a poll landed before Sonos caught up to our command).
3. `D.source == .app`, `U != D.uri`, past grace → the zone genuinely moved:
   - `U` maps to a known local-queue item → **advance D** (still app content).
   - else → **invalidate D**; external detection produces an `.external`
     declaration.
4. `D.source == .external` → use it; freely replaceable by any app declaration
   or newer poll.
5. no `D` → external detection derives content from polling.

**Transport fields (isPlaying/volume/elapsed/idle/group) always come from
`SonosZone`, every tick, regardless of `D`.**

## 6. No-blank rule (Tom's requirement)

An actively-playing zone **never renders empty content**. When a declaration is
invalidated, the store **holds the last-known content until the replacement
resolves, then swaps atomically** — it never emits the intermediate blank.

- **Local queue advances have no gap** — the whole queue is pre-fetched
  (`localQueues`), so the next track's metadata is ready before the swap.
- **Sonos `TRANSITIONING` transport state** is treated as "keep last," never blank.
- This is a **reducer rule, not a poll-frequency setting** — do not slow polling
  to hide the blank. An optional minimum content dwell (N seconds) is
  belt-and-suspenders, kept decoupled from poll cadence.

## 7. Module responsibilities after the change (de-aggregation)

| Module | Owns | Loses |
|---|---|---|
| `PlaybackStore` | declared content truth + reducer + declaration API | — |
| `ZoneDiscoveryService` | transport/topology facts + Sonos I/O | content writing |
| `PlaybackContextService` → **detector** | external-change detection + local-queue advance; emits declarations | primary content authority |
| Action functions | Sonos I/O, then declare | raw field mutation |

## 8. Caller audit — what must change

### A. Actions that must DECLARE (currently mutate raw fields)

- **`persistStationPlay`** (`ZoneDiscoveryService.swift:1033`) → declare
  `{name, art, uri = streamURL, .app}` instead of poking `stationName` etc.
  (mutations at `:1038-1061`). Callers: `IHeartServiceView.swift:191`,
  `LibraryView.swift:495`, `SomaFMServiceView.swift:167` (each after the static
  `playStationURL`).
- **`transferPlayback`** (`:1626`) → **move the source zone's declaration to the
  destination** (by URI/content), mark source stopped. **Delete** the optimistic
  field copy (`:1643-1653`) — that copy is what propagated the stale pair.
  Caller: `TransferZoneSheet.swift:107`.
- **`groupZone`** (`:1466`) → members **project the coordinator's declaration**.
  Callers: `ZonesView.swift:687`, `PlaybackCoordinator.swift:119`.
- **`ungroupZone`** (`:1593`) → clear/retain declaration appropriately. Callers:
  `ZonesView.swift:341`, `PlaybackCoordinator.swift:141`.
- **`playStation`** (`:1014`) / static `playStationURL` (`:1085`) → declare.
  Callers: `ContentView.swift:51,89`.
- **Local play** — `setLocalContext` / `setLocalQueue`
  (`PlaybackContextService.swift:367,386`) already declare; **reroute through the
  new store API** (behaviourally identical).

### B. Poll/fetch write sites to DEMOTE to transport-only (stop writing content)

- `fetchTransportStates` content clears (`:467-470`), stationName/logo (`:526-528`).
- `fetchAllStationMetadata` (`:766-770`).
- `updateZoneFromPositionInfo` content (`:893,951-954,987-988`) + HDMI clears
  (`:875-879`).
- `restoreZoneStateFromDB` (`:728-732`) → becomes a **declaration source on
  launch** rather than a field write (see §13 open decision on its `source`).

These keep writing transport fields (isPlaying/elapsed/duration/idle/volume/
groupMembers).

### C. Side-channels to retire (Phase E)

- `stationNameURI` staleness hack (`SonosZone` `:2080`) — subsumed by
  declaration URI-binding.
- content-grace `playingUntil` — subsumed by `declaredAt` + grace window.
- The topology-merge manual field re-apply (`:334-353`) — once content leaves
  `SonosZone`, the "field added but not listed in the merge silently resets"
  trap disappears for content fields.

## 9. Phasing — each independently verifiable, behaviour changes only from B

- **A. Primitive + precedence, no behaviour change.** Add `PlaybackDeclaration`,
  the `declare()` store API, and the §5 precedence rule + §6 no-blank rule in the
  reducer. Route the *existing* local declarations through it.
  *Verify:* local play + queue advance unchanged, no blank.
- **B. Station-play + transfer through declarations; delete optimistic copies.**
  *Verify (headline repro):* Living Room → Master Bedroom → Living Room shows the
  correct current content on Living Room, not the pre-transfer "Bossa Beyond."
- **C. Group / ungroup declarations** (members project coordinator).
  *Verify:* grouping a playing zone shows correct shared content; ungroup keeps
  the coordinator's.
- **D. Demote polling to transport-only + shrink the heuristic to external-only.**
  Stop poll paths writing content; `handleZoneUpdate`'s 4-case logic handles only
  changes the app didn't cause.
  *Verify:* change content on the physical Sonos app → app reflects it within a
  poll interval, no wrong name; confirm no content is written by any poll path.
- **E. Retire side-channels; align `zone_state` persistence to declarations.**
  *Verify:* no code path can leave a stale `stationName` behind.

## 10. Verification repros (keep these as the regression set)

- **Round-trip transfer** (B) — the headline bug.
- **Queue-advance no-blank** (A/B) — a local album advancing never blanks.
- **External change** (D) — physical Sonos app change reflected, no wrong name.
- **Empty-title station** (B) — a stream Sonos returns an empty `<dc:title>` for
  still shows the app-known name via the declaration.

## 11. ZoneDiscoveryService decomposition — after the store is stable

`ZoneDiscoveryService` (~103KB) does far too much. Its teardown comes **after**
this work, not before or in parallel — Phase D already extracts content as the
first cut, exposing the seams (discovery/topology · transport-poll · action-I/O ·
persistence) for a later, separate decomposition.

## 12. Future substrate — Sonos GENA (`fSonosEventSubscriptions`)

Push instead of poll (see roadmap + architecture handoff §7). Swaps in behind the
same transport interface after the teardown; **not a prerequisite** for this work.

## 13. Open decisions — confirm with Tom before the relevant phase

1. **Exact declaration API** — signature, name, and whether it's a method on
   `PlaybackStore` directly. (Phase A.)
2. **Grace-window constant** — one explicit value to replace the ad-hoc 5–6s.
   (Phase A.)
3. **`restoreZoneStateFromDB` on launch** — declare as `.app`, or a distinct
   `.restored` source with its own precedence? (Phase D.)
4. **"Previously playing"** — the code has no notion of it today; the design
   supports it (retain last declaration with a stopped flag). In scope or parked?
5. **Confirm start at Phase A** and the A→E order.
