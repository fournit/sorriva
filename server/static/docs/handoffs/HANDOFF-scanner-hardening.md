# Sorriva — Scanner & NAS Reliability Handoff

## How to use this document

This is a complete context transfer for continuing work on Sorriva's SMB
library scanner and artwork pipeline. Read this entire document before doing
anything else. It contains the full reasoning trail — not just conclusions —
including approaches that were tried and rejected, so you don't re-walk
already-eliminated paths. Where a root cause was found, it was found by
reading actual source code or real log evidence, not by inference — that
standard should continue. Do not propose fixes without first reading the
relevant real code and/or real log data yourself.

Working style established across this project, carry it forward:
- Diagnose → propose exact change → get explicit confirmation → write code.
  Do not write code before confirmation on anything non-trivial.
- One file at a time, deliver only what changed, with one `iosdeploy so`
  command. Never re-present unchanged files.
- When something doesn't reproduce or doesn't match your theory, say so
  plainly and re-verify against evidence rather than defending the theory.
- Terminal commands: one at a time, wait for output.
- Sessions are tracked in sessions.json (owner hours) and roadmap-data.json
  (feature/bug records) on the Mac Mini hub — update both when work
  completes, following the existing record shapes.

Repo: github.com/fournit/sorriva | Mini: ~/projects/sorriva-app/
Deploy: `iosdeploy so <files>` (main target), `iosdeploy so-test <files>`
(test target) | Commit: `gitops`

---

## TL;DR — current state

- **Scanner core identity/write correctness: DONE.** WP-02 fix (idempotent
  upsert), MediaSourceReader test seam, fillFromPath bug fixed. Solid,
  tested, verified against real repro cases.
- **Artwork best-wins redesign: DONE**, but shipped with real bugs found via
  live testing (not just unit tests) that were then fixed. See below —
  worth re-verifying with a fresh full scan before trusting further.
- **NAS connection reliability: Stage 1 (confirmed leak fixes) DONE across
  ScanCoordinator.swift. NOT YET AUDITED in MediaSourceReader.swift's
  SMBMediaSourceReader** — a fix WAS written and deployed for it (making a
  hung background task force-cancellable on timeout) but has not yet been
  re-tested to confirm it holds under sustained load. **Stage 2 (session
  reuse — read multiple files per SMB connection instead of one connection
  per file) is NOT STARTED.** This is the highest-priority remaining item —
  see "THE priority" section below.
- Two smaller scanner-correction items not started: bDuplicateAlbumDetection,
  bTagEditsNotDetected.
