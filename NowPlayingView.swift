import SwiftUI

// MARK: - NowPlayingView
// Full-screen Now Playing. Takes a zoneID and looks up the zone live from discovery
// so it never holds a stale value type. Sheet dismissal is user-controlled only —
// pausing/playing never dismisses the screen.

struct NowPlayingView: View {
    @Binding var selectedZoneID: String?
    @ObservedObject var discovery: ZoneDiscoveryService
    let onTapZone: () -> Void

    @State private var pollTask: Task<Void, Never>? = nil
    @State private var elapsed: Int = 0
    @State private var duration: Int = 0
    @State private var cachedTrack: String = ""
    @State private var cachedArtist: String = ""

    // Live zone lookup
    private var zone: SonosZone? {
        guard let id = selectedZoneID else { return nil }
        return discovery.zones.first(where: { $0.id == id })
    }
    private var zoneID: String { selectedZoneID ?? "" }
    private var zoneName: String { zone?.name ?? "" }
    private var zoneHost: String { zone?.host ?? "" }
    private var isPlaying: Bool { zone?.isPlaying ?? false }
    private var volume: Int { zone?.volume ?? 0 }

    // Track display — use cached values so pause doesn't clear the track
    // cachedTrack updates when zone has a track, never clears on pause
    private var displayTrack: String { cachedTrack.isEmpty ? (zone?.currentTrack ?? "") : cachedTrack }
    private var displayArtist: String { cachedArtist.isEmpty ? (zone?.currentArtist ?? "") : cachedArtist }
    private var stationName: String { zone?.stationName ?? "" }
    private var progress: Double { duration > 0 ? Double(elapsed) / Double(duration) : 0 }

