# Sorriva — PlaybackStore / Zone State Architecture Handoff

## How to use this document

This is a complete context transfer for continuing work on Sorriva's zone
playback state architecture. Read this entire document before doing
anything else. It documents a sequence of increasingly-targeted fixes that
each addressed a real symptom but not the root architectural cause — Tom
explicitly identified this pattern as "whack-a-mole" and "bandaids on top
of bandaids," and was right to. **Do not repeat this pattern.** The
individual fixes below are real and should not be reverted, but the next
work on this topic should be the actual architectural fix, not another
targeted patch.

Working style established across this project, carry it forward:
- Diagnose → propose exact change → get explicit confirmation → write code.
  Do not write code before confirmation on anything non-trivial, and
  especially not on this topic given the pattern above.
- One file at a time, deliver only what changed, with one `iosdeploy so`
  command. Never re-present unchanged files.
- When corrected, actually update the mental model — don't just apologize
  and continue with a slightly-adjusted version of the same wrong
  assumption. This document exists partly because that discipline slipped
  during this arc; don't repeat it.
- Read real source code / real log evidence before proposing a fix. Verify
  a fix against real reproduction, not just logical reasoning about what
  should happen.

Repo: github.com/fournit/sorriva | Mini: ~/projects/sorriva-app/
Deploy: `iosdeploy so <files>` | Commit: `gitops`

Key files: `ZoneDiscoveryService.swift` (raw Sonos zone state + all action
functions: transfer, group, ungroup, play station, etc.),
`PlaybackContextService.swift` (derives `PlaybackContext` from raw zone
state via 4-case pattern matching), `PlaybackStore.swift` (combines
`SonosZone` + `PlaybackContext` into `ZonePlaybackSnapshot`, the single
object all UI surfaces read from).

---

## TL;DR — current state

- **Read side of the architecture is already correct and should NOT be
  changed.** All four UI surfaces (ZonesView, MiniPlayerView, NowPlayingView,
  ZonePickerSheet) correctly read `albumName`/track info from
  `store.snapshot(for:)` — verified directly against source, not assumed.
  `PlaybackStore` genuinely is the single read-path for all UI. This part
  of Tom's target architecture already exists.
- **Write side is the actual, confirmed root cause of repeated bugs.**
  `PlaybackStore`'s snapshot is only as correct as `PlaybackContext`, which
  is *inferred after the fact* by `PlaybackContextService`'s four-case
  heuristic logic (URI prefix checks, `isPlaying` flags, timestamp-based
  staleness) — rather than being *told directly* by whatever action
  (transfer, group, play station, etc.) just happened. The action functions
  in `ZoneDiscoveryService` mutate low-level `SonosZone` fields and leave
  downstream code to guess what that means.
- **Several real, narrower bugs in this area were found and fixed this
  session** (topology race condition, state-wiping-on-refresh, multiple
  attempts at station-name staleness). These are documented in full below
  because they're real fixes worth keeping — but none of them are the
  actual architectural fix, and the station-name staleness problem in
  particular is NOT fully resolved (see section 4).
- **The actual next step is a scoped architectural refactor**, not another
  targeted patch. See section 5 for the agreed direction and section 6 for
  what's still undecided.

---

## 1. Two real, confirmed-fixed bugs in `ZoneDiscoveryService.fetchTopology` (unrelated to the staleness saga — keep these, don't touch)

These were found and fixed earlier in this session, are solid, and are NOT
part of the whack-a-mole pattern described below — they're genuine,
narrowly-scoped concurrency/data-integrity bugs with clean fixes.

### 1a. Topology-fetch race condition
`fetchTopology` had six independent call sites (discovery, foreground/
network-restored, group, ungroup, transfer) with no concurrency guard.
Network responses aren't guaranteed to arrive in request order — grouping
the same zone twice in quick succession could let an older, now-stale
fetch complete AFTER a newer one and silently overwrite correct group state
with wrong data. This also explained an earlier-reported symptom: a zone
grouping appeared correct in Sonos but stayed wrong in the UI for roughly
an hour before self-correcting (self-correction happened via the next
explicit trigger event — likely an app foreground — since nothing
re-fetches topology on a regular timer, only on these explicit trigger
events).

**Fix:** a single topology-refresh coordinator
(`requestTopologyRefresh`/`runTopologyRefreshLoop`). At most one fetch is
ever in flight; if a new refresh is requested while one is running, it
doesn't fire a duplicate — it coalesces into a single guaranteed follow-up
once the current one finishes. This was Tom's own proposed design
(queue-and-coalesce), which is better than the first proposal (cancel-and-
always-fire-newest, which still wastes a request most of the time). All 5
external trigger points route through this coordinator now;
`tryNextCandidate`'s internal host-failover retry (a different concern —
nested within one coordinated fetch, not a competing top-level request)
correctly still calls `fetchTopology` directly.

