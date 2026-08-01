# 05 — Sorriva Status and Roadmap

## Current product state

v0.0.51. Scanner architecture items 1-6 built and verified, and the first
full-library scan has run end to end. Seven-day
reliability gate running but due to be restarted — see below. fScannerPolish
substantially advanced. Zone discovery restart loop fixed and verified.

## 2026-07-31 — first full-library scan, and what it exposed

Ground truth taken from the mounted share first: **11,670 audio files across
562 folders**. The scan reported exactly those numbers.

| Phase | Result | Time |
|---|---|---|
| Walk + filter | 562 folders, 11,670 files — exact match | 16s |
| Header pass | 11,231 tracks, 439 skipped, 0 write failures | 3h 03m |
| Embedded art | 475/561 | 14m |
| Folder art | 63/561 | 4.5m |
| Retry | 419 of 439 skips recovered | 8m |
| **Rescan, nothing changed** | 11,670 tracks, all skipped | **16.9s** |

Zero `NWError 12` across roughly 11,700 connections — the strongest available
confirmation that the `session.disconnect()` fix holds at scale, given the
ceiling is 512. Zero walk retries: one connection survived all 562
`listDirectory` calls, so item 6 is built but still unexercised.

`bTagEditsNotDetected` was finally verified with a real Mp3tag edit, through
both the manual scan and the foreground change check.

### The question nobody could answer

After the retry scheduler hung and was relaunched, its queues eventually read
as empty — with no log line saying the 20 outstanding tracks and 5 albums had
been processed. They had not been. `resetArtworkPassMarkers` zeroes
`embeddedArtFailed`, which is the exact column the artwork retry queue selects
on, so any scan touching those folders silently empties the queue rather than
working it. The 20 tracks remain unexplained.

**That uncertainty is the real defect.** The app cannot say what it intended to
import versus what actually landed, which means it cannot tell a user *which*
tracks are missing — or that anything is missing at all. An album showing 12
tracks looks like a 12-track album.

The design that fixes it is `fScanSessionLedger` (Critical), specified in
`HANDOFF-scan-session-ledger-2026-07-31.md`: record the plan at scan start,
write every outcome against it with a session id and a reason, and treat the
session as incomplete until every planned row is terminal. Retry becomes part
of the session rather than a parallel actor. The audit is then arithmetic, and
any unaccounted row names the exact file.

Two features follow from it: a human-readable report written to the share after
each session (the only place a user without a second machine can reach a file),
and a Library Management tool that lists failures by album and retries them in
place.

### Also measured

The 15s header read timeout cost **110 minutes of the 3h03m header pass** — 439
timeouts, roughly 60% of runtime. At 5s it would have been ~37 minutes. Held
deliberately until the retry work lands, since the correct value depends on
failures carrying a reason. The skip rate also drifted upward through the run
(2.8% over files 900–1400, 5.5% by 2100), which may indicate the NAS degrading
under sustained load.

## 2026-07-30 — unified scan model (handoff items 1-5)

The full/incremental split is gone. One primitive now serves manual scan,
automatic foreground scan and resume: walk the tree, skip folders whose
stored fingerprint still matches (file count + total bytes + newest
modification time), scan the rest. Resume adds one extra condition — the
folder must also carry the resumed session's stamp.

Measured on a 104-file share: initial scan 37s, immediate rescan 0.6s with
everything skipped. Extrapolated to the real 13.5k library, a rescan that
previously re-read every header for roughly two hours becomes a directory
walk plus an in-memory comparison.

What this closed:

- `bNewFoldersNotDetected` — the old change detection iterated
  `folder_stats` rather than the disk, so a newly added folder had no row,
  was never checked, and never appeared until a manual rescan. Walking the
  disk fixes it structurally: absence of a stat means "scan it", never
  "skip it".
- Deletion reconciliation — folders removed from the NAS previously left
  their tracks and stats behind forever.
- `bArtworkPassNotResumable` — all three artwork passes are now
  marker-driven, with markers reset only for the folders actually being
  scanned. A rescan touching two folders re-evaluates two albums instead
  of every album in the source, and an interrupted artwork phase resumes
  rather than restarting.
