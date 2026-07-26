import Foundation

// MARK: - LibraryService
// Application-level library use cases.
// Architecture doc: LibraryService section.
// Views call this — never the repository or database directly.

@MainActor
final class LibraryService {

    static let shared = LibraryService()

    private let repository: LibraryRepository

    init(repository: LibraryRepository = GRDBLibraryRepository()) {
        self.repository = repository
    }

    // MARK: - List operations

    func listAlbums() -> [Album] {
        (try? repository.allAlbums()) ?? []
    }

    /// Placeholder names used as the album artist on compilations. These are not
    /// real performers, so they are hidden from artist browse. The artist rows and
    /// their album relationships are left intact — album views still show
    /// "Various Artists" as the album artist, and the artist remains reachable by
    /// direct navigation.
    private static let compilationArtistNames: Set<String> = [
        "va", "various", "various artists"
    ]

    func listArtists() -> [Artist] {
        let all = (try? repository.allArtists()) ?? []
        return all.filter { artist in
            let key = artist.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return !Self.compilationArtistNames.contains(key)
        }
    }

    func listTracks() -> [Track] {
        (try? repository.allTracks()) ?? []
    }

    func albumsForArtist(_ artistId: String) -> [Album] {
        (try? repository.albums(artistId: artistId)) ?? []
    }

    func tracksForAlbum(_ albumId: String) -> [Track] {
        (try? repository.tracks(albumId: albumId)) ?? []
    }

    func albumDetail(_ albumId: String) -> Album? {
        try? repository.album(id: albumId)
    }

    func albumsById(from albums: [Album]) -> [String: Album] {
        Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
    }

    // MARK: - Stations

    func allStations(source: String) -> [Station] {
        (try? repository.allStations(source: source)) ?? []
    }

    func favoriteStationIDs(sources: [String]) -> Set<Int> {
        let all = sources.flatMap { allStations(source: $0) }
        return Set(all.filter { $0.isFavorite }.map { $0.id })
    }

    // MARK: - Remove operations

    func removeAlbum(_ album: Album) {
        do {
            try repository.removeAlbum(id: album.id)
            try repository.deleteOrphanedArtists()
            NotificationCenter.default.post(name: .libraryDidUpdate, object: nil)
        } catch {
            sLog("LIBRARY: removeAlbum failed — \(album.title): \(error.localizedDescription)")
        }
    }

    func removeArtist(_ artist: Artist) {
        do {
            try repository.removeArtist(id: artist.id)
            try repository.deleteOrphanedAlbums()
            try repository.deleteOrphanedArtists()
            NotificationCenter.default.post(name: .libraryDidUpdate, object: nil)
        } catch {
            sLog("LIBRARY: removeArtist failed — \(artist.name): \(error.localizedDescription)")
        }
    }

    func removeTrack(_ track: Track) {
        do {
            try repository.removeTrack(id: track.id)
        } catch {
            sLog("LIBRARY: removeTrack failed — \(track.title): \(error.localizedDescription)")
        }
    }

    // MARK: - Post-scan cleanup

    /// Called after scan completes to remove orphaned artists and albums.
    func performPostScanCleanup() {
        do {
            try repository.deleteOrphanedArtists()
            try repository.deleteOrphanedAlbums()
        } catch {
            sLog("LIBRARY: post-scan cleanup failed: \(error.localizedDescription)")
        }
    }
}
