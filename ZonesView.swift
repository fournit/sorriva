import SwiftUI

// MARK: - ZonesView

struct ZonesView: View {
    @ObservedObject var discovery: ZoneDiscoveryService
    @ObservedObject var playbackContext: PlaybackContextService
    @Binding var expandZoneID: String?
    var onNowPlaying: ((String) -> Void)? = nil
    @EnvironmentObject private var tabState: SorrivaTabBarState
    @State private var scrollToZoneID: String? = nil

    // Persisted expanded zone IDs — JSON-encoded set of zone IDs
    @AppStorage("sorriva.expandedZoneIDs") private var expandedZoneIDsJSON: String = "[]"

    private var expandedZoneIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: Data(expandedZoneIDsJSON.utf8))) ?? []
    }

    private func setExpanded(_ zoneID: String, _ expanded: Bool) {
        var ids = expandedZoneIDs
        if expanded { ids.insert(zoneID) } else { ids.remove(zoneID) }
        expandedZoneIDsJSON = (try? String(data: JSONEncoder().encode(ids), encoding: .utf8)) ?? "[]"
    }

    private func expandAll() {
        let ids = Set(discovery.zones.map { $0.id })
        expandedZoneIDsJSON = (try? String(data: JSONEncoder().encode(ids), encoding: .utf8)) ?? "[]"
    }

    private func collapseAll() {
        expandedZoneIDsJSON = "[]"
    }

    var body: some View {
        VStack(spacing: 0) {

            // Navigation bar
            HStack {
                SorrivaWordmark()
                Spacer()
                // Expand all
                Button(action: expandAll) {
                    Image(systemName: "arrow.up.and.line.horizontal.and.arrow.down")
                        .font(.system(size: 16))
                        .foregroundColor(.sHighlight)
                }
                .buttonStyle(.plain)
                // Collapse all
                Button(action: collapseAll) {
                    Image(systemName: "arrow.down.and.line.horizontal.and.arrow.up")
                        .font(.system(size: 16))
                        .foregroundColor(.sHighlight)
                }
                .buttonStyle(.plain)
                .padding(.leading, 14)
                // Refresh
                if discovery.isDiscovering {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.sHighlight)
                        .scaleEffect(0.8)
                        .padding(.leading, 14)
                } else {
                    Button(action: { discovery.refresh() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18))
                            .foregroundColor(.sHighlight)
                    }
                    .padding(.leading, 14)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)
            .padding(.bottom, 16)

            if let error = discovery.discoveryError {
                errorView(message: error)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(discovery.zones) { zone in
                                EquatableView(content: ZoneCard(
                                    zone: zone,
                                    discovery: discovery,
                                    playbackContext: playbackContext,
                                    autoExpand: expandZoneID == zone.id,
                                    forceExpanded: expandedZoneIDs.contains(zone.id),
                                    onNowPlaying: { zoneID in
                                        onNowPlaying?(zoneID)
                                    },
                                    onExpandedChanged: { expanded in
                                        setExpanded(zone.id, expanded)
                                    }
                                ))
                                .id(zone.id)
                            }
                        }
                        .padding(.horizontal, 0)
                        .padding(.bottom, 24)
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { geo in
                        geo.contentOffset.y
                    } action: { oldY, newY in
                        let delta = newY - oldY
                        print("SCROLL: delta=\(delta) newY=\(newY)")
                        if delta > 8 {
                            tabState.hide()
                        } else if delta < -8 {
                            tabState.show()
                        }
                    }
                    .onChange(of: expandZoneID) { zoneID in
                        guard let zoneID else { return }
                        scrollToZoneID = zoneID
                        // Scroll after expand animation completes
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(zoneID, anchor: .center)
                            }
                        }
                    }
                    .onAppear {
                        // Handle expandZoneID set before this view appeared
                        if let zoneID = expandZoneID {
                            scrollToZoneID = zoneID
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    proxy.scrollTo(zoneID, anchor: .center)
                                }
                                expandZoneID = nil
                            }
                        }
                    }
                }
            }
        }
        .background(Color.clear)
    }

    @ViewBuilder
    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "wifi.slash")
                .font(.system(size: 36))
                .foregroundColor(.sTextMuted)
            Text("Discovery failed")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.sTextPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.sTextMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Try again") { discovery.startDiscovery() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.sAccent)
            Spacer()
        }
    }
}

