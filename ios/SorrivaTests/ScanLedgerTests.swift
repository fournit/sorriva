import XCTest
import GRDB
@testable import Sorriva

// MARK: - ScanLedgerTests
// fScanSessionLedger acceptance tests.
//
// These run the REAL SMBScanner against a real directory of real FLAC files,
// through SorrivaDatabase.shared. That is deliberate and is the difference
// between these and the older scanner tests.
//
// bScannerTestSeam exists because two existing tests reimplement scanner logic
// in a SorrivaDatabaseTestable wrapper and then assert against their own
// reimplementation — they pass whether or not production works. Here the scan
// path executes: SMBScanner walks the tree, parses tags out of bytes, writes
// ledger rows, and the assertions read what production wrote.
//
// Isolation: SorrivaDatabase.shared routes to a unique temp SQLite when
// XCTestConfigurationFilePath is set, so tests never touch the device library.
// The singleton IS shared across tests in a run, so every test uses its own
// source with a fresh UUID and its own fixture tree — rows cannot collide.

final class ScanLedgerTests: XCTestCase {

    var fixtureRoot: URL!
    var source: LibrarySource!
    var reader: FixtureMediaSourceReader!
    var scanner: SMBScanner!

    /// 3 folders x 3 tracks. Small enough to run in milliseconds, large enough
    /// that "kill at file 4" leaves a real remainder spanning a folder boundary.
    let expectedFiles = 9
    let expectedFolders = 3

    override func setUpWithError() throws {
        fixtureRoot = try LedgerTestFixtures.makeTree()
        source = Self.makeSource(rootPath: "/")
        try SorrivaDatabase.shared.upsertLibrarySource(source)
        rebuildScanner()
    }

    override func tearDownWithError() throws {
        if let fixtureRoot { try? FileManager.default.removeItem(at: fixtureRoot) }
        fixtureRoot = nil; source = nil; reader = nil; scanner = nil
    }

    /// A fresh reader (and therefore fresh counters and hooks) pointing at the
    /// current fixture tree.
    private func rebuildScanner() {
        let root = fixtureRoot!
        let r = FixtureMediaSourceReader(rootURL: root)
        reader = r
        scanner = SMBScanner(readerFactory: { _ in r })
    }

    /// Run a scan that will be interrupted, isolated in its own Task.
    ///
    /// The isolation matters: cancelScanAfterReads cancels the CURRENT task, and
    /// if the scan ran directly in the test's task it would cancel the test —
    /// after which the resume scan would see `Task.isCancelled` immediately and
    /// abort before doing anything. Wrapping it scopes the cancellation to the
    /// interrupted pass, exactly as a real app kill would.
    private func runInterruptedScan(sessionId: String, killAfter: Int) async {
        reader.cancelScanAfterReads(killAfter)
        let task = Task { [scanner, source] in
            try await scanner!.scan(source: source!,
                                    scanSessionId: sessionId,
                                    resumeSessionId: nil,
                                    ledgerSessionId: sessionId) { _ in }
        }
        _ = await task.result       // completes with CancellationError
    }

    // MARK: - Helpers

    /// Reuses TestDatabase.makeSource so these tests build a LibrarySource the
    /// same way the rest of the suite does. A UUID id per test is what keeps
    /// them isolated: SorrivaDatabase.shared is one instance for the whole test
    /// process, so rows are separated by source rather than by database.
    private static func makeSource(rootPath: String) -> LibrarySource {
        TestDatabase.makeSource(id: UUID().uuidString,
                                displayName: "Fixture",
                                host: "fixture.local",
                                share: "Fixture",
                                rootPath: rootPath)
    }

