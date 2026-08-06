import SwiftUI
import Combine

// MARK: - PlaybackStore
// Single authoritative owner of all playback presentation state.
// Constitution reference: I-002, ADR-005.
//
// Only PlaybackStateReducer writes to this store.
// Views, screen models, and endpoint drivers observe only — never write directly.

@MainActor
final class PlaybackStore: ObservableObject {

    static let shared = PlaybackStore()

    @Published private(set) var zones: [ZonePlaybackSnapshot] = []
    @Published private(set) var selectedEndpointID: String?
    @Published private(set) var pendingCommand: PendingPlaybackCommand?
    @Published private(set) var issue: PlaybackIssue?

    /// What each zone has been authoritatively told to be playing, keyed by zone id.
    /// Written only via declare(_:) — see the declarations section below.
    @Published private(set) var declarations: [String: PlaybackDeclaration] = [:]

    /// The last thing each zone was known to be playing. Never expires.
    ///
    /// Without this, "what was this zone playing?" had no owner: it was inferred from
    /// residue left in SonosZone's raw fields, which polling mutates, plus a zone_state
    /// row only one code path ever wrote. Every arbitration between those two produced
    /// a bug — a zone reverting to an older station, artwork blanking after a handoff,
    /// one station's art surviving onto another. Owning it here removes the arbitration
    /// entirely: a playing zone renders its current declaration, a stopped one renders
    /// this, and nothing needs clearing.
    @Published private(set) var lastDeclarations: [String: PlaybackDeclaration] = [:]

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: - Observation setup

