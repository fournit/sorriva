import SwiftUI

// MARK: - ZonePickerSheet
// Reusable zone picker sheet — used by radio, local library, and any future
// playback context that needs to route audio to a Sonos zone.
//
// Usage:
//   .sheet(item: $zonePickerItem) { item in
//       ZonePickerSheet(
//           title: item.title,
//           subtitle: "iHeartRADIO",   // or "Local Library", etc.
//           discovery: discovery
//       ) { zone in
//           // handle zone selection
//       }
//   }

struct ZonePickerSheet: View {
    let title: String
    let subtitle: String
    @ObservedObject var discovery: ZoneDiscoveryService
    let onPick: (SonosZone) -> Void
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
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.sTextMuted)
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.top, 8)

                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.sTextPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 32)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(.sTextMuted)
                    Text("Select a zone to play on")
                        .font(.system(size: 13))
                        .foregroundColor(.sTextMuted)
                        .padding(.top, 2)
                }
                .padding(.vertical, 16)

                Divider().background(Color.sSeparator)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(discovery.zones) { zone in
                            Button(action: {
                                print("ZONEPICKER: tapped zone — \(zone.name)")
                                dismiss()
                                onPick(zone)
                            }) {
                                HStack(spacing: 12) {
                                    if zone.isPlaying {
                                        EQBarsView().frame(width: 16, height: 12)
                                    } else {
                                        Circle()
                                            .fill(Color.sIdle)
                                            .frame(width: 8, height: 8)
                                            .padding(.horizontal, 4)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(zone.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.sTextPrimary)
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
                                        } else if !zone.stationName.isEmpty {
                                            Text(zone.stationName)
                                                .font(.system(size: 12))
                                                .foregroundColor(.sTextMuted)
                                                .lineLimit(1)
                                        } else {
                                            Text("Idle")
                                                .font(.system(size: 12))
                                                .foregroundColor(.sTextMuted)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12))
                                        .foregroundColor(.sTextMuted)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
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
}
