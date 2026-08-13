import SwiftUI

// MARK: - ServiceSetupView
//
// One setup screen, used by every service. Two panes: what is in your library on top,
// what is available below. Tap moves an item between them, immediately.
//
// WHY IT LOOKS LIKE THIS (Tom, 2026-08-12, after rejecting the first favorites screen):
//
// ONE SCREEN, NOT TWO. iHeart and SomaFM used a detail screen plus a "Browse + Add"
// screen behind a button. The button was a door into a room you always wanted to be
// in, so selecting a service now presents its content directly.
//
// SETUP DOES ADD AND REMOVE ONLY. Favourite and Play-on are library functions and
// already live there — the Library station card opens a zone picker on tap and the
// action sheet on long press. Putting them here too would give tap two meanings, which
// is exactly the collision that made the old two-screen split necessary.
//
// IMMEDIATE COMMIT, NO SAVE BUTTON. Checking adds, unchecking removes. There is no
// unsaved state to lose by navigating away, and nothing in the app works that way.
//
// SORT ON APPEAR, NOT WHILE TAPPING. Items move between panes only when the screen is
// re-entered. Re-sorting live would slide rows out from under a finger mid-tap.

/// One selectable thing — a station, a channel, a playlist. Deliberately not a
/// `Station` or a `SonosFavorite`: this screen serves both, and whatever comes next.
struct ServiceSetupItem: Identifiable, Equatable {
    /// Stable across a reload AND across households. For favorites this is the channel
    /// identity, not the URI — see SonosFavorites.channelIdentity.
    let id: String
    let title: String
    let subtitle: String
    let artURL: String?
    /// Listeners, audience, plays — whatever the service uses to rank. Nil where the
    /// service publishes no such number, which is most of them.
    let popularity: Int?
}

/// How the list is ordered beneath the in-library group.
/// A filter chip. Services with no meaningful categories supply none and no chip row is
/// drawn — only iHeart has a catalogue large enough to need them.
struct ServiceSetupChip: Identifiable, Equatable {
    let id: String
    let name: String
}

enum ServiceSetupSort: String, CaseIterable {
    case alphabetical = "A–Z"
    case popularity = "Popular"
}

/// Where a setup screen gets its content and what happens when something is tapped.
/// Implemented per service so the screen itself knows nothing about SiriusXM or iHeart.
@MainActor
protocol ServiceSetupSource {
    var serviceName: String { get }
    var icon: String { get }
    var color: Color { get }

    /// Categories to filter by. Empty for everything except iHeart.
    var chips: [ServiceSetupChip] { get async }

    /// Items matching the current query and chip, plus the ids already in the library.
    ///
    /// THE SOURCE FILTERS, NOT THE SCREEN. SomaFM and the favorites services filter a
    /// small cached array; iHeart filters in SQL across an ephemeral catalogue table of
    /// thousands of rows. Making the screen filter would force iHeart to hold its whole
    /// catalogue in memory only to filter it a second time.
    ///
    /// Throwing means "I could not reach what I need" — distinct from returning nothing,
    /// which means the user genuinely has no matches.
    func load(query: String, chip: String?) async throws -> (available: [ServiceSetupItem], inLibrary: Set<String>)

    func add(_ item: ServiceSetupItem) async throws
    func remove(_ item: ServiceSetupItem) async throws

    /// Shown when `available` comes back empty — the reason differs per service.
    var emptyMessage: String { get }

    /// Whether a Popular pill is offered. False for services with no audience figure —
    /// Sonos favorites have none — in which case the list is always alphabetical.
    var supportsPopularity: Bool { get }
}

struct ServiceSetupView<Source: ServiceSetupSource>: View {

    let source: Source
    @EnvironmentObject private var tabState: SorrivaTabBarState

    private enum Phase: Equatable {
        case loading
        case ready
        case empty
        case failed
    }

    @State private var phase: Phase = .loading
    @State private var items: [ServiceSetupItem] = []
    @State private var inLibrary: Set<String> = []
    @State private var search = ""
    @State private var busy: Set<String> = []
    @State private var sort: ServiceSetupSort = .alphabetical
    @State private var chips: [ServiceSetupChip] = []
    @State private var selectedChip: String?
    @State private var queryTask: Task<Void, Never>?

    /// Removal guard, mirroring the Library's. Pulling a station out from under a zone
    /// that is playing it should be a decision, not a side effect of a tap.
    @State private var pendingRemoval: ServiceSetupItem?
    @State private var blockedZones: [String] = []

