import Foundation
import GRDB

// MARK: - LegacyMusicMapper
// Maps existing Track/Album/Artist database rows to canonical domain objects.
// Pattern E: Legacy migration seam. This mapping is temporary —
// new application APIs use canonical IDs; legacy IDs are preserved in legacy_track_map.
//
// Constitution I-011: existing proven data is retained. We never delete legacy rows.

enum LegacyMusicMapper {

    // MARK: - Track mapping

    /// Map a legacy Track to a MusicTrack using the canonical ID from legacy_track_map.
    static func musicTrack(from track: Track, canonicalID: CanonicalTrackID) -> MusicTrack {
        MusicTrack(
            id: canonicalID,
            title: track.title,
            albumID: CanonicalAlbumID(string: track.albumId),
            primaryArtistID: CanonicalArtistID(string: track.primaryArtistId),
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
            duration: track.duration,
            sortTitle: nil
        )
    }

    /// Map a legacy Track to a TrackRepresentation (smbFile kind).
    static func smbRepresentation(
        from track: Track,
        canonicalTrackID: CanonicalTrackID,
        representationID: RepresentationID
    ) -> TrackRepresentation {
        let normalized = track.filePath.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        return TrackRepresentation(
            id: representationID,
            trackID: canonicalTrackID,
            sourceID: LibrarySourceID(string: track.sourceId) ?? LibrarySourceID(),
            householdID: nil,   // Set when household context is established (WP-12+)
            kind: .smbFile,
            locator: track.filePath,
            normalizedLocator: normalized,
            fileSize: track.fileSize,
            modifiedAt: nil,
            duration: track.duration,
            availability: .unknown,
            lastVerifiedAt: nil
        )
    }

    // MARK: - Album mapping

    static func musicAlbum(from album: Album, canonicalID: CanonicalAlbumID) -> MusicAlbum {
        MusicAlbum(
            id: canonicalID,
            title: album.title,
            sortTitle: album.sortTitle,
            primaryArtistID: CanonicalArtistID(string: album.primaryArtistId),
            year: album.year,
            genre: album.genre
        )
    }

    // MARK: - Artist mapping

    static func musicArtist(from artist: Artist, canonicalID: CanonicalArtistID) -> MusicArtist {
        MusicArtist(
            id: canonicalID,
            name: artist.name,
            sortName: artist.sortName
        )
    }

    // MARK: - Canonical ID from legacy ID

    /// Look up canonical track ID for a legacy track ID.
    /// Returns nil if not yet backfilled (should not happen after migration).
    static func canonicalTrackID(forLegacyID legacyID: String, in database: SorrivaDatabase) -> CanonicalTrackID? {
        guard let canonicalString = try? database.dbQueue.read({ db in
            try String.fetchOne(db,
                sql: "SELECT canonical_id FROM legacy_track_map WHERE legacy_id = ?",
                arguments: [legacyID])
        }) else { return nil }
        return CanonicalTrackID(string: canonicalString)
    }

    /// Look up legacy track ID for a canonical track ID.
    static func legacyTrackID(forCanonicalID canonicalID: CanonicalTrackID, in database: SorrivaDatabase) -> String? {
        try? database.dbQueue.read({ db in
            try String.fetchOne(db,
                sql: "SELECT legacy_id FROM legacy_track_map WHERE canonical_id = ?",
                arguments: [canonicalID.rawValue.uuidString])
        })
    }
}
