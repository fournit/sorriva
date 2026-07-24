import SwiftUI

// MARK: - SomaFMServiceView
// SomaFM service management screen.
// 46 channels — load all at once, no pagination needed.
// No account required. Public API: https://api.somafm.com/channels.json
// Stream format: x-rincon-mp3radio://ice{N}.somafm.com/{id}-128-aac
// lastPlaying field gives live track info — pollable even when paused.

struct SomaFMServiceView: View {
    @State private var stations: [Station] = []
    @State private var showBrowser = false
    @State private var zonePickerStation: RadioStation? = nil
    @State private var stationToRemove: Station? = nil
    @State private var showRemoveConfirm = false

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
                            .fill(Color(hex: "#2C3E50"))
                            .frame(width: 52, height: 52)
                        Text("SF")
                            .font(.system(size: 18, weight: .black))
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SomaFM")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                        Text(stations.isEmpty
                             ? "No account required · 46 channels"
                             : "\(stations.count) channel\(stations.count == 1 ? "" : "s") · No account required")
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
                        Text("No channels added yet")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                        Text("Browse SomaFM's curated catalog of commercial-free channels.")
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
                                    .sorrivaContextMenu(
                                        title: station.name,
                                        subtitle: "SomaFM",
                                        imageURL: station.logoURL,
                                        actions: SorrivaContextActions.radioStation(
                                            isFavorite: station.isFavorite,
                                            onFavorite: {
                                                _ = try? SorrivaDatabase.shared.toggleFavorite(stationId: station.id)
                                                NotificationCenter.default.post(name: .stationsDidUpdate, object: nil)
                                                loadStations()
                                            },
                                            onPlayOn: {
                                                zonePickerStation = RadioStation(from: station)
                                            },
                                            onRemove: {
                                                stationToRemove = station
                                                showRemoveConfirm = true
                                            }
                                        ),
                                        sheetHeight: 310
                                    )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                    }
                }

                // Browse button
                NavigationLink(destination: SomaFMBrowserView()
                    .onDisappear { loadStations() }
                ) {
                    HStack {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 16, weight: .semibold))
                        Text(stations.isEmpty ? "Browse Channels" : "Browse & Add More")
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
        .navigationTitle("SomaFM")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.sGradientTop, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { loadStations() }
        .onReceive(NotificationCenter.default.publisher(for: .stationsDidUpdate)) { _ in
            loadStations()
        }
        .alert("Remove \"\(stationToRemove?.name ?? "")\"?",
               isPresented: $showRemoveConfirm) {
            Button("Remove", role: .destructive) {
                if let station = stationToRemove {
                    do {
                        try SorrivaDatabase.shared.removeStation(id: station.id)
                        withAnimation { stations.removeAll { $0.id == station.id } }
                        NotificationCenter.default.post(name: .stationsDidUpdate, object: nil)
                    } catch {
                        print("SOMA: remove failed — \(error)")
                    }
                }
                stationToRemove = nil
            }
            Button("Cancel", role: .cancel) { stationToRemove = nil }
        } message: {
            Text("This removes the station from your Sorriva library.")
        }
        .sheet(item: $zonePickerStation) { rs in
            ZonePickerSheet(title: rs.name, subtitle: "SomaFM", discovery: discovery, store: PlaybackStore.shared) { zone in
                zonePickerStation = nil
                Task {
                    var streamURL = try? SorrivaDatabase.shared.cachedStreamURL(stationId: rs.id)
                    if streamURL == nil {
                        streamURL = await SomaFMAPI.fetchStreamURL(channelID: rs.name)
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
        stations = (try? SorrivaDatabase.shared.allStations(source: "somafm")) ?? []
    }
}

// MARK: - SomaFMBrowserView
// Loads all 46 SomaFM channels at once — small catalog, instant load.
// Shows channel art, name, description, genre, listener count.
// Search bar + genre chips. Sort by Popular (listeners) or A-Z.

struct SomaFMBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var allChannels: [SomaFMChannel] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String? = nil
    @State private var searchText = ""
    @State private var selectedGenre: String? = nil
    @State private var sortMode: SortMode = .popular
    @State private var selectedIDs: Set<Int> = []
    @State private var existingIDs: Set<Int> = []
    @State private var searchTask: Task<Void, Never>? = nil

    private var availableGenres: [String] {
        var genres = Set<String>()
        for channel in allChannels {
            for g in channel.genres { genres.insert(g) }
        }
        return genres.sorted()
    }

    private var displayChannels: [SomaFMChannel] {
        var result = allChannels
        if let genre = selectedGenre {
            result = result.filter { $0.genres.contains(genre) }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText) ||
                $0.genres.joined(separator: " ").localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortMode {
        case .popular: return result.sorted { $0.listeners > $1.listeners }
        case .alpha:   return result.sorted { $0.title < $1.title }
        }
    }

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
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.sHighlight)
                            .scaleEffect(1.2)
                        Text("Loading SomaFM channels…")
                            .font(.system(size: 14))
                            .foregroundColor(.sTextMuted)
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
                        Button("Try again") { loadChannels() }
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
                        TextField("Search \(allChannels.count) channels", text: $searchText)
                            .font(.system(size: 14))
                            .foregroundColor(.sTextPrimary)
                            .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
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
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                    // Genre chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            GenreChip(label: "All", isSelected: selectedGenre == nil) {
                                selectedGenre = nil
                            }
                            ForEach(availableGenres, id: \.self) { genre in
                                GenreChip(label: genre.capitalized, isSelected: selectedGenre == genre) {
                                    selectedGenre = selectedGenre == genre ? nil : genre
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 8)

                    // Count
                    HStack {
                        Text("\(displayChannels.count) channel\(displayChannels.count == 1 ? "" : "s")")
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
                            ForEach(displayChannels) { channel in
                                SomaFMChannelCell(
                                    channel: channel,
                                    isSelected: selectedIDs.contains(channel.numericID),
                                    isAlreadyAdded: existingIDs.contains(channel.numericID),
                                    onTap: { toggleChannel(channel) }
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
                    Button(action: saveSelectedChannels) {
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
                                 ? "Add \(selectedCount) Channel\(selectedCount == 1 ? "" : "s")"
                                 : "Select channels to add")
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
        .navigationTitle("Browse SomaFM")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.sGradientTop, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !isLoading {
                    Button(action: {
                        sortMode = sortMode == .popular ? .alpha : .popular
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
            existingIDs = Set((try? SorrivaDatabase.shared.allStations(source: "somafm"))?.map { $0.id } ?? [])
            loadChannels()
        }
    }

    private func loadChannels() {
        isLoading = true
        errorMessage = nil
        Task {
            let channels = await SomaFMAPI.fetchChannels()
            await MainActor.run {
                if channels.isEmpty {
                    errorMessage = "Could not load SomaFM channels."
                } else {
                    allChannels = channels
                }
                isLoading = false
            }
        }
    }

    private func toggleChannel(_ channel: SomaFMChannel) {
        guard !existingIDs.contains(channel.numericID) else { return }
        if selectedIDs.contains(channel.numericID) {
            selectedIDs.remove(channel.numericID)
        } else {
            selectedIDs.insert(channel.numericID)
        }
    }

    private func saveSelectedChannels() {
        guard hasSelection else { return }
        isSaving = true
        let toSave = allChannels.filter { selectedIDs.contains($0.numericID) }

        Task {
            for channel in toSave {
                try? SorrivaDatabase.shared.upsertStation(
                    id: channel.numericID,
                    source: "somafm",
                    name: channel.title,
                    logoURL: channel.largeImage,
                    streamURL: channel.streamURL,
                    cume: channel.listeners
                )
                print("SORRIVA: Saved SomaFM \(channel.id) \(channel.title)")
            }
            NotificationCenter.default.post(name: .stationsDidUpdate, object: nil)
            await MainActor.run {
                isSaving = false
                dismiss()
            }
        }
    }
}

// MARK: - SomaFMChannelCell

struct SomaFMChannelCell: View {
    let channel: SomaFMChannel
    let isSelected: Bool
    let isAlreadyAdded: Bool
    let onTap: () -> Void
    @State private var cachedImage: UIImage? = nil

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Group {
                    if let img = cachedImage {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.sCard)
                            .overlay(Image(systemName: "radio").font(.system(size: 18)).foregroundColor(.sTextMuted))
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.sTextPrimary)
                        .lineLimit(1)
                    Text(channel.description)
                        .font(.system(size: 12))
                        .foregroundColor(.sTextMuted)
                        .lineLimit(1)
                    if !channel.lastPlaying.isEmpty {
                        Text(channel.lastPlaying)
                            .font(.system(size: 11))
                            .foregroundColor(.sHighlight)
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
        .onAppear { loadFromCache() }
    }

    private func loadFromCache() {
        guard !channel.largeImage.isEmpty,
              let url = URL(string: channel.largeImage) else { return }
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
