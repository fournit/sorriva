import Foundation

// MARK: - SonosEndpointDriver
// Implements AudioEndpointDriver for Sonos endpoints.
// ADR-008: wraps existing SOAP mechanics — does not rewrite them.
//
// All SOAP calls now return typed results or throw EndpointCommandError.
// No print/log-only error handling — failures propagate to callers.
//
// ZoneDiscoveryService retains: discovery, topology parsing, polling, state reduction.
// SonosEndpointDriver owns: all command execution.

@MainActor
final class SonosEndpointDriver {

    static let shared = SonosEndpointDriver()

    let kind: EndpointKind = .sonos

    // Reference to discovery for host lookup and post-command refresh.
    // Set by SorrivaAppEnvironment after both are constructed.
    weak var discovery: ZoneDiscoveryService?

    private init() {}

    // MARK: - AudioEndpointDriver conformance

    func execute(
        _ command: EndpointCommand,
        on endpointID: EndpointID
    ) async throws -> EndpointCommandResult {
        let host = try resolveHost(for: endpointID)
        switch command {
        case .play:
            try await sendTransportAction(host: host, action: "Play")
            return .success

        case .pause:
            try await sendTransportAction(host: host, action: "Pause")
            return .success

        case .skipNext:
            try await sendTransportAction(host: host, action: "Next")
            return .success

        case .skipPrevious:
            try await sendTransportAction(host: host, action: "Previous")
            return .success

        case .seek(let seconds):
            try await sendSeek(host: host, seconds: seconds)
            return .success

        case .setVolume(let volume):
            try await sendSetVolume(host: host, volume: volume)
            return .success

        case .setMemberVolume(let memberID, let volume):
            let memberHost = try resolveHost(for: EndpointID(rawValue: memberID))
            try await sendSetVolume(host: memberHost, volume: volume)
            return .success

        case .clearQueue:
            try await removeAllTracksFromQueue(host: host)
            return .success

        case .addToQueue(let uri, let metadata, _):
            try await addURIToQueue(host: host, uri: uri, didl: metadata)
            return .success

        case .setTransportURI(let uri, let metadata):
            try await setAVTransportURI(host: host, uri: uri, metadata: metadata)
            return .success

        case .group(let coordinatorID, let addIDs, let removeIDs):
            let coordHost = try resolveHost(for: coordinatorID)
            for id in removeIDs {
                let memberHost = try resolveHost(for: id)
                try await becomeCoordinator(host: memberHost)
            }
            for id in addIDs {
                let memberHost = try resolveHost(for: id)
                try await addMember(coordinatorHost: coordHost,
                                    memberHost: memberHost,
                                    memberUUID: coordinatorID.rawValue)
            }
            return .success

        case .ungroup:
            try await becomeCoordinator(host: host)
            return .success

        case .transfer(let destID):
            let destHost = try resolveHost(for: destID)
            try await addMember(coordinatorHost: host,
                                memberHost: destHost,
                                memberUUID: endpointID.rawValue)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try await becomeCoordinator(host: host)
            return .success

        case .registerShare(let nasPath):
            try await createObject(host: host, nasPath: nasPath)
            return .success
        }
    }

    /// Build and execute an album queue — returns partialQueue result if any tracks fail.
    func addAlbumToQueue(
        host: String,
        items: [(uri: String, didl: String, title: String)]
    ) async throws -> EndpointCommandResult {
        var added = 0
        var lastError: EndpointCommandError?
        for item in items {
            do {
                try await addURIToQueue(host: host, uri: item.uri, didl: item.didl)
                added += 1
            } catch let e as EndpointCommandError {
                sLog("SONOS DRIVER: addToQueue failed for \(item.title): \(e.localizedDescription)")
                lastError = e
            }
        }
        if added == items.count {
            return .success
        } else if added == 0, let e = lastError {
            throw e
        } else {
            return .partialQueue(added: added, requested: items.count)
        }
    }

    func state(for endpointID: EndpointID) async throws -> EndpointPlaybackState {
        let host = try resolveHost(for: endpointID)
        // Delegate to ZoneDiscoveryService polling state
        guard let zone = discovery?.zones.first(where: { $0.id == endpointID.rawValue }) else {
            throw EndpointCommandError.endpointUnavailable(id: endpointID)
        }
        return EndpointPlaybackState(
            endpointID: endpointID,
            isPlaying: zone.isPlaying,
            volume: zone.volume,
            currentTrackURI: zone.currentTrackURI,
            elapsedSeconds: zone.elapsedSeconds,
            durationSeconds: zone.durationSeconds,
            trackTitle: zone.currentTrack,
            artistName: zone.currentArtist
        )
    }

