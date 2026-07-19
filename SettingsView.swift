import SwiftUI
import GRDB

// MARK: - SettingsView
// Main settings screen. Single menu rows per section — tapping navigates deeper.
// Services row → ServicesView (connected + add)
// ServicesView → individual service config (IHeartServiceView, etc.)

struct SettingsView: View {
    @ObservedObject var discovery: ZoneDiscoveryService
    let onPlayStation: (RadioStation, SonosZone) -> Void
    let onNavigateToZone: (String) -> Void
    @State private var showClearLibraryConfirm = false
    @State private var showClearLibraryDone = false

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

                            // Library Management
                            NavigationLink(destination: LibraryManagementView()) {
                                SettingsMenuRow(
                                    icon: "books.vertical",
                                    iconColor: Color(hex: "#3D7A5A"),
                                    title: "Library Management",
                                    subtitle: "Stats, storage, and library tools"
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

                            #if DEBUG
                            // Debug Log
                            NavigationLink(destination: DebugLogView()) {
                                SettingsMenuRow(
                                    icon: "doc.text.magnifyingglass",
                                    iconColor: Color(hex: "#E07B39"),
                                    title: "Debug Log",
                                    subtitle: "Playback diagnostics"
                                )
                            }
                            .buttonStyle(.plain)
                            #endif

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
                showClearLibraryDone = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all indexed tracks, albums, artists and scan history. Your actual music files are not affected. You will need to rescan to rebuild the library.")
        }
        .alert("Library Cleared", isPresented: $showClearLibraryDone) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("All indexed data has been removed. Open Local Library to rescan.")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}

// MARK: - LibraryManagementView

struct LibraryManagementView: View {
    @State private var artistCount: Int = 0
    @State private var albumCount: Int = 0
    @State private var trackCount: Int = 0
    @State private var dbSizeBytes: Int64 = 0
    @State private var showClearConfirm = false
    @State private var showClearDone = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Stats cards
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: "Library")

                        HStack(spacing: 10) {
                            LibStatCard(value: "\(artistCount)", label: "Artists", icon: "music.mic")
                            LibStatCard(value: "\(albumCount)", label: "Albums", icon: "square.stack")
                            LibStatCard(value: "\(trackCount)", label: "Tracks", icon: "music.note")
                        }
                    }
                    .padding(.horizontal, 16)

                    // Storage card
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: "Storage")

                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.sAccent.opacity(0.15))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "internaldrive")
                                    .font(.system(size: 18))
                                    .foregroundColor(.sAccent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Database size")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.sTextPrimary)
                                Text(formattedSize)
                                    .font(.system(size: 12))
                                    .foregroundColor(.sTextMuted)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(Color.sSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 16)

                    // Destructive section
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                            .background(Color.sSeparator)
                            .padding(.horizontal, 16)

                        Button { showClearConfirm = true } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.red)
                                        .frame(width: 36, height: 36)
                                    Image(systemName: "trash")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Clear Local Library")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.sTextPrimary)
                                    Text("Remove all indexed tracks, albums and artists")
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
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 48)
                }
                .padding(.top, 16)
            }
        }
        .navigationTitle("Library Management")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { loadStats() }
        .alert("Clear Local Library?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) {
                try? SorrivaDatabase.shared.clearLocalLibrary()
                NotificationCenter.default.post(name: .libraryDidUpdate, object: nil)
                loadStats()
                showClearDone = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all indexed tracks, albums, artists and scan history. Your actual music files are not affected. You will need to rescan to rebuild the library.")
        }
        .alert("Library Cleared", isPresented: $showClearDone) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("All indexed data has been removed. Open Local Library to rescan.")
        }
    }

    private func loadStats() {
        artistCount = (try? SorrivaDatabase.shared.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artists") ?? 0
        }) ?? 0
        albumCount = (try? SorrivaDatabase.shared.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums") ?? 0
        }) ?? 0
        trackCount = (try? SorrivaDatabase.shared.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? 0
        }) ?? 0

        // DB file size — resolve from Documents directory
        let docsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dbURL = docsDir.appendingPathComponent("sorriva.sqlite")
        dbSizeBytes = (try? dbURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) }) ?? 0
    }

    private var formattedSize: String {
        let mb = Double(dbSizeBytes) / 1_048_576
        if mb < 1 { return String(format: "%.0f KB", Double(dbSizeBytes) / 1024) }
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - LibStatCard

struct LibStatCard: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.sBrass)
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.sTextPrimary)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.sTextMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
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

// MARK: - DebugLogView

#if DEBUG
struct DebugLogView: View {
    @State private var logText: String = ""
    @State private var showShareSheet = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("Debug Log")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.sTextPrimary)
                    Spacer()
                    Button(action: { showShareSheet = true }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18))
                            .foregroundColor(.sTextPrimary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 56)
                .padding(.bottom, 12)

                HStack(spacing: 12) {
                    Button(action: {
                        SorrivaLogger.shared.clearLog()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { loadLog() }
                    }) {
                        Text("Clear")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Color.sSurface)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("\(logText.components(separatedBy: "\n").count) lines")
                        .font(.system(size: 12))
                        .foregroundColor(.sTextMuted)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

                ScrollViewReader { proxy in
                    ScrollView {
                        Text(logText.isEmpty ? "No log entries yet." : logText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.sTextSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .id("bottom")
                    }
                    .background(Color.sCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .onAppear {
                        loadLog()
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [SorrivaLogger.shared.logFileURL])
        }
    }

    private func loadLog() {
        logText = (try? String(contentsOf: SorrivaLogger.shared.logFileURL, encoding: .utf8)) ?? ""
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}
#endif
