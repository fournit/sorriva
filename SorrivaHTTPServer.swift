import Foundation
import AVFoundation
import Telegraph
import SMBClient
import GRDB

// MARK: - SorrivaHTTPServer
// Bridges local NAS files (SMB) to Sonos (HTTP).
// Sonos calls SetAVTransportURI with http://[device-IP]:8080/track/[trackId].
// This server looks up the track in SQLite, opens an SMBClient connection, reads
// the requested byte range, and returns it — zero audio processing, bit-perfect.
//
// Lifecycle:
//   start()  — called when local library playback begins. Declares background
//              audio session so iOS keeps the process alive when screen locks.
//   stop()   — called when session ends or app terminates.
//
// Usage:
//   let url = SorrivaHTTPServer.shared.localURL(for: track.id)
//   // → "http://192.168.1.42:8080/track/[uuid]"

final class SorrivaHTTPServer {

    static let shared = SorrivaHTTPServer()

    // MARK: - State

    private var server: Server?
    private(set) var isRunning = false
    private let port: Int = 8080

    private init() {}

    // MARK: - Public API

    /// Start the HTTP server and declare background audio session.
    /// Safe to call multiple times — no-ops if already running.
    func start() throws {
        guard !isRunning else {
            print("HTTPSERVER: already running on port \(port)")
            return
        }

        // Declare background audio session so iOS keeps the process alive when
        // the screen locks. .mixWithOthers avoids interrupting other audio.
        // We are NOT playing audio through the device — this is solely for lifecycle.
        try AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers]
        )
        try AVAudioSession.sharedInstance().setActive(true)

        let telegraphServer = Server()

        // Single catch-all GET handler — parse path manually to avoid Telegraph
        // route parameter issues with UUID hyphens.
        // Matches: /track/[any-id]
        // Returns 404 for anything else.
        telegraphServer.route(.GET, "/*") { [weak self] request in
            let path = request.uri.path
            print("HTTPSERVER: request — \(path)")

            guard let self, path.hasPrefix("/track/") else {
                return HTTPResponse(.notFound, content: "Not found: \(path)")
            }

            let trackId = String(path.dropFirst("/track/".count))
            guard !trackId.isEmpty else {
                return HTTPResponse(.badRequest)
            }

            return self.handleTrackRequest(trackId: trackId, request: request)
        }

        try telegraphServer.start(port: port)
        server = telegraphServer
        isRunning = true

        print("HTTPSERVER: started on port \(port) — device IP: \(Self.wifiIPAddress() ?? "unknown")")
        print("HTTPSERVER: server port confirmed — \(telegraphServer.port)")
    }

    /// Stop the HTTP server and release the background audio session.
    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false)
        print("HTTPSERVER: stopped")
    }

    /// Returns the full HTTP URL for a track — e.g. http://192.168.1.42:8080/track/[uuid]
    /// Returns nil if the server is not running or device is not on WiFi.
    func localURL(for trackId: String) -> String? {
        guard isRunning, let ip = Self.wifiIPAddress() else { return nil }
        return "http://\(ip):\(port)/track/\(trackId)"
    }

    // MARK: - Request handler
    // Telegraph route handlers are synchronous. We bridge to async SMB reads
    // using a DispatchSemaphore — the same pattern used in SMBScanner.

    private func handleTrackRequest(
        trackId: String,
        request: HTTPRequest
    ) -> HTTPResponse {

        // 1. Look up track in SQLite
        guard let track = try? SorrivaDatabase.shared.track(id: trackId) else {
            print("HTTPSERVER: track not found — \(trackId)")
            return HTTPResponse(.notFound)
        }

        // 2. Look up LibrarySource for SMB credentials
        guard let source = try? SorrivaDatabase.shared.librarySource(id: track.sourceId) else {
            print("HTTPSERVER: source not found for track \(track.title)")
            return HTTPResponse(.notFound)
        }

        let fileSize = track.fileSize ?? 0

        // 3. Parse Range header — Sonos sends "Range: bytes=0-" or "Range: bytes=X-Y"
        var rangeStart = 0
        var rangeEnd = max(0, fileSize - 1)
        var isRangeRequest = false

        if let rangeHeader = request.headers["Range"],
           let parsed = Self.parseRangeHeader(rangeHeader, fileSize: fileSize) {
            rangeStart = parsed.start
            rangeEnd = parsed.end
            isRangeRequest = true
        }

        let requestedLength = max(0, rangeEnd - rangeStart + 1)

        // Cap read at 8MB — UNAS Pro maximum read size (discovered during scanner work).
        // Sonos will issue subsequent Range requests for the rest of the file.
        let cappedLength = min(requestedLength, 8 * 1024 * 1024)

        // 4. Read byte range from SMB — bridge async to sync via semaphore
        let host = source.host
        let share = source.share
        let username = source.username ?? ""
        let password = source.password ?? ""
        let filePath = track.filePath
        let trackTitle = track.title

        print("HTTPSERVER: SMB read — host:\(host) share:\(share) user:\(username) path:\(filePath)")

        let semaphore = DispatchSemaphore(value: 0)
        var fileData: Data? = nil

        Task.detached {
            fileData = await Self.readSMBRange(
                host: host, share: share,
                username: username, password: password,
                path: filePath,
                offset: rangeStart,
                length: cappedLength
            )
            semaphore.signal()
        }

        // Wait up to 60 seconds — increased to distinguish slow vs broken
        if semaphore.wait(timeout: .now() + 60) == .timedOut {
            print("HTTPSERVER: SMB read timeout — \(trackTitle)")
            return HTTPResponse(.internalServerError)
        }

        guard let data = fileData else {
            print("HTTPSERVER: SMB read failed — \(trackTitle)")
            return HTTPResponse(.internalServerError)
        }

        print("HTTPSERVER: serving \(trackTitle) — \(data.count) bytes (range: \(rangeStart)-\(rangeEnd))")

        // 5. Build response
        let contentType = Self.contentType(for: track.fileFormat)

        let response: HTTPResponse
        if isRangeRequest && fileSize > 0 {
            let actualEnd = rangeStart + data.count - 1
            response = HTTPResponse(.partialContent, body: data)
            response.headers["Content-Range"] = "bytes \(rangeStart)-\(actualEnd)/\(fileSize)"
        } else {
            response = HTTPResponse(.ok, body: data)
        }

        response.headers.contentType = contentType
        response.headers["Accept-Ranges"] = "bytes"
        response.headers["Content-Length"] = String(data.count)
        response.headers["Cache-Control"] = "no-cache"

        return response
    }

    // MARK: - SMB read

    /// Read a byte range from an SMB file. Returns nil on error.
    /// Opens a fresh SMBClient connection per request — same pattern as SMBScanner.
    private static func readSMBRange(
        host: String, share: String,
        username: String, password: String,
        path: String,
        offset: Int,
        length: Int
    ) async -> Data? {
        guard length > 0 else { return Data() }
        do {
            print("HTTPSERVER: SMB connecting to \(host)...")
            let client = SMBClient(host: host)
            print("HTTPSERVER: SMB login as \(username.isEmpty ? "guest" : username)...")
            try await client.login(
                username: username.isEmpty ? "guest" : username,
                password: password
            )
            defer { Task { try? await client.logoff() } }
            print("HTTPSERVER: SMB connecting to share \(share)...")
            try await client.connectShare(share)
            defer { Task { try? await client.disconnectShare() } }
            print("HTTPSERVER: SMB opening file \(path)...")
            let reader = client.fileReader(path: path)
            defer { Task { try? await reader.close() } }
            print("HTTPSERVER: SMB reading \(length) bytes at offset \(offset)...")
            let data = try await reader.read(
                offset: UInt64(offset),
                length: UInt32(min(length, Int(UInt32.max)))
            )
            print("HTTPSERVER: SMB read complete — \(data.count) bytes")
            return data
        } catch {
            print("HTTPSERVER: SMB error — \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Range header parsing

    /// Parse "Range: bytes=X-Y" or "Range: bytes=X-" header.
    /// Returns (start, end) clamped to file size.
    private static func parseRangeHeader(
        _ header: String,
        fileSize: Int
    ) -> (start: Int, end: Int)? {
        guard header.lowercased().hasPrefix("bytes=") else { return nil }
        let rangeSpec = String(header.dropFirst("bytes=".count))
        let parts = rangeSpec.components(separatedBy: "-")
        guard parts.count == 2, let start = Int(parts[0].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)
        let end: Int
        if endStr.isEmpty {
            end = max(0, fileSize - 1)
        } else if let e = Int(endStr) {
            end = min(e, max(0, fileSize - 1))
        } else {
            return nil
        }
        guard start <= end else { return nil }
        return (start: start, end: end)
    }

    // MARK: - Content-Type

    private static func contentType(for fileFormat: String) -> String {
        switch fileFormat.lowercased() {
        case "flac":         return "audio/flac"
        case "mp3":          return "audio/mpeg"
        case "m4a", "aac",
             "alac":         return "audio/mp4"
        case "wav":          return "audio/wav"
        case "aiff", "aif":  return "audio/aiff"
        default:             return "application/octet-stream"
        }
    }

    // MARK: - WiFi IP detection

    /// Returns the device's current WiFi IP address using getifaddrs.
    /// en0 is the WiFi interface on iPhone and iPad.
    /// Returns nil if not connected to WiFi.
    static func wifiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let flags  = Int32(ptr.pointee.ifa_flags)
            let isUp       = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let family     = ptr.pointee.ifa_addr.pointee.sa_family

            if isUp && !isLoopback && family == UInt8(AF_INET) {
                let name = String(cString: ptr.pointee.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        ptr.pointee.ifa_addr,
                        socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count),
                        nil, 0,
                        NI_NUMERICHOST
                    ) == 0 {
                        address = String(cString: hostname)
                        break
                    }
                }
            }
            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }
        return address
    }
}