    /// Run one scan and return its ledger session id.
    @discardableResult
    private func runScan(resume: Bool = false,
                         sessionId: String? = nil) async throws -> String {
        let id: String
        if let sessionId {
            id = sessionId
        } else if resume, let active = try SorrivaDatabase.shared.activeScanSession(sourceId: source.id) {
            id = active.id
        } else {
            id = try SorrivaDatabase.shared.createScanSession(
                sourceId: source.id, trigger: resume ? .resume : .manual)
        }
        try await scanner.scan(source: source,
                               scanSessionId: id,
                               resumeSessionId: resume ? id : nil,
                               ledgerSessionId: id) { _ in }
        return id
    }

    private func audit(_ sessionId: String) throws -> [String: Int] {
        try SorrivaDatabase.shared.scanSessionAudit(sessionId: sessionId)
    }

    private func trackAudit(_ sessionId: String) throws -> [String: Int] {
        try SorrivaDatabase.shared.scanSessionAudit(sessionId: sessionId, kind: .track)
    }

    // MARK: - The invariant
    //
    // planned = written + resolved + skipped + permanent + unaccounted, and
    // unaccounted must always be zero. This is the single most important
    // assertion in the suite: a non-zero unaccounted means files were planned
    // and never reached any outcome, which is the exact failure the ledger was
    // built to make impossible.

    func testCleanScanLeavesNothingUnaccounted() async throws {
        let session = try await runScan()

        let a = try trackAudit(session)
        XCTAssertEqual(a["planned"] ?? 0, 0,
                       "No row may remain 'planned' after a clean scan")
        XCTAssertEqual(a["written"] ?? 0, expectedFiles,
                       "Every fixture file should be written")

        let unfinished = try SorrivaDatabase.shared.unfinishedLedgerFiles(sessionId: session)
        XCTAssertTrue(unfinished.isEmpty, "Unfinished: \(unfinished)")
    }

    func testPlanMatchesFilesOnDisk() async throws {
        let session = try await runScan()
        let a = try trackAudit(session)
        let total = a.values.reduce(0, +)
        XCTAssertEqual(total, expectedFiles,
                       "Ledger must plan exactly the files the walk found")
        XCTAssertEqual(reader.readCount, expectedFiles,
                       "One header read per planned file")
    }

    func testAuditTotalsToPlanned() async throws {
        let session = try await runScan()
        let a = try trackAudit(session)
        let accounted = (a["written"] ?? 0) + (a["resolved"] ?? 0)
                      + (a["skipped"] ?? 0) + (a["permanent"] ?? 0)
        XCTAssertEqual(accounted, expectedFiles)
        XCTAssertEqual(a["planned"] ?? 0, 0)
    }

    // MARK: - Change detection
    //
    // The unified walk-then-filter model: skip a folder only if file count,
    // total bytes AND newest mtime all match the stored fingerprint.

    func testUnchangedRescanReadsNothing() async throws {
        _ = try await runScan()

        rebuildScanner()                      // fresh counters
        let second = try await runScan()

        XCTAssertEqual(reader.readCount, 0,
                       "An unchanged rescan must perform ZERO header reads")
        let a = try trackAudit(second)
        XCTAssertEqual(a.values.reduce(0, +), 0,
                       "Nothing should be planned when nothing changed")
    }

    func testNewFolderDetected() async throws {
        _ = try await runScan()

        try LedgerTestFixtures.addFolder(to: fixtureRoot, spec: .init(
            folder: "Radiohead/OK Computer",
            trackTitles: ["Airbag", "Paranoid Android"],
            artist: "Radiohead", album: "OK Computer"))

        rebuildScanner()
        let second = try await runScan()

        let a = try trackAudit(second)
        XCTAssertEqual(a["written"] ?? 0, 2,
                       "Only the new folder's files should be scanned")
        XCTAssertEqual(reader.readCount, 2)
    }