### 1b. Full topology replacement wiping live zone state on every refresh
`fetchTopology`'s success path did `zones = parsed.sorted { ... }` —
unconditionally replacing every zone's entire struct with a freshly-parsed
one on every single refresh, not just during grouping. `TopologyParser`
only ever sets `id`/`name`/`host`/`isPlaying: false`/`volume: 0`/
`idleState`/`groupMembers` — every OTHER field (station info, current
track, position, volume, grace period timestamps) reset to bare defaults
every time. Invisible for an already-idle zone with nothing to lose,
visibly blipped any actively-playing zone's now-playing info to blank
before several separate async steps (`fetchTransportStates`,
`fetchAllStationMetadata`, `restoreZoneStateFromDB`) restored it moments
later.

**Fix:** merge fresh topology into existing zones instead of replacing
wholesale — for each zone matched by id, preserve `isPlaying`, `volume`,
`stationName`, `stationLogoURL`, `currentTrack`, `currentArtist`,
`currentTrackURI`, `elapsedSeconds`, `durationSeconds`, `dbDeviceId`,
`playingUntil` from the previous state; only `idleState`/`groupMembers`/
`name`/`host` are taken fresh (topology is the authoritative source for
those specifically).

Both of these are done, verified via real reproduction, and should not
need revisiting unless new evidence specifically implicates them again.

---

## 2. The station-name staleness saga — full chronology, read this before touching the topic again

### The original symptom
A zone would show the wrong station name/artwork after a transfer — e.g.,
"Bossa Beyond" displayed on a zone that was actually playing "Alternative
Rewind." Track/artist info updated correctly; specifically the station
name and artwork did not, and did not self-correct on zone-card refresh,
app relaunch, or waiting.

### Attempt 1 — URI-pairing staleness check (real fix, but incomplete on its own)
Added `stationNameURI` to `SonosZone` — tracks which URI the current
`stationName` was actually resolved against. Set wherever `stationName` is
set (`fetchAllStationMetadata`, `restoreZoneStateFromDB`), preserved
alongside `stationName` in the topology-merge fix above. In
`PlaybackContextService`'s Case 3 (actively playing), station
name/artwork are only trusted if `stationNameURI` matches the zone's
current URI — otherwise displayed as empty rather than stale.

**This is a real, defensible safety net and should not be reverted** — it
prevents ever confidently displaying a station name that's known to belong
to different content than what's currently playing. But Tom correctly
identified it does NOT fix the underlying problem: it can only make stale
data display as blank, it cannot produce the correct name out of thin air
when neither the app nor Sonos has it available.

### Direct verification of an external constraint (important, keep this in mind for any future work here)
Queried Sonos directly (bypassing the app entirely) via raw SOAP —
`GetMediaInfo` against the affected zone while a real iHeart stream was
actively and correctly playing:
```
<CurrentURI>hls-radio://http://stream.revma.ihrhls.com/zc6950/hls.m3u8</CurrentURI>
<CurrentURIMetaData>...<dc:title></dc:title>...
```
**Sonos itself returns a completely empty title for this stream, despite
it playing correctly.** This is a real, confirmed, external constraint —
not something fixable in Sorriva's code. Any future design must account
for Sonos legitimately not always providing a name after the fact.

### Attempt 2 — persistStationPlay + transferPlayback optimistic copy (real fix for the ORIGINAL repro, but see Attempt 3 for why it's insufficient in general)
Reasoning: since Sonos can't be relied upon to reliably tell us a station's
name after the fact, the app should rely on what it already knows itself
at the moment of action, instead.
- `persistStationPlay` (called when a user directly selects a station from
  the iHeart/SomaFM/Library browsers) now also receives the actual stream
  URL as a parameter and pairs it with `stationNameURI` (and optimistically
  sets `currentTrackURI` too) at the exact moment the app tells Sonos to
  play it — this is the one moment the app reliably knows both the name and
  the URL together, rather than waiting for a later poll to independently
  converge on the same URL.
- `transferPlayback` now optimistically copies the SOURCE zone's
  `stationName`/`stationNameURI`/`stationLogoURL`/`currentTrackURI`/
  `currentTrack`/`currentArtist` to the DESTINATION zone at the start of a
  transfer — reasoning: a transfer doesn't change WHAT is playing, only
  WHERE, so the destination should inherit the source's already-correct
  info directly rather than waiting on Sonos to (unreliably) re-confirm it
  for the new zone.

### Attempt 2 confirmed to fail on a more complete repro — the actual reason this needs real architecture, not another patch
Tom's test: transfer a currently-playing stream from Living Room to Master
Bedroom, then transfer it back from Master Bedroom to Living Room. Living
Room still showed "Bossa Beyond" (a stale name from BEFORE either transfer,
unrelated to the actual content) after the round trip.

