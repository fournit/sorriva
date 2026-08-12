# Sonos Playback Contract — the single authority

**Status:** authoritative. **Last verified:** 2026-08-05.

This is the definitive record of **which command sequences actually work against Sonos**,
and how each one fails when it doesn't. If another document contradicts this one, this one
wins and the other should be corrected or pointed here.

**Read this before touching any playback, transfer, or grouping code.**

## Rules for this document

1. **Measured facts only.** Every claim states how and when it was verified. No intended
   behaviour, no plans, no "should". Those belong in the handoffs.
2. **Failure signatures are as important as the happy path.** Most Sonos failures are
   silent, so knowing what a broken thing *looks like* is what saves the hours.
3. **Anything learned about Sonos behaviour gets added here**, not to a code comment and
   not to a session note. This document existing but not being read is exactly how
   2026-08-05 went; scattering the knowledge again defeats it.

---

## 0. The rule that underpins everything

> **A 200 from Sonos does not mean success.**

Sonos validates lazily. It will accept a command, return HTTP 200, and then do nothing.
Verified repeatedly on 2026-08-05:

- `SetAVTransportURI` returns **200 for a URI it cannot play**. The transport simply never
  leaves `STOPPED`.
- `CreateObject` returns **200 while registering no share at all** — confirmed by browsing
  the speaker's share list afterwards and finding it unchanged (§2).
- `Play` returns **200 and playback does not start**, or returns **500 with
  `errorCode=701`**, for the same underlying cause on different speakers.

**Therefore: never infer success from a status code. Read the transport state back.**
`verifyPlaybackStarted` exists for this. Anything that reports "every command was accepted"
without checking the outcome is lying.

---

## 1. Addressing — how to name a file

```
x-file-cifs://AV-Server/Media/Music II/Artist/Album/01 - Track.flac
              ^^^^^^^^^
              short host — NOT AV-Server.local, NOT an IP
```

**Use the server's short name.** `LibrarySource.host` holds the Bonjour form
(`AV-Server.local`) because that is what the **iPhone's own** SMB connection needs — the
scanner resolves it over mDNS and it works. Sonos needs the short name. One field, two
clients, different requirements: use `SourceResolver.sonosHost` for anything Sonos-facing.

Measured 2026-08-05, same file, same minute, four speakers:

| URI host | Master Bath | Office | Workout | Master Bedroom |
|---|---|---|---|---|
| `AV-Server` | plays | plays | plays | plays |
| `AV-Server.local` | plays | plays | **STOPPED** | **STOPPED (701)** |
| `192.168.1.102` | — | — | — | **STOPPED (701)** |

`.local` works on *some* speakers, which is why this presented as intermittent and
zone-specific and was mistaken for a wedged transport, a share-registration failure, NAS
trouble, and a code regression before being measured.

**Case and percent-encoding do not matter.** `av-server/media/...%20...` and
`AV-Server/Media/... ...` behave identically (measured 2026-08-05). Sonos's own URIs use
lowercase host and `%20`, but neither is required.

---

## 2. Seeding a speaker — share registration

```
CreateObject → ContainerID "S:", Elements = DIDL with //host/share
```

**Registration is NOT a precondition for playback.** Confirmed by Tom from earlier testing
and consistent with 2026-08-05 measurements: files outside any registered share play fine
when the queue path is used.

**`CreateObject` currently registers nothing.** On 2026-08-05 the app called it repeatedly
with `//AV-Server/Media`, got 200 every time, and the household's share list still contained
only `//av-server/media/Test Scan` — added long ago through the Sonos app. Tracked as
`bSonosShareRegistrationSilentlyNoOps`.

**To see what a speaker actually knows**, browse its ContentDirectory:

```
Browse  ObjectID="S:"  BrowseFlag="BrowseDirectChildren"
→ <container id="S://av-server/media/Test%20Scan">
```

This is the only reliable way to know the truth, and it is how the no-op above was found.

---

## 3. Playing local files — ALWAYS via the queue

**This is the single most important sequence in the app.**

```swift
sendTransportAction(host, "Stop")
removeAllTracksFromQueue(host)                      // clear first — always
for track in tracks {
    addURIToQueue(host, uri: "x-file-cifs://…")     // ONE AT A TIME
}
setAVTransportURI(host, uri: "x-rincon-queue:\(zoneUUID)#0")
sendTransportAction(host, "Play")
verifyPlaybackStarted(host)                          // read the state back
```

**Never point `SetAVTransportURI` directly at an `x-file-cifs://` file.** It returns 200 and
then either sits at `STOPPED` or rejects the following `Play` with `errorCode=701`, and
whether it works varies by speaker and over time on the same speaker.

Measured 2026-08-05 on Workout, which had refused every direct attempt for hours:

| Approach | Result |
|---|---|
| `SetAVTransportURI` → file directly | `Play` 500 / `errorCode=701`, STOPPED |
| Same file, Sonos's own lowercase+`%20` spelling, direct | 500 / 701, STOPPED |
| Sonos's *verbatim* working URI from a registered share, direct | `Play` 200, still STOPPED |
| **Queue path, 1 track** | **PLAYING, duration read** |
| **Queue path, 3 tracks** | **PLAYING, 3 tracks, duration read** |

A single track is not a special case — **queue it too**. A one-track queue works; a direct
URI does not. This also matters for transfers (§5), because a destination inherits whatever
the transport holds, and a bare file URI travels badly.

`AddMultipleURIsToQueue` rejects `x-file-cifs://` with error 402 — loop `AddURIToQueue`.
URIs need file extensions or UPnP returns 714.

**Reading a real `TrackDuration` is the proof it worked.** A speaker that cannot open the
file reports `0:00:00`, because it never read the header.

---

## 4. Playing radio

Radio is the opposite of §3: point the transport straight at the stream.

```swift
setAVTransportURI(host, uri: streamURL)   // hls-radio://…, aac://…, x-rincon-mp3radio://…
sendTransportAction(host, "Play")
```

DIDL duration metadata must be included; zero-duration triggers prefetch issues.

**Sonos cannot name a station.** `dc:title` means something different per service — a
filename for iHeart (`hls.m3u8`), a slug for SomaFM (`groovesalad-128-aac`), the *track*
title for Sonos Radio. Never display it as a station name. Station identity comes from the
stations table via the per-service adapters; see `radio-service-integration.md`.

`r:streamContent` **is** trustworthy — it carries the song playing now, and the reducer
reads it directly.

---

## 5. Transferring playback between zones

```swift
createObject(destHost, …)                       // register shares on destination
removeAllTracksFromQueue(destHost)
addMember(coordinatorHost: sourceHost, memberHost: destHost, memberUUID: sourceUUID)
sleep 2s                                        // let audio sync
becomeCoordinator(sourceHost)                   // source leaves; destination inherits
sleep 0.5s
sendTransportAction(destHost, "Play")
```

The destination inherits whatever the transport holds — so if the source was on a bare
`x-file-cifs://` URI rather than a queue, the destination inherits that and will fail on any
speaker that cannot play direct URIs. **§3 is what makes transfer reliable.**

**The source goes silent on its own.** No explicit `Stop` is needed or sent (confirmed by
Tom, 2026-08-04).

---

## 6. Grouping and ungrouping

`x-rincon:` with a **single colon** via `SetAVTransportURI` for S2 grouping. `x-rincon://`
fails with 501.

**A grouped member never receives the content.** Its transport is set to
`x-rincon:RINCON_<coordinator>` — a pointer at the coordinator, which does all the fetching
and distributes audio. The member's own queue is untouched the entire time it is grouped.

**On separation, Sonos restores the member's own previous queue.** Measured 2026-08-04:
Patio coordinating SomaFM Bossa Beyond, Garage separated and was parked on its own iHeart
station. So what an ungrouped zone reports is **what will actually play if the user presses
play on it** — do not overwrite it with the group's content. This is why PlaybackStore
phase C was closed as unnecessary (`fPlaybackStoreGroupDeclarations`).

Departing zones are stopped explicitly (`groupZone` removals, `ungroupZone`); the
coordinator and remaining members keep playing.

For ~2s mid-transfer a destination reports `x-rincon:` as its URI. **Anything that
pattern-matches URIs must exclude it** alongside `x-rincon-queue:` and `x-file-cifs://` —
it addresses a speaker, not content.

---

## 6a. External inputs — TV over HDMI/eARC, and line-in

Measured on a Living Room Arc Ultra (bonded with four surrounds), 2026-08-08.

**A TV powering on takes the room.** Sonos switches the zone to its HDMI input on its
own; nothing asked it to and nothing can veto it. What the speaker then reports:

| Field | Value |
|---|---|
| `TrackURI` / `CurrentURI` | `x-sonos-htastream:RINCON_<coordinator>:spdif` |
| `CurrentTransportState` | `PLAYING` |
| `CurrentTransportStatus` | `OK` |
| `dc:title`, `r:streamContent` | **empty** |
| `TrackDuration`, `RelTime` | `NOT_IMPLEMENTED` |
| `GetCurrentTransportActions` | `Set, Play` |
| `upnp:class` | `object.item.audioItem.linein.homeTheater` |

Prefer the `upnp:class` — anything under `object.item.audioItem.linein` — over matching
URI prefixes. It is stable and it covers line-in variants without a growing list.

**The input is held, then eventually released — THREE stages, not two.** This was
recorded on 2026-08-08 as "the input STICKS", which was measured over minutes and is
wrong over hours. The full sequence, watched to completion the same evening:

