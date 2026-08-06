import SwiftUI

// MARK: - RadioStation
// Display model for a radio station — constructed from the stations DB table
// or from a live iHeart API response.

struct RadioStation: Identifiable {
    let id: Int
    let name: String
    let description: String
    var logoURL: String
    var streamURL: String?
    var isFavorite: Bool
    var source: String
    var cume: Int           // iHeart cumulative audience — used for popularity sort

    init(from station: Station, description: String = "") {
        self.id = station.id
        self.name = station.name
        self.description = description
        self.logoURL = station.logoURL ?? ""
        self.streamURL = station.streamURL
        self.isFavorite = station.isFavorite
        self.source = station.source
        self.cume = station.cume
    }

    init(id: Int, name: String, description: String, logoURL: String,
         streamURL: String?, cume: Int = 0) {
        self.id = id
        self.name = name
        self.description = description
        self.logoURL = logoURL
        self.streamURL = streamURL
        self.isFavorite = false
        self.source = "iheart"
        self.cume = cume
    }
}

// MARK: - IHeartGenre

struct IHeartGenre: Identifiable {
    let id: Int
    let name: String
    var stationCount: Int = 0
}

// MARK: - IHeartAPI

enum IHeartAPI {

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private static let baseURL = "https://us.api.iheart.com/api/v2/content/liveStations"

    // iHeart genre IDs confirmed via API exploration July 2026
    static let knownGenreIDs: [Int] = [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 13, 14, 16, 18, 77, 93, 97, 104, 1201, 1208, 1209]

    static let genreNames: [Int: String] = [
        1: "Alternative",       2: "Christian & Gospel",  3: "Classic Rock",
        4: "Classical",         5: "Country",             6: "Hip Hop & R&B",
        7: "Jazz",              8: "Mix & Variety",       10: "Oldies",
        12: "Rock",             13: "Mix",                14: "Spanish",
        16: "Top 40 & Pop",    18: "80s & 90s",          77: "Dance",
        93: "Public Radio",    97: "Holiday",            104: "R&B",
        1201: "iHeart Originals", 1208: "Decades",       1209: "Commercial Free"
    ]

    // MARK: Fetch entire iHeart catalog — all genres, all pages
    // Returns up to ~3,644 stations. Fetches genres concurrently then paginates each.
    // cume field preserved for popularity sort.

    static func fetchFullCatalog() async -> [RadioStation] {
        var seen = Set<Int>()
        var all: [RadioStation] = []

        // Fetch all genre catalogs concurrently
        await withTaskGroup(of: [RadioStation].self) { group in
            for genreId in knownGenreIDs {
                group.addTask { await fetchAllStations(genreId: genreId) }
            }
            for await stations in group {
                for station in stations {
                    if seen.insert(station.id).inserted {
                        all.append(station)
                    }
                }
            }
        }

        print("SORRIVA iHeart: Full catalog loaded — \(all.count) stations")
        return all
    }

    // MARK: Fetch all stations for a single genre — paginated

    static func fetchAllStations(genreId: Int) async -> [RadioStation] {
        var all: [RadioStation] = []
        var offset = 0
        let pageSize = 50

        while true {
            guard var components = URLComponents(string: baseURL) else { break }
            components.queryItems = [
                URLQueryItem(name: "limit",   value: "\(pageSize)"),
                URLQueryItem(name: "offset",  value: "\(offset)"),
                URLQueryItem(name: "genreId", value: "\(genreId)")
            ]
            guard let url = components.url else { break }
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let hits = json?["hits"] as? [[String: Any]] ?? []

                let stations = hits.compactMap { hit -> RadioStation? in
                    guard let id = hit["id"] as? Int,
                          let name = hit["name"] as? String else { return nil }
                    let description = hit["description"] as? String ?? ""
                    let logo = hit["logo"] as? String ?? ""
                    let cume = hit["cume"] as? Int ?? 0
                    let streams = hit["streams"] as? [String: Any]
                    var streamURL: String? = nil
                    if let hls = streams?["hls_stream"] as? String {
                        streamURL = "hls-radio://\(hls)"
                    } else if let shout = streams?["shoutcast_stream"] as? String {
                        streamURL = shout
                    }
                    return RadioStation(id: id, name: name, description: description,
                                       logoURL: logo, streamURL: streamURL, cume: cume)
                }

                all.append(contentsOf: stations)
                if hits.count < pageSize { break }
                offset += pageSize

            } catch {
                print("SORRIVA iHeart: error genre \(genreId) offset \(offset): \(error.localizedDescription)")
                break
            }
        }

