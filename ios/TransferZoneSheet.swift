import SwiftUI

// MARK: - TransferZoneSheet
// Transfer playback from sourceZone to a selected destination zone.
// Tap a zone to transfer immediately — no Apply needed.
// Uses Sonos group → ungroup pattern: destination joins group, source leaves.
// Can be presented from ZoneCard, NowPlayingView, MiniPlayerView, or anywhere else.

struct TransferZoneSheet: View {
    let sourceZone: SonosZone
    @ObservedObject var discovery: ZoneDiscoveryService
    // Content shown per row comes from the store rather than SonosZone's raw fields.
    // Observed so a row updates when what a zone is playing changes while the sheet is up.
    @ObservedObject private var store = PlaybackStore.shared
    @Environment(\.dismiss) private var dismiss

    // Destination zones — all zones except the source
    private var destinationZones: [SonosZone] {
        discovery.zones.filter { $0.id != sourceZone.id }
    }

    /// What a destination row says the zone is doing. The station name is the resolved
    /// one from the store; SonosZone's own field holds Sonos's raw `dc:title`, which would
    /// show a filename or a stream slug here.
    private func subtitle(for zone: SonosZone) -> String {
        guard zone.isPlaying else { return "Idle" }
        let name = store.snapshot(for: zone.id)?.albumName ?? ""
        return name.isEmpty ? "Playing" : name
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
                                        Text(subtitle(for: zone))
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