| Stage | `CurrentURI` | State | `GetCurrentTransportActions` |
|---|---|---|---|
| TV playing | `x-sonos-htastream:…:spdif` | PLAYING | `Set, Play` |
| TV off, input still held | `x-sonos-htastream:…:spdif` | PLAYING | `Set, Play` |
| **Input released** | **empty** | STOPPED | **`Set`** |

The third stage arrives long after the television is switched off — long enough that two
separate measurements that evening both caught stage two and generalised from it. In the
released state `NrTracks` is 0 and `PlayMedium` is `NONE`: the transport holds nothing
at all, and **Play is not an available action**.

Turning the TV off never restores the previous station, at any stage. The app must not
"restore" anything — the TV genuinely was the last thing played there, which means it is
what the zone's last-playing should say. It does not today, and that is
bTVNotRecordedAsLastPlaying: the HDMI branch DERIVES "TV" for display and never declares
it, so when stage three arrives the reducer reaches past it to whatever was last
declared — a radio station from hours earlier.

**THE LESSON, since this doc exists to hold measured facts:** a transition watched for
five minutes is not a transition. Both wrong readings here came from sampling a state
twice and inferring a rule, rather than watching until it stopped changing. If a claim in
this file describes what a speaker does OVER TIME, it needs the whole sequence or it
needs to say how long it was watched.

### IdleState is how you tell a live input from a selected one

**AVTransport cannot distinguish a TV that is playing from a TV that is off** while the
input is still held (stages one and two above). Every field is byte-identical — state,
status, available actions, empty metadata. Confirmed by measuring both.

Once the input is RELEASED the transport does say so plainly, via `Actions` collapsing to
`Set` alone. That is a different fact from "the TV is off" and arrives much later, so it
is no substitute for `IdleState` — but it is decisive about whether the zone can play
anything at all, which the app currently ignores (bPlayOfferedWhenTransportCannotPlay).

The discriminator is `IdleState` on the zone's `ZoneGroupMember` in
**`ZoneGroupTopology`**, not in AVTransport:

| | AVTransport | `IdleState` |
|---|---|---|
| TV on, audio playing | `PLAYING` / htastream | `0` |
| TV on, silent | `PLAYING` / htastream | `1` |
| TV off | `PLAYING` / htastream | `1` |

This is how the Sonos app knows to show the room as not playing. **It needs no developer
key and no second protocol** — Sorriva already parses it into `SonosZone.idleState`.

`IdleState` is DEBOUNCED at the speaker. Measured ~20s from a TV going quiet to the flag
flipping, against a 2s app poll interval, so essentially all of that latency is Sonos and
none of it is ours. The debounce is almost certainly deliberate: a zone that flipped to
idle during a quiet passage of dialogue would be worse than one that settles slowly. Do
not design UI that assumes this is prompt.

### The trap: source facts versus activity facts

Which input a zone is on is a SOURCE fact. Whether sound is coming out is an ACTIVITY
fact. They move independently, and code that clears the first because of the second
breaks visibly: while a TV warms up, HDMI is negotiated but no audio flows yet, so the
playing state oscillates. A poll that cleared the HDMI flag whenever the zone was "not
playing" made the zone card flicker between the TV icon and the last station for the
entire warm-up period (bZoneShowsStaleStationWhenTVTakesOver). The only legitimate way to
leave the TV input is for the URI to stop being an htastream URI.

---

## 7. Failure signatures — what a broken thing looks like

| Symptom | Cause | §|
|---|---|---|
| Everything returns 200, transport stays `STOPPED`, `TrackDuration 0:00:00` | Speaker cannot open the file — bad host, or direct URI instead of queue | 1, 3 |
| `Play` → 500 `errorCode=701` | No playable content loaded; the URI was already rejected silently | 3 |
| Works on some zones, not others, changing over time | Almost always §1 or §3 — not hardware, not the NAS | 1, 3 |
| Card shows playing then goes quiet after ~6s | Optimistic grace expiring over a play that never started | 0 |
| Station shows `hls.m3u8` or a bitrate slug | `dc:title` treated as a station name, or the resolve cache missed | 4 |
| Zone reverts to older content after a transfer | Something writing content from raw poll fields | — |

---

## 8. Diagnostics

Raw SOAP probes against the speakers settle in seconds what inference argues about for
hours. Working scripts from the 2026-08-05 session pattern:

- **discover** — SSDP `M-SEARCH` for `urn:schemas-upnp-org:device:ZonePlayer:1`, then
  `http://<ip>:1400/xml/device_description.xml` for `roomName`, `UDN` (the `RINCON_…` seen
  in logs), model and firmware.
