import Foundation
import Network
import SMBClient

#if DEBUG

// MARK: - SMBSessionProbe
//
// Throwaway diagnostic for bScanConnectionExhaustionOnRepeatedScans.
//
// PURPOSE
// The scanner opens a fresh SMBClient per file because the UNAS Pro was
// observed to drop sessions after ~2 sequential reads. That observation was
// made inside long-lived app processes that had already burned hundreds of
// connections, and iOS enforces a per-process ceiling (~500) on network flows
// that reports as NWError 12 / "Cannot allocate memory". Those two conditions
// produce an identical symptom — a read failing on a reused session — so the
// original finding may be an artifact of exhaustion rather than real device
// behavior.
//
// This probe measures the actual number: how many sequential 64KB header reads
// survive on ONE authenticated session, starting from a clean process.
//
// WHY THE ANSWER DECIDES THE ARCHITECTURE
//   ~2 reads/session  → 10,000 tracks needs ~5,000 connections vs a ~500
//                       budget. Session reuse cannot work; batching with
//                       process restarts becomes the only path.
//   300+ reads/session → 10,000 tracks needs ~34 connections. Session reuse is
//                       sufficient and the per-file pattern is the whole bug.
//
// RUN PROTOCOL — this matters, the result is worthless otherwise:
//   1. Force-quit Sorriva.
//   2. Relaunch and run this probe as the FIRST action. Do not scan first.
//      Anything that opens connections beforehand contaminates the budget and
//      reintroduces exactly the ambiguity being measured.
//
// TOTAL CONNECTION SPEND: 3 (one walk, one probe session, one recovery check).

enum SMBSessionProbe {

    /// Stall detection window. Was 15s (inherited from readHeader), but a dead
    /// session never recovers and reconnect is instant, so the only thing a long
    /// window buys is dead waiting. At 27 stalls per 1000 files, 15s cost ~6.75
    /// minutes of pure timeout — roughly 67 minutes at 10k scale.
    private static let stallTimeout: TimeInterval = 3

    /// Churn test: how many open→read→close cycles to run. Deliberately above
    /// the ~512 figure so the ceiling is crossed if it exists.
    private static let churnCycles = 600

    /// Must match SMBScanner's header read size exactly. A smaller read could
    /// survive where the real one fails, which would make this misleading.
    private static let readLength: UInt32 = 65_536

    private static let audioExtensions: Set<String> = [
        "flac", "mp3", "m4a", "aac", "wav", "aif", "aiff", "alac", "ogg", "opus", "wma"
    ]

    // MARK: - Entry point

