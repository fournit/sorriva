import Foundation
import Network

#if DEBUG

// MARK: - NWConnectionProbe
//
// Isolates the ~512 ceiling: OS-level kernel accounting, or SMBClient retaining
// its connections?
//
// Every prior measurement churned connections THROUGH SMBClient, which confounds
// two variables. This test uses raw NWConnection with no SMBClient involvement at
// all, and deliberately clears stateUpdateHandler before cancel() so our own
// closure cannot be the thing holding a reference.
//
// OUTCOMES — these are genuinely either/or:
//
//   Passes 600 cycles  → NWConnection flow entries ARE reclaimed on cancel().
//                        The OS is fine. SMBClient v0.3.1 is retaining its
//                        connections somewhere. FIXABLE — fork and patch, or
//                        wrap the transport directly.
//
//   Fails around 512   → Kernel-level flow-table accounting with no public API
//                        to flush it. Matches Apple DTS's description. NOT
//                        fixable in-process; single-process import of a 13.5k
//                        library is off the table and the design moves to
//                        chunked import with checkpoint/resume.
//
// RUN FROM A FRESHLY FORCE-QUIT APP, as the first action. Anything prior spends
// budget and invalidates the result.
//
// Port 445 is used because that is what the real scanner talks to, so the traffic
// shape and the kernel's treatment of it match production. No SMB handshake is
// performed — TCP connect and teardown is all that is needed to consume and
// (hopefully) release a flow entry.

enum NWConnectionProbe {

    /// Above the ~512 figure so the ceiling is crossed if it exists.
    private static let cycles = 600

    /// Per-connection readiness timeout. Local NAS connects in single-digit ms;
    /// 5s is generous and only matters if something is badly wrong.
    private static let readyTimeout: TimeInterval = 5

    static func run(host: String) async {
        sLog("PROBE: ==================================================")
        sLog("PROBE: NWCONNECTION CHURN — \(host):445")
        sLog("PROBE: \(cycles) cycles of connect → ready → cancel, no SMBClient")

        let started = Date()
        var completed = 0

        for cycle in 1...cycles {
            do {
                try await connectAndCancel(host: host)
                completed = cycle
            } catch {
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                sLog("PROBE: FAILED at connection \(cycle) after \(elapsed)s")
                sLog("PROBE: error — \(String(describing: error))")

                if cycle >= 400 && cycle <= 600 {
                    sLog("PROBE: VERDICT — raw NWConnection hits the same ceiling at ~\(cycle).")
                    sLog("PROBE: Kernel-level flow accounting. NOT an SMBClient bug, NOT fixable in-process.")
                    sLog("PROBE: Single-process 13.5k import is off the table — design for chunked import with resume.")
                } else {
                    sLog("PROBE: VERDICT — failed at \(cycle), outside the expected ~512 band.")
                    sLog("PROBE: Something else is going on; inspect the error before drawing conclusions.")
                }
                sLog("PROBE: ==================================================")
                return
            }

            if cycle % 25 == 0 {
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                sLog("PROBE: nwchurn \(cycle)/\(cycles) ok — \(elapsed)s elapsed")
            }
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        sLog("PROBE: --- nwconnection churn results ---")
        sLog("PROBE: \(completed) connect/cancel cycles, zero failures, \(elapsed)s")
        sLog("PROBE: VERDICT — raw NWConnection flow entries ARE reclaimed on cancel().")
        sLog("PROBE: The OS is not the problem. SMBClient is retaining its connections.")
        sLog("PROBE: FIXABLE — patch SMBClient's teardown, or wrap NWConnection directly.")
        sLog("PROBE: ==================================================")
    }

    // MARK: - One cycle

    private enum ProbeError: Error, CustomStringConvertible {
        case timeout
        case failed(NWError)
        var description: String {
            switch self {
            case .timeout: return "connection did not reach .ready within \(Int(readyTimeout))s"
            case .failed(let e): return "connection failed — \(e)"
            }
        }
    }

    /// Open one TCP connection, wait for .ready, then release it as cleanly as
    /// possible: clear the handler first so no closure retains the connection,
    /// then cancel, then drop the last reference on return.
    private static func connectAndCancel(host: String) async throws {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: 445,
            using: .tcp
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Guards against resuming twice if a state change races the timeout.
            let settled = Settled()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard settled.claim() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard settled.claim() else { return }
                    continuation.resume(throwing: ProbeError.failed(error))
                case .cancelled:
                    guard settled.claim() else { return }
                    continuation.resume(throwing: ProbeError.timeout)
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + readyTimeout) {
                guard settled.claim() else { return }
                continuation.resume(throwing: ProbeError.timeout)
            }
        }

        // Clear the handler BEFORE cancelling. If a retained closure were the
        // thing keeping flow entries alive, this removes that possibility, so a
        // failure here cannot be blamed on probe code.
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    /// Minimal thread-safe one-shot latch.
    private final class Settled: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}

#endif
