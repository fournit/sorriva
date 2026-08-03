# Documentation-vs-Code Audit

**Date:** 2026-08-03
**Scope:** All 11 engineering + handoff markdown docs vs. the `ios/` Swift source
**Tree:** ~v0.0.54 (post scan-session-ledger, post ios/server restructure)
**Method:** Per-claim verification — every concrete claim traced to a
file/type/test; the loudest/contradicted claims spot-checked against source
directly. No code was changed producing this audit.

---

## Why this exists

The engineering docs are the project's stated source of truth — CLAUDE.md points
every new session at them before scanner or playback work. When their status
claims drift from the code, each future session inherits a wrong map. This audit
records, honestly, **what is done, what remains, and what is stale**, with
citations, as of the date above.

## The one-paragraph picture

The **correctness, scanner, persistence, and ledger work is genuinely done and
test-backed** — the docs that track it (`05_Status_and_Roadmap`, the three
scanner/ledger/playback handoffs) are trustworthy. The **presentation-layer
architecture the docs present as core does not exist** — no `ScreenModel` layer,
no `PassioneUI`/`SorrivaMusicUI` packages, no `HouseholdContext`. And a **middle
tier of seams is built but bypassed**: `SourceResolver`, `CanonicalTrackID`, the
typed `EndpointCommand` driver, and `PlaybackStore`'s write side all exist as
types, but the live playback path still runs `PlaybackIntent(Track)` →
`LocalPlaybackService`/legacy SOAP helpers. **The docs' acceptance checkmarks run
ahead of the code.**

## Three-tier reality model

1. **Done & verified** — scanner identity/idempotent upsert, safe migration
   recovery, Keychain credentials, playback-metadata correctness, consolidated
   polling, artwork best-wins, the scan-session ledger (v18/v19), retry circuit
   breaker. Backed by real-scanner tests.
2. **Built but bypassed** (scaffolded, not adopted) — `SourceResolver`, canonical
   identity + `track_representations` (tables/backfill done, API not cut over),
   typed `EndpointCommand`/`SonosEndpointDriver`, `PlaybackStore` write side. The
   seams compile and are unit-tested but are not on the live data path.
3. **Unbuilt** — `ScreenModel` layer (5 named), `HouseholdContext` / invariant
   I-012, `PassioneUI`+`SorrivaMusicUI` UI packages, design tokens.

---

## Per-document verdict

| Doc | Verdict | Recommended action |
|-----|---------|--------------------|
| `01_Constitution` | Drifting — I-004/007/008 accurate; I-002/003/006/012 aspirational | Mark aspirational invariants as "target, not current" |
| `02_Architecture` | Leaf types real; **struct shapes + ScreenModel/HouseholdContext stale** | Fix struct field-lists; label unbuilt layers |
| `03_Implementation_Plan` | Plan solid; **acceptance checkmarks ahead of reality** | Correct overstated acceptance bullets (WP-07/08/09/11/12/13) |
| `04_Decisions_and_Patterns` | Drifting — infra ADRs real; **presentation patterns contradicted** | Reconcile Pattern A + prohibited-pattern claims; drop fictional `FolderReconciler` |
| `05_Status_and_Roadmap` | **Broadly accurate (strongest)** | Two small fixes: circuit-breaker done, test/file counts |
| `06_UI_Specification` | **Badly stale / purely aspirational** | Re-label as "target design, not implemented" |
| `HANDOFF-scanner-hardening` | Current on fixes; **TL;DR stale** (logoff→disconnect; load-test gap closed) | Update TL;DR; keep for trail |
| `HANDOFF-scanner-architecture` | **Highly current** | Keep active; only item 7 remains |
| `HANDOFF-scan-session-ledger` | **Accurately current** | Keep active; steps 6–8 open |
| `HANDOFF-playbackstore-architecture` | Accurate & current | Keep as live brief; fix one over-absolute line |
| `HANDOFF-gate-readiness-assessment` | **Partly stale — archival candidate** | Archive after gate decision; keep 2 live items |

---

## Work completed (verified in code)

- **Scanner identity & idempotent persistence** — `upsertTrackIdempotent` is the
  sole production write (`SMBScanner.swift:981`, def `SorrivaDatabase.swift:1674`);
  real-scanner tests in `ScannerIdentityTests`/`ScannerRegressionTests`.
- **Safe migration recovery** — backup-before-migrate + restore-on-failure, no
  auto-delete (`SorrivaDatabase.swift:79-123`).
- **Keychain credentials** — `KeychainCredentialStore` + v12 migration nulls
  plaintext (`CredentialStore.swift:22`, `SorrivaDatabase.swift:745`).
