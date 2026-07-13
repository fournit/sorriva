import SwiftUI

// MARK: - LibraryView
// Row-based dashboard. Favorites and Radio rows share favoriteIDs state
// so toggling a heart anywhere updates all views instantly.
// Radio row is now DB-driven — stations come from the stations table,
// seeded via Settings → Services → iHeart.

struct LibraryView: View {
    @ObservedObject var discovery: ZoneDiscoveryService
    let onPlayStation: (RadioStation, SonosZone) -> Void
    let onNavigateToZone: (String) -> Void

    @State private var favoriteIDs: Set<Int> = []
    @State private var loadedLogos: [Int: String] = [:]
    @State private var showFavoritesGrid = false
    @State private var showRadioGrid = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // Header
                HStack {
                    SorrivaWordmark()
                    Spacer()
                    Button(action: {}) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20))
                            .foregroundColor(.sHighlight)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)
                .padding(.bottom, 24)

                // Favorites row
                LibraryRow(title: "Favorites", onSeeAll: { showFavoritesGrid = true }) {
                    FavoritesRow(
                        favoriteIDs: $favoriteIDs,
                        loadedLogos: $loadedLogos,
                        discovery: discovery,
                        onPlayStation: onPlayStation,
                        onNavigateToZone: onNavigateToZone,
                        onFavoriteToggled: { id, isFav in toggleFavorite(id: id, isFav: isFav) }
                    )
                }

                // Radio row — DB-driven
                LibraryRow(title: "Radio", onSeeAll: { showRadioGrid = true }) {
                    RadioRow(
                        favoriteIDs: $favoriteIDs,
                        loadedLogos: $loadedLogos,
                        discovery: discovery,
                        onPlayStation: onPlayStation,
                        onNavigateToZone: onNavigateToZone,
                        onFavoriteToggled: { id, isFav in toggleFavorite(id: id, isFav: isFav) }
                    )
                }

                Spacer().frame(height: 48)
            }
        }
        .background(Color.clear)
        .onAppear {
            loadFavorites()
        }
        .fullScreenCover(isPresented: $showFavoritesGrid) {
            MediaGridView(
                title: "Favorites",
                filter: .favorites,
                favoriteIDs: $favoriteIDs,
                loadedLogos: $loadedLogos,
                discovery: discovery,
                onPlayStation: onPlayStation,
                onNavigateToZone: onNavigateToZone,
                onFavoriteToggled: { id, isFav in toggleFavorite(id: id, isFav: isFav) }
            )
        }
        .fullScreenCover(isPresented: $showRadioGrid) {
            MediaGridView(
                title: "Radio",
                filter: .radio,
                favoriteIDs: $favoriteIDs,
                loadedLogos: $loadedLogos,
                discovery: discovery,
                onPlayStation: onPlayStation,
                onNavigateToZone: onNavigateToZone,
                onFavoriteToggled: { id, isFav in toggleFavorite(id: id, isFav: isFav) }
            )
        }
    }

    private func loadFavorites() {
        let iheart = (try? SorrivaDatabase.shared.allStations(source: "iheart")) ?? []
        let somafm = (try? SorrivaDatabase.shared.allStations(source: "somafm")) ?? []
        favoriteIDs = Set((iheart + somafm).filter { $0.isFavorite }.map { $0.id })
    }

    private func toggleFavorite(id: Int, isFav: Bool) {
        if isFav {
            favoriteIDs.insert(id)
        } else {
            favoriteIDs.remove(id)
        }
    }
}

// MARK: - LibraryRow

struct LibraryRow<Content: View>: View {
    let title: String
    let onSeeAll: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: onSeeAll) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.sTextPrimary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.sTextMuted)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onSeeAll) {
                    Text("See all")
                        .font(.system(size: 13))
                        .foregroundColor(.sHighlight)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            content()
        }
        .padding(.bottom, 28)
    }
}

// MARK: - FavoritesRow
// Shows only stations marked isFavorite in the DB.

struct FavoritesRow: View {
    @Binding var favoriteIDs: Set<Int>
    @Binding var loadedLogos: [Int: String]
    @ObservedObject var discovery: ZoneDiscoveryService
    let onPlayStation: (RadioStation, SonosZone) -> Void
    let onNavigateToZone: (String) -> Void
    let onFavoriteToggled: (Int, Bool) -> Void