    /// bTagEditsNotDetected — the case a byte check alone cannot see.
    ///
    /// Taggers write into the FLAC padding block, so file count and total bytes
    /// are unchanged and only mtime moves. Verified on device 2026-07-31 with a
    /// real Mp3tag edit; this is the deterministic version.
    func testTagEditDetectedViaModificationTime() async throws {
        _ = try await runScan()

        let target = LedgerTestFixtures.files(in: fixtureRoot).first!
        let folderOfTarget = target.deletingLastPathComponent().lastPathComponent
        try LedgerTestFixtures.touchPreservingSize(target)

        rebuildScanner()
        let second = try await runScan()

        let a = try trackAudit(second)
        XCTAssertGreaterThan(a["written"] ?? 0, 0,
            "A file whose mtime changed but size did not MUST trigger a rescan of its folder")
        XCTAssertTrue(reader.readPaths.contains { $0.contains(folderOfTarget) },
            "The touched file's folder should have been re-read")
    }

    func testChangedFileSizeDetected() async throws {
        _ = try await runScan()

        let target = LedgerTestFixtures.files(in: fixtureRoot).first!
        try LedgerTestFixtures.rewrite(target, title: "Rewritten", artist: "X",
                                       album: "Y", trackNumber: 1)

        rebuildScanner()
        let second = try await runScan()

        XCTAssertGreaterThan(try trackAudit(second)["written"] ?? 0, 0)
    }

    func testDeletedFolderReconciled() async throws {
        _ = try await runScan()
        let before = try SorrivaDatabase.shared.trackCount(sourceId: source.id)
        XCTAssertEqual(before, expectedFiles)

        try LedgerTestFixtures.removeFolder("Portishead/Dummy", from: fixtureRoot)

        rebuildScanner()
        _ = try await runScan()

        let after = try SorrivaDatabase.shared.trackCount(sourceId: source.id)
        XCTAssertEqual(after, expectedFiles - 3,
                       "Tracks in a folder removed from disk must be deleted")
    }

    /// Cheap regression guard, NOT proof of multi-source safety.
    ///
    /// Both sources here have different paths, so they could not collide even if
    /// the scoping were absent. Its value is catching a future change that
    /// computes reconciliation against all stats rather than the source's own.
    func testDeletionIsScopedBySource() async throws {
        _ = try await runScan()

        let otherRoot = try LedgerTestFixtures.makeTree(specs: [
            .init(folder: "Other/Album", trackTitles: ["A", "B"],
                  artist: "Other", album: "Album")
        ])
        defer { try? FileManager.default.removeItem(at: otherRoot) }

        let otherSource = Self.makeSource(rootPath: "/")
        try SorrivaDatabase.shared.upsertLibrarySource(otherSource)
        let otherReader = FixtureMediaSourceReader(rootURL: otherRoot)
        let otherScanner = SMBScanner(readerFactory: { _ in otherReader })
        let otherSession = try SorrivaDatabase.shared.createScanSession(
            sourceId: otherSource.id, trigger: .manual)
        try await otherScanner.scan(source: otherSource,
                                    scanSessionId: otherSession,
                                    resumeSessionId: nil,
                                    ledgerSessionId: otherSession) { _ in }

        // Now delete everything from the FIRST source and rescan it.
        try LedgerTestFixtures.removeFolder("Portishead/Dummy", from: fixtureRoot)
        rebuildScanner()
        _ = try await runScan()

        XCTAssertEqual(try SorrivaDatabase.shared.trackCount(sourceId: otherSource.id), 2,
                       "One source's reconciliation must not touch another's rows")
    }

    // MARK: - Interruption and resume
    //
    // The claim the ledger exists to support: a session is a bounded unit of
    // work that survives being killed. Verified on device across five kills in
    // three pipeline phases; these make the arithmetic cheap to re-check.

