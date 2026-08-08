import Foundation

// MARK: - Sonos topology
//
// The pure half of what ZoneDiscoveryService used to be: bytes in, zones out.
// Nothing here touches the network, the database, PlaybackStore or the clock, so
// it can be tested on a Mac in milliseconds instead of on a booted simulator.
//
// WHY IT WAS SPLIT OUT (2026-08-08). These three functions — parse, merge and
// applyPositionInfo — are where three of the week's defects lived: zones losing
// their alphabetical order, group members flickering to mute, and group changes
// made outside Sorriva never being seen. All three were logic bugs with no I/O in
// them, and all three were expensive to test only because they sat inside a
// 2,300-line object that also owned Bonjour, SOAP, the devices table and playback.
// Extracting them is step one of fZoneDiscoveryServiceDecomposition and what lets
// ZonePollingTests run in the FastTests package.
//
// ZoneDiscoveryService keeps thin wrappers over these, so it still owns WHEN they
// run and what they run against; it no longer owns HOW they work.
//
// The rule for this file: if something here ever needs a URL, a Date() or a
// database handle, it does not belong here — it belongs back in the service.

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
        lhs.isHDMI == rhs.isHDMI &&
        lhs.currentTrackURI == rhs.currentTrackURI &&
        lhs.elapsedSeconds == rhs.elapsedSeconds &&
        lhs.durationSeconds == rhs.durationSeconds &&
        lhs.idleState == rhs.idleState &&
        lhs.capabilities == rhs.capabilities &&
        lhs.groupMembers == rhs.groupMembers
    }
    let id: String          // RINCON UUID of coordinator
    let name: String        // Zone name e.g. "Living Room"
    let host: String        // IPv4 address of coordinator
    var isPlaying: Bool     // Transport state
    var volume: Int         // 0-100
    // stationName / stationNameURI / stationLogoURL were removed here (phase E).
    //
    // They held a station's identity on the zone struct, where every poll path could
    // write to them and every consumer had to defend against staleness. stationNameURI
    // existed solely to detect that staleness — a guard for a problem the field itself
    // created. PlaybackStore now owns station identity, bound to the URI it was resolved
    // for, so "no code path can leave a stale station name behind" is true by
    // construction rather than by vigilance.
    var currentTrack: String = ""
    var currentArtist: String = ""
    var isHDMI: Bool = false        // TV/HDMI source — Arc/Beam specific
    var currentTrackURI: String = ""   // x-file-cifs URI — used by PlaybackContextService
    var elapsedSeconds: Int = 0        // Playback position from GetPositionInfo
    var durationSeconds: Int = 0       // Track duration from GetPositionInfo
    var idleState: Bool = false     // IdleState from topology — true = idle even if transport says PLAYING
    var capabilities: [String] = ["eq", "volume", "mute"]  // Loaded from DB devices table
    var dbDeviceId: String = ""     // Sorriva UUID from devices table
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

class TopologyParser: NSObject, XMLParserDelegate {
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

enum SonosTopology {