    /// Wire the store to its upstream sources.
    /// Called once from SorrivaAppEnvironment.init.
    func observe(discovery: ZoneDiscoveryService,
                 playbackContext: PlaybackContextService) {
        // Every zone should show what it was playing before the app closed, so restore
        // that before wiring anything up.
        restoreLastPlaying()

        // Reduce whenever any source updates — raw zone state, detected context, a
        // current declaration, or the last-playing record.
        // Nested rather than CombineLatest5 — the operator stops at four. Transport
        // intents are folded in so a command alone re-reduces, without waiting for the
        // next poll to publish zones.
        Publishers.CombineLatest4(
            discovery.$zones,
            playbackContext.$contexts,
            $declarations,
            $lastDeclarations
        )
        .combineLatest($transportIntents)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] content, intents in
            let (sonosZones, contexts, declarations, lastDeclarations) = content
            self?.reduce(sonosZones: sonosZones,
                         contexts: contexts,
                         declarations: declarations,
                         lastDeclarations: lastDeclarations,
                         transportIntents: intents)
        }
        .store(in: &cancellables)
    }

    // MARK: - State mutations (internal only)

    func setPendingCommand(_ command: PendingPlaybackCommand?) {
        pendingCommand = command
    }

    func setIssue(_ issue: PlaybackIssue?) {
        self.issue = issue
    }

    func setSelectedEndpoint(_ id: String?) {
        selectedEndpointID = id
    }

    // MARK: - Declarations

    /// Authoritatively declare what a zone is now playing.
    ///
    /// Called by whichever action caused the change, at the moment it acts — that
    /// is the one moment the app reliably knows the content and the URI together.
    /// Sonos frequently cannot supply the name afterwards (empty stream titles;
    /// it never has local album art), which is why the app declares rather than
    /// waiting to infer it from a later poll.
    func declare(zoneID: String,
                 context: PlaybackContext,
                 uri: String,
                 source: PlaybackDeclaration.Source = .app) {
        let declaration = PlaybackDeclaration(context: context,
                                              uri: uri,
                                              source: source,
                                              declaredAt: Date())
        declarations[zoneID] = declaration
        // Every declaration is also the zone's most recent known playback, so it
        // becomes "last playing" immediately. Clearing the current one then leaves this
        // behind rather than losing it, which is what a stopped zone renders.
        lastDeclarations[zoneID] = declaration
        persistLastPlaying(declaration, zoneID: zoneID)
    }

    /// The app's optimistic transport claims, by zone. Written when a command is issued,
    /// honoured by the reducer only while inside `declarationGrace`.
    ///
    /// Step 2 of replacing `SonosZone.playingUntil`: this is populated and published but
    /// the reducer does not read it yet, so behaviour is unchanged until step 3.
    @Published private(set) var transportIntents: [String: TransportIntent] = [:]

    /// Record that the app has just told a zone to start or stop.
    ///
    /// Use this for anything that changes transport — play, pause, station start, local
    /// play, transfer, grouping — including the cases that make no claim about content.
    func declareTransport(zoneID: String, playing: Bool) {
        transportIntents[zoneID] = TransportIntent(isPlaying: playing, declaredAt: Date())
    }

    /// Rebuild `lastDeclarations` from disk. Called once at launch so every zone shows
    /// what it was playing before the app was closed, not a blank card.
    func restoreLastPlaying() {
        guard let rows = try? SorrivaDatabase.shared.allZoneLastPlaying(), !rows.isEmpty else { return }
        for row in rows {
            // Local tracks carry their album object for artwork; re-fetch it, since only
            // the id is persisted.
            let album = row.albumId.flatMap { try? SorrivaDatabase.shared.album(id: $0) }
            lastDeclarations[row.zoneId] = PlaybackDeclaration(
                context: PlaybackContext(track: row.track,
                                         artist: row.artist,
                                         albumName: row.albumName,
                                         duration: 0,
                                         artAlbum: album,
                                         artURL: row.artURL,
                                         isLocal: row.isLocal),
                uri: row.uri,
                // Restored state is a record of the past, not a live claim about what is
                // playing now — so it must never win the precedence rule's grace window.
                source: .external,
                declaredAt: Date(timeIntervalSince1970: TimeInterval(row.updatedAt))
            )
        }
        sLog("PLAYBACK: restored last-playing for \(rows.count) zone(s)")
    }

    private func persistLastPlaying(_ declaration: PlaybackDeclaration, zoneID: String) {
        let entry = ZoneLastPlaying(zoneId: zoneID,
                                    uri: declaration.uri,
                                    track: declaration.context.track,
                                    artist: declaration.context.artist,
                                    albumName: declaration.context.albumName,
                                    artURL: declaration.context.artURL,
                                    albumId: declaration.context.artAlbum?.id,
                                    isLocal: declaration.context.isLocal,
                                    updatedAt: Int(Date().timeIntervalSince1970))
        try? SorrivaDatabase.shared.upsertZoneLastPlaying(entry)
    }

    /// Drop a zone's declaration — the app no longer claims to know what it plays.
    func clearDeclaration(zoneID: String) {
        declarations[zoneID] = nil
    }

    /// Hand a zone's declaration to another zone.
    ///
    /// A transfer changes WHERE content plays, not WHAT — so the destination should
    /// inherit the source's declaration rather than a copy of its raw fields. Copying
    /// fields is precisely how a stale station name used to survive: name and its URI
    /// were copied together, arriving as a self-consistent pair that the staleness
    /// check could not distinguish from a fresh one. A declaration carries its own URI,
    /// so it is still checked against what Sonos reports and cannot smuggle stale text.
    ///
    /// `declaredAt` restarts because the destination has only just been told to play.
    func moveDeclaration(from: String, to: String) {
        guard let existing = declarations[from] else {
            clearDeclaration(zoneID: to)
            return
        }
        declare(zoneID: to, context: existing.context, uri: existing.uri, source: existing.source)
        // The source stops playing, but its lastDeclaration deliberately survives — that
        // is what it last played, and what its card should keep showing.
        declarations[from] = nil
    }

    /// Restart a declaration's grace window.
    ///
    /// Multi-step actions (a transfer runs group → settle → release → play over several
    /// seconds) would otherwise burn most of the window on the command sequence itself,
    /// leaving little of it for the period where Sonos is actually catching up.
    func touchDeclaration(zoneID: String) {
        guard let existing = declarations[zoneID] else { return }
        declarations[zoneID] = PlaybackDeclaration(context: existing.context,
                                                   uri: existing.uri,
                                                   source: existing.source,
                                                   declaredAt: Date())
    }

    // MARK: - Convenience accessors

    func snapshot(for zoneID: String) -> ZonePlaybackSnapshot? {
        zones.first(where: { $0.id == zoneID })
    }

    var selectedSnapshot: ZonePlaybackSnapshot? {
        guard let id = selectedEndpointID else { return nil }
        return snapshot(for: id)
    }

    // MARK: - Reducer

    private func reduce(sonosZones: [SonosZone],
                        contexts: [String: PlaybackContext],
                        declarations: [String: PlaybackDeclaration],
                        lastDeclarations: [String: PlaybackDeclaration],
                        transportIntents: [String: TransportIntent]) {
        zones = PlaybackStateReducer.reduce(sonosZones: sonosZones,
                                            contexts: contexts,
                                            declarations: declarations,
                                            lastDeclarations: lastDeclarations,
                                            transportIntents: transportIntents,
                                            previous: zones)
    }
}

