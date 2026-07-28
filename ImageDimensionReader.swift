import Foundation

// MARK: - ImageDimensionReader
// Reads image pixel dimensions from just the file header, without decoding
// the whole image. bArtworkSelectionNotBestWins — lets the artwork passes
// compare every candidate's true size cheaply (a few KB read) instead of
// fully downloading and decoding each one just to check if it clears a
// floor, which is what the folder pass used to do.
//
// Verified against real PNG/JPEG files (including a JPEG with realistic
// EXIF metadata — SOF marker still lands within ~1KB) before writing the
// production version, the same way the ID3v2 fix was verified.

enum ImageDimensionReader {

    /// Returns (width, height) in pixels, or nil if the data isn't a
    /// recognized PNG/JPEG or doesn't contain enough header to determine size.
    static func dimensions(data: Data) -> (width: Int, height: Int)? {
        // Convert to a base-zero [UInt8] array upfront — Data subscripting is
        // not guaranteed to be zero-based for all Data instances (the same
        // class of bug previously found and fixed in STREAMINFO parsing).
        // Doing this once here means neither parser below needs to worry about it.
        let bytes = [UInt8](data)
        if let png = pngDimensions(bytes: bytes) { return png }
        if let jpeg = jpegDimensions(bytes: bytes) { return jpeg }
        return nil
    }

    // PNG: fixed 8-byte signature, then a sequence of length-prefixed,
    // type-tagged chunks. IHDR (width/height) is normally the very first
    // chunk, but Xcode's build-time "Compress PNG Files" optimization can
    // rewrite a bundled resource to insert a proprietary "CgBI" chunk before
    // it — walking the chunk structure properly (rather than assuming IHDR
    // sits at a fixed byte offset) handles this correctly either way.
    // Verified against both a plain PNG and a simulated CgBI-prefixed one
    // before writing this version.
    private static func pngDimensions(bytes: [UInt8]) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= 8, Array(bytes.prefix(8)) == signature else { return nil }

        let ihdrType: [UInt8] = [0x49, 0x48, 0x44, 0x52] // "IHDR"
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = (Int(bytes[offset]) << 24) | (Int(bytes[offset+1]) << 16)
                       | (Int(bytes[offset+2]) << 8) | Int(bytes[offset+3])
            let typeStart = offset + 4
            guard typeStart + 4 <= bytes.count else { return nil }
            let type = Array(bytes[typeStart..<typeStart+4])

            if type == ihdrType {
                let d = typeStart + 4
                guard d + 8 <= bytes.count else { return nil }
                let width  = (Int(bytes[d])   << 24) | (Int(bytes[d+1]) << 16) | (Int(bytes[d+2]) << 8) | Int(bytes[d+3])
                let height = (Int(bytes[d+4]) << 24) | (Int(bytes[d+5]) << 16) | (Int(bytes[d+6]) << 8) | Int(bytes[d+7])
                return (width, height)
            }
            // Not IHDR — skip this chunk: 4 length + 4 type + <length> data + 4 CRC.
            offset = typeStart + 4 + length + 4
        }
        return nil
    }

    // JPEG: walk marker segments from the SOI (FFD8) looking for a Start Of
    // Frame marker (FFC0-FFCF, excluding DHT/JPG/DAC which reuse that range
    // but aren't SOF). SOF's payload is 1-byte precision, 2-byte height,
    // 2-byte width, both big-endian. Metadata (EXIF/APPn) before it is
    // skipped via each segment's own declared length — verified this stays
    // within a few KB even with realistic embedded EXIF data.
    private static func jpegDimensions(bytes: [UInt8]) -> (width: Int, height: Int)? {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var offset = 2
        while offset + 9 < bytes.count {
            guard bytes[offset] == 0xFF else { offset += 1; continue }
            let marker = bytes[offset + 1]
            let isSOF = (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker)
            if isSOF {
                let height = (Int(bytes[offset + 5]) << 8) | Int(bytes[offset + 6])
                let width  = (Int(bytes[offset + 7]) << 8) | Int(bytes[offset + 8])
                return (width, height)
            }
            // Markers with no length field (SOI/EOI/RSTn) — advance past just the marker.
            if marker == 0xD8 || marker == 0xD9 || (0xD0...0xD7).contains(marker) {
                offset += 2
                continue
            }
            guard offset + 3 < bytes.count else { break }
            let segmentLength = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 2 + segmentLength
        }
        return nil
    }
}