// MARK: - EQ Bars
// Animated equalizer bars shown on playing zones

struct EQBarsView: View {
    @State private var heights: [CGFloat] = [0.4, 0.7, 0.5, 0.9, 0.6]
    @State private var animating = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.sHighlight)
                    .frame(width: 3, height: 14 * heights[i])
            }
        }
        .frame(width: 20, height: 14)
        .onAppear { startAnimating() }
        .onDisappear { animating = false }
    }

    private func startAnimating() {
        animating = true
        animate()
    }

    private func animate() {
        guard animating else { return }
        withAnimation(.easeInOut(duration: Double.random(in: 0.3...0.6))) {
            heights = (0..<5).map { _ in CGFloat.random(in: 0.2...1.0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.3...0.6)) {
            guard animating else { return }
            animate()
        }
    }
}

// MARK: - ZoneCard

struct ZoneCard: View, Equatable {
    static func == (lhs: ZoneCard, rhs: ZoneCard) -> Bool {
        lhs.zone == rhs.zone && lhs.autoExpand == rhs.autoExpand && lhs.forceExpanded == rhs.forceExpanded
    }

    let zone: SonosZone
    @ObservedObject var discovery: ZoneDiscoveryService
    @ObservedObject var playbackContext: PlaybackContextService
    let autoExpand: Bool
    let forceExpanded: Bool
    let onNowPlaying: (String) -> Void
    var onExpandedChanged: ((Bool) -> Void)? = nil
    @State private var isExpanded = false
    @State private var showEQ = false
    @State private var showGroupPicker = false
    @State private var showTransferPicker = false
    @State private var contextVersion: Int = 0

    private var liveZone: SonosZone? {
        discovery.zones.first(where: { $0.id == zone.id })
    }

    private var localContext: PlaybackContext? {
        let ctx = playbackContext.contexts[zone.id]
        return ctx?.isLocal == true ? ctx : nil
    }

    private var isPlaying: Bool { liveZone?.isPlaying ?? false }

    private var artPlaceholder: some View {
        let z = liveZone ?? zone
        return RoundedRectangle(cornerRadius: 8)
            .fill(Color.sCard)
            .overlay(
                Image(systemName: z.isHDMI ? "tv.fill" : "music.note")
                    .font(.system(size: z.isHDMI ? 20 : 18))
                    .foregroundColor(.sTextMuted)
            )
    }

