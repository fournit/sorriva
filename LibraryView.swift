import SwiftUI

// MARK: - LibraryView
// Row-based dashboard. Favorites and Radio rows share favoriteIDs state
// so toggling a heart anywhere updates all views instantly.

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

                // Radio row
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
        .onAppear { loadFavorites() }
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
        let stations = (try? SorrivaDatabase.shared.allStations()) ?? []
        favoriteIDs = Set(stations.filter { $0.isFavorite }.map { $0.id })
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
            // Section title — tappable, same as See All
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

struct FavoritesRow: View {
    @Binding var favoriteIDs: Set<Int>
    @Binding var loadedLogos: [Int: String]
    @ObservedObject var discovery: ZoneDiscoveryService
    let onPlayStation: (RadioStation, SonosZone) -> Void
    let onNavigateToZone: (String) -> Void
    let onFavoriteToggled: (Int, Bool) -> Void

    private var favoriteStations: [RadioStation] {
        RadioStation.catalog.filter { favoriteIDs.contains($0.id) }
    }

    var body: some View {
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
                            logoURL: loadedLogos[station.id] ?? "",
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
}

// MARK: - RadioRow

struct RadioRow: View {
    @Binding var favoriteIDs: Set<Int>
    @Binding var loadedLogos: [Int: String]
    @ObservedObject var discovery: ZoneDiscoveryService
    let onPlayStation: (RadioStation, SonosZone) -> Void
    let onNavigateToZone: (String) -> Void
    let onFavoriteToggled: (Int, Bool) -> Void

    @State private var loadedStreamURLs: [Int: String] = [:]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(RadioStation.catalog, id: \.id) { station in
                    MediaCard(
                        radioStation: station,
                        logoURL: loadedLogos[station.id] ?? "",
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
        .onAppear { loadFromDB(); fetchMetadata() }
    }

    private func loadFromDB() {
        let stations = (try? SorrivaDatabase.shared.allStations()) ?? []
        for s in stations {
            if let logo = s.logoURL { loadedLogos[s.id] = logo }
            if let url = s.streamURL { loadedStreamURLs[s.id] = url }
        }
    }

    private func fetchMetadata() {
        for station in RadioStation.catalog {
            guard loadedLogos[station.id] == nil else { continue }
            Task {
                if let logo = await IHeartAPI.fetchStationLogo(streamID: station.id) {
                    loadedLogos[station.id] = logo
                    try? SorrivaDatabase.shared.upsertStation(
                        id: station.id, source: "iheart",
                        name: station.name, logoURL: logo, streamURL: nil)
                }
                if loadedStreamURLs[station.id] == nil,
                   let url = await IHeartAPI.fetchStreamURL(streamID: station.id) {
                    loadedStreamURLs[station.id] = url
                    try? SorrivaDatabase.shared.upsertStation(
                        id: station.id, source: "iheart",
                        name: station.name, logoURL: loadedLogos[station.id], streamURL: url)
                }
            }
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
            // Art with favorite indicator + UIKit context menu (no first-render lag)
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
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Bare brass heart — favorite indicator
                if localFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.sBrass)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                        .padding(6)
                }
            }
            .onTapGesture { zonePickerStation = radioStation }
            .onLongPressGesture(minimumDuration: 0.4) {
                showActionSheet = true
            }

            // Name only
            Text(displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.sTextPrimary)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
        }
        .onAppear { localFavorite = isFavorite }
        .onChange(of: isFavorite) { localFavorite = $0 }
        // Action sheet — instant appearance, no context menu init cost
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
        // sheet(item:) — sheet only constructed when item is non-nil, no pre-warm hack needed
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
            }
        }
    }
}

// MARK: - StationActionSheet
// Compact bottom sheet on long press — instant appearance, no context menu lag.
// Shows station art + name in header, action rows below.

struct StationActionSheet: View {
    let station: RadioStation
    let logoURL: String
    let isFavorite: Bool
    let onFavorite: () -> Void
    let onPlayOn: () -> Void

    var body: some View {
        VStack(spacing: 0) {

            // Header — art + name + source
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

            // Actions
            VStack(spacing: 0) {
                // Favorite
                ActionRow(
                    icon: isFavorite ? "heart.fill" : "heart",
                    iconColor: isFavorite ? .sBrass : .sTextPrimary,
                    title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    action: onFavorite
                )

                Divider().background(Color.sSeparator).padding(.leading, 56)

                // Play on
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

    private var displayStations: [RadioStation] {
        switch filter {
        case .radio: return RadioStation.catalog
        case .favorites: return RadioStation.catalog.filter { favoriteIDs.contains($0.id) }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color.sGradientTop, Color.sGradientBottom],
                          startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            VStack(spacing: 0) {
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
                .padding(.bottom, 16)

                if displayStations.isEmpty {
                    Spacer()
                    Text("No favorites yet\nHeart a station to add it here")
                        .font(.system(size: 15))
                        .foregroundColor(.sTextMuted)
                        .multilineTextAlignment(.center)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 16),
                            GridItem(.flexible(), spacing: 16)
                        ], spacing: 20) {
                            ForEach(displayStations, id: \.id) { rs in
                                MediaCard(
                                    radioStation: rs,
                                    logoURL: loadedLogos[rs.id] ?? "",
                                    isFavorite: favoriteIDs.contains(rs.id),
                                    discovery: discovery,
                                    onPlayStation: onPlayStation,
                                    onNavigateToZone: onNavigateToZone,
                                    onFavoriteToggled: onFavoriteToggled
                                )
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                    }
                }
            }
        }
    }
}
