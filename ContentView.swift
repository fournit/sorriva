import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Tab = .zones
    @State private var expandZoneID: String? = nil
    @StateObject private var discovery = ZoneDiscoveryService()

    enum Tab {
        case library, zones, discover, settings
    }

    var body: some View {
        ZStack(alignment: .bottom) {

            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ZStack {
                LibraryView(
                    discovery: discovery,
                    onPlayStation: { station, zone in
                        discovery.playStation(streamID: station.id, on: zone)
                        expandZoneID = zone.id
                        withAnimation { selectedTab = .zones }
                    },
                    onNavigateToZone: { zoneID in
                        expandZoneID = zoneID
                        withAnimation { selectedTab = .zones }
                    }
                )
                .environmentObject(discovery)
                .opacity(selectedTab == .library ? 1 : 0)
                .allowsHitTesting(selectedTab == .library)

                ZonesView(discovery: discovery, expandZoneID: $expandZoneID)
                    .opacity(selectedTab == .zones ? 1 : 0)
                    .allowsHitTesting(selectedTab == .zones)

                DiscoverView()
                    .opacity(selectedTab == .discover ? 1 : 0)
                    .allowsHitTesting(selectedTab == .discover)

                NavigationStack {
                    SettingsView(
                        discovery: discovery,
                        onPlayStation: { station, zone in
                            discovery.playStation(streamID: station.id, on: zone)
                            expandZoneID = zone.id
                            withAnimation { selectedTab = .zones }
                        },
                        onNavigateToZone: { zoneID in
                            expandZoneID = zoneID
                            withAnimation { selectedTab = .zones }
                        }
                    )
                }
                .opacity(selectedTab == .settings ? 1 : 0)
                .allowsHitTesting(selectedTab == .settings)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 72)

            VStack(spacing: 0) {
                Divider()
                    .background(Color.sSeparator)

                HStack(spacing: 0) {
                    TabBarButton(icon: "music.note.list", label: "Library",
                                 isActive: selectedTab == .library) { selectedTab = .library }
                    TabBarButton(icon: "hifispeaker.2", label: "Zones",
                                 isActive: selectedTab == .zones) { selectedTab = .zones }
                    TabBarButton(icon: "sparkles", label: "Discover",
                                 isActive: selectedTab == .discover) { selectedTab = .discover }
                    TabBarButton(icon: "gearshape", label: "Settings",
                                 isActive: selectedTab == .settings) { selectedTab = .settings }
                }
                .padding(.top, 8)
                .padding(.bottom, 28)
                .background(Color.sGradientBottom)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            print("CONTENTVIEW: onAppear fired")
            discovery.startDiscovery()
            // TEMP: prove local playback — fires 5s after launch
            Task {
                print("CONTENTVIEW: Task started")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                print("CONTENTVIEW: 5s elapsed — zones: \(discovery.zones.map(\.name))")
                guard let zone = discovery.zones.first(where: { $0.name == "Living Room" }) else {
                    print("LOCALPLAY TEST: Living Room not found")
                    return
                }
                print("LOCALPLAY TEST: zone found — \(zone.name) at \(zone.host)")
                guard let track = try? SorrivaDatabase.shared.track(id: "83C137BC-4010-4375-B140-55A2DE5E4431") else {
                    print("LOCALPLAY TEST: track not found in DB")
                    return
                }
                print("LOCALPLAY TEST: track found — \(track.title)")
                print("LOCALPLAY TEST: firing playTrack")
                await LocalPlaybackService.shared.playTrack(track, on: zone)
            }
        }
    }
}

// MARK: - Tab Bar Button
struct TabBarButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(isActive ? .sTabActive : .sTabInactive)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(isActive ? .sTabActive : .sTabInactive)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
