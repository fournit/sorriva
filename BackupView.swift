import SwiftUI
import Network
import SMBClient
import ZIPFoundation

// MARK: - BackupView
// Settings destination for backup and restore.
// Backup location config stored in @AppStorage — separate from library sources.
// Backup operation: copies sorriva.sqlite to configured SMB share/folder.

struct BackupView: View {

    @AppStorage("sorriva.backup.host")       private var backupHost     = ""
    @AppStorage("sorriva.backup.share")      private var backupShare    = ""
    @AppStorage("sorriva.backup.path")       private var backupPath     = ""
    @AppStorage("sorriva.backup.username")   private var backupUsername = ""
    @AppStorage("sorriva.backup.password")   private var backupPassword = ""
    @AppStorage("sorriva.backup.lastBackup") private var lastBackup     = ""

    @State private var isBackingUp   = false
    @State private var backupResult: BackupResult? = nil
    @State private var showLocationPicker = false
    @Environment(\.dismiss) private var dismiss

    private var hasLocation: Bool { !backupHost.isEmpty && !backupShare.isEmpty }

    enum BackupResult { case success(String), failure(String) }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // MARK: Location
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: "Backup Location")

                        if hasLocation {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.sBrass.opacity(0.15))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: "externaldrive.connected.to.line.below")
                                        .font(.system(size: 16))
                                        .foregroundColor(.sBrass)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(backupHost) / \(backupShare)")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.sTextPrimary)
                                        .lineLimit(1)
                                    Text(backupPath.isEmpty || backupPath == "/" ? "/" : backupPath)
                                        .font(.system(size: 12))
                                        .foregroundColor(.sTextMuted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    showLocationPicker = true
                                } label: {
                                    Text("Change")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.sAccent)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(14)
                            .background(Color.sSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        } else {
                            Button { showLocationPicker = true } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.sAccent.opacity(0.15))
                                            .frame(width: 36, height: 36)
                                        Image(systemName: "plus")
                                            .font(.system(size: 16))
                                            .foregroundColor(.sAccent)
                                    }
                                    Text("Set Backup Location")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.sTextPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13))
                                        .foregroundColor(.sTextMuted)
                                }
                                .padding(14)
                                .background(Color.sSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)

                    // MARK: Backup
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: "Backup")

                        VStack(spacing: 12) {
                            HStack {
                                Image(systemName: "clock")
                                    .font(.system(size: 14))
                                    .foregroundColor(.sTextMuted)
                                Text(lastBackup.isEmpty ? "Never backed up" : "Last backup: \(lastBackup)")
                                    .font(.system(size: 13))
                                    .foregroundColor(.sTextMuted)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.sSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                            if let result = backupResult {
                                HStack(spacing: 10) {
                                    switch result {
                                    case .success(let filename):
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(Color(hex: "#4CAF50"))
                                        Text("Saved as \(filename)")
                                            .font(.system(size: 13))
                                            .foregroundColor(Color(hex: "#4CAF50"))
                                    case .failure(let message):
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                        Text(message)
                                            .font(.system(size: 13))
                                            .foregroundColor(.red)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.sSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }

                            Button { runBackup() } label: {
                                HStack {
                                    if isBackingUp {
                                        ProgressView().scaleEffect(0.8).tint(.white)
                                    }
                                    Text(isBackingUp ? "Backing up…" : "Backup Now")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(hasLocation && !isBackingUp ? Color.sAccent : Color.sAccent.opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .disabled(!hasLocation || isBackingUp)
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)

                    // MARK: Restore
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: "Restore")

                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.sTextMuted.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 16))
                                    .foregroundColor(.sTextMuted)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Restore from Backup")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.sTextMuted)
                                Text("Coming soon")
                                    .font(.system(size: 12))
                                    .foregroundColor(.sTextMuted)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(Color.sSurface.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .opacity(0.6)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 48)
                }
                .padding(.top, 16)
            }
        }
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.large)
        .background(
            NavigationLink(
                destination: BackupLocationPickerView(
                    onFolderSelected: { source, path in
                        backupHost     = source.host
                        backupShare    = source.share
                        backupPath     = path
                        backupUsername = source.username ?? ""
                        backupPassword = source.password ?? ""
                        showLocationPicker = false
                    }
                ),
                isActive: $showLocationPicker
            ) { EmptyView() }
        )
    }

    // MARK: - Backup operation

    private func runBackup() {
        isBackingUp  = true
        backupResult = nil

        let host     = backupHost
        let share    = backupShare
        let path     = backupPath
        let username = backupUsername
        let password = backupPassword

        Task {
            do {
                let fm = FileManager.default

                // Locate source files
                let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let docsDir    = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let dbURL      = appSupport.appendingPathComponent("sorriva.sqlite")
                let artworkURL = docsDir.appendingPathComponent("artwork")

                guard fm.fileExists(atPath: dbURL.path) else {
                    await MainActor.run { backupResult = .failure("Database file not found"); isBackingUp = false }
                    return
                }

                // Build timestamp
                let formatter  = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                let timestamp  = formatter.string(from: Date())
                let backupName = "sorriva-backup-\(timestamp)"
                let zipName    = "\(backupName).zip"

                // Create temp staging directory
                let tempDir    = fm.temporaryDirectory.appendingPathComponent(backupName)
                try? fm.removeItem(at: tempDir)
                try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

                // Copy DB into staging
                try fm.copyItem(at: dbURL, to: tempDir.appendingPathComponent("sorriva.sqlite"))

                // Copy artwork folder into staging (if it exists)
                if fm.fileExists(atPath: artworkURL.path) {
                    try fm.copyItem(at: artworkURL, to: tempDir.appendingPathComponent("artwork"))
                }

                // Zip the staging directory
                let zipURL = fm.temporaryDirectory.appendingPathComponent(zipName)
                try? fm.removeItem(at: zipURL)
                try fm.zipItem(at: tempDir, to: zipURL)

                // Clean up staging dir
                try? fm.removeItem(at: tempDir)

                // Read zip into memory
                let zipData = try Data(contentsOf: zipURL)
                try? fm.removeItem(at: zipURL)

                sLog("BACKUP: zip built — \(zipName) (\(zipData.count / 1024)KB)")

                // Upload to NAS
                let folder     = path.isEmpty || path == "/" ? "" : path
                let remotePath = folder.isEmpty ? "/\(zipName)" : "\(folder)/\(zipName)"

                let client = SMBClient(host: host)
                try await client.login(username: username.isEmpty ? "guest" : username, password: password)
                try await client.connectShare(share)
                if !folder.isEmpty { try? await client.createDirectory(path: folder) }
                try await client.upload(content: zipData, path: remotePath)
                try? await client.disconnectShare()
                try? await client.logoff()

                let display = DateFormatter()
                display.dateStyle = .medium
                display.timeStyle = .short

                sLog("BACKUP: uploaded \(zipName) to \(host)/\(share)\(remotePath)")

                await MainActor.run {
                    lastBackup   = display.string(from: Date())
                    backupResult = .success(zipName)
                    isBackingUp  = false
                }
            } catch {
                sLog("BACKUP: failed — \(error.localizedDescription)")
                await MainActor.run { backupResult = .failure(error.localizedDescription); isBackingUp = false }
            }
        }
    }
}

