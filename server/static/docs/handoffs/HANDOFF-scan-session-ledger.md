# Sorriva — Scan Session Ledger (agreed 2026-07-31)

## How to use this document

This is a design agreed in session `2026-07-31-2`, arrived at after a full
11,670-file library scan exposed that the app cannot answer the question
"what was supposed to be in the library, and what actually made it?"

Nothing here is built. What HAS been built and verified is in
`HANDOFF-scanner-architecture-2026-07-29.md` items 1-6, plus the fixes listed
under "What prompted this" below.

Repo: github.com/fournit/sorriva | Mini: `~/projects/sorriva-app/`

---

## The problem, concretely

A full scan of `Media/Tom's Vault` (562 folders, 11,670 files) completed on
2026-07-31. It produced 11,231 tracks with 439 read-skipped. The retry
scheduler recovered 419 of those, leaving 20 tracks and 5 albums outstanding.

Then the retry scheduler hung. On relaunch it restarted, and some time later
both queues read as empty — with no log line saying the outstanding work had
been done.

**Nobody could say what happened to those 20 tracks and 5 albums.** Not the
user, not the log, not Claude reading the log. The 5 albums were probably
cleared by `resetArtworkPassMarkers` (added earlier the same day for item 5),
which zeroes `embeddedArtFailed` — the exact column
`albumsNeedingEmbeddedArtRetry()` selects on, so the retry queue is silently
emptied rather than worked. The 20 tracks remain unexplained: they can only
leave `pendingScanSkips` via `resolved = 1` or `attemptCount >= 5`, and the
permanent count was zero.

That uncertainty is the actual defect. The specific bugs are downstream of it.

**Tom's framing, which is the right one:** "this would also allow a user to see
specifically what failed rather than saying 20 of your 11,000 tracks didn't
make it. have fun trying to figure out which ones."

The app currently cannot tell a user *which* tracks are missing. Worse, it
cannot tell them anything is missing at all — an album showing 12 tracks looks
like a 12-track album. There is no marker distinguishing "this album has 12
tracks" from "three reads failed and those tracks are simply absent."

---

## The model

**A scan session is a bounded, auditable unit of work.** It records what it
intended to do, records every outcome against that intent, and is not complete
until every planned item has reached a terminal state.

This is not what exists today. Today:

- The session id exists but nothing is attributed to it — no track, album,
  artwork write or skip record carries it
- The retry scheduler is a separate actor with its own lifecycle that happens
  to run afterward, and is not part of the session in any enforced sense
- Nothing records what the scan *intended*, so "what should be in the library"
  is unknowable after the fact
- Completion is a `scanState` string written by four different code paths

### Core rules, agreed

1. **The retry phase is part of the session.** Not a separate process that runs
   afterward. It continues working the same ledger until every row is terminal.
2. **No other scan of that share runs until the session completes or is
   cancelled.** Enforced by the ledger having unaccounted rows, not by a state
   string.
3. **Interrupted retries recover exactly like interrupted tracks and artwork
   do** — the ledger is the recovery state, and it is durable by construction.
4. **The record survives automatic scans.** It is cleared only when the user
   manually scans that same share.
5. **Everything is auditable**: albums, tracks, and artwork.

---

## The ledger

At scan start, record the **plan**: every folder to be scanned and every file
within it. The walk already computes this — it is the same `allFiles` the
filter produces, so the denominator is free.

Every outcome then writes against the plan, carrying the session id:

- track written
- track skipped (with reason)
- skip retried and resolved
- skip exhausted / permanent
- artwork found by pass N (embedded / folder / online)
- artwork failed (with reason)

The audit becomes arithmetic rather than inference:

```
planned = written + skipped-resolved + skipped-permanent + unaccounted
```

**Any non-zero `unaccounted` is a bug, and it names the exact files.** That is
the property the current system lacks and the reason tonight's question was
unanswerable.

### Failure reason is load-bearing

Record WHY, not just that. All 439 skips in tonight's run were `TIMEOUT 15s` —
the NAS did not respond, and a retry will very likely work. That is completely
different from a corrupt file or a permission error, where retrying is
pointless.

With the reason recorded, the tool can say "12 tracks timed out — likely
recoverable" versus "1 track unreadable — check the file", and the user knows
whether retrying is worth anything. It also feeds the automatic path: a timeout
deserves several attempts, a malformed header deserves none.

---

## Storage: DB is authoritative, share gets a written record

Agreed after discussion. Both, with distinct jobs.

### The DB is the source of truth

- **The audit's job is to answer "what's missing", and the most likely reason
  something is missing is that the NAS was unreachable.** A ledger that lives
  only on the NAS is unavailable exactly when it is needed. Same reasoning that
  keeps the debug log on-device.
- It is a query, not a document. "Which albums have missing tracks" is one
  indexed SQL statement; against a file it is parse-everything-then-filter on
  every screen open.
- The retention rule (survives automatic scans, cleared by a manual scan of
  that share) is a `sourceId` column and a `DELETE WHERE`.
- It drives the **inline** signal — an album showing "12 of 15 tracks" needs
  that answer instantly on a scroll, not from a parsed file.

### The share gets a human-readable report after the session ends

Written once, when the session reaches terminal state. One connection, one
write. NOT during the scan — writing per-event to the share would consume the
connection budget being tested, hammer the same NAS the scan is already
loading, and fail precisely when diagnostics matter most.

**This is a first-class feature, not a developer convenience.** Tom's point:
"its not about the mini. its about some future user who doesn't have a mini."

