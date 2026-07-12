import SwiftUI
import Network
import AMSMB2

// MARK: - AddSMBSourceView
// Three-step flow: Discover → Select Share → Credentials & Test

struct AddSMBSourceView: View {
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    // Step management
    @State private var step: AddSMBStep = .discover

    // Discovery state
    @State private var discoveredDevices: [SMBDevice] = []
    @State private var isDiscovering = false
    @State private var browser: NWBrowser? = nil

    // Selected device / share
    @State private var selectedDevice: SMBDevice? = nil
    @State private var shares: [String] = []
    @State private var isLoadingShares = false
    @State private var sharesError: String? = nil

    // Credentials
    @State private var selectedShare = ""
    @State private var displayName = ""
    @State private var username = ""
    @State private var password = ""
    @State private var rootPath = "/"

    // Test connection
    @State private var isTesting = false
    @State private var testResult: TestResult? = nil

    enum AddSMBStep { case discover, shares, credentials }
    enum TestResult: Equatable { case success, failure(String) }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                switch step {
                case .discover: discoverView
                case .shares: sharesView
                case .credentials: credentialsView
                }
            }
            .navigationTitle(stepTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(step == .discover ? "Cancel" : "Back") {
                        if step == .discover {
                            stopDiscovery()
                            dismiss()
                        } else if step == .shares {
                            step = .discover
                        } else {
                            step = .shares
                        }
                    }
                    .foregroundColor(.sTextSecondary)
                }
            }
            .onAppear { startDiscovery() }
            .onDisappear { stopDiscovery() }
        }
    }

    // MARK: - Step 1: Discover

    private var discoverView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                if isDiscovering || !discoveredDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SettingsSectionLabel(title: "Available on Network")
                            Spacer()
                            if isDiscovering {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(.sTextSecondary)
                            }
                        }

                        if discoveredDevices.isEmpty {
                            Text("Searching for devices…")
                                .font(.system(size: 14))
                                .foregroundColor(.sTextMuted)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(discoveredDevices) { device in
                                    Button {
                                        selectDevice(device)
                                    } label: {
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
                }

                // Manual entry
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionLabel(title: "Manual Entry")

                    ManualSMBEntryRow {
                        // User wants to enter hostname manually
                        selectedDevice = SMBDevice(id: "manual", name: "Manual Entry", host: "", port: 445)
                        shares = []
                        step = .shares
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 48)
            }
        }
    }

    // MARK: - Step 2: Shares

    private var sharesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                if let device = selectedDevice {
                    // Device info
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
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.sTextPrimary)
                                Text(device.host.isEmpty ? "Enter address below" : device.host)
                                    .font(.system(size: 12))
                                    .foregroundColor(.sTextMuted)
                            }
                        }
                        .padding(12)
                        .background(Color.sSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                    // Manual host field if manual entry
                    if device.id == "manual" {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsSectionLabel(title: "Server Address")
                            SMBTextField(placeholder: "192.168.1.x or hostname", text: Binding(
                                get: { selectedDevice?.host ?? "" },
                                set: { selectedDevice?.host = $0 }
                            ))
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }

                    // Credentials
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: "Credentials")
                        VStack(spacing: 1) {
                            TextField("Username", text: $username)
                                .font(.system(size: 15))
                                .foregroundColor(.sTextPrimary)
                                .padding(12)
                                .background(Color.sSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .textContentType(.username)
                            SecureField("Password", text: $password)
                                .font(.system(size: 15))
                                .foregroundColor(.sTextPrimary)
                                .padding(12)
                                .background(Color.sSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .textContentType(.password)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                    // Connect buttons
                    VStack(spacing: 8) {
                        Button {
                            if let d = selectedDevice { loadShares(device: d) }
                        } label: {
                            Text(isLoadingShares ? "Connecting…" : "Connect")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Color.sAccent)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(isLoadingShares || (device.id == "manual" && (selectedDevice?.host.isEmpty ?? true)))

                        Button {
                            username = ""
                            password = ""
                            if let d = selectedDevice { loadShares(device: d) }
                        } label: {
                            Text("Connect as Guest")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.sTextSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Color.sSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(isLoadingShares)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                    // Shares list
                    if isLoadingShares {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(.sTextSecondary)
                            Text("Loading shares…")
                                .font(.system(size: 14))
                                .foregroundColor(.sTextMuted)
                        }
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 16)
                    } else if let err = sharesError {
                        VStack(spacing: 8) {
                            Text(err)
                                .font(.system(size: 13))
                                .foregroundColor(.sTextMuted)
                                .multilineTextAlignment(.center)
                            Button("Try Again") {
                                if let d = selectedDevice { loadShares(device: d) }
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.sAccent)
                        }
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                    } else if !shares.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsSectionLabel(title: "Shares")
                            VStack(spacing: 8) {
                                ForEach(shares, id: \.self) { share in
                                    Button {
                                        selectedShare = share
                                        displayName = device.name
                                        step = .credentials
                                    } label: {
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
    }

    // MARK: - Step 3: Credentials & Test

    private var credentialsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // Source name
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionLabel(title: "Name")
                    SMBTextField(placeholder: "My NAS", text: $displayName)
                }

                // Credentials
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionLabel(title: "Credentials (optional)")
                    VStack(spacing: 1) {
                        SMBTextField(placeholder: "Username (leave blank for guest)", text: $username)
                        SMBSecureField(placeholder: "Password", text: $password)
                    }
                    Text("Leave blank for guest / anonymous access.")
                        .font(.system(size: 12))
                        .foregroundColor(.sTextMuted)
                        .padding(.top, 2)
                }

                // Root path
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionLabel(title: "Music Folder (optional)")
                    SMBTextField(placeholder: "/Music or / for all", text: $rootPath)
                    Text("Limit scanning to a specific subfolder on the share.")
                        .font(.system(size: 12))
                        .foregroundColor(.sTextMuted)
                        .padding(.top, 2)
                }

                // Test result
                if let result = testResult {
                    HStack(spacing: 10) {
                        Image(systemName: result == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result == .success ? Color(hex: "#4CAF50") : .red)
                        Text(result == .success ? "Connection successful" : testErrorMessage(result))
                            .font(.system(size: 14))
                            .foregroundColor(result == .success ? Color(hex: "#4CAF50") : .red)
                    }
                    .padding(12)
                    .background(Color.sSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Buttons
                VStack(spacing: 8) {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                            }
                            Text(isTesting ? "Testing…" : "Test Connection")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.sSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.sAccent, lineWidth: 1)
                        )
                    }
                    .disabled(isTesting)

                    Button {
                        saveSource()
                    } label: {
                        Text("Save")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(canSave ? Color.sAccent : Color.sAccent.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(!canSave)
                }
            }
            .padding(16)
            .padding(.top, 8)
        }
    }

    // MARK: - Helpers

    private var stepTitle: String {
        switch step {
        case .discover: return "Add Network Share"
        case .shares: return "Select Share"
        case .credentials: return "Configure Source"
        }
    }

    private var canSave: Bool {
        !displayName.isEmpty && !selectedShare.isEmpty && selectedDevice != nil
    }

    private func testErrorMessage(_ result: TestResult) -> String {
        if case .failure(let msg) = result { return msg }
        return "Unknown error"
    }

    // MARK: - Bonjour Discovery

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

        b.stateUpdateHandler = { state in
            DispatchQueue.main.async {
                if case .failed = state { self.isDiscovering = false }
                if case .ready = state { /* keep spinning */ }
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

    private func selectDevice(_ device: SMBDevice) {
        selectedDevice = device
        shares = []
        sharesError = nil
        step = .shares
    }

    // MARK: - Load Shares

    private func loadShares(device: SMBDevice) {
        let cleanHost = device.host.hasSuffix(".") ? String(device.host.dropLast()) : device.host
        guard let url = URL(string: "smb://\(cleanHost)") else { return }
        isLoadingShares = true
        sharesError = nil
        shares = []

        let user = username.isEmpty ? "guest" : username
        let credential = URLCredential(user: user,
                                       password: password,
                                       persistence: .forSession)

        guard let smb = SMB2Manager(url: url, credential: credential) else {
            DispatchQueue.main.async {
                self.isLoadingShares = false
                self.sharesError = "Could not create SMB client for \(cleanHost)"
            }
            return
        }

        Task {
            do {
                let rawShares = try await smb.listShares(enumerateHidden: false)
                let filtered = rawShares
                    .map { $0.name }
                    .filter { !$0.hasPrefix("$") && !$0.isEmpty }
                print("SORRIVA SMB: Found shares: \(filtered)")
                await MainActor.run {
                    self.shares = filtered
                    self.isLoadingShares = false
                }
            } catch {
                let errMsg = "Could not list shares: \(error.localizedDescription) [\(error)]"
                print("SORRIVA SMB: \(errMsg)")
                await MainActor.run {
                    self.sharesError = errMsg
                    self.isLoadingShares = false
                }
            }
        }
    }

    // MARK: - Test Connection

    private func testConnection() {
        print("SORRIVA SMB: testConnection called — share='\(selectedShare)' host='\(selectedDevice?.host ?? "nil")' user='\(username)'")
        guard let device = selectedDevice else { return }
        let cleanHost = device.host.hasSuffix(".") ? String(device.host.dropLast()) : device.host
        guard let url = URL(string: "smb://\(cleanHost)") else { return }

        isTesting = true
        testResult = nil

        let user = username.isEmpty ? "guest" : username
        let credential = URLCredential(user: user,
                                       password: password,
                                       persistence: .forSession)

        guard let smb = SMB2Manager(url: url, credential: credential) else {
            testResult = .failure("Could not create SMB client")
            isTesting = false
            return
        }

        Task {
            do {
                print("SORRIVA SMB: Testing connection to \(cleanHost)/\(selectedShare) path:\(rootPath)")
                try await smb.connectShare(name: selectedShare)
                print("SORRIVA SMB: Connected to share")
                _ = try await smb.contentsOfDirectory(atPath: rootPath.isEmpty ? "/" : rootPath)
                print("SORRIVA SMB: Directory listing succeeded")
                try? await smb.disconnectShare()
                await MainActor.run {
                    self.testResult = .success
                    self.isTesting = false
                }
            } catch {
                print("SORRIVA SMB: Test connection failed: \(error)")
                await MainActor.run {
                    self.testResult = .failure(error.localizedDescription)
                    self.isTesting = false
                }
            }
        }
    }

    // MARK: - Save

    private func saveSource() {
        guard let device = selectedDevice else { return }
        let now = Int(Date().timeIntervalSince1970)
        let cleanHost = device.host.hasSuffix(".") ? String(device.host.dropLast()) : device.host
        let source = LibrarySource(
            id: UUID().uuidString,
            type: "smb",
            displayName: displayName.isEmpty ? device.name : displayName,
            host: cleanHost,
            share: selectedShare,
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
    }
}

// MARK: - SMBDevice

struct SMBDevice: Identifiable {
    let id: String
    var name: String
    var host: String
    let port: Int
}

// MARK: - SMBDeviceRow

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

// MARK: - ManualSMBEntryRow

struct ManualSMBEntryRow: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
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
        .buttonStyle(.plain)
    }
}

// MARK: - Text Field helpers

struct SMBTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.system(size: 15))
            .foregroundColor(.sTextPrimary)
            .padding(12)
            .background(Color.sSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }
}

struct SMBSecureField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        SecureField(placeholder, text: $text)
            .font(.system(size: 15))
            .foregroundColor(.sTextPrimary)
            .padding(12)
            .background(Color.sSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
