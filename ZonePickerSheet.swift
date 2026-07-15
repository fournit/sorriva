import SwiftUI

// MARK: - ZonePickerSheet
// Reusable zone picker sheet — called from anywhere in the app.
// Media long-press, mini player zone tap, now playing zone switch.
// External interface unchanged — callers pass title, subtitle, discovery, onPick.
//
// Layout:
//   Header — title + subtitle (context of what's being sent to zone)
//   Zone list — all zones with speaker icon, playing state, selected highlight
//   Footer — Pause all | Group (stub)

struct ZonePickerSheet: View {
    let title: String
    let subtitle: String
    @ObservedObject var discovery: ZoneDiscoveryService
    let onPick: (SonosZone) -> Void

    // Optional: pre-highlight a zone as "currently selected"
    var selectedZoneID: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showGroupSheet = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {

                // MARK: — Drag handle
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.sSeparator)
                    .frame(width: 36, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 16)

                // MARK: — Header
                VStack(spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.sTextPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 32)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundColor(.sTextMuted)
                            .lineLimit(1)
                    }
                }
                .padding(.bottom, 16)

                Divider()
                    .background(Color.sSeparator)

                // MARK: — Zone list
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(discovery.zones) { zone in
                            ZoneRow(
                                zone: zone,
                                isSelected: zone.id == selectedZoneID,
                                onTap: {
                                    print("ZONEPICKER: tapped zone — \(zone.name)")
                                    dismiss()
                                    onPick(zone)
                                }
                            )
                            Divider()
                                .background(Color.sSeparator)
                                .padding(.leading, 64)
                        }
                    }
                }

                Divider()
                    .background(Color.sSeparator)

                // MARK: — Footer actions
                HStack(spacing: 0) {

                    // Pause all
                    Button(action: {
                        for zone in discovery.zones where zone.isPlaying {
                            discovery.togglePlayPause(zoneID: zone.id)
                        }
                        dismiss()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "pause.circle")
                                .font(.system(size: 18))
                            Text("Pause all")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(discovery.zones.contains(where: { $0.isPlaying }) ? .sTextPrimary : .sTextMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .disabled(!discovery.zones.contains(where: { $0.isPlaying }))

                    Divider()
                        .background(Color.sSeparator)
                        .frame(height: 24)

                    // Group — stub, grouping sheet to be built
                    Button(action: {
                        showGroupSheet = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "link")
                                .font(.system(size: 18))
                            Text("Group")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(.sTextMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showGroupSheet) {
            // Grouping sheet — to be built
            VStack(spacing: 16) {
                Text("Group zones")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.sTextPrimary)
                    .padding(.top, 24)
                Text("Coming soon")
                    .font(.system(size: 14))
                    .foregroundColor(.sTextMuted)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Color.sGradientBottom)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - ZoneRow

private struct ZoneRow: View {
    let zone: SonosZone
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {

                // Zone icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.sHighlight.opacity(0.15) : Color.sSurface)
                        .frame(width: 44, height: 44)
                    Image(systemName: "hifispeaker.fill")
                        .font(.system(size: 20))
                        .foregroundColor(isSelected ? .sHighlight : .sTextMuted)
                }

                // Zone info
                VStack(alignment: .leading, spacing: 3) {
                    Text(zone.name)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .sTextPrimary : .sTextPrimary)

                    if zone.isPlaying {
                        let context: String = {
                            if !zone.currentTrack.isEmpty {
                                return zone.stationName.isEmpty
                                    ? zone.currentTrack
                                    : "\(zone.stationName) · \(zone.currentTrack)"
                            } else if !zone.stationName.isEmpty {
                                return zone.stationName
                            }
                            return "Playing"
                        }()
                        Text(context)
                            .font(.system(size: 12))
                            .foregroundColor(.sHighlight)
                            .lineLimit(1)
                    } else {
                        Text("Idle")
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                    }
                }

                Spacer()

                // Playing indicator or selected checkmark
                if zone.isPlaying {
                    EQBarsView()
                        .frame(width: 16, height: 14)
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.sHighlight)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isSelected ? Color.sHighlight.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}