    @State private var dbStations: [Station] = []

    private var favoriteStations: [RadioStation] {
        dbStations
            .filter { favoriteIDs.contains($0.id) }
            .map { RadioStation(from: $0) }
    }

    var body: some View {
        Group {
            if favoriteStations.isEmpty {
                HStack {
                    Text("Heart a station to add it here")
                        .font(.system(size: 13))
                        .foregroundColor(.sTextMuted)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    Spacer()
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(favoriteStations, id: \.id) { station in
                            MediaCard(
                                radioStation: station,
                                logoURL: loadedLogos[station.id] ?? station.logoURL,
                                isFavorite: true,
                                discovery: discovery,
                                onPlayStation: onPlayStation,
                                onNavigateToZone: onNavigateToZone,
                                onFavoriteToggled: onFavoriteToggled
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .onAppear { loadFromDB() }
        .onReceive(NotificationCenter.default.publisher(for: .stationsDidUpdate)) { _ in
            loadFromDB()
        }
    }

    private func loadFromDB() {
        let iheart = (try? SorrivaDatabase.shared.allStations(source: "iheart")) ?? []
        let somafm = (try? SorrivaDatabase.shared.allStations(source: "somafm")) ?? []
        dbStations = iheart + somafm
        for s in dbStations {
            if let logo = s.logoURL { loadedLogos[s.id] = logo }
        }
    }

    // Reload when a station is favorited elsewhere
    func refresh() { loadFromDB() }
}

// MARK: - RadioRow
// DB-driven. Loads all stations from the stations table.
// Empty state prompts user to go to Settings → Services to add stations.

struct RadioRow: View {
    @Binding var favoriteIDs: Set<Int>
    @Binding var loadedLogos: [Int: String]
    @ObservedObject var discovery: ZoneDiscoveryService
    let onPlayStation: (RadioStation, SonosZone) -> Void
    let onNavigateToZone: (String) -> Void
    let onFavoriteToggled: (Int, Bool) -> Void

    @State private var dbStations: [Station] = []

    private var radioStations: [RadioStation] {
        dbStations.map { RadioStation(from: $0) }
    }

    var body: some View {
        Group {
            if radioStations.isEmpty {
                // Empty state — prompt to add stations via Settings
                HStack(spacing: 12) {
                    Image(systemName: "radio")
                        .font(.system(size: 20))
                        .foregroundColor(.sTextMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No stations yet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                        Text("Add radio stations in Settings → Services")
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(radioStations, id: \.id) { station in
                            MediaCard(
                                radioStation: station,
                                logoURL: loadedLogos[station.id] ?? station.logoURL,
                                isFavorite: favoriteIDs.contains(station.id),
                                discovery: discovery,
                                onPlayStation: onPlayStation,
                                onNavigateToZone: onNavigateToZone,
                                onFavoriteToggled: onFavoriteToggled
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        // Reload every time this row appears
        .onAppear { loadFromDB() }
        // Also reload when stations are added via the browser
        .onReceive(NotificationCenter.default.publisher(for: .stationsDidUpdate)) { _ in
            loadFromDB()
        }
    }

    func loadFromDB() {
        // Load stations from all radio sources
        let iheart = (try? SorrivaDatabase.shared.allStations(source: "iheart")) ?? []
        let somafm = (try? SorrivaDatabase.shared.allStations(source: "somafm")) ?? []
        dbStations = (iheart + somafm).sorted { $0.name < $1.name }
        for s in dbStations {
            if let logo = s.logoURL { loadedLogos[s.id] = logo }
        }
    }
}

// MARK: - MediaCard

struct MediaCard: View {
    var radioStation: RadioStation? = nil
    var station: Station? = nil
    var logoURL: String = ""
    var isFavorite: Bool = false

    @ObservedObject var discovery: ZoneDiscoveryService
    var onPlayStation: ((RadioStation, SonosZone) -> Void)? = nil
    var onNavigateToZone: ((String) -> Void)? = nil
    var onFavoriteToggled: ((Int, Bool) -> Void)? = nil

    @State private var zonePickerStation: RadioStation? = nil
    @State private var localFavorite: Bool = false
    @State private var showActionSheet = false

    private var displayName: String { radioStation?.name ?? station?.name ?? "" }
    private var displayID: Int { radioStation?.id ?? station?.id ?? 0 }
    private var displayLogoURL: String {
        !logoURL.isEmpty ? logoURL : (radioStation?.logoURL ?? station?.logoURL ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if !displayLogoURL.isEmpty, let url = URL(string: displayLogoURL) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFill()
                            default: artPlaceholder
                            }
                        }
                    } else {
                        artPlaceholder
                    }
                }
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Brass heart in circle — favorite indicator
                if localFavorite {
                    ZStack {
                        Circle()
                            .fill(Color.sCard.opacity(0.85))
                            .frame(width: 26, height: 26)
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.sBrass)
                    }
                    .padding(5)
                }
            }
            .onTapGesture { zonePickerStation = radioStation }
            .onLongPressGesture(minimumDuration: 0.4) {
                showActionSheet = true
            }

            Text(displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.sTextPrimary)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)
        }
        .onAppear { localFavorite = isFavorite }
        .onChange(of: isFavorite) { localFavorite = $0 }
        .sheet(isPresented: $showActionSheet) {
            if let rs = radioStation {
                StationActionSheet(
                    station: rs,
                    logoURL: displayLogoURL,
                    isFavorite: localFavorite,
                    onFavorite: {
                        handleFavorite()
                        showActionSheet = false
                    },
                    onPlayOn: {
                        showActionSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            zonePickerStation = rs
                        }
                    }
                )
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.sCard)
            }
        }
        .sheet(item: $zonePickerStation) { rs in
            ZonePickerSheet(
                station: rs,
                discovery: discovery,
                onPick: { zone in
                    zonePickerStation = nil
                    let artURL = displayLogoURL
                    let stationName = rs.name
                    let stationId = rs.id

                    Task {
                        var streamURL = try? SorrivaDatabase.shared.cachedStreamURL(stationId: stationId)
                        if streamURL == nil {
                            streamURL = await IHeartAPI.fetchStreamURL(streamID: stationId)
                        }

                        guard let url = streamURL else { return }

                        await ZoneDiscoveryService.playStationURL(
                            streamURL: url,
                            on: zone,
                            stationName: stationName,
                            artURL: artURL
                        )
                        discovery.persistStationPlay(
                            zone: zone,
                            stationId: stationId,
                            stationName: stationName,
                            logoURL: artURL
                        )
                        discovery.triggerRefresh()
                    }

                    onPlayStation?(rs, zone)
                    onNavigateToZone?(zone.id)
                }
            )
        }
    }

    private var artPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.sCard)
            .overlay(Image(systemName: "radio").font(.system(size: 24)).foregroundColor(.sTextMuted))
    }

