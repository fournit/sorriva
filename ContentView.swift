import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Tab = .zones

    enum Tab {
        case library, zones, discover, settings
    }

    var body: some View {
        ZStack(alignment: .bottom) {

            // Background
            Color.sBackground
                .ignoresSafeArea()

            // Tab content
            Group {
                switch selectedTab {
                case .library:
                    LibraryView()
                case .zones:
                    ZonesView()
                case .discover:
                    DiscoverView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Leave room for mini-player + tab bar
            .padding(.bottom, 112)

            // Mini-player + tab bar stack
            VStack(spacing: 0) {
                MiniPlayerView()

                Divider()
                    .background(Color.sSeparator)

                // Tab bar
                HStack(spacing: 0) {
                    TabBarButton(
                        icon: "music.note.list",
                        label: "Library",
                        isActive: selectedTab == .library
                    ) { selectedTab = .library }

                    TabBarButton(
                        icon: "hifispeaker.2",
                        label: "Zones",
                        isActive: selectedTab == .zones
                    ) { selectedTab = .zones }

                    TabBarButton(
                        icon: "sparkles",
                        label: "Discover",
                        isActive: selectedTab == .discover
                    ) { selectedTab = .discover }

                    TabBarButton(
                        icon: "gearshape",
                        label: "Settings",
                        isActive: selectedTab == .settings
                    ) { selectedTab = .settings }
                }
                .padding(.top, 8)
                .padding(.bottom, 28)
                .background(Color.sBackground)
            }
        }
        .ignoresSafeArea(edges: .bottom)
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
