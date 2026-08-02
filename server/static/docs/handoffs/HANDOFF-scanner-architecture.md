# Sorriva — Scanner Architecture (agreed 2026-07-29)

## How to use this document

This is the design agreed in session `2026-07-29-1`, arrived at by working
through every scanning scenario case by case. It supersedes the
full-scan/incremental split currently in the code. Items 1–4 are a single
coherent change and should be built together; 5–8 follow.

**STATUS 2026-08-01 — items 1-6 are BUILT AND VERIFIED. Items 7 and 8 remain.**

- 1-4 (unified walk-then-filter, mtime change detection, deletion
  reconciliation) — built 2026-07-30, verified across six scenario tests.
- 5 (artwork pass markers and resumability) — built 2026-07-30.
- 6 (walk-connection resilience) — built 2026-07-31. Still **unexercised**: a
  full 11,670-file scan produced zero `walk recovered on attempt N` lines, so
  one connection survived all 562 `listDirectory` calls and the retry never
  fired. Correct by construction, unproven in practice.
- 7 (share-overlap validation and absorb) — **NOT STARTED.**
- 8 (retry scheduler circuit breaker) — built 2026-07-31 as part of the retry
  hardening, though not in the form this document describes.

`bTagEditsNotDetected` was the one open question from item 2 and is now
**closed** — verified 2026-07-31 with a real Mp3tag edit through both the manual
scan and the foreground change check, and covered permanently by
`testTagEditDetectedViaModificationTime`.

Work has since moved on to the scan session ledger; see
`HANDOFF-scan-session-ledger.md`. The design reasoning below still governs the
scan model and should be read before changing it.

Repo: github.com/fournit/sorriva | Mini: `~/projects/sorriva-app/`

---

## The model, in one sentence

**Walk the tree → skip folders whose stored stat still matches (file count +
total bytes + newest mtime) → scan the rest.**

Manual scan, automatic foreground scan, and resume all use this one primitive.
They differ only in what triggers them, and in what resume additionally skips.

### Why this replaces the current split

Today there are two separate paths:

- Full scan (`folderPaths == nil`) — walks root, reads EVERY header, no stat
  comparison at all. A manual rescan of 13.5k tracks re-reads everything
  (~2 hours) even if nothing changed.
- Incremental (`findChangedFolders` → `startIncrementalScan`) — iterates
  `folderStats(sourceId:)`, i.e. folders **already in the DB**, and re-counts
  each one.

The second is the important defect. Because it iterates the DB rather than the
disk, **a newly added folder is invisible** — no FolderStat row means it is
never in the loop, never checked, never scanned. New music on the NAS does not
appear until a manual full rescan. Logged as `bNewFoldersNotDetected`.

Walk-then-filter fixes this structurally: the walk enumerates what is actually
on disk, and absence of a stat means "scan it", never "skip it". It also
retires `findChangedFolders` entirely, including its N-recursive-walks-instead-
of-1 approach and its connection leak (its `defer` calls `logoff()` without
`session.disconnect()` — one leaked connection per foreground check).

### Scenario table (confirmed line by line with Tom)

| Trigger | Behaviour |
|---|---|
| Manual scan — initial | No stats exist, so everything is scanned |
| Manual scan — rescan | Picks up new folders AND changed folders; skips unchanged |
| Automatic (foreground) | Identical logic, different trigger |
| Resume after interruption | Skips folders stamped with the interrupted session, AND folders whose stats still match |

Resume requires BOTH the session stamp and a current stat match, so a folder
edited during the interruption is rescanned rather than skipped. Deliberate —
Tom confirmed this as a far edge case not worth special handling, but the
behaviour falls out correctly anyway.

---

## 1 — v17 migration

- `folder_stats`: add `maxModifiedAt` (integer, nullable)
- `albums`: add `folderArtScanned` (bool, default 0), `onlineArtAttempted`
  (bool, default 0)

v16 (`scanSessionId` on `folder_stats`, `currentScanSessionId` on
`library_sources`) already shipped this session. v15 was
`v15_artwork_dimensions` — do not reuse that number.

---

