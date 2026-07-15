import SwiftUI
import GRDB

// MARK: - LibraryView
// Row-based dashboard. Favorites and Radio rows share favoriteIDs state
// so toggling a heart anywhere updates all views instantly.
// Radio row is now DB-driven — stations come from the stations table,
// seeded via Settings → Services → iHeart.

struct LibraryView: View {
    @ObservedObject var discovery: ZoneDiscoveryService
    let onPlayStation: (RadioStation, SonosZone) -> Void
    let onNavigateToZone: (String) -> Void
    @EnvironmentObject private var tabState: SorrivaTabBarState

    @State private var favoriteIDs: Set<Int> = []
    @State private var loadedLogos: [Int: String] = [:]
    @State private var showFavoritesGrid = false
    @State private var showRadioGrid = false
    @State private var showAlbums = false
    @State private var showArtists = false
    @State private var showTracks = false
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var tracks: [Track] = []

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

                // Playlists — stub
                LibraryRow(title: "Playlists", onSeeAll: {}) {
                    HStack {
                        Text("Create a playlist to get started")
                            .font(.system(size: 13))
                            .foregroundColor(.sTextMuted)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                        Spacer()
                    }
                }

                // Albums
                if !albums.isEmpty {
                    LibraryRow(title: "Albums", onSeeAll: { showAlbums = true }) {
                        LibraryMediaRow(items: Array(albums.prefix(20).map {
                            LibraryMediaItem(id: $0.id, title: $0.title, subtitle: $0.artistName, album: $0)
                        }), onSeeAll: { showAlbums = true })
                    }
                }

                // Artists
                if !artists.isEmpty {
                    LibraryRow(title: "Artists", onSeeAll: { showArtists = true }) {
                        LibraryArtistRow(artists: Array(artists.prefix(20)),
                                         onSeeAll: { showArtists = true })
                    }
                }

                // Tracks
                if !tracks.isEmpty {
                    LibraryRow(title: "Tracks", onSeeAll: { showTracks = true }) {
                        LibraryMediaRow(items: Array(tracks.prefix(20).map {
                            LibraryMediaItem(id: $0.id, title: $0.title, subtitle: $0.artistName, track: $0)
                        }), onSeeAll: { showTracks = true })
                    }
                }

