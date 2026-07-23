import Foundation
import Network
import Combine

// MARK: - ZoneDiscoveryService
// Discovers the full Sonos household topology via a single SOAP call to any speaker.
// Uses GetZoneGroupState from ZoneGroupTopology:1 on port 1400 — the same undocumented
// UPnP layer used by Roon, SoCo, and every working third-party Sonos integration.
//
// Strategy:
// 1. NetServiceBrowser finds any one Sonos speaker on the network
// 2. We fire GetZoneGroupState at that speaker — returns the ENTIRE household topology
// 3. Parse ZoneGroup elements: coordinator = the zone, Satellite Invisible="1" = hidden
// 4. Result: clean zone list matching what the Sonos app shows

@MainActor
final class ZoneDiscoveryService: NSObject, ObservableObject {

    @Published var zones: [SonosZone] = []       // Display-ready zone list, alpha sorted
    @Published var isDiscovering: Bool = false
    @Published var discoveryError: String? = nil

    private var serviceBrowser: NetServiceBrowser?
    private var pendingServices: [NetService] = []
    private var topologyFetched = false
    private var refreshTask: Task<Void, Never>?

    // MARK: - Compatibility shim for ZonesView (uses devices/activeGroups/availableDevices)

    var devices: [String: SonosDevice] {
        Dictionary(uniqueKeysWithValues: zones.map { ($0.id, $0.asDevice) })
    }

    var activeGroups: [SonosGroup] {
        zones.filter { $0.isPlaying }
            .map { $0.asGroup }
            .sorted { $0.name < $1.name }
    }

    var availableDevices: [SonosDevice] {
        zones.filter { !$0.isPlaying }
            .map { $0.asDevice }
            .sorted { $0.name < $1.name }
    }

    // MARK: - Public interface