// MARK: - PlaybackStateReducer

enum PlaybackStateReducer {

    /// How long an app declaration is honoured while Sonos has not yet reported the
    /// URI we asked it to play. 5s matches the observed post-command transport lag
    /// (the optimistic windows in ZoneDiscoveryService use 5-6s). In the normal case
    /// this never elapses — a URI match short-circuits it the moment Sonos confirms.
    static let declarationGrace: TimeInterval = 5

    /// Which content should this zone display this tick?
    ///
    /// Sonos is authoritative for the URI; the app is authoritative for naming it.
    /// The binding rule: a declaration is honoured only while its URI still matches
    /// what Sonos reports. See HANDOFF-playbackstore-design.md section 5.
    /// What to display when Sonos confirms the URI we declared.
    ///
    /// The declaration is authoritative only for what Sonos CANNOT report. One URI does
    /// not mean one piece of content: a local file's URI changes with every track, so a
    /// declaration describes exactly one thing and stays true for as long as the URI
    /// does. A stream's URI is the STATION — `…/zc7934/hls.m3u8` is unchanged while the
    /// songs change — so a declaration that claimed the whole payload matched on every
    /// poll forever and pinned the track on screen at the moment the station started.
    ///
    /// Real repro (bStationTrackFrozenByDeclaration): Master Bedroom on iHeart Lost 80s,
    /// Sonos reporting Eurythmics and then Prince ~80s later, the app showing Chaka Khan
    /// from several songs earlier. Station name and artwork were right, because those
    /// genuinely are the app's to supply. Polling had the correct track the whole time
    /// and was being discarded by design.
    ///
    /// So the boundary is compositional rather than exclusive: the app supplies station
    /// identity (Sonos returns a filename or a slug for `dc:title`, and no artwork at
    /// all), and Sonos supplies now-playing (`r:streamContent`, live and correct).
    private static func confirmedContent(declaration: PlaybackDeclaration,
                                         zone: SonosZone,
                                         previous: ZonePlaybackSnapshot?) -> PlaybackContext {
        var content = declaration.context

        // Local content: Sonos has neither the track nor the art, so the app owns all
        // of it and the declaration stands exactly as before.
        guard !content.isLocal else { return content }

        if !zone.currentTrack.isEmpty {
            content.track = zone.currentTrack
            content.artist = zone.currentArtist
        } else if let previous, !previous.trackTitle.isEmpty {
            // Sonos reports an empty title between songs. Holding the previous track
            // honours the no-blank rule rather than flashing empty at every boundary.
            content.track = previous.trackTitle
            content.artist = previous.artistName
        }
        return content
    }

    private static func resolveContent(zone: SonosZone,
                                       declaration: PlaybackDeclaration?,
                                       lastDeclaration: PlaybackDeclaration?,
                                       context: PlaybackContext?,
                                       previous: ZonePlaybackSnapshot?,
                                       now: Date) -> PlaybackContext? {
        if let declaration {
            // 1. Sonos confirms what we declared — authoritative for the parts Sonos
            //    cannot report. See confirmedContent: this is NOT a blanket override.
            if !zone.currentTrackURI.isEmpty, zone.currentTrackURI == declaration.uri {
                return confirmedContent(declaration: declaration, zone: zone,
                                        previous: previous)
            }
            // 2. Our own command, Sonos has not caught up yet — hold the declaration.
            if declaration.source == .app,
               now.timeIntervalSince(declaration.declaredAt) < declarationGrace {
                return declaration.context
            }
            // 3. Past grace and the URI moved on — the declaration is stale.
            //    Fall through to whatever detection has produced.
        }

        // What polling resolved for the URI Sonos reports right now — a station matched
        // against the stations table, a local file against our own database.
        //
        // This runs BEFORE the stored last-playing at the bottom, and the order is the
        // point. A stopped zone was previously answered from the store outright and this
        // line was never reached, so the resolved answer was computed every poll and then
        // discarded (bStoredLastPlayingOutranksResolvedContent). Sonos keeps reporting the
        // URI a stopped zone is parked on, so it can always tell us what a zone last
        // played — including content started from the Sonos app, which the store has no
        // record of at all.
        //
        // The rule that used to sit here was written to stop the card reading RAW
        // SonosZone fields like `stationName`, which polling mutates and which caused the
        // reverting-station and blanking-artwork bugs. That reasoning holds for raw
        // fields. This context is not raw residue — it is the URI enriched by our
        // database — and blocking it too was over-correction.
        if let context { return context }

        // No-blank rule: an actively-playing zone never renders empty content. Hold
        // the last known content until a replacement resolves, then swap atomically.
        if zone.isPlaying, let previous,
           !previous.trackTitle.isEmpty || !previous.albumName.isEmpty {
            return PlaybackContext(track: previous.trackTitle,
                                   artist: previous.artistName,
                                   albumName: previous.albumName,
                                   duration: Double(previous.durationSeconds),
                                   artAlbum: previous.artAlbum,
                                   artURL: previous.artURL,
                                   isLocal: previous.isLocal)
        }

        // Nothing current and nothing detected — fall back to the last known playback.
        // This is now the ONLY job the stored copy does, and the one it is genuinely
        // needed for: a zone Sonos cannot describe, such as a speaker back from a power
        // cut with an empty transport. Whenever Sonos can describe it, the resolved
        // answer above wins and the card self-heals on the next poll.
        return lastDeclaration?.context
    }