## 2 — Modification time through the reader seam

**Verified available:** `SMBClient.File` exposes `public var lastWriteTime: Date`
(`Sources/SMBClient/SMBClient.swift:281`), backed by `FileStat.lastWriteTime`.
No fork needed.

- `MediaSourceEntry` gains `modifiedAt: Date` (currently `name`, `isDirectory`,
  `size` only)
- `SMBMediaSourceReader.listDirectory` maps `$0.lastWriteTime`
- `FixtureMediaSourceReader` maps the local filesystem date, so tests stay honest
- Folder comparison becomes count + bytes + **newest mtime in the folder**

### Why mtime matters — this is the fix for bTagEditsNotDetected

A byte check alone cannot detect tag-only edits. External taggers (dbPoweramp,
Picard, Yate, Mp3tag) write changes into the FLAC PADDING block that exists for
exactly that purpose, so neither file count nor total bytes changes and the
folder is never flagged. Adding mtime closes this: a retag changes
`lastWriteTime` even when size is identical.

This matters more under the new model than the old one. Previously a manual
rescan re-read everything, which was the de facto workaround for retagging.
Once manual and automatic share the same skip logic, that workaround
disappears — so mtime is not optional, it is what makes the unified model
complete.

---

## 3 — Walk-then-filter replaces the full/incremental split

One path in `SMBScanner.scanFolders`. After the walk and before the header
loop:

- Load `folderStats(sourceId:)` into `folderPath → (fileCount, totalBytes, maxModifiedAt)`
- Group `allFiles` by folder
- Skip a folder only if a stat exists AND count, bytes and newest mtime all match
- No stat, or any mismatch → scan the folder

Compute `totalFiles` AFTER filtering, or progress reports against the wrong
denominator and jumps (this bug was already hit and fixed for resume this
session).

The resume filter built this session is the same shape and should be folded
into this one code path rather than kept separate — resume becomes "additionally
require the session stamp", not a second mechanism.

---

## 4 — Deletion reconciliation

A folder removed from the NAS never appears in the walk, so today its
FolderStat row and its tracks persist forever.

The walk produces the complete disk picture, so this is a set difference:
`storedPaths - walkedPaths`. Rows absent from the walk are deleted folders.
Existing primitives cover the cleanup: `deleteTracksInFolder(folder:sourceId:)`,
`deleteFolderStats(sourceId:folderPaths:)`, and the `deleteOrphanedAlbums` /
`deleteOrphanedArtists` calls already running at finalize.

**Safety — verified, not assumed.** Both `folderStats(sourceId:)` and the
`DELETE FROM tracks WHERE sourceId = ? AND filePath LIKE ?` are sourceId-scoped.
Scanning share B compares B's walk against B's stats only; share A's rows are
not in the comparison set and cannot look deleted. Confirmed against the code
in response to Tom's exact scenario (13.5k share plus a 1k slice share).

**Constraint:** only safe on full-tree walks. A folder-scoped walk would make
every unvisited folder look deleted. Under the unified model all three triggers
walk the full tree of their share, so this is always satisfiable — but if any
folder-scoped scan is ever reintroduced, reconciliation must be skipped for it.

---

## 5 — Artwork resumability (all three passes)

### The gap Tom found

Quitting the app during the artwork phase kills it permanently. Backgrounding
is fine (same process resumes the same task), but a quit destroys the task and
**nothing else ever starts the artwork passes** — they only run inside
`runScan`'s pipeline task. After a completed file scan, `checkForChanges` takes
the `"complete"` branch, finds no changed folders, and does nothing. Confirmed
in a real log: launch, `checkForChanges` fires, not a single SCAN line follows.

### Current resumability, per pass

| Pass | Marker | Resumable today |
|---|---|---|
| Embedded | `embeddedArtScanned` | Yes — per-album, but PERMANENT (never reset) |
| Folder | none | No — restarts from album 1 every time |
| Online | `artPathThumb == nil` | Partially — albums with no findable art never clear, so they retry forever |

### Agreed marker semantics

Same shape as FolderStat: the marker means "done for this scan", and rescanning
the folder resets it.

