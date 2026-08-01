import Foundation

// MARK: - LibraryRepository
// Persistence boundary for music entities.
// Constitution I-003: views must not access this directly.
// Application services (LibraryService) are the only callers.

protocol LibraryRepository {
    // MARK: - Read
    func allAlbums() throws -> [Album]
    func allArtists() throws -> [Artist]
    func allTracks() throws -> [Track]
    func album(id: String) throws -> Album?
    func tracks(albumId: String) throws -> [Track]
    func albums(artistId: String) throws -> [Album]
    func allStations(source: String) throws -> [Station]

    // MARK: - Delete
    func removeAlbum(id: String) throws
    func removeArtist(id: String) throws
    func removeTrack(id: String) throws
    func deleteOrphanedArtists() throws
    func deleteOrphanedAlbums() throws
}
