import SwiftUI

// MARK: - VolumeControlView
// Mute | − 2 | [slider] | + 2 | [volume number]
// Tap track left of thumb = −4, right = +4.
// Drag thumb for continuous control.

struct VolumeControlView: View {
    let zoneID: String
    var memberID: String? = nil      // When set, controls this member's volume independently
    var memberName: String? = nil    // Label shown when controlling a member
    @ObservedObject var discovery: ZoneDiscoveryService
    @State private var isDragging = false
    @State private var dragVolume: Int? = nil
    @State private var preMuteVolume: Int? = nil
    @State private var preMuteGroupVolumes: [String: Int] = [:]

    private var volume: Int {
        if let mid = memberID {
            if mid == zoneID {
                // Coordinator individual
                return dragVolume ?? discovery.zones.first(where: { $0.id == zoneID })?.volume ?? 0
            }
            // Member individual
            return dragVolume ?? discovery.zones
                .first(where: { $0.id == zoneID })?
                .groupMembers.first(where: { $0.id == mid })?.volume ?? 0
        }
        // Group master (default)
        return dragVolume ?? discovery.zones.first(where: { $0.id == zoneID })?.volume ?? 0
    }

    private var isMuted: Bool { volume == 0 }

    private func set(_ vol: Int) {
        let clamped = max(0, min(100, vol))
        if let mid = memberID {
            discovery.setMemberVolume(zoneID: zoneID, memberID: mid, volume: clamped)
        } else {
            discovery.setVolume(zoneID: zoneID, volume: clamped)
        }
    }

    var body: some View {
        HStack(spacing: 10) {

            // Mute button — group master mutes all members explicitly
            Button(action: {
                if isMuted {
                    if memberID == nil {
                        // Group master unmute — restore all pre-mute volumes
                        discovery.muteGroup(zoneID: zoneID, mute: false, restoreVolumes: preMuteGroupVolumes)
                        preMuteGroupVolumes = [:]
                    } else {
                        set(preMuteVolume ?? 15)
                        preMuteVolume = nil
                    }
                } else {
                    if memberID == nil {
                        // Group master mute — capture all volumes first
                        if let zone = discovery.zones.first(where: { $0.id == zoneID }) {
                            preMuteGroupVolumes[zoneID] = zone.volume
                            for member in zone.groupMembers {
                                preMuteGroupVolumes[member.id] = member.volume
                            }
                        }
                        discovery.muteGroup(zoneID: zoneID, mute: true)
                    } else {
                        preMuteVolume = volume
                        set(0)
                    }
                }
            }) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .foregroundColor(isMuted ? .sBrass : .sHighlight)
                    .frame(width: 30, height: 30)
                    .background(Color.sSurface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            // − 1
            Button(action: { set(volume - 1) }) {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.sHighlight)
                    .frame(width: 30, height: 30)
                    .background(Color.sSurface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            // Custom slider
            GeometryReader { geo in
                let thumbX = geo.size.width * CGFloat(volume) / 100.0

                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 6)

                    // Fill
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.sHighlight)
                        .frame(width: max(0, thumbX), height: 6)

                    // Thumb
                    Circle()
                        .fill(Color.sHighlight)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        .offset(x: max(0, thumbX - 8))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    isDragging = true
                                    let pct = max(0, min(1, value.location.x / geo.size.width))
                                    dragVolume = Int(pct * 100)
                                }
                                .onEnded { value in
                                    let pct = max(0, min(1, value.location.x / geo.size.width))
                                    set(Int(pct * 100))
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        isDragging = false
                                        dragVolume = nil
                                    }
                                }
                        )
                }
                .frame(height: 16)
                .onTapGesture { location in
                    guard !isDragging else { return }
                    if location.x > thumbX {
                        set(volume + 3)
                    } else {
                        set(volume - 3)
                    }
                }
            }
            .frame(height: 16)

            // + 1
            Button(action: { set(volume + 1) }) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.sHighlight)
                    .frame(width: 30, height: 30)
                    .background(Color.sSurface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            // Volume number
            Text("\(volume)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.sTextMuted)
                .frame(width: 28, alignment: .trailing)
                .monospacedDigit()
        }
    }

}
