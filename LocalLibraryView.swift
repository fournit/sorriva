import SwiftUI
import GRDB

// MARK: - LocalLibraryView

struct LocalLibraryView: View {
    @State private var grouped: [(host: String, sources: [LibrarySource])] = []
    @State private var showAddSMB = false

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
                                    onSaved: {
                                        loadSources()
                                        showAddSMB = false
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
        .onAppear { loadSources() }
        // Hidden NavigationLinks for server actions
        .background(
            Group {
                NavigationLink(
                    destination: SMBSharePickerView(
                        device: SMBDevice(id: host, name: serverName, host: host, port: 445),
                        prefillUsername: username,
                        prefillPassword: password,
                        onSaved: { loadSources(); onChanged(); showAddShare = false }
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
            ShareActionSheet(source: source, onRemove: {
                removeShareSource = source
                showRemoveShareConfirm = true
            })
            .presentationDetents([.height(220)])
            .presentationDragIndicator(.visible)
        }
        // Remove share confirm
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
    let source: LibrarySource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 20))
                .foregroundColor(.sTextSecondary)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.share)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.sTextPrimary)

                HStack(spacing: 6) {
                    if source.trackCount > 0 {
                        Text("\(source.trackCount) tracks")
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                    }
                    Text(lastScannedText)
                        .font(.system(size: 12))
                        .foregroundColor(.sTextMuted)
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
    }

    private var lastScannedText: String {
        guard let ts = source.lastScanned else { return "Never scanned" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - ShareActionSheet

struct ShareActionSheet: View {
    let source: LibrarySource
    let onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss

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

                // Scan Now — Phase 2
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Scan Now")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                    Text("Phase 2")
                        .font(.system(size: 12))
                        .foregroundColor(.sTextMuted)
                }
                .foregroundColor(.sTextPrimary.opacity(0.35))
                .padding(.vertical, 14)
                .padding(.horizontal, 20)

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
