import SwiftUI
import GRDB

// MARK: - LocalLibraryView
// Entry point for local library management.
// Connected section: configured sources with track counts + last scan time.
// Available section: SMB and iOS Files source types to add.

struct LocalLibraryView: View {
    @State private var sources: [LibrarySource] = []
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

                    // MARK: Header
                    HStack {
                        SorrivaWordmark()
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 60)
                    .padding(.bottom, 32)

                    // MARK: Connected
                    if !sources.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsSectionLabel(title: "Connected")

                            VStack(spacing: 8) {
                                ForEach(sources) { source in
                                    NavigationLink(destination: LibrarySourceDetailView(source: source, onDelete: {
                                        loadSources()
                                    })) {
                                        ConnectedLibrarySourceRow(source: source)
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
                        SettingsSectionLabel(title: sources.isEmpty ? "Available" : "Add Another")

                        VStack(spacing: 8) {
                            // SMB / NAS
                            Button {
                                showAddSMB = true
                            } label: {
                                AvailableServiceRow(
                                    icon: "externaldrive.connected.to.line.below",
                                    iconColor: .sBrass,
                                    name: "Network Share (SMB)",
                                    description: "NAS, Mac, Windows PC, or router with USB drive"
                                )
                            }
                            .buttonStyle(.plain)

                            // iOS Files — coming Phase 1b
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
        .sheet(isPresented: $showAddSMB, onDismiss: { loadSources() }) {
            AddSMBSourceView(onSaved: {
                showAddSMB = false
                loadSources()
            })
        }
    }

    private func loadSources() {
        sources = (try? SorrivaDatabase.shared.allLibrarySources()) ?? []
    }
}

// MARK: - ConnectedLibrarySourceRow

struct ConnectedLibrarySourceRow: View {
    let source: LibrarySource

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.sBrass.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: source.type == "smb" ? "externaldrive.connected.to.line.below" : "folder")
                    .font(.system(size: 20))
                    .foregroundColor(.sBrass)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(source.displayName)
                    .font(.system(size: 15, weight: .semibold))
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

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.sTextMuted)
        }
        .padding(12)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var lastScannedText: String {
        guard let ts = source.lastScanned else { return "Never scanned" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let diff = Int(Date().timeIntervalSince(date))
        if diff < 60 { return "Just now" }
        if diff < 3600 { return "\(diff / 60)m ago" }
        if diff < 86400 { return "\(diff / 3600)h ago" }
        return "\(diff / 86400)d ago"
    }
}

// MARK: - LibrarySourceDetailView
// Management screen for a connected source.

struct LibrarySourceDetailView: View {
    let source: LibrarySource
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Source info card
                    VStack(alignment: .leading, spacing: 12) {
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
                                Text(source.displayName)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.sTextPrimary)
                                Text("\(source.host)/\(source.share)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.sTextMuted)
                                    .lineLimit(1)
                            }
                        }

                        Divider().background(Color.sSeparator)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Tracks")
                                    .font(.system(size: 11))
                                    .foregroundColor(.sTextMuted)
                                Text("\(source.trackCount)")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.sTextPrimary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Last Scanned")
                                    .font(.system(size: 11))
                                    .foregroundColor(.sTextMuted)
                                Text(lastScannedText)
                                    .font(.system(size: 13))
                                    .foregroundColor(.sTextSecondary)
                            }
                        }
                    }
                    .padding(16)
                    .background(Color.sSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    // Actions
                    VStack(spacing: 8) {
                        // Scan now — placeholder for Phase 2
                        Button {
                            // Phase 2: trigger scan
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 16))
                                Text("Scan Now")
                                    .font(.system(size: 15, weight: .medium))
                                Spacer()
                                Text("Coming in Phase 2")
                                    .font(.system(size: 12))
                                    .foregroundColor(.sTextMuted)
                            }
                            .foregroundColor(.sTextPrimary)
                            .padding(14)
                            .background(Color.sSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(true)
                        .opacity(0.5)

                        // Remove
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                    .font(.system(size: 16))
                                Text("Remove Source")
                                    .font(.system(size: 15, weight: .medium))
                                Spacer()
                            }
                            .foregroundColor(.red)
                            .padding(14)
                            .background(Color.sSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding(16)
                .padding(.top, 16)
            }
        }
        .navigationTitle(source.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(source.displayName)?",
                           isPresented: $showDeleteConfirm,
                           titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                try? SorrivaDatabase.shared.deleteLibrarySource(id: source.id)
                onDelete()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the source and all scanned tracks. This cannot be undone.")
        }
    }

    private var lastScannedText: String {
        guard let ts = source.lastScanned else { return "Never" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
