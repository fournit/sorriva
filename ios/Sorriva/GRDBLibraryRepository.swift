import Foundation
import GRDB

// MARK: - GRDBLibraryRepository
// Implements LibraryRepository using SorrivaDatabase.
// All queries go through the shared database queue.
// No network, no SwiftUI, no endpoint types — Constitution I-003.

final class GRDBLibraryRepository: LibraryRepository {

    private let database: SorrivaDatabase

    init(database: SorrivaDatabase = .shared) {
        self.database = database
    }

    // MARK: - Read

    func allAlbums() throws -> [Album] {
        try database.allAlbums()
    }

    func allArtists() throws -> [Artist] {
        try database.allArtists()
    }

    func allTracks() throws -> [Track] {
        try database.allTracks()
    }

    func album(id: String) throws -> Album? {
        try database.album(id: id)
    }

    func tracks(albumId: String) throws -> [Track] {
        try database.tracks(albumId: albumId)
    }

    func albums(artistId: String) throws -> [Album] {
        try database.albums(artistId: artistId)
    }

    func allStations(source: String) throws -> [Station] {
        try database.allStations(source: source)
    }

    // MARK: - Delete

    func removeAlbum(id: String) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tracks WHERE albumId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM albums WHERE id = ?", arguments: [id])
        }
    }

    func removeArtist(id: String) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tracks WHERE primaryArtistId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM albums WHERE primaryArtistId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM artists WHERE id = ?", arguments: [id])
        }
    }

    func removeTrack(id: String) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [id])
        }
    }

    func deleteOrphanedArtists() throws {
        try database.deleteOrphanedArtists()
    }

    func deleteOrphanedAlbums() throws {
        try database.deleteOrphanedAlbums()
    }
}
