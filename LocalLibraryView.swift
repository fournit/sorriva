import SwiftUI
import GRDB

// MARK: - LocalLibraryView

struct LocalLibraryView: View {
    @State private var grouped: [(host: String, sources: [LibrarySource])] = []
    @State private var showAddSMB = false
    @State private var savedHost: String = ""
    @State private var showSavedServer = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    HStack {
                        SorrivaWordmark()
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 60)
                    .padding(.bottom, 32)

                    // MARK: Connected
                    if !grouped.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsSectionLabel(title: "Connected")
                            VStack(spacing: 8) {
                                ForEach(grouped, id: \.host) { group in
                                    NavigationLink(destination: SMBServerDetailView(
                                        host: group.host,
                                        onChanged: { loadSources() }
                                    )) {
                                        ServerLibraryCard(host: group.host, sources: group.sources)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }

                    // MARK: Available
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: grouped.isEmpty ? "Available" : "Add Another")
                        VStack(spacing: 8) {
                            NavigationLink(
                                destination: AddSMBSourceView(
                                    onSaved: { source in
                                        loadSources()
                                        if let source = source {
                                            savedHost = source.host
                                            withAnimation(.none) { showAddSMB = false }
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                                withAnimation(.none) { showSavedServer = true }
                                            }
                                        }
                                    },
                                    existingHosts: Set(grouped.map { $0.host })
                                ),
                                isActive: $showAddSMB
                            ) {
                                AvailableServiceRow(
                                    icon: "externaldrive.connected.to.line.below",
                                    iconColor: .sBrass,
                                    name: "Network Share (SMB)",
                                    description: "NAS, Mac, Windows PC, or router with USB drive"
                                )
                            }
                            .buttonStyle(.plain)

                            AvailableServiceRow(
                                    icon: "folder",
                                    iconColor: Color(hex: "#4CAF50"),
                                    name: "Local Files",
                                    description: "iPhone storage, USB-C drive, or iCloud Drive"
                                )
                            .opacity(0.45)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 48)
                }
            }
        }
        .navigationTitle("Local Library")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSources() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidUpdate)) { _ in
            loadSources()
        }
        .background(
            NavigationLink(
                destination: SMBServerDetailView(
                    host: savedHost,
                    onChanged: { loadSources() }
                ),
                isActive: $showSavedServer
            ) { EmptyView() }
        )
    }

    private func loadSources() {
        grouped = (try? SorrivaDatabase.shared.allLibrarySourcesByHost()) ?? []
    }
}

// MARK: - ServerLibraryCard

struct ServerLibraryCard: View {
    let host: String
    let sources: [LibrarySource]

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.sBrass.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 20))
                    .foregroundColor(.sBrass)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(sources.first?.displayName ?? host)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.sTextPrimary)

                HStack(spacing: 6) {
                    Text("\(sources.count) share\(sources.count == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundColor(.sTextMuted)
                    if totalTracks > 0 {
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                        Text("\(totalTracks) tracks")
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.sTextMuted)
        }
        .padding(12)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var totalTracks: Int {
        sources.reduce(0) { $0 + $1.trackCount }
    }
}

// MARK: - SMBServerDetailView

struct SMBServerDetailView: View {
    let host: String
    let onChanged: () -> Void

    @State private var sources: [LibrarySource] = []
    @State private var actionSource: LibrarySource? = nil
    @State private var showRemoveServer = false
    @State private var showAddShare = false
    @State private var showEditServer = false
    @Environment(\.dismiss) private var dismiss

    var serverName: String { sources.first?.displayName ?? host }
    var username: String { sources.first?.username ?? "" }
    var password: String { sources.first?.password ?? "" }

