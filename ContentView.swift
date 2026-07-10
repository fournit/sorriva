import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Tab = .zones
    @State private var expandZoneID: String? = nil  // Zone to auto-expand after station play
    @StateObject private var discovery = ZoneDiscoveryService()

    enum Tab {
        case library, zones, discover, settings
    }

    var body: some View {
        ZStack(alignment: .bottom) {

            // Full-screen gradient background
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Tab content — ZStack keeps all views alive so @State persists across tab switches
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
                .opacity(selectedTab == .library ? 1 : 0)

                ZonesView(discovery: discovery, expandZoneID: $expandZoneID)
                    .opacity(selectedTab == .zones ? 1 : 0)

                DiscoverView()
                    .opacity(selectedTab == .discover ? 1 : 0)

                SettingsView()
                    .opacity(selectedTab == .settings ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 72)

            // Tab bar
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
        .onAppear { discovery.startDiscovery() }
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