- **Two additional open items found via a full roadmap audit (not part of
  this session's earlier work, surfaced afterward) — both High priority,
  both genuinely relevant:**
  - `bMissingTracksInAlbum` — an open, live bug: some albums show only one
    track when the NAS folder holds a full album. Root cause not yet
    identified. Has a real, newly-discovered interaction with
    `bFailedReadCreatesWrongAlbumFromFallback` (see full detail in the
    separate gate-readiness assessment document) — that fix removed the
    old "write a path-derived stub row even on a failed read" behavior,
    which may make this bug worse for tracks that fail both their initial
    read and all retry attempts. Most likely root cause per the roadmap's
    own ranking: an interrupted incremental scan combined with
    `fScanResume` (also not built) not repairing the resulting partial
    state.
  - `bScannerTestSeam` — `ScannerTests.swift` (an older, 16-test file,
    distinct from the newer real-scanner-path tests built this week) never
    instantiates `SMBScanner` — it drives a hand-written stand-in
    (`SorrivaDatabaseTestable`) instead. Precisely scoped: most of its
    tests cover unrelated components where this is harmless; exactly two
    scanner-specific behaviors (`testDeletedFileRemovedOnFolderRescan`,
    `testFailedWriteDoesNotMarkFolderComplete`) have zero verification
    against the real production scan path.
- fScanFailureUtility was deliberately reclassified OUT of scanner hardening
  — it's a new feature (manual retry UI), not a scanner correction. Don't
  fold it back in.

---

## 1. Scanner identity & write correctness (COMPLETE)

### The core defect (WP-02)
`upsertTrack` (not idempotent) was the actual production write call despite
`upsertTrackIdempotent` existing and being tested — rescans silently failed
on the UNIQUE constraint on `tracks.filePath`. Fixed: `upsertTrackIdempotent`
is now the real call, returns the actually-persisted `Track` (critical:
internally reassigns id to the existing row's id on rescan, and the caller
must use the returned Track's id for the subsequent `track_artists` insert
or the FK constraint fails).

### MediaSourceReader seam
Built specifically to make the scanner testable against fixtures instead of
a live NAS. Protocol has exactly two responsibilities: `listDirectory` and
`readHeader`. Two implementations:
- `SMBMediaSourceReader` (production) — see the connection-lifecycle section
  below, this file is central to the NAS reliability work.
- `FixtureMediaSourceReader` (test-only) — reads from local fixture files.

### fillFromPath bug (folder-name fallback)
Two related bugs found in the folder-name-derived metadata fallback (used
when tag data is missing or unreadable):
1. Original bug: `case 1:` (single-level folder depth) was missing the
   `m.albumArtist == nil &&` guard present in the `default:` case — caused
   track artist to be overwritten with the folder name when ALBUMARTIST was
   present with no ARTIST tag.
2. **Structural bug, fixed later, more important:** a FAILED tag read used
   to still fall through to `buildTrack` with empty `ParsedMetadata`,
   letting `fillFromPath`'s prefix-strip logic run with no artist context
   (both `albumArtist` and `artist` nil) — for a VA-compilation folder named
   like `Various Artists - Album Name (CD 2)`, the strip couldn't correctly
   remove the "Various Artists -" prefix (it compared against the wrong
   fallback reference), producing a wrong, unstripped album name. **Worse:**
   a later successful retry of the SAME file's tags never corrected the
   album record already wrongly created, since retry only ever updates a
   track's own row, never re-evaluates the album it belongs to.
   - **Real repro used to confirm this:** "Various Artists - 12 Inch Dance
     80s Remix (CD 2)" — track 1 timed out on the main scan, fell back,
     created the album wrong. A later retry successfully re-read track 1's
     real tags but the wrong album persisted.
   - **The fix (Tom's proposed design, correct):** a failed read should
     never create a track/album from empty fallback data in the first
     place — just record the skip and move on. Implemented by moving
     `buildTrack`/write inside the read-succeeded branch only in
     `SMBScanner.swift`'s main loop; `FolderStat` and progress bookkeeping
     stay unconditional so a folder containing a skip can still complete
     once retry resolves it, rather than never completing.
   - **Verified fixed** via a second full scan — the exact repro album now
     resolves correctly (`Various Artists · 12 Inch Dance: 80s Remix (Disc
     2)`, matching the real tag data), because a *different* track (not the
     one that timed out) successfully defined the album first.
   - Roadmap ID: `bFailedReadCreatesWrongAlbumFromFallback` (done).

### Retry-loop-never-resolves bug pattern (found TWICE — watch for a third)
Shape: a genuinely confirmed negative result (successful read, but nothing
useful found) gets treated as if it needs indefinite retrying, because the
code that "resolves" it clears the wrong flag — one the retry queue's own
eligibility query doesn't actually check.
- **First instance (track metadata, scan_skips):** fixed in an earlier
  session (not detailed further here — search roadmap for the original fix
  if needed, this doc focuses on what's since happened).
- **Second instance (embedded art retry):** `markEmbeddedArtScanned` only
  set `embeddedArtScanned = 1`, but the retry queue
  (`albumsNeedingEmbeddedArtRetry`) filters on a DIFFERENT flag,
  `embeddedArtFailed`, which was never cleared. Real repro: an album
  retried indefinitely showing "attempt 2/5" without the counter ever
  incrementing, since nothing in the "no art in file" branch touched either
  flag the retry queue actually depends on. **Fixed** by having
  `markEmbeddedArtScanned` clear `embeddedArtFailed` too, matching its
  actual intent (no further scanning OR retrying needed) everywhere it's
  called. Roadmap ID: `bEmbeddedArtRetryNeverResolves` (done).
- **When auditing other retry loops in this codebase, check specifically:
  does the "resolved" path clear every flag the retry queue's own
  eligibility query depends on, not just the flag that seems most obviously
  related?**

---

## 2. Artwork best-wins redesign (bArtworkSelectionNotBestWins — DONE)

### The original defect
Three artwork sources (embedded tags, folder image files, iTunes online
fetch) ran with no real comparison between them — whichever ran last won
unconditionally, even if it was lower resolution than what was already
stored. Folder pass also only compared candidates within itself weakly
(sorted by file size, took the first over a floor, never true best-of).

### The redesign
- v15 migration: `albums.artworkWidth`/`artworkHeight` — the shared
  "current winner" record all three passes compare against.
- `ImageDimensionReader.swift` (new) — header-only PNG/JPEG dimension
  parsing, so passes can compare true pixel area without fully downloading/
  decoding every candidate. **Found and fixed a real bug in this file
  itself:** the original PNG parser assumed `IHDR` sits at a fixed byte
  offset right after the signature — true for a standard PNG, but Xcode's
  own build-time "Compress PNG Files" optimization can rewrite a *bundled
  test fixture* to insert a proprietary `CgBI` chunk before it, breaking
  that assumption. Rewrote to walk the chunk structure properly instead of
  assuming a fixed offset — more robust in general, not just a workaround
  for the test environment. (This only affects Xcode-processed bundled
  resources, never real files scanned from a NAS, so it was purely a test-
  fixture problem, but the fix makes the parser genuinely more correct.)
- `ArtworkBestWins.swift` (new) — pure, testable candidate-selection logic
  extracted from the folder pass (largest area wins, filename tie-break:
  cover > folder > AlbumArt_* > other). Deliberately pure/pluggable so it
  could be unit tested without touching SMB I/O.
- Pass order: **embedded runs first** (highest likelihood of being
  hi-res — real motivating case: an MP3's embedded art was 300KB+ and beat
  everything else available). **Folder pass always does its cheap header-
  check regardless of what embedded found** — only the expensive full
  download is conditional on actually beating the stored winner. This was
  Tom's design correction to an earlier proposal that would have skipped
  the folder check entirely once embedded found "good enough" art — that
  would have missed cases where the folder image was genuinely better than
  embedded. **Online fetch (iTunes) originally redesigned to be "just
  another candidate" competing on area — this specific piece was reverted,
  see below.**

### Three real bugs found via live testing (not caught by unit tests) — all fixed
1. **Folder pass hung indefinitely after a connection timeout.** New
   header-check code had no reconnect-on-timeout logic (unlike the old
   download-timeout path, which correctly reconnected). Once a timeout hit,
   every subsequent album's header check also timed out, forever — this is
   what "hung" felt like from the outside. Also found the download-timeout
   reconnect logic itself had been *lost* during the rewrite. Both fixed:
   explicit `disconnectShare()`+`logoff()` before creating a fresh
   `SMBClient` in both timeout paths.
2. **Embedded pass stopped at the first track with any art**, instead of
   checking all up-to-3 tracks per album and keeping the best. Real repro:
   Pat Metheny "We Live Here" — track 1 had 200×200 embedded art, track 2
   had 1280×1280; the old code saved the 200×200 and never looked further.
   Fixed using the same `ArtworkBestWins` selection logic, now comparing
   across all checked tracks (and against the stored winner) before saving.
3. **Online fetch overwriting CORRECT existing artwork with WRONG iTunes
   matches — the most serious of the three.** Root cause: the online-fetch
   query has always included both artist and album name (a stale roadmap
   record, `bArtworkArtistQuery`, incorrectly attributed this to a missing
   artist name — corrected, see below) — but iTunes's own search relevance
   ranking plus zero verification on our side that the returned result is
   even plausibly related meant a generic/common title could match
   something completely unrelated. **Confirmed real cases, not
   hypothetical:** a "Various Artists" compilation with a generic title
   matched "The Greatest Showman Reimagined"; a Johnny Cash "18 Greatest
   Hits" matched Al Green's artwork. **Explicitly not compilation-specific**
   — any album with a common/generic title is at risk. This became newly
   dangerous specifically because of this redesign: before, online fetch
   only ever ran for albums with zero existing art (low risk — a bad match
   could only fill an empty slot). After the redesign, it could overwrite
   anything below the resolution ceiling, including something already
   correct, purely because iTunes always claims a fixed 600×600 and that
   beats almost any real local candidate on area alone.
   - **Immediate fix (shipped):** reverted online fetch to gap-filling-only
     (original, safe behavior) — a wrong match can now only ever fill an
     empty slot, never overwrite something correct.
   - **bArtworkArtistQuery** — corrected the stale diagnosis, kept
     deliberately OPEN for future query-tuning experiments (not urgent).
   - **fArtworkManualSearchUtility** — new roadmap record, NOT STARTED.
     Tom's proposed long-term direction: a human-in-the-loop utility where
     the user sees a wrong/low-res cover, the app searches multiple sources
     (Apple, Discogs, MusicBrainz Cover Art Archive per the existing
     `fMusicBrainzCoverArt` record), and the user picks the correct result.
     Rationale: no amount of automated query tuning can fully guarantee a
     correct match when two different albums share a similar name — better
     to put a human in the loop for the final decision than keep trying to
     perfect matching heuristics.
   - **Known caveat, not yet addressed:** any album that already received a
     wrong iTunes match before this revert (the Johnny Cash and VA-
     compilation cases specifically) will NOT self-correct on a normal
     rescan, since it now has "some" art and the gap-filling-only gate will
     skip it. Needs either a one-off manual DB fix or the manual-search
     utility above.

### Diagnostic gaps closed along the way (keep this pattern going)
`ArtworkCache.swift` was using bare `print()` instead of `sLog()` — its
activity was completely invisible in every exported debug log, which is
part of why the online-fetch bug took real digging to surface. Converted to
`sLog()`. **When adding new logging anywhere in this codebase, always use
`sLog()`/`scanLog()`, never bare `print()` — `SorrivaLogger` only captures
explicit calls, there is no global stdout redirect.** Also added a
previously-missing log line for "candidate image files existed in a folder
but every single one failed to produce a readable header" (was silently
just... nothing, no explanation) — this was added specifically because Tom
plans repeated clear+rescan cycles to hunt timeout patterns and needs this
visible.

### 10 new tests: `ArtworkSelectionTests.swift`
Covers `ImageDimensionReader` (real generated PNG/JPEG fixtures, including
confirming it works from just the first 16KB — matching what the real
folder pass reads — and fails safely on garbage/empty data) and
`ArtworkBestWins` (largest-area-wins, filename tie-breaking, the core
"candidate must beat stored area" defect this whole redesign exists to fix,
non-square-area comparison). One attempted additional test (a synthetic
CgBI-simulating PNG fixture) was abandoned after repeated fixture-generation
issues cost too much time relative to its value — the underlying fix is
already proven via the real-world case and pre-implementation Python
verification; don't re-attempt this specific test without a clear reason.

**fArtworkPassTestSeam** — logged, not started. The pass orchestration
itself (`runFolderArtPass`, `runEmbeddedArtPass`, `ArtworkCache.fetchArtwork`)
still talks directly to `SMBClient`/`URLSession` with no test seam, same
situation the scanner was in before `MediaSourceReader`. Not urgent — the
decision logic most likely to have subtle bugs is already covered.

---

## 3. NAS connection reliability — THIS IS THE PRIORITY

Tom has explicitly stated this is the single most important open item.
Direct quote from context: without a resolution, the product's core premise
(no dedicated server/hardware requirement, unlike Roon) may not be viable
for large libraries. **Do not treat this as routine bug-fixing — it is
close to an existential product question.**

### The symptom
`Network.NWError error 12 — Cannot allocate memory`. First observed
repeatedly during scanning against the primary NAS (a UNAS Pro). Critically,
also reproduced against a COMPLETELY DIFFERENT device (a Mac mini, plain
SMB, just listing shares, not even scanning) within the same long app
session — this rules out "one misbehaving NAS" as the root cause and points
at something tied to the app PROCESS's cumulative connection activity.

### What was ruled out
- **NAS-specific tuning as a general solution.** Tom explicitly rejected
  this direction: this is a commercial product, users will have many
  different NAS implementations, and none of them can be assumed to be
  correctly tuned. **Any fix must work correctly against an unoptimized,
  arbitrary, "least common denominator" NAS** — a fresh-connection-per-file
  worst case must be reliable (if slow) regardless of the NAS's own
  configuration quality. Do not propose NAS-side configuration changes
  (signing/encryption settings, credit limits, etc.) as part of the actual
  product fix — those are useful only as diagnostic tools to understand the
  problem, never as something to tell users to go configure.
- **A cloud server doing the heavy lifting.** Technically impossible as
  originally proposed — a cloud server cannot reach into a user's home NAS
  (no public IP, no port forwarding by default, and exposing SMB to the
  public internet is not something any legitimate product does).
- **A required desktop/server helper app** (à la Roon Core, Plex Server).
  Rejected on product-thesis grounds, not technical grounds: the entire
  point of this product is to avoid exactly this kind of setup/maintenance
  burden. A "run a helper app on your Mac/PC" requirement reintroduces the
  friction the product exists to eliminate. **Any fix must keep all
  processing on-device (iOS) or be a lightweight, optional, non-blocking
  enhancement — never a hard requirement for core functionality.**

### Research findings (via the Research feature, high confidence)
Full report available — key points:
- Apple DTS-confirmed: a per-process kernel limit of ~512 simultaneous
  network flows (`nw_connection_t` objects backed by kernel flow-table
  entries). Affected connections enter `nw_connection_state_waiting` and
  report exactly this "Cannot allocate memory" error, and **can remain
  stuck indefinitely even after other connections are deallocated and
  resources should theoretically be available again** — i.e., this can be
  a real leak, not just "too many at once."
- The ~512 figure is on SIMULTANEOUS connections, not a cumulative lifetime
  count. Sorriva's architecture only ever holds 1-2 connections open at a
  time (strictly sequential). This means the app should never approach the
  limit under correct behavior — if it's hitting the ceiling anyway, that
  strongly implies leaked/not-fully-released connections accumulating over
  a long session, not a simultaneous-open-count problem.
- Apple's confirmed guidance: always call `.cancel()` explicitly on a
  connection before discarding it — never rely on ARC/reference release,
  which is non-deterministic and can leave a connection (and its retain
  cycle via handler closures) alive far longer than expected.
- SMB2/SMB3 protocol fully supports reading many files over one session
  (multiple CREATE/READ/CLOSE cycles per authenticated session, plus
  compound-request and multi-credit capabilities for even more efficiency).
  This means the "NAS drops the session after ~2 reads" behavior observed
  against the UNAS Pro is very likely a device-specific quirk/bug, not a
  protocol limitation — but per the constraint above, this must NOT be
  relied upon; the architecture must work even against a NAS that genuinely
  only tolerates 1-2 reads per session.

### Stage 1 — connection cleanup fixes (DONE in ScanCoordinator.swift, deployed but NOT YET RE-VERIFIED under sustained load in MediaSourceReader.swift)

**Critical finding: the actual `SMBClient` library (kishikawakatsumi/SMBClient)
was cloned and its real source read directly — it is NOT the leak source.**
`Connection.disconnect()` correctly calls `NWConnection.cancel()`.
`SMBClient.logoff()` has `defer { session.disconnect() }`, unconditionally
chaining down to that cancel call. The library does the right thing. Any
future investigation should NOT re-litigate whether the library itself is
at fault — it isn't, verified directly against real source, not
documentation or inference.

**The actual leak was in Sorriva's own reconnect-after-timeout code.** In
`ScanCoordinator.swift`, exactly 3 of 8 places that create a fresh
`SMBClient` after abandoning an old one skipped calling
`disconnectShare()`/`logoff()` on the old one first — relying on ARC to
eventually clean it up, which is exactly the non-deterministic pattern
Apple's guidance warns against. One of the three had a comment explicitly
saying "without disconnecting," based on the reasonable-sounding but
backwards assumption that a hung connection is unsafe to call cleanup
methods on. **It's the opposite: `.cancel()` is specifically designed to
safely force-release a connection's resources regardless of its current
state — verified this is safe by tracing `Connection.send()`'s actual
behavior: it fails fast (throws) rather than hanging when the connection is
in `.waiting`/`.failed` state, and `SMBClient.logoff()`'s `defer` block
still runs `NWConnection.cancel()` even if the SMB-protocol-level logoff
message itself throws.** All 3 sites fixed: explicit
`disconnectShare()`+`logoff()` before every reassignment, matching the
pattern the other 5 (already-correct) sites used.

**A structurally different, more significant version of the same problem
found in `MediaSourceReader.swift`'s `SMBMediaSourceReader.readHeader`** —
this is the function called once per file across the ENTIRE main scan
(hundreds of calls per run), so it's plausibly the highest-impact site of
all. The actual network work runs inside `Task.detached`, while a separate
`DispatchQueue` waits on a semaphore for at most 15 seconds and gives up if
it doesn't fire. **The background task was never cancelled when the
timeout fired** — it just kept running, however long, never reaching its
own cleanup code if the underlying operation was genuinely hung (not just
slow) rather than eventually erroring out on its own. Swift Task
cancellation is cooperative and SMBClient's own async methods don't check
for it, so simply calling `.cancel()` on the outer task wrapper would NOT
have reliably interrupted a stuck network operation.
**Fix implemented:** restructured so the `SMBClient` instance is created
outside `Task.detached` and shared with the timeout handler; when the
timeout fires, the timeout handler explicitly calls `client.logoff()`
directly (fire-and-forget) on the shared client. This forces
`NWConnection.cancel()`, which reliably completes any outstanding
receive/send with an error — unblocking whatever the stuck background task
was awaiting, letting it exit (its own cleanup becomes redundant but
harmless) rather than leaking indefinitely. Also fixed a smaller gap: the
login-failure branch wasn't calling `logoff()` at all before this fix, even
though login can fail after the underlying connection was already
established.

**This fix (MediaSourceReader.swift) was deployed but not yet re-tested
under sustained load — this should be the very first thing done in a new
session on this topic:** run a full scan on the current ~476-track library,
confirm no NWError 12 recurrence, then (per Tom's stated plan) deliberately
scale up past ~512 (the documented ceiling figure) to see what actually
happens now.

### Stage 2 — NOT STARTED
The architectural fix: move from "fresh connection per file" (the current,
now leak-free, but inherently expensive worst-case baseline that works
against any NAS regardless of quality) to session reuse — read multiple
files over one authenticated SMB session where the NAS allows it, falling
back to per-file reconnection transparently the moment a session drops,
regardless of whether that's after 1 file or 500. This must remain fully
correct against a NAS that only tolerates 1-2 reads per session (the
observed UNAS Pro behavior) — session reuse is a pure performance
optimization layered on top of the reliable baseline, never a
correctness requirement. Not yet designed in any detail — this is
genuinely the next real conversation to have once Stage 1 is confirmed
solid under real testing.

### Testing plan already stated by Tom, follow it
1. Test on the current real library (~476 files) first.
2. Then deliberately increase past ~512 (the documented per-process ceiling
   figure) and observe what happens.
3. This will inform whether Stage 1 alone is sufficient for realistic
   library sizes, or whether Stage 2 (session reuse) is required sooner
   rather than later. Tom's real library is 10,000+ tracks — that's the
   actual target scale this needs to hold up against.

---

## Summary of roadmap IDs referenced in this document
`fScannerIdentityIntegrity` (done), `bArtworkSelectionNotBestWins` (done),
`bArtworkArtistQuery` (open, corrected diagnosis),
`fArtworkManualSearchUtility` (not started), `fArtworkPassTestSeam` (not
started), `bEmbeddedArtRetryNeverResolves` (done),
`bFailedReadCreatesWrongAlbumFromFallback` (done),
`bScanConnectionExhaustionOnRepeatedScans` (high priority, Stage 1 done/
needs re-verification, Stage 2 not started — this is the real name of "the
priority" issue in roadmap-data.json), `bDuplicateAlbumDetection` (not
started), `bTagEditsNotDetected` (not started), `fScanFailureUtility`
(reclassified out, not scanner hardening).
