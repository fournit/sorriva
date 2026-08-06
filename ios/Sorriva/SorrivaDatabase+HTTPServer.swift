import Foundation
import GRDB

// MARK: - SorrivaDatabase extensions for SorrivaHTTPServer
// These methods are required by SorrivaHTTPServer for track and source lookup.
// Add these to SorrivaDatabase.swift in the Track and LibrarySource sections.

extension SorrivaDatabase {

    // MARK: - Track lookup by ID

    /// Fetch a track by its Sorriva UUID — used by SorrivaHTTPServer to resolve
    /// a trackId from the HTTP route to a full Track record with filePath and sourceId.
    func track(id: String) throws -> Track? {
        try dbQueue.read { db in
            try Track.fetchOne(db, key: id)
        }
    }

    // MARK: - LibrarySource lookup by ID

    /// Fetch a library source by its Sorriva UUID — used by SorrivaHTTPServer
    /// to get SMB credentials (host, share, username, password) for a given track's source.
    func librarySource(id: String) throws -> LibrarySource? {
        try dbQueue.read { db in
            try LibrarySource.fetchOne(db, key: id)
        }
    }
}
