import Foundation

// MARK: - SonosCommands
//
// Everything Sorriva says to a speaker. Play, pause, skip, load a station, build
// a queue, register a NAS share, join a group, break away from one, set a volume,
// and ask whether playback actually started.
//
// These are the app's entire vocabulary for talking to Sonos: every tap in the UI
// eventually becomes one of these calls. They hold no state — a host address goes
// in, XML goes out over the wire — which is why they were the safest large piece
// to lift out of ZoneDiscoveryService (2026-08-09, step two of
// fZoneDiscoveryServiceDecomposition, 556 lines).
//
// THEY HAVE NO TESTS. That is the point of moving them, not an accident of it.
// This is the highest-traffic untested code in the app, and until there is a seam
// to fake a speaker, the only verification available is playing something and
// watching. The move was deliberately VERBATIM for that reason — no restructuring,
// no shared SOAP helper yet, so the compiler and a live check are enough to trust
// it. The helper and the tests come next, on their own.
//
// THE SEQUENCES ARE LOAD-BEARING AND DOCUMENTED ELSEWHERE. Before changing the
// ORDER of anything here, read server/static/docs/engineering/sonos-playback-contract.md.
// It is the measured record of which command sequences work, and two of its rules
// explain most of what looks redundant below: a 200 from Sonos does NOT mean
// success — it validates lazily and will happily accept a command it then ignores —
// and local files play via the QUEUE, never by pointing SetAVTransportURI at the
// file. Code that looks like it could be simplified is usually a sequence that was
// arrived at by measurement.

enum SonosCommands {

    /// Swap this in a test to assert what a command sends without a speaker.
    /// See SonosSOAP.swift for why it is a static var rather than a parameter.
    nonisolated(unsafe) static var soap: SonosSOAPTransport = LiveSonosSOAP()

    static func fetchPositionData(host: String) async -> Data? {
        return try? await soap.send(host: host, service: .avTransport, action: "GetPositionInfo",
                                            innerXML: """
              <InstanceID>0</InstanceID>
            """, timeout: SonosTimeout.quick).body
    }