- Reset `embeddedArtScanned`, `folderArtScanned`, `onlineArtAttempted` for
  **albums in the folders being scanned**, at scan start — NOT for the whole
  source. An incremental scan of 2 folders must not re-evaluate artwork for all
  47 albums.
- Each pass marks albums as it completes them
- **Resume never resets** — that is the entire point
- All three passes continue to skip `artManualOverride` permanently

`embeddedArtScanned` becoming per-scan rather than permanent is a deliberate
change in existing semantics, agreed with Tom: a rescanned folder may contain
new or replaced files carrying different embedded art. Note the cost — the
embedded pass reads 1MB per track for up to 3 tracks per album, roughly 50× the
I/O of the folder pass (64KB headers). A forced manual rescan of ~1000 albums
is therefore ~3GB over WiFi. Correct, but not free; the user asked for a full
re-read.

### resumeArtworkIfNeeded(source:)

Called from `checkForChanges`'s `"complete"` branch. Runs whichever passes still
have unmarked albums. Must set `activeScanSourceId` and the pipeline heartbeat
so the UI reflects activity and the wedge watchdog covers it.

**Do NOT gate on `albumsWithoutArtwork()`** — some albums will never have
findable art, so that count never reaches zero and the pass would re-run on
every single foreground.

---

## 6 — Walk-connection resilience

`connectedWalkClient()` holds ONE connection across the entire directory walk.
At 673 files that completed in 1.7s with no trouble. At ~10k files / ~1000
folders it is untested, and this session established that SMB sessions die
unpredictably (measured 1 to 139 reads before a stall, averaging 37, with no
correlation to reads, bytes or elapsed time).

The walk needs the same reconnect-on-stall handling `readHeader` has: timeout,
`session.disconnect()`, fresh client, retry the failed `listDirectory`, continue.
Build it in rather than discovering it at 10k.

---

## 7 — Share-overlap handling at add time

### Why this exists instead of qualified paths

The alternative considered and rejected: making paths fully qualified
(`host/share/path`) so two sources can never collide. That would have required
a v17 data migration rewriting every existing track and album path, reworking
every Sonos `x-file-cifs://` URI construction (which currently concatenates
`source.host` + `share` + `filePath` and would double-prefix), and requalifying
FolderStat. Large, risky, touches playback.

Tom's reasoning collapsed it: the only reason to create a second share into the
same tree is to rescan a changed album — and under the new model finding one
changed album in 10k tracks takes well under a minute (walk ~25-30s extrapolated
from 673 files in 1.7s, in-memory filter, then ~8s for the one folder). So the
targeted share has no purpose, and preventing same-server overlap makes the
whole class of problem unreachable.

### Rules

| Situation | Action |
|---|---|
| New share is INSIDE an existing one, same host+share | **Block** — already covered |
| New share CONTAINS an existing one, same host+share | Offer **absorb** (below) |
| Same relative rootPath, different host | **Warn only** — legitimate backup case, rare |
| No overlap | Proceed |

Prefix comparison needs a trailing-separator guard so `/Music` does not falsely
match `/Music II`.

### The absorb case

Adding a share at the root when a narrow share already exists deeper is
legitimate expansion, not an error. Blocking it would be wrong.

It is nearly free because **the path strings already coincide**: `rootPath` is
embedded in the path the walk builds, so a narrow share at `/Music II/ABBA`
produces `folderPath = /Music II/ABBA/Gold`, and a root share produces the same
string. Existing rows are already valid for the new share — only `sourceId` is
wrong.

On confirm, in ONE transaction, reassign rather than delete:

```sql
UPDATE albums       SET sourceId = :new WHERE sourceId = :old;
UPDATE tracks       SET sourceId = :new WHERE sourceId = :old;
UPDATE folder_stats SET sourceId = :new WHERE sourceId = :old;
UPDATE scan_skips   SET sourceId = :new WHERE sourceId = :old;
DELETE FROM library_sources WHERE id = :old;
```

Then scan normally. Because the FolderStat rows carry over with matching paths,
walk-then-filter skips the already-scanned subtree and reads only what is new.