// MARK: - BackupLocationPickerView
// Mirrors LocalLibraryView exactly — Connected section shows existing library sources,
// Add Another section allows adding new servers. All server/share/folder browsing
// reuses SMBServerDetailView and SMBFolderBrowserView with onFolderSelected in backup mode.

struct BackupLocationPickerView: View {
    /// Called when user selects a folder — provides the LibrarySource (for credentials/host/share) and chosen path.
    let onFolderSelected: (LibrarySource, String) -> Void

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

                    // MARK: Connected
                    if !grouped.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsSectionLabel(title: "Connected")
                            VStack(spacing: 8) {
                                ForEach(grouped, id: \.host) { group in
                                    NavigationLink(destination: SMBServerDetailView(
                                        host: group.host,
                                        onChanged: { loadSources() },
                                        onFolderSelected: { source, path in
                                            onFolderSelected(source, path)
                                        }
                                    )) {
                                        ServerLibraryCard(host: group.host, sources: group.sources)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                        .padding(.bottom, 24)
                    }

                    // MARK: Add Another
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: grouped.isEmpty ? "Available" : "Add Another")
                        NavigationLink(
                            destination: AddSMBSourceView(
                                onSaved: { _ in loadSources() },
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
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 48)
                }
            }
        }
        .navigationTitle("Backup Location")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSources() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidUpdate)) { _ in
            loadSources()
        }
    }

    private func loadSources() {
        grouped = (try? SorrivaDatabase.shared.allLibrarySourcesByHost()) ?? []
    }
}