    var body: some View {
        VStack(spacing: 0) {

            // Card header
            HStack(spacing: 12) {

                // Station/local art thumbnail — square, 48pt
                let z = liveZone ?? zone
                let artKey = "\(localContext?.artAlbum?.id ?? "")-\(z.stationLogoURL)-\(contextVersion)"
                Group {
                    if let album = localContext?.artAlbum {
                        AlbumArtView(album: album, size: 48)
                            .id(album.id)
                    } else if !z.stationLogoURL.isEmpty,
                       let artURL = URL(string: z.stationLogoURL) {
                        CachedAsyncImage(url: artURL) { phase in
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
                .id(artKey)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Text block — zone name + EQ on same line, station + track below
                VStack(alignment: .leading, spacing: 2) {
                    // Zone name + EQ bars inline
                    HStack(spacing: 6) {
                        Text(zone.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                        if isPlaying {
                            EQBarsView()
                                .frame(width: 18, height: 12)
                        }
                    }

                    // Group members — same visual weight as coordinator
                    if !z.groupMembers.isEmpty {
                        ForEach(z.groupMembers, id: \.id) { member in
                            Text(member.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.sTextPrimary)
                                .lineLimit(1)
                        }
                    }

                    // Source label — album name for local tracks, station name for streams
                    let sourceLabel: String = {
                        if let ctx = localContext { return ctx.albumName }
                        return z.stationName
                    }()
                    if !sourceLabel.isEmpty {
                        Text(sourceLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.sBrass)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                        onExpandedChanged?(isExpanded)
                    }
                }

                // Play/pause — far right
                Button(action: { discovery.togglePlayPause(zoneID: zone.id) }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .foregroundColor(isPlaying ? .sHighlight : .sTextMuted)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Expanded controls
            if isExpanded {
                VStack(spacing: 16) {
                    Divider()
                        .background(Color.sSeparator)
                        .padding(.horizontal, 16)

                    // Volume — group master (applies delta to all members)
                    VolumeControlView(zoneID: zone.id, discovery: discovery)
                        .padding(.horizontal, 16)

                    // Individual member volume controls
                    let liveMembers = (liveZone ?? zone).groupMembers
                    if !liveMembers.isEmpty {
                        Divider()
                            .background(Color.sSeparator)
                            .padding(.horizontal, 16)

                        // Sync + Ungroup buttons
                        HStack {
                            Spacer()

                            // Ungroup
                            Button(action: {
                                discovery.ungroupZone(zoneID: zone.id)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "rectangle.on.rectangle.slash")
                                        .font(.system(size: 11))
                                    Text("Ungroup")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(.sHighlight)
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .frame(height: 12)
                                .padding(.horizontal, 8)

                            // Sync
                            Button(action: {
                                let coordVol = (liveZone ?? zone).volume
                                for member in liveMembers {
                                    discovery.setMemberVolume(zoneID: zone.id, memberID: member.id, volume: coordVol)
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.left.arrow.right")
                                        .font(.system(size: 11))
                                    Text("Sync")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(.sHighlight)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)

                        // Coordinator individual row
                        VStack(alignment: .leading, spacing: 4) {
                            Text(zone.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.sTextMuted)
                                .padding(.horizontal, 16)
                            VolumeControlView(zoneID: zone.id, memberID: zone.id, discovery: discovery)
                                .padding(.horizontal, 16)
                        }

                        // Member individual rows
                        ForEach(liveMembers, id: \.id) { member in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(member.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.sTextMuted)
                                    .padding(.horizontal, 16)
                                VolumeControlView(zoneID: zone.id, memberID: member.id, discovery: discovery)
                                    .padding(.horizontal, 16)
                            }
                        }
                    }

                    // Action row — icon only
                    HStack(spacing: 0) {
                        // Group
                        Button(action: { showGroupPicker = true }) {
                            Image(systemName: "rectangle.3.group")
                                .font(.system(size: 18))
                                .foregroundColor(.sHighlight)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        // Transfer
                        Button(action: { showTransferPicker = true }) {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 18))
                                .foregroundColor(isPlaying && liveMembers.isEmpty ? .sHighlight : .sTextMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(!isPlaying || !liveMembers.isEmpty)

                        // EQ
                        Button(action: { if liveMembers.isEmpty { showEQ = true } }) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 18))
                                .foregroundColor(liveMembers.isEmpty ? .sHighlight : .sTextMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        // Now Playing
                        Button(action: { if isPlaying { onNowPlaying(zone.id) } }) {
                            Image(systemName: "music.note")
                                .font(.system(size: 18))
                                .foregroundColor(isPlaying ? .sBrass : .sTextMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 14)
                }
            }
        }
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .sheet(isPresented: $showEQ) {
            if let liveZone = discovery.zones.first(where: { $0.id == zone.id }) {
                EQSheet(zone: liveZone, discovery: discovery)
                    .presentationDetents([.height(EQSheet.sheetHeight(for: liveZone))])
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .height(EQSheet.sheetHeight(for: liveZone))))
                    .presentationBackground(Color.sCard)
            }
        }
        .sheet(isPresented: $showGroupPicker) {
            GroupPickerSheet(coordinatorZone: zone, discovery: discovery)
        }
        .sheet(isPresented: $showTransferPicker) {
            TransferZoneSheet(sourceZone: zone, discovery: discovery)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            // Restore persisted state first
            if forceExpanded && !isExpanded {
                isExpanded = true
            }
            // autoExpand from tab navigation overrides
            if autoExpand && !isExpanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded = true
                        onExpandedChanged?(true)
                    }
                }
            }
        }
        .onChange(of: forceExpanded) { newValue in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded = newValue
            }
        }
        .onReceive(playbackContext.$contexts) { _ in
            contextVersion += 1
        }
    }
}

#Preview {
    ZonesView(discovery: ZoneDiscoveryService(), playbackContext: PlaybackContextService.shared, expandZoneID: .constant(nil))
        .preferredColorScheme(.dark)
}

// MARK: - GroupPickerSheet

struct GroupPickerSheet: View {
    let coordinatorZone: SonosZone
    @ObservedObject var discovery: ZoneDiscoveryService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIDs: Set<String> = []
    @State private var hasChanges = false

    // Flat list of ALL rooms — coordinators + their members, minus invisible satellites
    private var allRooms: [RoomEntry] {
        var rooms: [RoomEntry] = []
        for zone in discovery.zones {
            // Add the coordinator
            rooms.append(RoomEntry(
                id: zone.id,
                name: zone.name,
                host: zone.host,
                isPlaying: zone.isPlaying,
                stationName: zone.stationName,
                currentTrack: zone.currentTrack,
                currentArtist: zone.currentArtist,
                coordinatorName: nil,  // it IS a coordinator
                isCoordinator: true
            ))
            // Add its members
            for member in zone.groupMembers {
                rooms.append(RoomEntry(
                    id: member.id,
                    name: member.name,
                    host: member.host,
                    isPlaying: zone.isPlaying,       // inherits coordinator state
                    stationName: zone.stationName,
                    currentTrack: zone.currentTrack,
                    currentArtist: zone.currentArtist,
                    coordinatorName: zone.id != coordinatorZone.id ? zone.name : nil,
                    isCoordinator: false
                ))
            }
        }
        // Remove the coordinator zone itself — can't add yourself
        return rooms.filter { $0.id != coordinatorZone.id }.sorted { $0.name < $1.name }
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
                        Text("Group")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.sTextPrimary)
                        Text(coordinatorZone.name)
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                    }

                    Spacer()

                    // Placeholder to balance X button
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.top, 8)

                Divider().background(Color.sSeparator)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(allRooms, id: \.id) { room in
                            let isSelected = selectedIDs.contains(room.id)

                            Button(action: { toggleRoom(room) }) {
                                HStack(spacing: 12) {
                                    // Playing indicator — EQ bars or dot
                                    if room.isPlaying {
                                        EQBarsView()
                                            .frame(width: 16, height: 12)
                                    } else {
                                        Circle()
                                            .fill(Color.sIdle)
                                            .frame(width: 8, height: 8)
                                            .padding(.horizontal, 4)
                                    }

                                    // Zone info
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(room.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.sTextPrimary)

                                        let context: String = {
                                            if !room.currentTrack.isEmpty {
                                                return room.stationName.isEmpty
                                                    ? room.currentTrack
                                                    : "\(room.stationName) · \(room.currentTrack)"
                                            } else if !room.stationName.isEmpty {
                                                return room.stationName
                                            }
                                            return room.isPlaying ? "Playing" : "Idle"
                                        }()
                                        Text(context)
                                            .font(.system(size: 12))
                                            .foregroundColor(room.isPlaying ? .sHighlight : .sTextMuted)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    // Coordinator name if in another group
                                    if let coordName = room.coordinatorName {
                                        Text(coordName)
                                            .font(.system(size: 11))
                                            .foregroundColor(.sTextMuted)
                                            .lineLimit(1)
                                    }

                                    // Selection indicator
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundColor(isSelected ? .sBrass : .sTextMuted)
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
                    .padding(.bottom, 16)
                }

                // Apply button — bottom centered
                Button(action: applyChanges) {
                    Text("Apply")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(hasChanges ? .white : .sTextMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(hasChanges ? Color.sAccent : Color.sSurface)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!hasChanges)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .onAppear {
            selectedIDs = Set(coordinatorZone.groupMembers.map { $0.id })
        }
    }

    private func toggleRoom(_ room: RoomEntry) {
        if selectedIDs.contains(room.id) {
            selectedIDs.remove(room.id)
        } else {
            selectedIDs.insert(room.id)
        }
        let currentMembers = Set(coordinatorZone.groupMembers.map { $0.id })
        hasChanges = selectedIDs != currentMembers
    }

    private func applyChanges() {
        let currentMembers = Set(coordinatorZone.groupMembers.map { $0.id })
        let toAdd = Array(selectedIDs.subtracting(currentMembers))
        let toRemove = Array(currentMembers.subtracting(selectedIDs))
        discovery.groupZone(coordinatorID: coordinatorZone.id, addZoneIDs: toAdd, removeZoneIDs: toRemove)
        dismiss()
    }
}

// MARK: - RoomEntry
// Flat room representation for GroupPickerSheet — includes coordinator members

struct RoomEntry {
    let id: String
    let name: String
    let host: String
    let isPlaying: Bool
    let stationName: String
    let currentTrack: String
    let currentArtist: String
    let coordinatorName: String?  // nil = standalone or in this group
    let isCoordinator: Bool
}
