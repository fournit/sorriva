# 05 — Sorriva Status and Roadmap

## Current product state

v0.0.45 (locally deployed, NOT YET PUSHED to git — see below). Seven-day
reliability gate running. fScannerPolish substantially advanced.

## CRITICAL: git push status

Last confirmed git push was v0.0.41 (ID3v2 embedded-art fix). Everything
below — the topology coordinator, both grouping fixes, the full artwork
best-wins redesign, the folder-pass hang fix, the embedded multi-track fix,
the online-fetch revert, the embedded-art retry-loop fix, and the scanner
empty-fallback fix — is deployed to the device and locally correct, but has
NOT been committed to git. This must happen before anything else next
session, likely as several logically-grouped commits rather than one large one.

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

## Next coding session

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

## Next coding session

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
