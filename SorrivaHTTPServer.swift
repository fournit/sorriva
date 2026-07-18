import Foundation
import Network
import AVFoundation
import SMBClient

// MARK: - SorrivaHTTPServer
// NWListener HTTP server — streams local FLAC/MP3/WAV files from NAS to Sonos.
// Architecture: one persistent SMB session per HTTP request, 1MB sequential reads.
// Prefetch delay: when Sonos requests the next track, we delay the response until
// the current track is nearly done playing. Combined with rolling 2-track queue
// in LocalPlaybackService, this prevents Sonos from skipping tracks early.

final class SorrivaHTTPServer {

    static let shared = SorrivaHTTPServer()

    private var listener: NWListener?
    private(set) var isRunning = false
    private let port: NWEndpoint.Port = 8080
    private let queue = DispatchQueue(label: "sorriva.httpserver", qos: .userInitiated)

    // MARK: - Current track state (for prefetch delay calculation)
    private var currentTrackId: String? = nil
    private var currentTrackStartTime: Date? = nil
    private var currentTrackDuration: Double? = nil

    // MARK: - Notifications
    static let trackDidStartNotification = Notification.Name("SorrivaHTTPServer.trackDidStart")
    static let trackIdKey = "trackId"

    // Called by LocalPlaybackService when initiating playback of first track
    func setCurrentTrack(id: String, duration: Double?) {
        currentTrackId = id
        currentTrackStartTime = Date()
        currentTrackDuration = duration
        sLog("HTTPSERVER: track registered — \(id) duration=\(duration.map { String($0) } ?? "nil")")
    }

    private init() {}

    // MARK: - Public API

