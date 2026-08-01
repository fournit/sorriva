import Foundation
import SwiftUI
import Combine
import UIKit
import SMBClient
import GRDB

// MARK: - ScanCoordinator

@MainActor
final class ScanCoordinator: ObservableObject {

    static let shared = ScanCoordinator()

    // MARK: - Published state

    @Published var activeScanSourceId: String? = nil
    @Published var progress: ScanProgress? = nil
    @Published var lastReport: ScanReport? = nil
    @Published var pendingFullScanSource: LibrarySource? = nil
    @Published var interruptedScanSource: LibrarySource? = nil
    @Published var statusMessages: [String] = []  // live pipeline messages for UI display

    nonisolated func appendStatus(_ message: String) {
        Task { @MainActor in
            ScanCoordinator.shared.statusMessages.append(message)
            if ScanCoordinator.shared.statusMessages.count > 50 {
                ScanCoordinator.shared.statusMessages.removeFirst()
            }
        }
    }

    func clearStatus() {
        statusMessages = []
    }  // set when incomplete scan detected

    // MARK: - Private

    private var lastCheckForChanges: Date = .distantPast
    private let scanner = SMBScanner()
    private var scanTask: Task<Void, Never>? = nil

    /// Handle on the post-scan pipeline (artwork passes + retry scheduler). Held
    /// so a wedged pipeline can be cancelled — scanTask.cancel() does not reach
    /// it, because it runs in a detached task that outlives the scan itself.
    private var pipelineTask: Task<Void, Never>? = nil

    /// Wall-clock of the last observable pipeline progress. Updated by the scan
    /// loop and by every artwork album iteration.
    ///
    /// Exists because a hang anywhere in the post-scan pipeline used to be
    /// unrecoverable without a force-quit: scanState -> "retrying" and
    /// activeScanSourceId = nil both happen AFTER the artwork passes, so a stall
    /// during artwork left the app permanently believing a scan was healthy and
    /// running. Observed 2026-07-29: folder art pass stopped mid-album-10 when
    /// the app was backgrounded and never resumed across two foregrounds and
    /// fifteen minutes, with none of its own timeouts firing.
    private var lastPipelineProgress: Date? = nil

    /// How long without progress before the pipeline is presumed wedged.
    /// Generous — a single slow album read plus reconnect can legitimately take
    /// well over a minute, and a false positive here interrupts real work.
    private let pipelineStallThreshold: TimeInterval = 240

    /// Has this source ever recorded a completed folder?
    ///
    /// Distinguishes "never scanned" from every other state. Both scanState
    /// "idle" (the schema default for a new source) and an empty folder_stats
    /// table mean the same thing, and neither should trigger automatic work:
    /// the first scan of a share is a deliberate user action, not something a
    /// foreground transition should start.
    /// Does this source have a session with work still outstanding?
    ///
    /// fScanSessionLedger — replaces asking scan_skips and the artwork queue
    /// separately. Those were two parallel queues with their own lifecycles,
    /// each clobberable by other components, and neither could say whether the
    /// work they held belonged to a session that was still live.
    private func hasOutstandingWork(_ source: LibrarySource) -> Bool {
        // `try?` on a throwing function that returns an optional flattens to a
        // single optional, so this guard fully unwraps it.
        guard let active = try? SorrivaDatabase.shared.activeScanSession(sourceId: source.id) else {
            // No live session. Fall back to the old artwork queue for sources
            // scanned before v18/v19 — they have no ledger to consult.
            return !((try? SorrivaDatabase.shared.albumsNeedingEmbeddedArtRetry()) ?? []).isEmpty
        }
        return (try? SorrivaDatabase.shared.sessionHasOutstandingWork(sessionId: active.id)) ?? false
    }

    private func hasBeenScanned(_ source: LibrarySource) -> Bool {
        let stats = (try? SorrivaDatabase.shared.folderFingerprints(sourceId: source.id)) ?? [:]
        return !stats.isEmpty
    }

    /// Heartbeat entry point for ScanRetryScheduler, which is a separate actor
    /// and outlives the scan pipeline. Without it the watchdog cannot see the
    /// retry passes at all, so a hang there is invisible and unrecoverable.
    nonisolated func notePipelineProgressExternal() {
        notePipelineProgress()
    }

    nonisolated private func notePipelineProgress() {
        Task { @MainActor in ScanCoordinator.shared.lastPipelineProgress = Date() }
    }

    private init() {}

    nonisolated private func scanLog(_ message: String) {
        sLog(message)
        appendStatus(message)
    }

    // MARK: - Public API

    /// Called when a new share is saved — queues confirmation alert.
    func scanNewSource(_ source: LibrarySource) {
        pendingFullScanSource = source
    }

