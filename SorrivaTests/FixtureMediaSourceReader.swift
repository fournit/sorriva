import Foundation
@testable import Sorriva

// MARK: - FixtureMediaSourceReader
// Test-only MediaSourceReader implementation backed by a local directory of
// real fixture files, instead of a live SMB share. Lets SMBScanner's actual
// production code run under XCTest.
//
// bScannerTestSeam — sorriva-scanner-handoff-2026-07-25.md §5.1

final class FixtureMediaSourceReader: MediaSourceReader {

    private let rootURL: URL

    /// - Parameter rootURL: local directory standing in for the SMB share root.
    ///   Paths passed to listDirectory/readHeader use the same shape SMBScanner
    ///   already produces — a leading "/" relative to the share root, e.g.
    ///   "/TestArtist/TestAlbum/01 Track One.flac".
    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private func absoluteURL(for path: String) -> URL {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return relative.isEmpty ? rootURL : rootURL.appendingPathComponent(relative)
    }

    func listDirectory(path: String) async throws -> [MediaSourceEntry] {
        let dirURL = absoluteURL(for: path)
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        )
        return try contents.map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return MediaSourceEntry(
                name: url.lastPathComponent,
                isDirectory: values.isDirectory ?? false,
                size: values.fileSize ?? 0
            )
        }
    }

    func readHeader(path: String, byteCount: Int) async throws -> Data {
        let fileURL = absoluteURL(for: path)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        return handle.readData(ofLength: byteCount)
    }
}