For a user with no second machine, the share is the only place they can reach a
file from a computer they are already sitting at. The Settings → share sheet →
AirDrop → find-it-in-Downloads flow is a developer's workaround. That same user
already has the NAS mounted in Finder or Explorer, because that is how the
music got there.

Which means **the format matters** — a human opens this directly. Not a JSON
dump. Album, tracks that did not import, and why, readable in TextEdit by
someone who knows nothing about the app's internals.

Same mechanism answers debug-log retention generally: same destination, same
reason, same "survives reinstall and device change".

---

## The in-app tool (Library Management)

Review the record, and **recover from it in place**. The machinery largely
exists: `scan_skips` holds exact file paths, the retry scheduler already knows
how to re-read a single file, and `folderPath` gives album-level scope.

Three actions:

- **Retry this track** — one file, immediate, reports success or the actual error
- **Retry this album** — every failed file in that folder
- **Retry everything** — the whole session's failures

The difference from today's automatic retry is that it is user-initiated and
**reports back**. Today it runs invisibly on a backoff schedule and the user
finds out by noticing a track missing months later.

Failure reason should be surfaced here so the user knows whether retrying is
worth anything before they tap it.

This supersedes / absorbs `fScanFailureUtility`, which was previously scoped as
a Settings screen without a ledger underneath it to make it possible.

---

## What prompted this — session 2026-07-31-2 findings

**The full-library scan itself passed**, and comprehensively:

| Phase | Result | Time |
|---|---|---|
| Walk + filter | 562 folders, 11,670 files — **exact match to `find`** | 16s |
| Header pass | 11,231 tracks, 439 skipped, 0 write failures | 3h 03m |
| Embedded art | 475/561 found | 14m |
| Folder art | 63/561 found | 4.5m |
| Online art | complete | 2m |
| Retry (tracks) | 419 of 439 resolved | 8m |
| Rescan, nothing changed | 11,670 tracks, all skipped | **16.9s** |

Zero `NWError 12` across ~11,700 connections — the `session.disconnect()` fix
holds at full scale. Zero `walk recovered on attempt N` — the single walk
connection survived all 562 `listDirectory` calls, so item 6's retry never
needed to fire (built, still unexercised).

That 16.9s rescan is the headline: a full-library change check that would
previously have re-read every header for three hours.

**Bugs found and fixed during the run:**

- `ScanRetryScheduler` art retry had NO timeout on its read. A dead session
  meant waiting forever, and because `scanState 'retrying'` restarts the
  scheduler on every launch, each relaunch reproduced the hang. Unrecoverable
  without clearing the library. Now 15s with `session.disconnect()`.
- Three teardown sites in `ScanRetryScheduler` called `logoff()` without
  `session.disconnect()`, leaking a flow entry per retry pass.
- No circuit breaker — added, 5 consecutive timeouts aborts the pass and leaves
  remaining albums queued rather than hammering an unresponsive NAS at 15s each.
- The retry scheduler was invisible to the pipeline wedge watchdog:
  `lastPipelineProgress` was only updated by the scan and artwork loops. Now
  heartbeats per album via `notePipelineProgressExternal()`.
- RETRY log lines lost their session tag after a relaunch, and also mid-run
  because `ScanCoordinator`'s pipeline completion raced the scheduler by calling
  `ScanLogSession.end()`. The scheduler now owns the tag and clears the session
  id when it genuinely completes.

**Known, deliberately not fixed pending this design:**

- `resetArtworkPassMarkers` zeroes `embeddedArtFailed`, which is the retry
  queue's selection column — so any scan touching those folders silently
  empties the artwork retry queue. A narrow fix (exclude that column) was
  proposed and rejected as patching a symptom: the real issue is that retry
  state and pass state are conflated, which the ledger resolves.
- `fReduceHeaderReadTimeout` — `readHeader` still uses 15s. Tonight that cost
  **110 minutes of the 3-hour header pass** (439 timeouts × 15s), roughly 60% of
  runtime; at 5s it would have been ~37 minutes. Deliberately held until the
  retry changes land, because the correct timeout depends on failures carrying a
  reason and the user being able to retry deliberately. Note 15s buys nothing on
  this path: `readHeader` opens a fresh connection per file, so a timeout does
  not trigger reconnect-and-continue — it skips the file and moves on.
- The retry pass restarts from album 1 within a pass rather than resuming
  mid-pass. Cheap at 5 albums and self-limiting via `embeddedArtRetryCount`, but
  it is the same gap item 5 closed for the scan's artwork passes.

**Current timeouts, for reference:**

| Path | Timeout |
|---|---|
| `MediaSourceReader.listDirectory` (walk) | 10s |
| `MediaSourceReader.readHeader` | 15s |
| `ScanRetryScheduler` art retry | 15s |

---

## Suggested build order

1. **Schema** — session table, plan rows, outcome rows with reason. Retention
   scoped by `sourceId`, cleared on manual scan of that share.
2. **Record the plan** at scan start from the filter's output.
3. **Write outcomes** with the session id from every write path — track, skip,
   retry result, artwork per pass.
4. **Fold retry into the session** so it works the ledger rather than its own
   queues, and so the session is not complete until every planned row is
   terminal.
5. **Reconciliation query** — the arithmetic above, surfacing `unaccounted`.
6. **Share export** on session completion, human-readable.
7. **Library Management tool** — review plus in-place retry.
8. **Inline signal** — "12 of 15 tracks" on the album itself.
9. Then revisit `fReduceHeaderReadTimeout` with reasons recorded.

Steps 1-5 are the foundation and are worth doing together; 6-8 are the user-
facing payoff and can follow.