    static func fetchMediaInfo(host: String) async -> (name: String, artURL: String)? {
        guard let reply = try? await soap.send(host: host, service: .avTransport, action: "GetMediaInfo",
                                              innerXML: """
              <InstanceID>0</InstanceID>
            """, timeout: SonosTimeout.quick) else {
            print("SORRIVA: GetMediaInfo fetch failed for \(host)")
            return nil
        }
        let raw = reply.text

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

    static func playStationURL(streamURL: String, on zone: SonosZone, stationName: String = "", artURL: String = "") async {
        print("SORRIVA: Playing \(streamURL) on \(zone.name)")
        await setAVTransportURI(host: zone.host, streamURL: streamURL, stationName: stationName, artURL: artURL)
        await sendTransportAction(host: zone.host, action: "Play")
    }

    static func setAVTransportURI(host: String, streamURL: String, stationName: String = "", artURL: String = "") async {
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

        do {
            let reply = try await soap.send(host: host, service: .avTransport, action: "SetAVTransportURI",
                                            innerXML: """
              <InstanceID>0</InstanceID>
              <CurrentURI>\(escapedURL)</CurrentURI>
              <CurrentURIMetaData>\(didl)</CurrentURIMetaData>
            """, timeout: SonosTimeout.action)
            let status = reply.status
            print("SORRIVA: SetAVTransportURI \(host) status=\(status)")
        } catch {
            print("SORRIVA: SetAVTransportURI error: \(error.localizedDescription)")
        }
    }

    /// Overload for local library playback — accepts a pre-built DIDL-Lite metadata string.
    /// Used by LocalPlaybackService which builds musicTrack DIDL rather than audioBroadcast.
    static func setAVTransportURIWithMetadata(host: String, streamURL: String, didl: String) async {
        let escapedURL = streamURL.replacingOccurrences(of: "&", with: "&amp;")
        do {
            let reply = try await soap.send(host: host, service: .avTransport, action: "SetAVTransportURI",
                                            innerXML: """
              <InstanceID>0</InstanceID>
              <CurrentURI>\(escapedURL)</CurrentURI>
              <CurrentURIMetaData>\(didl)</CurrentURIMetaData>
            """, timeout: SonosTimeout.action)
            let status = reply.status
            sLog("LOCALPLAY: SetAVTransportURIWithMetadata \(host) status=\(status) url=\(streamURL.prefix(60))")
        } catch {
            sLog("LOCALPLAY: SetAVTransportURIWithMetadata error \(host): \(error.localizedDescription)")
        }
    }

    static func removeAllTracksFromQueue(host: String) async {
        do {
            let reply = try await soap.send(host: host, service: .avTransport, action: "RemoveAllTracksFromQueue",
                                            innerXML: """
              <InstanceID>0</InstanceID>
            """, timeout: SonosTimeout.action)
            let status = reply.status
            print("SORRIVA: RemoveAllTracksFromQueue \(host) status=\(status)")
        } catch {
            print("SORRIVA: RemoveAllTracksFromQueue error: \(error.localizedDescription)")
        }
    }

    static func addMultipleURIsToQueue(host: String, uris: [String], didls: [String]) async {
        guard !uris.isEmpty else { return }
        // Build comma-separated URI and DIDL lists
        let uriList = uris.map { $0.replacingOccurrences(of: "&", with: "&amp;") }.joined(separator: " ")
        let didlList = didls.joined(separator: " ")
        do {
            let reply = try await soap.send(host: host, service: .avTransport, action: "AddMultipleURIsToQueue",
                                            innerXML: """
              <InstanceID>0</InstanceID>
              <UpdateID>0</UpdateID>
              <NumberOfURIs>\(uris.count)</NumberOfURIs>
              <EnqueuedURIs>\(uriList)</EnqueuedURIs>
              <EnqueuedURIsMetaData>\(didlList)</EnqueuedURIsMetaData>
              <ContainerURI></ContainerURI>
              <ContainerMetaData></ContainerMetaData>
              <DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued>
              <EnqueueAsNext>0</EnqueueAsNext>
            """, timeout: SonosTimeout.bulk)
            let status = reply.status
            print("SORRIVA: AddMultipleURIsToQueue \(host) \(uris.count) tracks status=\(status)")
        } catch {
            print("SORRIVA: AddMultipleURIsToQueue error: \(error.localizedDescription)")
        }
    }

    /// Add a single URI to the Sonos queue — required for x-file-cifs:// URIs
    /// (AddMultipleURIsToQueue rejects x-file-cifs:// with error 402)
    static func addURIToQueue(host: String, uri: String, didl: String = "") async {
        let escapedURI = uri.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // Previously sent with NO timeoutInterval, so it inherited URLSession's
        // 60-second default — an unreachable speaker froze the start of an album for
        // a full minute. Nobody chose that; it is what the sixteenth hand-written
        // copy of this block happened to omit.
        do {
            let reply = try await soap.send(host: host, service: .avTransport, action: "AddURIToQueue",
                                            innerXML: """
              <InstanceID>0</InstanceID>
              <EnqueuedURI>\(escapedURI)</EnqueuedURI>
              <EnqueuedURIMetaData>\(didl)</EnqueuedURIMetaData>
              <DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued>
              <EnqueueAsNext>0</EnqueueAsNext>
            """, timeout: SonosTimeout.action)
            sLog("SONOS: AddURIToQueue \(host) status=\(reply.status)")
            if !reply.ok {
                sLog("SONOS: AddURIToQueue error body — \(reply.text)")
            }
        } catch {
            sLog("SONOS: AddURIToQueue error: \(error.localizedDescription)")
        }
    }

    /// Register a NAS share with Sonos via ContentDirectory CreateObject.
    /// Must be called once per share before x-file-cifs:// URIs will play.
    /// path format: //hostname/share  e.g. //av-server/media/Music II
    static func createObject(host: String, nasPath: String) async {
        let encodedPath = nasPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nasPath
        let escapedPath = nasPath
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let didl = "&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;container id=&quot;&quot; parentID=&quot;S:&quot; restricted=&quot;false&quot;&gt;&lt;dc:title&gt;\(escapedPath)&lt;/dc:title&gt;&lt;upnp:class&gt;object.container&lt;/upnp:class&gt;&lt;/container&gt;&lt;/DIDL-Lite&gt;"
        // Also previously untimed — same 60-second default, same path. Share
        // registration runs before every local-file play.
        do {
            let reply = try await soap.send(host: host, service: .contentDirectory, action: "CreateObject",
                                            innerXML: """
              <ContainerID>S:</ContainerID>
              <Elements>\(didl)</Elements>
            """, timeout: SonosTimeout.action)
            sLog("SONOS: CreateObject \(host) nasPath=\(nasPath) status=\(reply.status)")
            sLog("SONOS: CreateObject response — \(reply.text.prefix(200))")
        } catch {
            sLog("SONOS: CreateObject error: \(error.localizedDescription)")
        }
        _ = encodedPath // suppress unused warning
    }

    static func sendTransportAction(host: String, action: String) async {
        do {
            let reply = try await soap.send(host: host, service: .avTransport, action: action,
                                            innerXML: """
                  <InstanceID>0</InstanceID>
                  <Speed>1</Speed>
            """, timeout: SonosTimeout.quick)
            sLog("LOCALPLAY: \(action) \(host) status=\(reply.status)")
        } catch {
            sLog("LOCALPLAY: \(action) error \(host): \(error.localizedDescription)")
        }
    }

    static func addMember(coordinatorHost: String, memberHost: String, memberUUID: String) async {
        // SetAVTransportURI with x-rincon: (single colon) sent to MEMBER's host
        // x-rincon:RINCON_XXXX tells the member to join the coordinator's group
        do {
            let reply = try await soap.send(host: memberHost, service: .avTransport, action: "SetAVTransportURI",
                                            innerXML: """
              <InstanceID>0</InstanceID>
              <CurrentURI>x-rincon:\(memberUUID)</CurrentURI>
              <CurrentURIMetaData></CurrentURIMetaData>
            """, timeout: SonosTimeout.action)
            let status = reply.status
            sLog("TRANSFER: AddMember \(memberHost) → \(memberUUID) status=\(status)")
        } catch {
            sLog("TRANSFER: AddMember error: \(error.localizedDescription)")
        }
    }

    static func becomeCoordinator(host: String) async {
        do {
            let reply = try await soap.send(host: host, service: .avTransport, action: "BecomeCoordinatorOfStandaloneGroup",
                                            innerXML: """
              <InstanceID>0</InstanceID>
            """, timeout: SonosTimeout.action)
            let status = reply.status
            sLog("TRANSFER: BecomeCoordinator \(host) status=\(status)")
        } catch {
            sLog("TRANSFER: BecomeCoordinator error: \(error.localizedDescription)")
        }
    }

    static func sendSetVolume(host: String, volume: Int) async {
        do {
            let reply = try await soap.send(host: host, service: .renderingControl, action: "SetVolume",
                                            innerXML: """
              <InstanceID>0</InstanceID>
              <Channel>Master</Channel>
              <DesiredVolume>\(volume)</DesiredVolume>
            """, timeout: SonosTimeout.quick)
            let status = reply.status
            print("SORRIVA: SetVolume \(host) → \(volume) status=\(status)")
        } catch {
            print("SORRIVA: SetVolume error \(host): \(error.localizedDescription)")
        }
    }

    static func volumeInfo(host: String) async -> Int {
        do {
            let reply = try await soap.send(host: host, service: .renderingControl, action: "GetVolume",
                                            innerXML: """
              <InstanceID>0</InstanceID>
              <Channel>Master</Channel>
            """, timeout: SonosTimeout.quick)
            let raw = reply.text ?? ""
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
    static func verifyPlaybackStarted(host: String, context: String) async {
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        do {
            let reply = try await soap.send(host: host, service: .avTransport, action: "GetTransportInfo",
                                            innerXML: """
              <InstanceID>0</InstanceID>
            """, timeout: SonosTimeout.quick)
            let raw = reply.text ?? ""
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

    static func transportInfo(host: String) async -> Bool {

        do {
            let reply = try await soap.send(host: host, service: .avTransport, action: "GetTransportInfo",
                                            innerXML: """
              <InstanceID>0</InstanceID>
            """, timeout: SonosTimeout.quick)
            let raw = reply.text ?? ""
            let isPlaying = raw.contains("PLAYING") || raw.contains("TRANSITIONING")
            print("SORRIVA: Transport \(host) → \(isPlaying ? "PLAYING" : "STOPPED")")
            return isPlaying
        } catch {
            print("SORRIVA: Transport fetch error \(host): \(error.localizedDescription)")
            return false
        }
    }
}