    var body: some View {
        ZStack {
            LinearGradient(colors: [.sGradientTop, .sGradientMid, .sGradientBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            switch phase {
            case .loading: centred { ProgressView().tint(.sTextMuted) }
            case .failed:  centred { notice("wifi.exclamationmark", "Can't reach your Sonos system",
                                            "No speaker answered. Check you're on the same network, then try again.") }
            case .empty:   centred { notice(source.icon, "Nothing available yet", source.emptyMessage) }
            case .ready:   panes
            }
        }
        // THE TITLE SAYS WHAT YOU ARE DOING; THE CARD SAYS WHICH SERVICE. Both said the
        // service name until 2026-08-12, which read as a stutter. Keeping the service on
        // the card also leaves room to make it tappable later — a way to switch services
        // without leaving the screen.
        .navigationTitle("Manage Stations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // THE TITLE GOES IN THE PRINCIPAL SLOT so it is centred in the bar rather
            // than laid out around the other items. An inline title shares a row with
            // the back button and the trailing control, so a wide trailing item pushes
            // it off centre — and a trailing item that CHANGES width makes it shift on
            // every toggle. Fixing the width stopped the shifting; only the principal
            // slot actually centres it.
            if source.supportsPopularity, phase == .ready {
                ToolbarItem(placement: .topBarTrailing) { sortToggle }
            }
        }
        // THE TAB BAR COMES OFF THIS SCREEN. It hides itself on scroll, but this screen
        // has a fixed frame with two internally scrolling panes, so it never scrolls
        // and the bar would sit over the lower pane forever. The mini player stays.
        .onAppear { tabState.chromeSuppressed = true }
        .onDisappear { tabState.chromeSuppressed = false }
        .task { await reload() }
        .alert("Playing right now", isPresented: .constant(pendingRemoval != nil), presenting: pendingRemoval) { item in
            Button("Remove anyway", role: .destructive) {
                let target = item; pendingRemoval = nil
                Task { await commitRemove(target) }
            }
            Button("Keep", role: .cancel) { pendingRemoval = nil }
        } message: { item in
            Text("\(item.title) is playing in \(blockedZones.joined(separator: ", ")). "
               + "Removing it from your library won't stop it.")
        }
    }

    // MARK: - Panes

    private var panes: some View {
        VStack(spacing: 10) {
            // EVERY SERVICE GETS THE HEADER CARD — the same one iHeart and SomaFM have
            // always shown. It is how you know which service you are configuring, and
            // it is where the service's own logo will sit once those are supplied.
            ServiceHeaderCard(name: source.serviceName,
                              subtitle: "\(inLibrary.count) in your library") {
                Image(systemName: source.icon)
                    .font(.system(size: 26))
                    .foregroundColor(source.color)
                    .frame(width: 56, height: 56)
                    .background(Color.sSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            searchField
            if !chips.isEmpty { chipRow }
            list
        }
        .padding(.top, 8)
    }

    /// ONE LIST, NOT TWO PANES. Two panes were tried on 2026-08-12 and rejected: on a
    /// phone there is not enough height for both, and without a visible divider they
    /// read as one broken list anyway.
    ///
    /// SORT ORDER IS: in your library first, then the chosen key. Membership is the
    /// primary sort, so what you already have is always at the top and what you might
    /// add follows.
    ///
    /// RE-GROUPS THE MOMENT SOMETHING IS TAPPED — a station you add joins the group at
    /// the top straight away. What must NOT happen is the viewport moving: no scrollTo,
    /// no jump to the top, no chasing the row. Tom, 2026-08-12: fine for it to move to
    /// the top "as long as the list is not repositioned and you stay where you were".
    private var ordered: [ServiceSetupItem] {
        let key = sort
        return items.sorted { a, b in
            let aIn = inLibrary.contains(a.id), bIn = inLibrary.contains(b.id)
            if aIn != bIn { return aIn }
            switch key {
            case .popularity:
                let ap = a.popularity ?? -1, bp = b.popularity ?? -1
                if ap != bp { return ap > bp }
            case .alphabetical:
                break
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// ONE CONTROL IN THE NAVIGATION BAR, not two pills competing with the genre chips
    /// for a row. This is where it lived before the rebuild, and it reads as a mode
    /// switch rather than a filter — which is what it is.
    private var sortToggle: some View {
        Button {
            sort = (sort == .alphabetical) ? .popularity : .alphabetical
        } label: {
            HStack(spacing: 4) {
                Image(systemName: sort == .popularity ? "chart.bar.fill" : "textformat.abc")
                    .font(.system(size: 12))
                Text(sort.rawValue)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.sHighlight)
            // SIZED TO MATCH THE ORIGINAL Browse Stations control, and that matters for
            // more than looks. A wide trailing item leaves the inline title no room to
            // centre — three attempts at fixing the alignment with principal slots and
            // balancing spacers all failed because the control itself was the problem.
            // The fixed width additionally stops the title shifting as the label changes
            // between "A–Z" and "Popular".
            .frame(width: 76)
            .padding(.vertical, 5)
            .background(Color.sSurface)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(id: nil, name: "All")
                ForEach(chips) { chip(id: $0.id, name: $0.name) }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(id: String?, name: String) -> some View {
        let selected = selectedChip == id
        return Button {
            selectedChip = selected ? nil : id
            requery()
        } label: {
            Text(name)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .white : .sTextSecondary)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(selected ? Color.sAccent : Color.sSurface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(ordered) { row($0) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func row(_ item: ServiceSetupItem) -> some View {
        Button { Task { await toggle(item) } } label: {
            HStack(spacing: 12) {
                artwork(item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.sTextPrimary).lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 12)).foregroundColor(.sTextMuted).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if busy.contains(item.id) {
                    ProgressView().scaleEffect(0.7).tint(.sTextMuted)
                } else {
                    Image(systemName: inLibrary.contains(item.id) ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 22))
                        .foregroundColor(inLibrary.contains(item.id) ? .sBrass : .sTextMuted)
                }
            }
            .padding(12)
            .background(Color.sSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func artwork(_ item: ServiceSetupItem) -> some View {
        Group {
            if let s = item.artURL, let url = URL(string: s) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var placeholder: some View {
        ZStack {
            Color.sCard
            Image(systemName: source.icon)
                .font(.system(size: 20)).foregroundColor(source.color.opacity(0.8))
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14)).foregroundColor(.sTextMuted)
            TextField("Search \(source.serviceName)", text: $search)
                .font(.system(size: 15)).foregroundColor(.sTextPrimary)
                .autocorrectionDisabled()
                .onChange(of: search) { _, _ in requery() }
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15)).foregroundColor(.sTextMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }

    private func centred<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack { Spacer(); content(); Spacer() }
    }

    private func notice(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 38)).foregroundColor(.sTextMuted)
            Text(title).font(.system(size: 18, weight: .semibold)).foregroundColor(.sTextPrimary)
            Text(detail).font(.system(size: 14)).foregroundColor(.sTextMuted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Try again") { Task { await reload() } }
                .font(.system(size: 15, weight: .medium)).padding(.top, 2)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Behaviour

    /// Debounced so typing does not fire a query per keystroke — iHeart's runs against
    /// a catalogue of thousands.
    private func requery() {
        queryTask?.cancel()
        queryTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await load(showingSpinner: false)
        }
    }

    private func reload() async {
        chips = await source.chips
        await load(showingSpinner: true)
    }

    private func load(showingSpinner: Bool) async {
        if showingSpinner { phase = .loading }
        do {
            let (available, library) = try await source.load(query: search, chip: selectedChip)
            // Sorted ONCE, here. Rows must not reorder while a finger is on them.
            items = available.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            inLibrary = library
            // An empty result while searching is "no matches", not "nothing available" —
            // showing the service's empty message there would be wrong.
            phase = (items.isEmpty && search.isEmpty && selectedChip == nil) ? .empty : .ready
        } catch {
            sLog("SETUP: \(source.serviceName) load failed — \(error.localizedDescription)")
            phase = .failed
        }
    }

    private func toggle(_ item: ServiceSetupItem) async {
        if inLibrary.contains(item.id) {
            let playing = zonesPlaying(item)
            guard playing.isEmpty else {
                blockedZones = playing
                pendingRemoval = item
                return
            }
            await commitRemove(item)
        } else {
            busy.insert(item.id)
            do {
                try await source.add(item)
                inLibrary.insert(item.id)
            } catch {
                sLog("SETUP: add failed for \(item.title) — \(error.localizedDescription)")
            }
            busy.remove(item.id)
            NotificationCenter.default.post(name: .stationsDidUpdate, object: nil)
        }
    }

    private func commitRemove(_ item: ServiceSetupItem) async {
        busy.insert(item.id)
        do { try await source.remove(item); inLibrary.remove(item.id) }
        catch { sLog("SETUP: remove failed for \(item.title) — \(error.localizedDescription)") }
        busy.remove(item.id)
        NotificationCenter.default.post(name: .stationsDidUpdate, object: nil)
    }

    /// Matched against the store's RESOLVED name, never SonosZone's raw fields — those
    /// hold Sonos's dc:title ("hls.m3u8" for iHeart), so the comparison could never
    /// match and the warning would never fire. Same lesson as IHeartServiceView.
    private func zonesPlaying(_ item: ServiceSetupItem) -> [String] {
        PlaybackStore.shared.zones
            .filter { $0.albumName == item.title && $0.isPlaying }
            .map(\.name)
    }
}