    /// SOAP GetZoneGroupState response in, zones out. Returns nil when the payload
    /// is not a topology response at all; an empty array means a real household with
    /// no visible zones, which callers must treat differently — see merge.
    static func parse(data: Data) -> [SonosZone]? {
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

    /// Merge a freshly parsed topology into the live zones, preserving transport state.
    ///
    /// Topology owns IDENTITY and STRUCTURE — which zones exist, their names and hosts,
    /// who is grouped with whom, and IdleState. The 2s transport poll owns ACTIVITY —
    /// playing, volume, track, position, HDMI. Neither may overwrite the other's facts,
    /// which is why this is a merge and not an assignment.
    ///
    /// Grouping changes HOW MANY zones there are, so this cannot be a field update:
    /// a zone that joins a group stops being a zone and becomes a member of one, and a
    /// zone that leaves reappears. That is why the old code, which only patched
    /// IdleState in place, could never see a group change however often it ran.
    ///
    /// RETURNS ALPHABETICALLY SORTED. `zones` is a display-ready list and has always
    /// been alpha sorted, but that invariant lived as a `.sorted` at each assignment
    /// site plus a comment on the property — so adding a new assignment site silently
    /// broke it. That is exactly what happened on 2026-08-08: this merge shipped
    /// assigning unsorted, and because it runs every 15s the alphabetical order
    /// survived only until the first poll. Zone cards, transfer and group pickers all
    /// went unordered. Sorting HERE puts the rule in one place both callers inherit.
    static func merge(parsed: [SonosZone], into existing: [SonosZone]) -> [SonosZone] {
        // Refuse to act on nothing. A timed-out or truncated response parses to an
        // empty list, and applying that would clear every zone in the app — the exact
        // hazard that kept full topology refreshes off the poll loop in the first place.
        guard !parsed.isEmpty else { return existing }

        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return parsed.map { fresh in
            guard let prior = byID[fresh.id] else { return fresh }
            var merged = fresh                 // identity, host, groupMembers, idleState
            merged.isPlaying       = prior.isPlaying
            merged.volume          = prior.volume
            merged.currentTrack    = prior.currentTrack
            merged.currentArtist   = prior.currentArtist
            merged.currentTrackURI = prior.currentTrackURI
            merged.isHDMI          = prior.isHDMI
            merged.elapsedSeconds  = prior.elapsedSeconds
            merged.durationSeconds = prior.durationSeconds
            merged.capabilities    = prior.capabilities   // from the devices table
            merged.dbDeviceId      = prior.dbDeviceId

            // MEMBER VOLUMES TOO. Topology is authoritative for WHICH members a group
            // has; the transport poll is authoritative for how loud each one is.
            // TopologyParser builds members as SonosGroupMember(id:name:host:) with no
            // volume, so they arrive at the struct default of 0 — which the UI draws as
            // muted. Taking fresh.groupMembers wholesale therefore reset every member to
            // silent on each merge, and the poll refilled it moments later: the Master
            // Bedroom and Master Bath sliders cycled between mute and their real level
            // while the speakers never changed. Observed 2026-08-08 with both grouped to
            // Living Room, and confirmed against the speakers, which reported a steady
            // vol=14 and vol=18 throughout.
            //
            // Harmless before this merge ran on a timer, because a topology parse only
            // happened at launch and after Sorriva's own grouping commands.
            let priorVolumes = Dictionary(prior.groupMembers.map { ($0.id, $0.volume) },
                                          uniquingKeysWith: { a, _ in a })
            merged.groupMembers = fresh.groupMembers.map { m in
                var m = m
                if let known = priorVolumes[m.id] { m.volume = known }
                return m
            }
            return merged
        }
        .sorted { $0.name < $1.name }
    }

    /// Raw GetPositionInfo response in, an updated zone out.
    ///
    /// Was an instance method mutating `zones[idx]` in place. Made pure on
    /// 2026-08-08 so it can be tested with a captured response and an expected
    /// zone, with no service and no speaker. Three defects in two days lived here.
    static func applyPositionInfo(to zone: SonosZone, data: Data) -> SonosZone {
        var zone = zone
        let raw = String(data: data, encoding: .utf8) ?? ""

        // Detect HDMI/TV source — clear stale radio metadata
        let isHDMI = raw.contains("x-sonos-htastream") || raw.contains("x-rincon-stream")
        if isHDMI {
            zone.isHDMI = true
            zone.currentTrack = "TV"
            zone.currentArtist = "HDMI"
            return zone
        }

        // Non-HDMI source — clear HDMI flag if it was previously set
        zone.isHDMI = false

        // Parse current TrackURI for local queue advancement
        if let tStart = raw.range(of: "<TrackURI>"),
           let tEnd = raw.range(of: "</TrackURI>") {
            let uri = String(raw[tStart.upperBound..<tEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&")
            if !uri.isEmpty && uri != zone.currentTrackURI {
                zone.currentTrackURI = uri
            }
        }

        // Parse playback position and duration
        if let relStart = raw.range(of: "<RelTime>"),
           let relEnd = raw.range(of: "</RelTime>") {
            let t = String(raw[relStart.upperBound..<relEnd.lowerBound]).trimmingCharacters(in: .whitespaces)
            zone.elapsedSeconds = parseTimeString(t)
        }
        if let durStart = raw.range(of: "<TrackDuration>"),
           let durEnd = raw.range(of: "</TrackDuration>") {
            let t = String(raw[durStart.upperBound..<durEnd.lowerBound]).trimmingCharacters(in: .whitespaces)
            zone.durationSeconds = parseTimeString(t)
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

        // The dc:title / upnp:albumArtURI block was removed here. It ran every poll to
        // copy Sonos's own idea of the station name and art into the zone, which meant a
        // filename for iHeart ("hls.m3u8"), a slug for SomaFM ("groovesalad-128-aac"), and
        // the TRACK title for Sonos Radio — three different meanings for one field, each
        // needing its own defence downstream. The stations table is the single source for
        // a station's name and logo, resolved from the URI in PlaybackContextService.
        //
        // r:streamContent below STAYS. That is genuinely Sonos's to report: it carries the
        // song playing right now on a stream, which the app cannot know, and the reducer
        // reads it directly (bStationTrackFrozenByDeclaration).

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

            // B-005: Filter raw stream metadata (commercials, promos, jingles)
            // Patterns that indicate non-music content: date stamps, raw IDs, numeric-heavy strings
            let isRawMetadata = isRawStreamContent(track) || isRawStreamContent(artist)

            if !track.isEmpty && !isRawMetadata { zone.currentTrack = track }
            if !artist.isEmpty && !isRawMetadata { zone.currentArtist = artist }
            // If raw metadata detected, preserve last known track/artist (or clear if never set)
        }

        return zone
    }

    /// "0:03:17" or "3:17" to seconds. Anything else is 0.
    static func parseTimeString(_ s: String) -> Int {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return 0
        }
    }

    /// B-005: Detect raw/non-music stream metadata patterns.
    static func isRawStreamContent(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        // Date patterns: "04-17-", "2024-", timestamps
        let datePattern = #"\d{2}-\d{2}-"#
        // Raw ID patterns: "IHD-", "SHD-", all-caps with dashes
        let rawIDPattern = #"^[A-Z]+-[A-Z]+"#
        // Numeric prefix: starts with digits like "09 - "
        let numericPrefix = #"^\d{2}\s*-\s*"#

        for pattern in [datePattern, rawIDPattern, numericPrefix] {
            if s.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        // Too many digits relative to length (promo codes, timestamps)
        let digitCount = s.filter { $0.isNumber }.count
        if s.count > 0 && Double(digitCount) / Double(s.count) > 0.4 { return true }
        return false
    }
}
