# Music App — Project Context
> Drop this file into any new Claude session to restore full project context.
> Last updated: 2026-07-03 — major architecture pivot session

---

## Project Overview

A pure App Store music app for the Apple ecosystem. Sorriva is the **intelligent music layer that sits above your hardware and streaming services** — the one place that knows your entire music world and delivers it beautifully based on context.

**What it is:** A unified music graph across your local library and every streaming service you subscribe to. When you're home it plays your FLAC files through your Sonos zones. When you're traveling it seamlessly switches to Apple Music or Spotify. Anywhere, any device, one app.

**What it is not:** A self-hosted server. No Mac Mini required, no Cloudflare Tunnel, no launchctl, no deployment pipeline. Pure App Store product.

**Inspired by:** The gap nobody fills — Spotify owns the catalog, Sonos owns the hardware, Roon owns the audiophile server. Nobody owns the intelligent layer that unifies all of them into one coherent, beautiful experience.

**Competitive position:** Not a Spotify competitor — Sorriva enhances Spotify. The user keeps their subscription, Spotify still gets the stream and the royalty. Sorriva is the universal remote, not the TV. Closest analogy: what Infuse Pro does for video, Sorriva does for music — but with AI, multi-room, and cross-service unification that Infuse never attempted.

**Status:** Architecture pivot complete — 2026-07-03. Pre-build. No code written yet.

**Name:** Sorriva

**Repo:** Not yet created. `github.com/tomfo/sorriva`

**Domain:** sorriva.app ✅ registered

---

## What Changed — 2026-07-03 Architecture Pivot

The original architecture was a self-hosted Python/Flask server on a Mac Mini, positioned as a Roon replacement. That architecture was replaced entirely in this session. Key decisions:

- **No self-hosted server** — pure App Store product, zero server management for users
- **AirPlay 2 as the multi-room backbone** — replaces direct Sonos/Bluesound API control for audio delivery
- **Apple ecosystem only** — Android excluded deliberately; AirPlay 2 is the core differentiator and has no Android equivalent
- **Unified music graph** — one track identity, multiple sources, resolved at playback time based on context
- **Spotify/Apple Music as transport, not competition** — Spotify Connect and MusicKit for in-app playback, no app switching
- **Mac app as optional library bridge** — not required, but enables remote library access for power users
- **Windows users fully supported** — the app lives on Apple devices; the user's PC is irrelevant

---

## Architecture

### The Core Concept — Unified Music Graph

Every track in the user's world exists once in Sorriva's understanding. Source is just an attribute resolved at playback time.

```
Track: Kind of Blue — Miles Davis — So What
  └── Sources:
        ├── Local library (FLAC, 24-bit)     ← home, preferred
        ├── Apple Music                       ← away, lossless
        └── Spotify                           ← away, fallback
  └── Sorriva playlists: ["Late Night Jazz", "Favorites"]
  └── Play count: 12
  └── Last played: Tuesday
  └── MusicBrainz ID: [canonical cross-platform identifier]
```

Sorriva owns the playlist, the history, the discovery, the identity. Source is a delivery mechanism.

### Context-Aware Source Resolution

```
Playback request for a track
        │
        ▼
On home network?
        ├── YES → local library (FLAC/ALAC preferred)
        │           fallback: Apple Music → Spotify
        └── NO  → Apple Music → Spotify
                  (streaming services only — no local library access without Mac bridge)
```

User never thinks about this. It just plays.

### Multi-Room — AirPlay 2

AirPlay 2 is the audio delivery protocol for all zones. Key facts locked:

- Apple TV initiates AirPlay 2 streams natively — first-class supported capability
- Tom's hardware (Era 100, Era 300, Roam, Ultra Arc, Bluesound Node) all support AirPlay 2
- AirPlay 2 natively handles: simultaneous multi-room, independent volume per room, latency sync
- AirPlay 2 does NOT have persistent named groups — Sorriva builds saved group UI on top, automating device selection at playback time
- High-end audiophile hardware supports AirPlay 2: Sonos, Bluesound, Bang & Olufsen, Bowers & Wilkins, Devialet, KEF, Naim, Marantz, Denon, Yamaha, NAD — this is not a consumer-device-only protocol

### Device Control — Two Separate Layers

AirPlay 2 handles audio delivery. Native device APIs handle configuration and EQ. They run simultaneously and independently.