    func testResumeDoesNotReplanAndWorksTheRemainder() async throws {
        let session = try SorrivaDatabase.shared.createScanSession(
            sourceId: source.id, trigger: .manual)

        // Kill after 4 of 9 reads. NOT failReadNumber — a read failure is caught
        // and recorded, and the scan runs to completion. Only cancellation stops
        // the pass with rows still planned.
        await runInterruptedScan(sessionId: session, killAfter: 4)

        let planned = try trackAudit(session).values.reduce(0, +)
        XCTAssertEqual(planned, expectedFiles,
                       "The plan is recorded up front and must survive the interruption")

        let remainingBefore = try SorrivaDatabase.shared
            .unfinishedLedgerFiles(sessionId: session).count
        XCTAssertGreaterThan(remainingBefore, 0)
        XCTAssertLessThan(remainingBefore, expectedFiles,
                          "Some files completed before the kill")

        // Resume the SAME session.
        rebuildScanner()
        try await scanner.scan(source: source, scanSessionId: session,
                               resumeSessionId: session,
                               ledgerSessionId: session) { _ in }

        let after = try trackAudit(session)
        XCTAssertEqual(after.values.reduce(0, +), expectedFiles,
                       "Resume must NOT create additional plan rows")
        XCTAssertEqual(after["planned"] ?? 0, 0,
                       "Every planned file must reach an outcome after resume")
    }

    func testResumeKeepsTheSameSession() async throws {
        let session = try SorrivaDatabase.shared.createScanSession(
            sourceId: source.id, trigger: .manual)
        await runInterruptedScan(sessionId: session, killAfter: 3)

        let active = try SorrivaDatabase.shared.activeScanSession(sourceId: source.id)
        XCTAssertEqual(active?.id, session,
                       "The interrupted session must still be the active one")
        XCTAssertEqual(active?.plannedFiles, expectedFiles)
    }

    func testSessionNotCompleteWhileRowsRemainPlanned() async throws {
        let session = try SorrivaDatabase.shared.createScanSession(
            sourceId: source.id, trigger: .manual)
        await runInterruptedScan(sessionId: session, killAfter: 4)

        XCTAssertTrue(try SorrivaDatabase.shared.sessionHasOutstandingWork(sessionId: session),
                      "A session with planned rows is not complete")

        rebuildScanner()
        try await scanner.scan(source: source, scanSessionId: session,
                               resumeSessionId: session,
                               ledgerSessionId: session) { _ in }

        XCTAssertFalse(try SorrivaDatabase.shared.sessionHasOutstandingWork(sessionId: session),
                       "Once every row is terminal the session is complete")
    }

    // MARK: - Failure classification
    //
    // Retry policy depends on WHY a read failed. A timeout means the NAS did not
    // answer and is very likely recoverable, so it must not consume an attempt —
    // otherwise a few bad minutes permanently retire recoverable tracks. A
    // content failure is a property of the file and does consume one.

    func testReadFailureIsRecordedWithAReason() async throws {
        let session = try SorrivaDatabase.shared.createScanSession(
            sourceId: source.id, trigger: .manual)

        // Fail exactly one read, but let the scan continue past it.
        let failingCall = 3
        reader.beforeRead = { path, call in
            if call == failingCall {
                throw MediaSourceReaderError.timeout
            }
        }
        try await scanner.scan(source: source, scanSessionId: session,
                               resumeSessionId: nil,
                               ledgerSessionId: session) { _ in }

        let failures = try SorrivaDatabase.shared.scanSessionFailures(sessionId: session)
        XCTAssertEqual(failures.count, 1, "Exactly one file should have failed")
        XCTAssertEqual(failures.first?.kind, SorrivaDatabase.LedgerFailureKind.timeout.rawValue,
                       "A timeout must be recorded as kind 'timeout', not a generic read error")

        // And it is still accounted for.
        let a = try trackAudit(session)
        XCTAssertEqual(a["planned"] ?? 0, 0)
        XCTAssertEqual((a["written"] ?? 0) + (a["skipped"] ?? 0), expectedFiles)
    }