    @State private var showServerAction = false
    @State private var showServerActionSheet = false
    @State private var removeShareSource: LibrarySource? = nil
    @State private var showRemoveShareConfirm = false
    @State private var showScanReport = false
    @State private var showScanConfirm = false
    @ObservedObject private var coordinator = ScanCoordinator.shared

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // Header card — long press for server actions
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.sBrass.opacity(0.15))
                                    .frame(width: 48, height: 48)
                                Image(systemName: "externaldrive.connected.to.line.below")
                                    .font(.system(size: 22))
                                    .foregroundColor(.sBrass)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(serverName)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.sTextPrimary)
                                Text(host)
                                    .font(.system(size: 12))
                                    .foregroundColor(.sTextMuted)
                                    .lineLimit(1)
                            }
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "person")
                                .font(.system(size: 11))
                                .foregroundColor(.sTextMuted)
                            Text(username.isEmpty ? "Guest access" : username)
                                .font(.system(size: 12))
                                .foregroundColor(.sTextMuted)
                        }

                    }
                    .padding(16)
                    .background(Color.sSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                    .onLongPressGesture { showServerActionSheet = true }

                    // Scan status panel — visible during active scan, retries, or while messages remain
                    let activeSource = sources.first(where: {
                        $0.id == coordinator.activeScanSourceId ||
                        $0.scanState == "retrying" ||
                        $0.scanState == "scanning"
                    }) ?? (coordinator.statusMessages.isEmpty ? nil : sources.first(where: {
                        $0.host == host
                    }))
                    if let active = activeSource, !coordinator.statusMessages.isEmpty {
                        ScanStatusPanel(sourceId: active.id, scanState: active.scanState)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }

                    // Shares
                    if !sources.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsSectionLabel(title: "Shares")
                            VStack(spacing: 8) {
                                ForEach(sources) { source in
                                    ShareDetailCard(source: source)
                                        .onLongPressGesture {
                                            actionSource = source
                                        }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 48)
                    }
                }
            }
        }
        .navigationTitle(serverName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadSources()
            // Show scan confirmation if a scan was queued during navigation
            if coordinator.pendingFullScanSource != nil {
                showScanConfirm = true
            }
        }
        .onDisappear {
            // Clear status messages when leaving the page
            ScanCoordinator.shared.clearStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidUpdate)) { _ in
            loadSources()
        }
        .onChange(of: coordinator.activeScanSourceId) { _ in
            loadSources()
        }
        // Hidden NavigationLinks for server actions
        .background(
            Group {
                NavigationLink(
                    destination: SMBSharePickerView(
                        device: SMBDevice(id: host, name: serverName, host: host, port: 445),
                        prefillUsername: username,
                        prefillPassword: password,
                        onSaved: { _ in loadSources(); onChanged(); showAddShare = false }
                    ),
                    isActive: $showAddShare
                ) { EmptyView() }
                NavigationLink(
                    destination: SMBEditServerView(
                        host: host,
                        currentName: serverName,
                        currentUsername: username,
                        currentPassword: password,
                        onSaved: { loadSources(); onChanged() }
                    ),
                    isActive: $showEditServer
                ) { EmptyView() }
            }
        )
        // Server action sheet
        .sheet(isPresented: $showServerActionSheet) {
            ServerActionSheet(
                serverName: serverName,
                host: host,
                username: username,
                onAddShare: { showServerActionSheet = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showAddShare = true } },
                onEditServer: { showServerActionSheet = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showEditServer = true } },
                onRemoveServer: { showServerActionSheet = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showRemoveServer = true } }
            )
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
        }
        // Remove server confirm
        .alert("Remove \(serverName)?", isPresented: $showRemoveServer) {
            Button("Remove Server & All Shares", role: .destructive) {
                try? SorrivaDatabase.shared.deleteLibrarySourcesByHost(host: host)
                onChanged()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all \(sources.count) share\(sources.count == 1 ? "" : "s") and all scanned tracks. This cannot be undone.")
        }
        // Share action sheet
        .sheet(item: $actionSource) { source in
            ShareActionSheet(
                source: source,
                onScan: {
                    ScanCoordinator.shared.pendingFullScanSource = source
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showScanConfirm = true
                    }
                },
                onViewReport: {
                    showScanReport = true
                },
                onRemove: {
                    removeShareSource = source
                    showRemoveShareConfirm = true
                }
            )
            .presentationDetents([.height(310)])
            .presentationDragIndicator(.visible)
        }
        // Scan report sheet
        .sheet(isPresented: $showScanReport) {
            if let report = ScanCoordinator.shared.lastReport {
                ScanReportSheet(report: report)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
        // Scan confirmation alert
        .alert("Scan Music Library?", isPresented: $showScanConfirm) {
            Button("Start Scan") {
                if let source = coordinator.pendingFullScanSource {
                    coordinator.confirmAndScanSource(source)
                }
            }
            Button("Cancel", role: .cancel) {
                coordinator.pendingFullScanSource = nil
            }
        } message: {
            Text("Sorriva will read tags from every audio file on this share. On large libraries this can take several hours.\n\nDuring the scan, auto-lock will be disabled to keep the screen on. It will be re-enabled automatically when the scan completes.\n\nKeep Sorriva in the foreground — backgrounding the app will pause the scan.")
        }
        .onChange(of: coordinator.pendingFullScanSource) { source in
            if source != nil { showScanConfirm = true }
        }        // Remove share confirm
        .alert("Remove \(removeShareSource?.share ?? "Share")?", isPresented: $showRemoveShareConfirm) {
            Button("Remove Share", role: .destructive) {
                if let s = removeShareSource {
                    try? SorrivaDatabase.shared.deleteLibrarySource(id: s.id)
                    loadSources()
                    onChanged()
                    removeShareSource = nil
                    if sources.isEmpty { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) { removeShareSource = nil }
        } message: {
            Text("This removes the share and all scanned tracks. This cannot be undone.")
        }
    }

    private func loadSources() {
        let all = (try? SorrivaDatabase.shared.allLibrarySources()) ?? []
        sources = all.filter { $0.host == host }
    }
}

// MARK: - ShareDetailCard

struct ShareDetailCard: View {
    @State private var source: LibrarySource

    init(source: LibrarySource) {
        _source = State(initialValue: source)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 20))
                .foregroundColor(.sTextSecondary)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(shareDisplayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.sTextPrimary)

                Text(source.rootPath.isEmpty || source.rootPath == "/" ? "/" : source.rootPath)
                    .font(.system(size: 11))
                    .foregroundColor(.sTextMuted)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if source.trackCount > 0 {
                        Text("\(source.trackCount) tracks")
                            .font(.system(size: 12))
                            .foregroundColor(.sTextSecondary)
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundColor(.sTextSecondary)
                    }
                    Text(lastScannedText)
                        .font(.system(size: 12))
                        .foregroundColor(.sTextSecondary)
                }
            }

            Spacer()

            Image(systemName: "ellipsis")
                .font(.system(size: 16))
                .foregroundColor(.sTextMuted)
        }
        .padding(12)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidUpdate)) { _ in
            reloadSource()
        }
    }

    private func reloadSource() {
        if let fresh = try? SorrivaDatabase.shared.allLibrarySources().first(where: { $0.id == source.id }) {
            source = fresh
        }
    }

    private var shareDisplayName: String {
        let share = source.share
        let root = source.rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !root.isEmpty else { return share }
        let lastComponent = root.components(separatedBy: "/").filter { !$0.isEmpty }.last ?? root
        return "\(share) — .../\(lastComponent)"
    }

    private var lastScannedText: String {
        guard let ts = source.lastScanned else { return "Never scanned" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - ScanStatusPanel
// Shows live log tail during any active scan pipeline phase.
// Reads last N lines from sorriva-debug.log on a 1s timer.
// No callbacks or dispatches in the scan hot path — purely observes the log file.

struct ScanStatusPanel: View {
    let sourceId: String
    let scanState: String
    @ObservedObject private var coordinator = ScanCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if scanState == "scanning" || scanState == "retrying" {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.sBrass)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.sBrass)
                }
                Text(phaseLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.sBrass)
            }

            if !coordinator.statusMessages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(coordinator.statusMessages.indices, id: \.self) { i in
                                Text(coordinator.statusMessages[i])
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.sTextSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .id(i)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                    .onChange(of: coordinator.statusMessages.count) { _ in
                        if let last = coordinator.statusMessages.indices.last {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var phaseLabel: String {
        switch scanState {
        case "scanning":  return "Scanning library…"
        case "retrying":  return "Retrying skipped tracks…"
        case "complete":  return "Scan complete"
        default:          return "Processing…"
        }
    }
}

// MARK: - ShareActionSheet

struct ShareActionSheet: View {
    let source: LibrarySource
    let onScan: () -> Void
    let onViewReport: () -> Void
    let onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var coordinator = ScanCoordinator.shared

    var body: some View {
        ZStack {
            Color.sCard.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 20))
                        .foregroundColor(.sTextSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.share)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                        Text(source.host)
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 16)

                Divider().background(Color.sSeparator).padding(.horizontal, 20)

                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onScan() }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Scan Now")
                            .font(.system(size: 15, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(.sTextPrimary)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 20)
                }

                if coordinator.lastReport?.sourceId == source.id {
                    Divider().background(Color.sSeparator).padding(.horizontal, 20)

                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onViewReport() }
                    } label: {
                        HStack {
                            Image(systemName: "doc.text")
                            Text("View Scan Report")
                                .font(.system(size: 15, weight: .medium))
                            Spacer()
                        }
                        .foregroundColor(.sTextPrimary)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 20)
                    }
                }

                Divider().background(Color.sSeparator).padding(.horizontal, 20)

                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onRemove() }
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Remove Share")
                            .font(.system(size: 15, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(.red)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 20)
                }

                Spacer()
            }
        }
    }
}