        return all
    }

    // MARK: Fetch iHeart genre list with station counts

    static func fetchGenres() async -> [IHeartGenre] {
        let counts: [(Int, Int)] = await withTaskGroup(of: (Int, Int).self) { group in
            for genreId in knownGenreIDs {
                group.addTask {
                    guard var components = URLComponents(string: baseURL) else { return (genreId, 0) }
                    components.queryItems = [
                        URLQueryItem(name: "limit",   value: "1"),
                        URLQueryItem(name: "genreId", value: "\(genreId)")
                    ]
                    guard let url = components.url else { return (genreId, 0) }
                    var request = URLRequest(url: url)
                    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                    request.timeoutInterval = 8
                    do {
                        let (data, _) = try await URLSession.shared.data(for: request)
                        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        return (genreId, json?["total"] as? Int ?? 0)
                    } catch { return (genreId, 0) }
                }
            }
            var collected: [(Int, Int)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        return counts
            .compactMap { (id, count) -> IHeartGenre? in
                guard let name = genreNames[id], count > 0 else { return nil }
                return IHeartGenre(id: id, name: name, stationCount: count)
            }
            .sorted { $0.name < $1.name }
    }

    // MARK: Stream URL fallback

    static func fetchStreamURL(streamID: Int) async -> String? {
        guard let url = URL(string: "https://us.api.iheart.com/api/v2/content/liveStations/\(streamID)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 5
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let hits = json?["hits"] as? [[String: Any]],
                  let station = hits.first,
                  let streams = station["streams"] as? [String: Any] else { return nil }
            if let hls = streams["hls_stream"] as? String { return "hls-radio://\(hls)" }
            return streams["shoutcast_stream"] as? String
        } catch { return nil }
    }
}

// MARK: - SomaFMChannel
// Model for a SomaFM channel from the public channels.json API.
// numericID is a stable hash of the channel ID string for use as DB primary key.

struct SomaFMChannel: Identifiable {
    let id: String          // SomaFM channel slug e.g. "groovesalad"
    let title: String
    let description: String
    let largeImage: String  // 256px PNG from api.somafm.com/logos/
    let genres: [String]    // pipe-split genre tags e.g. ["ambient", "electronic"]
    let listeners: Int      // current listener count — popularity sort
    let lastPlaying: String // "Artist - Title" — live track, free from API
    let streamURL: String   // x-rincon-mp3radio://ice1.somafm.com/{id}-128-aac

    // Stable numeric ID for SQLite primary key — deterministic djb2 hash of the slug.
    // Swift's hashValue is randomized per-session on iOS — cannot be used for persistence.
    // djb2 is stable across runs. Range 900000-1999999 avoids iHeart ID collision.
    var numericID: Int {
        var hash: UInt32 = 5381
        for char in id.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ UInt32(char.value)
        }
        return Int(hash % 1_000_000) + 900_000
    }
}

// MARK: - SomaFMAPI
// Public SomaFM API — no auth, no rate limiting documented.
// Single endpoint returns all 46 channels with full metadata.
// Stream URL extracted from highest quality AAC playlist.

enum SomaFMAPI {

    // MARK: Fetch all channels