    func testTimeoutDoesNotConsumeARetryAttempt() async throws {
        let session = try SorrivaDatabase.shared.createScanSession(
            sourceId: source.id, trigger: .manual)
        reader.beforeRead = { _, call in
            if call == 2 { throw MediaSourceReaderError.timeout }
        }
        try await scanner.scan(source: source, scanSessionId: session,
                               resumeSessionId: nil,
                               ledgerSessionId: session) { _ in }

        let attemptsAfterScan = try SorrivaDatabase.shared
            .scanSessionFailures(sessionId: session).first?.attempts ?? 0

        // Retry, failing with a timeout again.
        let retryReader = FixtureMediaSourceReader(rootURL: fixtureRoot)
        retryReader.beforeRead = { _, _ in throw MediaSourceReaderError.timeout }
        let retryScanner = SMBScanner(readerFactory: { _ in retryReader })
        await retryScanner.retrySkippedTracks(source: source, ledgerSessionId: session)

        let attemptsAfterRetry = try SorrivaDatabase.shared
            .scanSessionFailures(sessionId: session).first?.attempts ?? -1
        XCTAssertEqual(attemptsAfterRetry, attemptsAfterScan,
            "A timeout on retry must NOT consume an attempt — the NAS not answering is not a property of the file")
    }

    func testRetryResolvesARecoverableFailure() async throws {
        let session = try SorrivaDatabase.shared.createScanSession(
            sourceId: source.id, trigger: .manual)
        reader.beforeRead = { _, call in
            if call == 2 { throw MediaSourceReaderError.timeout }
        }
        try await scanner.scan(source: source, scanSessionId: session,
                               resumeSessionId: nil,
                               ledgerSessionId: session) { _ in }
        XCTAssertEqual(try trackAudit(session)["skipped"] ?? 0, 1)

        // Retry with a healthy reader — the file is fine, the NAS was not.
        let retryReader = FixtureMediaSourceReader(rootURL: fixtureRoot)
        let retryScanner = SMBScanner(readerFactory: { _ in retryReader })
        await retryScanner.retrySkippedTracks(source: source, ledgerSessionId: session)

        let a = try trackAudit(session)
        XCTAssertEqual(a["resolved"] ?? 0, 1, "The failure should be resolved on retry")
        XCTAssertEqual(a["skipped"] ?? 0, 0)
        XCTAssertEqual((a["written"] ?? 0) + (a["resolved"] ?? 0), expectedFiles)
    }

    // MARK: - Per-folder rollup
    //
    // Drives both the review tool and the inline "12 of 15 tracks" signal. An
    // album with failed reads is currently indistinguishable from a short album
    // (bAlbumMissingTracksNotVisible); this is the query that fixes it.

    func testFailuresRollUpByFolder() async throws {
        let session = try SorrivaDatabase.shared.createScanSession(
            sourceId: source.id, trigger: .manual)
        reader.beforeRead = { _, call in
            if call == 1 || call == 2 { throw MediaSourceReaderError.timeout }
        }
        try await scanner.scan(source: source, scanSessionId: session,
                               resumeSessionId: nil,
                               ledgerSessionId: session) { _ in }

        let byFolder = try SorrivaDatabase.shared.scanSessionFailuresByFolder(sessionId: session)
        XCTAssertFalse(byFolder.isEmpty, "Folders with failures must be reported")
        let totalFailed = byFolder.reduce(0) { $0 + $1.failed }
        XCTAssertEqual(totalFailed, 2)
        for row in byFolder {
            XCTAssertEqual(row.planned, row.written + row.failed,
                           "Per-folder counts must reconcile")
        }
    }

    // MARK: - Retention
    //
    // Agreed 2026-07-31: the record survives automatic scans and is cleared only
    // when the user manually scans that same share.

    func testClearScanSessionsRemovesTheRecord() async throws {
        let session = try await runScan()
        XCTAssertFalse(try audit(session).isEmpty)

        try SorrivaDatabase.shared.clearScanSessions(sourceId: source.id)

        XCTAssertTrue(try audit(session).isEmpty,
                      "Clearing sessions must cascade to their ledger rows")
        XCTAssertNil(try SorrivaDatabase.shared.activeScanSession(sourceId: source.id))
    }
    // MARK: - Detection machinery
    //
    // The 17 tests above all drive a real scan and assert the result. These three
    // do the opposite: they construct a KNOWN-BAD ledger state directly and
    // assert the detection machinery reports it correctly.
    //
    // That distinction matters. Everything above depends on the audit query, the
    // outstanding-work check and the per-folder rollup being right — but none of
    // them would catch those queries silently breaking, because a scan that
    // writes correct rows plus a query that reads them wrongly can still produce
    // a passing assertion. These test the detector, not the scanner, and they
    // need no scan at all so they run in milliseconds.