```
Sorriva
  ├── AirPlay 2 layer     → audio delivery to all endpoints
  └── Device API layer    → configuration, EQ, tone controls
        ├── Sonos HTTP API   → bass, treble, loudness, balance, Trueplay status
        ├── BluOS API        → EQ, tone controls, device config
        └── Plain AirPlay 2  → volume only (HomePod, etc.)
```

**Abstracted EQ UI:** One Sorriva EQ panel. EQService translates to each device's native API behind the scenes. Users see one consistent UI regardless of device. Devices that don't expose EQ show reduced panel with honest explanation. New device type = write one driver, UI never changes.

### Unified Device Discovery

Sorriva discovers all endpoints on the network and presents them in one list:
- AirPlay 2 devices via mDNS/Bonjour (native AirPlay 2 discovery)
- Sonos via Sonos local discovery API
- Bluesound via BluOS discovery

User sees one list. No protocol awareness required. Each device shows what its API exposes.

### Streaming Integration

**Spotify Connect** — third-party apps control Spotify playback without showing the Spotify app. Sorriva calls Connect API, Spotify streams directly to device, user stays in Sorriva UI. Source badge shows Spotify logo. Spotify still gets the stream and royalty — Sorriva is an enhancer not a competitor.

**MusicKit (Apple Music)** — Apple's framework for third-party apps to play Apple Music inside their own UI. Same model as Spotify Connect.

**Qobuz** — Connect equivalent available.

**Source attribution:** Source badge always shown on now playing — Spotify logo, Apple Music logo, or local library icon. Honest, clean, reinforces the value proposition visibly.

### Track Identity Matching

MusicBrainz IDs (MBID) as canonical cross-platform track identifiers. Open matching databases bridge between Spotify IDs, Apple Music IDs, and local files. 90%+ match rate on typical libraries. Graceful fallback for live versions, remasters, regional variants.

---

## Stack

| Layer | Choice |
|---|---|
| iOS / iPadOS | React Native (Expo Bare) |
| tvOS (Apple TV) | React Native tvOS |
| macOS | React Native macOS (optional library bridge client) |
| watchOS | Future — deferred |
| Backend (cloud) | Lightweight hosted service — metadata, AI, accounts, sync |
| Database (cloud) | PostgreSQL (multi-user from day one) |
| Database (local) | SQLite per device for offline cache |
| Metadata | MusicBrainz (credits, MBID), Discogs (vinyl), Last.fm (bio, similar artists) |
| Track matching | MusicBrainz MBID + open cross-platform ID mapping |
| Streaming | Spotify Connect API, MusicKit (Apple Music), Qobuz Connect |
| Multi-room | AirPlay 2 (native iOS/tvOS) |
| Device control | Sonos Local HTTP API, BluOS HTTP API |
| AI / Deriva | Anthropic API |
| Distribution | App Store (iOS, iPadOS, tvOS, macOS) |

**No Flask. No Mac Mini server. No Cloudflare Tunnel. No launchctl. No deployment pipeline.**

---

## Platform Strategy

### Apple Ecosystem Only — Intentional

AirPlay 2 is the core multi-room differentiator. Android has no AirPlay 2 support. The Android equivalent (Google Cast) has a weaker device ecosystem, doesn't cover the same high-end hardware, and would require a parallel multi-room architecture — essentially a separate product. Android deferred indefinitely. Being Apple-first is a product decision, not an apology.

### Platforms

| Platform | Role |
|---|---|
| **iPhone** | Primary controller, away-from-home listening, full feature set |
| **iPad** | Beautiful controller surface, lean-back art display mode |
| **Apple TV** | Living room primary — browse, discover, zones, lean-back |
| **Mac app** | Desktop controller + optional always-on library bridge |
| **Apple CarPlay** | Playback control while driving — future phase |
| **watchOS** | Future — deferred |

### Windows Users

Fully supported. The app lives on Apple devices. The user's PC is invisible to Sorriva. Windows/NAS households (Synology, QNAP) are a great target — their library is already on a network share, pointing Sorriva at it is trivial. No web admin needed.

---

## Library Sources

Sorriva reads music from wherever it lives. Four source types, all resolve identically inside the app:

| Source | When | Notes |
|---|---|---|
| NAS via SMB | Home, primary | Synology, QNAP, any SMB share |
| Local device storage | Always | Downloaded owned tracks for offline |
| External USB-C drive | Travel | iPadOS 13+ supports external drives natively |
| Mac running Sorriva | Home + remote | Optional bridge for remote library access |

### Offline Playback

**Owned music:** Sorriva downloads tracks from local library to device for offline playback. User marks albums/playlists as "available offline." Works on airplane mode. This is a genuine differentiator — no streaming service lets you do this with music you own.

**Streaming services:** Spotify and Apple Music allow offline downloads in their own apps. Those files are DRM-encrypted and sandboxed — Sorriva cannot access them. This is an accepted limitation. Sorriva handles offline gracefully: owned downloaded tracks play normally, streaming tracks show as unavailable offline with clear visual treatment.

**Mixed playlist offline state:**
```
Late Night Jazz
  ✅ Kind of Blue — Miles Davis        (owned, downloaded)
  ✅ A Love Supreme — Coltrane         (owned, downloaded)
  ☁️ In a Silent Way — Miles Davis     (Spotify — needs network)
  ✅ Time Out — Dave Brubeck            (owned, downloaded)
  ☁️ Bitches Brew — Miles Davis        (Apple Music — needs network)
```

### Remote Access (Away from Home)

**Without Mac bridge:** Streaming services only when off home network. Context-aware switching handles this automatically — user never changes a setting.

**With Mac bridge:** Mac app running at home exposes local library through cloud backend. Full library available anywhere. No VPN, no Tailscale, no port forwarding — Mac app maintains a cloud connection.

This creates a clean two-tier story:
- Mac running Sorriva at home → full library everywhere
- NAS only → full library at home, streaming services away

---

## Full Feature Registry

### 📚 Library & Content

**Unified Music Graph**
- Single track identity across all sources
- MusicBrainz MBID as canonical cross-platform identifier
- Source resolution at playback time based on network context
- De-duplication across local library and streaming services
- "Available on X sources" indicator per track
- Source badge always shown — honest about where audio comes from

**Local Library**
- SMB share scanning and indexing (NAS, attached drive, external USB-C)
- Metadata tagging (read/write)
- File format support: FLAC, ALAC, MP3, AAC, WAV, AIFF
- Auto-match to MusicBrainz for canonical ID assignment
- Watch for new files — auto-import on detect

**Metadata & Enrichment**
- Album art (hi-res, multiple sizes, cached locally)
- Liner notes (Discogs)
- Artist biography (Last.fm primary, Discogs fallback)
- Album reviews (Pitchfork, AllMusic, RateYourMusic)
- Credits — producer, engineer, session musicians (MusicBrainz)
- Genre / tags (Last.fm + MusicBrainz)
- Related artists

**Billboard Archive**
- Annual Top 100 every year from 1955 to present
- Browse by year or decade
- Each entry resolves to best available source (local → streaming)
- "You own X of the [year] Top 100" stat per year

**Favorites**
- Favorite albums, stations, playlists
- Multi-user / household profiles
- Per-user play history

**Offline / Device Download**
- Mark albums, playlists, or individual tracks as "available offline"
- Sorriva downloads from local library to device storage
- Offline indicator in UI — clear visual state for available vs network-required tracks
- External USB-C drive support for travel (iPad + drive = full portable library)

**iOS Widgets**
- Now Playing widget (art, track, controls)
- Zone selector widget
- Quick play favorites widget
- Via react-native-widget-extension — future phase

**Shazam Integration**
- Read Shazam library and generate playlist
- Resolve each tag to local library → subscribed service → fallback
- Future phase

**Vinyl Library**
- Separate collection management module
- Manual entry or barcode scan
- Metadata via Discogs API (pressing info, matrix numbers, label variants)
- Augmented by MusicBrainz for credits
- Fields: title, artist, label, catalog number, pressing/variant, year, format, condition (Goldmine scale), purchase price, purchase date, notes
- Collection browser, value estimator, wantlist, duplicates detection
- "You own this digitally too" cross-reference indicator
- Export to CSV/PDF for insurance
- AI angle (future): "Based on your digital listening, here are records you should own"

**Playback Statistics**
- Albums, tracks, artists, genres, decades — all ranked by play count
- Total hours played, total tracks, total albums
- Session history
- Streaming service stats supplemented where APIs allow
- Annual wrap-up — future phase

