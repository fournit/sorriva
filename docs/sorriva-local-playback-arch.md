# Sorriva — Local Library Playback Architecture
**v4.0 · Researched 2026-07-14 · Implemented 2026-07-14–17**

---

## The Problem

Playing local FLAC files through Sonos and Bluesound speakers — with the phone out of the audio path, no dedicated server hardware, and zero setup friction — is unsolved by any product except Roon (requires always-on hardware) and Bluesound (speaker is its own SMB client).

---

## What Was Ruled Out

| Approach | Why It Fails |
|----------|-------------|
| NAS HTTP server | Not universal — UNAS Pro has no web server capability. Only Synology/QNAP class NAS devices support this. |
| Cloud proxy | Kills audio quality, requires internet, massive storage cost. Wrong for owned media. |
| Apple TV as HTTP server | tvOS sandbox prevents file system access and SMB. Cannot read NAS files. ATV suspends apps not in foreground. |
| iPhone as permanent HTTP server | iOS suspends NWListener TCP streaming tasks on screen lock regardless of AVAudioSession or charge state. Confirmed on both iPhone and iPad. |
| iPad as Sorriva Core (HTTP server) | Same iOS background restriction applies. AVAudioSession keeps process alive for polling but not for NWListener TCP streaming. Confirmed via testing: HTTP server stops streaming when screen locks on both devices. |
| Silent audio trick to keep HTTP server alive | Rejected — phone calls interrupt the audio session, killing playback. Unacceptable UX for whole-home audio. |
| AirPlay for local hi-res files | Downgrades 24/96+ to 16/44.1. Unacceptable for audiophile use case. CD-quality files (16/44.1) are fine over AirPlay — see Playback Conductor section. |
| `x-file-cifs://` via Sonos app | Sonos removed NAS library setup from mobile app (May 2024). No programmatic path to register credentials via port 1400. |

---

## The Chosen Architecture — x-file-cifs:// Direct NAS Playback

**Sonos and Bluesound can fetch files directly from the NAS** via `x-file-cifs://` URIs. Sorriva registers the NAS share with Sonos once using a `CreateObject` UPnP call on port 1400, then sends `AddURIToQueue` commands with `x-file-cifs://` file paths. Sonos manages its own queue, fetches each file from the NAS as it plays, and advances through the album independently.

The phone is a pure remote control. No HTTP server. No iOS background restrictions. Screen can be locked. Phone calls do not interrupt playback.

```
NAS (FLAC files, SMB)
    ↓ x-file-cifs:// — Sonos fetches directly
Sonos / Bluesound (fetches file, decodes internally, outputs audio)

iPhone (Sorriva)
    ↓ UPnP/SOAP commands — queue management, transport control
Sonos / Bluesound
```

### NAS Share Registration

One-time setup per Sonos household. Sorriva sends a `CreateObject` call to the Sonos `ContentDirectory` service:

```
POST http://[sonos-ip]:1400/MediaServer/ContentDirectory/Control
SOAPACTION: "urn:schemas-upnp-org:service:ContentDirectory:1#CreateObject"

<u:CreateObject>
  <ContainerID>S:</ContainerID>
  <Elements>[DIDL with NAS path]</Elements>
</u:CreateObject>
```

Response includes `ObjectID=S://[nas-host]/[share-path]` — confirming the share is registered. Sonos stores credentials internally. No Sonos desktop app required. No mobile app UI. Purely programmatic via port 1400.

Confirmed working: UNAS Pro NAS registered as `//av-server/media/Music II`. Subsequent `x-file-cifs://` playback confirmed lossless.

### Album Queue Flow

```swift
// Register share once (fXFileCIFS)
await ZoneDiscoveryService.createObject(host: coordinatorHost, nasPath: "//av-server/media/Music II")

// Queue all album tracks
await ZoneDiscoveryService.removeAllTracksFromQueue(host: zoneHost)
for track in tracks {
    let uri = "x-file-cifs://av-server/media/Music II/\(track.filePath)"
    await ZoneDiscoveryService.addURIToQueue(host: zoneHost, uri: uri)
}
// Point transport at queue and play
await ZoneDiscoveryService.setAVTransportURI(host: zoneHost, uri: "x-rincon-queue:\(zone.id)#0")
await ZoneDiscoveryService.sendTransportAction(host: zoneHost, action: "Play")
```