    /// A row left at `planned` is the definition of an unaccounted file, and it
    /// is the single most important thing the ledger detects. If a later change
    /// makes the audit stop seeing `planned` rows, every other test here would
    /// still pass while the invariant quietly stopped meaning anything.
    func testUnaccountedRowIsDetected() throws {
        let session = try SorrivaDatabase.shared.createScanSession(
            sourceId: source.id, trigger: .manual)

        let files = [
            (path: "/A/one.flac",   folder: "/A", size: 100),
            (path: "/A/two.flac",   folder: "/A", size: 100),
            (path: "/A/three.flac", folder: "/A", size: 100),
        ]
        try SorrivaDatabase.shared.recordScanPlan(
            sessionId: session, sourceId: source.id, files: files,
            plannedFolders: 1, skippedUnchangedFiles: 0)

        // Settle two, deliberately leave the third stranded.
        try SorrivaDatabase.shared.recordLedgerOutcome(
            sessionId: session, filePath: "/A/one.flac", outcome: .written)
        try SorrivaDatabase.shared.recordLedgerOutcome(
            sessionId: session, filePath: "/A/two.flac", outcome: .written)

        XCTAssertTrue(try SorrivaDatabase.shared.sessionHasOutstandingWork(sessionId: session),
            "A session with a stranded 'planned' row must report outstanding work")

        let unfinished = try SorrivaDatabase.shared.unfinishedLedgerFiles(sessionId: session)
        XCTAssertEqual(unfinished, ["/A/three.flac"],
            "The unaccounted file must be NAMED, not merely counted — 'you have 1 missing track' is the problem, not the answer")

        XCTAssertEqual(try SorrivaDatabase.shared.scanSessionAudit(sessionId: session)["planned"] ?? 0, 1)

        // And once it is settled, the session is genuinely complete.
        try SorrivaDatabase.shared.recordLedgerOutcome(
            sessionId: session, filePath: "/A/three.flac", outcome: .written)
        XCTAssertFalse(try SorrivaDatabase.shared.sessionHasOutstandingWork(sessionId: session))
    }

    /// The audit is arithmetic: planned = written + resolved + skipped +
    /// permanent + unaccounted. This asserts the query returns exactly the
    /// counts that were written, with no scan involved to obscure it.
    func testAuditArithmeticIsCorrect() throws {
        let session = try SorrivaDatabase.shared.createScanSession(
            sourceId: source.id, trigger: .manual)

        let files = (1...7).map {
            (path: "/A/\($0).flac", folder: "/A", size: 100)
        }
        try SorrivaDatabase.shared.recordScanPlan(
            sessionId: session, sourceId: source.id, files: files,
            plannedFolders: 1, skippedUnchangedFiles: 0)

        // 3 written, 2 skipped, 1 permanent, 1 left planned.
        for i in 1...3 {
            try SorrivaDatabase.shared.recordLedgerOutcome(
                sessionId: session, filePath: "/A/\(i).flac", outcome: .written)
        }
        for i in 4...5 {
            try SorrivaDatabase.shared.recordLedgerOutcome(
                sessionId: session, filePath: "/A/\(i).flac", outcome: .skipped,
                failureKind: .timeout, failureDetail: "no response",
                incrementAttempt: true)
        }
        try SorrivaDatabase.shared.recordLedgerOutcome(
            sessionId: session, filePath: "/A/6.flac", outcome: .permanent,
            failureKind: .read, failureDetail: "unreadable", incrementAttempt: true)

        let a = try SorrivaDatabase.shared.scanSessionAudit(sessionId: session)
        XCTAssertEqual(a["written"] ?? 0, 3)
        XCTAssertEqual(a["skipped"] ?? 0, 2)
        XCTAssertEqual(a["permanent"] ?? 0, 1)
        XCTAssertEqual(a["planned"] ?? 0, 1)
        XCTAssertEqual(a.values.reduce(0, +), files.count,
                       "Every planned row must appear in exactly one bucket")

        // Failure reason must survive the round trip — retry policy and the
        // user-facing message both depend on it.
        let failures = try SorrivaDatabase.shared.scanSessionFailures(sessionId: session)
        XCTAssertEqual(failures.count, 3, "skipped + permanent are both failures")
        XCTAssertEqual(failures.filter { $0.kind == "timeout" }.count, 2)
        XCTAssertEqual(failures.filter { $0.kind == "read" }.count, 1)
    }

