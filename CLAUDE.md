# Sorriva

Native iOS/iPadOS music app for audiophiles with NAS-based local FLAC libraries and multi-room audio.

**Stack:** Swift/SwiftUI, GRDB SQLite, Sonos UPnP (port 1400), SMB/NAS via SMBClient.

**Key architecture:** Sonos pulls audio directly from the NAS via `x-file-cifs://` — the iPhone is never in the audio path for local files. Pure App Store product, no backend required for core functionality. `server/` holds docs and roadmap only; there is no Flask app to deploy.

**Read before scanner work:** `server/static/docs/handoffs/HANDOFF-scanner-hardening.md`
**Read before playback/zone work:** `server/static/docs/handoffs/HANDOFF-playbackstore-design.md` — the live spec and current state (phases A+B built; C, D, E remain). Its §14 as-built notes are the hard-won ones. Then `HANDOFF-playbackstore-architecture.md` for problem history and *rejected* patches — do not re-propose them.
**Read before ANY playback, transfer, or grouping work:** `server/static/docs/engineering/sonos-playback-contract.md` — the single authority for which Sonos command sequences work and how each one fails. Measured facts only. If another doc contradicts it, it wins.
**Read before radio/streaming-service work:** `server/static/docs/engineering/radio-service-integration.md` — each service gets its own adapter; never add a global URI heuristic.
**Engineering corpus:** `server/static/docs/engineering/` — constitution, target architecture, ADRs, UI spec.

**Known constraints — verify against source before acting on these:**

*Network flows.* iOS enforces a ~500 open-network-flow ceiling per process; exceeding it surfaces as `NWError 12` / "Cannot allocate memory". SMBClient never calls `NWConnection.cancel()` and has no `deinit`, so every header read leaked a kernel socket until the ceiling was hit. Forcing the disconnect fixed it — scans now complete 11.5k file reads. See `SMBSessionProbe.swift` and `MediaSourceReader.swift`.

Note the earlier "UNAS Pro drops sessions after ~2 reads" finding is suspect: a dropped session and an exhausted flow budget produce identical symptoms, and that measurement was taken in a process that had already leaked heavily. Do not treat it as settled.

*Connection discipline.* The directory walk holds one connection across the whole tree (`listDirectory` only), reconnecting transparently on a stall. Header reads open a fresh connection per file, force-cancelled on timeout. 1MB chunk size is empirically stable.

*Sonos.* **All Sonos command sequences live in one place: `server/static/docs/engineering/sonos-playback-contract.md`.** Do not duplicate them here — a partial copy in this file is what made a documented answer un-findable and cost a full session on 2026-08-05. Two rules worth knowing before you open it: **a 200 from Sonos does not mean success** (it validates lazily and will accept commands it silently ignores), and **local files play via the queue, never by pointing `SetAVTransportURI` at the file**.

*Artwork.* Folder, embedded, and online passes stay separate to avoid NAS connection pressure. Best-wins selection compares stored outcomes across passes rather than collapsing them.

## Read at session start

- `shared/passione-session-protocol.md` — session conventions, open/close checklist
- `shared/passione-dev-guide.md` — machines, repo structure, deploy command

## Read before specific work

- `shared/passione-roadmap-schema.md` — before any roadmap edit. Field names are `name`/`desc`, never `title`/`description`.
- `server/static/docs/roadmap-data.json` — current roadmap. Verify claims against the actual code before acting on them.

## Standing rules

- **Session ritual — every session, unconditionally.** At the first message of every session, before any work, ask Tom for the local time and record it as `session_start_time` — do not wait for an explicit "start a session" phrase. When Tom signals the end ("close", "wrap up", "done for the day"), run the Section 3 close checklist in `shared/passione-session-protocol.md`: state the start time, ask `owner_hrs` (never estimate), update `roadmap-data.json` / `sessions.json` / `version.json` / relevant handoff, then hand Tom the deploy command.
- **No code changes without explicit confirmation.** Diagnose, propose exact changes, wait for approval.
- **One terminal command at a time.** Wait for output before the next.
- **Timestamps are CDT/CST.** `TZ='America/Chicago' date`.
- **Feature IDs** are `fCamelCase` for features, `bCamelCase` for bugs.
- **Flag every new file** and ask whether it belongs in the repo.
- **Store Tom's feature descriptions verbatim.** Never rewrite them.
- **Be concise.** Answer the question asked. No preamble, no restating the request.

## Structure

```
ios/       Swift app + .xcodeproj — build with ⌘R in Xcode, no deploy needed
server/    Docs, roadmap, session state (no Flask app) — deploy with `deploy so`
shared/    Portfolio docs (symlink, gitignored)
```