Note: `AddMultipleURIsToQueue` rejects `x-file-cifs://` URIs (error 402). Must use `AddURIToQueue` (single track) in a loop.

---

## iOS Background Restriction — Confirmed

Tested on iPhone and iPad (plugged in, iOS 26):

- **AVAudioSession `.playback`** — keeps the process alive. Zone polling (`GetPositionInfo` every 5s) continues through screen lock. ✓
- **NWListener TCP streaming** — suspended when screen locks. HTTP file serving stops mid-stream. ✗
- **AVAudioSession does NOT keep NWListener tasks alive.** The process stays alive but streaming tasks are throttled. This is the fundamental reason iPad Core as HTTP server was ruled out.

Apple's DTS documentation confirms: "iOS does not allow apps to run indefinitely in the background" for network servers. The `x-file-cifs://` architecture sidesteps this entirely — Sonos handles its own networking.

---

## Playback Conductor Architecture

The Playback Conductor replaces `LocalPlaybackService` as the central orchestration layer. It owns the canonical mixed-source queue and routes each track to the correct transport based on the track's source and the zone's capabilities.

### Zone Capability Table

Built automatically from zone discovery. Persisted in `ZoneCapabilityStore`.

| Zone | Primary | Secondary |
|------|---------|-----------|
| Living Room (Sonos) | Sonos (x-file-cifs, UPnP) | AirPlay 2 |
| HiFi (Bluesound) | Bluesound (x-file-cifs, BluOS) | AirPlay 2 |
| Bathroom (AirPlay only) | AirPlay 2 | AirPlay 2 |
| Patio (Sonos) | Sonos | AirPlay 2 |
| Patio + Pool (mixed group) | AirPlay 2 | AirPlay 2 |

### Source Transport Table

| Source | Method | Preferred Transport |
|--------|--------|-------------------|
| Local FLAC (CD 16/44.1) | x-file-cifs:// | Sonos / Bluesound native |
| Local hi-res FLAC (24/96+) | x-file-cifs:// | Sonos (24/48 ceiling) / Bluesound (full res) |
| Apple Music | MusicKit | AirPlay 2 |
| Tidal | Tidal Connect | Sonos / Bluesound native |
| Qobuz | Qobuz Connect | Sonos / Bluesound native |
| Radio | HTTP stream | Sonos / Bluesound native |
| Any source → AirPlay-only zone | MusicKit / AVPlayer | AirPlay 2 |
| Mixed source queue with Apple Music | MusicKit | AirPlay 2 (everything) |

### Conductor Routing Logic

```swift
func route(track: UnifiedTrack, zone: SonosZone) -> PlaybackPath {
    let zonePrimary = zoneCapabilityStore.primary(for: zone)
    
    switch track.source {
    case .localLibrary:
        if zonePrimary == .sonos || zonePrimary == .bluesound {
            return .xFileCIFS  // NAS direct — app not needed after queuing
        } else {
            return .airPlay    // AirPlay-only zone
        }
    case .appleMusic:
        return .musicKit       // Always AirPlay via MusicKit
    case .tidal:
        return zonePrimary == .sonos || zonePrimary == .bluesound 
            ? .tidalConnect : .airPlay
    case .qobuz:
        return zonePrimary == .sonos || zonePrimary == .bluesound 
            ? .qobuzConnect : .airPlay
    case .radio:
        return zonePrimary == .sonos || zonePrimary == .bluesound 
            ? .httpStream : .airPlay
    }
}
```

### Mixed Queue Detection

Before queueing, the conductor inspects the full track list:

```swift
if queue.contains(where: { $0.source == .appleMusic }) {
    // Mixed queue with Apple Music — route everything via MusicKit/AirPlay
    // MusicKit manages queue, iOS background audio keeps alive
} else if queue.allSatisfy({ $0.source == .localLibrary }) && zone.primary == .native {
    // Pure local queue to native zone — x-file-cifs, app not needed after queuing
} else {
    // Mixed non-Apple queue — route per track
}
```