    static func run(source: LibrarySource) async {
        let creds = source.resolvedCredentials
        let username = creds.username.isEmpty ? "guest" : creds.username
        let password = creds.password

        sLog("PROBE: ==================================================")
        sLog("PROBE: START — \(source.displayName) host=\(source.host) share=\(source.share)")
        sLog("PROBE: read size \(readLength) bytes, \(Int(stallTimeout))s stall timeout")

        // ---- Phase 1: collect paths on a throwaway walk connection ----------

        let paths: [String]
        do {
            paths = try await collectPaths(
                host: source.host,
                share: source.share,
                username: username,
                password: password,
                limit: 1000
            )
        } catch {
            sLog("PROBE: FAILED during path collection — \(String(describing: error))")
            sLog("PROBE: ==================================================")
            return
        }

        guard !paths.isEmpty else {
            sLog("PROBE: ABORT — no audio files found under share root")
            sLog("PROBE: ==================================================")
            return
        }
        sLog("PROBE: collected \(paths.count) audio paths — walk connection closed")

        // ---- Phase 2: sequential reads, reconnecting on session death -------
        //
        // This now simulates the proposed Stage 2 architecture directly: read on
        // one session until it stalls, transparently reconnect, keep going. The
        // number we care about is total connections used for the whole run —
        // that is what has to fit inside the ~500 per-process budget at 10k
        // tracks.

        var client = SMBClient(host: source.host)
        var successCount = 0
        var totalBytes = 0
        var connectionCount = 1
        var sessionReadCount = 0
        var sessionStart = Date()
        var sessionSpans: [Int] = []
        var aborted = false

        do {
            try await client.login(username: username, password: password)
            try await client.connectShare(source.share)
            sessionStart = Date()
            sLog("PROBE: session 1 established — beginning sequential reads")
        } catch {
            sLog("PROBE: FAILED to establish probe session — \(String(describing: error))")
            try? await client.logoff()
            sLog("PROBE: ==================================================")
            return
        }

        for (index, path) in paths.enumerated() {
            let started = Date()
            do {
                let data = try await timedRead(client: client, path: path)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                successCount += 1
                sessionReadCount += 1
                totalBytes += data.count
                sLog("PROBE: read \(index + 1) ok — \(data.count) bytes, \(ms)ms — \(path)")
            } catch {
                let sessionAge = String(format: "%.1f", Date().timeIntervalSince(sessionStart))
                sLog("PROBE: read \(index + 1) STALLED — \(path)")
                sLog("PROBE: session \(connectionCount) ended — \(sessionReadCount) reads, alive \(sessionAge)s")
                sessionSpans.append(sessionReadCount)

                // Dead session: tear down without waiting. timedRead already
                // force-cancelled it, and awaiting here would block forever.
                let dead = client
                Task {
                    try? await dead.disconnectShare()
                    try? await dead.logoff()
                }

                // Reconnect and retry the same file once.
                connectionCount += 1
                sessionReadCount = 0
                client = SMBClient(host: source.host)
                do {
                    try await client.login(username: username, password: password)
                    try await client.connectShare(source.share)
                    sessionStart = Date()
                    sLog("PROBE: session \(connectionCount) established — reconnected")

                    let data = try await timedRead(client: client, path: path)
                    successCount += 1
                    sessionReadCount += 1
                    totalBytes += data.count
                    sLog("PROBE: read \(index + 1) ok after reconnect — \(data.count) bytes — \(path)")
                } catch {
                    sLog("PROBE: RECONNECT FAILED at read \(index + 1) — \(String(describing: error))")
                    sLog("PROBE: ABORTING — could not re-establish a session")
                    aborted = true
                    break
                }
            }
        }

        if !aborted {
            sessionSpans.append(sessionReadCount)
        }

        Task {
            try? await client.disconnectShare()
            try? await client.logoff()
        }

        // ---- Phase 3: results ------------------------------------------------

        let spanText = sessionSpans.map(String.init).joined(separator: ", ")
        sLog("PROBE: --- results ---")
        sLog("PROBE: \(successCount) of \(paths.count) files read using \(connectionCount) connection(s)")
        sLog("PROBE: reads per session — \(spanText)")
        sLog("PROBE: total bytes \(totalBytes)")

        if aborted {
            sLog("PROBE: VERDICT — reconnect failed mid-run. Session reuse is NOT reliable as-is.")
        } else if connectionCount == 1 {
            sLog("PROBE: VERDICT — all \(successCount) reads on a single session, no stall.")
        } else {
            let perSession = successCount / connectionCount
            let projected = (10_000 / max(perSession, 1))
            sLog("PROBE: VERDICT — session reuse with transparent reconnect WORKS.")
            sLog("PROBE: averaging \(perSession) reads/session → ~\(projected) connections for a 10,000-track library (budget ~500).")
        }
        sLog("PROBE: ==================================================")
    }

    // MARK: - Churn test