- `fScanSessionLogCorrelation` — SCAN, ARTWORK and RETRY lines now carry
  the run's session id, so one search covers an entire scan including any
  kills and resumes.

Six pre-existing bugs surfaced during verification and were fixed:
the debug log rotated itself away on every launch (destroying evidence at
exactly the moment it mattered), `updateScanComplete` wrote scanState
'idle' before the artwork passes ran, the Scan Incomplete alert was bound
to a publisher that never fired, the new change check launched overlapping
scans across sources, never-scanned shares began importing themselves on
foreground, and read-failure skip records were batched to the end of a scan
and lost on interruption.

NOT VERIFIED: the modification-time change-detection direction. An
unchanged folder correctly skips, but nothing has confirmed that a changed
mtime with identical file size triggers a rescan. This is the entire basis
for `bTagEditsNotDetected`, and it matters more than it used to — a manual
rescan used to re-read every header, which was the de facto workaround for
retagging, and the unified model removes that. Test: `touch` a file over
SMB without changing content, then rescan.

Remaining from the handoff: item 6 (walk-connection resilience at 10k
scale), item 7 (share-overlap validation and absorb), item 8 (retry
scheduler circuit breaker).

## Git status — RESOLVED 2026-07-30

Current: `a43080e` on `main`, pushed to `origin/main`. Working tree clean.
Note two commits carry the version string v0.0.49 (`d398080` and `3d00c18`)
for different work — see `bVersionNumberDriftBetweenRepoAndState`. This
session took v0.0.50 rather than rewriting history.

This section previously asserted that the last confirmed push was v0.0.41
and framed it as the top-priority blocker. That was wrong, and the way it
was wrong is worth recording.

Checking `git log` in the laptop clone at `~/projects/sorriva-app` showed
HEAD at v0.0.36 with a clean tree, which read as a much larger backlog. It
was not: that clone is deliberately stale and had never fetched, so its
`origin/main` pointer was six versions behind reality. The Mini — the
actual working copy, where all scp'd Swift lands and all builds run — was
at v0.0.47 committed, with `origin/main` already there too.

So there was no push backlog. Only the working tree was uncommitted:
v0.0.48 (scan resume, pipeline watchdog, session.disconnect teardown) and
v0.0.49 (zone discovery loop, network-scoped cache), committed together as
`d398080` and pushed.

Two lessons: a stale clone's `origin/main` is not evidence about the
remote, and this doc carried an unverified claim forward across several
sessions until it was checked. State the position or state that it is
unknown; do not restate a stale number.

Known cosmetic issue: pushing from the Mini over SSH emits
`failed to store: -25308` (`errSecInteractionNotAllowed`) from
git-credential-osxkeychain. There is no unlocked GUI login keychain in an
SSH session, so the credential cannot be cached; it is read from
`~/.git-credentials` instead and the push succeeds. Harmless unless it
starts prompting.

## 2026-07-27 — two zone-grouping bugs found and fixed (unrelated to scanner work)

- Topology-fetch race condition: fetchTopology had six independent call
  sites with no concurrency guard. Grouping the same zone twice in quick
  succession could let a stale fetch complete after a newer one and
  silently overwrite correct group state with wrong data. Fixed with a
  single topology-refresh coordinator — at most one fetch in flight,
  concurrent requests coalesce into one guaranteed follow-up.
- Full topology replacement wiping live zone state: fetchTopology's
  `zones = parsed.sorted{...}` reset every OTHER field (station info,
  current track, position, volume, grace period) to bare defaults on every
  single refresh, not just during grouping — invisible for an idle zone,
  visibly blipped any actively-playing zone. Fixed by merging fresh
  topology into existing zones instead of replacing wholesale.

Both logged and closed under bGroupingUIStaleForExtendedPeriod.

## fScannerPolish — bArtworkSelectionNotBestWins COMPLETE

Full best-wins redesign: v15 migration (albums.artworkWidth/Height),
ImageDimensionReader (header-only PNG/JPEG parsing), ArtworkBestWins (pure,
testable selection logic), embedded pass reordered first, folder pass
always does a cheap header-check regardless of what embedded found, online
fetch reverted to gap-filling-only after real-world testing found it
overwriting correct artwork with wrong iTunes matches.