**Root cause of why Attempt 2 didn't hold, worked out via direct
questioning from Tom, not independently found:**
1. The URI-staleness check (Attempt 1) only ever *hides* a stale name at
   display time — it never actually clears the underlying `stationName`
   field. So even when the UI correctly showed nothing for a zone, the
   stale text was often still sitting in `zone.stationName` underneath,
   simply masked.
2. `transferPlayback`'s optimistic copy (Attempt 2) copies `stationName`
   AND `stationNameURI` TOGETHER, as a matched pair, from source to
   destination. If the source zone's own `stationName` field still held
   old stale text (masked by its own staleness check, never actually
   cleared), the copy faithfully propagated that stale pair to the new
   zone — and because both values arrive together as an internally
   consistent pair, the destination's OWN staleness check sees them as
   "fresh" (they match each other), even though the underlying name is
   still wrong. The mismatch that Attempt 1 was designed to catch never
   had a chance to fire, because the copy recreated a self-consistent but
   wrong pair rather than an actually-empty one.
3. **No code path anywhere in the system ever writes an empty string into
   `stationName` when Sonos confirms there's genuinely no name for new
   content.** All four places that touch `stationName`
   (`fetchAllStationMetadata`, direct station selection, DB restore, the
   transfer copy) only ever SET it to something or leave it untouched —
   none of them CLEAR it. `fetchAllStationMetadata` specifically has a
   deliberate `if !name.isEmpty` guard (correctly avoiding overwriting good
   data with blank data on a normal poll) — but the side effect is that
   once a zone has a stale name, nothing in the system is responsible for
   ever invalidating it, only for potentially replacing it with something
   better if one happens to come along.

**Conclusion: Attempt 2 built a way to hide stale data (Attempt 1) and a
way to copy data faithfully (Attempt 2) — but never built the piece that
actually invalidates data at its source when Sonos confirms there's
genuinely nothing there.** This is confirmed, not theoretical — traced
through the actual code and the actual repro sequence together with Tom.

---

## 3. Tom's architectural diagnosis (agreed, confirmed against real code — this is the actual problem statement for the next session)

Direct framing from Tom, confirmed correct: **all logic about what is
playing and where should live in one place — the store — and every
function that can change media in any zone (transfer, group, ungroup,
start a station, start local play) needs to inform the store directly,
rather than mutating low-level fields and leaving the store to guess.**

Verified against real code, precisely:
- **Read side: already correct, do not change.** `ZonesView`,
  `MiniPlayerView`, `NowPlayingView`, and `ZonePickerSheet` were each
  checked directly — all four read station/track display info from
  `store.snapshot(for:).albumName`, not from raw `discovery.zones` data.
  (`ZonePickerSheet` does reference `discovery.zones` in two places, but
  only for building the zone list itself and an "is anything playing
  anywhere" button-enable check — structural uses, not display of what's
  playing. Not a violation.)
- **Write side: the actual gap.** `PlaybackStore`'s snapshot is built by
  `PlaybackStateReducer` combining `SonosZone` (raw, mutated directly by
  action functions) with `PlaybackContext` (inferred AFTER THE FACT by
  `PlaybackContextService`'s four-case heuristic matching on URI patterns,
  `isPlaying` flags, and timestamps). The action functions in
  `ZoneDiscoveryService` — `transferPlayback`, `groupZone`, `ungroupZone`,
  `playStation`/`persistStationPlay`, and presumably local-play functions
  in `LocalPlaybackService` (not yet audited) — never make an authoritative
  "this zone is now playing X" declaration. They mutate fields; downstream
  code infers intent.

This fully explains the whole chronology in section 2: every fix added was
another attempt to make the INFERENCE smarter (a new field here, a copy
there) rather than eliminating the need for inference by having actions
state their intent directly.

---

## 4. What's still open / genuinely unresolved right now

- **The round-trip transfer repro is NOT confirmed fixed.** Attempt 2 is
  known-insufficient per section 2. No further patch has been applied
  since that diagnosis — the architectural conversation started instead,
  per Tom's explicit direction ("I'm tired of chasing all these issues over
  and over again... let's fix this correctly").
- Any album/zone that received wrong station info from earlier bugs in
  this saga may still have stale data sitting in the database
  (`zone_state` table) — not audited for cleanup.
- `LocalPlaybackService`'s local-play code path has not been checked
  against the same "does it authoritatively declare state or just mutate
  fields" question — assume it has the same shape of problem until
  verified otherwise.

---

## 5. Agreed direction for the actual fix (design not yet started in detail)

- Every zone-mutating action function should end with one explicit,
  authoritative call that declares the zone's new playback state as a
  complete, atomic fact — not a raw field mutation for downstream code to
  interpret via pattern-matching.
