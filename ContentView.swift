import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var env: SorrivaAppEnvironment

    private var discovery: ZoneDiscoveryService { env.discovery }
    private var tabState: SorrivaTabBarState { env.tabState }
    private var playbackContext: PlaybackContextService { env.playbackContext }
    private var store: PlaybackStore { env.playbackStore }

    @State private var selectedZoneID: String? = UserDefaults.standard.string(forKey: "sorriva.selectedZoneID")
    @State private var showNowPlaying = false
    @State private var showZonePicker = false
    @State private var expandZoneID: String? = nil

    // Mini player height — tab bar floats directly above this
    private let miniPlayerHeight: CGFloat = 90

    var body: some View {
        ZStack(alignment: .bottom) {

            // MARK: — Full screen background
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // MARK: — Tab content (full screen, no bottom padding)
            Group {
                switch tabState.selectedTab {
                case .library:
                    NavigationStack {
                        LibraryView(
                            discovery: discovery,
                            onPlayStation: { station, zone in
                                discovery.playStation(streamID: station.id, on: zone)
                                selectedZoneID = zone.id
                                persistSelectedZone(zone.id)
                            },
                            onNavigateToZone: { zoneID in
                                expandZoneID = zoneID
                                tabState.selectedTab = .zones
                            }
                        )
                        .environmentObject(tabState)
                    }
                    .environmentObject(discovery)

                case .zones:
                    NavigationStack {
                        ZonesView(
                            discovery: discovery,
                            store: store,
                            expandZoneID: $expandZoneID,
                            onNowPlaying: { zoneID in
                                selectedZoneID = zoneID
                                persistSelectedZone(zoneID)
                                showNowPlaying = true
                            }
                        )
                        .environmentObject(tabState)
                    }

                case .discover:
                    NavigationStack {
                        DiscoverView()
                    }

                case .settings:
                    NavigationStack {
                        SettingsView(
                            discovery: discovery,
                            onPlayStation: { station, zone in
                                discovery.playStation(streamID: station.id, on: zone)
                                selectedZoneID = zone.id
                                persistSelectedZone(zone.id)
                            },
                            onNavigateToZone: { zoneID in
                                expandZoneID = zoneID
                                tabState.selectedTab = .zones
                            }
                        )
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // MARK: — Mini player (fixed at very bottom, always visible, floats over content)
            MiniPlayerView(
                selectedZoneID: $selectedZoneID,
                discovery: discovery,
                store: store,
                onTapTrack: { showNowPlaying = true },
                onTapZone: { showZonePicker = true }
            )
            .ignoresSafeArea(edges: .bottom)

            // MARK: — Floating tab bar (floats over content above mini player)
            SorrivaTabBar(state: tabState)
                .padding(.bottom, miniPlayerHeight + 8)
        }
        .ignoresSafeArea(edges: .bottom)
        .preferredColorScheme(.dark)
        .environmentObject(tabState)
        .environmentObject(discovery)
        .migrationAlert()
        .onAppear {
            discovery.startDiscovery()
            // playbackContext.observe and playbackStore.observe wired in SorrivaAppEnvironment.init
        }
        .onChange(of: discovery.zones) { zones in
            if selectedZoneID == nil {
                if let active = zones.first(where: { $0.isPlaying }) {
                    selectedZoneID = active.id
                    persistSelectedZone(active.id)
                } else if let first = zones.first {
                    selectedZoneID = first.id
                    persistSelectedZone(first.id)
                }
            }
        }
        // Now Playing sheet
        .sheet(isPresented: $showNowPlaying) {
            if let _ = selectedZoneID {
                NowPlayingView(
                    selectedZoneID: $selectedZoneID,
                    discovery: discovery,
                    store: store,
                    onTapZone: {
                        showNowPlaying = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showZonePicker = true
                        }
                    }
                )
            }
        }
        // Zone picker sheet
        .sheet(isPresented: $showZonePicker) {
            ZonePickerSheet(
                title: "Select Zone",
                subtitle: "Choose a zone to control",
                discovery: discovery,
                selectedZoneID: selectedZoneID
            ) { zone in
                selectedZoneID = zone.id
                persistSelectedZone(zone.id)
                showZonePicker = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func persistSelectedZone(_ id: String) {
        UserDefaults.standard.set(id, forKey: "sorriva.selectedZoneID")
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