    static func reduce(sonosZones: [SonosZone],
                       contexts: [String: PlaybackContext],
                       declarations: [String: PlaybackDeclaration] = [:],
                       lastDeclarations: [String: PlaybackDeclaration] = [:],
                       transportIntents: [String: TransportIntent] = [:],
                       previous: [ZonePlaybackSnapshot] = [],
                       now: Date = Date()) -> [ZonePlaybackSnapshot] {
        sonosZones.map { zone in
            let ctx = resolveContent(zone: zone,
                                     declaration: declarations[zone.id],
                                     lastDeclaration: lastDeclarations[zone.id],
                                     context: contexts[zone.id],
                                     previous: previous.first(where: { $0.id == zone.id }),
                                     now: now)
            let isLocal = ctx?.isLocal == true

            // Transport optimism. For a short window after the app issues a command, its
            // claim outranks polling — otherwise a zone reads as idle between the command
            // and Sonos confirming it, and the card flickers.
            //
            // Bounded deliberately: past the window Sonos wins, so a command that silently
            // failed cannot leave a zone permanently claiming to play. Applied ONLY to
            // transport here; content optimism is the declaration's job and already
            // handled in resolveContent.
            let intent = transportIntents[zone.id]
            let intentIsFresh = intent.map {
                now.timeIntervalSince($0.declaredAt) < declarationGrace
            } ?? false
            let isPlaying = intentIsFresh ? (intent?.isPlaying ?? zone.isPlaying) : zone.isPlaying

            // Display state — always from PlaybackContextService.
            // PlaybackStore is the single authority: one path for all sources.
            let trackTitle  = ctx?.track    ?? ""
            let artistName  = ctx?.artist   ?? ""
            let albumName   = ctx?.albumName ?? ""
            let artAlbum    = ctx?.artAlbum
            let artURL      = ctx?.artURL
            let sourceLabel = isLocal ? "Local Library" : ""
            // Duration is transport truth — Sonos reads the file itself and reports it.
            // Prefer the scanned value, but fall back to what Sonos says so a track the
            // scanner could not measure still shows a total time, with no rescan needed.
            let scannedDuration = Int(ctx?.duration ?? 0)
            let duration    = isLocal
                ? (scannedDuration > 0 ? scannedDuration : zone.durationSeconds)
                : zone.durationSeconds

            return ZonePlaybackSnapshot(
                id:              zone.id,
                name:            zone.name,
                host:            zone.host,
                isPlaying:       isPlaying,
                volume:          zone.volume,
                isHDMI:          zone.isHDMI,
                idleState:       zone.idleState,
                trackTitle:      trackTitle,
                artistName:      artistName,
                albumName:       albumName,
                sourceLabel:     sourceLabel,
                isLocal:         isLocal,
                elapsedSeconds:  zone.elapsedSeconds,
                durationSeconds: duration,
                artAlbum:        artAlbum,
                artURL:          artURL,
                groupMembers:    zone.groupMembers,
                coordinatorID:   nil,
                isAvailable:     !zone.idleState || isPlaying
            )
        }
    }
}
