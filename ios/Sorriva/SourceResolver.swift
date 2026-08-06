import Foundation
import GRDB

// MARK: - PlayableSource
// Output of SourceResolver — everything needed to start playback on an endpoint.

struct PlayableSource: Sendable {
    let trackID: CanonicalTrackID
    let representationID: RepresentationID
    let kind: RepresentationKind
    let locator: String         // Endpoint-specific URI (e.g. x-file-cifs://)
    let metadata: PlaybackMetadata
}

struct PlaybackMetadata: Sendable {
    let title: String
    let artistName: String
    let albumTitle: String
    let duration: TimeInterval?
    let trackNumber: Int?
}

// MARK: - SourceResolverError

enum SourceResolverError: Error, LocalizedError {
    case noCanonicalTrack(legacyID: String)
    case noRepresentationFound(canonicalID: CanonicalTrackID)
    case sourceUnreachable(sourceID: LibrarySourceID)
    case unsupportedKind(RepresentationKind)

    var errorDescription: String? {
        switch self {
        case .noCanonicalTrack(let id):
            return "No canonical track found for legacy ID: \(id)"
        case .noRepresentationFound(let id):
            return "No playable representation found for track \(id)"
        case .sourceUnreachable(let id):
            return "Library source \(id) is not reachable"
        case .unsupportedKind(let kind):
            return "Representation kind '\(kind.rawValue)' is not yet supported"
        }
    }
}

// MARK: - SourceResolver
// Resolves canonical track identity to a playable representation for a given endpoint.
// Constitution I-006: source resolution is late — happens at playback time, not queue time.
// Architecture doc: SourceResolver section.

@MainActor
final class SourceResolver {

    static let shared = SourceResolver()

    private let database: SorrivaDatabase

    init(database: SorrivaDatabase = .shared) {
        self.database = database
    }

    // MARK: - Primary API

    /// Resolve a legacy Track to a PlayableSource for Sonos x-file-cifs playback.
    /// This is the initial implementation — SMB representation only.
    /// Future: check streaming representations when SMB is unavailable.
    func resolve(track: Track) throws -> PlayableSource {
        // Step 1: find canonical ID via legacy map
        guard let canonicalID = LegacyMusicMapper.canonicalTrackID(
            forLegacyID: track.id,
            in: database
        ) else {
            // Fall back to direct construction if backfill hasn't run yet
            return try resolveDirectly(from: track)
        }

        // Step 2: find best representation
        guard let repr = try findBestRepresentation(for: canonicalID, track: track) else {
            throw SourceResolverError.noRepresentationFound(canonicalID: canonicalID)
        }

        // Step 3: build endpoint locator
        let locator = try buildLocator(for: repr, track: track)

        return PlayableSource(
            trackID: canonicalID,
            representationID: repr.id,
            kind: repr.kind,
            locator: locator,
            metadata: PlaybackMetadata(
                title: track.title,
                artistName: track.artistName,
                albumTitle: track.albumTitle,
                duration: track.duration,
                trackNumber: track.trackNumber
            )
        )
    }

    /// Resolve a canonical track ID directly (for use after WP-12 is fully settled).
    func resolve(canonicalTrackID: CanonicalTrackID) throws -> PlayableSource {
        // Look up legacy track via reverse map
        guard let legacyID = LegacyMusicMapper.legacyTrackID(
            forCanonicalID: canonicalTrackID,
            in: database
        ),
        let track = try? database.dbQueue.read({ db in
            try Track.filter(sql: "id = ?", arguments: [legacyID]).fetchOne(db)
        }) else {
            throw SourceResolverError.noRepresentationFound(canonicalID: canonicalTrackID)
        }
        return try resolve(track: track)
    }

    // MARK: - x-file-cifs URI construction
    // Confined to SourceResolver — SMB path construction must not appear in views
    // or application services. Architecture doc WP-13 acceptance criteria.