                Spacer().frame(height: 48)
            }
        }
        .background(Color.clear)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { oldY, newY in
            let delta = newY - oldY
            if delta > 8 { tabState.hide() }
            else if delta < -8 { tabState.show() }
        }
        .onAppear {
            loadFavorites()
            loadLibrary()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidUpdate)) { _ in
            loadLibrary()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stationsDidUpdate)) { _ in
            loadFavorites()
        }
        .navigationDestination(isPresented: $showAlbums) { AlbumsView() }
        .navigationDestination(isPresented: $showArtists) { ArtistsView() }
        .navigationDestination(isPresented: $showTracks) { TracksView() }
        .navigationDestination(isPresented: $showFavoritesGrid) {
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
        .navigationDestination(isPresented: $showRadioGrid) {
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

    private func loadLibrary() {
        albums  = (try? SorrivaDatabase.shared.allAlbums()) ?? []
        artists = (try? SorrivaDatabase.shared.allArtists()) ?? []
        tracks  = (try? SorrivaDatabase.shared.allTracks()) ?? []
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
    @State private var showRemoveStation = false

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
                    },
                    onRemove: {
                        showActionSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showRemoveStation = true
                        }
                    }
                )
                .presentationDetents([.height(340)])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.sCard)
            }
        }
        .alert("Remove \"\(displayName)\"?", isPresented: $showRemoveStation) {
            Button("Remove", role: .destructive) {
                Task {
                    try? SorrivaDatabase.shared.deleteStation(id: displayID)
                    NotificationCenter.default.post(name: .stationsDidUpdate, object: nil)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the station from your Sorriva library.")
        }
        .sheet(item: $zonePickerStation) { rs in
            ZonePickerSheet(
                title: rs.name,
                subtitle: "iHeartRADIO",
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
    let onRemove: () -> Void

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

                Divider().background(Color.sSeparator).padding(.leading, 56)

                ActionRow(
                    icon: "trash",
                    iconColor: .red,
                    title: "Remove from Library",
                    action: onRemove
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
    @EnvironmentObject private var tabState: SorrivaTabBarState

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
        .navigationBarHidden(true)
        .onAppear {
            tabState.show()
            loadFromDB()
        }
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

// MARK: - LibraryMediaItem

struct LibraryMediaItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    var album: Album? = nil
    var track: Track? = nil
}

// MARK: - LibraryMediaRow

struct LibraryMediaRow: View {
    let items: [LibraryMediaItem]
    let onSeeAll: () -> Void
    @EnvironmentObject private var discovery: ZoneDiscoveryService
    @State private var itemToRemove: LibraryMediaItem? = nil
    @State private var showRemoveConfirm = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(items) { item in
                    Group {
                        if let album = item.album {
                            NavigationLink(destination:
                                AlbumDetailView(album: album)
                                    .environmentObject(discovery)
                            ) {
                                LibraryMediaCard(item: item)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button { } label: {
                                LibraryMediaCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .sorrivaContextMenu(
                        title: item.title,
                        subtitle: item.subtitle,
                        album: item.album,
                        actions: item.album != nil
                            ? SorrivaContextActions.album(item.album!) {
                                itemToRemove = item
                                showRemoveConfirm = true
                              }
                            : SorrivaContextActions.track(item.track!) {
                                itemToRemove = item
                                showRemoveConfirm = true
                              },
                        sheetHeight: item.album != nil ? 280 : 260
                    )
                }
            }
            .padding(.horizontal, 20)
        }
        .alert("Remove \"\(itemToRemove?.title ?? "")\"?", isPresented: $showRemoveConfirm) {
            Button("Remove", role: .destructive) { removeItem(itemToRemove); itemToRemove = nil }
            Button("Cancel", role: .cancel) { itemToRemove = nil }
        } message: {
            Text("This removes it from your Sorriva library. The original file is not affected.")
        }
    }

    private func removeItem(_ item: LibraryMediaItem?) {
        guard let item else { return }
        if let album = item.album {
            try? SorrivaDatabase.shared.deleteTracks(sourceId: album.sourceId)
            try? SorrivaDatabase.shared.deleteOrphanedAlbums()
            try? SorrivaDatabase.shared.deleteOrphanedArtists()
        } else if let track = item.track {
            try? SorrivaDatabase.shared.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [track.id])
            }
        }
        NotificationCenter.default.post(name: .libraryDidUpdate, object: nil)
    }
}

// MARK: - LibraryMediaCard

struct LibraryMediaCard: View {
    let item: LibraryMediaItem
    private let size: CGFloat = 90

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            if let album = item.album {
                AlbumArtView(album: album, size: size)
            } else {
                AlbumArtPlaceholder(
                    letter: item.title.first.map(String.init) ?? "?",
                    size: size
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(item.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.sTextPrimary)
                .lineLimit(1)
                .frame(width: size)
            Text(item.subtitle)
                .font(.system(size: 10))
                .foregroundColor(.sTextMuted)
                .lineLimit(1)
                .frame(width: size)
        }
        .frame(width: size)
    }
}

// MARK: - LibraryArtistRow

struct LibraryArtistRow: View {
    let artists: [Artist]
    let onSeeAll: () -> Void
    @State private var selectedArtist: Artist? = nil
    @State private var artistToRemove: Artist? = nil
    @State private var showRemoveConfirm = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(artists) { artist in
                    Button {
                        selectedArtist = artist
                    } label: {
                        VStack(spacing: 6) {
                            ArtistAvatarView(artist: artist, size: 90)
                            Text(artist.name)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.sTextPrimary)
                                .lineLimit(1)
                                .frame(width: 90)
                            Text("\(artist.albumCount) \(artist.albumCount == 1 ? "album" : "albums")")
                                .font(.system(size: 10))
                                .foregroundColor(.sTextMuted)
                                .lineLimit(1)
                                .frame(width: 90)
                        }
                        .frame(width: 90)
                    }
                    .buttonStyle(.plain)
                    .sorrivaContextMenu(
                                    title: artist.name,
                                    subtitle: "\(artist.albumCount) \(artist.albumCount == 1 ? "album" : "albums")",
                                    actions: SorrivaContextActions.artist(artist) {
                                        artistToRemove = artist
                                        showRemoveConfirm = true
                                    },
                                    sheetHeight: 250
                                )
                }
            }
            .padding(.horizontal, 20)
        }
        .sheet(item: $selectedArtist) { artist in
            NavigationView {
                ArtistDetailView(artist: artist)
            }
            .navigationViewStyle(.stack)
        }
        .alert("Remove \"\(artistToRemove?.name ?? "")\"?",
               isPresented: $showRemoveConfirm) {
            Button("Remove", role: .destructive) {
                if let artist = artistToRemove {
                    try? SorrivaDatabase.shared.dbQueue.write { db in
                        try db.execute(sql: "DELETE FROM tracks WHERE primaryArtistId = ?", arguments: [artist.id])
                        try db.execute(sql: "DELETE FROM albums WHERE primaryArtistId = ?", arguments: [artist.id])
                        try db.execute(sql: "DELETE FROM artists WHERE id = ?", arguments: [artist.id])
                    }
                    NotificationCenter.default.post(name: .libraryDidUpdate, object: nil)
                }
                artistToRemove = nil
            }
            Button("Cancel", role: .cancel) { artistToRemove = nil }
        } message: {
            Text("This removes the artist and all their albums and tracks from your Sorriva library. Original files are not affected.")
        }
    }
}