---

## HTTP Server — Retained as Fallback

`SorrivaHTTPServer` is retained for:
- Local files playing to AirPlay-only zones (phone in audio path, screen must stay on or MusicKit manages)
- Radio streams (already working, no background issue — Sonos pulls the stream URL independently)
- Development and debugging

For Sonos and Bluesound zones, `x-file-cifs://` is preferred — no HTTP server involved.

### UNAS Pro SMB Learnings (retained from v3.0)

**8MB reads on persistent connection → drops after 2 reads.** Root cause of original streaming failures.

**Fresh-connection-per-chunk accumulates orphaned sessions.** Caused inconsistent hangs at 6–20MB across successive attempts.

**Correct HTTP server pattern: one persistent SMB session, 1MB sequential reads.**

```swift
let client = SMBClient(host: host)
try await client.login(...)
try await client.connectShare(share)
let reader = client.fileReader(path: path)
while true {
    let data = try await reader.read(offset: offset, length: 1_048_576)
    // send, advance offset, backpressure via .contentProcessed
}
```

---

## Scanner Duration Extraction — fScannerDuration ✓ SHIPPED

Duration is extracted at scan time and stored in `tracks.duration`. Never re-read at play time.

| Format | Source | Method |
|--------|--------|--------|
| FLAC | STREAMINFO block | Sample rate × total samples (bit-accurate parsing) |
| MP3 | ID3v2 TLEN frame | Milliseconds as string |
| M4A/ALAC | `mvhd` atom | Duration / timescale |
| WAV | fmt + data chunk | Data size / byte rate |
| AIFF | COMM chunk | numFrames / sampleRate (80-bit IEEE float) |

---

## Quality Preservation

With `x-file-cifs://` direct NAS playback:
- Sorriva does NOT touch the audio
- Sonos/Bluesound decode the file internally
- Quality ceiling is downstream hardware:
  - **Sonos** — 24-bit/48kHz lossless
  - **Bluesound Node, NAD BluOS** — 24-bit/192kHz lossless
  - **AirPlay 2 (fallback)** — 16-bit/44.1kHz (CD-quality FLAC: lossless, no penalty; hi-res: downsampled)

---

## Features Status

| Feature | Status | Complexity |
|---------|--------|------------|
| `fLocalHTTPServer` | ✓ Shipped 2026-07-15 | S |
| `fLocalSonosPlayback` | ✓ Shipped 2026-07-16 | M |
| `fScannerDuration` | ✓ Shipped 2026-07-16 | S |
| `fAlbumQueue` | ✓ Shipped 2026-07-16 | M |
| `fXFileCIFS` | Next — Phase 1 | M |
| `fZoneCapabilityStore` | Next — Phase 1 | S |
| `fPlaybackConductor` | Planned — Phase 2 | L |
| `fMusicKitAdapter` | Planned — Phase 3 | L |
| `fLocalNowPlaying` | Planned | S |
| `fPollingOptimization` | Planned | XS |
| `fDBBackup` | Planned | S |
| `fSorrivaCoreTransfer` | Deferred — x-file-cifs eliminates need for most use cases | S |

---

## Bluesound Native Path

Bluesound hardware is its own SMB client. `x-file-cifs://` via `AddURIToQueue` works the same way as Sonos. BluOS HTTP API is used for zone control.

- Quality ceiling: 24-bit/192kHz lossless (no Sonos 48kHz ceiling)
- Phone completely out of audio path after initiating playback

---

## What's No Longer Needed

**iPad as Sorriva Core** — original v1/v2 architecture. Superseded by `x-file-cifs://`. The HTTP server bridge was the only reason the iPad Core was needed for local playback. With Sonos fetching directly from the NAS, no always-on device is required.

**fSorrivaCoreTransfer** — the Multipeer Connectivity session transfer mechanism. Deferred indefinitely as the core premise (iPad as always-on HTTP server) was ruled out by iOS background restrictions.

**fMacBridge** — still valid as an optional power-user feature but no longer required for the product to work.
