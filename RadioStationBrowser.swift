import SwiftUI

// MARK: - RadioStation
// Hardcoded iHeart station catalog for POC.
// Logo URLs fetched at runtime — no bundled assets needed.
// Stream IDs extracted from iHeart URLs (iheart.com/live/{slug}-{id}/).

struct RadioStation: Identifiable {
    let id: Int          // iHeart stream ID
    let name: String
    let description: String
    var logoURL: String = ""

    var streamID: String { "\(id)" }

    static let catalog: [RadioStation] = [
        RadioStation(id: 8681,  name: "Yacht Rock Radio",    description: "The smoothest hits of the 70s & 80s"),
        RadioStation(id: 6950,  name: "Alternative Rewind",  description: "90s & 2000s alternative"),
        RadioStation(id: 7934,  name: "Lost 80s",            description: "80s hits you forgot you loved"),
        RadioStation(id: 10252, name: "The Valley 80s",      description: "Classic 80s hits"),
        RadioStation(id: 5060,  name: "iHeart80s Radio",     description: "All 80s, all the time"),
    ]
}

// MARK: - ZonePickerSheet
// Zone list with current playing context — shows what each zone is playing
// so user knows what they'd be replacing before picking.

struct ZonePickerSheet: View {
    let station: RadioStation
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

                // Station being queued
                VStack(spacing: 4) {
                    Text(station.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.sTextPrimary)
                    Text("Select a zone to play on")
                        .font(.system(size: 13))
                        .foregroundColor(.sTextMuted)
                }
                .padding(.vertical, 16)

                Divider().background(Color.sSeparator)

                // Zone list with context
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(discovery.zones) { zone in
                            Button(action: { onPick(zone) }) {
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

                                    // Zone name + current context
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

// MARK: - IHeartAPI
// Fetches station metadata from iHeart v2 API.

enum IHeartAPI {
    static func fetchStationLogo(streamID: Int) async -> String? {
        guard let url = URL(string: "https://us.api.iheart.com/api/v2/content/liveStations/\(streamID)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 5
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let hits = json?["hits"] as? [[String: Any]]
            return hits?.first?["logo"] as? String
        } catch {
            return nil
        }
    }

    static func fetchStreamURL(streamID: Int) async -> String? {
        guard let url = URL(string: "https://us.api.iheart.com/api/v2/content/liveStations/\(streamID)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 5
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let hits = json?["hits"] as? [[String: Any]],
                  let station = hits.first,
                  let streams = station["streams"] as? [String: Any] else { return nil }
            // Sonos requires hls-radio:// wrapper with HTTP HLS URL
            // HTTPS URLs don't work with SetAVTransportURI on port 1400
            if let hlsStream = streams["hls_stream"] as? String {
                print("SORRIVA: Stream URL for \(streamID): hls-radio://\(hlsStream)")
                return "hls-radio://\(hlsStream)"
            }
            return streams["shoutcast_stream"] as? String
        } catch {
            print("SORRIVA: fetchStreamURL error: \(error.localizedDescription)")
            return nil
        }
    }
}