    func startDiscovery() {
        guard serviceBrowser == nil else { return }
        print("SORRIVA: startDiscovery — looking for any Sonos speaker")
        isDiscovering = true
        discoveryError = nil
        topologyFetched = false

        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: "_sonos._tcp", inDomain: "local.")
        self.serviceBrowser = browser
    }

    func stopDiscovery() {
        serviceBrowser?.stop()
        serviceBrowser = nil
        pendingServices.forEach { $0.stop() }
        pendingServices = []
        refreshTask?.cancel()
        refreshTask = nil
        isDiscovering = false
        topologyFetched = false
    }

    func refresh() {
        guard let anyZone = zones.first else {
            // No zones yet — restart discovery
            stopDiscovery()
            startDiscovery()
            return
        }
        refreshTask?.cancel()
        refreshTask = Task {
            await self.fetchTopology(host: anyZone.host)
        }
    }

    // MARK: - Private

    fileprivate func serviceResolved(_ service: NetService) {
        guard !topologyFetched else { return }

        // Extract IPv4 address
        guard let addresses = service.addresses else { return }
        var host: String? = nil

        for data in addresses {
            if let ip = ipv4String(from: data) {
                host = ip
                break
            }
        }

        guard let host else {
            print("SORRIVA: Could not extract IPv4 from \(service.name)")
            return
        }

        print("SORRIVA: Got speaker at \(host) — fetching household topology")
        topologyFetched = true  // Only need one topology fetch

        // Stop browsing — we have what we need
        serviceBrowser?.stop()
        serviceBrowser = nil

        Task {
            await self.fetchTopology(host: host)
        }
    }

    private func fetchTopology(host: String) async {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetZoneGroupState xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"/>
          </s:Body>
        </s:Envelope>
        """

        guard let url = URL(string: "http://\(host):1400/ZoneGroupTopology/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:ZoneGroupTopology:1#GetZoneGroupState\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("SORRIVA: Topology response status=\(status) bytes=\(data.count)")

            if let parsed = parseTopology(data: data) {
                zones = parsed.sorted { $0.name < $1.name }
                print("SORRIVA: Parsed \(zones.count) zones: \(zones.map(\.name).joined(separator: ", "))")
                // Sync topology to DB — upsert household + devices, load capabilities
                await syncTopologyToDB(host: host)
                // Fetch transport state for all coordinators concurrently
                await fetchTransportStates()
                // Fetch station metadata for ALL zones on startup — repopulates stationName/art
                await fetchAllStationMetadata()
                // Restore last-used station from DB for idle zones
                restoreZoneStateFromDB()
                // Start 5-second transport poll cycle
                startPolling()
            } else {
                print("SORRIVA: Failed to parse topology")
                if let str = String(data: data.prefix(500), encoding: .utf8) {
                    print("SORRIVA: Raw: \(str)")
                }
            }
        } catch {
            print("SORRIVA: Topology fetch error: \(error.localizedDescription)")
            discoveryError = error.localizedDescription
        }

        isDiscovering = false
    }

    private func fetchTransportStates() async {
        let snapshot = zones

        // Fetch transport state + volume for all zones concurrently
        let results: [(String, Bool, Int)] = await withTaskGroup(of: (String, Bool, Int).self) { group in
            for zone in snapshot {
                let id = zone.id
                let host = zone.host
                group.addTask {
                    async let playing = ZoneDiscoveryService.transportInfo(host: host)
                    async let vol = ZoneDiscoveryService.volumeInfo(host: host)
                    return (id, await playing, await vol)
                }
            }
            var collected: [(String, Bool, Int)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        // Track which zones just started playing (idle → playing transition)
        var newlyPlayingZones: [SonosZone] = []

        for (id, playing, vol) in results {
            if let idx = zones.firstIndex(where: { $0.id == id }) {
                let effectivePlaying = playing && !zones[idx].idleState

                // Honor grace period — if we just started playing, don't override with STOPPED
                let inGracePeriod = zones[idx].playingUntil.map { Date() < $0 } ?? false
                let finalPlaying = inGracePeriod ? (effectivePlaying || zones[idx].isPlaying) : effectivePlaying

                let wasPlaying = zones[idx].isPlaying

                // Detect idle → playing transition for GetMediaInfo fetch
                if finalPlaying && !wasPlaying {
                    newlyPlayingZones.append(zones[idx])
                }

                zones[idx].isPlaying = finalPlaying
                zones[idx].volume = vol

                // Clear stale track info when zone stops (only outside grace period)
                if !finalPlaying && !inGracePeriod {
                    zones[idx].currentTrack = ""
                    zones[idx].currentArtist = ""
                    zones[idx].isHDMI = false
                    zones[idx].playingUntil = nil
                }
            }
        }

        // Fetch volume for group members
        for (zoneIdx, zone) in zones.enumerated() {
            guard !zone.groupMembers.isEmpty else { continue }
            for (memberIdx, member) in zone.groupMembers.enumerated() {
                let host = member.host
                Task { @MainActor in
                    let vol = await ZoneDiscoveryService.volumeInfo(host: host)
                    if zoneIdx < self.zones.count && memberIdx < self.zones[zoneIdx].groupMembers.count {
                        self.zones[zoneIdx].groupMembers[memberIdx].volume = vol
                    }
                }
            }
        }

        // Fetch GetPositionInfo for ALL playing zones — adaptive interval based on state
        let positionResults: [(String, Data)] = await withTaskGroup(of: (String, Data?).self) { group in
            for zone in zones.filter({ $0.isPlaying }) {
                let id = zone.id
                let host = zone.host
                group.addTask {
                    let data = await ZoneDiscoveryService.fetchPositionData(host: host)
                    return (id, data)
                }
            }
            var collected: [(String, Data)] = []
            for await (id, data) in group {
                if let d = data { collected.append((id, d)) }
            }
            return collected
        }

        for (id, data) in positionResults {
            updateZoneFromPositionInfo(zoneID: id, positionData: data)
        }

        // Fetch GetMediaInfo ONLY for zones that just started playing (state transition)
        // Station name/art is static — no need to re-fetch every 5 seconds
        if !newlyPlayingZones.isEmpty {
            print("SORRIVA: \(newlyPlayingZones.count) zones newly playing — fetching station metadata")
            await withTaskGroup(of: (String, String, String).self) { group in
                for zone in newlyPlayingZones {
                    let id = zone.id
                    let host = zone.host
                    group.addTask {
                        let info = await ZoneDiscoveryService.fetchMediaInfo(host: host)
                        return (id, info?.name ?? "", info?.artURL ?? "")
                    }
                }
                for await (id, name, art) in group {
                    if let idx = zones.firstIndex(where: { $0.id == id }) {
                        if !name.isEmpty { zones[idx].stationName = name }
                        if !art.isEmpty {
                            zones[idx].stationLogoURL = art
                            // Pre-warm image cache
                            Task {
                                if let url = URL(string: art) {
                                    let req = URLRequest(url: url)
                                    if URLCache.shared.cachedResponse(for: req) == nil,
                                       let (data, response) = try? await URLSession.shared.data(for: req) {
                                        URLCache.shared.storeCachedResponse(
                                            CachedURLResponse(response: response, data: data), for: req)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Exposed for testing only.
    nonisolated static func parseTimeStringPublic(_ s: String) -> Int { parseTimeString(s) }

    private nonisolated static func parseTimeString(_ s: String) -> Int {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return 0
        }
    }

    private static func fetchPositionData(host: String) async -> Data? {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
            </u:GetPositionInfo>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/AVTransport/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 3
        return try? await URLSession.shared.data(for: request).0
    }

    private static func fetchMediaInfo(host: String) async -> (name: String, artURL: String)? {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetMediaInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
            </u:GetMediaInfo>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/AVTransport/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#GetMediaInfo\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 3

        guard let data = try? await URLSession.shared.data(for: request).0,
              let raw = String(data: data, encoding: .utf8) else {
            print("SORRIVA: GetMediaInfo fetch failed for \(host)")
            return nil
        }

        print("SORRIVA: GetMediaInfo raw (\(host)): \(raw.prefix(500))")

        // Decode entities — match Python order exactly
        let decoded = raw
            .replacingOccurrences(of: "&amp;quot;", with: "\"")
            .replacingOccurrences(of: "&amp;lt;",   with: "<")
            .replacingOccurrences(of: "&amp;gt;",   with: ">")
            .replacingOccurrences(of: "&amp;amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",       with: "<")
            .replacingOccurrences(of: "&gt;",       with: ">")
            .replacingOccurrences(of: "&quot;",     with: "\"")
            .replacingOccurrences(of: "&amp;",      with: "&")
            .replacingOccurrences(of: "&apos;",     with: "'")

        print("SORRIVA: GetMediaInfo decoded (\(host)): \(decoded.prefix(500))")

        // HDMI/TV source — no station metadata to extract
        if decoded.contains("x-sonos-htastream") || decoded.contains("x-rincon-stream") {
            print("SORRIVA: GetMediaInfo — HDMI/TV source detected, skipping")
            return nil
        }

        var stationName = ""
        if let start = decoded.range(of: "<dc:title>"),
           let end = decoded.range(of: "</dc:title>") {
            let title = String(decoded[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("SORRIVA: GetMediaInfo title='\(title)'")
            if !title.hasPrefix("http") && !title.contains(".m3u8") &&
               !title.contains("?rj-") && !title.hasPrefix("RINCON_") && !title.isEmpty {
                stationName = title
            }
        } else {
            print("SORRIVA: GetMediaInfo — no dc:title found in decoded")
        }

        var artURL = ""
        if let start = decoded.range(of: "<upnp:albumArtURI>"),
           let end = decoded.range(of: "</upnp:albumArtURI>") {
            artURL = String(decoded[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("SORRIVA: GetMediaInfo artURL='\(artURL)'")
        }

        guard !stationName.isEmpty else {
            print("SORRIVA: GetMediaInfo — stationName empty, returning nil")
            return nil
        }
        return (name: stationName, artURL: artURL)
    }

    private func syncTopologyToDB(host: String) async {
        print("SORRIVA DB: syncTopologyToDB starting, host=\(host), zones=\(zones.count)")
        // Get household ID from ZoneGroupAttributes
        let hhid = await fetchHouseholdID(host: host) ?? "unknown"
        print("SORRIVA DB: hhid=\(hhid)")
        do {
            try SorrivaDatabase.shared.upsertHousehold(hhid: hhid, sonosName: nil)
            print("SORRIVA DB: Household upserted")
        } catch {
            print("SORRIVA DB: Household upsert error: \(error)")
        }

        // Upsert each zone coordinator into devices table
        print("SORRIVA DB: Starting device loop for \(zones.count) zones")
        for (idx, zone) in zones.enumerated() {
            print("SORRIVA DB: Processing device \(zone.name) (\(zone.id))")
            do {
                // Check if device already exists in DB
                let existing = try SorrivaDatabase.shared.device(sourceId: zone.id, source: "sonos")
                print("SORRIVA DB: device lookup for \(zone.name): existing=\(existing?.id ?? "nil")")

                if let device = existing {
                    // Known device — load capabilities from DB
                    zones[idx].capabilities = device.capabilities
                    zones[idx].dbDeviceId = device.id
                } else {
                    // New device — fetch model name from device description
                    let modelName = await SorrivaDatabase.fetchModelName(host: zone.host)
                    let device = try SorrivaDatabase.shared.upsertDevice(
                        sourceId: zone.id,
                        source: "sonos",
                        householdId: hhid,
                        modelName: modelName,
                        sourceName: zone.name
                    )
                    zones[idx].capabilities = device.capabilities
                    zones[idx].dbDeviceId = device.id
                    print("SORRIVA DB: Registered new device \(zone.name) model=\(modelName ?? "unknown") caps=\(device.capabilities)")
                }
            } catch {
                print("SORRIVA DB: Device upsert error for \(zone.name): \(error)")
            }
        }
    }

    private func fetchHouseholdID(host: String) async -> String? {
        // GetZoneGroupAttributes returns CurrentMuseHouseholdId
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetZoneGroupAttributes xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"/>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/ZoneGroupTopology/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:ZoneGroupTopology:1#GetZoneGroupAttributes\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let raw = String(data: data, encoding: .utf8),
              let start = raw.range(of: "<CurrentMuseHouseholdId>"),
              let end = raw.range(of: "</CurrentMuseHouseholdId>") else { return nil }
        return String(raw[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func restoreZoneStateFromDB() {
        for (idx, zone) in zones.enumerated() {
            guard !zone.dbDeviceId.isEmpty else { continue }
            do {
                if let state = try SorrivaDatabase.shared.zoneState(deviceId: zone.dbDeviceId) {
                    if zones[idx].stationName.isEmpty, let name = state.stationName {
                        zones[idx].stationName = name
                    }
                    if zones[idx].stationLogoURL.isEmpty, let logo = state.stationLogoURL {
                        zones[idx].stationLogoURL = logo
                        // Pre-warm image cache so Now Playing art is instant
                        Task {
                            if let url = URL(string: logo) {
                                let req = URLRequest(url: url)
                                if URLCache.shared.cachedResponse(for: req) == nil,
                                   let (data, response) = try? await URLSession.shared.data(for: req) {
                                    URLCache.shared.storeCachedResponse(
                                        CachedURLResponse(response: response, data: data), for: req)
                                }
                            }
                        }
                    }
                }
            } catch {
                print("SORRIVA DB: Zone state restore error: \(error)")
            }
        }
        print("SORRIVA DB: Zone state restored from DB")
    }

    private func fetchAllStationMetadata() async {
        await withTaskGroup(of: (String, String, String).self) { group in
            for zone in zones {
                let id = zone.id
                let host = zone.host
                group.addTask {
                    let info = await ZoneDiscoveryService.fetchMediaInfo(host: host)
                    return (id, info?.name ?? "", info?.artURL ?? "")
                }
            }
            for await (id, name, art) in group {
                if let idx = zones.firstIndex(where: { $0.id == id }) {
                    if !name.isEmpty { zones[idx].stationName = name }
                    if !art.isEmpty {
                        zones[idx].stationLogoURL = art
                        // Pre-warm image cache so Now Playing art is instant
                        Task {
                            if let url = URL(string: art) {
                                let req = URLRequest(url: url)
                                if URLCache.shared.cachedResponse(for: req) == nil,
                                   let (data, response) = try? await URLSession.shared.data(for: req) {
                                    URLCache.shared.storeCachedResponse(
                                        CachedURLResponse(response: response, data: data), for: req)
                                }
                            }
                        }
                    }
                }
            }
        }
        print("SORRIVA: Station metadata populated for \(zones.filter { !$0.stationName.isEmpty }.count) zones")
    }

    private func startPolling() {
        refreshTask?.cancel()
        var pollCount = 0
        var consecutiveFailures = 0
        refreshTask = Task {
            while !Task.isCancelled {
                // Adaptive interval:
                // — 2s when playing zones exist (responsive position updates)
                // — 5s when paused or idle
                // — 15s backoff after 3 consecutive failures
                let hasPlaying = zones.contains { $0.isPlaying && !$0.idleState }
                let backingOff = consecutiveFailures >= 3
                let intervalNs: UInt64 = backingOff ? 15_000_000_000
                                       : hasPlaying  ?  2_000_000_000
                                       :                 5_000_000_000
                try? await Task.sleep(nanoseconds: intervalNs)
                guard !Task.isCancelled else { break }
                await fetchTransportStates()
                // Track failures for backoff — reset on any zones responding
                if zones.isEmpty {
                    consecutiveFailures += 1
                } else {
                    consecutiveFailures = 0
                }
                pollCount += 1
                // Lightweight IdleState refresh every 15s (3 polls at 5s, or more at 2s)
                if pollCount >= 3 {
                    pollCount = 0
                    if let anyHost = zones.first?.host {
                        await refreshIdleStates(host: anyHost)
                    }
                }
            }
        }
    }

    // Fetch fresh IdleState from topology without replacing the zones array
    private func refreshIdleStates(host: String) async {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetZoneGroupState xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"/>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/ZoneGroupTopology/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:ZoneGroupTopology:1#GetZoneGroupState\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 5

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let raw = String(data: data, encoding: .utf8),
              let start = raw.range(of: "<ZoneGroupState>"),
              let end = raw.range(of: "</ZoneGroupState>") else { return }

        let encoded = String(raw[start.upperBound..<end.lowerBound])
        let decoded = encoded
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")

        // Extract IdleState per UUID — update in-place, no array replacement
        let pattern = #"UUID="([^"]+)"[^>]*IdleState="(\d)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = regex.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded))
        for match in matches {
            guard let uuidRange = Range(match.range(at: 1), in: decoded),
                  let stateRange = Range(match.range(at: 2), in: decoded) else { continue }
            let uuid = String(decoded[uuidRange])
            let idle = decoded[stateRange] == "1"
            if let idx = zones.firstIndex(where: { $0.id == uuid }) {
                zones[idx].idleState = idle
            }
        }
    }

    // MARK: - Live station metadata (iHeart)
    // When a zone is playing an iHeart stream, we extract the stream ID from the HLS URL
    // and cache it. When the zone is paused, we poll iHeart every 15s for current on-air
    // track and station art — giving users "what's on now" even when paused.

    // Called from fetchTransportStates when we get UPnP position info for a playing zone
    func updateZoneFromPositionInfo(zoneID: String, positionData: Data) {
        guard let idx = zones.firstIndex(where: { $0.id == zoneID }) else { return }
        let raw = String(data: positionData, encoding: .utf8) ?? ""

        // Detect HDMI/TV source — clear stale radio metadata
        let isHDMI = raw.contains("x-sonos-htastream") || raw.contains("x-rincon-stream")
        if isHDMI {
            zones[idx].isHDMI = true
            zones[idx].currentTrack = "TV"
            zones[idx].currentArtist = "HDMI"
            zones[idx].stationName = ""
            zones[idx].stationLogoURL = ""
            return
        }

        // Non-HDMI source — clear HDMI flag if it was previously set
        zones[idx].isHDMI = false

        // Parse current TrackURI for local queue advancement
        if let tStart = raw.range(of: "<TrackURI>"),
           let tEnd = raw.range(of: "</TrackURI>") {
            let uri = String(raw[tStart.upperBound..<tEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&")
            if !uri.isEmpty && uri != zones[idx].currentTrackURI {
                zones[idx].currentTrackURI = uri
            }
        }

        // Parse playback position and duration
        if let relStart = raw.range(of: "<RelTime>"),
           let relEnd = raw.range(of: "</RelTime>") {
            let t = String(raw[relStart.upperBound..<relEnd.lowerBound]).trimmingCharacters(in: .whitespaces)
            zones[idx].elapsedSeconds = Self.parseTimeString(t)
        }
        if let durStart = raw.range(of: "<TrackDuration>"),
           let durEnd = raw.range(of: "</TrackDuration>") {
            let t = String(raw[durStart.upperBound..<durEnd.lowerBound]).trimmingCharacters(in: .whitespaces)
            zones[idx].durationSeconds = Self.parseTimeString(t)
        }

        // Parse current track from r:streamContent
        let decoded = raw
            .replacingOccurrences(of: "&amp;apos;", with: "'")
            .replacingOccurrences(of: "&amp;quot;", with: "\"")
            .replacingOccurrences(of: "&amp;amp;",  with: "&")
            .replacingOccurrences(of: "&amp;lt;",   with: "<")
            .replacingOccurrences(of: "&amp;gt;",   with: ">")
            .replacingOccurrences(of: "&lt;",  with: "<")
            .replacingOccurrences(of: "&gt;",  with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;",  with: "&")

        if let scStart = decoded.range(of: "<r:streamContent>"),
           let scEnd = decoded.range(of: "</r:streamContent>") {
            let content = String(decoded[scStart.upperBound..<scEnd.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            var track = ""
            var artist = ""

            // Format 1: pipe-delimited "TITLE xxx|ARTIST xxx" (iHeart, most stations)
            for part in content.components(separatedBy: "|") {
                if part.hasPrefix("TITLE ") { track = String(part.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                else if part.hasPrefix("ARTIST ") { artist = String(part.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            }

            // Format 2: "Artist - Title" (Soma FM and similar)
            // Only attempt if pipe-delimited parse found nothing
            if track.isEmpty && artist.isEmpty && content.contains(" - ") {
                let parts = content.components(separatedBy: " - ")
                if parts.count >= 2 {
                    artist = parts[0].trimmingCharacters(in: .whitespaces)
                    // Rejoin remaining parts in case track title itself contains " - "
                    track  = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
                }
            }

            if !track.isEmpty { zones[idx].currentTrack = track }
            if !artist.isEmpty { zones[idx].currentArtist = artist }
        }
    }

    // MARK: - Station playback

    func playStation(streamID: Int, on zone: SonosZone) {
        Task {
            print("SORRIVA: Fetching stream URL for station \(streamID)")
            guard let streamURL = await IHeartAPI.fetchStreamURL(streamID: streamID) else {
                print("SORRIVA: Could not resolve stream URL for \(streamID)")
                return
            }
            await ZoneDiscoveryService.playStationURL(streamURL: streamURL, on: zone, stationName: "", artURL: "")
            triggerRefresh()
        }
    }

    func persistStationPlay(zone: SonosZone, stationId: Int, stationName: String, logoURL: String) {
        // Optimistic update — set zone state immediately in memory
        // playingUntil gives a 5-second grace period so fetchTransportStates
        // doesn't immediately override with STOPPED during Sonos startup
        if let idx = zones.firstIndex(where: { $0.id == zone.id }) {
            zones[idx].isPlaying = true
            zones[idx].stationName = stationName
            zones[idx].stationLogoURL = logoURL
            zones[idx].currentTrack = ""
            zones[idx].currentArtist = ""
            zones[idx].isHDMI = false
            zones[idx].playingUntil = Date().addingTimeInterval(5)
        }

        Task {
            do {
                try SorrivaDatabase.shared.upsertStation(
                    id: stationId, source: "iheart",
                    name: stationName, logoURL: logoURL, streamURL: nil
                )
                if !zone.dbDeviceId.isEmpty {
                    try SorrivaDatabase.shared.updateZoneState(
                        deviceId: zone.dbDeviceId,
                        stationId: stationId,
                        stationName: stationName,
                        logoURL: logoURL
                    )
                }
                print("SORRIVA DB: Persisted station play \(stationName) on \(zone.name)")
            } catch {
                print("SORRIVA DB: Station persist error: \(error)")
            }
        }
    }

    nonisolated static func playStationURL(streamURL: String, on zone: SonosZone, stationName: String = "", artURL: String = "") async {
        print("SORRIVA: Playing \(streamURL) on \(zone.name)")
        await setAVTransportURI(host: zone.host, streamURL: streamURL, stationName: stationName, artURL: artURL)
        await sendTransportAction(host: zone.host, action: "Play")
    }

    func triggerRefresh() {
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await fetchTransportStates()
        }
    }

    nonisolated static func setAVTransportURI(host: String, streamURL: String, stationName: String = "", artURL: String = "") async {
        let escapedURL = streamURL.replacingOccurrences(of: "&", with: "&amp;")
        let escapedName = stationName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let escapedArt = artURL
            .replacingOccurrences(of: "&", with: "&amp;")

        // Art element — only include if we have a URL
        let artElement = escapedArt.isEmpty ? "" :
            "&lt;upnp:albumArtURI&gt;\(escapedArt)&lt;/upnp:albumArtURI&gt;"

        let didl = "&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;item id=&quot;-1&quot; parentID=&quot;-1&quot; restricted=&quot;true&quot;&gt;&lt;dc:title&gt;\(escapedName)&lt;/dc:title&gt;\(artElement)&lt;upnp:class&gt;object.item.audioItem.audioBroadcast&lt;/upnp:class&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;"

        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <CurrentURI>\(escapedURL)</CurrentURI>
              <CurrentURIMetaData>\(didl)</CurrentURIMetaData>
            </u:SetAVTransportURI>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/AVTransport/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("SORRIVA: SetAVTransportURI \(host) status=\(status)")
        } catch {
            print("SORRIVA: SetAVTransportURI error: \(error.localizedDescription)")
        }
    }

    /// Overload for local library playback — accepts a pre-built DIDL-Lite metadata string.
    /// Used by LocalPlaybackService which builds musicTrack DIDL rather than audioBroadcast.
    nonisolated static func setAVTransportURIWithMetadata(host: String, streamURL: String, didl: String) async {
        let escapedURL = streamURL.replacingOccurrences(of: "&", with: "&amp;")
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <CurrentURI>\(escapedURL)</CurrentURI>
              <CurrentURIMetaData>\(didl)</CurrentURIMetaData>
            </u:SetAVTransportURI>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/AVTransport/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("SORRIVA: SetAVTransportURIWithMetadata \(host) status=\(status)")
        } catch {
            print("SORRIVA: SetAVTransportURIWithMetadata error: \(error.localizedDescription)")
        }
    }

    // MARK: - Queue management

    nonisolated static func removeAllTracksFromQueue(host: String) async {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:RemoveAllTracksFromQueue xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
            </u:RemoveAllTracksFromQueue>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/AVTransport/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#RemoveAllTracksFromQueue\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("SORRIVA: RemoveAllTracksFromQueue \(host) status=\(status)")
        } catch {
            print("SORRIVA: RemoveAllTracksFromQueue error: \(error.localizedDescription)")
        }
    }

    nonisolated static func addMultipleURIsToQueue(host: String, uris: [String], didls: [String]) async {
        guard !uris.isEmpty else { return }
        // Build comma-separated URI and DIDL lists
        let uriList = uris.map { $0.replacingOccurrences(of: "&", with: "&amp;") }.joined(separator: " ")
        let didlList = didls.joined(separator: " ")
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:AddMultipleURIsToQueue xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <UpdateID>0</UpdateID>
              <NumberOfURIs>\(uris.count)</NumberOfURIs>
              <EnqueuedURIs>\(uriList)</EnqueuedURIs>
              <EnqueuedURIsMetaData>\(didlList)</EnqueuedURIsMetaData>
              <ContainerURI></ContainerURI>
              <ContainerMetaData></ContainerMetaData>
              <DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued>
              <EnqueueAsNext>0</EnqueueAsNext>
            </u:AddMultipleURIsToQueue>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/AVTransport/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#AddMultipleURIsToQueue\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("SORRIVA: AddMultipleURIsToQueue \(host) \(uris.count) tracks status=\(status)")
        } catch {
            print("SORRIVA: AddMultipleURIsToQueue error: \(error.localizedDescription)")
        }
    }

    /// Add a single URI to the Sonos queue — required for x-file-cifs:// URIs
    /// (AddMultipleURIsToQueue rejects x-file-cifs:// with error 402)
    nonisolated static func addURIToQueue(host: String, uri: String, didl: String = "") async {
        let escapedURI = uri.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let body = """
        <u:AddURIToQueue xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
          <InstanceID>0</InstanceID>
          <EnqueuedURI>\(escapedURI)</EnqueuedURI>
          <EnqueuedURIMetaData>\(didl)</EnqueuedURIMetaData>
          <DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued>
          <EnqueueAsNext>0</EnqueueAsNext>
        </u:AddURIToQueue>
        """
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            \(body)
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/AVTransport/Control") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#AddURIToQueue\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = soapBody.data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            sLog("SONOS: AddURIToQueue \(host) status=\(status)")
            if status != 200, let resp = String(data: data, encoding: .utf8) {
                sLog("SONOS: AddURIToQueue error body — \(resp)")
            }
        } catch {
            sLog("SONOS: AddURIToQueue error: \(error.localizedDescription)")
        }
    }

    /// Register a NAS share with Sonos via ContentDirectory CreateObject.
    /// Must be called once per share before x-file-cifs:// URIs will play.
    /// path format: //hostname/share  e.g. //av-server/media/Music II
    nonisolated static func createObject(host: String, nasPath: String) async {
        let encodedPath = nasPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nasPath
        let escapedPath = nasPath
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let didl = "&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;container id=&quot;&quot; parentID=&quot;S:&quot; restricted=&quot;false&quot;&gt;&lt;dc:title&gt;\(escapedPath)&lt;/dc:title&gt;&lt;upnp:class&gt;object.container&lt;/upnp:class&gt;&lt;/container&gt;&lt;/DIDL-Lite&gt;"
        let body = """
        <u:CreateObject xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
          <ContainerID>S:</ContainerID>
          <Elements>\(didl)</Elements>
        </u:CreateObject>
        """
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            \(body)
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaServer/ContentDirectory/Control") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:ContentDirectory:1#CreateObject\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = soapBody.data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            sLog("SONOS: CreateObject \(host) nasPath=\(nasPath) status=\(status)")
            if let resp = String(data: data, encoding: .utf8) {
                sLog("SONOS: CreateObject response — \(resp.prefix(200))")
            }
        } catch {
            sLog("SONOS: CreateObject error: \(error.localizedDescription)")
        }
        _ = encodedPath // suppress unused warning
    }

    // MARK: - Transport control

    func togglePlayPause(zoneID: String) {
        guard let zone = zones.first(where: { $0.id == zoneID }) else { return }
        let isPlaying = zone.isPlaying
        // Optimistic UI
        if let idx = zones.firstIndex(where: { $0.id == zoneID }) {
            zones[idx].isPlaying = !isPlaying
        }
        Task {
            let action = isPlaying ? "Pause" : "Play"
            await ZoneDiscoveryService.sendTransportAction(host: zone.host, action: action)
        }
    }

    func skipNext(zoneID: String) {
        guard let zone = zones.first(where: { $0.id == zoneID }) else { return }
        Task { await ZoneDiscoveryService.sendTransportAction(host: zone.host, action: "Next") }
    }

    func skipPrevious(zoneID: String) {
        guard let zone = zones.first(where: { $0.id == zoneID }) else { return }
        Task { await ZoneDiscoveryService.sendTransportAction(host: zone.host, action: "Previous") }
    }

    nonisolated static func sendTransportAction(host: String, action: String) async {
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
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/AVTransport/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 3

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("SORRIVA: \(action) \(host) status=\(status)")
        } catch {
            print("SORRIVA: \(action) error \(host): \(error.localizedDescription)")
        }
    }

    func setVolume(zoneID: String, volume: Int) {
        guard let zone = zones.first(where: { $0.id == zoneID }) else { return }
        let clamped = max(0, min(100, volume))
        let delta = clamped - zone.volume

        if let idx = zones.firstIndex(where: { $0.id == zoneID }) {
            zones[idx].volume = clamped
            // Apply same delta to all group members
            for memberIdx in zones[idx].groupMembers.indices {
                let newVol = max(0, min(100, zones[idx].groupMembers[memberIdx].volume + delta))
                zones[idx].groupMembers[memberIdx].volume = newVol
                let host = zones[idx].groupMembers[memberIdx].host
                Task { await ZoneDiscoveryService.sendSetVolume(host: host, volume: newVol) }
            }
        }
        Task { await ZoneDiscoveryService.sendSetVolume(host: zone.host, volume: clamped) }
    }

    func muteGroup(zoneID: String, mute: Bool, restoreVolumes: [String: Int] = [:]) {
        guard let zone = zones.first(where: { $0.id == zoneID }) else { return }
        if let idx = zones.firstIndex(where: { $0.id == zoneID }) {
            if mute {
                // Mute all — set coordinator and all members to 0
                zones[idx].volume = 0
                Task { await ZoneDiscoveryService.sendSetVolume(host: zone.host, volume: 0) }
                for memberIdx in zones[idx].groupMembers.indices {
                    zones[idx].groupMembers[memberIdx].volume = 0
                    let host = zones[idx].groupMembers[memberIdx].host
                    Task { await ZoneDiscoveryService.sendSetVolume(host: host, volume: 0) }
                }
            } else {
                // Restore coordinator
                let coordVol = restoreVolumes[zoneID] ?? 15
                zones[idx].volume = coordVol
                Task { await ZoneDiscoveryService.sendSetVolume(host: zone.host, volume: coordVol) }
                // Restore members
                for memberIdx in zones[idx].groupMembers.indices {
                    let memberId = zones[idx].groupMembers[memberIdx].id
                    let memberVol = restoreVolumes[memberId] ?? 15
                    zones[idx].groupMembers[memberIdx].volume = memberVol
                    let host = zones[idx].groupMembers[memberIdx].host
                    Task { await ZoneDiscoveryService.sendSetVolume(host: host, volume: memberVol) }
                }
            }
        }
    }

    func groupZone(coordinatorID: String, addZoneIDs: [String], removeZoneIDs: [String]) {
        guard let coordinator = zones.first(where: { $0.id == coordinatorID }) else { return }
        print("SORRIVA: groupZone — coordinator: \(coordinator.name) (\(coordinatorID))")
        print("SORRIVA: groupZone — adding: \(addZoneIDs)")
        print("SORRIVA: groupZone — removing: \(removeZoneIDs)")

        // Capture host data synchronously before async Task — zones may change during execution
        var addHostMap: [String: String] = [:]  // id → host
        for id in addZoneIDs {
            if let zone = zones.first(where: { $0.id == id }) {
                addHostMap[id] = zone.host
            } else {
                // Check if it's a member of another group
                for z in zones {
                    if let member = z.groupMembers.first(where: { $0.id == id }) {
                        addHostMap[id] = member.host
                        break
                    }
                }
            }
        }
        var removeHostMap: [String: String] = [:]
        for id in removeZoneIDs {
            if let zone = zones.first(where: { $0.id == id }) {
                removeHostMap[id] = zone.host
            } else {
                for z in zones {
                    if let member = z.groupMembers.first(where: { $0.id == id }) {
                        removeHostMap[id] = member.host
                        break
                    }
                }
            }
        }
        let coordinatorHost = coordinator.host
        let coordinatorName = coordinator.name

        print("SORRIVA: groupZone — host map: \(addHostMap)")

        Task {
            // Remove zones from this group
            for id in removeZoneIDs {
                if let host = removeHostMap[id] {
                    await ZoneDiscoveryService.becomeCoordinator(host: host)
                    print("SORRIVA: Removed zone \(id) from group")
                }
            }

            // Add new zones to this group
            for id in addZoneIDs {
                if let memberHost = addHostMap[id] {
                    await ZoneDiscoveryService.addMember(
                        coordinatorHost: coordinatorHost,
                        memberHost: memberHost,
                        memberUUID: coordinatorID
                    )
                    print("SORRIVA: Added zone \(id) (\(memberHost)) to \(coordinatorName)")
                } else {
                    print("SORRIVA: Could not find host for zone \(id)")
                }
            }

            // Refresh after grouping — lightweight, no zone array replacement
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await fetchTransportStates()
            if let host = zones.first?.host {
                await refreshIdleStates(host: host)
            }
            // Full topology refresh to get updated group members
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let host = zones.first?.host {
                await fetchTopology(host: host)
            }
        }
    }

    private static func addMember(coordinatorHost: String, memberHost: String, memberUUID: String) async {
        // SetAVTransportURI with x-rincon: (single colon) sent to MEMBER's host
        // x-rincon:RINCON_XXXX tells the member to join the coordinator's group
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
        guard let url = URL(string: "http://\(memberHost):1400/MediaRenderer/AVTransport/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("SORRIVA: AddMember \(memberHost) → \(memberUUID) status=\(status)")
        } catch {
            print("SORRIVA: AddMember error: \(error.localizedDescription)")
        }
    }

    func ungroupZone(zoneID: String) {
        guard let zone = zones.first(where: { $0.id == zoneID }),
              !zone.groupMembers.isEmpty else { return }

        // Send each member to standalone — dissolves playback group
        // Hardware bonds (stereo pairs, Arc+Sub) are not affected
        for member in zone.groupMembers {
            let host = member.host
            Task {
                await ZoneDiscoveryService.becomeCoordinator(host: host)
                print("SORRIVA: Ungrouped \(member.name) from \(zone.name)")
            }
        }

        // Optimistic update — clear members immediately
        if let idx = zones.firstIndex(where: { $0.id == zoneID }) {
            zones[idx].groupMembers = []
        }

        // Refresh topology after short delay to get new zone list
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let host = zones.first?.host {
                await fetchTopology(host: host)
            }
        }
    }

    /// Transfer playback from one zone to another.
    /// 1. Destination joins source group (audio syncs)
    /// 2. Source pauses
    /// 3. Source goes standalone via BecomeCoordinatorOfStandaloneGroup
    /// Destination continues playing as standalone coordinator.
    func transferPlayback(fromZoneID: String, toZoneID: String) {
        guard let sourceZone = zones.first(where: { $0.id == fromZoneID }),
              let destZone = zones.first(where: { $0.id == toZoneID }) else { return }

        let sourceHost = sourceZone.host
        let destHost = destZone.host
        let sourceID = fromZoneID

        print("SORRIVA: transferPlayback — \(sourceZone.name) → \(destZone.name)")

        Task {
            // Step 1: destination joins source group — audio syncs
            await ZoneDiscoveryService.addMember(
                coordinatorHost: sourceHost,
                memberHost: destHost,
                memberUUID: sourceID
            )
            print("SORRIVA: Transfer step 1 — \(destZone.name) joined \(sourceZone.name)")

            // Step 2: wait for audio to sync on destination
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // Step 3: source goes standalone — destination automatically becomes
            // the new coordinator and inherits the queue
            await ZoneDiscoveryService.becomeCoordinator(host: sourceHost)
            print("SORRIVA: Transfer step 2 — \(sourceZone.name) released, \(destZone.name) is new coordinator")

            // Refresh topology
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let host = zones.first?.host {
                await fetchTopology(host: host)
            }
        }
    }

    private static func becomeCoordinator(host: String) async {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:BecomeCoordinatorOfStandaloneGroup xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
            </u:BecomeCoordinatorOfStandaloneGroup>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/AVTransport/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#BecomeCoordinatorOfStandaloneGroup\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("SORRIVA: BecomeCoordinator \(host) status=\(status)")
        } catch {
            print("SORRIVA: BecomeCoordinator error: \(error.localizedDescription)")
        }
    }

    func setMemberVolume(zoneID: String, memberID: String, volume: Int) {
        let clamped = max(0, min(100, volume))

        // Coordinator case — set directly without delta
        if memberID == zoneID {
            if let idx = zones.firstIndex(where: { $0.id == zoneID }) {
                zones[idx].volume = clamped
                let host = zones[idx].host
                Task { await ZoneDiscoveryService.sendSetVolume(host: host, volume: clamped) }
            }
            return
        }

        // Member case
        guard let zoneIdx = zones.firstIndex(where: { $0.id == zoneID }),
              let memberIdx = zones[zoneIdx].groupMembers.firstIndex(where: { $0.id == memberID })
        else { return }
        let host = zones[zoneIdx].groupMembers[memberIdx].host
        zones[zoneIdx].groupMembers[memberIdx].volume = clamped
        Task { await ZoneDiscoveryService.sendSetVolume(host: host, volume: clamped) }
    }

    private static func sendSetVolume(host: String, volume: Int) async {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
              <InstanceID>0</InstanceID>
              <Channel>Master</Channel>
              <DesiredVolume>\(volume)</DesiredVolume>
            </u:SetVolume>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/RenderingControl/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:RenderingControl:1#SetVolume\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 3

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("SORRIVA: SetVolume \(host) → \(volume) status=\(status)")
        } catch {
            print("SORRIVA: SetVolume error \(host): \(error.localizedDescription)")
        }
    }

    private static func volumeInfo(host: String) async -> Int {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
              <InstanceID>0</InstanceID>
              <Channel>Master</Channel>
            </u:GetVolume>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/RenderingControl/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return 0 }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:RenderingControl:1#GetVolume\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 3

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let raw = String(data: data, encoding: .utf8) ?? ""
            // Extract <CurrentVolume>42</CurrentVolume>
            if let start = raw.range(of: "<CurrentVolume>"),
               let end = raw.range(of: "</CurrentVolume>") {
                let volStr = String(raw[start.upperBound..<end.lowerBound])
                let vol = Int(volStr) ?? 0
                print("SORRIVA: Volume \(host) → \(vol)")
                return vol
            }
        } catch {
            print("SORRIVA: GetVolume error \(host): \(error.localizedDescription)")
        }
        return 0
    }

    private static func transportInfo(host: String) async -> Bool {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
            </u:GetTransportInfo>
          </s:Body>
        </s:Envelope>
        """

        guard let url = URL(string: "http://\(host):1400/MediaRenderer/AVTransport/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#GetTransportInfo\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 3

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let raw = String(data: data, encoding: .utf8) ?? ""
            let isPlaying = raw.contains("PLAYING") || raw.contains("TRANSITIONING")
            print("SORRIVA: Transport \(host) → \(isPlaying ? "PLAYING" : "STOPPED")")
            return isPlaying
        } catch {
            print("SORRIVA: Transport fetch error \(host): \(error.localizedDescription)")
            return false
        }
    }

    private func parseTopology(data: Data) -> [SonosZone]? {
        // The ZoneGroupState value is HTML-entity-encoded XML inside the SOAP response.
        // Extract the inner XML string, decode entities, then parse as XML.
        guard let raw = String(data: data, encoding: .utf8) else { return nil }

        // Extract content between <ZoneGroupState> and </ZoneGroupState>
        guard let start = raw.range(of: "<ZoneGroupState>"),
              let end = raw.range(of: "</ZoneGroupState>") else { return nil }

        let encoded = String(raw[start.upperBound..<end.lowerBound])

        // Decode HTML entities
        let decoded = encoded
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&apos;", with: "'")

        let wrappedXML = "<ZoneGroupState>\(decoded)</ZoneGroupState>"
        guard let xmlData = wrappedXML.data(using: .utf8) else { return nil }

        let parser = TopologyParser(data: xmlData)
        return parser.parse()
    }

    // MARK: - Address helpers

    private func ipv4String(from data: Data) -> String? {
        data.withUnsafeBytes { ptr -> String? in
            guard let sa = ptr.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                  sa.pointee.sa_family == UInt8(AF_INET) else { return nil }
            let sin = ptr.baseAddress!.assumingMemoryBound(to: sockaddr_in.self)
            var addr = sin.pointee.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buf)
        }
    }
}

