import SwiftUI
import GRDB

// MARK: - SortMode

enum SortMode: String, CaseIterable {
    case popular = "Popular"
    case alpha   = "A–Z"
}

// MARK: - GenreChip model
// Uses our AllMusic parent genres as chips — not iHeart's categories.
// SQL built dynamically from subgenre names + iHeart xref IDs.

struct GenreChipModel: Identifiable {
    let id: String      // our internal genre slug e.g. "pop-rock"
    let name: String    // display name e.g. "Pop/Rock"
}

// MARK: - IHeartStationBrowserView
// Single-pass catalog load: fetch all stations per genre concurrently,
// build genre map, insert into ephemeral iheart_catalog SQLite table.
// All search/filter via SQL — fast at any catalog size.

struct IHeartStationBrowserView: View {
    @Environment(\.dismiss) private var dismiss

    // Genre chips — our AllMusic parent genres
    @State private var genreChips: [GenreChipModel] = []
    @State private var selectedChipID: String? = nil

    // Load state
    @State private var isLoading = true
    @State private var loadedCount = 0
    @State private var isSaving = false
    @State private var errorMessage: String? = nil

    // Filter
    @State private var searchText = ""
    @State private var sortMode: SortMode = .popular
    @State private var searchTask: Task<Void, Never>? = nil

    // Results from SQL query
    @State private var displayStations: [RadioStation] = []
    @State private var totalCatalogCount = 0

    // Selection
    @State private var selectedIDs: Set<Int> = []
    @State private var existingIDs: Set<Int> = []

