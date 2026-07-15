import Foundation
import Network
import AVFoundation
import SMBClient

// MARK: - SorrivaHTTPServer
// Minimal HTTP/1.1 server using NWListener for true chunked streaming.
// Reads audio files from NAS via SMB in 8MB chunks and sends each chunk
// to Sonos immediately — no buffering, no memory pressure, full file plays.
//
// Protocol flow:
//   Sonos → GET /track/[id].flac HTTP/1.1
//   Server → 200 OK + Transfer-Encoding: chunked headers
//   Server → [8MB chunk] → [8MB chunk] → ... → [final chunk] → [0-byte terminator]
//   Sonos → decodes chunked stream → plays audio

final class SorrivaHTTPServer {

    static let shared = SorrivaHTTPServer()

    // MARK: - State

    private var listener: NWListener?
    private(set) var isRunning = false
    private let port: NWEndpoint.Port = 8080
    private let queue = DispatchQueue(label: "sorriva.httpserver", qos: .userInitiated)

    private init() {}

    // MARK: - Public API

    func start() throws {
        guard !isRunning else {
            print("HTTPSERVER: already running")
            return
        }

        // Background audio session — keeps iOS process alive when screen locks
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
                print("HTTPSERVER: started on port 8080 — device IP: \(SorrivaHTTPServer.wifiIPAddress() ?? "unknown")")
            case .failed(let error):
                print("HTTPSERVER: listener failed — \(error)")
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
        print("HTTPSERVER: stopped")
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

            // Check if we have the full HTTP header block
            let separator1 = Data("\r\n\r\n".utf8)
            let separator2 = Data("\n\n".utf8)
            if buffer.range(of: separator1) != nil || buffer.range(of: separator2) != nil {
                // Full headers received — process request
                guard let request = String(data: buffer, encoding: .utf8) else {
                    self.sendError(connection: connection, status: "400 Bad Request")
                    return
                }
                self.processRequest(request, connection: connection)
            } else if isComplete {
                // Connection closed before full headers
                connection.cancel()
            } else {
                // Keep reading
                self.readRequest(connection: connection, accumulated: buffer)
            }
        }
    }

    private func processRequest(_ request: String, connection: NWConnection) {
        // Parse request line: GET /track/[id].flac HTTP/1.1
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
        print("HTTPSERVER: request — \(path)")

        guard path.hasPrefix("/track/") else {
            sendError(connection: connection, status: "404 Not Found")
            return
        }

        // Strip /track/ prefix and file extension
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

        // Parse Range header
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

        // Look up track and source
        guard let track = try? SorrivaDatabase.shared.track(id: trackId) else {
            print("HTTPSERVER: track not found — \(trackId)")
            sendError(connection: connection, status: "404 Not Found")
            return
        }

        guard let source = try? SorrivaDatabase.shared.librarySource(id: track.sourceId) else {
            print("HTTPSERVER: source not found — \(track.title)")
            sendError(connection: connection, status: "404 Not Found")
            return
        }

        let fileSize = track.fileSize ?? 0
        let contentType = Self.contentType(for: track.fileFormat)
        let rangeEnd = fileSize > 0 ? fileSize - 1 : 0
        let contentLength = fileSize > 0 ? fileSize - rangeStart : 0

        print("HTTPSERVER: streaming \(track.title) from offset \(rangeStart), fileSize \(fileSize)")

        // Send headers with full Content-Length — Sonos manages Range requests itself
        let statusLine = rangeStart > 0 ? "206 Partial Content" : "200 OK"
        var headers = "HTTP/1.1 \(statusLine)\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(contentLength)\r\n"
        headers += "Accept-Ranges: bytes\r\n"
        if fileSize > 0 && rangeStart > 0 {
            headers += "Content-Range: bytes \(rangeStart)-\(rangeEnd)/\(fileSize)\r\n"
        }
        headers += "Cache-Control: no-cache\r\n"
        headers += "Connection: close\r\n"
        headers += "\r\n"

        sendData(Data(headers.utf8), connection: connection)

        // Stream SMB file in 8MB chunks — multiple reads, single HTTP response body
        let smbHost = source.host
        let smbShare = source.share
        let smbUser = source.username ?? ""
        let smbPass = source.password ?? ""
        let filePath = track.filePath
        let chunkSize = 1 * 1024 * 1024  // 1MB — test smaller reads

        Task.detached { [weak self] in
            guard let self else { return }
            await self.streamSMBFile(
                host: smbHost, share: smbShare,
                username: smbUser, password: smbPass,
                path: filePath,
                startOffset: rangeStart,
                chunkSize: chunkSize,
                connection: connection
            )
        }
    }

    // MARK: - SMB streaming

    private func streamSMBFile(
        host: String, share: String,
        username: String, password: String,
        path: String,
        startOffset: Int,
        chunkSize: Int,
        connection: NWConnection
    ) async {
        var offset = startOffset
        var totalSent = 0

        while true {
            let data = await Self.readSMBRange(
                host: host, share: share,
                username: username, password: password,
                path: path,
                offset: offset,
                length: chunkSize
            )

            guard let data = data, !data.isEmpty else {
                print("HTTPSERVER: EOF at offset \(offset), total: \(totalSent)")
                break
            }

            let sendOK = await withCheckedContinuation { continuation in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        print("HTTPSERVER: send error at offset \(offset) — \(error)")
                        continuation.resume(returning: false)
                    } else {
                        continuation.resume(returning: true)
                    }
                })
            }

            guard sendOK else {
                print("HTTPSERVER: send failed at offset \(offset) — stopping")
                break
            }

            offset += data.count
            totalSent += data.count
            print("HTTPSERVER: sent \(data.count) bytes at offset \(offset), total: \(totalSent)")

            if data.count < chunkSize { break }
        }

        print("HTTPSERVER: stream complete — \(totalSent) bytes sent")
        try? await Task.sleep(nanoseconds: 500_000_000)
        connection.cancel()
    }

    // MARK: - Helpers

    private func sendData(_ data: Data, connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("HTTPSERVER: send error — \(error)")
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

    // MARK: - SMB read (fresh connection per call — UNAS Pro drops persistent connections)

    private static func readSMBRange(
        host: String, share: String,
        username: String, password: String,
        path: String,
        offset: Int,
        length: Int
    ) async -> Data? {
        guard length > 0 else { return Data() }
        do {
            let client = SMBClient(host: host)
            try await client.login(
                username: username.isEmpty ? "guest" : username,
                password: password
            )
            defer { Task { try? await client.logoff() } }
            try await client.connectShare(share)
            defer { Task { try? await client.disconnectShare() } }
            let reader = client.fileReader(path: path)
            defer { Task { try? await reader.close() } }
            let data = try await reader.read(
                offset: UInt64(offset),
                length: UInt32(min(length, Int(UInt32.max)))
            )
            return data
        } catch {
            print("HTTPSERVER: SMB error at offset \(offset) — \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Range header parsing
    // Returns start byte only — we stream from there to EOF

    private static func parseRangeHeader(_ header: String) -> Int? {
        guard header.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = String(header.dropFirst("bytes=".count))
        let parts = spec.components(separatedBy: "-")
        guard let start = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        return start
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

    // MARK: - WiFi IP

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