**Play Queue**
- Queue = what is waiting (not what has played)
- Play history = permanent, sessionized
- Queue persists across sessions until explicitly cleared
- Session history: past sessions can be recalled and replayed
- Actions: Add to queue, Delete from queue, Play Next, Play Now, Save queue as playlist, Clear queue
- Significantly more elegant than existing Bluesound/Sonos implementations

**Auto Play**
- Seeds from currently playing track
- Pulls complementary tracks from local library and/or services (configurable)
- Tightness dial: strict (same genre/era) → open (anything goes)
- Last.fm similar tracks API + local library index
- AI skip pattern learning over time

---

### 🎵 Audio Sources

**Local**
- Direct file playback (no transcoding — files play natively)
- Format support: FLAC, ALAC, MP3, AAC, WAV, AIFF

**Streaming Services**
- Spotify — Spotify Connect for in-app playback (Premium required)
- Apple Music — MusicKit for in-app playback
- Qobuz — Qobuz Connect, hi-res streaming
- iHeartRadio — live radio & stations
- SiriusXM — satellite radio (future phase — legal posture TBD)

---

### 📡 Zones & Audio Output

**Audio Delivery — AirPlay 2**
- Apple TV initiates all AirPlay 2 streams
- Simultaneous multi-room playback with latency sync
- Independent volume per room
- Native iOS/tvOS capability — no custom protocol implementation needed

**Sonos Native Groups and Stereo Pairs — Preserved As-Is**
- Sonos stores group configuration at the hardware/firmware level, not in any app
- Stereo pairs (e.g. two Era 100s paired in a room) appear as a single AirPlay 2 zone — the pairing is invisible to Sorriva
- Multi-speaker room groups (e.g. a 5-speaker living room) appear as a single addressable zone — Sonos handles internal distribution and sync
- Sorriva never reconfigures or breaks native Sonos groups — it simply streams to the zone as defined
- Users do not need to regroup anything in Sorriva; their existing Sonos configuration is respected entirely

**Saved Zone Groups**
- AirPlay 2 has no native persistent groups — Sorriva builds this at the zone level
- A Sorriva zone group combines multiple zones (which may themselves be Sonos groups or pairs internally)
- Example: "Party Mode" = Living Room (5-speaker Sonos group) + Office (Bluesound Node) + Patio (Era 300) — each zone maintains its own internal configuration; Sorriva coordinates the top level only
- User creates named groups once; one tap to recall
- Ad-hoc groups — temporary, session-based

**Unified Device Discovery**
- mDNS/Bonjour for AirPlay 2 devices
- Sonos local API discovery — sees native groups and pairs as single zones
- BluOS discovery
- All presented in one list — no protocol awareness required for user

**Device Control — EQService Abstraction**
- One Sorriva EQ UI — bass, mid, treble, loudness
- EQService translates to each device's native API:
  - Sonos: bass, treble, loudness, balance, Trueplay status via Sonos HTTP API
  - Bluesound: tone controls via BluOS API
  - Plain AirPlay 2 (HomePod etc.): volume only — EQ panel shows reduced state with explanation
- New device type = new driver, UI unchanged

**Volume Control**
- Per device and per group
- Via AirPlay 2 protocol

---

### 🤖 AI Features — Deriva

Deriva is Sorriva's AI discovery engine. It operates on the complete unified music graph — not just one service's catalog.

**AI Playlists**
- Mood/context-based generation ("Sunday Morning Coffee", "Late Night Drive", "Dinner Party")
- Draws from entire music graph — local library + streaming services
- Listening pattern awareness across all sources
- Skip pattern learning — stops recommending what consistently gets skipped
- Library rediscovery — surfaces forgotten/unplayed albums
- Playlist reasoning — explains the thread connecting choices
- Time-of-day and seasonal awareness as soft signals
- Weather API as optional soft signal

**Music Discovery**
- Analyzes most played tracks, artists, genres across all sources
- Finds similar music in graph
- "Music just like this" from any artist or track
- Gateway albums — "if you love X, here's Y you haven't explored"
- Deep cuts surfacing per artist

**Future AI**
- Annual wrap-up — "your year in music" across all sources
- Vinyl recommendation — "based on your digital listening, here are records you should own"

---

### 📱 Clients & Platforms