**Three requirements, all load-bearing:**

1. **Order** — reassign BEFORE deleting the old source row, or the cascade
   (`onDelete: .cascade` on both `albums.sourceId` and `tracks.sourceId`) takes
   everything with it.
2. **One transaction** — a partial failure must not leave rows pointing at a
   deleted source.
3. **Clear `currentScanSessionId` as part of the absorb.** The carried-over
   FolderStat rows carry the OLD share's session id; resuming against it would
   filter using a session that scanned a different tree. Clearing it means the
   worst case is a full rescan of an already-correct library — slow, never wrong.

**Precondition:** block absorb entirely if either share has
`scanState == "scanning"`, with a message to let it finish or cancel. Absorbing
mid-scan silently discards in-flight work.

**Resume after absorb** needs no new machinery: absorb is atomic so there is no
partial state to resume from (interruption leaves the pre-absorb state, retry).
The scan afterward resumes on the existing mechanism — killed-scan detection →
alert → resume → walk-then-filter skips both what this scan completed and what
the absorbed share had already done.

---

## 8 — Retry scheduler circuit breaker

Observed this session: after connection exhaustion the retry scheduler fired
hundreds of doomed retries, cycling the same file list repeatedly, burning
further connection attempts for zero possible gain and deepening the hole. No
circuit breaker exists. Needs: N consecutive failures of the same class → stop,
surface an actionable message, do not keep hammering.

Requires `ScanRetryScheduler.swift` (not read this session).

---

## Explicitly NOT doing, and why

**Fully-qualified paths / `(host, share, path)` identity.** Item 7 makes the
cascade problem unreachable on a single server, which is what this change was
for. Multi-server identity belongs with WP-12 (canonical identity) and WP-13
(SourceResolver), which already specify it.

**Making manual rescan byte-check-free.** Under the new model manual and
automatic share the same skip logic. Item 2 (mtime) is what makes that safe; if
mtime turns out not to work in practice, the escape hatch of "manual rescan
re-reads everything" must be restored, because otherwise retagging becomes
undetectable.

---

## Confirmed behaviour — album and track identity

Worked through case by case, verified against the code. Recorded because the
reasoning is not obvious from reading the schema.

**There is no "source" entity separate from "share."** Each share IS a
`LibrarySource` row with its own `sourceId` (the table holds `host`, `share`,
`rootPath` per row). So "same server, two shares" and "two different servers"
are identical in the schema: two rows, two sourceIds. Host plays no part in
album resolution.

`album(folderPath:)` is a **global** lookup on the path string — no host, no
share, no sourceId:

```swift
try Album.filter(Album.Columns.folderPath == folderPath).fetchOne(db)
```

Therefore **only the folderPath string decides**:

| Scenario | Result |
|---|---|
| Two shares, paths coincide | 1 album, owned by whichever share created it |
| Two shares, paths differ | 2 duplicate albums (`bDuplicateAlbumDetection` — expected behaviour) |

`albums.sourceId` is a single NOT NULL column, so an album physically cannot
reference two sources. In the same-path case the album is invisible to the other
share's artwork passes and reports, both of which select via
`albums(sourceId:)` — this is what the `fOverlappingShareDetection` record meant
by "produces 0 tracks in its report."

**tracks.filePath is globally unique** — `t.column("filePath", .text).notNull().unique()`,
NOT scoped by sourceId. So two shares covering the same file produce ONE row
whose `sourceId` flips to whichever scanned last. Combined with
`onDelete: .cascade`, **removing the share that scanned last deletes tracks the
other share still covers on disk**, silently, recoverable only by full rescan.

Item 7 prevents this by making same-server overlap impossible. The underlying
schema issue is logged as `bTrackFilePathGloballyUnique` (blocker on any second
source, e.g. `fMacBridge`) and `bAlbumFolderPathGloballyUnique`.

A cheaper partial mitigation, if ever needed before item 7 lands: make
`upsertTrackIdempotent` first-writer-wins on `sourceId` (do not overwrite it on
an existing row). No migration. Still wrong if the FIRST share is removed
instead of the last.

---