    /// Called from confirmation alert — user confirmed full scan.
    func confirmAndScanSource(_ source: LibrarySource) {
        guard activeScanSourceId != source.id else {
            sLog("SCAN: ignoring duplicate scan request for \(source.displayName) — already active")
            return
        }
        pendingFullScanSource = nil
        interruptedScanSource = nil
        // Explicit full rescan — discard any interrupted session so this run
        // cannot inherit it and skip folders the user expects to be re-read.
        try? SorrivaDatabase.shared.setCurrentScanSessionId(sourceId: source.id, sessionId: nil)
        // Retention: the scan record survives automatic scans and is cleared
        // only when the user manually scans that same share.
        try? SorrivaDatabase.shared.clearScanSessions(sourceId: source.id)
        try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "scanning")
        clearStatus()
        lastReport = nil
        startFullScan(source: source)
    }

    /// Manual "Scan Now" from ShareActionSheet — queues confirmation.
    func scanSource(_ source: LibrarySource) {
        pendingFullScanSource = source
    }

    /// Called when app foregrounds.
    /// Skips never-scanned sources (require confirmation).
    /// Detects interrupted scans and surfaces restart option.
    /// Runs incremental rescan for changed folders on completed sources.
    /// Restarts retry scheduler if pending skips exist and no scan is active.
    func checkForChanges() {
        let now = Date()
        guard now.timeIntervalSince(lastCheckForChanges) > 30 else {
            sLog("SCAN: checkForChanges — skipped (debounce)")
            return
        }
        lastCheckForChanges = now
        sLog("SCAN: checkForChanges — scene became active")
        Task {
            let sources = (try? SorrivaDatabase.shared.allLibrarySources()) ?? []
            for source in sources {
                guard source.type == "smb" else { continue }

                // Scanning is strictly one-at-a-time. There is a single scanTask
                // property, so starting a second scan silently overwrites the
                // handle for the first — the loop then races ahead launching
                // more, and `await scanTask?.value` waits on whichever handle
                // happens to be current rather than the one just started.
                //
                // This became reachable when the change check started calling a
                // full scan for EVERY scanned source rather than only those with
                // detected changes: seven sources meant seven overlapping scans
                // in ~130ms, clobbering each other and leaving sources in
                // 'error' (observed 2026-07-30). Whatever is not reached this
                // pass is picked up on the next foreground.
                if let active = activeScanSourceId {
                    sLog("SCAN: checkForChanges — stopping, scan already running (\(active))")
                    break
                }
                sLog("SCAN: checkForChanges — \(source.displayName) [\(source.share)\(source.rootPath == "/" ? "" : source.rootPath)] scanState='\(source.scanState)'")

                // A source stuck at "scanning" with no active task in THIS
                // process means the scan was killed — iOS terminated the app
                // mid-scan, so neither the completion path nor runScan's catch
                // block ever ran to move the state off "scanning".
                //
                // The previous `guard scanState != "scanning"` skipped these
                // outright, so a killed scan produced no alert, no resume, and a
                // source that showed a live ScanStatusPanel forever. The
                // launch-time reset that sorriva-context.html documents was
                // never actually built; this is that reset, done at the only
                // place that can distinguish "killed" from "running".
                if source.scanState == "scanning" {
                    // fScanSessionLedger, rule 2. Liveness is now a property of
                    // the SESSION, not of an in-memory flag.
                    //
                    // activeScanSourceId cannot survive a kill, cannot say
                    // whether a live scan is actually progressing, and cannot
                    // describe what is outstanding — which is why a separate
                    // lastPipelineProgress heartbeat had to be bolted alongside
                    // it, and why a killed scan used to be detectable only via a
                    // scanState string four code paths write to.
                    //
                    // scan_sessions.lastProgressAt is written by every ledger
                    // outcome, so it survives termination and answers all three.
                    if let live = try? SorrivaDatabase.shared.activeScanSession(sourceId: source.id),
                       Date().timeIntervalSince1970 - Double(live.lastProgressAt) < pipelineStallThreshold {
                        continue    // session is live and progressing
                    }
                    if activeScanSourceId == source.id {
                        // Believed healthy — but verify it is actually making
                        // progress. Without this check a wedged pipeline is
                        // permanent: nothing downstream ever runs to move the
                        // state off "scanning", and this branch would keep
                        // reporting "genuinely running" forever.
                        let idle = Date().timeIntervalSince(lastPipelineProgress ?? Date())
                        if idle < pipelineStallThreshold {
                            continue    // genuinely running right now
                        }
                        sLog("SCAN: pipeline WEDGED for \(source.displayName) — no progress in \(Int(idle))s, recovering")
                        scanTask?.cancel()
                        pipelineTask?.cancel()
                        scanTask = nil
                        pipelineTask = nil
                        activeScanSourceId = nil
                        progress = nil
                        lastPipelineProgress = nil
                        UIApplication.shared.isIdleTimerDisabled = false
                        try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "error")
                        interruptedScanSource = source
                        continue
                    }
                    sLog("SCAN: killed scan detected for \(source.displayName) — offering resume")
                    try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "error")
                    interruptedScanSource = source
                    continue
                }

                switch source.scanState {
                case "idle":
                    // "idle" is ALSO the schema default for a newly added
                    // source, so it cannot be read as "was scanned, then
                    // stranded". A source with no folder_stats has never run —
                    // leave it dormant. Promoting it to "complete" made the
                    // change check below treat every folder as new and start a
                    // full 673-file import unprompted (observed 2026-07-30).
                    guard hasBeenScanned(source) else {
                        sLog("SCAN: \(source.displayName) never scanned — leaving idle")
                        continue
                    }
                    // Recovery for sources stranded by the old updateScanComplete,
                    // which set 'idle' the moment the file pass ended. Anything
                    // killed between that write and 'retrying' is stuck here, and
                    // 'idle' previously matched no branch — so those sources got
                    // no alert and no change detection, permanently. Treat a
                    // stranded 'idle' with pending work as an interrupted scan;
                    // otherwise promote it to 'complete' so change detection
                    // resumes normally.
                    if hasOutstandingWork(source) {
                        sLog("SCAN: stranded 'idle' with pending work for \(source.displayName) — offering resume")
                        try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "error")
                        interruptedScanSource = source
                    } else {
                        sLog("SCAN: stranded 'idle' with empty queues — marking complete for \(source.displayName)")
                        try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "complete")
                    }

                case "error":
                    // A source with no folder_stats has nothing to resume TO —
                    // resuming would walk the tree, find zero recorded folders,
                    // and run a full import. That is the same unprompted-scan
                    // problem in a different guise, and it is exactly what a
                    // library drop leaves behind if anything wrote 'error'
                    // afterward. Reset to idle instead: the share is simply
                    // unscanned, and the user starts it deliberately.
                    guard hasBeenScanned(source) else {
                        sLog("SCAN: \(source.displayName) in 'error' but never scanned — resetting to idle")
                        try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "idle")
                        try? SorrivaDatabase.shared.setCurrentScanSessionId(sourceId: source.id, sessionId: nil)
                        continue
                    }
                    // bPhantomScanInterruptedDialog — dissolved rather than
                    // patched. Since the unified scan model, every foreground
                    // briefly sets scanState 'scanning' for an automatic change
                    // check, so a kill in that window produced a "scan did not
                    // complete" dialog for a scan the user never started and
                    // which did no work. The session records BOTH its trigger
                    // and what it planned, so that case is now identifiable:
                    // an automatic run with nothing planned needs no decision,
                    // it simply runs again on the next foreground.
                    if let last = try? SorrivaDatabase.shared.activeScanSession(sourceId: source.id),
                       last.trigger == SorrivaDatabase.ScanTrigger.automatic.rawValue,
                       last.plannedFiles == 0 {
                        sLog("SCAN: interrupted automatic check with no planned work — resetting silently")
                        try? SorrivaDatabase.shared.updateScanSessionState(
                            sessionId: last.id, state: .cancelled)
                        try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "complete")
                        continue
                    }
                    sLog("SCAN: interrupted scan detected for \(source.displayName)")
                    interruptedScanSource = source

                case "retrying":
                    if !hasOutstandingWork(source) {
                        sLog("SCAN: retrying state but queues empty — marking complete for \(source.displayName)")
                        try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "complete")
                    } else if await ScanRetryScheduler.shared.isRunning {
                        sLog("SCAN: retry scheduler already running — skipping restart for \(source.displayName)")
                    } else {
                        sLog("SCAN: resuming retry scheduler for \(source.displayName)")
                        let active = try? SorrivaDatabase.shared.activeScanSession(sourceId: source.id)
                        await ScanRetryScheduler.shared.start(source: source, scanner: scanner,
                                                             ledgerSessionId: active?.id)
                    }

                case "complete":
                    // fUnifiedScanWalkThenFilter — automatic change detection is
                    // now the SAME operation as a manual scan. It walks the tree
                    // and skips folders whose fingerprint still matches, so new
                    // folders, changed folders and deletions are all handled by
                    // one code path.
                    //
                    // This replaces findChangedFolders, which iterated
                    // folder_stats rather than the disk and therefore could not
                    // see a newly added folder at all (bNewFoldersNotDetected) —
                    // new music never appeared until a manual rescan. It also
                    // walked once per known folder instead of once total, and
                    // leaked a connection per foreground check by tearing down
                    // without session.disconnect().
                    //
                    // Cost of the walk is listDirectory only, no header reads.
                    // If nothing changed the scan filters to zero files and ends
                    // in well under a second (measured: 0.5s over 104 files).
                    // Never-scanned sources are skipped here on purpose. With no
                    // folder_stats there is nothing to compare against, so the
                    // filter would classify every folder as new and this would
                    // become a full initial import triggered by a foreground
                    // rather than by the user. Initial scans stay user-initiated.
                    guard hasBeenScanned(source) else {
                        sLog("SCAN: \(source.displayName) never scanned — skipping change check")
                        continue
                    }
                    // An interrupted artwork phase has no other way back in —
                    // the passes only ever ran inside a scan's pipeline task, so
                    // quitting during artwork lost that work permanently: the
                    // file scan was complete, so the change check found nothing
                    // to do and simply returned (observed 2026-07-30).
                    if (try? SorrivaDatabase.shared.hasPendingArtworkWork(sourceId: source.id)) == true {
                        let artSession = (try? SorrivaDatabase.shared.currentScanSessionId(sourceId: source.id))
                            ?? nil
                        ScanLogSession.begin(artSession ?? UUID().uuidString)
                        sLog("SCAN: pending artwork work for \(source.displayName) — resuming artwork only")
                        let artActive = try? SorrivaDatabase.shared.activeScanSession(sourceId: source.id)
                        await runArtworkPasses(source: source, ledgerSessionId: artActive?.id)
                        ScanLogSession.end()
                        continue
                    }

                    sLog("SCAN: change check for \(source.displayName)")
                    startFullScan(source: source, trigger: .automatic)
                    await scanTask?.value

                default:
                    break
                }
            }
        }
    }

    // MARK: - Private scan starters

    /// fScanResume — continue a scan that was killed mid-flight. Reuses the
    /// interrupted run's session id so folders it already completed are skipped.
    /// Distinct from confirmAndScanSource, which deliberately starts clean.
    func resumeScan(source: LibrarySource) {
        guard activeScanSourceId != source.id else {
            sLog("SCAN: ignoring resume for \(source.displayName) — already active")
            return
        }
        pendingFullScanSource = nil
        interruptedScanSource = nil
        clearStatus()
        lastReport = nil

        let resumeId = (try? SorrivaDatabase.shared.currentScanSessionId(sourceId: source.id)) ?? nil
        if let resumeId {
            sLog("SCAN: resuming session \(resumeId) for \(source.displayName)")
        } else {
            sLog("SCAN: no recorded session for \(source.displayName) — resuming as full scan")
        }

        if activeScanSourceId == source.id { scanTask?.cancel() }
        scanTask = Task {
            await runScan(source: source, folders: nil,
                          resumeSessionId: resumeId ?? "resume")
        }
    }

    private func startFullScan(source: LibrarySource,
                               trigger: SorrivaDatabase.ScanTrigger = .manual) {
        if activeScanSourceId == source.id { scanTask?.cancel() }
        // Fresh session — a user-initiated full scan must never skip folders,
        // or "Scan Now" on a completed source would do nothing.
        scanTask = Task {
            await runScan(source: source, folders: nil,
                          resumeSessionId: nil,
                          triggerKind: trigger)
        }
    }


    /// Establishes session identity for the whole run, then delegates.
    ///
    /// ONE id. There used to be two — a scan sessionId used for the
    /// folder_stats stamp and the log tag, and a separate ledger session id used
    /// for the audit. They were different UUIDs for the same thing, so the log
    /// said one and the audit said another (2026-08-01: scan tagged D60CE953,
    /// retry tagged 107962AD, same run). Two identifiers for one concept is the
    /// same duplication that produced the parallel-queue bugs this ledger
    /// replaced.
    ///
    /// The ledger id wins because it is the durable one: scan_sessions survives
    /// a kill and is recoverable via activeScanSession, whereas
    /// currentScanSessionId is cleared at pipeline completion.
    ///
    /// The tag is bound around the ENTIRE run rather than set globally, because
    /// a second scan starting while the first was still in its artwork phase
    /// used to overwrite the first scan's tag. A task-local is scoped to this
    /// task and its children, so concurrent pipelines cannot interfere.
    private func runScan(source: LibrarySource, folders: [String]?,
                         resumeSessionId: String?,
                         triggerKind: SorrivaDatabase.ScanTrigger = .manual) async {
        // Resume continues the existing session; anything else opens a new one.
        let sessionId: String
        if resumeSessionId != nil,
           let active = try? SorrivaDatabase.shared.activeScanSession(sourceId: source.id) {
            sessionId = active.id
            sLog("SCAN: ledger — resuming session \(active.id.prefix(8)) (\(active.plannedFiles) planned)")
        } else {
            let trigger: SorrivaDatabase.ScanTrigger = resumeSessionId != nil ? .resume : triggerKind
            sessionId = (try? SorrivaDatabase.shared.createScanSession(
                sourceId: source.id, trigger: trigger)) ?? UUID().uuidString
        }

        await ScanLogSession.with(sessionId) {
            await runScanBody(source: source, folders: folders,
                              sessionId: sessionId,
                              resumeSessionId: resumeSessionId,
                              triggerKind: triggerKind)
        }
    }


    private func runScanBody(source: LibrarySource, folders: [String]?,
                         sessionId: String, resumeSessionId: String?,
                         triggerKind: SorrivaDatabase.ScanTrigger = .manual) async {
        activeScanSourceId = source.id
        lastPipelineProgress = Date()
        // Recorded BEFORE the scan starts, so if the app is killed mid-scan the
        // session id survives and a resume can find the folders it completed.
        try? SorrivaDatabase.shared.setCurrentScanSessionId(sourceId: source.id, sessionId: sessionId)
        try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "scanning")
        ScanLogSession.begin(sessionId)

        // fScanSessionLedger — sessionId IS the ledger session, established by
        // the wrapper above. Kept as an optional-shaped local so the call sites
        // below read unchanged.
        let ledgerSessionId: String? = sessionId

        sLog("SCAN: state -> scanning (resume=\(resumeSessionId != nil))")

        // Prevent screen lock during scan
        UIApplication.shared.isIdleTimerDisabled = true

        do {
            if let folders = folders {
                try await scanner.scanChangedFolders(source: source, folderPaths: folders,
                                                     scanSessionId: sessionId,
                                                     ledgerSessionId: ledgerSessionId) { [weak self] p in
                    Task { @MainActor [weak self] in self?.handleProgress(p) }
                }
            } else {
                try await scanner.scan(source: source,
                                       scanSessionId: sessionId,
                                       resumeSessionId: resumeSessionId,
                                       ledgerSessionId: ledgerSessionId) { [weak self] p in
                    Task { @MainActor [weak self] in self?.handleProgress(p) }
                }
            }
            print("SCAN: Completed — \(source.displayName)")
        } catch {
            sLog("SCAN: Failed — \(source.displayName): \(error)")
            sLog("SCAN: state -> error")
            if let ledgerSessionId {
                try? SorrivaDatabase.shared.updateScanSessionState(
                    sessionId: ledgerSessionId, state: .failed)
            }
            ScanLogSession.end()
            // Session id deliberately left in place — it is what a resume needs.
            try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "error")
            UIApplication.shared.isIdleTimerDisabled = false
            if activeScanSourceId == source.id {
                activeScanSourceId = nil
                progress = nil
            }
            return
        }

        NotificationCenter.default.post(name: .libraryDidUpdate, object: nil)

        pipelineTask = Task.detached { [weak self] in
            guard let self else { return }
            // Task.detached deliberately does NOT inherit task-locals, so the
            // pipeline rebinds the tag. Without this the artwork and retry lines
            // come out untagged — exactly what the 2026-08-01 log showed for the
            // LEDGER: artwork line.
            await ScanLogSession.with(sessionId) {
            // bArtworkSelectionNotBestWins — embedded art is checked first since
            // it has the highest likelihood of being high-resolution (e.g. the
            // real-world MP3 case found during the ID3v2 investigation). Folder
            // pass always runs its cheap header-check afterward regardless of
            // what embedded found, since the folder could genuinely have
            // something better — only its expensive download is conditional.
            // Online fetch runs last, only for albums still below its fixed
            // 600×600 ceiling.
            if let ledgerSessionId {
                try? SorrivaDatabase.shared.updateScanSessionState(
                    sessionId: ledgerSessionId, state: .artwork)
            }
            let (embeddedArtFound, folderArtFound) = await self.runArtworkPasses(
                source: source, ledgerSessionId: ledgerSessionId)

            // Mark as retrying before scheduler starts
            try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "retrying")
            if let ledgerSessionId {
                try? SorrivaDatabase.shared.updateScanSessionState(
                    sessionId: ledgerSessionId, state: .retrying)
            }
            sLog("SCAN: state -> retrying")
            // Session id deliberately NOT cleared here. The retry scheduler runs
            // after this point, can be restarted independently after a kill, and
            // needs the id to re-establish its log tag so its lines stay
            // searchable alongside the scan that produced their queue. The
            // scheduler clears it when it genuinely completes.
            self.scanLog("SCAN: pipeline complete — starting retry scheduler for \(source.displayName)")
            await ScanRetryScheduler.shared.start(source: source, scanner: self.scanner,
                                                  ledgerSessionId: ledgerSessionId)

            // Pass 1 done — restore screen lock and clear active state
            await MainActor.run {
                UIApplication.shared.isIdleTimerDisabled = false
                if self.activeScanSourceId == source.id {
                    self.activeScanSourceId = nil
                    self.progress = nil
                }
                // Pipeline finished cleanly — retire the watchdog so a later
                // idle period can't be mistaken for a wedge.
                self.lastPipelineProgress = nil
                self.pipelineTask = nil
                // ScanLogSession is NOT ended here. The retry scheduler starts
                // just above and owns the tag from this point until it genuinely
                // completes — ending it here raced the scheduler and stripped the
                // session id off every RETRY line after the first two (observed
                // 2026-07-31).
            }

            // Enrich report with artwork and retry totals
            let artworkFound    = folderArtFound + embeddedArtFound
            let audit = ledgerSessionId.flatMap {
                try? SorrivaDatabase.shared.scanSessionAudit(sessionId: $0)
            } ?? [:]
            let permanent       = audit["permanent"] ?? 0
            let retried         = audit["resolved"] ?? 0
            await MainActor.run {
                if var report = self.lastReport {
                    report.artworkFound      = artworkFound
                    report.tracksRetried     = max(0, retried)
                    report.permanentFailures = permanent
                    self.lastReport = report
                }
            }
            }
        }
    }

    private func handleProgress(_ p: ScanProgress) {
        lastPipelineProgress = Date()
        if p.phase == .complete {
            // Enrich report with source-level totals — incremental scans only show partial counts otherwise
            if var report = p.report {
                let sourceId = report.sourceId
                report.tracksIndexed = (try? SorrivaDatabase.shared.trackCount(sourceId: sourceId)) ?? report.tracksIndexed
                report.albumsFound   = (try? SorrivaDatabase.shared.albums(sourceId: sourceId).count) ?? report.albumsFound
                lastReport = report
            } else {
                lastReport = p.report
            }
        } else {
            progress = p
        }
    }

    // MARK: - Folder artwork pass

    @discardableResult
    private func runFolderArtPass(source: LibrarySource, ledgerSessionId: String? = nil) async -> Int {
        // Marker-driven, not every album in the source. Previously this
        // re-checked EVERY album on every scan — a rescan touching 2 folders
        // still checked all 11 (observed 2026-07-30), which at ~1000 albums
        // means a full pass of NAS reads for folders nobody touched. Markers are
        // reset at scan start for exactly the folders being scanned, so
        // best-wins re-evaluation still happens for changed folders and nowhere
        // else. Also makes the pass resumable: a kill mid-pass leaves the
        // already-checked albums marked.
        let albums = (try? SorrivaDatabase.shared.albumsNeedingFolderArtScan(sourceId: source.id)) ?? []
        guard !albums.isEmpty else {
            scanLog("ARTWORK: folder pass — nothing to scan")
            return 0
        }
        var found = 0

        // One persistent connection for the entire pass.
        var client = SMBClient(host: source.host)
        do {
            try await client.login(username: source.loginCredentials.username, password: source.loginCredentials.password)
            try await client.connectShare(source.share)
        } catch {
            scanLog("ARTWORK: folder pass — failed to connect: \(error.localizedDescription)")
            return 0
        }

        for (idx, album) in albums.enumerated() {
            // Heartbeat — proves the pass is alive. Without this a hang here is
            // invisible and unrecoverable (see lastPipelineProgress).
            notePipelineProgress()

            // Marked via `defer`, which is the only construct that gets both
            // cases right.
            //
            // It runs on normal completion AND on every `continue` exit (manual
            // override, no folder path, reconnect-after-timeout, no winner, no
            // winner path) — so an album that was genuinely considered is marked
            // whatever the outcome, and the pass always drains rather than
            // sticking on an album that can never produce artwork.
            //
            // It does NOT run when the process is killed, because no code does.
            // So an album interrupted mid-check stays unmarked and is retried on
            // resume, which is the point of the marker. Marking at the top of
            // the iteration instead would have treated a killed album as done
            // and silently skipped its artwork.
            defer { try? SorrivaDatabase.shared.markFolderArtScanned(albumId: album.id) }

            guard !album.artManualOverride else {
                self.scanLog("ARTWORK: folder [\(idx+1)/\(albums.count)] SKIP manual override — \(album.title)")
                continue
            }
            guard !album.folderPath.isEmpty else {
                self.scanLog("ARTWORK: folder [\(idx+1)/\(albums.count)] SKIP no folder path — \(album.title)")
                continue
            }

            // Always run the cheap check, even if a prior pass (embedded, or an
            // earlier scan) already found something — bArtworkSelectionNotBestWins.
            // The folder might genuinely have something better; only the
            // expensive download below is conditional on actually winning.
            self.scanLog("ARTWORK: folder [\(idx+1)/\(albums.count)] checking — \(album.artistName) · \(album.title)")

            var pathsByName: [String: String] = [:]
            var measured: [ArtworkBestWins.Candidate] = []
            var candidateFileCount = 0

            do {
                let entries = try await client.listDirectory(path: album.folderPath)

                let imageExts  = Set(["jpg", "jpeg", "png"])
                let thumbWords = ["small", "thumb", "mini", "tiny"]
                let candidateFiles = entries.filter { entry in
                    let ext  = (entry.name as NSString).pathExtension.lowercased()
                    let name = entry.name.lowercased()
                    guard imageExts.contains(ext) else { return false }
                    guard !thumbWords.contains(where: { name.contains($0) }) else { return false }
                    return true
                }

                if candidateFiles.isEmpty {
                    self.scanLog("ARTWORK: folder [\(idx+1)/\(albums.count)] no image files found")
                }
                candidateFileCount = candidateFiles.count

                // Cheap pass — header-only read of every candidate to compare true
                // pixel area, instead of fully decoding each one just to check size.
                for candidate in candidateFiles {
                    let artPath = album.folderPath == "/"
                        ? "/\(candidate.name)"
                        : "\(album.folderPath)/\(candidate.name)"

                    var timedOut = false
                    let headerData: Data? = await withCheckedContinuation { continuation in
                        let semaphore = DispatchSemaphore(value: 0)
                        var result: Data? = nil
                        Task.detached {
                            let reader = client.fileReader(path: artPath)
                            result = try? await reader.read(offset: 0, length: 16384)
                            try? await reader.close()
                            semaphore.signal()
                        }
                        DispatchQueue.global(qos: .utility).async {
                            if semaphore.wait(timeout: .now() + 10) == .timedOut {
                                self.scanLog("ARTWORK: folder [\(idx+1)/\(albums.count)] header TIMEOUT — \(candidate.name)")
                                timedOut = true
                            }
                            continuation.resume(returning: result)
                        }
                    }

                    if timedOut {
                        // NAS drops SMB sessions after a timeout — the connection is
                        // now in a bad state and every subsequent read on it will also
                        // time out until it's replaced. Reconnect before continuing,
                        // same recovery the download step below already does.
                        //
                        // Explicitly disconnect/logoff the OLD client before replacing
                        // it — even though it's in a bad state. Per Apple DTS guidance,
                        // NWConnection.cancel() (reached ONLY via session.disconnect() --
                        // logoff() does NOT trigger it; see bScanConnectionExhaustionOnRepeatedScans)
                        // is specifically designed to safely force-
                        // release a connection's resources regardless of its current
                        // state; relying on ARC to eventually deallocate an abandoned
                        // client instead is the non-deterministic pattern that leaks
                        // kernel connection resources over a long scan session.
                        scanLog("ARTWORK: folder — reconnecting after header timeout")
                        let staleClient = client
                        Task { try? await staleClient.disconnectShare(); try? await staleClient.logoff(); staleClient.session.disconnect() }
                        client = SMBClient(host: source.host)
                        if await reconnectWithTimeout(client: client, source: source) {
                            scanLog("ARTWORK: folder — reconnected")
                        } else {
                            scanLog("ARTWORK: folder — reconnect failed/timed out, will retry next album")
                        }
                    }

                    guard let header = headerData,
                          let dims = ImageDimensionReader.dimensions(data: header) else { continue }

                    pathsByName[candidate.name] = artPath
                    measured.append(ArtworkBestWins.Candidate(name: candidate.name, width: dims.width, height: dims.height))
                }
            } catch {
                self.scanLog("ARTWORK: folder [\(idx+1)/\(albums.count)] error — \(error.localizedDescription)")
                let staleClient = client
                Task { try? await staleClient.disconnectShare(); try? await staleClient.logoff(); staleClient.session.disconnect() }
                client = SMBClient(host: source.host)
                if await reconnectWithTimeout(client: client, source: source) {
                    scanLog("ARTWORK: folder — reconnected")
                } else {
                    scanLog("ARTWORK: folder — reconnect failed/timed out, will retry next album")
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }

            guard let winner = ArtworkBestWins.selectWinner(
                candidates: measured, storedWidth: album.artworkWidth, storedHeight: album.artworkHeight
            ) else {
                if !measured.isEmpty {
                    self.scanLog("ARTWORK: folder [\(idx+1)/\(albums.count)] best candidate does not beat stored \(album.artworkWidth ?? 0)×\(album.artworkHeight ?? 0) — skip download")
                    if let ledgerSessionId, album.artPathThumb != nil {
                        // Already has artwork and nothing beat it — settled.
                        try? SorrivaDatabase.shared.recordArtworkOutcome(
                            sessionId: ledgerSessionId, albumId: album.id,
                            outcome: .written, resolvedBy: .folder, incrementAttempt: true)
                    }
                } else if candidateFileCount > 0 {
                    // Real image files existed in the folder, but not one of them
                    // produced a readable header — every candidate hit a timeout or
                    // an unparseable header. Previously silent; this album ends up
                    // with no artwork from this pass and it wasn't obvious why.
                    self.scanLog("ARTWORK: folder [\(idx+1)/\(albums.count)] NO USABLE CANDIDATE — \(candidateFileCount) image file(s) found but none produced a readable header")
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            guard let winnerPath = pathsByName[winner.name] else {
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }

            // Winner beats what's stored — download in full and save.
            var downloadTimedOut = false
            let downloaded: Data? = await withCheckedContinuation { continuation in
                let semaphore = DispatchSemaphore(value: 0)
                var result: Data? = nil
                Task.detached {
                    result = try? await client.download(path: winnerPath)
                    semaphore.signal()
                }
                DispatchQueue.global(qos: .utility).async {
                    if semaphore.wait(timeout: .now() + 20) == .timedOut {
                        self.scanLog("ARTWORK: folder [\(idx+1)/\(albums.count)] download TIMEOUT — \(winner.name)")
                        downloadTimedOut = true
                    }
                    continuation.resume(returning: result)
                }
            }
            if downloadTimedOut {
                scanLog("ARTWORK: folder — reconnecting after download timeout")
                let staleClient = client
                Task { try? await staleClient.disconnectShare(); try? await staleClient.logoff(); staleClient.session.disconnect() }
                client = SMBClient(host: source.host)
                if await reconnectWithTimeout(client: client, source: source) {
                    scanLog("ARTWORK: folder — reconnected")
                } else {
                    scanLog("ARTWORK: folder — reconnect failed/timed out, will retry next album")
                }
            }

            if let data = downloaded, let image = UIImage(data: data) {
                let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let artDir  = docsDir.appendingPathComponent("artwork", isDirectory: true)
                try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
                let fullURL  = artDir.appendingPathComponent("\(album.id)_full.jpg")
                let thumbURL = artDir.appendingPathComponent("\(album.id)_thumb.jpg")
                if let fullData  = resized(image, to: 600)?.jpegData(compressionQuality: 0.85),
                   let thumbData = resized(image, to: 300)?.jpegData(compressionQuality: 0.85) {
                    try? fullData.write(to: fullURL)
                    try? thumbData.write(to: thumbURL)
                    try? SorrivaDatabase.shared.updateAlbumArtworkWithDimensions(
                        albumId: album.id,
                        thumbPath: "artwork/\(album.id)_thumb.jpg",
                        fullPath:  "artwork/\(album.id)_full.jpg",
                        width: winner.width, height: winner.height
                    )
                    found += 1
                    if winner.width < 200 && winner.height < 200 {
                        self.scanLog("ARTWORK: folder [\(idx+1)/\(albums.count)] SAVED LOW-RES (\(winner.width)×\(winner.height)px, nothing better found) — \(album.artistName) · \(album.title)")
                    } else {
                        self.scanLog("ARTWORK: folder [\(idx+1)/\(albums.count)] SAVED — \(winner.name) (\(winner.width)×\(winner.height)px) — \(album.artistName) · \(album.title)")
                    }
                    if let ledgerSessionId {
                        try? SorrivaDatabase.shared.recordArtworkOutcome(
                            sessionId: ledgerSessionId, albumId: album.id,
                            outcome: .written, resolvedBy: .folder, incrementAttempt: true)
                    }
                    await MainActor.run {
                        NotificationCenter.default.post(name: .artworkDidUpdate, object: album.id)
                    }
                }
            }

            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms between albums
        }

        try? await client.disconnectShare()
        try? await client.logoff()
        client.session.disconnect()
        scanLog("ARTWORK: folder pass COMPLETE — \(found)/\(albums.count) found")
        return found
    }

    func resized(_ image: UIImage, to maxDimension: CGFloat) -> UIImage? {
        let size = image.size
        let scale = min(maxDimension / size.width, maxDimension / size.height)
        if scale >= 1 { return image }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }

    @discardableResult
    /// Attempts login + connectShare with a hard timeout, returning whether it
    /// succeeded. Without this, a reconnect attempted right after a read
    /// timeout (i.e. exactly when the NAS is most likely still unresponsive)
    /// could hang indefinitely with nothing to interrupt it — this is what
    /// caused a real embedded-art-pass lockup: the read timeout's own recovery
    /// was working correctly, but the reconnect attempt that followed it had
    /// no timeout of its own and froze the whole scan loop silently.
    private func reconnectWithTimeout(client: SMBClient, source: LibrarySource, timeoutSeconds: Double = 10) async -> Bool {
        await withCheckedContinuation { continuation in
            let semaphore = DispatchSemaphore(value: 0)
            var succeeded = false
            Task.detached {
                if (try? await client.login(username: source.loginCredentials.username, password: source.loginCredentials.password)) != nil,
                   (try? await client.connectShare(source.share)) != nil {
                    succeeded = true
                }
                semaphore.signal()
            }
            DispatchQueue.global(qos: .utility).async {
                if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
                    self.scanLog("ARTWORK: reconnect TIMEOUT — NAS still unresponsive")
                    // Force-release, same reasoning as the read-timeout path —
                    // don't leave this Task.detached's login/connectShare hanging
                    // indefinitely if it never completes on its own.
                    client.session.disconnect()
                }
                continuation.resume(returning: succeeded)
            }
        }
    }

    // MARK: - Artwork passes

    /// Runs all three artwork passes in order.
    ///
    /// Extracted so it can be invoked from two places: the scan pipeline, and
    /// the change check when an interrupted artwork phase needs to continue
    /// without a scan. Previously the passes existed only inside the pipeline
    /// task, so quitting during artwork lost that work with no way back in —
    /// the file scan was already complete, so the next foreground found nothing
    /// to do and simply returned (observed 2026-07-30).
    ///
    /// bArtworkSelectionNotBestWins — embedded is checked first since it has the
    /// highest likelihood of being high-resolution. The folder pass always runs
    /// its cheap header-check afterward regardless of what embedded found, since
    /// the folder could genuinely have something better; only its expensive
    /// download is conditional. Online runs last, and only for albums still
    /// below its fixed 600x600 ceiling.
    @discardableResult
    private func runArtworkPasses(source: LibrarySource,
                                  ledgerSessionId: String? = nil) async -> (embedded: Int, folder: Int) {
        // fScanSessionLedger — plan the artwork work now rather than at scan
        // start, because the albums only exist once the file pass has created
        // them. Idempotent, so a resume keeps the outcomes it already recorded.
        if let ledgerSessionId {
            let albums = (try? SorrivaDatabase.shared.albums(sourceId: source.id)) ?? []
            let rows = albums
                .filter { !$0.artManualOverride }
                .map { (albumId: $0.id, folderPath: $0.folderPath ?? "") }
            try? SorrivaDatabase.shared.recordArtworkPlan(
                sessionId: ledgerSessionId, sourceId: source.id, albums: rows)
            sLog("SCAN: ledger — planned artwork for \(rows.count) album(s)")
        }

        sLog("SCAN: PHASE artwork-embedded START")
        let embedded = await runEmbeddedArtPass(source: source, ledgerSessionId: ledgerSessionId)
        sLog("SCAN: PHASE artwork-embedded END")

        // A 30s pause used to sit between these passes to let the NAS recover.
        // That pressure was SMBClient never calling NWConnection.cancel() --
        // every read leaked a kernel flow entry and the NAS was refusing service
        // to a client holding hundreds of abandoned sockets
        // (bScanConnectionExhaustionOnRepeatedScans, fixed 2026-07-29). With
        // that fixed, 600 back-to-back connections ran with zero stalls and flat
        // timing, so the pause was pure dead time. Removed rather than
        // shortened: if stalls return we want to see them, not have them masked.
        sLog("SCAN: PHASE artwork-folder START")
        let folder = await runFolderArtPass(source: source, ledgerSessionId: ledgerSessionId)
        sLog("SCAN: PHASE artwork-folder END")

        sLog("SCAN: PHASE artwork-online START")
        await ArtworkCache.shared.fetchMissingArtwork(sourceId: source.id,
                                                      ledgerSessionId: ledgerSessionId)
        sLog("SCAN: PHASE artwork-online END")

        // Settle rows no pass touched. An album that already had artwork is
        // skipped by all three selections, so its row would otherwise sit at
        // 'planned' forever and the session could never complete.
        if let ledgerSessionId {
            try? SorrivaDatabase.shared.settleUntouchedArtworkRows(sessionId: ledgerSessionId)
            let a = (try? SorrivaDatabase.shared.scanSessionAudit(
                sessionId: ledgerSessionId, kind: .artwork)) ?? [:]
            sLog("LEDGER: artwork — written \(a["written"] ?? 0), still failing \(a["skipped"] ?? 0), none found \(a["permanent"] ?? 0), unaccounted \(a["planned"] ?? 0)")
        }

        return (embedded, folder)
    }

    private func runEmbeddedArtPass(source: LibrarySource, ledgerSessionId: String? = nil) async -> Int {
        let albums = (try? SorrivaDatabase.shared.albumsNeedingEmbeddedArtScan(sourceId: source.id)) ?? []
        guard !albums.isEmpty else {
            scanLog("ARTWORK: embedded pass — nothing to scan")
            return 0
        }
        var found = 0

        // One persistent connection for the entire pass
        var client = SMBClient(host: source.host)
        do {
            try await client.login(username: source.loginCredentials.username, password: source.loginCredentials.password)
            try await client.connectShare(source.share)
        } catch {
            scanLog("ARTWORK: embedded pass — failed to connect: \(error.localizedDescription)")
            return 0
        }

        for (idx, album) in albums.enumerated() {
            // Heartbeat — proves the pass is alive. Without this a hang here is
            // invisible and unrecoverable (see lastPipelineProgress).
            notePipelineProgress()
            guard !album.folderPath.isEmpty else {
                try? SorrivaDatabase.shared.markEmbeddedArtScanned(albumId: album.id)
                continue
            }

            let tracks = (try? SorrivaDatabase.shared.tracks(albumId: album.id)) ?? []
            guard !tracks.isEmpty else {
                try? SorrivaDatabase.shared.markEmbeddedArtScanned(albumId: album.id)
                continue
            }

            scanLog("ARTWORK: embedded [\(idx+1)/\(albums.count)] — \(album.artistName) · \(album.title)")

            var artReadErrored = false  // true if any track read threw an error (vs genuine no-art)
            struct FoundArt { let data: Data; let candidate: ArtworkBestWins.Candidate }
            var foundCandidates: [FoundArt] = []

            for track in tracks.prefix(3) {
                let ext = (track.filePath as NSString).pathExtension.lowercased()
                guard ["mp3", "flac", "m4a", "aac", "alac"].contains(ext) else { continue }

                var imageData: Data? = nil
                do {
                    let reader = client.fileReader(path: track.filePath)
                    let raw: Data? = await withCheckedContinuation { continuation in
                        let semaphore = DispatchSemaphore(value: 0)
                        var result: Data? = nil
                        Task.detached {
                            result = try? await reader.read(offset: 0, length: 1048576)
                            try? await reader.close()
                            semaphore.signal()
                        }
                        DispatchQueue.global(qos: .utility).async {
                            if semaphore.wait(timeout: .now() + 20) == .timedOut {
                                self.scanLog("ARTWORK: embedded TIMEOUT — \((track.filePath as NSString).lastPathComponent)")
                            }
                            continuation.resume(returning: result)
                        }
                    }
                    guard let rawData = raw else {
                        artReadErrored = true
                        // Timeout — explicitly disconnect/logoff the old client before
                        // replacing it, even though it's in a bad state. See the folder
                        // pass's header-timeout handling for why this matters: relying
                        // on ARC to eventually deallocate an abandoned client instead of
                        // calling cancel() is the non-deterministic pattern that leaks
                        // kernel connection resources over a long scan session.
                        scanLog("ARTWORK: embedded — creating fresh connection after timeout")
                        let staleClient = client
                        Task { try? await staleClient.disconnectShare(); try? await staleClient.logoff(); staleClient.session.disconnect() }
                        client = SMBClient(host: source.host)
                        if await reconnectWithTimeout(client: client, source: source) {
                            scanLog("ARTWORK: embedded — reconnected")
                        } else {
                            scanLog("ARTWORK: embedded — reconnect failed/timed out, will retry next album")
                        }
                        continue
                    }
                    imageData = Self.extractArt(from: rawData, ext: ext)
                } catch {
                    scanLog("ARTWORK: embedded read error — \((track.filePath as NSString).lastPathComponent): \(error.localizedDescription)")
                    artReadErrored = true
                    // Reconnect on non-timeout error
                    let staleClient = client
                    Task { try? await staleClient.disconnectShare(); try? await staleClient.logoff(); staleClient.session.disconnect() }
                    client = SMBClient(host: source.host)
                    if await reconnectWithTimeout(client: client, source: source) {
                        scanLog("ARTWORK: embedded — reconnected")
                    } else {
                        scanLog("ARTWORK: embedded — reconnect failed/timed out, will retry next album")
                    }
                    continue
                }

                // Collect this track's art rather than saving and stopping —
                // a later track in the same album can have better embedded art
                // than an earlier one (real case: "We Live Here" track 1 at
                // 200×200, track 2 at 1280×1280 — the old break-on-first logic
                // saved the worse one and never looked further).
                if let data = imageData, let dims = ImageDimensionReader.dimensions(data: data) {
                    foundCandidates.append(FoundArt(
                        data: data,
                        candidate: ArtworkBestWins.Candidate(
                            name: (track.filePath as NSString).lastPathComponent,
                            width: dims.width, height: dims.height
                        )
                    ))
                }
            }

            var artFound = false
            if let winner = ArtworkBestWins.selectWinner(
                candidates: foundCandidates.map(\.candidate),
                storedWidth: album.artworkWidth, storedHeight: album.artworkHeight
            ), let winningArt = foundCandidates.first(where: { $0.candidate == winner }),
               let image = UIImage(data: winningArt.data) {
                let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let artDir = docsDir.appendingPathComponent("artwork", isDirectory: true)
                try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
                let fullURL  = artDir.appendingPathComponent("\(album.id)_full.jpg")
                let thumbURL = artDir.appendingPathComponent("\(album.id)_thumb.jpg")
                if let fullData  = resized(image, to: 600)?.jpegData(compressionQuality: 0.85),
                   let thumbData = resized(image, to: 300)?.jpegData(compressionQuality: 0.85) {
                    try? fullData.write(to: fullURL)
                    try? thumbData.write(to: thumbURL)
                    try? SorrivaDatabase.shared.updateAlbumArtworkWithDimensions(
                        albumId: album.id,
                        thumbPath: "artwork/\(album.id)_thumb.jpg",
                        fullPath: "artwork/\(album.id)_full.jpg",
                        width: winner.width, height: winner.height
                    )
                    try? SorrivaDatabase.shared.markEmbeddedArtScanned(albumId: album.id)
                    if let ledgerSessionId {
                        try? SorrivaDatabase.shared.recordArtworkOutcome(
                            sessionId: ledgerSessionId, albumId: album.id,
                            outcome: .written, resolvedBy: .embedded, incrementAttempt: true)
                    }
                    found += 1
                    artFound = true
                    if winner.width < 200 && winner.height < 200 {
                        scanLog("ARTWORK: embedded SAVED LOW-RES (\(winner.width)×\(winner.height)px, nothing better found) — \(album.artistName) · \(album.title)")
                    } else {
                        scanLog("ARTWORK: embedded SAVED (\(winner.width)×\(winner.height)px, best of \(foundCandidates.count) track(s) checked) — \(album.artistName) · \(album.title)")
                    }
                    await MainActor.run {
                        NotificationCenter.default.post(name: .artworkDidUpdate, object: album.id)
                    }
                }
            } else if !foundCandidates.isEmpty {
                // Found embedded art, but it didn't beat what's already stored —
                // still mark scanned, this album genuinely has no better embedded art.
                try? SorrivaDatabase.shared.markEmbeddedArtScanned(albumId: album.id)
                if let ledgerSessionId {
                    // Considered and settled — the album has artwork, this pass
                    // simply had nothing better. Terminal, not a failure.
                    try? SorrivaDatabase.shared.recordArtworkOutcome(
                        sessionId: ledgerSessionId, albumId: album.id,
                        outcome: .written, resolvedBy: .embedded, incrementAttempt: true)
                }
                artFound = true
                scanLog("ARTWORK: embedded — best candidate does not beat stored \(album.artworkWidth ?? 0)×\(album.artworkHeight ?? 0), keeping existing — \(album.artistName) · \(album.title)")
            }

            if !artFound {
                if artReadErrored {
                    // Read error — not genuinely artless. Retryable.
                    try? SorrivaDatabase.shared.markEmbeddedArtFailed(albumId: album.id)
                    if let ledgerSessionId {
                        // Left 'skipped' so the later passes and the retry loop
                        // can still reach it. The ledger — not embeddedArtFailed
                        // — is now what the session consults, which is what
                        // stops resetArtworkPassMarkers silently emptying the
                        // queue (bArtworkMarkerResetClearsRetryQueue).
                        try? SorrivaDatabase.shared.recordArtworkOutcome(
                            sessionId: ledgerSessionId, albumId: album.id,
                            outcome: .skipped, failureKind: .read,
                            failureDetail: "embedded art read failed",
                            incrementAttempt: true)
                    }
                    scanLog("ARTWORK: embedded FAILED (queued for retry) — \(album.artistName) · \(album.title)")
                } else {
                    // Read fine, the file simply has no embedded art. Terminal
                    // for THIS pass but not for the album — the folder and
                    // online passes still get their turn, so the ledger row
                    // stays open and only they can close it.
                    try? SorrivaDatabase.shared.markEmbeddedArtScanned(albumId: album.id)
                    scanLog("ARTWORK: embedded — no art in file — \(album.artistName) · \(album.title)")
                }
            }

            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms between albums
        }

        try? await client.disconnectShare()
        try? await client.logoff()
        client.session.disconnect()
        scanLog("ARTWORK: embedded pass COMPLETE — \(found)/\(albums.count) found")
        return found
    }

    nonisolated static func extractArt(from data: Data, ext: String) -> Data? {
        switch ext {
        case "mp3": return extractID3Art(data: data)
        case "flac": return extractFlacArt(data: data)
        case "m4a", "aac", "alac": return extractMP4Art(data: data)
        default: return nil
        }
    }

    private nonisolated static func extractID3Art(data: Data) -> Data? {
        guard data.count > 10, data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return nil }
        let tagSize = (Int(data[6]) << 21) | (Int(data[7]) << 14) | (Int(data[8]) << 7) | Int(data[9])
        let version = data[3]
        var offset = 10
        while offset + 10 < min(tagSize + 10, data.count) {
            let frameID = String(bytes: data[offset..<offset+4], encoding: .isoLatin1) ?? ""
            if frameID == "\0\0\0\0" { break }
            let frameSize: Int
            if version >= 4 {
                frameSize = (Int(data[offset+4]) << 21) | (Int(data[offset+5]) << 14) | (Int(data[offset+6]) << 7) | Int(data[offset+7])
            } else {
                frameSize = (Int(data[offset+4]) << 24) | (Int(data[offset+5]) << 16) | (Int(data[offset+6]) << 8) | Int(data[offset+7])
            }
            guard frameSize > 0, offset + 10 + frameSize <= data.count else { break }
            if frameID == "APIC" {
                let frameData = Data(data[(offset+10)..<(offset+10+frameSize)]) // base-zero copy
                // Skip encoding byte, mime type, null, pic type, description, null
                var pos = 1
                while pos < frameData.count && frameData[pos] != 0 { pos += 1 }
                pos += 2 // skip null and picture type
                while pos < frameData.count && frameData[pos] != 0 { pos += 1 }
                pos += 1 // skip null after description
                if pos < frameData.count {
                    return Data(frameData[pos...])
                }
            }
            offset += 10 + frameSize
        }
        return nil
    }

    private nonisolated static func extractFlacArt(data: Data) -> Data? {
        guard data.count > 4, data[0] == 0x66, data[1] == 0x4C, data[2] == 0x61, data[3] == 0x43 else { return nil }
        var offset = 4
        while offset + 4 <= data.count {
            let blockHeader = data[offset]
            let isLast = (blockHeader & 0x80) != 0
            let blockType = blockHeader & 0x7F
            let blockSize = (Int(data[offset+1]) << 16) | (Int(data[offset+2]) << 8) | Int(data[offset+3])
            offset += 4
            if blockType == 6 && offset + blockSize <= data.count {
                let block = Data(data[offset..<(offset+blockSize)]) // base-zero copy
                guard block.count == blockSize else { offset += blockSize; if isLast { break }; continue }
                var pos = 4 // skip picture type
                guard pos + 4 <= block.count else { offset += blockSize; if isLast { break }; continue }
                let mimeLen = (Int(block[pos]) << 24) | (Int(block[pos+1]) << 16) | (Int(block[pos+2]) << 8) | Int(block[pos+3]); pos += 4
                guard pos + mimeLen + 4 <= block.count else { offset += blockSize; if isLast { break }; continue }
                pos += mimeLen
                let descLen = (Int(block[pos]) << 24) | (Int(block[pos+1]) << 16) | (Int(block[pos+2]) << 8) | Int(block[pos+3]); pos += 4
                guard pos + descLen + 20 <= block.count else { offset += blockSize; if isLast { break }; continue }
                pos += descLen + 16 // skip desc, width, height, color depth, indexed colors
                let dataLen = (Int(block[pos]) << 24) | (Int(block[pos+1]) << 16) | (Int(block[pos+2]) << 8) | Int(block[pos+3]); pos += 4
                guard pos + dataLen <= block.count else { offset += blockSize; if isLast { break }; continue }
                return Data(block[pos..<(pos+dataLen)])
            }
            offset += blockSize
            if isLast { break }
        }
        return nil
    }

    private nonisolated static func extractMP4Art(data: Data) -> Data? {
        // Find moov → udta → meta → ilst → covr → data
        func atomSize(_ d: Data, _ o: Int) -> Int {
            guard o + 4 <= d.count else { return 0 }
            return (Int(d[o]) << 24) | (Int(d[o+1]) << 16) | (Int(d[o+2]) << 8) | Int(d[o+3])
        }
        func atomName(_ d: Data, _ o: Int) -> String {
            guard o + 8 <= d.count else { return "" }
            return String(bytes: d[(o+4)..<(o+8)], encoding: .isoLatin1) ?? ""
        }
        func findAtom(_ name: String, _ d: Data, _ start: Int, _ end: Int) -> Int? {
            var pos = start
            while pos + 8 <= end {
                let size = atomSize(d, pos)
                guard size >= 8 else { break }
                if atomName(d, pos) == name { return pos }
                pos += size
            }
            return nil
        }
        let end = data.count
        guard let moov = findAtom("moov", data, 0, end) else { return nil }
        let moovEnd = min(moov + atomSize(data, moov), end)
        guard let udta = findAtom("udta", data, moov+8, moovEnd) else { return nil }
        let udtaEnd = min(udta + atomSize(data, udta), end)
        guard let meta = findAtom("meta", data, udta+8, udtaEnd) else { return nil }
        let metaEnd = min(meta + atomSize(data, meta), end)
        guard let ilst = findAtom("ilst", data, meta+12, metaEnd) else { return nil }
        let ilstEnd = min(ilst + atomSize(data, ilst), end)
        guard let covr = findAtom("covr", data, ilst+8, ilstEnd) else { return nil }
        let covrEnd = min(covr + atomSize(data, covr), end)
        guard let dataAtom = findAtom("data", data, covr+8, covrEnd) else { return nil }
        let valueOffset = dataAtom + 16
        let valueEnd = min(dataAtom + atomSize(data, dataAtom), covrEnd)
        guard valueOffset < valueEnd else { return nil }
        return Data(data[valueOffset..<valueEnd])
    }

}

// MARK: - Notification names

extension Notification.Name {
    static let libraryDidUpdate = Notification.Name("SorrivaLibraryDidUpdate")
}