| Client | Primary Role |
|---|---|
| **iPhone** | Full control — library, queue, zones, search, playback, away-from-home |
| **iPad** | Controller surface, lean-back art display mode |
| **Apple TV (tvOS)** | Primary living room client — browse, discover, zones, lean-back |
| **Mac app** | Desktop controller + optional always-on local library bridge |
| **CarPlay** | Playback control while driving — future phase |

**Tech:** Single React Native (Expo Bare) codebase targeting iOS, iPadOS, tvOS, macOS. Bare chosen for AirPlay 2 native module access and Spotify Connect SDK integration.

---

### 🎨 UI & Design

**Theme:** Light — warm parchment base (`#F5F2EE`), slate blue accent (`#3D5A99`), warm brass secondary (`#B07D4F`). Same DNA as Tack and Passione brand system.

**Icon system:** Custom SVG icon library, consistent 1.5px stroke weight. Room icons distinct per zone type.

**Key screens:**
- Home — "What should I play?" prompt, Deriva suggestions, recently played, zone status
- Library — unified album grid, source badges, filter/sort/search
- Now Playing — full art, source badge, scrub bar, zone indicator, EQ panel, content tabs (Info / Review / Credits / Lyrics)
- Artist page — bio, stats, discography, related artists
- Zones panel — unified device list, saved groups, ad-hoc grouping, EQ per device
- Deriva — AI prompt entry, playlist reasoning, discovery mode
- Vinyl — collection grid, wantlist, stats
- Stats — playback history, rankings, wrap-up
- Settings — library sources, streaming service connections, household profiles, offline downloads

**Source badge design:** Small, consistent logo badge on all track/album cells and now playing — Spotify green, Apple Music gradient, Qobuz blue, local library icon. Always visible, never hidden.

---

### 🏗 Infrastructure

**App infrastructure (standard App Store):**
- Xcode project, App Store Connect, TestFlight
- React Native Expo Bare
- No server deployment pipeline

**Cloud backend (lean, hosted):**
- Metadata enrichment service (MusicBrainz, Discogs, Last.fm)
- Track identity matching service (MBID cross-referencing)
- Deriva AI service (Anthropic API)
- User accounts and sync
- Mac bridge relay (for remote library access)
- Hosted on small cloud instance (not user-managed)

**No self-hosted infrastructure required by users.**

---

### 🔮 Commercial Path

Pure App Store subscription model. No self-hosting complexity to explain in onboarding. No server setup. Download, connect library, connect services, play music.

**Pricing story:** $5–8/month. The user already pays for Spotify ($11), Apple Music ($11), and probably Qobuz ($13). Sorriva makes all of those better. Easy upsell math.

**Estimated commercial delta from personal build:**
| What | Effort |
|---|---|
| User auth (Clerk or Auth0) | ~1 week |
| App Store submission (all platforms) | ~1 week |
| RevenueCat subscription billing | ~1 week |
| Support tooling | ~1 week |

**Commercial observation:** No product currently owns the position of "intelligent music layer above your hardware and services" for the Apple audiophile market. Spotify is too broad and service-locked. Roon is too complex and expensive. Sonos is hardware-dependent and app quality is declining. The gap is real and the addressable market — serious audio gear, Apple household, multiple streaming subscriptions — is reachable through App Store.

---

## Design Principles

- **One app, all your music** — local library, every streaming service, one unified experience
- **Source is invisible until it matters** — the right source plays automatically; badge shows it honestly when it does
- **Apple-first is a choice, not a limitation** — AirPlay 2 is the differentiator; own this ecosystem completely
- **Simple above all else** — no music expertise required. Every configuration decision must pass: "can a normal person do this?"
- **Sorriva owns discovery, not playback** — streaming services play their own audio; Sorriva owns the intelligence layer above them
- **Show-first / build-second** — mockup or wireframe before any code on UI features
- **Offline is a first-class citizen** — owned music travels with you, always

---

## Marketing Positioning

### The Core Message

Sorriva is the music app for people who care about their system — but are tired of being locked into one ecosystem's idea of how it should work.

### Hardware Freedom — Key Differentiator

The two dominant players in this space both use hardware lock-in as a business model:

- **Sonos** — buy Sonos hardware, use the Sonos app, play by Sonos rules. Years of app deterioration and product controversies have left a significant user base actively looking for an exit ramp.
- **Roon** — requires Roon Ready hardware or approved endpoints. Complex, expensive ($130/yr or $830 lifetime), and notoriously difficult to set up.

Sorriva's answer is the opposite. **If it speaks AirPlay 2, it works.** A $79 WiiM Mini, a $1,000 Marantz M1, a $3,500 Naim Mu-so, a Bluesound Node into a NAD preamp — user's choice, user's budget, user's taste. Want to bring your audiophile system into Sorriva? Pick up any AirPlay 2 compatible streamer or amplifier. Hundreds of devices across every price point and brand. No Sorriva hardware to buy. No ecosystem to join.

This is a direct and honest contrast to both Sonos and Roon without naming either.

### Candidate Taglines

**Primary:**
- *Your Music. Your Way.* ← current, locked
- *Finally, an app that works with your system — not the other way around.*

**Hardware freedom angle:**
- *Your system. Your services. Your music.*
- *Any speaker. Any service. One app.*
- *Great gear deserves a great app.*

**Streaming unification angle:**
- *All your music. One place. Finally.*
- *Stop switching apps. Start listening.*

### Target User

Someone who has:
- An Apple household (iPhone, iPad, Apple TV)
- Serious audio gear — Sonos, Bluesound, Marantz, Naim, KEF, B&W, or similar
- One or more streaming subscriptions (Spotify, Apple Music, Qobuz)
- A local music library they care about — FLAC rips, vinyl transfers, music they own
- Frustration that nothing ties it all together elegantly

They are not looking for another streaming service. They already have those. They want the intelligent layer above all of it.

### Competitive Framing

| | Sorriva | Spotify | Sonos | Roon |
|---|---|---|---|---|
| Local library | ✅ | ❌ | Limited | ✅ |
| Multi-room | ✅ AirPlay 2 | ❌ | ✅ native | ✅ RAAT |
| AI discovery | ✅ Deriva | Limited | ❌ | Limited |
| Hardware freedom | ✅ any AirPlay 2 | ❌ | ❌ Sonos only | ❌ Roon Ready only |
| Cross-service unification | ✅ | ❌ | ❌ | ❌ |
| Setup complexity | Simple | Simple | Moderate | Complex |
| Price | ~$5-8/mo | $11/mo | $0 (hardware) | $130/yr |
| Apple TV UI | ✅ | Limited | ❌ | ❌ |

### What Sorriva Is Not

Worth being explicit in marketing — sets honest expectations and defuses objections:
- Not a streaming service (you keep Spotify/Apple Music)
- Not a hardware company (no Sorriva speakers to buy)
- Not a server to maintain (pure App Store, nothing to install at home)
- Not a Roon clone (simpler, cheaper, no server)
- Not just a Sonos app replacement (though it solves that too)

---

## Brand Identity

**Name:** Sorriva
**Domain:** sorriva.app ✅ registered
**Umbrella company:** Passione (passione.app)
**AI discovery engine:** Deriva — the intelligent wandering engine within Sorriva

