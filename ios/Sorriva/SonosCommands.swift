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

    /// DIDL metadata is XML travelling INSIDE an XML element, so it must be escaped or
    /// the envelope is malformed and the speaker rejects the command.
    ///
    /// Found 2026-08-12: `setAVTransportURIWithMetadata` and `addURIToQueue` both
    /// interpolated their `didl` argument raw. Nothing caught it because every caller
    /// passed an empty string — the first real content sent through was a Sonos
    /// favorite's resMD, and SiriusXM would not play. The tools script that proved
    /// favorites work on 2026-08-10 escaped it; the app did not, and that is the entire
    /// difference between that success and this failure.
    ///
    /// NOT used by `setAVTransportURI`, which builds its own DIDL pre-escaped —
    /// running it through here would double-encode.
    ///
    /// `&` FIRST, or ampersands introduced by the later replacements get re-escaped.
    static func escapingXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Swap this in a test to assert what a command sends without a speaker.
    /// See SonosSOAP.swift for why it is a static var rather than a parameter.
    nonisolated(unsafe) static var soap: SonosSOAPTransport = LiveSonosSOAP()

    static func fetchPositionData(host: String) async -> Data? {
        return try? await soap.send(host: host, service: .avTransport, action: "GetPositionInfo",
                                            innerXML: """
              <InstanceID>0</InstanceID>
            """, timeout: SonosTimeout.quick).body
    }

    /// Raw GetMediaInfo, for the one field that matters: CurrentURI.
    ///
    /// Separate from `fetchMediaInfo` below, which resolves a station NAME and artwork
    /// and is a different job entirely. This exists because the poll needs to know WHAT
    /// a zone has loaded — Sonos Radio and SiriusXM keep that only here, while TrackURI
    /// changes with every song.
    static func fetchMediaData(host: String) async -> Data? {
        do {
            let reply = try await soap.send(host: host, service: .avTransport,
                                            action: "GetMediaInfo",
                                            innerXML: "      <InstanceID>0</InstanceID>",
                                            timeout: SonosTimeout.quick)
            return reply.ok ? reply.body : nil
        } catch {
            return nil
        }
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

    /// Start a station on a zone.
    ///
    /// TWO PATHS, and which one is taken decides whether a closed service plays at all.
    ///
    /// `resMD` present — a station that came from a Sonos favorite. Its metadata is sent
    /// VERBATIM, because it carries the `<desc id="cdudn">` service token that is the
    /// household's entitlement. Synthesising DIDL from the station name instead is the
    /// 2026-08-12 bug: Sonos Radio played (its own service, token account 0) while
    /// SiriusXM returned 200 and sat silent. A 200 is not success — contract §0.
    ///
    /// `resMD` nil — iHeart and SomaFM, which Sorriva addresses directly with real
    /// stream URLs. Generic DIDL is correct for them and is left untouched.
    static func playStationURL(streamURL: String, on zone: SonosZone,
                               stationName: String = "", artURL: String = "",
                               resMD: String? = nil) async {
        print("SORRIVA: Playing \(streamURL) on \(zone.name)\(resMD == nil ? "" : " [favorite metadata]")")
        // A CONTAINER IS NOT A STREAM. Spotify playlists arrive as
        // x-rincon-cpcontainer: and cannot be pointed at with SetAVTransportURI —
        // measured 2026-08-12: 500 with errorCode 714, after which Play returns 200 and
        // the speaker resumes whatever was ALREADY in the queue. A 200 that plays the
        // wrong thing is the worst answer available (contract §0).
        //
        // Containers expand INTO the queue, exactly as local files do (§3). Enqueuing
        // this playlist produced 50 tracks and played correctly.
        if streamURL.hasPrefix("x-rincon-cpcontainer:") {
            await sendTransportAction(host: zone.host, action: "Stop")
            await removeAllTracksFromQueue(host: zone.host)
            await addURIToQueue(host: zone.host, uri: streamURL, didl: resMD ?? "")
            await setAVTransportURIWithMetadata(host: zone.host,
                                                streamURL: "x-rincon-queue:\(zone.id)#0",
                                                didl: "")
            await sendTransportAction(host: zone.host, action: "Play")
            return
        }
        if let resMD, !resMD.isEmpty {
            await setAVTransportURIWithMetadata(host: zone.host, streamURL: streamURL, didl: resMD)
        } else {
            await setAVTransportURI(host: zone.host, streamURL: streamURL,
                                    stationName: stationName, artURL: artURL)
        }
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
              <CurrentURIMetaData>\(escapingXML(didl))</CurrentURIMetaData>
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
    /// The Sonos service ids this household has linked.
    ///
    /// Derived from the speakers rather than hardcoded: whether Apple Music is usable
    /// here is a property of the household, and claiming a service the speakers cannot
    /// play is the same broken promise as a play button on a dead transport.
    static func availableServiceIds(host: String) async -> Set<Int> {
        guard let reply = try? await soap.send(host: host, service: .musicServices,
                                               action: "ListAvailableServices",
                                               innerXML: "", timeout: SonosTimeout.action),
              reply.ok else { return [] }
        // `<Service Id="204" Name="Apple Music" …>` — entity-encoded inside the response.
        let text = reply.text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        var ids: Set<Int> = []
        var search = text.startIndex
        while let open = text.range(of: "<Service Id=\"", range: search..<text.endIndex),
              let close = text.range(of: "\"", range: open.upperBound..<text.endIndex) {
            if let id = Int(text[open.upperBound..<close.lowerBound]) { ids.insert(id) }
            search = close.upperBound
        }
        return ids
    }

    // MARK: - Apple Music

    /// Play Apple Music tracks on a zone. Addresses, metadata rules and the reason the
    /// DIDL carries no `<res>` element all live in AppleMusicPlayback.
    ///
    /// TRACKS INDIVIDUALLY, NOT A CONTAINER. Both work — a container gets Sonos to expand
    /// an album for us — but enqueuing tracks keeps the queue ours: an album, a hand-made
    /// playlist and a mix of local FLAC with streaming tracks are then all the same
    /// operation. Containers would make the album case slightly simpler and every other
    /// case harder.
    ///
    /// Returns false when the household has no Apple Music token, which is not a failure
    /// to retry — it means no Apple Music favorite has been saved in the Sonos app yet.
    /// Play a whole Apple Music album by handing Sonos the container.
    ///
    /// Sonos expands it through the service, which is the only way to play an album whose
    /// tracks the public catalogue will not enumerate — and it also means Sonos supplies
    /// every track's title, mime type and duration.
    static func playAppleMusicAlbum(collectionId: Int, title: String,
                                    token: String, on zone: SonosZone) async -> Bool {
        guard !token.isEmpty else { return false }
        await sendTransportAction(host: zone.host, action: "Stop")
        await removeAllTracksFromQueue(host: zone.host)
        await addURIToQueue(host: zone.host,
                            uri: AppleMusicPlayback.albumContainerURI(collectionId: collectionId),
                            didl: AppleMusicPlayback.albumDIDL(collectionId: collectionId,
                                                               title: title, token: token))
        await setAVTransportURIWithMetadata(host: zone.host,
                                            streamURL: "x-rincon-queue:\(zone.id)#0",
                                            didl: "")
        await sendTransportAction(host: zone.host, action: "Play")
        return true
    }

    static func playAppleMusicTracks(_ tracks: [(id: Int, title: String)],
                                     token: String,
                                     on zone: SonosZone) async -> Bool {
        guard !tracks.isEmpty, !token.isEmpty else { return false }

        await sendTransportAction(host: zone.host, action: "Stop")
        await removeAllTracksFromQueue(host: zone.host)

        for track in tracks {
            await addURIToQueue(
                host: zone.host,
                uri: AppleMusicPlayback.trackURI(catalogueId: track.id),
                didl: AppleMusicPlayback.didl(catalogueId: track.id,
                                              title: track.title,
                                              token: token))
        }

        await setAVTransportURIWithMetadata(host: zone.host,
                                            streamURL: "x-rincon-queue:\(zone.id)#0",
                                            didl: "")
        await sendTransportAction(host: zone.host, action: "Play")
        return true
    }

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
              <EnqueuedURIMetaData>\(escapingXML(didl))</EnqueuedURIMetaData>
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

    /// Which Sonos household this speaker belongs to.
    ///
    /// Favorites are household property, not account property — measured 2026-08-11
    /// across two systems sharing one Sonos account: 42 favorites at one, 10 at the
    /// other. So anything stored from a favorite records the household it came from,
    /// and a refresh may only reconcile what that household can see.
    static func householdId(host: String) async -> String? {
        do {
            let reply = try await soap.send(host: host, service: .deviceProperties,
                                            action: "GetHouseholdID", innerXML: "",
                                            timeout: SonosTimeout.quick)
            guard reply.ok else { return nil }
            let text = reply.text
            guard let open = text.range(of: "<CurrentHouseholdID>"),
                  let close = text.range(of: "</CurrentHouseholdID>") else { return nil }
            return String(text[open.upperBound..<close.lowerBound])
        } catch {
            sLog("SONOS: GetHouseholdID failed for \(host): \(error.localizedDescription)")
            return nil
        }
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

    // MARK: - Mute
    //
    // MUTE IS NOT VOLUME ZERO, and treating them as one thing is what hid a silent
    // Living Room on 2026-08-18: five speakers reporting Mute=1 at volume 10, while
    // Sorriva drew an un-slashed speaker icon at 10 and had no way to say otherwise.
    //
    // Sonos keeps the two independently — muting preserves the level, so unmuting
    // restores it without anyone remembering the old number. Sorriva used to fake mute
    // by setting the volume to 0 and storing the previous value itself, which is both a
    // worse mechanism and invisible to the Sonos app and Alexa.

    static func sendSetMute(host: String, mute: Bool) async {
        do {
            let reply = try await soap.send(host: host, service: .renderingControl, action: "SetMute",
                                            innerXML: """
              <InstanceID>0</InstanceID>
              <Channel>Master</Channel>
              <DesiredMute>\(mute ? 1 : 0)</DesiredMute>
            """, timeout: SonosTimeout.quick)
            print("SORRIVA: SetMute \(host) → \(mute) status=\(reply.status)")
        } catch {
            print("SORRIVA: SetMute error \(host): \(error.localizedDescription)")
        }
    }

    /// Whether a speaker is muted. Defaults to FALSE when the read fails — a zone that
    /// cannot be reached should not be drawn as silenced, which would be a claim we
    /// cannot support.
    static func muteInfo(host: String) async -> Bool {
        do {
            let reply = try await soap.send(host: host, service: .renderingControl, action: "GetMute",
                                            innerXML: """
              <InstanceID>0</InstanceID>
              <Channel>Master</Channel>
            """, timeout: SonosTimeout.quick)
            let raw = reply.text ?? ""
            if let start = raw.range(of: "<CurrentMute>"),
               let end = raw.range(of: "</CurrentMute>") {
                return String(raw[start.upperBound..<end.lowerBound]) == "1"
            }
        } catch {
            print("SORRIVA: GetMute error \(host): \(error.localizedDescription)")
        }
        return false
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