    /// The per-folder rollup drives the review tool and the inline
    /// "12 of 15 tracks" signal. Nothing consumes it yet, so a regression here
    /// would be invisible until that UI ships — which is exactly why it needs a
    /// test now rather than then.
    func testFailureRollupCountsPerFolder() throws {
        let session = try SorrivaDatabase.shared.createScanSession(
            sourceId: source.id, trigger: .manual)

        let files = [
            (path: "/A/1.flac", folder: "/A", size: 100),
            (path: "/A/2.flac", folder: "/A", size: 100),
            (path: "/A/3.flac", folder: "/A", size: 100),
            (path: "/B/1.flac", folder: "/B", size: 100),
            (path: "/B/2.flac", folder: "/B", size: 100),
            (path: "/C/1.flac", folder: "/C", size: 100),
        ]
        try SorrivaDatabase.shared.recordScanPlan(
            sessionId: session, sourceId: source.id, files: files,
            plannedFolders: 3, skippedUnchangedFiles: 0)

        // /A: 2 written, 1 failed.  /B: 1 written, 1 failed.  /C: all written.
        try SorrivaDatabase.shared.recordLedgerOutcome(sessionId: session, filePath: "/A/1.flac", outcome: .written)
        try SorrivaDatabase.shared.recordLedgerOutcome(sessionId: session, filePath: "/A/2.flac", outcome: .written)
        try SorrivaDatabase.shared.recordLedgerOutcome(sessionId: session, filePath: "/A/3.flac",
            outcome: .skipped, failureKind: .timeout, failureDetail: "no response", incrementAttempt: true)
        try SorrivaDatabase.shared.recordLedgerOutcome(sessionId: session, filePath: "/B/1.flac", outcome: .written)
        try SorrivaDatabase.shared.recordLedgerOutcome(sessionId: session, filePath: "/B/2.flac",
            outcome: .permanent, failureKind: .read, failureDetail: "unreadable", incrementAttempt: true)
        try SorrivaDatabase.shared.recordLedgerOutcome(sessionId: session, filePath: "/C/1.flac", outcome: .written)

        let rollup = try SorrivaDatabase.shared.scanSessionFailuresByFolder(sessionId: session)

        XCTAssertEqual(rollup.count, 2,
            "Only folders WITH failures should appear — a clean folder is not a finding")
        XCTAssertNil(rollup.first { $0.folderPath == "/C" },
            "A folder with no failures must not be reported")

        let a = rollup.first { $0.folderPath == "/A" }
        XCTAssertEqual(a?.planned, 3)
        XCTAssertEqual(a?.written, 2)
        XCTAssertEqual(a?.failed, 1, "This is the '2 of 3 tracks' the user needs to see")

        let b = rollup.first { $0.folderPath == "/B" }
        XCTAssertEqual(b?.planned, 2)
        XCTAssertEqual(b?.written, 1)
        XCTAssertEqual(b?.failed, 1)

        for row in rollup {
            XCTAssertEqual(row.planned, row.written + row.failed,
                           "Per-folder counts must reconcile")
        }
    }
}