Real-world testing (not just unit tests) surfaced and fixed 3 genuine bugs
in the new code before closing this out:
1. Folder pass hung indefinitely after a connection timeout — no reconnect
   logic in the new header-check step, and the download-timeout reconnect
   had been lost in the same rewrite. Both fixed.
2. Embedded pass stopped at the first track with any art instead of
   checking all up-to-3 tracks and keeping the best. Real case: Pat Metheny
   "We Live Here" saved a 200×200 image while track 2 had 1280×1280.
3. Online fetch overwriting CORRECT existing artwork with WRONG iTunes
   matches — not compilation-specific, also hit single-artist "Greatest
   Hits"-style albums. Root cause: iTunes's weak matching plus zero
   relevance verification on our end, made newly dangerous by this
   redesign since online fetch could now overwrite anything below the
   ceiling, not just fill empty slots. Reverted to gap-filling-only as the
   immediate safe fix. bArtworkArtistQuery's stale diagnosis corrected
   (query has always included artist name). New record
   fArtworkManualSearchUtility logged for the proposed long-term fix — a
   human-in-the-loop multi-source search utility rather than trying to
   perfect automated matching.

10 new tests (ArtworkSelectionTests).

## Two more real bugs found and fixed, same session

- bEmbeddedArtRetryNeverResolves — same bug class as an earlier scan_skips
  fix. The "no art in file" retry branch cleared the wrong flag
  (embeddedArtScanned, not embeddedArtFailed, which is what the retry
  queue actually checks), so a confirmed negative result retried forever
  instead of ever resolving. Fixed.
- bFailedReadCreatesWrongAlbumFromFallback — a failed tag read still fell
  through to buildTrack with empty data, letting fillFromPath's folder-name
  fallback create a wrong album (unstripped "Various Artists - " prefix)
  from a transient NAS timeout. Worse: a later successful retry of the
  same file never corrected the album it had already wrongly created,
  since retry only ever updates a track's own row. Fixed per Tom's
  structurally correct proposal: a failed read now only ever produces a
  skip record, never a track/album from empty data — whichever read
  succeeds first (this pass or on retry) defines the album.

## fScannerPolish remaining

- bDuplicateAlbumDetection, bTagEditsNotDetected — not started.
- fScanFailureUtility — reclassified OUT of fScannerPolish (it's new
  feature surface area, not a scanner correction). Own record, Extended
  phase.

## Known, logged, not yet investigated

- bScanConnectionExhaustionOnRepeatedScans — the underlying NAS connection-
  drop pattern responsible for several of today's read timeouts. Still not
  root-caused at the network level, only worked around (reconnect logic,
  the empty-fallback fix). Worth real investigation.
- fArtworkManualSearchUtility — new, not started.
- fArtworkPassTestSeam, fScannerDatabaseInjection — future test-seam work.
- bLocalQueueContextAdvanceTestFlaky — unrelated pre-existing flaky test.
- bCanonicalIdentityBackfillStale — WP-12 backfill should be re-run.

## Test coverage

45 tests passing / 1 intentionally failing (documents a known, deferred
FLAC limitation) / 1 pre-existing unrelated flaky test.

## Next coding session — as of 2026-07-27 (superseded)

FIRST: commit and push everything since v0.0.41 to git — this did not
happen before this session closed. Then: run a fresh, complete library
scan with all of today's fixes active and confirm the "12 Inch Dance 80s
Remix (CD 2)" album (and similar) now resolve correctly. Continue
fScannerPolish (bDuplicateAlbumDetection or bTagEditsNotDetected), or
investigate bScanConnectionExhaustionOnRepeatedScans properly.

## 2026-07-28 — Gate-readiness audit + fresh-chat handoff documents

