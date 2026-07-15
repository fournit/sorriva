import SwiftUI

struct ContentView: View {
    @StateObject private var discovery = ZoneDiscoveryService()
    @State private var selectedZoneID: String? = UserDefaults.standard.string(forKey: "sorriva.selectedZoneID")
    @State private var showNowPlaying = false
    @State private var showZonePicker = false
    @State private var expandZoneID: String? = nil

    var body: some View {
        ZStack(alignment: .bottom) {

            // MARK: — Tab View
            TabView {
                Tab("Library", systemImage: "music.note.list") {
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
                            }
                        )
                        .environmentObject(discovery)
                    }
                }

                Tab("Zones", systemImage: "hifispeaker.2") {
                    NavigationStack {
                        ZonesView(discovery: discovery, expandZoneID: $expandZoneID)
                    }
                }

                Tab("Discover", systemImage: "sparkles") {
                    NavigationStack {
                        DiscoverView()
                    }
                }

                Tab("Settings", systemImage: "gearshape") {
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
                            }
                        )
                    }
                }
            }
            .tint(.sTabActive)

            // MARK: — Mini Player (always visible above tab bar)
            VStack(spacing: 0) {
                Spacer()
                MiniPlayerView(
                    selectedZoneID: $selectedZoneID,
                    discovery: discovery,
                    onTapTrack: { showNowPlaying = true },
                    onTapZone: { showZonePicker = true }
                )
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            discovery.startDiscovery()
        }
        // Auto-select first active zone if none selected
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
            if let zoneID = selectedZoneID {
                NowPlayingView(zoneID: zoneID, discovery: discovery)
            }
        }
        // Zone picker sheet
        .sheet(isPresented: $showZonePicker) {
            ZonePickerSheet(
                title: "Select Zone",
                subtitle: "Choose a zone to control",
                discovery: discovery
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