// MARK: - NetServiceBrowserDelegate

extension ZoneDiscoveryService: NetServiceBrowserDelegate {

    nonisolated func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        print("SORRIVA: Browser searching...")
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        print("SORRIVA: Found: \(service.name)")
        service.delegate = self
        service.resolve(withTimeout: 5.0)
        Task { @MainActor in self.pendingServices.append(service) }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        print("SORRIVA: Browser error: \(errorDict)")
        Task { @MainActor in
            self.discoveryError = "Network search failed"
            self.isDiscovering = false
        }
    }
}

// MARK: - NetServiceDelegate

extension ZoneDiscoveryService: NetServiceDelegate {

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        print("SORRIVA: Resolved: \(sender.name)")
        Task { @MainActor in
            self.serviceResolved(sender)
            self.pendingServices.removeAll { $0 === sender }
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        print("SORRIVA: Did not resolve \(sender.name): \(errorDict)")
        Task { @MainActor in
            self.pendingServices.removeAll { $0 === sender }
        }
    }
}

// MARK: - SonosGroupMember

struct SonosGroupMember: Equatable {
    let id: String
    let name: String
    let host: String
    var volume: Int = 0
}

// MARK: - SonosZone
// A display-ready zone — coordinator only, satellites filtered out.

struct SonosZone: Identifiable, Equatable {
    static func == (lhs: SonosZone, rhs: SonosZone) -> Bool {
        lhs.id == rhs.id &&
        lhs.isPlaying == rhs.isPlaying &&
        lhs.volume == rhs.volume &&
        lhs.currentTrack == rhs.currentTrack &&
        lhs.currentArtist == rhs.currentArtist &&
        lhs.stationName == rhs.stationName &&
        lhs.stationLogoURL == rhs.stationLogoURL &&
        lhs.isHDMI == rhs.isHDMI &&
        lhs.currentTrackURI == rhs.currentTrackURI &&
        lhs.elapsedSeconds == rhs.elapsedSeconds &&
        lhs.durationSeconds == rhs.durationSeconds &&
        lhs.idleState == rhs.idleState &&
        lhs.capabilities == rhs.capabilities &&
        lhs.groupMembers == rhs.groupMembers
        // playingUntil intentionally excluded — internal timing state, not display state
    }
    let id: String          // RINCON UUID of coordinator
    let name: String        // Zone name e.g. "Living Room"
    let host: String        // IPv4 address of coordinator
    var isPlaying: Bool     // Transport state
    var volume: Int         // 0-100
    var stationName: String = ""
    var stationLogoURL: String = ""
    var currentTrack: String = ""
    var currentArtist: String = ""
    var isHDMI: Bool = false        // TV/HDMI source — Arc/Beam specific
    var currentTrackURI: String = ""   // x-file-cifs URI — used by PlaybackContextService to advance local context
    var elapsedSeconds: Int = 0        // Playback position from GetPositionInfo
    var durationSeconds: Int = 0       // Track duration from GetPositionInfo — 0 for streams
    var idleState: Bool = false     // IdleState from topology — true = idle even if transport says PLAYING
    var capabilities: [String] = ["eq", "volume", "mute"]  // Loaded from DB devices table
    var dbDeviceId: String = ""     // Sorriva UUID from devices table
    var playingUntil: Date? = nil   // Grace period — ignore transport STOPPED within 5s of station play
    var groupMembers: [SonosGroupMember] = [] // Non-coordinator zones in this playback group

