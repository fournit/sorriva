import Foundation

// MARK: - StationMetadataResolver
// Single source of truth for validating and cleaning station/stream metadata
// reported by Sonos DIDL (GetMediaInfo, GetPositionInfo TrackMetaData).
//
// WHY THIS EXISTS:
// Sonos's dc:title field is unreliable — depending on zone state and station
// source it may contain the real station name ("Classic Rock") OR the raw
// HLS stream URL/token ("hls.m3u8?rj-ttl=5&rj-tok=..."). Every call site that
// parses this data must apply the same validation, or bugs where a URL leaks
// into the UI as a station name will resurface in whichever site was missed.
//
// isValidStationName is hardware-agnostic — any future endpoint (BlueOS,
// AirPlay) that needs to judge "is this string a real name" should reuse it.
// resolve(rawTitle:rawArtPath:) is Sonos-DIDL-specific (art path conversion
// assumes a Sonos zone host), since other transports report metadata in
// their own shapes.

enum StationMetadataResolver {

    /// Returns true if `raw` looks like a genuine human-readable station/media name,
    /// false if it looks like a URL, stream token, or internal identifier.
    static func isValidStationName(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // URL / URI scheme prefixes
        if trimmed.hasPrefix("http") { return false }
        if trimmed.hasPrefix("x-") { return false }          // x-sonosapi-stream:, x-file-cifs://, etc.
        if trimmed.hasPrefix("RINCON_") { return false }     // Sonos internal zone ID

        // Stream file extensions / manifest formats
        let streamExtensions = [".m3u8", ".m3u", ".pls", ".aac", ".mp3"]
        for ext in streamExtensions where trimmed.contains(ext) {
            return false
        }

        // Query string / token markers — real names don't contain these
        if trimmed.contains("?") || trimmed.contains("&") { return false }
        if trimmed.contains("rj-tok") || trimmed.contains("rj-ttl") { return false }

        // Mostly-digits strings are session IDs or timestamps, not names
        let digitCount = trimmed.filter { $0.isNumber }.count
        if trimmed.count > 0 && Double(digitCount) / Double(trimmed.count) > 0.5 {
            return false
        }

        return true
    }

    /// Resolve a cleaned (name, artURL) pair from raw Sonos DIDL fields.
    /// - Parameters:
    ///   - rawTitle: raw `dc:title` content, if present
    ///   - rawArtPath: raw `upnp:albumArtURI` content, if present (may be relative)
    ///   - zoneHost: host of the zone that reported this metadata, used to
    ///     absolutize relative art paths (Sonos's own `/getaa?...` proxy paths)
    /// - Returns: (name, artURL) — either may be nil if not present or not valid
    static func resolve(rawTitle: String?, rawArtPath: String?, zoneHost: String) -> (name: String?, artURL: String?) {
        var name: String? = nil
        if let rawTitle, isValidStationName(rawTitle) {
            name = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var artURL: String? = nil
        if let rawArtPath, !rawArtPath.isEmpty {
            if rawArtPath.hasPrefix("http") {
                artURL = rawArtPath
            } else if rawArtPath.hasPrefix("/") {
                artURL = "http://\(zoneHost):1400\(rawArtPath)"
            }
        }

        return (name, artURL)
    }
}