**Wordmark:**
- Font: Inter 800
- Letter spacing: -0.05em
- Color: #1A1714 (warm near-black) on parchment (#F5F2EE)
- Signature dot: 9px circle, slate blue (#3D5A99), top-right after wordmark

**Primary tagline:** Your Music. Your Way.
**Secondary tagline:** Bring the vinyl experience to your digital collection.
**Deriva tagline:** Let Deriva find the rest.

**Palette:**
- Background: #F5F2EE (warm parchment)
- Accent: #3D5A99 (slate blue)
- Secondary: #B07D4F (warm brass)
- Text primary: #1A1714 (warm near-black)

**Name etymology:**
- Sonic + Deriva (the sound that drifts)
- Sorriva = final spelling (double-r, domain-available variant)
- Deriva = Italian/Portuguese/Spanish for "to drift, wander freely"

---

## Development Phases

| Phase | What | Why First |
|---|---|---|
| **1 — Foundation** | Xcode project, Expo Bare setup, App Store Connect, cloud backend skeleton, user accounts, library scanner (SMB + local + external drive), basic playback | Nothing else works without this |
| **2 — Music Graph** | MusicBrainz MBID matching, source de-duplication, unified track model, metadata pipeline (art, bio, reviews, credits) | Everything else depends on the graph |
| **3 — Streaming Sources** | Spotify Connect, MusicKit (Apple Music), Qobuz Connect, context-aware source resolution | Core value proposition |
| **4 — Zones & AirPlay 2** | AirPlay 2 multi-room, device discovery, saved groups, EQService abstraction, Sonos/BluOS control layer | Multi-room is core value |
| **5 — UI — iPhone & iPad** | Library, Now Playing, Artist, Album, Zones, Queue, Settings | Proven UI before TV |
| **6 — Apple TV** | Lean-back browse, Deriva prompt, zone control, cinematic now playing | Primary living room client |
| **7 — Deriva AI** | AI playlists, discovery, skip learning, library rediscovery | Needs library + history data |
| **8 — Extended** | Offline downloads, vinyl library, Billboard archive, Shazam, stats, CarPlay, Mac bridge, watchOS | Polish and differentiation |

---

## Pre-Build Checklist

- [ ] GitHub repo created (`github.com/tomfo/sorriva`)
- [ ] Xcode project initialized with Expo Bare
- [ ] App Store Connect app record created (iOS, iPadOS, tvOS, macOS)
- [ ] Cloud backend hosting chosen and provisioned
- [ ] Spotify developer account + Connect API access confirmed
- [ ] Apple MusicKit developer entitlement confirmed
- [ ] Qobuz developer API access confirmed
- [ ] MusicBrainz API access confirmed
- [ ] Anthropic API key allocated for Deriva
- [ ] `sessions.json` initialized
- [ ] `roadmap-data.json` populated and phased

---

## Session Conventions

- **Feature IDs** — `fCamelCase` (e.g. `fLibraryScanner`, `fAirPlayZones`, `fMusicGraph`)
- **sessions.json duration_hrs** — equivalent traditional dev hours (XS=3h, S=8h, M=20h, L=40h, XL=80h)
- **owner_hrs** — Tom's actual hours. Never estimated. Always ask at session close.
- **Show-first / build-second** — mockup before any UI code
- **CSS variables only** — never hardcode hex values
- **user_id on every DB record** — commercial-ready from day one
- **Priority reassessment** — mandatory every session

---

## Open Questions / Decisions Pending

- [ ] Cloud backend hosting choice (Railway, Fly.io, Render, AWS — lean toward simple)
- [ ] SiriusXM legal posture for personal use — deferred
- [ ] Pitchfork / AllMusic scraping legal posture — deferred
- [ ] iHeartRadio integration depth — deferred
- [ ] watchOS — future phase, not yet scoped
- [ ] Track matching confidence threshold — what % match is acceptable before flagging for manual review?
- [ ] MusicBrainz MBID matching strategy for local files without embedded IDs (acoustic fingerprinting via AcoustID?)

---

## Decisions & Discussion Log

### Session: 2026-06-24-1
Full product definition. Original architecture: self-hosted Flask/Python server on Mac Mini, Roon replacement positioning. See sessions.json for full notes.

### Session: 2026-07-03 — Architecture Pivot
**Trigger:** Rethinking self-hosting complexity and maintenance burden vs user experience.

**Key decisions:**
- Self-hosted server eliminated entirely — pure App Store product
- AirPlay 2 as multi-room backbone — Tom's full hardware stack (Era 100, Era 300, Roam, Ultra Arc, Bluesound Node) all AirPlay 2 compatible
- AirPlay 2 ecosystem confirmed as audiophile-grade: B&O, Bowers & Wilkins, Devialet, KEF, Naim, Marantz, Denon, Yamaha, NAD all support it
- Unified music graph concept locked — one track identity, source resolved at playback time
- Spotify Connect + MusicKit confirmed as in-app playback path — no app switching, Sorriva owns UI throughout
- Source badge always shown — honest attribution, reinforces value proposition
- Android excluded — AirPlay 2 has no Android equivalent; Apple-first is a deliberate product decision
- Mac app as optional library bridge for remote access — not required for core use case
- External USB-C drive support for iPad — full portable library without network (iPadOS 13+)
- Offline owned music = full Sorriva download; streaming offline = accepted limitation (DRM-sandboxed)
- EQService abstraction — one UI, per-device API translation behind the scenes
- Positioning: not Roon replacement, not Sonos replacement — the intelligent music layer above both
- Commercial story sharpened: $5-8/month, pure App Store, no onboarding friction