    private func handleFavorite() {
        let newState = !localFavorite
        localFavorite = newState
        Task {
            _ = try? SorrivaDatabase.shared.toggleFavorite(stationId: displayID)
            await MainActor.run {
                onFavoriteToggled?(displayID, newState)
                // Notify FavoritesRow to reload so new favorite appears immediately
                NotificationCenter.default.post(name: .stationsDidUpdate, object: nil)
            }
        }
    }
}

// MARK: - StationActionSheet

struct StationActionSheet: View {
    let station: RadioStation
    let logoURL: String
    let isFavorite: Bool
    let onFavorite: () -> Void
    let onPlayOn: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Group {
                    if !logoURL.isEmpty, let url = URL(string: logoURL) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFill()
                            default: RoundedRectangle(cornerRadius: 8).fill(Color.sCard)
                            }
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(Color.sCard)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(station.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.sTextPrimary)
                    Text("iHeartRADIO")
                        .font(.system(size: 12))
                        .foregroundColor(.sTextMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(Color.sSeparator)

            VStack(spacing: 0) {
                ActionRow(
                    icon: isFavorite ? "heart.fill" : "heart",
                    iconColor: isFavorite ? .sBrass : .sTextPrimary,
                    title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    action: onFavorite
                )

                Divider().background(Color.sSeparator).padding(.leading, 56)

                ActionRow(
                    icon: "hifispeaker.2",
                    iconColor: .sTextPrimary,
                    title: "Play on...",
                    action: onPlayOn
                )
            }

            Spacer(minLength: 0)
        }
    }
}

