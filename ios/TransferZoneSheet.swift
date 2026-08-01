import SwiftUI

// MARK: - TransferZoneSheet
// Transfer playback from sourceZone to a selected destination zone.
// Tap a zone to transfer immediately — no Apply needed.
// Uses Sonos group → ungroup pattern: destination joins group, source leaves.
// Can be presented from ZoneCard, NowPlayingView, MiniPlayerView, or anywhere else.

struct TransferZoneSheet: View {
    let sourceZone: SonosZone
    @ObservedObject var discovery: ZoneDiscoveryService
    @Environment(\.dismiss) private var dismiss

    // Destination zones — all zones except the source
    private var destinationZones: [SonosZone] {
        discovery.zones.filter { $0.id != sourceZone.id }
    }

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
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.sTextMuted)
                            .padding(12)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    VStack(spacing: 2) {
                        Text("Transfer")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                        Text(sourceZone.name)
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                    }

                    Spacer()

                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.top, 8)

                Divider().background(Color.sSeparator)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(destinationZones) { zone in
                            Button(action: {
                                transferPlayback(to: zone)
                            }) {
                                HStack(spacing: 12) {
                                    // Playing indicator
                                    if zone.isPlaying {
                                        EQBarsView()
                                            .frame(width: 16, height: 12)
                                    } else {
                                        Circle()
                                            .fill(Color.sIdle)
                                            .frame(width: 8, height: 8)
                                            .padding(.horizontal, 4)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(zone.name)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(.sTextPrimary)
                                        Text(zone.isPlaying ? (zone.stationName.isEmpty ? "Playing" : zone.stationName) : "Idle")
                                            .font(.system(size: 12))
                                            .foregroundColor(zone.isPlaying ? .sHighlight : .sTextMuted)
                                    }

                                    Spacer()

                                    Image(systemName: "arrow.left.arrow.right")
                                        .font(.system(size: 14))
                                        .foregroundColor(.sTextMuted)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(Color.sSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
            }
        }
    }

    private func transferPlayback(to destination: SonosZone) {
        discovery.transferPlayback(fromZoneID: sourceZone.id, toZoneID: destination.id)
        dismiss()
    }
}
