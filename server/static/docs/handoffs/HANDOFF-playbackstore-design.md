# Sorriva — Authoritative PlaybackStore Design (Implementation Spec)

**Date:** 2026-08-03 · **Updated:** 2026-08-04
**Status:** **phases A and B built and device-tested; C, D, E remain**
**Companion to:** `HANDOFF-playbackstore-architecture.md` — read that first for the
problem history and the list of *rejected* patches (do not re-propose them).

This document is the spec the PlaybackStore work is built against. The model held
up in implementation and is no longer design-gated — every open item in §13 was
resolved during phases A and B. **Start at §9 for what is built and §14 for what
implementation actually taught us**, then pick up at phase C. Working discipline
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

- **A. ✅ BUILT 2026-08-04.** Primitive + precedence, no behaviour change. Added
  `PlaybackDeclaration`, the `declare()` store API, and the §5 precedence rule +
  §6 no-blank rule in the reducer. Existing local declarations routed through it.
  *Verified:* local play + queue advance unchanged, no blank.
- **B. ✅ BUILT 2026-08-04.** Station-play + transfer through declarations;
  optimistic field copies deleted. **Scope grew during implementation** to include
  last-playing ownership (§14.1) and per-service station identity (§14.2), both at
  Tom's direction, because the headline repro could not be closed without them.
  *Verified:* round-trip transfer carries artwork, station name, track and artist;
  a station started in the Sonos app resolves in Sorriva after one poll; idle zones
  show what they last played, across an app relaunch.
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

## 13. Open decisions — ALL RESOLVED during phases A and B

1. **Exact declaration API** — ✅ resolved. Methods on `PlaybackStore` directly:
   `declare(zoneID:context:uri:source:)`, `moveDeclaration(from:to:)`,
   `clearDeclaration(zoneID:)`.
2. **Grace-window constant** — ✅ resolved. `PlaybackStore.declarationGrace = 5`,
   one named constant replacing the ad-hoc 5–6s values.
3. **Launch restore source** — ✅ resolved. Restored entries are marked
   `.external`, not `.app`, so they can never win the grace window. A restored
   declaration is a *memory* of what played, not an assertion about right now;
   marking it `.app` would let a stale memory outrank live polled state for five
   seconds after every launch.
4. **"Previously playing"** — ✅ resolved, and IN SCOPE — Tom's decision, verbatim:
   *"1. never expires. 2. previous state of all zones survive app relaunch."*
   Built in phase B; see §14.1.

---

## 14. As-built notes — what implementation taught us

The model survived contact with the device. These are the things the design did
not anticipate, kept here because each one cost real debugging time.

### 14.1 Last-playing is the store's job, and it changed the reducer

The store holds `lastDeclarations` alongside `declarations`, written by the same
`declare()` call and persisted to `zone_last_playing` (schema v20). An idle zone
renders its last declaration; this is why a stopped zone shows what it played
rather than blank. Restored at launch for every zone, marked `.external` per §13.3.

### 14.2 Station identity belongs to the service, not to a shared heuristic

Phase B originally used one global URI normaliser. It accumulated an exception per
service and each new provider re-broke the previous ones — iHeart rotates a session
token per poll, SomaFM load-balances across mirrors (ice1/ice2/ice4) and appends a
bitrate slug. Tom stopped it: *"instead of trying to make a global rule set against
all radio stations we need code for each service so it is handled exactly as it
needs to be."* Now `RadioServiceAdapter` per provider + `RadioServiceRegistry`,
with generic normalisation only as a last resort for unclaimed URIs. **Adding a
service is a new file.** See `engineering/radio-service-integration.md`.

### 14.3 `dc:title` means something different per service — never trust it as a name

iHeart returns a filename (`hls.m3u8`), SomaFM a stream slug
(`groovesalad-128-aac`), Sonos Radio the *track* title. The stations table is the
only reliable source of a station's name; `dc:title` is a fallback at best. The
open bug `bSonosRadioTitleShownAsStation` is the residue of this.

### 14.4 Two code paths answering one question WILL diverge

Idle and playing zones had separate station-resolution implementations. Every fix
applied to one left the other broken — the symptom was two zones on the same
stream showing different names. They now share one `stationDisplay(for:)`. Treat a
second implementation of an existing question as a defect, not a convenience.

### 14.5 Never cache a negative result without an expiry

A failed station lookup was cached permanently in memory, so one miss stranded a
zone until the app was force-quit. The tell is a bug that "self-heals on relaunch"
— that means in-memory state, and a cache is the first place to look. Misses now
expire after 30s.

### 14.6 Transfers briefly park the destination on a `x-rincon:` group address

For ~2s mid-transfer the destination reports a *speaker* address, not a stream.
Anything that pattern-matches URIs must exclude `x-rincon:` alongside
`x-rincon-queue:` and `x-file-cifs://`, or it will act on an address that can
never identify content.

### 14.7 Verify the transport actually started

A wedged zone accepts `SetAVTransportURI`, reports the new track, updates artwork
— and does not play. `Stop` before `SetAVTransportURI` clears it;
`verifyPlaybackStarted` reads `GetTransportInfo` after `Play` and logs whether the
zone truly entered PLAYING. This cost three wrong theories before raw-SOAP testing
found it. **Do not diagnose playback from what the UI reflects back.**
5. **Confirm start at Phase A** and the A→E order.
