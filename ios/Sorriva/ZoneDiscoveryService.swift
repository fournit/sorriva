import Foundation
import Network
import Combine
import SystemConfiguration

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

    // MARK: - Topology refresh coordinator
    // Every caller that needs a fresh topology (group, ungroup, transfer,
    // foreground/network-restored, initial discovery) goes through
    // requestTopologyRefresh(host:) rather than calling fetchTopology directly.
    // Without this, independent unguarded calls could overlap — network
    // responses aren't guaranteed to arrive in request order, so a stale
    // fetch completing after a newer one would silently overwrite correct
    // group state with wrong data. At most one fetchTopology call is ever
    // in flight; any requests that arrive while one is running coalesce
    // into a single guaranteed follow-up rather than piling up.
    private var topologyFetchInFlight = false
    private var topologyRefreshPending = false
    private var pendingTopologyHost: String?

    // WP-14: Candidate host pool for topology failover (S-008)
    private var candidateHosts: [String] = []
    private var candidateIndex: Int = 0
    private var pathMonitor: NWPathMonitor?
    private var lastTopologyHost: String? = nil
    private var topologyLastFetched: Date? = nil

    // MARK: - Discovery lifecycle guards
    // The network monitor and the notification observers are OBJECT-lifetime
    // concerns, not per-discovery concerns. They were previously created inside
    // startDiscovery(), which produced two defects:
    //
    //   1. NWPathMonitor invokes pathUpdateHandler immediately on start() with
    //      the current path — not only on change. On a device with no cached
    //      zones that gave startDiscovery -> monitor.start -> "satisfied"
    //      callback -> handleNetworkRestored -> stopDiscovery (clears the
    //      serviceBrowser guard) -> startDiscovery, with nothing able to break
    //      the cycle. Observed at ~400 iterations/sec on first iPad launch.
    //   2. Both observers were re-registered on every startDiscovery() call and
    //      never removed, so each restart leaked two more live observers.
    //
    // Both are now established once in init().
    private var observersRegistered = false
    private var lastPathSatisfied: Bool? = nil
    private var lastDiscoveryRestart: Date? = nil
    private let discoveryRestartFloor: TimeInterval = 10.0

    // Household ID attached to whatever topology was restored from cache this
    // launch, if any. Validated against the live household once real topology
    // arrives — see fetchTopology.
    private var cachedHouseholdId: String? = nil

    // B-001: Volume command debounce — suppress poll overwrites for 3s after command
    private var volumeCommandTimes: [String: Date] = [:]  // zoneID → last command time
    private let volumeDebounceInterval: TimeInterval = 3.0

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

    // MARK: - Lifecycle

    override init() {
        super.init()
        startNetworkMonitor()
        registerObservers()
    }

    // MARK: - Public interface

    func startDiscovery() {
        guard serviceBrowser == nil else { return }
        sLog("ZONES: startDiscovery — looking for Sonos speakers")
        isDiscovering = true
        discoveryError = nil
        topologyFetched = false
        candidateHosts = []
        candidateIndex = 0

        // Restore cached zones immediately — gives instant UI while Bonjour runs in background
        if zones.isEmpty {
            restoreZonesFromCache()
        }

        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: "_sonos._tcp", inDomain: "local.")
        self.serviceBrowser = browser
    }

    /// Registered exactly once, from init. Never from startDiscovery — see the
    /// discovery lifecycle guards above.
    private func registerObservers() {
        guard !observersRegistered else { return }
        observersRegistered = true

        // Subscribe to playback grace notification from LocalPlaybackService
        NotificationCenter.default.addObserver(
            forName: .sorrivaSetPlaybackGrace,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let zoneID = notification.userInfo?["zoneID"] as? String else { return }
            Task { @MainActor in self.setPlaybackGrace(zoneID: zoneID) }
        }

        // WP-14: Subscribe to foreground notification for topology refresh
        NotificationCenter.default.addObserver(
            forName: .sorrivaAppDidBecomeActive,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Use handleNetworkRestored which correctly distinguishes
                // empty zones (full restart) from known zones (lightweight refresh)
                self.handleNetworkRestored()
            }
        }
    }

    /// Started once from init and left running for the lifetime of the service.
    /// stopDiscovery() must NOT cancel it — tearing the monitor down and
    /// rebuilding it is precisely what created the restart loop.
    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = (path.status == .satisfied)
            Task { @MainActor in
                defer { self.lastPathSatisfied = satisfied }

                // Only a TRANSITION into .satisfied is a network-restored event.
                // NWPathMonitor fires this handler on start() and on unrelated
                // path changes (interface reshuffles, DNS updates) while the
                // status stays .satisfied throughout. Treating every satisfied
                // callback as "restored" is what let this feed back into
                // startDiscovery in an unbounded loop.
                guard satisfied else {
                    if self.lastPathSatisfied == true {
                        sLog("ZONES: Network lost")
                    }
                    return
                }
                guard self.lastPathSatisfied != true else { return }
                sLog("ZONES: Network became reachable — triggering rediscovery")
                self.handleNetworkRestored()
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .background))
        pathMonitor = monitor
    }

    private func handleNetworkRestored() {
        // Always clear any stale error on foreground
        discoveryError = nil
        if zones.isEmpty {
            // Restart floor. Belt-and-braces against any future caller that
            // fires repeatedly: if a browser is already running and we tore it
            // down less than discoveryRestartFloor ago, leave it alone and let
            // Bonjour finish. A restart when discovery is NOT running is always
            // allowed, so this can never wedge discovery shut.
            if serviceBrowser != nil,
               let last = lastDiscoveryRestart,
               Date().timeIntervalSince(last) < discoveryRestartFloor {
                sLog("ZONES: restart suppressed — discovery already running (floor \(Int(discoveryRestartFloor))s)")
                return
            }
            lastDiscoveryRestart = Date()
            sLog("ZONES: no zones — restarting discovery")
            stopDiscovery()
            startDiscovery()
        } else {
            // Zones exist — restart polling only. Do NOT re-fetch topology.
            // fetchTopology would replace zones[] and risk clearing them on timeout.
            // The polling loop will update transport state (playing/paused/volume).
            sLog("ZONES: foreground with \(zones.count) zones — restarting poll")
            startPolling()
        }
    }

    func stopDiscovery() {
        // NOTE: pathMonitor is deliberately NOT cancelled here. It is owned by
        // the service lifetime, not by a discovery pass. Cancelling and
        // recreating it per pass is what produced the discovery restart loop.
        serviceBrowser?.stop()
        serviceBrowser = nil
        pendingServices.forEach { $0.stop() }
        pendingServices = []
        refreshTask?.cancel()
        refreshTask = nil
        isDiscovering = false
        topologyFetched = false
        candidateHosts = []
        candidateIndex = 0
    }

    func refresh() {
        guard let anyZone = zones.first else {
            // No zones yet — restart discovery
            stopDiscovery()
            startDiscovery()
            return
        }
        requestTopologyRefresh(host: anyZone.host)
    }

    // MARK: - Private

    fileprivate func serviceResolved(_ service: NetService) {
        // Extract IPv4 address
        guard let addresses = service.addresses else { return }
        var host: String? = nil
        for data in addresses {
            if let ip = ipv4String(from: data) { host = ip; break }
        }
        guard let host else {
            sLog("ZONES: Could not extract IPv4 from \(service.name)")
            return
        }

        // WP-14: Collect all candidates for failover pool
        if !candidateHosts.contains(host) {
            candidateHosts.append(host)
            sLog("ZONES: Candidate speaker at \(host) (\(candidateHosts.count) total)")
        }

        // Only fetch topology once — from the first resolved speaker
        guard !topologyFetched else { return }
        topologyFetched = true

        sLog("ZONES: Fetching topology from \(host)")
        requestTopologyRefresh(host: host)
    }

    /// Single entry point for requesting a topology refresh. If a fetch is
    /// already in flight, this request coalesces into a guaranteed follow-up
    /// rather than firing a concurrent, racing duplicate. See the property
    /// declarations above for why this exists.
    private func requestTopologyRefresh(host: String) {
        pendingTopologyHost = host
        if topologyFetchInFlight {
            topologyRefreshPending = true
            return
        }
        Task { await runTopologyRefreshLoop() }
    }

    private func runTopologyRefreshLoop() async {
        topologyFetchInFlight = true
        defer { topologyFetchInFlight = false }
        repeat {
            topologyRefreshPending = false
            guard let host = pendingTopologyHost else { break }
            // fetchTopology handles its own host failover internally
            // (tryNextCandidate) — that's a single atomic unit of work from
            // this coordinator's point of view, success or failure.
            await fetchTopology(host: host)
        } while topologyRefreshPending
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
            sLog("ZONES: Topology response status=\(status) bytes=\(data.count)")

            if let parsed = parseTopology(data: data) {
                // Merge rather than replace: TopologyParser only knows
                // id/name/host/idleState/groupMembers, so a wholesale replace resets
                // every other field — track, position, volume, HDMI — to bare defaults
                // on every topology fetch. Invisible on an idle zone; it visibly blanks
                // an actively-playing coordinator until fetchTransportStates catches up.
                //
                // This used to be an inline copy of mergeTopology. Two copies of one
                // rule is how the alphabetical-sort invariant got lost on 2026-08-08 —
                // it was restated at each assignment site instead of living in one
                // place. The shared version is also strictly better: it carries forward
                // isHDMI and capabilities, which this copy dropped (so a topology
                // refresh silently cleared the TV flag), and it tolerates a duplicate
                // zone id rather than trapping on it the way uniqueKeysWithValues does.
                zones = ZoneDiscoveryService.mergeTopology(parsed: parsed, into: zones)
                lastTopologyHost = host
                topologyLastFetched = Date()
                sLog("ZONES: Parsed \(zones.count) zones: \(zones.map(\.name).joined(separator: ", "))")

                // Household ID is only knowable once we've reached a real
                // speaker, so the cache write happens AFTER this — not before.
                let liveHouseholdId = await syncTopologyToDB(host: host)

                // Validate anything restored from cache earlier this launch.
                // The network key can collide across locations; the household
                // ID is what actually proves it's the same Sonos system.
                if let cached = cachedHouseholdId,
                   let live = liveHouseholdId,
                   cached != live {
                    discardCachedTopology(reason: "household changed (\(cached) → \(live))")
                }

                // Cache zone topology for instant restore on next launch
                saveZonesToCache(householdId: liveHouseholdId)
                await fetchTransportStates()
                startPolling()
            } else {
                sLog("ZONES: Failed to parse topology from \(host) — trying next candidate")
                await tryNextCandidate(failedHost: host)
            }
        } catch {
            sLog("ZONES: Topology fetch error from \(host): \(error.localizedDescription)")
            // Only surface error to UI if we have no zones — transient failures
            // after foreground shouldn't clear a working zone list
            if zones.isEmpty {
                discoveryError = error.localizedDescription
            }
            await tryNextCandidate(failedHost: host)
        }

        isDiscovering = false
    }

    /// WP-14 S-008: Try next candidate host when current one fails.
    private func tryNextCandidate(failedHost: String) async {
        let nextCandidates = candidateHosts.filter { $0 != failedHost }
        if let next = nextCandidates.first {
            sLog("ZONES: Failing over to candidate \(next)")
            await fetchTopology(host: next)
        } else {
            // No more candidates — restart Bonjour in 5 seconds
            sLog("ZONES: No candidates left — restarting Bonjour in 5s")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            topologyFetched = false
            candidateHosts = []
            candidateIndex = 0
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: "_sonos._tcp", inDomain: "local.")
            self.serviceBrowser = browser
        }
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

                // Transport optimism is no longer applied here. PlaybackStore owns it:
                // it holds the intent and the reducer decides what a zone DISPLAYS, so
                // this field can simply report what Sonos said. Keeping a second copy of
                // that judgement in the poll path is what let the two drift — the windows
                // had already diverged to 5s in one call site and 6s in five others.
                let finalPlaying = effectivePlaying

                let wasPlaying = zones[idx].isPlaying


                // Detect idle → playing transition for GetMediaInfo fetch
                if finalPlaying && !wasPlaying {
                    newlyPlayingZones.append(zones[idx])
                }

                zones[idx].isPlaying = finalPlaying
                // B-001: Skip volume update from poll if a command was issued recently
                let zid = zones[idx].id
                let isDebouncing = volumeCommandTimes[zid].map {
                    Date().timeIntervalSince($0) < volumeDebounceInterval
                } ?? false
                if !isDebouncing {
                    zones[idx].volume = vol
                } else {
                    sLog("ZONES: volume debounce active for \(zones[idx].name) — skipping poll update (cmd age: \(String(format: "%.1f", volumeCommandTimes[zid].map { Date().timeIntervalSince($0) } ?? -1))s)")
                }

                // Clear stale track info when a zone stops — but not while one of our own
                // commands is still settling, or a transient STOPPED mid-command would wipe
                // the track the zone is about to resume. Same question as before, now asked
                // of the store rather than of a duplicate field on the zone.
                //
                // isHDMI is deliberately NOT cleared here. It says which INPUT is selected;
                // isPlaying says whether sound is coming out. Clearing the first because of
                // the second made the Living Room card flicker between the TV icon and the
                // last station for the whole time a TV took to warm up — HDMI negotiated
                // but no audio yet, so every poll landing on "not playing" wiped the input,
                // the reducer fell through to the last station, and the next poll put it
                // back. Reported from the room 2026-08-08.
                //
                // The clear was redundant as well as wrong: the only legitimate way to
                // leave the TV input is for the URI to stop being an htastream URI, and
                // updateZoneFromPositionInfo already owns that in both directions.
                if !finalPlaying && !PlaybackStore.shared.hasFreshTransportIntent(zoneID: id) {
                    zones[idx].currentTrack = ""
                    zones[idx].currentArtist = ""
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

        // Fetch GetPositionInfo for ALL zones — playing AND idle
        // Idle zones need URI resolution to show last loaded content on launch
        let positionResults: [(String, Data)] = await withTaskGroup(of: (String, Data?).self) { group in
            for zone in zones {
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

        // A GetMediaInfo call per newly-playing zone used to happen here, purely to copy
        // Sonos's station name and art into the zone. Both are removed: the name is
        // `dc:title`, which is a filename for iHeart and a slug for SomaFM, and the art is
        // usually absent for radio. The stations table has the real values and the store
        // resolves them from the URI, so the round trip bought nothing and its result had
        // to be defended against downstream. Polling now reports transport only.
    }

    nonisolated static func parseTimeStringPublic(_ s: String) -> Int {
        SonosTopology.parseTimeString(s)
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

        let rawTitle: String? = {
            guard let start = decoded.range(of: "<dc:title>"),
                  let end = decoded.range(of: "</dc:title>") else { return nil }
            return String(decoded[start.upperBound..<end.lowerBound])
        }()
        let rawArt: String? = {
            guard let start = decoded.range(of: "<upnp:albumArtURI>"),
                  let end = decoded.range(of: "</upnp:albumArtURI>") else { return nil }
            return String(decoded[start.upperBound..<end.lowerBound])
        }()

        let resolved = StationMetadataResolver.resolve(rawTitle: rawTitle, rawArtPath: rawArt, zoneHost: host)
        guard let stationName = resolved.name else {
            print("SORRIVA: GetMediaInfo — no valid station name for \(host)")
            return nil
        }
        let artURL = resolved.artURL ?? ""
        return (name: stationName, artURL: artURL)
    }

    /// Returns the live Sonos household ID, or nil if the speaker did not
    /// report one. Callers use it to validate cached topology.
    @discardableResult
    private func syncTopologyToDB(host: String) async -> String? {
        print("SORRIVA DB: syncTopologyToDB starting, host=\(host), zones=\(zones.count)")
        // Get household ID from ZoneGroupAttributes
        let liveHouseholdId = await fetchHouseholdID(host: host)
        let hhid = liveHouseholdId ?? "unknown"
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
        return liveHouseholdId
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

    // restoreZoneStateFromDB was removed here. It read each zone's last Sorriva-played
    // station out of zone_state, wrote it into the zone, and stamped stationNameURI with
    // whatever URI the zone currently reported — forging the very freshness check that is
    // supposed to prove a name was resolved for the content in hand. That is how a zone
    // reverted to "last playing minus one" after a transfer, and it ran on every topology
    // refresh, not just at launch. PlaybackStore.restoreLastPlaying now does this job
    // properly: URI-bound, marked .external so it cannot outrank live state.
    //
    // It also pre-warmed the station logo into URLCache. That is worth reinstating from
    // the store's resolved art URLs if first-paint artwork feels slower.

    // fetchAllStationMetadata was removed here. It issued a GetMediaInfo call per zone on
    // every topology refresh solely to copy Sonos's dc:title and art into the zone — a
    // filename for iHeart, a slug for SomaFM, and usually no art at all for radio. The
    // stations table holds the real values and the store resolves them from the URI, so
    // this was a SOAP round trip per zone in exchange for data that had to be defended
    // against downstream.

    private func startPolling() {
        refreshTask?.cancel()
        var pollCount = 0
        var consecutiveFailures = 0
        refreshTask = Task {
            while !Task.isCancelled {
                let hasPlaying = zones.contains { $0.isPlaying && !$0.idleState }
                let backingOff = consecutiveFailures >= 3
                let intervalNs: UInt64 = backingOff ? 15_000_000_000
                                       : hasPlaying  ?  2_000_000_000
                                       :                 5_000_000_000
                try? await Task.sleep(nanoseconds: intervalNs)
                guard !Task.isCancelled else { break }
                await fetchTransportStates()
                if zones.isEmpty { consecutiveFailures += 1 } else { consecutiveFailures = 0 }
                pollCount += 1
                // Lightweight IdleState refresh every 15s
                if pollCount >= 3 {
                    pollCount = 0
                    if let anyHost = zones.first?.host {
                        await refreshZoneGroupState(host: anyHost)
                    }
                }
            }
        }
    }

    /// Merge a freshly parsed topology into the live zones, preserving transport state.
    ///
    /// The rules — which fields topology owns, which the transport poll owns, and why the
    /// result is alphabetically sorted — moved to SonosTopology.merge on 2026-08-08 and
    /// are documented there. This is the name the service's own call sites use.
    static func mergeTopology(parsed: [SonosZone], into existing: [SonosZone]) -> [SonosZone] {
        SonosTopology.merge(parsed: parsed, into: existing)
    }

    /// Refresh zone structure AND idle state from ZoneGroupTopology.
    ///
    /// Renamed from refreshIdleStates on 2026-08-08. It always fetched the entire
    /// household topology and kept only IdleState, throwing the group structure away —
    /// so a group change made from the Sonos app, a voice command or TV autoplay was
    /// invisible until relaunch (bGroupChangesMadeOutsideSorrivaAreNeverSeen). The name
    /// described the one field it kept rather than what it asked for, which is most of
    /// why the gap went unnoticed.
    private func refreshZoneGroupState(host: String) async {
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
              let parsed = parseTopology(data: data) else { return }

        // The same parser fetchTopology uses. The bespoke IdleState regex that used to
        // sit here read one attribute out of a payload that describes the whole
        // household, which is how group changes stayed invisible.
        let merged = ZoneDiscoveryService.mergeTopology(parsed: parsed, into: zones)
        if merged != zones {
            let before = Set(zones.map(\.id)), after = Set(merged.map(\.id))
            if before != after {
                sLog("ZONES: group structure changed — \(zones.count) zones -> \(merged.count)")
            }
            zones = merged
        }
    }

    // MARK: - Live station metadata (iHeart)
    // When a zone is playing an iHeart stream, we extract the stream ID from the HLS URL
    // and cache it. When the zone is paused, we poll iHeart every 15s for current on-air
    // track and station art — giving users "what's on now" even when paused.

    // Called from fetchTransportStates when we get UPnP position info for a playing zone
    /// Finds the zone and applies a GetPositionInfo response to it. The parsing moved to
    /// SonosTopology.applyPositionInfo on 2026-08-08 — pure, and tested without a speaker.
    /// What stays here is the part that genuinely needs the service: the lookup and the
    /// write-back into `zones`.
    func updateZoneFromPositionInfo(zoneID: String, positionData: Data) {
        guard let idx = zones.firstIndex(where: { $0.id == zoneID }) else { return }

        // B-001: Only update volume from poll if no recent volume command.
        //
        // COMPUTED AND NEVER READ. Left exactly as found when the parsing moved out,
        // because deleting it would erase the evidence of whether the guard is missing
        // or is merely leftover from when volume was written here. Logged as
        // bVolumeDebounceGuardUnused — decide it there, with a test, not in passing.
        let volumeIsDebouncing = volumeCommandTimes[zoneID].map {
            Date().timeIntervalSince($0) < volumeDebounceInterval
        } ?? false
        _ = volumeIsDebouncing

        zones[idx] = SonosTopology.applyPositionInfo(to: zones[idx], data: positionData)
    }


    // MARK: - Station playback

    func playStation(streamID: Int, on zone: SonosZone) {
        // Same protection as persistStationPlay/setPlaybackGrace/togglePlayPause —
        // clear stale IdleState immediately and set a grace period so the UI doesn't
        // report a false "stopped" while topology catches up on this zone's first play.
        if let idx = zones.firstIndex(where: { $0.id == zone.id }) {
            zones[idx].idleState = false
            PlaybackStore.shared.declareTransport(zoneID: zone.id, playing: true)
        }
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

    func persistStationPlay(zone: SonosZone, stationId: Int, stationName: String, logoURL: String, streamURL: String) {
        // Optimistic update — set zone state immediately in memory
        // The transport intent above gives a grace period so fetchTransportStates
        // doesn't immediately override with STOPPED during Sonos startup
        if let idx = zones.firstIndex(where: { $0.id == zone.id }) {
            zones[idx].isPlaying = true
            // Pair stationNameURI with the URL we're actually telling Sonos to
            // play, right now, at the one moment we reliably know both together.
            // This is the real fix for stale station names surviving a transfer/
            // new selection — the app already knows the correct name here; we
            // don't need to wait for (or trust) Sonos's own GetMediaInfo title,
            // which can come back empty for iHeart HLS streams (confirmed via a
            // real repro — Sonos's dc:title was blank while the stream itself
            // was playing correctly). currentTrackURI is set optimistically here
            // too so the staleness check in PlaybackContextService is correctly
            // satisfied immediately, not left waiting for a later poll to
            // independently converge on the same URL.
            zones[idx].currentTrackURI = streamURL
            zones[idx].currentTrack = ""
            zones[idx].currentArtist = ""
            zones[idx].isHDMI = false
            PlaybackStore.shared.declareTransport(zoneID: zone.id, playing: true)
            // Force idleState false immediately — stale topology IdleState for a zone's
            // first playback this session would otherwise cause a false "stopped" report
            // once the grace period above expires, until the next periodic topology refresh.
            zones[idx].idleState = false
        }

        // Declare it as well: the same content, now bound to the URI it describes.
        // This is the one moment the app reliably knows both together — Sonos itself
        // often returns an empty title for these streams, so waiting to infer the name
        // from a later poll is what produced stale names in the first place.
        PlaybackStore.shared.declare(
            zoneID: zone.id,
            context: PlaybackContext(track: "",
                                     artist: "",
                                     albumName: stationName,
                                     duration: 0,
                                     artAlbum: nil,
                                     artURL: logoURL.isEmpty ? nil : logoURL,
                                     isLocal: false),
            uri: streamURL
        )

        Task {
            do {
                // Store the stream URL we actually played. It is the key the reverse
                // lookup needs to answer "what station is this URI?" later — Sonos
                // never reports a station name for these streams, so without this a
                // station first seen by playing it has no way to be identified again.
                try SorrivaDatabase.shared.upsertStation(
                    id: stationId, source: "iheart",
                    name: stationName, logoURL: logoURL,
                    streamURL: streamURL.isEmpty ? nil : streamURL
                )
                if !zone.dbDeviceId.isEmpty {
                    // zone_state write removed — write-only table, superseded by
                    // PlaybackStore's zone_last_playing (bZoneStateWriteOnly).
                }
                sLog("ZONES: Persisted station play \(stationName) on \(zone.name)")
            } catch {
                sLog("ZONES: Station persist error: \(error)")
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
            sLog("LOCALPLAY: SetAVTransportURIWithMetadata \(host) status=\(status) url=\(streamURL.prefix(60))")
        } catch {
            sLog("LOCALPLAY: SetAVTransportURIWithMetadata error \(host): \(error.localizedDescription)")
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
        // Declared in BOTH directions. The playingUntil field this replaced was only set
        // on idle -> playing, so a pause the user issued had no protection from a stale
        // poll and the button appeared to bounce back.
        PlaybackStore.shared.declareTransport(zoneID: zoneID, playing: !isPlaying)
        if let idx = zones.firstIndex(where: { $0.id == zoneID }) {
            zones[idx].isPlaying = !isPlaying
            if !isPlaying {
                // Transitioning idle → playing: same protection as persistStationPlay/
                // setPlaybackGrace — stale IdleState from before this zone was active
                // would otherwise cause a false "stopped" report once raw transport
                // catches up, until the next periodic topology refresh corrects it.
                zones[idx].idleState = false
            }
        }
        Task {
            let action = isPlaying ? "Pause" : "Play"
            do {
                await ZoneDiscoveryService.sendTransportAction(host: zone.host, action: action)
            } catch {
                sLog("ZONES: \(action) failed on \(zone.name): \(error.localizedDescription)")
                // Revert optimistic update on failure
                if let idx = self.zones.firstIndex(where: { $0.id == zoneID }) {
                    self.zones[idx].isPlaying = isPlaying
                }
            }
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
            sLog("LOCALPLAY: \(action) \(host) status=\(status)")
        } catch {
            sLog("LOCALPLAY: \(action) error \(host): \(error.localizedDescription)")
        }
    }

    /// Set a playback grace period for a zone — prevents brief STOPPED state during media switches
    /// from showing the zone as inactive. Call before initiating playback.
    func setPlaybackGrace(zoneID: String, duration: TimeInterval = 6.0) {
        if let idx = zones.firstIndex(where: { $0.id == zoneID }) {
            PlaybackStore.shared.declareTransport(zoneID: zoneID, playing: true)
            // Same rationale as persistStationPlay — clear any stale idle flag now
            // rather than waiting for the next periodic topology refresh to catch up.
            zones[idx].idleState = false
            sLog("ZONES: grace period set for \(zones[idx].name) (\(duration)s)")
        }
    }

    func setVolume(zoneID: String, volume: Int) {
        guard let zone = zones.first(where: { $0.id == zoneID }) else { return }
        let clamped = max(0, min(100, volume))
        let delta = clamped - zone.volume
        // B-001: Record command time to prevent poll from snapping volume back
        volumeCommandTimes[zoneID] = Date()

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

    /// What a zone is playing, expressed as a declaration another zone can inherit —
    /// or nil when nothing honest can be said about it.
    ///
    /// One resolution order, so that anything needing to say "what is this zone playing"
    /// asks once and gets one answer. Transfer used to carry its own inline version of
    /// this, which is how two implementations of a single question drifted apart.
    ///
    /// The order is load-bearing:
    /// 1. A live declaration is definitive — the app set this content itself.
    /// 2. Last-playing counts ONLY while its URI is still what the zone reports. A
    ///    memory of *different* content would otherwise travel as though it were current,
    ///    which is the stale-pair failure the declaration model exists to prevent.
    /// 3. Whatever the zone is currently displaying — Sonos's URI as already enriched by
    ///    our database. Sonos reports the URI for a stopped zone as readily as a playing
    ///    one, so "we don't know what this is" is almost never true.
    /// 4. Last resort only: synthesis from the zone's own RAW fields. It reads Sonos's
    ///    `dc:title`, which is a filename or a slug, so it must never outrank step 3.
    func contentDeclaration(forZoneID zoneID: String) -> PlaybackDeclaration? {
        if let live = PlaybackStore.shared.declarations[zoneID] { return live }
        guard let zone = zones.first(where: { $0.id == zoneID }),
              !zone.currentTrackURI.isEmpty else { return nil }

        if let last = PlaybackStore.shared.lastDeclarations[zoneID],
           last.uri == zone.currentTrackURI {
            return last
        }

        // What the zone is currently displaying: Sonos's URI enriched by our own database
        // — a local file resolved from its `x-file-cifs://` URI, a station matched against
        // the stations table. This is the RESOLVED answer, and it comes before the raw
        // synthesis below.
        //
        // The order matters and getting it wrong is visible: with synthesis first, an
        // ungrouped zone showed the group's correct artwork beside the name `hls.m3u8`,
        // because synthesis reads `zone.stationName` — Sonos's raw `dc:title`, a filename
        // for iHeart and a slug for SomaFM — while the artwork came from a field that did
        // hold the resolved logo. Raw Sonos fields must never outrank resolved ones.
        if let context = PlaybackContextService.shared.contexts[zoneID] {
            return PlaybackDeclaration(context: context,
                                       uri: zone.currentTrackURI,
                                       source: .app,
                                       declaredAt: Date())
        }

        // The raw-field synthesis that used to sit here is gone with the fields it read.
        // It existed only for a zone nothing had resolved yet, and it read Sonos's
        // dc:title — a filename or a slug — so it could only ever produce a name worse
        // than no name. The resolved context above is the last real source.

        // Nothing left to consult: the zone reports no URI we can describe. The group
        // is not playing anything, so clearing the member is the honest outcome.
        return nil
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

        // Same protection as persistStationPlay/setPlaybackGrace/togglePlayPause —
        // clear stale idleState and declare transport on the coordinator and every zone
        // being added, BEFORE the SOAP calls fire. Without this, the regular periodic poll
        // loop (running independently the whole time) can catch Sonos's own brief internal
        // transition mid-handshake and correctly-but-visibly render it as idle for a
        // moment, even though the group action is succeeding — exactly the "everything
        // flashes idle then bounces back" blip.
        //
        // Grouping runs ~2s, comfortably inside the grace window, so unlike transfer and
        // local playback these declarations do not need refreshing after the fact. That
        // was measured, not assumed (see bTransportOptimismScalesWithQueueLength).
        if let idx = zones.firstIndex(where: { $0.id == coordinatorID }) {
            zones[idx].idleState = false
            PlaybackStore.shared.declareTransport(zoneID: coordinatorID, playing: true)
        }
        for id in addZoneIDs {
            if let idx = zones.firstIndex(where: { $0.id == id }) {
                zones[idx].idleState = false
                PlaybackStore.shared.declareTransport(zoneID: id, playing: true)
            }
        }

        // Nothing is declared here on purpose. A grouped member never receives the
        // stream — its transport is set to `x-rincon:` pointing at the coordinator, which
        // does the streaming — so its own queue is untouched the whole time it is grouped,
        // and Sonos restores it on separation. Declaring the coordinator's content onto a
        // member therefore asserts something Sonos is about to contradict, and destroys
        // the member's real last-playing on the way in. Verified on the speakers: with
        // Patio coordinating Bossa Beyond, Garage separated still parked on its own
        // zc7934. See fPlaybackStoreGroupDeclarations.
        Task {
            // Remove zones from this group
            for id in removeZoneIDs {
                if let host = removeHostMap[id] {
                    await ZoneDiscoveryService.becomeCoordinator(host: host)
                    // A departing zone stops. Standing alone, it would otherwise carry on
                    // playing the group's content in a room the user just removed from
                    // the group; only the coordinator and the members still in it keep
                    // playing.
                    await ZoneDiscoveryService.sendTransportAction(host: host, action: "Stop")
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
                await refreshZoneGroupState(host: host)
            }
            // Full topology refresh to get updated group members.
            //
            // Now arguably redundant: refreshZoneGroupState above merges group structure
            // as of 2026-08-08, which is the whole point of that fix. Left in place
            // deliberately rather than removed in the same change — this path runs after
            // OUR OWN grouping command, where being certain matters more than saving a
            // round trip, and removing it is a behavioural change that deserves its own
            // test rather than riding along with the bug fix.
            //
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let host = zones.first?.host {
                requestTopologyRefresh(host: host)
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
            sLog("TRANSFER: AddMember \(memberHost) → \(memberUUID) status=\(status)")
        } catch {
            sLog("TRANSFER: AddMember error: \(error.localizedDescription)")
        }
    }

    func ungroupZone(zoneID: String) {
        guard let zone = zones.first(where: { $0.id == zoneID }),
              !zone.groupMembers.isEmpty else { return }

        // No content is declared onto the departing members — Sonos restores each one to
        // its own pre-grouping queue, and that is what will play if the user presses play
        // on it. Saying anything else would describe something the speaker will not do.
        //
        // Send each member to standalone — dissolves playback group
        // Hardware bonds (stereo pairs, Arc+Sub) are not affected
        for member in zone.groupMembers {
            let host = member.host
            Task {
                await ZoneDiscoveryService.becomeCoordinator(host: host)
                // Departing zones stop; only the coordinator keeps playing.
                await ZoneDiscoveryService.sendTransportAction(host: host, action: "Stop")
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
                requestTopologyRefresh(host: host)
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

        // Content moves as a DECLARATION, not as a field copy.
        //
        // This block used to copy stationName + stationNameURI (and track/artist) from
        // the source. That is what made the round-trip transfer bug so durable: if the
        // source's own stationName was stale — masked at display time by the staleness
        // check but never actually cleared — the copy carried name and URI across
        // together, so they agreed with each other on arrival. The destination's
        // staleness check compares exactly those two values, saw a self-consistent
        // pair, and passed it as fresh. The check could never fire.
        //
        // Moving the declaration avoids that by construction: it carries the URI it was
        // declared against, so it is still reconciled against what Sonos actually
        // reports and cannot smuggle stale text through as its own corroboration.
        // Resolved through the same `contentDeclaration` that grouping uses. This used to
        // be three inline branches — live declaration, synthesis from the source's own
        // fields, give up — which is the identical question grouping answers, asked a
        // second way. Two implementations of one question is what let the idle and playing
        // station paths drift until they disagreed on screen; one resolver, used by both,
        // is the fix for the category rather than the instance.
        if let content = contentDeclaration(forZoneID: fromZoneID) {
            PlaybackStore.shared.declare(zoneID: toZoneID,
                                         context: content.context,
                                         uri: content.uri,
                                         source: content.source)
            PlaybackStore.shared.clearDeclaration(zoneID: fromZoneID)
        } else {
            // The source's state cannot be trusted, so there is nothing honest to hand
            // over. Clear the destination rather than leave it showing its own previous
            // content — polling will establish the truth shortly.
            PlaybackStore.shared.clearDeclaration(zoneID: toZoneID)
            PlaybackStore.shared.clearDeclaration(zoneID: fromZoneID)
        }

        // Transport state is Sonos's to own, and is not implicated in the staleness
        // bug — keep the optimistic values so the destination card doesn't flicker
        // through "idle" while the multi-step transfer settles.
        if let idx = zones.firstIndex(where: { $0.id == toZoneID }) {
            zones[idx].isPlaying = true
            zones[idx].idleState = false
            PlaybackStore.shared.declareTransport(zoneID: toZoneID, playing: true)
        }

        Task {
            // Step 0: register NAS shares with destination before transfer
            // so x-file-cifs:// URIs work immediately when dest becomes coordinator
            if let sources = try? SorrivaDatabase.shared.allLibrarySources(), !sources.isEmpty {
                for source in sources {
                    // Sonos-facing host — see SourceResolver.sonosHost.
                    let nasPath = SourceResolver.sonosNASPath(for: source)
                    await ZoneDiscoveryService.createObject(host: destHost, nasPath: nasPath)
                    sLog("TRANSFER: createObject called for \(nasPath) on \(destZone.name) (\(destHost))")
                }
            }

            // Clear destination queue/transport before joining
            await ZoneDiscoveryService.removeAllTracksFromQueue(host: destHost)
            sLog("TRANSFER: destination queue cleared")

            // Step 1: destination joins source group — audio syncs
            await ZoneDiscoveryService.addMember(
                coordinatorHost: sourceHost,
                memberHost: destHost,
                memberUUID: sourceID
            )
            print("SORRIVA: Transfer step 1 — \(destZone.name) joined \(sourceZone.name)")

            // Step 2: wait for audio to sync on destination
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // Step 3: source goes standalone — destination inherits the queue
            await ZoneDiscoveryService.becomeCoordinator(host: sourceHost)
            sLog("TRANSFER: Step 2 — \(sourceZone.name) released, \(destZone.name) is new coordinator")

            // The source's station fields are deliberately NOT cleared here.
            //
            // An earlier version did clear them, reasoning that a zone which hands
            // playback away should not keep a stale name. That backfired twice:
            // emptying stationName is precisely the condition restoreZoneStateFromDB
            // waits for, so the next topology refresh repopulated the zone from its
            // zone_state row — whatever it last played *via Sorriva*, not what it just
            // handed off — and stamped it fresh on the way in. The zone reverted to
            // "last playing minus one", and the source's artwork blanked meanwhile.
            //
            // Clearing was also solving a problem that no longer exists. The original
            // round-trip bug came from transfer COPYING a stale name+URI pair to the
            // destination, where the two corroborated each other. Transfers now move a
            // declaration instead, and the one remaining path that reads raw source
            // fields is gated on stationNameURI == currentTrackURI. After a handoff the
            // source's URI moves on, that gate fails, and stale data cannot propagate.

            // Step 4: destination needs explicit Play to resume
            try? await Task.sleep(nanoseconds: 500_000_000)
            await ZoneDiscoveryService.sendTransportAction(host: destHost, action: "Play")
            sLog("TRANSFER: Step 3 — Play sent to \(destZone.name)")

            // The steps above take roughly four seconds. Restart BOTH optimism windows
            // now, so they cover the period where Sonos is settling on the new coordinator
            // rather than having been spent on the command sequence.
            //
            // Content and transport must both be refreshed. Refreshing only the content
            // declaration — which is what this did when transport optimism first moved
            // into the store — produced a phantom pause after every transfer: the
            // transport intent was declared before the SOAP sequence began, and a measured
            // transfer takes ~5.2s against a 5s declarationGrace, so the intent had already
            // expired a quarter-second BEFORE Play was sent. The zone then read whatever
            // Sonos reported mid-handover, which is briefly not-playing.
            //
            // It went unnoticed until now because SonosZone.playingUntil used +6s and
            // covered the gap by ~0.7s. That field is being retired (phase E step 5), so
            // this must stand on its own.
            PlaybackStore.shared.touchDeclaration(zoneID: toZoneID)
            PlaybackStore.shared.declareTransport(zoneID: toZoneID, playing: true)

            // A zone_state write used to sit here, mirroring what the destination now
            // plays. PlaybackStore.declare already persists that to zone_last_playing —
            // URI-bound and richer — and nothing ever read zone_state back. See §
            // bZoneStateWriteOnly.

            // Refresh topology
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let host = zones.first?.host {
                requestTopologyRefresh(host: host)
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
            sLog("TRANSFER: BecomeCoordinator \(host) status=\(status)")
        } catch {
            sLog("TRANSFER: BecomeCoordinator error: \(error.localizedDescription)")
        }
    }

    func setMemberVolume(zoneID: String, memberID: String, volume: Int) {
        volumeCommandTimes[memberID] = Date()
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

    /// Read back what a zone is actually doing shortly after a play command.
    ///
    /// A 200 on Play only means the command was well-formed. Sonos will accept every
    /// command in the sequence and still sit in STOPPED if it cannot read the media or
    /// its transport is wedged — which looks identical to success in the logs. Logging
    /// the real state turns "silent with 200s everywhere" into one obvious line.
    nonisolated static func verifyPlaybackStarted(host: String, context: String) async {
        try? await Task.sleep(nanoseconds: 2_500_000_000)
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
              let bodyData = soapBody.data(using: .utf8) else { return }
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
            var state = "UNKNOWN"
            if let open = raw.range(of: "<CurrentTransportState>"),
               let close = raw.range(of: "</CurrentTransportState>",
                                     range: open.upperBound..<raw.endIndex) {
                state = String(raw[open.upperBound..<close.lowerBound])
            }
            if state == "PLAYING" || state == "TRANSITIONING" {
                sLog("LOCALPLAY: verified playing — \(context) is \(state) on \(host)")
            } else {
                sLog("LOCALPLAY: PLAY DID NOT START — \(context) reports \(state) on \(host). "
                   + "Every command was accepted, so check share registration, file "
                   + "reachability from the speaker, or a wedged transport.")
            }
        } catch {
            sLog("LOCALPLAY: transport verify failed \(host): \(error.localizedDescription)")
        }
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

    /// Raw GetZoneGroupState response in, zones out. No network, no state — the
    /// natural seam for the polling path, which had no test coverage until
    /// fZonePollingTestSeam. Internal rather than private so tests can reach it.
    func parseTopology(data: Data) -> [SonosZone]? {
        SonosTopology.parse(data: data)
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

// MARK: - Zone topology cache
// Saves minimal zone info (id, name, host) for instant restore on launch, keyed
// by the network the topology was observed on. Full topology is confirmed and
// replaced by Bonjour discovery running in the background.
//
// The cache is a fast-path hint, never a source of truth. Two independent
// checks keep it honest:
//   1. Network key — a topology is only ever restored on the same IPv4 subnet
//      it was captured on. Take the iPad to a different Sonos system and
//      nothing is restored; discovery runs clean.
//   2. Household ID — subnet keys DO collide (two homes on 192.168.1.0/24 is
//      commonplace). The Sonos household ID, available only after real
//      topology arrives, is what actually proves identity. On mismatch the
//      entry is discarded and rewritten from the live system.

extension ZoneDiscoveryService {

    private static let cacheKeyPrefix = "sorriva.cachedZones."

    /// Pre-network-scoping key. Network-agnostic, therefore exactly the thing
    /// that restores a home topology onto a stranger's network. Dropped on
    /// sight, never read.
    private static let legacyCacheKey = "sorriva.cachedZones"

    private struct CachedTopology: Codable {
        let householdId: String?
        let zones: [CachedZone]
    }

    private struct CachedZone: Codable {
        let id: String
        let name: String
        let host: String
        let capabilities: [String]
    }

    private static func cacheKey(for networkKey: String) -> String {
        cacheKeyPrefix + networkKey
    }

    func saveZonesToCache(householdId: String?) {
        guard let networkKey = NetworkIdentity.currentKey() else {
            sLog("ZONES: No network key available — skipping topology cache write")
            return
        }
        let payload = CachedTopology(
            householdId: householdId,
            zones: zones.map {
                CachedZone(id: $0.id, name: $0.name, host: $0.host, capabilities: $0.capabilities)
            }
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey(for: networkKey))
        UserDefaults.standard.removeObject(forKey: Self.legacyCacheKey)
        cachedHouseholdId = householdId
        sLog("ZONES: Cached \(payload.zones.count) zones — network \(networkKey), household \(householdId ?? "unknown")")
    }

    func restoreZonesFromCache() {
        cachedHouseholdId = nil
        UserDefaults.standard.removeObject(forKey: Self.legacyCacheKey)

        guard let networkKey = NetworkIdentity.currentKey() else {
            sLog("ZONES: No network key available — discovering without cache")
            return
        }
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey(for: networkKey)),
              let payload = try? JSONDecoder().decode(CachedTopology.self, from: data),
              !payload.zones.isEmpty else {
            sLog("ZONES: No cached topology for network \(networkKey) — discovering fresh")
            return
        }

        cachedHouseholdId = payload.householdId
        zones = payload.zones.map { c in
            var z = SonosZone(id: c.id, name: c.name, host: c.host, isPlaying: false, volume: 0)
            z.capabilities = c.capabilities
            return z
        }.sorted { $0.name < $1.name }

        sLog("ZONES: Restored \(zones.count) zones for network \(networkKey) — unverified until household confirms")

        // Immediately poll transport state so cached zones show real play/pause status
        Task {
            await fetchTransportStates()
        }
    }

    func discardCachedTopology(reason: String) {
        if let networkKey = NetworkIdentity.currentKey() {
            UserDefaults.standard.removeObject(forKey: Self.cacheKey(for: networkKey))
        }
        cachedHouseholdId = nil
        sLog("ZONES: Discarded cached topology — \(reason)")
    }
}

// MARK: - Foreground notification

extension Notification.Name {
    static let sorrivaAppDidBecomeActive = Notification.Name("sorrivaAppDidBecomeActive")
    static let sorrivaSetPlaybackGrace   = Notification.Name("sorrivaSetPlaybackGrace")
}

// MARK: - NetServiceBrowserDelegate

extension ZoneDiscoveryService: NetServiceBrowserDelegate {

    nonisolated func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        Task { @MainActor in sLog("ZONES: Bonjour browser searching for _sonos._tcp") }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in sLog("ZONES: Bonjour found \(service.name)") }
        service.delegate = self
        service.resolve(withTimeout: 5.0)
        Task { @MainActor in self.pendingServices.append(service) }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        Task { @MainActor in sLog("ZONES: Bonjour browser error \(errorDict) — check Local Network permission") }
        Task { @MainActor in
            self.discoveryError = "Network search failed"
            self.isDiscovering = false
        }
    }
}

// MARK: - NetServiceDelegate

extension ZoneDiscoveryService: NetServiceDelegate {

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in sLog("ZONES: Bonjour resolved \(sender.name)") }
        Task { @MainActor in
            self.serviceResolved(sender)
            self.pendingServices.removeAll { $0 === sender }
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        Task { @MainActor in sLog("ZONES: Bonjour failed to resolve \(sender.name): \(errorDict)") }
        Task { @MainActor in
            self.pendingServices.removeAll { $0 === sender }
        }
    }
}