// MARK: - SMBEditServerView

struct SMBEditServerView: View {
    let host: String
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var username: String
    @State private var password: String

    init(host: String, currentName: String, currentUsername: String, currentPassword: String, onSaved: @escaping () -> Void) {
        self.host = host
        self.onSaved = onSaved
        _displayName = State(initialValue: currentName)
        _username = State(initialValue: currentUsername)
        _password = State(initialValue: currentPassword)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: "Server Name")
                        TextField("My NAS", text: $displayName)
                            .font(.system(size: 15))
                            .foregroundColor(.sTextPrimary)
                            .padding(12)
                            .background(Color.sSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .autocorrectionDisabled()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: "Credentials")
                        TextField("Username", text: $username)
                            .font(.system(size: 15))
                            .foregroundColor(.sTextPrimary)
                            .padding(12)
                            .background(Color.sSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Password", text: $password)
                            .font(.system(size: 15))
                            .foregroundColor(.sTextPrimary)
                            .padding(12)
                            .background(Color.sSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Text("Updates credentials for all shares on this server.")
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                    }

                    Button {
                        try? SorrivaDatabase.shared.updateServerCredentials(
                            host: host,
                            displayName: displayName,
                            username: username.isEmpty ? nil : username,
                            password: password.isEmpty ? nil : password
                        )
                        onSaved()
                        dismiss()
                    } label: {
                        Text("Save")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(displayName.isEmpty ? Color.sAccent.opacity(0.4) : Color.sAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(displayName.isEmpty)
                }
                .padding(16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Edit Server")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - ServerActionSheet

struct ServerActionSheet: View {
    let serverName: String
    let host: String
    let username: String
    let onAddShare: () -> Void
    let onEditServer: () -> Void
    let onRemoveServer: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.sCard.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.sBrass.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.system(size: 18))
                            .foregroundColor(.sBrass)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(serverName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                        Text(username.isEmpty ? "Guest access" : username)
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

                Divider().background(Color.sSeparator).padding(.horizontal, 20)

                VStack(spacing: 0) {
                    ServerActionRow(icon: "plus", label: "Add Share", color: .sTextPrimary) {
                        onAddShare()
                    }
                    Divider().background(Color.sSeparator).padding(.horizontal, 20)
                    ServerActionRow(icon: "pencil", label: "Edit Server", color: .sTextPrimary) {
                        onEditServer()
                    }
                    Divider().background(Color.sSeparator).padding(.horizontal, 20)
                    ServerActionRow(icon: "trash", label: "Remove Server", color: .red) {
                        onRemoveServer()
                    }
                }
                .padding(.top, 4)

                Spacer()
            }
        }
    }
}

// MARK: - ScanReportSheet

struct ScanReportSheet: View {
    let report: ScanReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.sCard.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scan Report")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                        Text(report.sourceName)
                            .font(.system(size: 13))
                            .foregroundColor(.sTextMuted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.sTextMuted)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)