    func start() throws {
        guard !isRunning else {
            sLog("HTTPSERVER: already running")
            return
        }

        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try AVAudioSession.sharedInstance().setActive(true)

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                sLog("HTTPSERVER: started on port 8080 — device IP: \(SorrivaHTTPServer.wifiIPAddress() ?? "unknown")")
            case .failed(let error):
                sLog("HTTPSERVER: listener failed — \(error)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        isRunning = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false)
        sLog("HTTPSERVER: stopped")
    }

    func localURL(for trackId: String, format: String) -> String? {
        guard isRunning, let ip = Self.wifiIPAddress() else { return nil }
        return "http://\(ip):8080/track/\(trackId).\(format.lowercased())"
    }

    // MARK: - Connection handler

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection: connection, accumulated: Data())
    }

    private func readRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = accumulated
            if let data = data, !data.isEmpty {
                buffer.append(data)
            }

            let separator1 = Data("\r\n\r\n".utf8)
            let separator2 = Data("\n\n".utf8)
            if buffer.range(of: separator1) != nil || buffer.range(of: separator2) != nil {
                guard let request = String(data: buffer, encoding: .utf8) else {
                    self.sendError(connection: connection, status: "400 Bad Request")
                    return
                }
                self.processRequest(request, connection: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.readRequest(connection: connection, accumulated: buffer)
            }
        }
    }

    private func processRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n").flatMap { $0.components(separatedBy: "\n") }

        guard let requestLine = lines.first else {
            sendError(connection: connection, status: "400 Bad Request")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendError(connection: connection, status: "400 Bad Request")
            return
        }

        let path = parts[1]
        sLog("HTTPSERVER: request — \(path)")

        guard path.hasPrefix("/track/") else {
            sendError(connection: connection, status: "404 Not Found")
            return
        }

        let rawId = String(path.dropFirst("/track/".count))
        let trackId: String
        if let dotIndex = rawId.lastIndex(of: ".") {
            trackId = String(rawId[rawId.startIndex..<dotIndex])
        } else {
            trackId = rawId
        }

        guard !trackId.isEmpty else {
            sendError(connection: connection, status: "400 Bad Request")
            return
        }

        var rangeStart = 0
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("range:") {
                let value = String(line.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces)
                if let parsed = Self.parseRangeHeader(value) {
                    rangeStart = parsed
                }
            }
        }

        guard let track = try? SorrivaDatabase.shared.track(id: trackId) else {
            sLog("HTTPSERVER: track not found — \(trackId)")
            sendError(connection: connection, status: "404 Not Found")
            return
        }

        guard let source = try? SorrivaDatabase.shared.librarySource(id: track.sourceId) else {
            sLog("HTTPSERVER: source not found — \(track.title)")
            sendError(connection: connection, status: "404 Not Found")
            return
        }

        let fileSize = track.fileSize ?? 0
        let contentType = Self.contentType(for: track.fileFormat)

        sLog("HTTPSERVER: streaming \(track.title) from offset \(rangeStart), fileSize \(fileSize)")

        // MARK: Prefetch delay + track state management
        var prefetchDelay: Double = 0
        if rangeStart == 0 {
            if trackId != currentTrackId {
                // Different track — calculate prefetch delay
                if let startTime = currentTrackStartTime, let duration = currentTrackDuration {
                    let elapsed = Date().timeIntervalSince(startTime)
                    let delay = (duration - 1.0) - elapsed
                    prefetchDelay = max(0, delay)
                    if prefetchDelay > 0 {
                        sLog("HTTPSERVER: prefetch delay \(String(format: "%.1f", prefetchDelay))s for \(track.title) (current has \(String(format: "%.1f", (currentTrackDuration ?? 0) - elapsed))s remaining)")
                    }
                }
            }
            // Update current track state
            currentTrackId = trackId
            currentTrackStartTime = Date()
            currentTrackDuration = track.duration
        }

        let smbHost = source.host
        let smbShare = source.share
        let smbUser = source.username ?? ""
        let smbPass = source.password ?? ""
        let filePath = track.filePath
        let chunkSize = 1 * 1024 * 1024
        let statusLine = rangeStart > 0 ? "206 Partial Content" : "200 OK"

        // Send headers immediately — Sonos needs a response or it will timeout and close the socket
        var headers = "HTTP/1.1 \(statusLine)\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(fileSize > 0 ? fileSize - rangeStart : 0)\r\n"
        headers += "Accept-Ranges: bytes\r\n"
        if fileSize > 0 && rangeStart > 0 {
            headers += "Content-Range: bytes \(rangeStart)-\(fileSize - 1)/\(fileSize)\r\n"
        }
        headers += "Cache-Control: no-cache\r\n"
        headers += "Connection: close\r\n"
        headers += "\r\n"
        sendData(Data(headers.utf8), connection: connection)

        let notificationTrackId = trackId

        Task.detached { [weak self] in
            guard let self else { return }
            // Delay body only — headers already sent so Sonos won't timeout
            if prefetchDelay > 0 {
                sLog("HTTPSERVER: holding body for \(String(format: "%.1f", prefetchDelay))s")
                try? await Task.sleep(nanoseconds: UInt64(prefetchDelay * 1_000_000_000))
                // Reset start time after delay so next prefetch calculates correctly
                await MainActor.run { self.currentTrackStartTime = Date() }
            }
            // Notify AFTER delay so LocalPlaybackService enqueues next track at the right time
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: SorrivaHTTPServer.trackDidStartNotification,
                    object: nil,
                    userInfo: [SorrivaHTTPServer.trackIdKey: notificationTrackId]
                )
            }
            await self.streamFile(
                host: smbHost, share: smbShare,
                username: smbUser, password: smbPass,
                path: filePath,
                startOffset: rangeStart,
                chunkSize: chunkSize,
                connection: connection
            )
        }
    }

    // MARK: - SMB streaming — single persistent connection for entire file

    private func streamFile(
        host: String, share: String,
        username: String, password: String,
        path: String,
        startOffset: Int,
        chunkSize: Int,
        connection: NWConnection
    ) async {
        var offset = startOffset
        var totalSent = 0

        do {
            let client = SMBClient(host: host)
            try await client.login(username: username.isEmpty ? "guest" : username, password: password)
            defer { Task { try? await client.logoff() } }
            try await client.connectShare(share)
            defer { Task { try? await client.disconnectShare() } }
            let reader = client.fileReader(path: path)
            defer { Task { try? await reader.close() } }

            sLog("HTTPSERVER: SMB session open — streaming \(path) from offset \(offset)")

            while true {
                let data: Data
                do {
                    data = try await reader.read(
                        offset: UInt64(offset),
                        length: UInt32(min(chunkSize, Int(UInt32.max)))
                    )
                } catch {
                    sLog("HTTPSERVER: SMB read error at offset \(offset) — \(error.localizedDescription)")
                    break
                }

                guard !data.isEmpty else {
                    sLog("HTTPSERVER: EOF at offset \(offset), total: \(totalSent)")
                    break
                }

                let sendOK = await withCheckedContinuation { continuation in
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error = error {
                            sLog("HTTPSERVER: send error at offset \(offset) — \(error)")
                            continuation.resume(returning: false)
                        } else {
                            continuation.resume(returning: true)
                        }
                    })
                }

                guard sendOK else {
                    sLog("HTTPSERVER: send failed at offset \(offset) — stopping")
                    break
                }

                offset += data.count
                totalSent += data.count
                sLog("HTTPSERVER: sent \(data.count) bytes at offset \(offset), total: \(totalSent)")

                if data.count < chunkSize { break }
            }
        } catch {
            sLog("HTTPSERVER: SMB session error — \(error.localizedDescription)")
        }

        sLog("HTTPSERVER: stream complete — \(totalSent) bytes sent")
        try? await Task.sleep(nanoseconds: 500_000_000)
        connection.cancel()
    }

    // MARK: - Helpers

    private func sendData(_ data: Data, connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                sLog("HTTPSERVER: send error — \(error)")
            }
        })
    }

    private func sendError(connection: NWConnection, status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        sendData(Data(response.utf8), connection: connection)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            connection.cancel()
        }
    }

    private static func parseRangeHeader(_ header: String) -> Int? {
        guard header.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = String(header.dropFirst("bytes=".count))
        let parts = spec.components(separatedBy: "-")
        guard let start = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        return start
    }

    private static func contentType(for fileFormat: String) -> String {
        switch fileFormat.lowercased() {
        case "flac":         return "audio/flac"
        case "mp3":          return "audio/mpeg"
        case "m4a", "aac", "alac": return "audio/mp4"
        case "wav":          return "audio/wav"
        case "aiff", "aif":  return "audio/aiff"
        default:             return "application/octet-stream"
        }
    }

    static func wifiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = firstAddr
        while true {
            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let family = ptr.pointee.ifa_addr.pointee.sa_family
            if isUp && !isLoopback && family == UInt8(AF_INET) {
                let name = String(cString: ptr.pointee.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr,
                                   socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
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