    func discoverEndpoints() async throws -> EndpointTopology {
        let zones = discovery?.zones ?? []
        let descriptors = zones.map { zone in
            EndpointDescriptor(
                id: EndpointID(rawValue: zone.id),
                name: zone.name,
                host: zone.host,
                kind: .sonos,
                groupMemberIDs: zone.groupMembers.map { EndpointID(rawValue: $0.id) },
                coordinatorID: nil
            )
        }
        return EndpointTopology(endpoints: descriptors)
    }

    // MARK: - Host resolution

    private func resolveHost(for endpointID: EndpointID) throws -> String {
        // Check coordinator zones
        if let zone = discovery?.zones.first(where: { $0.id == endpointID.rawValue }) {
            guard !zone.host.isEmpty else {
                throw EndpointCommandError.endpointUnavailable(id: endpointID)
            }
            return zone.host
        }
        // Check group members
        if let member = discovery?.zones.flatMap({ $0.groupMembers })
            .first(where: { $0.id == endpointID.rawValue }) {
            return member.host
        }
        throw EndpointCommandError.endpointUnavailable(id: endpointID)
    }

    // MARK: - SOAP primitives (typed — no silent swallowing)

    func sendTransportAction(host: String, action: String) async throws {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <Speed>1</Speed>
            </u:\(action)>
          </s:Body>
        </s:Envelope>
        """
        try await soapRequest(
            host: host,
            path: "/MediaRenderer/AVTransport/Control",
            action: "AVTransport#\(action)",
            body: soapBody
        )
        sLog("SONOS DRIVER: \(action) → \(host) OK")
    }

    func addURIToQueue(host: String, uri: String, didl: String = "") async throws {
        let escapedURI = uri
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:AddURIToQueue xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <EnqueuedURI>\(escapedURI)</EnqueuedURI>
              <EnqueuedURIMetaData>\(didl)</EnqueuedURIMetaData>
              <DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued>
              <EnqueueAsNext>0</EnqueueAsNext>
            </u:AddURIToQueue>
          </s:Body>
        </s:Envelope>
        """
        try await soapRequest(
            host: host,
            path: "/MediaRenderer/AVTransport/Control",
            action: "AVTransport#AddURIToQueue",
            body: soapBody
        )
    }

    func removeAllTracksFromQueue(host: String) async throws {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:RemoveAllTracksFromQueue xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
            </u:RemoveAllTracksFromQueue>
          </s:Body>
        </s:Envelope>
        """
        try await soapRequest(
            host: host,
            path: "/MediaRenderer/AVTransport/Control",
            action: "AVTransport#RemoveAllTracksFromQueue",
            body: soapBody
        )
    }

    func setAVTransportURI(host: String, uri: String, metadata: String = "") async throws {
        let escaped = uri
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <CurrentURI>\(escaped)</CurrentURI>
              <CurrentURIMetaData>\(metadata)</CurrentURIMetaData>
            </u:SetAVTransportURI>
          </s:Body>
        </s:Envelope>
        """
        try await soapRequest(
            host: host,
            path: "/MediaRenderer/AVTransport/Control",
            action: "AVTransport#SetAVTransportURI",
            body: soapBody
        )
    }

    func sendSetVolume(host: String, volume: Int) async throws {
        let clamped = max(0, min(100, volume))
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
              <InstanceID>0</InstanceID>
              <Channel>Master</Channel>
              <DesiredVolume>\(clamped)</DesiredVolume>
            </u:SetVolume>
          </s:Body>
        </s:Envelope>
        """
        try await soapRequest(
            host: host,
            path: "/MediaRenderer/RenderingControl/Control",
            action: "RenderingControl#SetVolume",
            body: soapBody
        )
    }

    func sendSeek(host: String, seconds: Int) async throws {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        let target = String(format: "%d:%02d:%02d", h, m, s)
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:Seek xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <Unit>REL_TIME</Unit>
              <Target>\(target)</Target>
            </u:Seek>
          </s:Body>
        </s:Envelope>
        """
        try await soapRequest(
            host: host,
            path: "/MediaRenderer/AVTransport/Control",
            action: "AVTransport#Seek",
            body: soapBody
        )
    }