                Divider().background(Color.sSeparator)

                ScrollView {
                    VStack(spacing: 0) {
                        ReportRow(label: "Files found",     value: "\(report.totalFiles)")
                        ReportRow(label: "Tracks indexed",  value: "\(report.tracksIndexed)")
                        ReportRow(label: "Albums",          value: "\(report.albumsFound)")
                        ReportRow(label: "Artists",         value: "\(report.artistsFound)")
                        ReportRow(label: "Artwork found",   value: "\(report.artworkFound)")
                        if report.filesSkipped > 0 {
                            ReportRow(label: "Tracks skipped",   value: "\(report.filesSkipped)", valueColor: .sBrass)
                            ReportRow(label: "Tracks retried",   value: "\(report.tracksRetried)", valueColor: report.tracksRetried > 0 ? .green : .sTextSecondary)
                            if report.permanentFailures > 0 {
                                ReportRow(label: "Unresolvable",  value: "\(report.permanentFailures)", valueColor: .red)
                            }
                        }
                        ReportRow(label: "Completed", value: completedText, isLast: true)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
        }
    }

    private var completedText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: report.completedAt)
    }
}

struct ReportRow: View {
    let label: String
    let value: String
    var valueColor: Color = .sTextSecondary
    var isLast: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundColor(.sTextMuted)
                Spacer()
                Text(value)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(valueColor)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            if !isLast {
                Divider().background(Color.sSeparator).padding(.horizontal, 20)
            }
        }
    }
}

struct ServerActionRow: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(width: 24)
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                Spacer()
            }
            .foregroundColor(color)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
        }
    }
}