A full, honest audit was done of what's actually verified vs merely marked
"done" in the roadmap, prompted by a direct question ("did you go through
all the WP packages?") that correctly caught an initial assessment that was
based on a pre-filtered subset, not a full pass. Full results in
HANDOFF-gate-readiness-assessment.md. Headline findings:

- Most recently-completed items are genuinely solid (re-verified via fresh
  reproduction after the fix). A few are fixed-but-not-yet-re-confirmed.
- The connection-leak fix underneath the whole scanner (in
  MediaSourceReader.swift) is deployed but has NOT been stress-tested under
  any real load yet — this is the single most important open verification
  gap, since it sits underneath every scan operation. Tom's own plan:
  test at current library size, then deliberately push past ~512 files.
- A full roadmap pass (not just the pre-filtered list used in the first
  assessment attempt) surfaced two previously-unconnected, High-priority
  open items: bMissingTracksInAlbum (a real, live bug — some albums show
  only one track when the NAS folder holds a full album — with a newly-
  discovered interaction with bFailedReadCreatesWrongAlbumFromFallback,
  see that record for detail) and bScannerTestSeam (precisely scoped: 2
  specific scanner behaviors in the older ScannerTests.swift have zero
  verification against the real production scan path, not a blanket
  concern about all 16 tests in that file).

Three standalone handoff documents were created, each self-sufficient for
a fresh Claude session with zero prior context: HANDOFF-scanner-hardening.md,
HANDOFF-playbackstore-architecture.md, HANDOFF-gate-readiness-assessment.md.
These exist because the PlaybackStore station-name bug went through several
rounds of targeted-but-insufficient patches this session (Tom's framing:
"whack-a-mole," "bandaids on top of bandaids") before the actual
architectural gap was correctly diagnosed — the goal of these documents is
to prevent that pattern from repeating by carrying the full reasoning
trail forward, not just conclusions.

**PlaybackStore architecture — real, unresolved, and the most important
open conversation right now, separate from the scanner/gate work above.**
Tom's diagnosis, confirmed against real code: the UI read side is already
correctly unified (all four surfaces read from PlaybackStore's snapshot,
verified directly). The write side is not — actions like transfer/group/
station-play mutate raw zone fields and leave PlaybackContextService to
infer intent afterward via heuristics, instead of stating intent directly.
This is the root cause of the whole station-name saga. Agreed direction,
NOT yet designed in detail: every zone-mutating action should end with an
explicit, authoritative "here's what's playing now" declaration; the
existing heuristic case-matching should shrink to only handling externally-
initiated changes (something outside Sorriva changed a zone's playback),
not double as the primary path for the app's own actions. Full detail,
including what's genuinely undecided, in HANDOFF-playbackstore-architecture.md.
Do not start implementation without first discussing the exact shape of
the declaration mechanism.

## Next coding session — as of 2026-07-28 (superseded)

Three clear directions exist, roughly independent of each other:
1. Scanner/NAS reliability — stress-test the connection fix, investigate
   bMissingTracksInAlbum, port the 2 at-risk scanner tests. See
   HANDOFF-scanner-hardening.md.
2. PlaybackStore architecture — design and scope the authoritative-
   declaration refactor with Tom before writing code. See
   HANDOFF-playbackstore-architecture.md.
3. Decide explicitly whether the 7-day reliability gate clock should
   restart, given the gap between what it's measuring and what's actually
   been stress-tested. See HANDOFF-gate-readiness-assessment.md.

## 2026-07-30 — Zone discovery restart loop (first iPad launch)

First launch on iPad went into an unbounded discovery loop. Debug export:
145,126 lines across 122 seconds, six distinct messages, 48,374 identical
cycles at roughly 400 per second. Zero zones ever discovered.

**Cause.** `NWPathMonitor` invokes `pathUpdateHandler` immediately on
`start()`, not only on change. The monitor was created inside
`startDiscovery()` and cancelled by `stopDiscovery()`, which closed a
cycle: start -> satisfied callback -> `handleNetworkRestored()` ->
`stopDiscovery()` (nils `serviceBrowser`, clearing the re-entry guard) ->
`startDiscovery()`. The `NetServiceBrowser` was destroyed roughly every
2.5ms, well before Bonjour could resolve a service, so `zones` never
populated and the loop's own exit condition was never reachable. Nothing
was wrong with the network or with Local Network permission — discovery
had simply never been allowed to finish once.

**Why iPhone never hit it.** The zone cache. Cached zones filled `zones`
on the first pass, so `handleNetworkRestored()` took the poll branch
instead. The defect was reachable only on a device with no cache — that
is, any first install. Worth carrying forward as a general lesson: a cache
was silently masking a Critical defect on the only device being tested.

**Fixed.** Network monitor and both `NotificationCenter` observers moved
to `init` as service-lifetime concerns rather than per-discovery ones;
`stopDiscovery()` no longer cancels the monitor; transition-into-satisfied
detection added so only a real network change triggers rediscovery; 10s
restart floor added, bypassed when discovery is not running so it can
never wedge discovery shut. Also fixed in the same pass: both observers
were re-registered on every `startDiscovery()` call and never removed,
leaking approximately 96,700 live observers over the captured session.

**Diagnostics.** The `NetServiceBrowser` and resolve delegate callbacks
used `print()`, not `sLog()`, so Bonjour behaviour was entirely absent
from the debug export. That is why the first analysis pass could not
distinguish "restart loop" from "Local Network permission denied" without
a second export. All five delegate callbacks now use `sLog()`. General
rule: any diagnostic that would be needed to triage a field report must go
through `sLog()`, or it does not exist.

**Zone cache rescoped in the same pass.** The cache was network-agnostic —
a single flat UserDefaults key — so carrying the device to a different
Sonos system would restore home topology onto it. Now keyed by IPv4 subnet
via new file `NetworkIdentity.swift` (`getifaddrs`, CIDR form, no
entitlements and no permission prompts), and validated against the Sonos
household ID from `GetZoneGroupAttributes` once real topology arrives; on
mismatch the entry is discarded and rewritten from the live system.
`syncTopologyToDB` now returns the live household ID and the cache write
moved to after it, so the household is known at write time. The legacy
flat key is deleted on sight and never read.

Subnet keys collide across locations sharing a common private range
(192.168.1.0/24 in two different homes is commonplace). The household ID
is what actually resolves that; the subnet is only a fast-path hint. The
default gateway was evaluated as an additional key component and rejected:
within a given subnet the gateway is almost always x.x.x.1, so it adds no
entropy in the exact collision case it was intended to fix, at the cost of
a fragile NET_RT_DUMP routing-table walk. Residual failure mode is
cosmetic — briefly showing the wrong zone names before topology replaces
them — and self-correcting.

**Verified on device.** Loop gone. Zones discovered promptly on first
launch. Instant restore on relaunch, with discovery still running behind
it and replacing the restored set when real topology lands.

Logged as `bZoneDiscoveryRestartLoop` (bug, Critical, closed) and
`fNetworkScopedZoneCache` (feature, closed). `fMultiHouseholdScoping`
opened: user-owned state — library sources, favorites, presets, persisted
zone state — is still global and should probably scope per household for
anyone with more than one Sonos system. The household ID is already
persisted and validated, so the join key exists; the open questions are
which entities scope per-household and whether a friendly household name
is surfaced in settings. Distinct from `fHouseholdProfiles`, which is
multi-profile support within a single account.

New file: `NetworkIdentity.swift` (swift-config.json now 75 files).

## Roadmap hygiene — noted, not actioned

A pass over `roadmap-data.json` while adding the records above surfaced
pre-existing drift, left untouched because it was outside the scope of
this session:

- `fXFileCIFS`, `fAlbumSplitInvestigation`, and `fScannerIdentityIntegrity`
  are closed but still carry `priority_rank`. Schema requires removing it
  on close.
- `fSonosDiscovery` has its full `desc` duplicated into `name`, so it
  renders as a truncated paragraph in the Hub list view.

## Next coding session

1. Git is current as of v0.0.49 (`d398080`, pushed). Nothing outstanding.
2. Scanner/NAS reliability — stress-test the connection fix, investigate
   `bMissingTracksInAlbum`, port the 2 at-risk scanner tests. See
   HANDOFF-scanner-hardening.md.
3. PlaybackStore architecture — design and scope the authoritative-
   declaration refactor with Tom before writing code. See
   HANDOFF-playbackstore-architecture.md.
4. Decide explicitly whether the 7-day reliability gate clock should
   restart, given the gap between what it measures and what has actually
   been stress-tested. See HANDOFF-gate-readiness-assessment.md.
5. Confirm `Info.plist` declares `NSLocalNetworkUsageDescription` and lists
   `_sonos._tcp` under `NSBonjourServices`. Discovery worked on 2026-07-30,
   but undeclared Bonjour types fail intermittently rather than loudly.
