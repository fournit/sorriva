# Sorriva — Reliability Gate Readiness Assessment

## How to use this document

This is an honest audit of what's actually verified versus what's merely
marked "done" in roadmap-data.json, specifically for the purpose of
deciding whether the seven-day reliability gate (started 2026-07-24,
criteria: "repeat scans are idempotent" and "critical failures produce
actionable diagnostics") can be trusted as currently running, or whether it
needs to be restarted once specific open items are closed.

This document does not recommend a decision — that's a risk-tolerance call
for Tom to make, not something to presume. It exists to make sure that
decision is made with an accurate picture, not an optimistic one. The
pattern this session repeatedly demonstrated: things marked "done" turned
out to have real bugs, found only when someone actually ran a fresh test
against them rather than trusting the checkmark. Don't repeat that pattern
here — verify, don't assume, and if verification hasn't happened, say so
plainly rather than inferring it probably would have gone fine.

Repo: github.com/fournit/sorriva | Mini: ~/projects/sorriva-app/

---

## IMPORTANT — this document's first version was incomplete; read this section first

The first pass at this assessment used a pre-filtered list of roadmap items
based on what seemed relevant from recent session work, not a systematic
pass through the entire roadmap. When directly challenged on this ("did you
go through all the WP packages?"), the honest answer was no — and a full
pass surfaced two items that materially change the picture. Both are
folded into the tiers and table below, but are significant enough to call
out explicitly up front:

**`bScannerTestSeam` (High priority, NOT done).** `ScannerTests.swift` — an
older, 16-test file, distinct from the newer real-scanner-path test files
built this week — never instantiates `SMBScanner` at all; every test in it
drives `SorrivaDatabaseTestable`, a hand-written stand-in. Checked
precisely rather than assumed: of the 16 tests, 10 cover unrelated
components (playback, keychain, migrations, etc.) where the fake database
is a harmless convenience, not a risk. Two more (`testFullScanTwicePreservesIDs`,
`testMetadataChangeUpdatesExistingTrack`) genuinely overlap with tests
built this week that DO exercise the real scanner via `MediaSourceReader`
— so those specific behaviors are independently verified elsewhere despite
this particular test being untrustworthy on its own. **That leaves exactly
two tests with real, unverified exposure:** `testDeletedFileRemovedOnFolderRescan`
and `testFailedWriteDoesNotMarkFolderComplete` — genuine scanner behaviors
with no real-path equivalent anywhere else found.

**`bMissingTracksInAlbum` (High priority, NOT done) — a real, live,
previously-undiscussed bug, with a new complication from tonight's work.**
Some albums show only one track when the NAS folder holds a full album.
Root cause not yet identified. The roadmap's own analysis ranks candidates
by likelihood, most likely first: **(1) an interrupted incremental scan —
`deleteTracksInFolder` removes every track in a changed folder before
re-adding them one at a time, so cancellation or backgrounding partway
leaves the folder partially populated, and `fScanResume` (also not built)
means nothing repairs it automatically; (2) SMBClient's `listDirectory`
returning a truncated entry set on large folders, consistent with known
UNAS Pro session behavior; (3) a full scan cancelled mid-folder.**
Diagnostics recommended (cheapest first): pick one affected album, count
files in that folder on the NAS directly, compare against the "SCAN:
folder done" line's reported count in the scan log for that path; check
the "SCAN: START" line's total file count against the true library total;
query `scan_skips` for that folder to rule out skips.

**The complication:** this bug's own "ruled out" reasoning explicitly
states *"read failures do not cause missing rows because a Track is still
written from path data when a header read fails."* That's exactly the
behavior `bFailedReadCreatesWrongAlbumFromFallback` removed tonight, for
good reason (it was causing wrong album names). But the side effect: a
track that now fails both its initial read AND all 5 retry attempts has
ZERO representation in the library, where before it would have had at
least a path-derived stub row. This is a legitimate, correct trade-off
for the bug that was actually fixed — but it may be making this separate,
already-open bug worse in a specific case that hasn't been checked. This
interaction was not previously known or considered when the fix shipped.

---



**"Repeat scans are idempotent."** Technically achieved at the track level
— `upsertTrackIdempotent` is the real production write path, verified.
**Important nuance the original criterion didn't capture:** idempotent is
not the same as self-correcting. `resolveAlbum` is a pure "find existing by
folder path, else create" — once an album is created, nothing ever
re-evaluates or corrects its title/artist, even if better data becomes
available later. This session's evidence (the "12 Inch Dance 80s Remix"
wrong-album saga) showed exactly why this matters: idempotency prevented
*duplication*, but did nothing to prevent a *wrong* album from persisting
indefinitely once created. Worth deciding whether "idempotent" as a gate
criterion needs a companion criterion about self-correction, or whether
that's explicitly out of scope for this gate and belongs to a different
initiative (the fix already applied — never build an album from a failed
read — addresses the most common trigger, but doesn't guarantee no wrong
album can ever be created by some other path).

**"Critical failures produce actionable diagnostics."** This one has real,
demonstrated gaps, found repeatedly throughout this session, not
hypothetically:
- `ArtworkCache.swift` used bare `print()` instead of `sLog()` — its entire
  activity was invisible in every exported debug log until fixed partway
  through this session. For a period of testing, online-fetch behavior was
  completely unauditable.
- The same gap existed in at least one function in `ZoneDiscoveryService.swift`
  (`fetchAllStationMetadata`) — fixed the same way.
- A missing log line meant "folder had real image candidates but every
  single one failed to read" was previously silent — you'd see nothing
  explaining why an album ended up with no art. Fixed, but only after it
  actively obscured a real diagnostic session.
- The embedded-art retry loop was silently stuck (showing "attempt 2/5"
  forever without incrementing) for an unknown period before being
  noticed — the diagnostic signal existed in the log, but nothing flagged
  it as an anomaly requiring attention.

**Given how many of these were found this session alone, each one only
surfacing because a specific investigation happened to shine a light on
that exact spot, it is reasonable to suspect more exist that haven't been
found yet.** This is not a reason to distrust everything, but it is a
reason not to assume "no more diagnostic gaps exist" without more
deliberate auditing.

---

## Item-by-item, tiered by actual confidence

### Tier 1 — Solid, verified via fresh reproduction after the fix, high confidence

**bFailedReadCreatesWrongAlbumFromFallback (done, High priority).** Fixed,
then explicitly re-tested with a second fresh full scan targeting the exact
original repro case — confirmed the album now resolves correctly. This is
the standard the rest of this list should be held to.

**bID3v2EmbeddedArtRejectedWholeFile (done, High priority).** Fixed based
on a real uploaded file, verified with a dedicated passing test using that
exact file as a fixture. Narrow, well-scoped, solid.

**bAlbumGenreFromFirstTrack (done, Low priority).** v14 migration, has
dedicated tests (`AlbumGenreTests`), confirmed passing in later test runs
this session. Low-risk change, well covered.

### Tier 2 — Fixed via precise diagnosis, NOT yet re-confirmed via fresh reproduction

**bEmbeddedArtRetryNeverResolves (done, High priority).** The root cause
was found with high precision (traced the exact flag mismatch between what
gets cleared and what the retry queue checks) and the fix directly
addresses it. But unlike the item above, **there has not been an explicit
follow-up scan specifically confirming the "stuck at attempt N/5 forever"
pattern is actually gone.** Several scans happened after this fix, but none
of them were specifically checked for a recurrence of this pattern.
Recommend: grep the most recent post-fix logs for repeated
"attempt N/5" on the same album across multiple retry passes before
trusting this is closed.

### Tier 3 — Substantially reworked, functionally verified, but younger/less battle-tested than the core scanner work

**bArtworkSelectionNotBestWins (done, Normal priority).** The redesign
itself is real and tested (10 new tests). But this item's actual history
within the session was: marked done → real bugs found via live testing
(hang on timeout, embedded pass stopping at first track, online fetch
overwriting correct art with wrong matches) → fixed → re-verified with two
subsequent fresh scans. The final state is solid, but this went through
more iteration-after-"done" than anything else on this list, which is
itself informative: it suggests live-testing surfaces real bugs that unit
tests and code review don't, for this specific area of the codebase.
Recommend treating this as adequately verified but keeping an eye out
during the gate period specifically for artwork-related anomalies, given
its history.

### Tier 4 — Core logic solid, but a significant dependency changed very recently and has NOT been stress-tested at all

**fScannerIdentityIntegrity (done, Critical priority).** The WP-02 fix
itself (idempotent upsert, the core identity/write correctness work) was
thoroughly tested early and should be trusted. **However:** the connection-
handling layer underneath it — `MediaSourceReader.swift`'s
`SMBMediaSourceReader.readHeader`, called once per file across the entire
scan — received a significant structural fix late in this session (force-
cancelling a hung background task on timeout, to address a real connection
leak). **This fix has been deployed but not yet tested under any real
load.** This is the single most important verification gap on this entire
list, because it sits underneath every other scanner operation. If this
fix has a subtle problem, it could manifest as scan failures that get
misattributed to something else during gate testing, rather than being
recognized as a regression in this specific area.

### Not done, explicitly flagged as high-priority and gate-relevant

**bScanConnectionExhaustionOnRepeatedScans (not done, High priority).**
This is the "NWError 12 / Cannot allocate memory" investigation — Stage 1
(the leak fixes referenced in Tier 4 above) is deployed but unverified
under load; Stage 2 (session reuse, the real architectural fix) hasn't
started. Given Tom's own framing of this as close to an existential product
question, and given it directly affects scan reliability at the scale the
gate is meant to validate, **this is the strongest candidate for "the gate
shouldn't be trusted as fully meaningful until this is stress-tested."**
Full context: see the separate scanner-hardening handoff document.

**bMissingTracksInAlbum (not done, High priority).** A real, live,
open bug — some albums show only one track when the NAS folder holds a
full album. Not previously part of any assessment of this codebase this
session until a full roadmap pass surfaced it. See the section above for
full detail, including a real, newly-identified interaction with tonight's
`bFailedReadCreatesWrongAlbumFromFallback` fix. Most-likely cause per the
roadmap's own ranking is an interrupted incremental scan combined with
`fScanResume` not being built yet to repair the resulting partial state —
meaning this bug and the not-started `fScanResume` item are likely linked,
not independent.

**bScannerTestSeam (not done, High priority).** Precisely scoped above —
not a reason to distrust the WP-02 identity work broadly (that work is
independently verified via newer real-scanner-path tests), but two specific
scanner behaviors (`testDeletedFileRemovedOnFolderRescan`,
`testFailedWriteDoesNotMarkFolderComplete`) currently have zero real-path
verification, tested only against a hand-written stand-in that could
silently diverge from what `SMBScanner` actually does.

### Not done, lower urgency, worth knowing about but likely not gate-blocking

**bCanonicalIdentityBackfillStale (not done, Normal priority).** The WP-12
canonical identity backfill was run before the current artist-resolution
fix existed, meaning some canonical identity records may still reflect
stale (pre-fix) artist resolution. Doesn't affect what the gate is
measuring directly (scan reliability, not data-quality of historical
backfills), but worth remembering it's still pending.

**fScannerPolish sub-items not started** — `bDuplicateAlbumDetection`,
`bTagEditsNotDetected`. Feature/quality work, not reliability-gate-relevant.

**fScannerDatabaseInjection (not done).** Future test-seam improvement, not
gate-relevant.

---

## Summary table

| Item | Status | Confidence |
|---|---|---|
| bFailedReadCreatesWrongAlbumFromFallback | Done | High — re-verified |
| bID3v2EmbeddedArtRejectedWholeFile | Done | High — tested |
| bAlbumGenreFromFirstTrack | Done | High — tested |
| bEmbeddedArtRetryNeverResolves | Done | Medium — needs fresh-log recheck |
| bArtworkSelectionNotBestWins | Done | Medium-high — verified but iterated a lot |
| fScannerIdentityIntegrity | Done | Core logic high; connection layer beneath it UNTESTED |
| bScanConnectionExhaustionOnRepeatedScans | **Not done** | Stage 1 deployed/unverified, Stage 2 not started |
| bMissingTracksInAlbum | **Not done** | Open, live bug; new interaction with tonight's fix, unchecked |
| bScannerTestSeam | **Not done** | Narrow, precise exposure — 2 specific behaviors unverified via real path |
| bCanonicalIdentityBackfillStale | Not done | Low urgency, not gate-relevant |
| fScanResume | Not done | High priority, likely linked to bMissingTracksInAlbum |
| fScannerPolish remainder | Not done | Feature work, not gate-relevant |

---

## Recommended next actions (in order), pending Tom's call on whether this changes the gate clock

1. **Stress-test the connection-leak fix** (Tom's own already-stated plan:
   test at current library size, then deliberately push past ~512 files)
   before trusting anything else on this list, since it sits underneath
   every scan operation.
2. **Run bMissingTracksInAlbum's own recommended diagnostics** (cheapest
   first, already specified in its roadmap record): pick one affected
   album, count real files in that NAS folder, compare against the "SCAN:
   folder done" line's reported count in the scan log; check the "SCAN:
   START" total against the true library total; query `scan_skips` for
   that folder. This is an open, live, high-priority bug that hasn't been
   investigated at all yet, and tonight's fix may have changed its
   behavior in an uncertain direction — worth confirming with a fresh scan
   whether it's better, worse, or unaffected.
3. **Re-check recent logs for the embedded-art retry pattern** specifically
   — quick, should take minutes, closes the one Tier 2 gap.
4. **Decide whether to port the two at-risk ScannerTests.swift behaviors**
   (`testDeletedFileRemovedOnFolderRescan`, `testFailedWriteDoesNotMarkFolderComplete`)
   to the real MediaSourceReader-based test seam, so they're no longer
   running only against a hand-written stand-in.
5. **Decide explicitly** whether the seven-day gate clock should: continue
   as-is (accepting the fixes above as sufficient), restart from zero once
   the connection-leak fix is stress-tested (since that's arguably the
   precondition for any scan result being trustworthy), or some other
   explicit choice. This should be a deliberate decision, not something
   that happens by default because the clock is already running.