- `PlaybackContextService`'s four-case heuristic logic should shrink to
  handling ONLY externally-initiated changes — i.e., detecting playback
  that Sorriva did not itself cause (someone used the physical Sonos app,
  a schedule, a voice assistant) — via polling. It should not be the
  primary path for the app's own actions; those should already have stated
  their intent directly by the time this logic would otherwise have to
  guess.
- Topology/transport polling remains necessary (for the externally-
  initiated case above) but should be treated as a lower-priority fallback
  signal — it should never override a state an action just explicitly and
  recently declared, only fill in for changes the app didn't cause itself.
- Every existing caller of transfer/group/ungroup/station-play/local-play
  needs auditing once the new authoritative-declaration mechanism exists,
  to confirm each one actually uses it rather than the old field-mutation
  path.

## 6. What's genuinely undecided, needs to be worked out with Tom before writing code

- The exact shape/signature of the "authoritative declaration" call —
  what data it carries, where it lives (a method on `PlaybackStore`
  directly? A new intermediary?), and how it interacts with the existing
  `PlaybackContext`/`ZonePlaybackSnapshot` types.
- How to prevent the fallback polling path from fighting with a just-
  declared authoritative state — needs an explicit precedence/recency rule,
  not just "hope polling doesn't run at a bad time" (which is roughly the
  failure mode of the current architecture).
- Whether this is one large refactor or can be sequenced action-by-action
  (e.g., fix `transferPlayback`'s declaration first since it has the clearest
  real repro, then extend the pattern to group/ungroup/station-play) —
  Tom has not indicated a preference yet; worth asking directly rather than
  assuming.
- Full scope/file list has not been enumerated — `LocalPlaybackService`
  and its callers have not yet been read at all in this context and need a
  first pass before any design commitment.

**Do not start writing code on this until the shape of the declaration
mechanism has been explicitly discussed and confirmed with Tom.** This
document exists precisely because that discipline slipped on this topic
before — treat that as the one hard rule carried forward.

---

## 7. Design confirmed (2026-08-03) + the transport substrate it should sit on

The section-5/6 design was worked through with Tom and **agreed**. Confirmed
shape (a dedicated phased design doc will follow; this is the summary):

- **Split content-truth from transport-truth.** Sonos is authoritative for the
  URI (what is playing) and transport state (isPlaying/volume/elapsed/idle/
  group) via polling, which stays. The app is authoritative for resolving that
  URI into display metadata (name/artist/album/artwork) — because Sonos often
  cannot (empty stream titles; no local album/art).
- **URI-binding is the safety guarantee:** resolved metadata is displayed ONLY
  while its URI matches the URI Sonos currently reports; on mismatch it is
  invalidated. This is what prevents the wrong-info bugs — the old code let
  `stationName` float free of any URI.
- **Declarations** live on `PlaybackStore` (fulfils I-002): today's
  `PlaybackContext` plus `{uri, source: .app/.external, declaredAt}`. Local play
  already declares (`setLocalContext`); generalise to station/transfer/group/
  ungroup.
- **No-blank rule (Tom's requirement):** an actively-playing zone never renders
  empty content — hold last-known until the replacement resolves, then swap
  atomically. This is a reducer rule, NOT a poll-frequency setting.
- **Phasing:** A) declaration primitive + precedence rule (no behaviour change)
  → B) route station-play + transfer through it, delete optimistic field-copies
  (fixes the round-trip-transfer repro) → C) group/ungroup → D) demote polling
  to transport-only + shrink the heuristic to external-only → E) retire the
  side-channels (`stationNameURI`, content-grace `playingUntil`).
- **ZoneDiscoveryService decomposition** (it does far too much) comes AFTER the
  store is stable — the store work extracts content as the first cut.

### The transport substrate: Sonos GENA event subscriptions (roadmap `fSonosEventSubscriptions`)

The design above runs on polling and is correct on polling. But the *right*
long-term substrate is **Sonos GENA (UPnP General Event Notification
Architecture) event subscriptions** — push instead of poll. The app SUBSCRIBEs
to each speaker's `AVTransport`/`RenderingControl` services and Sonos pushes an
HTTP `NOTIFY` to an in-app callback (the existing `SorrivaHTTPServer`) the
instant transport/track/volume changes. This near-eliminates the external-change
staleness window and the poll-interval latency, with far less network traffic.

**Had GENA been known at design time, the transport layer would have been built
on it from the start** (Tom, 2026-08-03). It is deliberately sequenced as a
future tightening AFTER the PlaybackStore rearchitecture is stable and
ZoneDiscoveryService is decomposed — at which point poll→push can be swapped in
behind the same transport interface without changing anything above it. It is
NOT a prerequisite for the declaration work. Tracked as `fSonosEventSubscriptions`
(Phase 4) so it is not lost.