    func addMember(coordinatorHost: String, memberHost: String, memberUUID: String) async throws {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <CurrentURI>x-rincon:\(memberUUID)</CurrentURI>
              <CurrentURIMetaData></CurrentURIMetaData>
            </u:SetAVTransportURI>
          </s:Body>
        </s:Envelope>
        """
        try await soapRequest(
            host: memberHost,
            path: "/MediaRenderer/AVTransport/Control",
            action: "AVTransport#SetAVTransportURI",
            body: soapBody,
            timeout: 5
        )
        sLog("SONOS DRIVER: AddMember \(memberHost) → \(memberUUID) OK")
    }

    func becomeCoordinator(host: String) async throws {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:BecomeCoordinatorOfStandaloneGroup xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
            </u:BecomeCoordinatorOfStandaloneGroup>
          </s:Body>
        </s:Envelope>
        """
        try await soapRequest(
            host: host,
            path: "/MediaRenderer/AVTransport/Control",
            action: "AVTransport#BecomeCoordinatorOfStandaloneGroup",
            body: soapBody,
            timeout: 5
        )
    }

    func createObject(host: String, nasPath: String) async throws {
        let escapedPath = nasPath
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let didl = "&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;container id=&quot;&quot; parentID=&quot;S:&quot; restricted=&quot;false&quot;&gt;&lt;dc:title&gt;\(escapedPath)&lt;/dc:title&gt;&lt;upnp:class&gt;object.container&lt;/upnp:class&gt;&lt;/container&gt;&lt;/DIDL-Lite&gt;"
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:CreateObject xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
              <ContainerID>S:</ContainerID>
              <Elements>\(didl)</Elements>
            </u:CreateObject>
          </s:Body>
        </s:Envelope>
        """
        try await soapRequest(
            host: host,
            path: "/MediaServer/ContentDirectory/Control",
            action: "ContentDirectory#CreateObject",
            body: soapBody,
            timeout: 8
        )
        sLog("SONOS DRIVER: CreateObject \(nasPath) on \(host) OK")
    }

    // MARK: - Core SOAP transport

    /// Execute a SOAP request and throw typed errors on failure.
    /// This is the single point where all Sonos HTTP errors are classified.
    @discardableResult
    func soapRequest(
        host: String,
        path: String,
        action: String,
        body: String,
        timeout: TimeInterval = 3
    ) async throws -> Data {
        guard let url = URL(string: "http://\(host):1400\(path)"),
              let bodyData = body.data(using: .utf8) else {
            throw EndpointCommandError.unknown("Invalid URL or body for \(path)", underlying: nil)
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Build full SOAPACTION URN from short action name
        let soapAction: String
        if action.hasPrefix("AVTransport#") {
            soapAction = "\"urn:schemas-upnp-org:service:AVTransport:1#\(action.dropFirst("AVTransport#".count))\""
        } else if action.hasPrefix("RenderingControl#") {
            soapAction = "\"urn:schemas-upnp-org:service:RenderingControl:1#\(action.dropFirst("RenderingControl#".count))\""
        } else if action.hasPrefix("ContentDirectory#") {
            soapAction = "\"urn:schemas-upnp-org:service:ContentDirectory:1#\(action.dropFirst("ContentDirectory#".count))\""
        } else {
            soapAction = "\"\(action)\""
        }
        request.setValue(soapAction, forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 200 || status == 207 { return data }

            // Parse UPnP error from response body
            let responseText = String(data: data, encoding: .utf8) ?? ""
            let (faultCode, faultDesc) = parseSoapFault(responseText)
            sLog("SONOS DRIVER: SOAP fault \(action) → \(host) status=\(status) code=\(faultCode) desc=\(faultDesc)")
            throw EndpointCommandError.soapFault(code: faultCode, description: faultDesc)

        } catch let error as EndpointCommandError {
            throw error
        } catch {
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut || nsError.code == NSURLErrorCannotConnectToHost {
                throw EndpointCommandError.timeout(underlying: error)
            }
            throw EndpointCommandError.unknown(error.localizedDescription, underlying: error)
        }
    }

    // MARK: - SOAP fault parsing

    private func parseSoapFault(_ body: String) -> (Int, String) {
        // Extract <errorCode> and <errorDescription> from UPnP fault envelope
        var code = 0
        var desc = "Unknown SOAP fault"
        if let cStart = body.range(of: "<errorCode>"),
           let cEnd = body.range(of: "</errorCode>") {
            let codeStr = String(body[cStart.upperBound..<cEnd.lowerBound])
            code = Int(codeStr.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        if let dStart = body.range(of: "<errorDescription>"),
           let dEnd = body.range(of: "</errorDescription>") {
            desc = String(body[dStart.upperBound..<dEnd.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        } else if let dStart = body.range(of: "<faultstring>"),
                  let dEnd = body.range(of: "</faultstring>") {
            desc = String(body[dStart.upperBound..<dEnd.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }
        return (code, desc)
    }
}