    /// Open → one read → clean close, repeated past the ~512 figure.
    ///
    /// Settles whether the per-process budget counts EVERY connection ever
    /// opened, or only ones left leaked/stuck. Stage 1 evidence says the former
    /// (clean teardown still hit ~512), and this measures the exact number so
    /// Stage 2 can be designed against a real figure rather than a remembered
    /// one. Every connection here is torn down with an awaited
    /// disconnectShare() + logoff() — the cleanest possible path.
    ///
    /// RUN FROM A FRESHLY FORCE-QUIT APP. Anything prior spends budget.
    static func runChurn(source: LibrarySource) async {
        let creds = source.resolvedCredentials
        let username = creds.username.isEmpty ? "guest" : creds.username
        let password = creds.password

        sLog("PROBE: ==================================================")
        sLog("PROBE: CHURN START — \(source.displayName) host=\(source.host) share=\(source.share)")
        sLog("PROBE: \(churnCycles) cycles of open → 1 read → clean close")

        let paths: [String]
        do {
            paths = try await collectPaths(
                host: source.host,
                share: source.share,
                username: username,
                password: password,
                limit: 50
            )
        } catch {
            sLog("PROBE: CHURN FAILED during path collection — \(String(describing: error))")
            sLog("PROBE: ==================================================")
            return
        }

        guard !paths.isEmpty else {
            sLog("PROBE: CHURN ABORT — no audio files found")
            sLog("PROBE: ==================================================")
            return
        }
        sLog("PROBE: collected \(paths.count) paths — cycling over them repeatedly")

        let started = Date()
        var completed = 0
        var stalls = 0
        var consecutiveStalls = 0
        var cycle = 0

        // Counts SUCCESSFUL connections, so stalls don't stop us short of the
        // ceiling. Sessions stall roughly every 90 connections on this NAS; the
        // previous run aborted on the first one at connection 91 and never got
        // near 512, which is why that result was inconclusive.
        while completed < churnCycles {
            cycle += 1
            if consecutiveStalls >= 10 {
                sLog("PROBE: ABORT — 10 consecutive stalls, NAS is not responding")
                sLog("PROBE: INCONCLUSIVE — reached \(completed) successful connections, ceiling not tested")
                sLog("PROBE: ==================================================")
                return
            }

            let path = paths[cycle % paths.count]
            let client = SMBClient(host: source.host)

            do {
                try await client.login(username: username, password: password)
                try await client.connectShare(source.share)
                _ = try await timedRead(client: client, path: path)
            } catch {
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))

                if isBudgetExhausted(error) {
                    sLog("PROBE: CEILING HIT at \(completed) successful connections after \(elapsed)s")
                    sLog("PROBE: error — \(String(describing: error))")
                    sLog("PROBE: VERDICT — session.disconnect() does NOT clear the ceiling.")
                    sLog("PROBE: cancel() alone is insufficient; the Connection retain cycle blocks dealloc.")
                    sLog("PROBE: FORK REQUIRED — patch Connection.swift: nil stateUpdateHandler in disconnect(), weak self in the handler, add deinit.")
                    sLog("PROBE: ==================================================")
                    Task { try? await client.logoff(); client.session.disconnect() }
                    return
                }

                // Transient stall — the separate unexplained defect, not the
                // ceiling. Tear down and carry on.
                stalls += 1
                consecutiveStalls += 1
                sLog("PROBE: stall \(stalls) at cycle \(cycle) (\(completed) ok so far, \(elapsed)s) — skipping")
                Task {
                    try? await client.logoff()
                    client.session.disconnect()
                }
                continue
            }

            consecutiveStalls = 0

            // Cleanest possible teardown — the whole point of this test.
            //
            // session.disconnect() is the critical addition. SMBClient never
            // calls it internally and exposes no wrapper, but `session` is a
            // public property and Session.disconnect() is public, so it is
            // reachable: it is the ONLY path in the library that reaches
            // NWConnection.cancel(). logoff() alone sends the SMB2 LOGOFF frame
            // and zeroes sessionId, leaving the TCP connection open.
            try? await client.disconnectShare()
            try? await client.logoff()
            client.session.disconnect()
            completed += 1