## Already shipped and verified this session — do not redo

**bScanConnectionExhaustionOnRepeatedScans — ROOT-CAUSED AND FIXED.** SMBClient
v0.3.1 never calls `NWConnection.cancel()` anywhere: nothing invokes
`Session.disconnect()`, `SMBClient` exposes no wrapper, no deinit on
Connection/Session/SMBClient. `logoff()` sends the SMB2 LOGOFF frame and zeroes
sessionId while leaving the TCP connection open, so every read leaked a kernel
flow entry against a hard per-process ceiling of exactly 512. Fixed by calling
`client.session.disconnect()` on every teardown path — `session` is a public
property and `Session.disconnect()` is public, so no fork was needed. Verified:
673-file scan in 400.8s, 663 tracks, zero NWError 12, full pipeline 10 minutes
in one process. Note a comment in `ScanCoordinator.swift` asserting `logoff()`
triggers `Session.disconnect()` was FALSE and has been corrected.

**Also disproved:** the "UNAS Pro drops sessions after ~2 sequential reads"
premise that justified the fresh-connection-per-file architecture. Measured 1 to
139 reads per session, averaging 37. Session reuse with transparent reconnect
verified working (1000 files on 27 connections). It is now a performance
optimisation, not a survival requirement.

**fScanResume — built and verified.** v16 `scanSessionId` on `folder_stats`,
`currentScanSessionId` on `library_sources`. Killed-scan detection added to
`checkForChanges` (the launch-time `"scanning"` → `"error"` reset that
`sorriva-context.html` documents was never actually built). Alert now offers
Resume / Start Over / Cancel. Verified: killed mid-scan, resumed, skipped 31
files in 4 complete folders, and the negative test passed — a subsequent manual
scan rescanned all 673 with no skip lines.

**Pipeline wedge watchdog — built, NOT yet verified.** A hang in the artwork
phase used to be permanent: `scanState` → `"retrying"` and
`activeScanSourceId = nil` both happen AFTER the artwork passes, so a stall left
the app believing a scan was healthy forever, which also blocked killed-scan
detection. Added `lastPipelineProgress` heartbeat (scan progress callback +
every artwork album iteration), a held `pipelineTask` handle, and a 240s stall
threshold in `checkForChanges` that cancels, resets state and offers resume.
**Test: start a scan, reach the folder art pass, background 5 minutes,
foreground — expect `SCAN: pipeline WEDGED`.**

**Also shipped:** all six `session.disconnect()` sites in `ScanCoordinator`;
`SMBConnectionCounter` stripped (it never emitted a line — `sLog` appears
unreachable from a plain class outside the actor); `folder done` now reports
persisted rather than enumerated track count, flagging shortfalls explicitly.

---

## Newly logged, not built

- `bNewFoldersNotDetected` — automated change detection cannot see new folders
- `bTrackFilePathGloballyUnique` — Critical, blocks any second source
- `bAlbumFolderPathGloballyUnique` — same class, album level
- `bScanCoordinatorReconnectLeak` — `findChangedFolders`' `defer` leaks one
  connection per foreground check (moot once item 3 retires it)
- `bPlaybackContextResolveChurn` — `CONTEXT: resolved idle station` fires
  hundreds of times per second at launch for the same zone; write-side heuristic
  recomputation, likely folds into the PlaybackStore architecture conversation
- `bMissingTracksInAlbum` — lowered to **Low** per Tom; did not recur in the
  clean run, keep open pending several more scans

## Gate status

WP-14 criteria: seven consecutive days without database rebuild, repeat scans
idempotent, album metadata advances correctly, interruptions recover without
relaunch, critical failures produce actionable diagnostics.

The clock has been running since 2026-07-24 while the foundation under every
scan was broken. Tom's stated intent is to restart it. Remaining gate-relevant
work: `bScannerTestSeam` (two tests certify code they never execute —
`testDeletedFileRemovedOnFolderRescan`, `testFailedWriteDoesNotMarkFolderComplete`),
`fScanReconciliationAudit`, and items 5–6 above (background/foreground recovery
is an explicit WP-14 task).
