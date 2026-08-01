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

    static func xFileCIFSLocator(track: Track, source: LibrarySource) -> String {
        let path = track.filePath.hasPrefix("/") ? track.filePath : "/\(track.filePath)"
        return "x-file-cifs://\(source.host)/\(source.share)\(path)"
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