    private var hasSelection: Bool { !selectedIDs.isEmpty }
    private var selectedCount: Int { selectedIDs.count }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {

                if isLoading {
                    Spacer()
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.sHighlight)
                            .scaleEffect(1.2)
                        VStack(spacing: 4) {
                            Text("Loading stations…")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.sTextPrimary)
                            if loadedCount > 0 {
                                Text("\(loadedCount) loaded")
                                    .font(.system(size: 13))
                                    .foregroundColor(.sTextMuted)
                            }
                        }
                    }
                    Spacer()

                } else if let error = errorMessage {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 32))
                            .foregroundColor(.sTextMuted)
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundColor(.sTextMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button("Try again") { loadCatalog() }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.sAccent)
                    }
                    Spacer()

                } else {

                    // Search bar
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundColor(.sTextMuted)
                        TextField("Search \(totalCatalogCount) stations", text: $searchText)
                            .font(.system(size: 14))
                            .foregroundColor(.sTextPrimary)
                            .autocorrectionDisabled()
                            .onChange(of: searchText) { _ in debouncedQuery() }
                        if !searchText.isEmpty {
                            Button(action: { searchText = ""; runQuery() }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.sTextMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.sSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                    // Genre chips — our AllMusic parents
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            GenreChip(label: "All", isSelected: selectedChipID == nil) {
                                selectedChipID = nil
                                runQuery()
                            }
                            ForEach(genreChips) { chip in
                                GenreChip(label: chip.name, isSelected: selectedChipID == chip.id) {
                                    selectedChipID = selectedChipID == chip.id ? nil : chip.id
                                    runQuery()
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 8)

                    // Count + selection
                    HStack {
                        Text("\(displayStations.count) station\(displayStations.count == 1 ? "" : "s")")
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                        Spacer()
                        if hasSelection {
                            Button(action: { selectedIDs.removeAll() }) {
                                Text("\(selectedCount) selected · Clear")
                                    .font(.system(size: 12))
                                    .foregroundColor(.sHighlight)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(displayStations) { station in
                                StationBrowserCell(
                                    station: station,
                                    isSelected: selectedIDs.contains(station.id),
                                    isAlreadyAdded: existingIDs.contains(station.id),
                                    onTap: { toggleStation(station) }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 120)
                    }
                }
            }

            // Add button
            if !isLoading {
                VStack {
                    Spacer()
                    Button(action: saveSelectedStations) {
                        HStack(spacing: 8) {
                            if isSaving {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 16))
                            }
                            Text(hasSelection
                                 ? "Add \(selectedCount) Station\(selectedCount == 1 ? "" : "s")"
                                 : "Select stations to add")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(hasSelection ? .white : .sTextMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(hasSelection ? Color.sAccent : Color.sSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasSelection || isSaving)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                    .background(
                        LinearGradient(
                            colors: [Color.sGradientBottom.opacity(0), Color.sGradientBottom],
                            startPoint: .top, endPoint: .bottom
                        )
                        .ignoresSafeArea()
                    )
                }
            }
        }
        .navigationTitle("Browse Stations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.sGradientTop, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !isLoading {
                    Button(action: {
                        sortMode = sortMode == .popular ? .alpha : .popular
                        runQuery()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: sortMode == .popular ? "chart.bar.fill" : "textformat.abc")
                                .font(.system(size: 12))
                            Text(sortMode.rawValue)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.sHighlight)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.sSurface)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear {
            loadExistingStations()
            loadGenreChips()
            loadCatalog()
        }
    }

    // MARK: - Setup

    private func loadExistingStations() {
        existingIDs = Set((try? SorrivaDatabase.shared.allStations())?.map { $0.id } ?? [])
    }

    private func loadGenreChips() {
        // Use our AllMusic parent genres as chips
        let parents = (try? SorrivaDatabase.shared.topLevelGenres()) ?? []
        genreChips = parents.map { GenreChipModel(id: $0.id, name: $0.name) }
    }

    // MARK: - Single-pass catalog load
    // Fetches all stations per iHeart genre concurrently.
    // Builds station data + genre map in one pass.
    // Inserts into ephemeral iheart_catalog table.
    // No separate genre count fetch — totals come from the station data itself.

    private func loadCatalog() {
        isLoading = true
        errorMessage = nil
        loadedCount = 0

        Task {
            // All iHeart genre IDs we know about
            let genreIDs = IHeartAPI.knownGenreIDs

            // Single concurrent fetch — one task per genre
            var stationData: [Int: RadioStation] = [:]       // stationId → station
            var stationGenreMap: [Int: Set<Int>] = [:]       // stationId → Set<iHeartGenreId>

            await withTaskGroup(of: (Int, [RadioStation]).self) { group in
                for genreId in genreIDs {
                    group.addTask {
                        let stations = await IHeartAPI.fetchAllStations(genreId: genreId)
                        return (genreId, stations)
                    }
                }
                for await (genreId, stations) in group {
                    for station in stations {
                        stationGenreMap[station.id, default: []].insert(genreId)
                        if stationData[station.id] == nil {
                            stationData[station.id] = station
                        }
                    }
                    await MainActor.run { loadedCount = stationData.count }
                }
            }

            // Build catalog rows — genreIDs as ",1,7,12," for SQL LIKE matching
            let catalogRows = stationData.values.map { s -> (id: Int, name: String,
                description: String, logoURL: String, streamURL: String?,
                cume: Int, genreIDs: String) in
                let gids = stationGenreMap[s.id] ?? []
                let genreStr = "," + gids.sorted().map { "\($0)" }.joined(separator: ",") + ","
                return (id: s.id, name: s.name, description: s.description,
                        logoURL: s.logoURL, streamURL: s.streamURL,
                        cume: s.cume, genreIDs: genreStr)
            }

            do {
                try SorrivaDatabase.shared.rebuildIHeartCatalog(stations: Array(catalogRows))
                await MainActor.run {
                    totalCatalogCount = catalogRows.count
                    loadedCount = catalogRows.count
                    isLoading = false
                    runQuery()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to load station catalog."
                    isLoading = false
                }
            }
        }
    }

    // MARK: - Query

    private func runQuery() {
        let query = searchText
        let chipID = selectedChipID

        Task {
            do {
                var results = try SorrivaDatabase.shared.searchIHeartCatalog(
                    query: query,
                    parentGenreId: chipID,
                    existingIDs: existingIDs
                )
                if sortMode == .alpha {
                    results.sort { $0.name < $1.name }
                }
                await MainActor.run { displayStations = results }
            } catch {
                // Catalog may not be ready yet
            }
        }
    }

    private func debouncedQuery() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            runQuery()
        }
    }

    // MARK: - Actions

    private func toggleStation(_ station: RadioStation) {
        guard !existingIDs.contains(station.id) else { return }
        if selectedIDs.contains(station.id) {
            selectedIDs.remove(station.id)
        } else {
            selectedIDs.insert(station.id)
        }
    }

    private func saveSelectedStations() {
        guard hasSelection else { return }
        isSaving = true

        Task {
            do {
                let toSave = try SorrivaDatabase.shared.dbQueue.read { db in
                    try Row.fetchAll(db,
                        sql: "SELECT * FROM iheart_catalog WHERE id IN (\(selectedIDs.sorted().map { "\($0)" }.joined(separator: ",")))")
                }

                for row in toSave {
                    let id: Int = row["id"]
                    let genreIDStr: String = row["genreIDs"]
                    try? SorrivaDatabase.shared.upsertStation(
                        id: id, source: "iheart",
                        name: row["name"],
                        logoURL: (row["logoURL"] as String?)?.isEmpty == false ? row["logoURL"] : nil,
                        streamURL: row["streamURL"],
                        cume: row["cume"]
                    )
                    // Map iHeart genre IDs to our internal genre IDs
                    let iHeartGenreIDs = genreIDStr.split(separator: ",").compactMap { Int($0) }
                    for iHeartId in iHeartGenreIDs {
                        if let internalId = try? SorrivaDatabase.shared.internalGenreId(forIHeartGenreId: iHeartId) {
                            try? SorrivaDatabase.shared.addStationGenre(stationId: id, genreId: internalId)
                        }
                    }
                }

                NotificationCenter.default.post(name: .stationsDidUpdate, object: nil)

                await MainActor.run {
                    isSaving = false
                    dismiss()
                }
            } catch {
                await MainActor.run { isSaving = false }
            }
        }
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let stationsDidUpdate = Notification.Name("sorriva.stationsDidUpdate")
}

// MARK: - GenreChip

struct GenreChip: View {
    let label: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .sTextSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Color.sAccent : Color.sSurface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - StationBrowserCell

struct StationBrowserCell: View {
    let station: RadioStation
    let isSelected: Bool
    let isAlreadyAdded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Group {
                    if !station.logoURL.isEmpty, let url = URL(string: station.logoURL) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFill()
                            default: logoPlaceholder
                            }
                        }
                    } else {
                        logoPlaceholder
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(station.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.sTextPrimary)
                        .lineLimit(1)
                    if !station.description.isEmpty {
                        Text(station.description)
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isAlreadyAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.sHighlight)
                } else {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 22))
                        .foregroundColor(isSelected ? .sBrass : .sTextMuted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isSelected ? Color.sSurface.opacity(0.9) : Color.sSurface.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.sBrass.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isAlreadyAdded)
    }

    private var logoPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.sCard)
            .overlay(Image(systemName: "radio").font(.system(size: 18)).foregroundColor(.sTextMuted))
    }
}
