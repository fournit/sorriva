import Foundation
import GRDB
@testable import Sorriva

// MARK: - TestDatabase
// Creates a disposable in-memory DatabaseQueue with the full Sorriva schema.
// Each test gets a fresh database — no shared state between tests.

enum TestDatabase {

    /// Returns a fully migrated in-memory DatabaseQueue.
    /// Throws if migrations fail — that itself is a test failure.
    static func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()  // in-memory
        try SorrivaDatabase.runMigrationsForTesting(on: queue)
        return queue
    }

    /// A LibrarySource fixture pointing at a fake SMB share.
    static func makeSource(
        id: String = "source-1",
        displayName: String = "Test NAS",
        host: String = "192.168.1.100",
        share: String = "Music",
        rootPath: String = "/"
    ) -> LibrarySource {
        let now = Int(Date().timeIntervalSince1970)
        return LibrarySource(
            id: id,
            type: "smb",
            displayName: displayName,
            host: host,
            share: share,
            rootPath: rootPath,
            username: nil,
            password: nil,
            credentialRef: nil,
            lastScanned: nil,
            trackCount: 0,
            scanState: "idle",
            lastScanFileCount: nil,
            lastScanTotalBytes: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Insert a source into the given queue.
    static func insertSource(_ source: LibrarySource, in queue: DatabaseQueue) throws {
        try queue.write { db in try source.save(db) }
    }

    /// A minimal Artist fixture.
    static func makeArtist(
        id: String = UUID().uuidString,
        name: String = "Test Artist"
    ) -> Artist {
        let now = Int(Date().timeIntervalSince1970)
        return Artist(
            id: id,
            name: name,
            sortName: name,
            imageURL: nil,
            albumCount: 0,
            trackCount: 0,
            createdAt: now,
            updatedAt: now
        )
    }

    /// A minimal Album fixture.
    static func makeAlbum(
        id: String = UUID().uuidString,
        title: String = "Test Album",
        artistId: String,
        sourceId: String,
        folderPath: String = "/Music/Test Artist/Test Album"
    ) -> Album {
        let now = Int(Date().timeIntervalSince1970)
        return Album(
            id: id,
            title: title,
            sortTitle: title,
            primaryArtistId: artistId,
            artistName: "Test Artist",
            year: 2020,
            genre: "Rock",
            artPathThumb: nil,
            artPathFull: nil,
            embeddedArtScanned: false,
            artManualOverride: false,
            embeddedArtFailed: false,
            embeddedArtRetryCount: 0,
            trackCount: 0,
            sourceId: sourceId,
            folderPath: folderPath,
            createdAt: now,
            updatedAt: now
        )
    }

    /// A minimal Track fixture.
    static func makeTrack(
        id: String = UUID().uuidString,
        title: String = "Test Track",
        albumId: String,
        artistId: String,
        sourceId: String,
        filePath: String,
        trackNumber: Int? = 1,
        duration: Double? = 240.0
    ) -> Track {
        let now = Int(Date().timeIntervalSince1970)
        return Track(
            id: id,
            title: title,
            albumId: albumId,
            albumTitle: "Test Album",
            primaryArtistId: artistId,
            artistName: "Test Artist",
            trackNumber: trackNumber,
            discNumber: nil,
            year: 2020,
            genre: "Rock",
            duration: duration,
            fileFormat: "flac",
            filePath: filePath,
            fileSize: 30_000_000,
            bitrate: 1411,
            sampleRate: 44100,
            sourceId: sourceId,
            createdAt: now,
            updatedAt: now
        )
    }
}