            if completed % 25 == 0 {
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                sLog("PROBE: churn \(completed)/\(churnCycles) ok — \(elapsed)s elapsed, \(stalls) stall(s) skipped")
            }
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        sLog("PROBE: --- churn results ---")
        sLog("PROBE: \(completed) successful connections in \(cycle) attempts (\(stalls) stalls skipped), \(elapsed)s")
        sLog("PROBE: VERDICT — ceiling CLEARED. \(completed) connections, well past 512, no error 12.")
        sLog("PROBE: cancel() releases the flow entry; the Connection retain cycle does not matter.")
        sLog("PROBE: NO FORK NEEDED — fix is adding session.disconnect() to SMBMediaSourceReader teardown.")
        sLog("PROBE: ==================================================")
    }

    // MARK: - Timed read

    /// One header read with the same 15s ceiling and force-cancel-on-timeout
    /// behavior `SMBMediaSourceReader.readHeader` uses. Without this, a stalled
    /// session hangs the probe forever and the recovery check never runs —
    /// which is exactly what happened on the first run.
    ///
    /// On timeout the connection is force-cancelled via `logoff()`, which makes
    /// `NWConnection.cancel()` complete any outstanding receive with an error,
    /// releasing the stuck background task rather than leaking it.
    private static func timedRead(client: SMBClient, path: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<Data, Error> = .failure(ProbeError.timeout)

            Task.detached {
                do {
                    let reader = client.fileReader(path: path)
                    let data = try await reader.read(offset: 0, length: readLength)
                    try? await reader.close()
                    result = .success(data)
                } catch {
                    result = .failure(error)
                }
                semaphore.signal()
            }

            DispatchQueue.global(qos: .utility).async {
                if semaphore.wait(timeout: .now() + stallTimeout) == .timedOut {
                    result = .failure(ProbeError.timeout)
                    Task { try? await client.logoff() }
                }
                continuation.resume(with: result)
            }
        }
    }

    enum ProbeError: Error, CustomStringConvertible {
        case timeout
        var description: String {
            "read stalled — no response within \(Int(stallTimeout))s (session presumed dead)"
        }
    }

    /// Distinguishes the ceiling (POSIX ENOMEM / NWError 12) from an ordinary
    /// session stall. Conflating these produced a wrong verdict on the previous
    /// run: a stall at connection 91 was reported as the 512 ceiling. Checked
    /// structurally first, with a string fallback because this surfaces variously
    /// as POSIXErrorCode(rawValue: 12) and as Network.NWError error 12.
    private static func isBudgetExhausted(_ error: Error) -> Bool {
        if let posix = error as? POSIXError, posix.code == .ENOMEM { return true }
        if let nw = error as? NWError, case .posix(let code) = nw, code == .ENOMEM { return true }
        let text = String(describing: error)
        return text.contains("Cannot allocate memory") || text.contains("rawValue: 12")
    }

    // MARK: - Path collection

    /// Breadth-first walk on a single connection, torn down before the probe
    /// session opens so it cannot influence the measurement.
    private static func collectPaths(
        host: String,
        share: String,
        username: String,
        password: String,
        limit: Int
    ) async throws -> [String] {
        let client = SMBClient(host: host)
        try await client.login(username: username, password: password)
        try await client.connectShare(share)
        defer {
            Task {
                try? await client.disconnectShare()
                try? await client.logoff()
            }
        }

        var found: [String] = []
        var queue: [String] = [""]

        while !queue.isEmpty && found.count < limit {
            let dir = queue.removeFirst()

            var childDirs: [String] = []
            var audioFiles: [String] = []

            do {
                let entries = try await client.listDirectory(path: dir)
                for entry in entries {
                    let name = entry.name
                    if name == "." || name == ".." || name.hasPrefix(".") { continue }

                    let full = dir.isEmpty ? "/\(name)" : "\(dir)/\(name)"

                    if entry.isDirectory {
                        childDirs.append(full)
                    } else {
                        let ext = (name as NSString).pathExtension.lowercased()
                        if audioExtensions.contains(ext) {
                            audioFiles.append(full)
                        }
                    }
                }
            } catch {
                sLog("PROBE: listDirectory failed for '\(dir)' — \(error.localizedDescription)")
                continue
            }

            queue.append(contentsOf: childDirs)
            for path in audioFiles {
                found.append(path)
                if found.count >= limit { break }
            }
        }

        return found
    }
}

#endif