- **Playback-metadata correctness** — pin removed, per-URI advancement,
  idempotent `observe()` (`PlaybackContextService.swift:48,62-73`).
- **Consolidated polling** — single poller w/ adaptive back-off
  (`ZoneDiscoveryService.swift:789,797`); views read the store.
- **Artwork best-wins** — v15 dimensions, pure selector, header-only image reader
  (`ArtworkBestWins.swift`, `ImageDimensionReader.swift:37`).
- **Scan-session ledger** — v18/v19 schema, one-row-per-file plan, audit
  arithmetic, 20-test suite (`SorrivaDatabase.swift:936-1040`, `ScanLedgerTests`).
- **Retry circuit breaker** — `ScanRetryScheduler.swift:227` (docs 03/05 still
  list this as remaining — understated).
- **Connection-leak fix verified at scale** — 11,670-file scan, zero NWError 12
  (baked into `MediaSourceReader.swift:97-113,304-322`). Supersedes the
  "unverified under load" framing in scanner-hardening + gate-readiness.

## Work remaining (real open items)

**Adopt the built-but-bypassed seams (biggest gap):**

- Route playback through `SourceResolver` (not called by
  `PlaybackCoordinator.route`, `PlaybackCoordinator.swift:63-159`).
- Cut playback API over to `CanonicalTrackID` (`PlaybackIntent` still carries
  `Track`, `PlaybackIntent.swift:11`).
- Route Sonos commands through typed `driver.execute(EndpointCommand)` instead of
  legacy helper methods (`PlaybackCoordinator.swift:84-117`); also make
  `SonosEndpointDriver` formally declare `: AudioEndpointDriver`
  (`SonosEndpointDriver.swift:14` — currently duck-typed).
- `PlaybackStore` write side / declare-vs-mutate refactor (handoff §4-6, not
  started); add missing `activeQueue`, `selectedHouseholdID`.

**Named-but-unbuilt:**

- `HouseholdContext` / invariant I-012 — no type exists.
- `ScreenModel` layer + move DB/SOAP out of Views (I-003). LibraryView alone has
  21 direct `SorrivaDatabase.shared` calls; NowPlayingView holds raw SOAP.
- `PassioneUI`/`SorrivaMusicUI` packages + tokens (WP-15, gated behind WP-14).

**Open scanner/ledger items (correctly flagged by their handoffs):**

- `bRetrySchedulerReportsPhantomArtPending` — live at
  `ScanRetryScheduler.swift:117,133`.
- Ledger steps 6–8 (share export, management review UI, inline track counts).
- Scanner-architecture item 7 (share-overlap validation/absorb).
- `bMissingTracksInAlbum` — still open; **priority conflict** across docs (High in
  01/05, Low in 02) needs one source-of-truth decision in roadmap-data.json.

## Unnecessary / stale (cleanup candidates)

- **Dead SOAP in `NowPlayingView.swift:262-345`** — `fetchTrackInfo`/
  `parsePositionInfo` are now unreferenced (view reads the store). Safe delete.
- **Fictional named seams in docs** — `FolderReconciler`, `DiscoveredMediaFile`,
  `resumeArtworkIfNeeded(source:)` (renamed/absorbed into the ledger). Remove the
  names from 02/04/scanner-architecture, and the stale comment at
  `SorrivaDatabase.swift:2381`.
- **`06_UI_Specification`** — describes an unbuilt architecture as "APPROVED".
  Re-label as target, or move out of the current-state corpus.
- **`HANDOFF-gate-readiness-assessment`** — central thesis ("connection fix
  untested under load", "`fScanResume` not built") overtaken by code; archival
  candidate once its gate decision is recorded.
- **Small count drifts in `05`** — `swift-config.json` is 77 files (not 75);
  `ArtworkSelectionTests` has 12 tests (not 10).

---

## Notes on method & confidence

- Line cites were resolved live during the audit. The loudest contradictions
  (ScreenModel/PassioneUI/HouseholdContext absence, direct DB calls in views, raw
  SOAP in NowPlayingView, `session.disconnect` vs `logoff`, the phantom-art bug)
  were independently spot-checked against source.
- **Runtime measurements are not disputed but are unverifiable statically** —
  the 11,670-file scan, timing numbers, and pass/fail test counts were taken as
  reported; code is consistent with them.
- **No hard code contradictions of behavior were found.** The closest was
  PlaybackStore's absolute "nothing ever clears `stationName`" vs. the HDMI/TV
  clear at `ZoneDiscoveryService.swift:878` — a wording imprecision, not a
  behavioral contradiction of the doc's argument.