- **state** — `GetTransportInfo`, `GetMediaInfo`, `GetPositionInfo` on
  `/MediaRenderer/AVTransport/Control`.
- **shares** — `Browse` `S:` on `/MediaServer/ContentDirectory/Control`.
- **fault detail** — capture the SOAP body on non-200 and read `<errorCode>`. The app
  currently discards this (`fSurfaceSonosErrorCodes`).

**Compare against what Sonos itself does.** Play from the Sonos app, then read the
transport back — its URI and queue shape are the reference implementation. That single
comparison is what identified the queue requirement on 2026-08-05.

---

## 9. Known-unproven

- Why direct `x-file-cifs://` URIs work on some speakers and not others. Identical models
  and firmware behave differently, and the same speaker changes over time. **Not needed** —
  §3 avoids the path entirely — but it is unexplained.
- Whether `CreateObject` can be made to register a share (§2), and what it needs. Possibly
  credentials.
- Whether `RefreshShareIndex` affects per-speaker state. Never run.

---

## 10. Related

- `sonos-upnp-reference.html` — protocol reference: which calls exist, their parameters,
  S1/S2 differences. **This document says which *sequences* are proven.**
- `sorriva-local-playback-arch.md` — why `x-file-cifs://` was chosen and what was ruled out.
- `radio-service-integration.md` — per-service station identity.
- `HANDOFF-playbackstore-design.md` — how resolved content is displayed once playing.

---

## 11. Favorites — the only local route to a closed service

Measured 2026-08-10. **ContentDirectory `FV:2` lists the household's saved favorites,
over plain UPnP on the LAN.** No cloud API, no developer programme, no quota approval.
This is how a service whose catalogue is contractually closed still becomes playable.

Tom's household: 42 favorites spanning SiriusXM, Spotify, Sonos Radio, iHeartRADIO
and SomaFM.

**Browse it like this** — note ContentDirectory takes NO `<InstanceID>`, which is why
`tools/sonos.py`'s `soap()` helper cannot be used for it as written:

```
POST http://{host}:1400/MediaServer/ContentDirectory/Control
SOAPACTION: "urn:schemas-upnp-org:service:ContentDirectory:1#Browse"
  <ObjectID>FV:2</ObjectID>
  <BrowseFlag>BrowseDirectChildren</BrowseFlag>
  <Filter>*</Filter><StartingIndex>0</StartingIndex>
  <RequestedCount>100</RequestedCount><SortCriteria></SortCriteria>
```

Each item carries four things that matter:

| Field | Example | Why |
|---|---|---|
| `<res>` | `x-sonosapi-stream:channel-linear%3A2ea0…?sid=37` | the URI to play |
| `<r:resMD>` | DIDL with `<desc id="cdudn">SA_RINCON9479_X_#Svc9479-…-Token</desc>` | **the household's service token — without it the URI will not play** |
| `<upnp:albumArtURI>` | `https://ce-sonos.siriusxm.com/image/…png` | artwork; Sonos supplies none at playback |
| `<r:description>` | `SiriusXM` | which service it belongs to |

**Playing one is the metadata form of SetAVTransportURI, then Play:**

```swift
SonosCommands.setAVTransportURIWithMetadata(host:, streamURL: <res>, didl: <r:resMD>)
SonosCommands.sendTransportAction(host:, action: "Play")
```

Verified on Workout at volume zero: PLAYING, with
`r:streamContent = TYPE=SNG|TITLE White Wedding (83)|ARTIST Billy Idol`. The live-track
format is identical to iHeart's, so the existing parser handles it unchanged.

**THE URI IS REWRITTEN ON PLAYBACK.** `x-sonosapi-stream:` goes in;
`x-sonosapi-hls:` comes back from `GetMediaInfo`. Any reverse lookup that identifies a
playing station must survive that rewrite — this is a third case for
`radio-service-integration.md` §3, alongside the app-vs-Sonos scheme differences.

**What favorites are NOT.** They are not a service catalogue. There is no channel
browser: `Browse('0')` returns exactly six containers — `A:` `S:` `SQ:` `R:` `FV:` `Q:`
— and none of them is a music service's own listing. That needs SMAPI, which is
partner-gated. A channel that was never favorited must be saved in the Sonos app first.

### ContentDirectory does not answer on every speaker

Living Room returned **500 to every ContentDirectory action**, including
`GetSearchCapabilities`, while Office and Master Bedroom answered normally. Its
`device_description.xml` is also incomplete — it omits AVTransport, which demonstrably
works on that same speaker.

Two rules follow, both learned the expensive way:

1. **Do not treat `device_description.xml` as a map of what a speaker supports.**
2. **Do not conclude a capability is absent because one speaker refuses.** An hour was
   spent concluding favorites were unreachable, on the basis of a single speaker that
   happens not to answer.
