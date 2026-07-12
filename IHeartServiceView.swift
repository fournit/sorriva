import SwiftUI

// MARK: - IHeartServiceView
// iHeart Radio service management screen.
// Stations displayed as cards — same pattern as Zones/Library.
// Long press → bottom action sheet (Remove, Favorite, Play on).
// Zero List usage — no compositing issues, consistent with app patterns.

struct IHeartServiceView: View {
    @State private var stations: [Station] = []
    @State private var actionStation: Station? = nil
    @State private var zonePickerStation: RadioStation? = nil

    @ObservedObject var discovery: ZoneDiscoveryService
    let onPlayStation: (RadioStation, SonosZone) -> Void
    let onNavigateToZone: (String) -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {

                // Service header
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color(hex: "#CC2027"))
                            .frame(width: 52, height: 52)
                        Image(systemName: "radio")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("iHeartRADIO")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                        Text(stations.isEmpty
                             ? "No account required"
                             : "\(stations.count) station\(stations.count == 1 ? "" : "s") · No account required")
                            .font(.system(size: 13))
                            .foregroundColor(.sTextMuted)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 16)

                if stations.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 36))
                            .foregroundColor(.sTextMuted)
                        Text("No stations added yet")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                        Text("Browse the iHeart catalog to add stations to your library.")
                            .font(.system(size: 13))
                            .foregroundColor(.sTextMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(stations, id: \.id) { station in
                                SavedStationCard(station: station)
                                    .onLongPressGesture(minimumDuration: 0.4) {
                                        actionStation = station
                                    }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                    }
                }

                // Browse button
                NavigationLink(destination: IHeartStationBrowserView()
                    .onDisappear { loadStations() }
                ) {
                    HStack {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 16, weight: .semibold))
                        Text(stations.isEmpty ? "Browse Stations" : "Browse & Add More")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.sAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("iHeartRADIO")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.sGradientTop, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { loadStations() }
        .onReceive(NotificationCenter.default.publisher(for: .stationsDidUpdate)) { _ in
            loadStations()
        }
        // Action sheet — long press on station card
        .sheet(item: $actionStation) { station in
            SavedStationActionSheet(
                station: station,
                onRemove: {
                    actionStation = nil
                    try? SorrivaDatabase.shared.removeStation(id: station.id)
                    withAnimation { stations.removeAll { $0.id == station.id } }
                    NotificationCenter.default.post(name: .stationsDidUpdate, object: nil)
                },
                onFavorite: {
                    actionStation = nil
                    _ = try? SorrivaDatabase.shared.toggleFavorite(stationId: station.id)
                    loadStations()
                },
                onPlayOn: {
                    actionStation = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        zonePickerStation = RadioStation(from: station)
                    }
                }
            )
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.sCard)
        }
        // Zone picker
        .sheet(item: $zonePickerStation) { rs in
            ZonePickerSheet(station: rs, discovery: discovery) { zone in
                zonePickerStation = nil
                Task {
                    var streamURL = try? SorrivaDatabase.shared.cachedStreamURL(stationId: rs.id)
                    if streamURL == nil {
                        streamURL = await IHeartAPI.fetchStreamURL(streamID: rs.id)
                    }
                    guard let url = streamURL else { return }
                    await ZoneDiscoveryService.playStationURL(
                        streamURL: url, on: zone,
                        stationName: rs.name, artURL: rs.logoURL)
                    discovery.persistStationPlay(
                        zone: zone, stationId: rs.id,
                        stationName: rs.name, logoURL: rs.logoURL)
                    discovery.triggerRefresh()
                    onPlayStation(rs, zone)
                    onNavigateToZone(zone.id)
                }
            }
        }

    }

    private func loadStations() {
        stations = (try? SorrivaDatabase.shared.allStations(source: "iheart")) ?? []
    }
}

// MARK: - SavedStationCard
// Station card — same visual language as zone cards.
// Logo + name + favorite indicator. Long press for actions.

struct SavedStationCard: View {
    let station: Station
    @State private var cachedImage: UIImage? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Logo
            Group {
                if let img = cachedImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.sCard)
                        .overlay(
                            Image(systemName: "radio")
                                .font(.system(size: 18))
                                .foregroundColor(.sTextMuted)
                        )
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Name + favorite badge
            VStack(alignment: .leading, spacing: 3) {
                Text(station.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.sTextPrimary)
                    .lineLimit(1)
                if station.isFavorite {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.sBrass)
                        Text("Favorited")
                            .font(.system(size: 11))
                            .foregroundColor(.sBrass)
                    }
                }
            }

            Spacer()

            Image(systemName: "ellipsis")
                .font(.system(size: 14))
                .foregroundColor(.sTextMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { loadFromCache() }
    }

    private func loadFromCache() {
        guard let logoURL = station.logoURL,
              !logoURL.isEmpty,
              let url = URL(string: logoURL) else { return }
        let request = URLRequest(url: url)
        if let cached = URLCache.shared.cachedResponse(for: request),
           let img = UIImage(data: cached.data) {
            cachedImage = img
            return
        }
        Task {
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let img = UIImage(data: data) {
                URLCache.shared.storeCachedResponse(
                    CachedURLResponse(response: response, data: data), for: request)
                await MainActor.run { cachedImage = img }
            }
        }
    }
}

// MARK: - SavedStationActionSheet
// Bottom sheet on long press — Remove, Favorite toggle, Play on.

struct SavedStationActionSheet: View {
    let station: Station
    let onRemove: () -> Void
    let onFavorite: () -> Void
    let onPlayOn: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                Group {
                    if let logoURL = station.logoURL,
                       !logoURL.isEmpty,
                       let url = URL(string: logoURL) {
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
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(station.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.sTextPrimary)
                    Text("iHeartRADIO")
                        .font(.system(size: 12))
                        .foregroundColor(.sTextMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().background(Color.sSeparator)

            // Actions
            VStack(spacing: 0) {
                ActionRow(
                    icon: station.isFavorite ? "heart.fill" : "heart",
                    iconColor: station.isFavorite ? .sBrass : .sTextPrimary,
                    title: station.isFavorite ? "Remove from Favorites" : "Add to Favorites",
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
