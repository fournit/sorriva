import SwiftUI
import Network
import AMSMB2

// MARK: - SMBDevice

struct SMBDevice: Identifiable {
    let id: String
    var name: String
    var host: String
    let port: Int
}

// MARK: - AddSMBSourceView
// Step 1 — Bonjour discovery + manual entry

struct AddSMBSourceView: View {
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var discoveredDevices: [SMBDevice] = []
    @State private var isDiscovering = false
    @State private var browser: NWBrowser? = nil

    var body: some View {
        ZStack {
            Color.sGradientBottom.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SettingsSectionLabel(title: "Available on Network")
                            Spacer()
                            if isDiscovering {
                                ProgressView().scaleEffect(0.7).tint(.sTextSecondary)
                            }
                        }

                        if discoveredDevices.isEmpty && isDiscovering {
                            Text("Searching for devices…")
                                .font(.system(size: 14))
                                .foregroundColor(.sTextMuted)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(discoveredDevices) { device in
                                    NavigationLink(destination: SMBSharePickerView(
                                        device: device,
                                        onSaved: onSaved
                                    )) {
                                        SMBDeviceRow(device: device)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 24)

                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: "Manual Entry")
                        NavigationLink(destination: SMBSharePickerView(
                            device: SMBDevice(id: "manual", name: "Manual Entry", host: "", port: 445),
                            onSaved: onSaved
                        )) {
                            ManualSMBEntryRow()
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 48)
                }
            }
        }
        .navigationTitle("Add Network Share")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { startDiscovery() }
        .onDisappear { stopDiscovery() }

    }

    private func startDiscovery() {
        isDiscovering = true
        discoveredDevices = []
        let params = NWParameters()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_smb._tcp", domain: "local."), using: params)
        b.browseResultsChangedHandler = { _, changes in
            DispatchQueue.main.async {
                for change in changes {
                    switch change {
                    case .added(let result):
                        if case .service(let name, _, let domain, _) = result.endpoint {
                            let host = "\(name).\(domain)"
                            let device = SMBDevice(id: name, name: name, host: host, port: 445)
                            if !self.discoveredDevices.contains(where: { $0.id == device.id }) {
                                self.discoveredDevices.append(device)
                            }
                        }
                    case .removed(let result):
                        if case .service(let name, _, _, _) = result.endpoint {
                            self.discoveredDevices.removeAll { $0.id == name }
                        }
                    default: break
                    }
                }
            }
        }
        b.start(queue: .global(qos: .userInitiated))
        self.browser = b
    }

    private func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isDiscovering = false
    }
}

// MARK: - SMBSharePickerView
// Step 2 — Credentials + share list

struct SMBSharePickerView: View {
    var device: SMBDevice
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var manualHost = ""
    @State private var shares: [String] = []
    @State private var isLoading = false
    @State private var error: String? = nil
    @State private var shouldDismiss = false