    static func fetchChannels() async -> [SomaFMChannel] {
        guard let url = URL(string: "https://api.somafm.com/channels.json") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let channels = json?["channels"] as? [[String: Any]] else { return [] }

            // Fetch stream URLs concurrently — one .pls fetch per channel
            let results: [SomaFMChannel] = await withTaskGroup(of: SomaFMChannel?.self) { group in
                for ch in channels {
                    group.addTask { await parseChannel(ch) }
                }
                var collected: [SomaFMChannel] = []
                for await result in group {
                    if let c = result { collected.append(c) }
                }
                return collected
            }

            print("SORRIVA SomaFM: Loaded \(results.count) channels")
            return results.sorted { $0.listeners > $1.listeners }

        } catch {
            print("SORRIVA SomaFM: fetchChannels error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: Parse a single channel dict — fetch .pls to resolve stream URL

    private static func parseChannel(_ ch: [String: Any]) async -> SomaFMChannel? {
        guard let id = ch["id"] as? String,
              let title = ch["title"] as? String else { return nil }

        let description = ch["description"] as? String ?? ""
        let largeImage = ch["largeimage"] as? String ?? ch["image"] as? String ?? ""
        let genreStr = ch["genre"] as? String ?? ""
        let genres = genreStr.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
        let listeners = ch["listeners"] as? Int ?? 0
        let lastPlaying = ch["lastPlaying"] as? String ?? ""

        // Find highest quality AAC playlist URL
        let playlists = ch["playlists"] as? [[String: Any]] ?? []
        let aacHighest = playlists.first(where: { ($0["format"] as? String) == "aac" && ($0["quality"] as? String) == "highest" })
        let plsURL = aacHighest?["url"] as? String ?? ""

        // Fetch .pls to get direct stream URL
        let streamURL = await resolveStreamURL(plsURL: plsURL, channelID: id)

        return SomaFMChannel(
            id: id, title: title, description: description,
            largeImage: largeImage, genres: genres,
            listeners: listeners, lastPlaying: lastPlaying,
            streamURL: streamURL
        )
    }

    // MARK: Resolve .pls to direct stream URL
    // .pls format: File1=https://ice4.somafm.com/groovesalad-128-aac
    // Sonos needs: x-rincon-mp3radio://ice4.somafm.com/groovesalad-128-aac (no scheme)

    static func resolveStreamURL(plsURL: String, channelID: String) async -> String {
        guard let url = URL(string: plsURL) else {
            return "x-rincon-mp3radio://ice1.somafm.com/\(channelID)-128-aac"
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let text = String(data: data, encoding: .utf8) ?? ""
            // Extract File1= line
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.lowercased().hasPrefix("file1=") {
                    let rawURL = String(trimmed.dropFirst(6)) // drop "File1="
                    // Strip https:// → x-rincon-mp3radio://host/path
                    if rawURL.hasPrefix("https://") {
                        let withoutScheme = String(rawURL.dropFirst(8)) // drop "https://"
                        return "x-rincon-mp3radio://\(withoutScheme)"
                    } else if rawURL.hasPrefix("http://") {
                        let withoutScheme = String(rawURL.dropFirst(7))
                        return "x-rincon-mp3radio://\(withoutScheme)"
                    }
                    return rawURL
                }
            }
        } catch {}
        // Fallback — construct URL from known pattern
        return "x-rincon-mp3radio://ice1.somafm.com/\(channelID)-128-aac"
    }

    // MARK: Fetch stream URL for a single channel by ID (for playback fallback)

    static func fetchStreamURL(channelID: String) async -> String? {
        let plsURL = "https://api.somafm.com/\(channelID)130.pls"
        let result = await resolveStreamURL(plsURL: plsURL, channelID: channelID)
        return result.isEmpty ? nil : result
    }

    // MARK: Fetch live now-playing for saved SomaFM stations
    // Returns dict of channelID → "Artist - Title"
    // Called by ZoneDiscoveryService polling for SomaFM zones.

    static func fetchNowPlaying() async -> [String: String] {
        guard let url = URL(string: "https://api.somafm.com/channels.json") else { return [:] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let channels = json?["channels"] as? [[String: Any]] ?? []
            var result: [String: String] = [:]
            for ch in channels {
                if let id = ch["id"] as? String,
                   let playing = ch["lastPlaying"] as? String,
                   !playing.isEmpty {
                    result[id] = playing
                }
            }
            return result
        } catch { return [:] }
    }
}