    /// The host form Sonos needs — for `x-file-cifs://` URIs and for share registration.
    ///
    /// `LibrarySource.host` is what Bonjour discovery produced: the service name plus its
    /// domain, e.g. `AV-Server.local` (see `AddSMBSourceView`, where the hostname is
    /// assembled). That is the right address for the **iPhone's own** SMB connection —
    /// the scanner resolves it over mDNS and it works — so it stays exactly as it is.
    ///
    /// **Sonos needs the name the share is registered under in the household**, which is
    /// the short name. One field was serving two clients with different addressing
    /// requirements, and Sonos silently inherited an address meant for the phone.
    ///
    /// Measured 2026-08-05, same file and same minute across four speakers:
    ///
    ///     host              Master Bath   Office    Workout   Master Bedroom
    ///     AV-Server         PLAYING       PLAYING   PLAYING   PLAYING
    ///     AV-Server.local   PLAYING       PLAYING   STOPPED   STOPPED (UPnP 701)
    ///
    /// The failure mode is what made this so hard to see: `SetAVTransportURI` returns 200
    /// and Sonos validates lazily, so a bad host is accepted and the transport simply
    /// never leaves STOPPED. `Play` then returns either 200 (and nothing happens) or 500
    /// with `errorCode=701`, depending on the speaker. Because `.local` resolves on some
    /// speakers and not others, it presented as intermittent and zone-specific, and was
    /// twice mistaken for a wedged transport, a share-registration failure, and a
    /// regression in unrelated work.
    static func sonosHost(_ host: String) -> String {
        guard let range = host.range(of: ".local", options: [.caseInsensitive, .backwards]),
              range.upperBound == host.endIndex else { return host }
        return String(host[..<range.lowerBound])
    }

    /// The `//host/share` path used to register a NAS share with a speaker.
    static func sonosNASPath(for source: LibrarySource) -> String {
        "//\(sonosHost(source.host))/\(source.share)"
    }

    static func xFileCIFSLocator(track: Track, source: LibrarySource) -> String {
        let path = track.filePath.hasPrefix("/") ? track.filePath : "/\(track.filePath)"
        return "x-file-cifs://\(sonosHost(source.host))/\(source.share)\(path)"
    }

    // MARK: - Private

    private func findBestRepresentation(
        for canonicalID: CanonicalTrackID,
        track: Track
    ) throws -> TrackRepresentation? {
        // Priority 1: available SMB representation reachable by current household
        // For now: use the track's sourceId to build the representation directly
        // This will be replaced by a proper DB lookup once representation CRUD is in place
        let reprID = RepresentationID()
        return LegacyMusicMapper.smbRepresentation(
            from: track,
            canonicalTrackID: canonicalID,
            representationID: reprID
        )
    }

    private func buildLocator(for repr: TrackRepresentation, track: Track) throws -> String {
        switch repr.kind {
        case .smbFile:
            guard let source = (try? database.allLibrarySources())?.first(where: { $0.id == track.sourceId }) else {
                throw SourceResolverError.sourceUnreachable(sourceID: repr.sourceID)
            }
            return Self.xFileCIFSLocator(track: track, source: source)
        case .localReplica, .appleMusic, .qobuz, .tidal:
            throw SourceResolverError.unsupportedKind(repr.kind)
        }
    }

    /// Direct resolution without canonical ID — fallback for tracks not yet backfilled.
    private func resolveDirectly(from track: Track) throws -> PlayableSource {
        guard let source = (try? database.allLibrarySources())?.first(where: { $0.id == track.sourceId }) else {
            throw SourceResolverError.sourceUnreachable(
                sourceID: LibrarySourceID(string: track.sourceId) ?? LibrarySourceID()
            )
        }
        let locator = Self.xFileCIFSLocator(track: track, source: source)
        let canonicalID = CanonicalTrackID()
        let reprID = RepresentationID()

        return PlayableSource(
            trackID: canonicalID,
            representationID: reprID,
            kind: .smbFile,
            locator: locator,
            metadata: PlaybackMetadata(
                title: track.title,
                artistName: track.artistName,
                albumTitle: track.albumTitle,
                duration: track.duration,
                trackNumber: track.trackNumber
            )
        )
    }
}