struct ActionRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.sSurface)
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 16))    
                        .foregroundColor(iconColor)
                }
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(.sTextPrimary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - MediaGridView
// See All screen for a library category.
// Radio: 3-column grid, genre chips derived from actual stations in library.
// Albums: 2-column grid (when implemented).
// Genre chips show only genres present in the user's data.

enum MediaFilter { case favorites, radio }

struct MediaGridView: View {
    let title: String
    let filter: MediaFilter
    @Binding var favoriteIDs: Set<Int>
    @Binding var loadedLogos: [Int: String]
    @ObservedObject var discovery: ZoneDiscoveryService
    let onPlayStation: (RadioStation, SonosZone) -> Void
    let onNavigateToZone: (String) -> Void
    let onFavoriteToggled: (Int, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var allStations: [Station] = []
    @State private var availableGenres: [Genre] = []
    @State private var selectedGenreID: String? = nil

    // Columns per filter type
    private var columns: [GridItem] {
        switch filter {
        case .radio, .favorites:
            return [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ]
        }
    }

    private var displayStations: [RadioStation] {
        var base = allStations
        switch filter {
        case .favorites: base = base.filter { favoriteIDs.contains($0.id) }
        case .radio: break
        }
        if let genreID = selectedGenreID {
            let filtered = (try? SorrivaDatabase.shared.stations(inGenre: genreID)) ?? []
            let filteredIDs = Set(filtered.map { $0.id })
            base = base.filter { filteredIDs.contains($0.id) }
        }
        return base.map { RadioStation(from: $0) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color.sGradientTop, Color.sGradientBottom],
                          startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.sTextPrimary)
                    Spacer()
                    Color.clear.frame(width: 24, height: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 56)
                .padding(.bottom, 12)

                // Genre chips — only genres present in user's library
                if !availableGenres.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            GenreFilterChip(label: "All", isSelected: selectedGenreID == nil) {
                                selectedGenreID = nil
                            }
                            ForEach(availableGenres, id: \.id) { genre in
                                GenreFilterChip(
                                    label: genre.name,
                                    isSelected: selectedGenreID == genre.id
                                ) {
                                    selectedGenreID = selectedGenreID == genre.id ? nil : genre.id
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 12)
                }

                if displayStations.isEmpty {
                    Spacer()
                    Text(filter == .favorites
                         ? "No favorites yet\nHeart a station to add it here"
                         : "No stations yet\nAdd stations in Settings → Services")
                        .font(.system(size: 15))
                        .foregroundColor(.sTextMuted)
                        .multilineTextAlignment(.center)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(displayStations, id: \.id) { rs in
                                MediaCard(
                                    radioStation: rs,
                                    logoURL: loadedLogos[rs.id] ?? rs.logoURL,
                                    isFavorite: favoriteIDs.contains(rs.id),
                                    discovery: discovery,
                                    onPlayStation: onPlayStation,
                                    onNavigateToZone: onNavigateToZone,
                                    onFavoriteToggled: onFavoriteToggled
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 32)
                    }
                }
            }
        }
        .onAppear { loadFromDB() }
    }

    private func loadFromDB() {
        let iheart = (try? SorrivaDatabase.shared.allStations(source: "iheart")) ?? []
        let somafm = (try? SorrivaDatabase.shared.allStations(source: "somafm")) ?? []
        allStations = (iheart + somafm).sorted { $0.name < $1.name }
        for s in allStations {
            if let logo = s.logoURL { loadedLogos[s.id] = logo }
        }
        availableGenres = (try? SorrivaDatabase.shared.genresInStationLibrary()) ?? []
    }
}

// MARK: - GenreFilterChip
// Used in the See All grid — distinct from GenreChip in the station browser.

struct GenreFilterChip: View {
    let label: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .sTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.sAccent : Color.sSurface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