    private var artPlaceholder: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.sCard)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 64))
                    .foregroundColor(.sTextMuted)
            )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {

            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {

                // Drag handle — swipe down to collapse
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.sSeparator)
                    .frame(width: 36, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                // Header — zone name
                Button(action: onTapZone) {
                    HStack(spacing: 6) {
                        Text("NOW PLAYING")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.sTextMuted)
                            .kerning(1.2)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(.sTextMuted)
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 2)

                Text(zoneName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.sTextSecondary)
                    .padding(.bottom, 8)

                Spacer()

                // Album art — AsyncImage from zone's stationLogoURL (same source as zone card)
                let artURL = zone?.stationLogoURL ?? ""
                Group {
                    if !artURL.isEmpty, let url = URL(string: artURL) {
                        CachedAsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            default:
                                artPlaceholder
                            }
                        }
                    } else {
                        artPlaceholder
                    }
                }
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.3), radius: 24, x: 0, y: 12)

                Spacer().frame(height: 40)

                // Track info
                // Track info — cached so pause doesn't clear display
                VStack(spacing: 8) {
                    if !displayTrack.isEmpty {
                        Text(displayTrack)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.sTextPrimary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        if !displayArtist.isEmpty {
                            Text(displayArtist)
                                .font(.system(size: 16))
                                .foregroundColor(.sTextSecondary)
                        }
                        if !stationName.isEmpty {
                            Text(stationName)
                                .font(.system(size: 14))
                                .foregroundColor(.sTextMuted)
                        }
                    } else if !stationName.isEmpty {
                        Text(stationName)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.sTextPrimary)
                        Text(isPlaying ? "Loading track..." : "Paused")
                            .font(.system(size: 14))
                            .foregroundColor(.sTextMuted)
                    } else {
                        Text(isPlaying ? "Loading..." : "Paused")
                            .font(.system(size: 18))
                            .foregroundColor(.sTextMuted)
                    }
                }
                .padding(.horizontal, 32)

                Spacer().frame(height: 40)

                // Progress bar — elapsed/duration from SOAP poll
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.sSurface)
                        .frame(height: 3)
                        .overlay(
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.sHighlight)
                                    .frame(width: geo.size.width * progress)
                            },
                            alignment: .leading
                        )
                        .padding(.horizontal, 32)

                    HStack {
                        Text(formatTime(elapsed))
                            .font(.system(size: 11))
                            .foregroundColor(.sTextMuted)
                        Spacer()
                        Text(formatTime(duration))
                            .font(.system(size: 11))
                            .foregroundColor(.sTextMuted)
                    }
                    .padding(.horizontal, 32)
                }

                Spacer().frame(height: 32)

                // Transport controls
                HStack(spacing: 48) {
                    Button(action: { discovery.skipPrevious(zoneID: zoneID) }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.sTextPrimary)
                    }
                    .buttonStyle(.plain)

                    Button(action: { discovery.togglePlayPause(zoneID: zoneID) }) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.sTextPrimary)
                    }
                    .buttonStyle(.plain)

                    Button(action: { discovery.skipNext(zoneID: zoneID) }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.sTextPrimary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer().frame(height: 32)

                // Volume
                VolumeControlView(zoneID: zoneID, discovery: discovery)
                    .padding(.horizontal, 32)

                Spacer().frame(height: 24)

                // Zone switcher
                Button(action: onTapZone) {
                    HStack(spacing: 8) {
                        Image(systemName: "hifispeaker.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.sTextMuted)
                        Text(zoneName.isEmpty ? "Select zone" : zoneName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.sTextSecondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11))
                            .foregroundColor(.sTextMuted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.sSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                Spacer().frame(height: 48)
            }
        }
        .onAppear {
            if let z = zone {
                if !z.currentTrack.isEmpty { cachedTrack = z.currentTrack }
                if !z.currentArtist.isEmpty { cachedArtist = z.currentArtist }
            }
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
        .onChange(of: selectedZoneID) { _ in
            // Reset cache and restart polling when zone changes
            cachedTrack = ""
            cachedArtist = ""
            elapsed = 0
            duration = 0
            startPolling()
        }
        .onChange(of: zone?.currentTrack ?? "") { track in
            if !track.isEmpty { cachedTrack = track }
        }
        .onChange(of: zone?.currentArtist ?? "") { artist in
            if !artist.isEmpty { cachedArtist = artist }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            // Immediate fetch of progress info
            if isPlaying, !zoneHost.isEmpty {
                await fetchProgress(host: zoneHost)
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                let host = zoneHost
                guard !host.isEmpty, isPlaying else { continue }
                await fetchProgress(host: host)
            }
        }
    }

    private func fetchProgress(host: String) async {
        guard let info = await NowPlayingView.fetchTrackInfo(host: host) else { return }
        elapsed = info.elapsedSeconds
        duration = info.durationSeconds
    }

    private func formatTime(_ secs: Int) -> String {
        String(format: "%d:%02d", secs / 60, secs % 60)
    }

    // MARK: - UPnP fetch

    static func fetchTrackInfo(host: String) async -> SonosTrackInfo? {
        let soapBody = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
            </u:GetPositionInfo>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(host):1400/MediaRenderer/AVTransport/Control"),
              let bodyData = soapBody.data(using: .utf8) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = bodyData
        request.timeoutInterval = 3

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return parsePositionInfo(data: data)
        } catch {
            return nil
        }
    }

    private static func parsePositionInfo(data: Data) -> SonosTrackInfo? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }

        let decoded = raw
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;amp;", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&apos;", with: "'")

        var title = ""
        var artist = ""
        var album = ""

        // r:streamContent pipe-delimited: TYPE=SNG|TITLE Crazy|ARTIST Icehouse|ALBUM Foo
        if let streamContent = extractXMLValue(from: decoded, tag: "r:streamContent"),
           !streamContent.isEmpty {
            for part in streamContent.components(separatedBy: "|") {
                if part.hasPrefix("TITLE ") { title = String(part.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                else if part.hasPrefix("ARTIST ") { artist = String(part.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
                else if part.hasPrefix("ALBUM ") { album = String(part.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            }
        }

        if title.isEmpty {
            let dcTitle = extractXMLValue(from: decoded, tag: "dc:title") ?? ""
            if !dcTitle.hasPrefix("http") && !dcTitle.contains(".m3u8") && !dcTitle.contains("?rj-") {
                title = dcTitle
            }
        }
        if artist.isEmpty { artist = extractXMLValue(from: decoded, tag: "dc:creator") ?? "" }
        if album.isEmpty { album = extractXMLValue(from: decoded, tag: "upnp:album") ?? "" }

        // Source label fallback for album field
        if album.isEmpty {
            if decoded.contains("hls-radio://") || decoded.contains("sonos.com-hls-radio") {
                album = "Radio"
            } else if decoded.contains("x-sonos-htastream") {
                title = title.isEmpty ? "TV" : title
                artist = artist.isEmpty ? "HDMI" : artist
            }
        }

        let elapsed = extractXMLValue(from: decoded, tag: "RelTime") ?? "0:00:00"
        let duration = extractXMLValue(from: decoded, tag: "TrackDuration") ?? "0:00:00"
        let elapsedSecs = parseSeconds(elapsed)
        let durationSecs = parseSeconds(duration)
        let progress = durationSecs > 0 ? Double(elapsedSecs) / Double(durationSecs) : 0

        return SonosTrackInfo(
            title: title, artist: artist, album: album,
            elapsedSeconds: elapsedSecs, durationSeconds: durationSecs, progress: progress
        )
    }

    private static func extractXMLValue(from raw: String, tag: String) -> String? {
        guard let start = raw.range(of: "<\(tag)>"),
              let end = raw.range(of: "</\(tag)>") else { return nil }
        let value = String(raw[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func parseSeconds(_ timeStr: String) -> Int {
        let parts = timeStr.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return 0
        }
    }
}

// MARK: - SonosTrackInfo

struct SonosTrackInfo {
    let title: String
    let artist: String
    let album: String
    let elapsedSeconds: Int
    let durationSeconds: Int
    let progress: Double

    var elapsedFormatted: String { formatTime(elapsedSeconds) }
    var durationFormatted: String { formatTime(durationSeconds) }

    private func formatTime(_ secs: Int) -> String {
        String(format: "%d:%02d", secs / 60, secs % 60)
    }
}
