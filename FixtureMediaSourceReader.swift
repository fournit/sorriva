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
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        )
        // Sorted for deterministic test ordering — FileManager.contentsOfDirectory
        // makes no ordering guarantee otherwise, which would make any test that
        // depends on processing order (e.g. "first occurrence wins") flaky.
        let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try sorted.map { url in
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            )
            return MediaSourceEntry(
                name: url.lastPathComponent,
                isDirectory: values.isDirectory ?? false,
                size: values.fileSize ?? 0,
                // Real filesystem mtime, not a stub — a test that fabricates
                // this would not exercise the change-detection logic it exists
                // to verify. Tests needing a specific value should set it on
                // the fixture file via FileManager.
                modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
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
