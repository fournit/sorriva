import SwiftUI

// MARK: - SonosFavoriteServiceView
//
// The detail screen for a service Sorriva reaches through Sonos favorites —
// SiriusXM, Sonos Radio, Spotify. One view serves all of them: the only thing that
// varies is the descriptor.
//
// WHY THESE SERVICES ARE DIFFERENT. iHeart and SomaFM have real browsers because
// Sorriva can address them directly — it stores stream URLs and plays them itself.
// These cannot be browsed at all: their catalogues are closed, and the household's
// saved favorites are the only handle that exists. So the "browse" here is your own
// Sonos favorites list, and adding something new means saving it in the Sonos app
// first. See fSonosFavoritesAsSource and sonos-playback-contract.md §11.
//
// SELECTION IS THE POINT. A household's favorites accumulate for every room and
// every listener; the library should hold what this user wants, not all of them.

/// What varies between one favorites-backed service and another. Presentation is
/// designed per service rather than generated — an icon and a colour are decisions,
/// not data — while CONNECTED/AVAILABLE state is derived from whether stations exist.
struct FavoriteServiceDescriptor: Identifiable, Equatable {
    let id: String              // matches services.id
    let name: String            // "SiriusXM"
    let sonosServiceId: Int     // sid in a favorite's URI — the reliable match
    let icon: String
    let color: Color
    let blurb: String           // shown when the service has nothing yet

    static let siriusXM = FavoriteServiceDescriptor(
        id: "siriusxm", name: "SiriusXM", sonosServiceId: 37,
        icon: "dot.radiowaves.left.and.right", color: Color(hex: "#0000EB"),
        blurb: "Your saved SiriusXM channels, played through your Sonos subscription")

    static let sonosRadio = FavoriteServiceDescriptor(
        id: "sonosradio", name: "Sonos Radio", sonosServiceId: 303,
        icon: "waveform", color: Color(hex: "#1B1B1B"),
        blurb: "Sonos Radio stations you have saved as favorites")

    static let spotify = FavoriteServiceDescriptor(
        id: "spotify", name: "Spotify", sonosServiceId: 12,
        icon: "music.note.list", color: Color(hex: "#1DB954"),
        blurb: "Playlists you have saved as Sonos favorites")

    static let all: [FavoriteServiceDescriptor] = [.siriusXM, .sonosRadio, .spotify]
}

struct SonosFavoriteServiceView: View {

    let descriptor: FavoriteServiceDescriptor
    @ObservedObject var discovery: ZoneDiscoveryService

    private enum LoadState: Equatable {
        case loading
        case ready
        /// Reached the system, but this service has nothing saved.
        case noneForService
        /// Could not reach ANY speaker. Deliberately distinct from the above: telling
        /// someone to go save favorites they already have is the worse mistake.
        case unreachable
    }

    @State private var state: LoadState = .loading
    @State private var favorites: [SonosFavorite] = []
    @State private var selected: Set<String> = []      // by URI
    @State private var householdId: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LinearGradient(colors: [.sGradientTop, .sGradientMid, .sGradientBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            switch state {
            case .loading:    loadingView
            case .unreachable: message(
                    icon: "wifi.exclamationmark",
                    title: "Can't reach your Sonos system",
                    detail: "No speaker answered. Check you're on the same network as your Sonos, then try again.")
            case .noneForService: message(
                    icon: descriptor.icon,
                    title: "Nothing saved yet",
                    detail: "Save \(descriptor.name) content as a favorite in the Sonos app, then come back. "
                          + "Sorriva can play what your household has saved, but cannot browse \(descriptor.name) itself.")
            case .ready:      list
            }
        }
        .navigationTitle(descriptor.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if state == .ready {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "Saving…" : "Save") { save() }
                        .disabled(saving)
                }
            }
        }
        .task { await load() }
    }

    // MARK: - Pieces

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.sTextMuted)
            Text("Reading your Sonos favorites…")
                .font(.system(size: 14)).foregroundColor(.sTextMuted)
        }
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40)).foregroundColor(.sTextMuted)
            Text(title)
                .font(.system(size: 18, weight: .semibold)).foregroundColor(.sTextPrimary)
            Text(detail)
                .font(.system(size: 14)).foregroundColor(.sTextMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { Task { await load() } }
                .font(.system(size: 15, weight: .medium))
                .padding(.top, 4)
        }
        .padding(.horizontal, 40)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ServiceHeaderCard(name: descriptor.name,
                                  subtitle: "\(selected.count) of \(favorites.count) in your library") {
                    Image(systemName: descriptor.icon)
                        .font(.system(size: 26))
                        .foregroundColor(descriptor.color)
                        .frame(width: 56, height: 56)
                        .background(Color.sSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text("Tap to choose what appears in your library.")
                    .font(.system(size: 13)).foregroundColor(.sTextMuted)
                    .padding(.horizontal, 16).padding(.bottom, 4)

                ForEach(favorites, id: \.uri) { fav in
                    Button { toggle(fav) } label: { row(fav) }.buttonStyle(.plain)
                }
            }
            .padding(.bottom, 48)
        }
    }

    private func row(_ fav: SonosFavorite) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selected.contains(fav.uri) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundColor(selected.contains(fav.uri) ? descriptor.color : .sTextMuted)
            Text(fav.title)
                .font(.system(size: 16)).foregroundColor(.sTextPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
        }
        .padding(14)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    // MARK: - Behaviour

    private func toggle(_ fav: SonosFavorite) {
        if selected.contains(fav.uri) { selected.remove(fav.uri) } else { selected.insert(fav.uri) }
    }

    private func load() async {
        state = .loading
        // Every known zone is a candidate, because not every speaker answers
        // ContentDirectory — see SonosFavorites.read.
        let hosts = discovery.zones.map(\.host)
        guard !hosts.isEmpty else { state = .unreachable; return }

        switch await SonosFavorites.read(hosts: hosts) {
        case .noSpeakerAnswered:
            state = .unreachable
        case .ok(let all, let household):
            householdId = household
            favorites = all.filter { $0.sonosServiceId == descriptor.sonosServiceId }
            // Pre-tick whatever is already in the library for this household, so the
            // screen shows the current state rather than an empty slate every time.
            // Pre-tick by CHANNEL, not by URI. A station imported at another house
            // carries that household's account handle in its stored URI, so comparing
            // full URIs would show it unticked here and invite a duplicate.
            let inLibrary = (try? SorrivaDatabase.shared.allStations(serviceId: descriptor.id)) ?? []
            let known = Set(inLibrary.compactMap { $0.streamURL }
                                     .map(SonosFavorites.channelIdentity(of:)))
            selected = Set(favorites.map(\.uri)
                                    .filter { known.contains(SonosFavorites.channelIdentity(of: $0)) })
            state = favorites.isEmpty ? .noneForService : .ready
        }
    }

    private func save() {
        guard let household = householdId else { return }
        saving = true
        let chosen = favorites.filter { selected.contains($0.uri) }
        do {
            try SorrivaDatabase.shared.importFavorites(chosen, householdId: household)
            try SorrivaDatabase.shared.removeDeselectedFavorites(
                serviceId: descriptor.id,
                offered: Set(favorites.map(\.uri)),
                keeping: selected)
            NotificationCenter.default.post(name: .stationsDidUpdate, object: nil)
            dismiss()
        } catch {
            sLog("FAVORITES: save failed for \(descriptor.name) — \(error.localizedDescription)")
        }
        saving = false
    }
}