    var body: some View {
        ZStack {
            Color.sGradientBottom.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // Device card
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: "Device")
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
                                Text(device.id == "manual" ? (manualHost.isEmpty ? "Manual Entry" : manualHost) : device.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.sTextPrimary)
                                if device.id != "manual" {
                                    Text(device.host)
                                        .font(.system(size: 12))
                                        .foregroundColor(.sTextMuted)
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.sSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                    // Manual host
                    if device.id == "manual" {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsSectionLabel(title: "Server Address")
                            TextField("192.168.1.x or hostname", text: $manualHost)
                                .font(.system(size: 15))
                                .foregroundColor(.sTextPrimary)
                                .padding(12)
                                .background(Color.sSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }

                    // Credentials
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
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                    // Connect buttons
                    VStack(spacing: 8) {
                        Button { loadShares(asGuest: false) } label: {
                            HStack {
                                if isLoading { ProgressView().scaleEffect(0.8).tint(.white) }
                                Text(isLoading ? "Connecting…" : "Connect")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.sAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(isLoading)

                        Button { loadShares(asGuest: true) } label: {
                            Text("Connect as Guest")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.sTextSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Color.sSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(isLoading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                    if let err = error {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundColor(.red.opacity(0.8))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }

                    // Shares
                    if !shares.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsSectionLabel(title: "Shares")
                            VStack(spacing: 8) {
                                ForEach(shares, id: \.self) { share in
                                    NavigationLink(destination: SMBConfigureSourceView(
                                        device: resolvedDevice,
                                        share: share,
                                        username: username,
                                        password: password,
                                        onSaved: {
                                            onSaved()
                                            dismiss()
                                        }
                                    )) {
                                        HStack {
                                            Image(systemName: "folder")
                                                .font(.system(size: 16))
                                                .foregroundColor(.sTextSecondary)
                                                .frame(width: 24)
                                            Text(share)
                                                .font(.system(size: 15))
                                                .foregroundColor(.sTextPrimary)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 13))
                                                .foregroundColor(.sTextMuted)
                                        }
                                        .padding(12)
                                        .background(Color.sSurface)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 48)
                    }
                }
            }
        }
        .navigationTitle("Select Share")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var resolvedDevice: SMBDevice {
        device.id == "manual"
            ? SMBDevice(id: "manual", name: manualHost, host: manualHost, port: 445)
            : device
    }

    private func loadShares(asGuest: Bool) {
        let host = device.id == "manual" ? manualHost : device.host
        let cleanHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !cleanHost.isEmpty, let url = URL(string: "smb://\(cleanHost)") else { return }

        isLoading = true
        error = nil
        shares = []

        let user = asGuest ? "guest" : (username.isEmpty ? "guest" : username)
        let pass = asGuest ? "" : password
        let credential = URLCredential(user: user, password: pass, persistence: .forSession)

        guard let smb = SMB2Manager(url: url, credential: credential) else {
            isLoading = false
            error = "Could not create SMB client"
            return
        }

        Task {
            do {
                let raw = try await smb.listShares(enumerateHidden: false)
                let filtered = raw.map { $0.name }.filter { !$0.hasPrefix("$") && !$0.isEmpty }
                print("SORRIVA SMB: Shares: \(filtered)")
                await MainActor.run {
                    self.shares = filtered
                    self.isLoading = false
                }
            } catch {
                print("SORRIVA SMB: listShares error: \(error)")
                await MainActor.run {
                    self.error = "Could not list shares: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - SMBConfigureSourceView
// Step 3 — Name, root path, test, save

struct SMBConfigureSourceView: View {
    let device: SMBDevice
    let share: String
    let username: String
    let password: String
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String
    @State private var rootPath = "/"
    @State private var isTesting = false
    @State private var testResult: TestResult? = nil

    enum TestResult: Equatable { case success, failure(String) }

    init(device: SMBDevice, share: String, username: String, password: String, onSaved: @escaping () -> Void) {
        self.device = device
        self.share = share
        self.username = username
        self.password = password
        self.onSaved = onSaved
        _displayName = State(initialValue: device.name)
    }

    var body: some View {
        ZStack {
            Color.sGradientBottom.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: "Name")
                        TextField("My NAS", text: $displayName)
                            .font(.system(size: 15))
                            .foregroundColor(.sTextPrimary)
                            .padding(12)
                            .background(Color.sSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .autocorrectionDisabled()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: "Music Folder (optional)")
                        TextField("/Music or / for all", text: $rootPath)
                            .font(.system(size: 15))
                            .foregroundColor(.sTextPrimary)
                            .padding(12)
                            .background(Color.sSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Text("Limit scanning to a specific subfolder on the share.")
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        SettingsSectionLabel(title: "Connection")
                        VStack(alignment: .leading, spacing: 4) {
                            Label("\(device.host)/\(share)", systemImage: "externaldrive.connected.to.line.below")
                            Label(username.isEmpty ? "Guest access" : username, systemImage: "person")
                        }
                        .font(.system(size: 13))
                        .foregroundColor(.sTextMuted)
                        .padding(12)
                        .background(Color.sSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    if let result = testResult {
                        HStack(spacing: 10) {
                            Image(systemName: result == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(result == .success ? Color(hex: "#4CAF50") : .red)
                            Text(result == .success ? "Connection successful" : errorMessage(result))
                                .font(.system(size: 14))
                                .foregroundColor(result == .success ? Color(hex: "#4CAF50") : .red)
                        }
                        .padding(12)
                        .background(Color.sSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(spacing: 8) {
                        Button { testConnection() } label: {
                            HStack {
                                if isTesting { ProgressView().scaleEffect(0.8).tint(.sTextSecondary) }
                                Text(isTesting ? "Testing…" : "Test Connection")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.sTextSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.sSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.sAccent, lineWidth: 1))
                        }
                        .disabled(isTesting)

                        Button { saveSource() } label: {
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
                }
                .padding(16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Configure Source")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func errorMessage(_ result: TestResult) -> String {
        if case .failure(let m) = result { return m }
        return "Unknown error"
    }

    private func testConnection() {
        let cleanHost = device.host.hasSuffix(".") ? String(device.host.dropLast()) : device.host
        guard let url = URL(string: "smb://\(cleanHost)") else { return }
        isTesting = true
        testResult = nil
        let user = username.isEmpty ? "guest" : username
        let credential = URLCredential(user: user, password: password, persistence: .forSession)
        guard let smb = SMB2Manager(url: url, credential: credential) else {
            testResult = .failure("Could not create SMB client")
            isTesting = false
            return
        }
        Task {
            do {
                try await smb.connectShare(name: share)
                _ = try await smb.contentsOfDirectory(atPath: rootPath.isEmpty ? "/" : rootPath)
                try? await smb.disconnectShare()
                await MainActor.run { self.testResult = .success; self.isTesting = false }
            } catch {
                print("SORRIVA SMB: Test failed: \(error)")
                await MainActor.run { self.testResult = .failure(error.localizedDescription); self.isTesting = false }
            }
        }
    }

    private func saveSource() {
        let cleanHost = device.host.hasSuffix(".") ? String(device.host.dropLast()) : device.host
        let now = Int(Date().timeIntervalSince1970)
        let source = LibrarySource(
            id: UUID().uuidString,
            type: "smb",
            displayName: displayName,
            host: cleanHost,
            share: share,
            rootPath: rootPath.isEmpty ? "/" : rootPath,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            lastScanned: nil,
            trackCount: 0,
            scanState: "idle",
            createdAt: now,
            updatedAt: now
        )
        try? SorrivaDatabase.shared.upsertLibrarySource(source)
        onSaved()
        dismiss()
    }
}

// MARK: - Shared UI Components

struct SMBDeviceRow: View {
    let device: SMBDevice
    var body: some View {
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
                Text(device.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.sTextPrimary)
                Text(device.host)
                    .font(.system(size: 12))
                    .foregroundColor(.sTextMuted)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundColor(.sTextMuted)
        }
        .padding(12)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ManualSMBEntryRow: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.sAccent.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "plus")
                    .font(.system(size: 16))
                    .foregroundColor(.sAccent)
            }
            Text("Enter address manually")
                .font(.system(size: 14))
                .foregroundColor(.sTextPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundColor(.sTextMuted)
        }
        .padding(12)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
