import Foundation

// MARK: - AppleMusicPlayback
//
// Handing Sonos an Apple Music track so that IT does the fetching — the phone is never in
// the audio path. Everything here was measured on hardware 2026-08-18; see
// sonos-playback-contract.md §13.
//
// THE RULE THAT LOOKS WRONG AND IS NOT: THE DIDL MUST NOT CONTAIN A `<res>` ELEMENT.
//
// Supply one and Sonos takes your word for the resource, stores it as an opaque
// `application/octet-stream`, and reports TrackDuration 0:00:00 forever — the progress bar
// has nothing to draw while the elapsed clock climbs past it. Omit it, give the item its
// object id and the household token, and Sonos resolves the track THROUGH THE SERVICE,
// returning the real mime type (`application/x-mpegURL`) and the real length.
//
// This cost most of a session to find, because the first attempt omitted `<res>` AND used
// `id="-1"` AND had no token — it failed with errorCode 800, and "res is required" was
// recorded as the lesson. It was the wrong variable. Sonos's own favorite metadata carries
// no `<res>` at all, which is what finally gave it away.
//
// A TOKEN IS REQUIRED, unlike a bare URI play. Without it the same request falls back to
// octet-stream with no duration. It is the household's Apple Music linkage and is read
// from a saved favorite — see `AppleMusicPlayback.token(from:)`.

enum AppleMusicPlayback {

    /// Sonos's service number for Apple Music. The `sid` in a URI is 204; the number
    /// inside the token is `sid * 256 + 7`, which holds across every service in the
    /// household — iHeart 6→1543, Spotify 12→3079, SiriusXM 37→9479, Sonos Radio
    /// 303→77575. Derivable, so only the ACCOUNT half ever needs discovering.
    static let serviceId = 204

    /// The address Sonos plays. Catalogue ids only — the same numbers Apple's public
    /// catalogue returns.
    static func trackURI(catalogueId: Int) -> String {
        "x-sonos-http:song%3a\(catalogueId).mp4?sid=\(serviceId)&flags=8232&sn=5"
    }

    /// The object id Sonos uses for a catalogue track. Three prefixes were tried and all
    /// three resolved; this is the one the speaker writes for its own items.
    static func objectId(catalogueId: Int) -> String {
        "10032028song%3a\(catalogueId)"
    }

    /// The container address for a whole album.
    ///
    /// WHY BOTH THIS AND TRACK-LEVEL ENQUEUE EXIST. Enqueuing tracks keeps the queue ours
    /// and is what lets a playlist mix local FLAC with streaming. But the public catalogue
    /// will not always list an album's tracks — measured 2026-08-18 on Vanessa Daou's
    /// "Slow to Burn", where the API reported 11 tracks and returned NONE, while Sonos
    /// resolved all 11 through the service. With no track ids there is nothing to enqueue,
    /// so an album must be playable as a container or it is not playable at all.
    static func albumContainerURI(collectionId: Int) -> String {
        "x-rincon-cpcontainer:\(albumObjectId(collectionId: collectionId))?sid=\(serviceId)&flags=0&sn=5"
    }

    static func albumObjectId(collectionId: Int) -> String {
        "00040000album%3a\(collectionId)"
    }

    /// Metadata for a whole album. Same rule as a track: no `<res>`.
    static func albumDIDL(collectionId: Int, title: String, token: String) -> String {
        "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
        + " xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\""
        + " xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\""
        + " xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"
        + "<item id=\"\(albumObjectId(collectionId: collectionId))\" parentID=\"-1\" restricted=\"true\">"
        + "<dc:title>\(SonosCommands.escapingXML(title))</dc:title>"
        + "<upnp:class>object.container.album.musicAlbum</upnp:class>"
        + "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">"
        + SonosCommands.escapingXML(token)
        + "</desc></item></DIDL-Lite>"
    }

    /// Metadata for one track. NO `<res>` — see the note at the top of this file.
    static func didl(catalogueId: Int, title: String, token: String) -> String {
        "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
        + " xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\""
        + " xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\""
        + " xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"
        + "<item id=\"\(objectId(catalogueId: catalogueId))\" parentID=\"-1\" restricted=\"true\">"
        + "<dc:title>\(SonosCommands.escapingXML(title))</dc:title>"
        + "<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
        + "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">"
        + SonosCommands.escapingXML(token)
        + "</desc></item></DIDL-Lite>"
    }

    /// The household's Apple Music token, pulled out of any favorite that carries one.
    ///
    /// Every favorite of a given service embeds the same `cdudn`, so ONE saved Apple Music
    /// favorite is enough and it never expires from Sorriva's point of view. This is the
    /// identical mechanism the favorites-backed services already rely on — nothing new is
    /// invented here.
    ///
    /// Returns nil when the household has no Apple Music favorite, which is a real and
    /// reportable state: the user has to save one in the Sonos app once, exactly as they
    /// did for SiriusXM and Spotify.
    /// The household's token, cached for the process.
    ///
    /// Read from the SPEAKER's favorites, not from Sorriva's database. Apple Music is not
    /// imported as a Sorriva service — there are no `stations` rows for it — so looking
    /// locally found nothing even when the household plainly had the credential. That was
    /// a real bug on 2026-08-18: the user saved a favorite, the app still said Apple Music
    /// needed setting up.
    nonisolated(unsafe) private static var cachedToken: String?

    static func token(hosts: [String]) async -> String? {
        if let cachedToken { return cachedToken }
        guard case .ok(let favorites, _) = await SonosFavorites.read(hosts: hosts) else { return nil }
        let found = token(from: favorites.map(\.metadata))
        cachedToken = found
        return found
    }

    static func token(from metadata: [String]) -> String? {
        // `SA_RINCON52231_X_#Svc52231-e60e984c-Token`
        let expected = "SA_RINCON\(serviceId * 256 + 7)_X_#Svc\(serviceId * 256 + 7)-"
        for md in metadata {
            guard let start = md.range(of: expected) else { continue }
            guard let end = md.range(of: "-Token", range: start.upperBound..<md.endIndex) else { continue }
            return String(md[start.lowerBound..<end.upperBound])
        }
        return nil
    }
}