// MARK: - Favorites as a setup source
//
// The favorites-backed services adopting the shared setup screen. Everything
// service-specific lives here; the screen itself knows nothing about SiriusXM.

@MainActor
struct SonosFavoritesSetupSource: ServiceSetupSource {

    let descriptor: FavoriteServiceDescriptor
    let discovery: ZoneDiscoveryService

    var serviceName: String { descriptor.name }
    var icon: String { descriptor.icon }
    var color: Color { descriptor.color }

    /// Sonos favorites carry no audience figure, so the list is always alphabetical.
    var supportsPopularity: Bool { false }

    var emptyMessage: String {
        "Save \(descriptor.name) content as a favorite in the Sonos app, then come back. "
        + "Sorriva plays what your household has saved, but cannot browse \(descriptor.name) itself."
    }

    /// Keyed by CHANNEL IDENTITY so a favorite saved at another house matches the row
    /// already in the library — the URIs differ by an account handle the speaker ignores.
    private static var byIdentity: [String: SonosFavorite] = [:]

    /// A household's favorites for one service are a short list; nothing to filter by.
    var chips: [ServiceSetupChip] { get async { [] } }

    func load(query: String, chip: String?) async throws -> (available: [ServiceSetupItem], inLibrary: Set<String>) {
        let hosts = discovery.zones.map(\.host)
        guard !hosts.isEmpty else { throw SonosSOAPError.badHost("no zones discovered") }

        switch await SonosFavorites.read(hosts: hosts) {
        case .noSpeakerAnswered:
            // Distinct from an empty household: telling someone to go save favorites
            // they already have is the worse mistake.
            throw SonosSOAPError.badHost("no speaker answered")

        case .ok(let all, _):
            var mine = all.filter { $0.sonosServiceId == descriptor.sonosServiceId }
            if !query.isEmpty {
                mine = mine.filter { $0.title.localizedCaseInsensitiveContains(query) }
            }
            for f in mine { Self.byIdentity[SonosFavorites.channelIdentity(of: f.uri)] = f }

            let items = mine.map {
                ServiceSetupItem(id: SonosFavorites.channelIdentity(of: $0.uri),
                                 title: $0.title,
                                 subtitle: descriptor.name,
                                 artURL: $0.artURL,
                                 popularity: nil)
            }
            let stored = (try? SorrivaDatabase.shared.allStations(serviceId: descriptor.id)) ?? []
            let library = Set(stored.compactMap { $0.streamURL }
                                    .map(SonosFavorites.channelIdentity(of:)))
            return (items, library)
        }
    }

    func add(_ item: ServiceSetupItem) async throws {
        guard let fav = Self.byIdentity[item.id] else { return }
        let hosts = discovery.zones.map(\.host)
        let household = await hosts.firstNonNilHouseholdId() ?? "unknown"
        try SorrivaDatabase.shared.importFavorites([fav], householdId: household)
    }

    func remove(_ item: ServiceSetupItem) async throws {
        // Scoped to this one channel. Removing "everything not selected" would delete
        // channels favorited only at another location — absent is not deselected.
        try SorrivaDatabase.shared.removeDeselectedFavorites(
            serviceId: descriptor.id, offered: [item.id], keeping: [])
    }
}

private extension Array where Element == String {
    /// First host that will tell us its household. Not every speaker answers.
    func firstNonNilHouseholdId() async -> String? {
        for host in self {
            if let id = await SonosCommands.householdId(host: host) { return id }
        }
        return nil
    }
}