    // Shim adapters for ZonesView compatibility
    var asDevice: SonosDevice {
        SonosDevice(id: id, name: name, host: host, port: 1400,
                    groupCoordinatorID: nil, transportState: isPlaying ? .playing : .stopped)
    }

    var asGroup: SonosGroup {
        SonosGroup(coordinatorID: id, members: [asDevice])
    }
}

// MARK: - TopologyParser
// Parses the decoded ZoneGroupState XML into SonosZone objects.
// Rules:
//   ZoneGroup[@Coordinator] = one user-visible zone
//   ZoneGroupMember[@Invisible="1"] = satellite, skip
//   Satellite elements = bonded sub/surround speakers, always skip
//   The coordinator ZoneGroupMember (UUID == Coordinator attr) = the zone

private class TopologyParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var zones: [SonosZone] = []

    // Parsing state
    private var currentCoordinatorID: String = ""
    private var currentMembers: [(uuid: String, name: String, host: String, invisible: Bool, idleState: Bool)] = []
    private var inSatellite = false

    init(data: Data) { self.data = data }

    func parse() -> [SonosZone] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return zones
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {

        switch elementName {

        case "ZoneGroup":
            currentCoordinatorID = attributes["Coordinator"] ?? ""
            currentMembers = []
            inSatellite = false

        case "ZoneGroupMember":
            guard !inSatellite else { return }
            let uuid = attributes["UUID"] ?? ""
            let name = attributes["ZoneName"] ?? ""
            let location = attributes["Location"] ?? ""
            let invisible = attributes["Invisible"] == "1"
            let idleState = attributes["IdleState"] == "1"

            // Extract IP from Location URL e.g. http://192.168.1.149:1400/xml/device_description.xml
            let host = URL(string: location)?.host ?? ""

            currentMembers.append((uuid: uuid, name: name, host: host, invisible: invisible, idleState: idleState))

        case "Satellite":
            inSatellite = true  // Everything inside Satellite is a bonded speaker — skip

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "Satellite":
            inSatellite = false
        case "ZoneGroup":
            // Find the coordinator member — it's the zone
            if let coordinator = currentMembers.first(where: {
                $0.uuid == currentCoordinatorID && !$0.invisible
            }) {
                var zone = SonosZone(
                    id: coordinator.uuid,
                    name: coordinator.name,
                    host: coordinator.host,
                    isPlaying: false,
                    volume: 0
                )
                zone.idleState = coordinator.idleState
                // Store non-coordinator, non-invisible members with full data
                zone.groupMembers = currentMembers
                    .filter { $0.uuid != currentCoordinatorID && !$0.invisible }
                    .map { SonosGroupMember(id: $0.uuid, name: $0.name, host: $0.host) }
                zones.append(zone)
            }
            currentCoordinatorID = ""
            currentMembers = []
            inSatellite = false
        default:
            break
        }
    }
}
