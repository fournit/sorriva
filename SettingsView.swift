import SwiftUI

// MARK: - SettingsView
// Main settings screen. Single menu rows per section — tapping navigates deeper.
// Services row → ServicesView (connected + add)
// ServicesView → individual service config (IHeartServiceView, etc.)

struct SettingsView: View {
    @ObservedObject var discovery: ZoneDiscoveryService
    let onPlayStation: (RadioStation, SonosZone) -> Void
    let onNavigateToZone: (String) -> Void
    @State private var showClearLibraryConfirm = false

    var body: some View {
            ZStack {
                LinearGradient(
                    colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                    ScrollView {
                    VStack(alignment: .leading, spacing: 0) {

                        // Header
                        HStack {
                            SorrivaWordmark()
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 60)
                        .padding(.bottom, 32)

                        // MARK: Settings menu
                        VStack(spacing: 10) {

                            // Services
                            NavigationLink(destination: ServicesView(
                        discovery: discovery,
                        onPlayStation: onPlayStation,
                        onNavigateToZone: onNavigateToZone
                    )) {
                                SettingsMenuRow(
                                    icon: "rectangle.stack",
                                    iconColor: .sAccent,
                                    title: "Services",
                                    subtitle: "Radio, streaming, and library sources"
                                )
                            }
                            .buttonStyle(.plain)

                            // Local Library
                            NavigationLink(destination: LocalLibraryView()) {
                                SettingsMenuRow(
                                    icon: "externaldrive.connected.to.line.below",
                                    iconColor: .sBrass,
                                    title: "Local Library",
                                    subtitle: "NAS and network share music"
                                )
                            }
                            .buttonStyle(.plain)

                            // Clear Local Library
                            Button { showClearLibraryConfirm = true } label: {
                                SettingsMenuRow(
                                    icon: "trash",
                                    iconColor: .red,
                                    title: "Clear Local Library",
                                    subtitle: "Remove all indexed tracks, albums and artists"
                                )
                            }
                            .buttonStyle(.plain)

                            // Zones (stub)
                            SettingsMenuRow(
                                icon: "hifispeaker.2",
                                iconColor: Color(hex: "#3D7A8A"),
                                title: "Zones",
                                subtitle: "Coming in Phase 5",
                                isStub: true
                            )

                            // Playback (stub)
                            SettingsMenuRow(
                                icon: "slider.horizontal.3",
                                iconColor: Color(hex: "#6B5EA8"),
                                title: "Playback",
                                subtitle: "Coming in Phase 4",
                                isStub: true
                            )

                            // About
                            NavigationLink(destination: AboutView()) {
                                SettingsMenuRow(
                                    icon: "info.circle",
                                    iconColor: .sTextMuted,
                                    title: "About",
                                    subtitle: "Version \(appVersion)"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 48)
                }
            }
        .alert("Clear Local Library?", isPresented: $showClearLibraryConfirm) {
            Button("Clear", role: .destructive) {
                try? SorrivaDatabase.shared.clearLocalLibrary()
                NotificationCenter.default.post(name: .libraryDidUpdate, object: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all indexed tracks, albums, artists and scan history. Your actual music files are not affected. You will need to rescan to rebuild the library.")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}

// MARK: - SettingsMenuRow

struct SettingsMenuRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    var isStub: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(isStub ? 0.3 : 1))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(isStub ? iconColor.opacity(0.5) : .white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isStub ? .sTextMuted : .sTextPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.sTextMuted)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundColor(isStub ? .sTextMuted.opacity(0.4) : .sTextMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .opacity(isStub ? 0.6 : 1)
    }
}

// MARK: - ServicesView
// Single screen: Connected section + Available section.
// No sheet — available services navigate directly to their config.
// Refreshes counts on every appear so adding a service updates the page immediately.

struct ServicesView: View {
    @ObservedObject var discovery: ZoneDiscoveryService
    let onPlayStation: (RadioStation, SonosZone) -> Void
    let onNavigateToZone: (String) -> Void

    @State private var iHeartStationCount: Int = 0
    @State private var somaFMStationCount: Int = 0

    private var isIHeartConnected: Bool { iHeartStationCount > 0 }
    private var isSomaFMConnected: Bool { somaFMStationCount > 0 }
    private var hasAnyConnected: Bool { isIHeartConnected || isSomaFMConnected }
    private var allRadioConnected: Bool { isIHeartConnected && isSomaFMConnected }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // CONNECTED section
                    if hasAnyConnected {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsSectionLabel(title: "Connected")

                            if isIHeartConnected {
                                NavigationLink(destination: IHeartServiceView(
                                    discovery: discovery,
                                    onPlayStation: onPlayStation,
                                    onNavigateToZone: onNavigateToZone
                                )) {
                                    ConnectedServiceRow(
                                        icon: "radio",
                                        iconColor: Color(hex: "#CC2027"),
                                        name: "iHeartRADIO",
                                        detail: "\(iHeartStationCount) station\(iHeartStationCount == 1 ? "" : "s")"
                                    )
                                }
                                .buttonStyle(.plain)
                            }

                            if isSomaFMConnected {
                                NavigationLink(destination: SomaFMServiceView(
                                    discovery: discovery,
                                    onPlayStation: onPlayStation,
                                    onNavigateToZone: onNavigateToZone
                                )) {
                                    ConnectedServiceRow(
                                        icon: "antenna.radiowaves.left.and.right",
                                        iconColor: Color(hex: "#2C3E50"),
                                        name: "SomaFM",
                                        detail: "\(somaFMStationCount) channel\(somaFMStationCount == 1 ? "" : "s")"
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // AVAILABLE section — radio services not yet connected
                    if !allRadioConnected {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsSectionLabel(title: "Available")

                            if !isIHeartConnected {
                                NavigationLink(destination: IHeartServiceView(
                                    discovery: discovery,
                                    onPlayStation: onPlayStation,
                                    onNavigateToZone: onNavigateToZone
                                )) {
                                    AvailableServiceRow(
                                        icon: "radio",
                                        iconColor: Color(hex: "#CC2027"),
                                        name: "iHeartRADIO",
                                        description: "Thousands of live radio stations, no account required"
                                    )
                                }
                                .buttonStyle(.plain)
                            }

                            if !isSomaFMConnected {
                                NavigationLink(destination: SomaFMServiceView(
                                    discovery: discovery,
                                    onPlayStation: onPlayStation,
                                    onNavigateToZone: onNavigateToZone
                                )) {
                                    AvailableServiceRow(
                                        icon: "antenna.radiowaves.left.and.right",
                                        iconColor: Color(hex: "#2C3E50"),
                                        name: "SomaFM",
                                        description: "46 curated commercial-free channels, no account required"
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // COMING SOON section
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: "Coming Soon")
                        VStack(spacing: 8) {
                            ComingSoonRow(name: "Spotify",                   iconColor: Color(hex: "#1DB954"))
                            ComingSoonRow(name: "Apple Music",               iconColor: Color(hex: "#FC3C44"))
                            ComingSoonRow(name: "Qobuz",                     iconColor: Color(hex: "#1A56DB"))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 48)
                }
                .padding(.top, 16)
            }
        }
        .navigationTitle("Services")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { refreshCounts() }
        .onReceive(NotificationCenter.default.publisher(for: .stationsDidUpdate)) { _ in
            refreshCounts()
        }
    }

    private func refreshCounts() {
        iHeartStationCount = (try? SorrivaDatabase.shared.allStations(source: "iheart"))?.count ?? 0
        somaFMStationCount = (try? SorrivaDatabase.shared.allStations(source: "somafm"))?.count ?? 0
    }
}

// MARK: - ConnectedServiceRow

struct ConnectedServiceRow: View {
    let icon: String
    let iconColor: Color
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor)
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.sTextPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.sTextMuted)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundColor(.sTextMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - ServiceBrowserSection

struct ServiceBrowserSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel(title: title)
            content()
        }
    }
}

// MARK: - AvailableServiceRow

struct AvailableServiceRow: View {
    let icon: String
    let iconColor: Color
    let name: String
    let description: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor)
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.sTextPrimary)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.sTextMuted)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundColor(.sTextMuted)
        }
        .padding(14)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - ComingSoonRow

struct ComingSoonRow: View {
    let name: String
    let iconColor: Color

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8)
                .fill(iconColor.opacity(0.3))
                .frame(width: 44, height: 44)
            Text(name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.sTextMuted)
            Spacer()
            Text("Soon")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.sTextMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.sSurface)
                .clipShape(Capsule())
        }
        .padding(14)
        .background(Color.sSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - SettingsSectionLabel

struct SettingsSectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.sTextMuted)
            .kerning(0.8)
            .padding(.horizontal, 4)
    }
}

// MARK: - AboutView

struct AboutView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("Version")
                        .font(.system(size: 15))
                        .foregroundColor(.sTextPrimary)
                    Spacer()
                    Text(appVersion)
                        .font(.system(size: 15))
                        .foregroundColor(.sTextMuted)
                }
                .padding(16)
                .background(Color.sSurface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Spacer()
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.large)
    }
}
