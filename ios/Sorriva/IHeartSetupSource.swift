import SwiftUI

// MARK: - IHeartSetupSource
//
// iHeart adopting the shared setup screen (fServiceSetupScreens).
//
// THE ONLY SERVICE WITH A CATALOGUE TOO BIG TO HOLD. SomaFM is 46 channels and a Sonos
// household's favorites are a dozen; iHeart is thousands. So this source does not
// return "everything" and let the screen filter — it fetches the catalogue once into an
// ephemeral SQLite table and answers each query with SQL. That is why the shared
// protocol asks the SOURCE to filter rather than filtering in the view: making the
// screen do it would force this catalogue into memory purely to be filtered twice.
//
// GENRE CHIPS COME FROM OUR OWN TAXONOMY, not iHeart's. The chips are the AllMusic
// parent genres already in the database; the catalogue rows carry iHeart's genre ids as
// a ",1,7,12," string, matched with LIKE. Both halves already existed — this only wires
// them to the shared screen.

@MainActor
struct IHeartSetupSource: ServiceSetupSource {

    var serviceName: String { "iHeartRADIO" }
    var icon: String { "radio" }
    var color: Color { Color(hex: "#CC2027") }
    var emptyMessage: String {
        "iHeart's station catalogue could not be loaded. Check your connection and try again."
    }
    /// iHeart publishes `cume` — cumulative audience — which is what its own popularity
    /// ordering has always used.
    var supportsPopularity: Bool { true }

    var chips: [ServiceSetupChip] {
        get async {
            let parents = (try? SorrivaDatabase.shared.topLevelGenres()) ?? []
            return parents.map { ServiceSetupChip(id: $0.id, name: $0.name) }
        }
    }

    func load(query: String, chip: String?) async throws -> (available: [ServiceSetupItem], inLibrary: Set<String>) {
        try await ensureCatalogue()

        // existingIDs is passed as EMPTY deliberately. The old browser used it to hide
        // stations already added, because that screen could only add. This one shows
        // them with a tick so they can be removed, so nothing is excluded.
        let stations = try SorrivaDatabase.shared.searchIHeartCatalog(
            query: query, parentGenreId: chip, existingIDs: [])

        let items = stations.map {
            ServiceSetupItem(id: String($0.id),
                             title: $0.name,
                             subtitle: $0.description,
                             artURL: $0.logoURL.isEmpty ? nil : $0.logoURL,
                             popularity: $0.cume)
        }
        let stored = (try? SorrivaDatabase.shared.allStations(serviceId: "iheart")) ?? []
        return (items, Set(stored.map { String($0.id) }))
    }

    func add(_ item: ServiceSetupItem) async throws {
        guard let id = Int(item.id) else { return }
        // Read the row back from the catalogue rather than trusting the display item —
        // the stream URL and audience figure are not carried on screen.
        let match = try SorrivaDatabase.shared.searchIHeartCatalog(
            query: item.title, parentGenreId: nil, existingIDs: []).first { $0.id == id }
        try SorrivaDatabase.shared.upsertStation(
            id: id, serviceId: "iheart", name: item.title,
            logoURL: item.artURL, streamURL: match?.streamURL,
            cume: item.popularity ?? 0)
    }

    func remove(_ item: ServiceSetupItem) async throws {
        guard let id = Int(item.id) else { return }
        try SorrivaDatabase.shared.deleteStation(id: id)
    }

    // MARK: - Catalogue

    /// Fetch the catalogue once per launch. It is ephemeral by design — dropped and
    /// rebuilt — so a cold screen must fill it before any query can answer.
    private func ensureCatalogue() async throws {
        if let count = try? SorrivaDatabase.shared.iHeartCatalogCount(), count > 0 { return }

        var stationData: [Int: RadioStation] = [:]
        var stationGenreMap: [Int: Set<Int>] = [:]

        await withTaskGroup(of: (Int, [RadioStation]).self) { group in
            for genreId in IHeartAPI.knownGenreIDs {
                group.addTask { (genreId, await IHeartAPI.fetchAllStations(genreId: genreId)) }
            }
            for await (genreId, stations) in group {
                for station in stations {
                    stationGenreMap[station.id, default: []].insert(genreId)
                    if stationData[station.id] == nil { stationData[station.id] = station }
                }
            }
        }

        guard !stationData.isEmpty else {
            throw SonosSOAPError.badHost("iheart catalogue empty")
        }

        // genreIDs stored as ",1,7,12," so a LIKE can match one id without matching 12
        // when looking for 1.
        let rows = stationData.values.map { s -> (id: Int, name: String, description: String,
                                                  logoURL: String, streamURL: String?,
                                                  cume: Int, genreIDs: String) in
            let gids = stationGenreMap[s.id] ?? []
            let genreStr = "," + gids.sorted().map(String.init).joined(separator: ",") + ","
            return (s.id, s.name, s.description, s.logoURL, s.streamURL, s.cume, genreStr)
        }
        try SorrivaDatabase.shared.rebuildIHeartCatalog(stations: Array(rows))
    }
}
