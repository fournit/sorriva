# Integrating a Radio Service

**Last updated:** 2026-08-04
**Applies to:** adding any new streaming radio provider (iHeartRADIO and SomaFM are the first two of many)

Everything here was established empirically by polling live Sonos zones and reading
what they actually return. Do not assume any of it can be inferred from the UPnP spec
or from how the previous service behaved — the two we have already behave differently
from each other.

---

## 1. The one rule that matters

**Sonos tells you the URI. It does not reliably tell you the station name, and it may
not tell you the artwork at all. The station name comes from our own stations table,
never from Sonos.**

Every bug in this area has come from some code path trusting Sonos's `dc:title`.

---

## 2. What Sonos actually returns

Verified 2026-08-03/04 against live zones playing iHeart and SomaFM.

| Field | iHeartRADIO (HLS) | SomaFM |
|---|---|---|
| `CurrentURI` / `TrackURI` | ✅ always correct | ✅ always correct |
| `dc:title` | ❌ `hls.m3u8` — the filename | ⚠️ `secretagent-128-aac` — a stream slug, not the name |
| `upnp:albumArtURI` | ❌ **absent entirely** | ✅ present |
| `dc:title` from `GetMediaInfo` | ❌ absent | — |
| `r:streamContent` | ✅ `TYPE=SNG\|TITLE …\|ARTIST …` | varies |

Two consequences:

- **Track and artist** can come from Sonos (`r:streamContent`) and usually do.
- **Station name and artwork** must come from our database. For iHeart there is
  literally nothing else available — Sonos has no idea what station it is playing.

`StationMetadataResolver.isValidStationName` exists to reject the junk in that column.
It will never be complete: it rejects `.aac` but not `-aac`, which is exactly how the
SomaFM slug reached the UI. **Do not fix such gaps by extending the reject list** —
the next provider will invent a shape you did not anticipate. The lookup below wins
over `dc:title` by design, which makes the validator's blind spots harmless.

---

## 2a. Which field carries now-playing is the SERVICE'S decision

Added 2026-08-13 after `bSonosRadioTitleShownAsStation`. Section 2's table describes
iHeart and SomaFM. **Sonos Radio inverts it**, and reading either layout globally breaks
the other:

| Field | iHeart / SomaFM | Sonos Radio |
|---|---|---|
| `r:streamContent` | ✅ the song | ❌ **absent entirely** |
| `dc:title` | ❌ filename / slug | ✅ the song — `My Hood` |
| `dc:creator` | — | ✅ the artist — `RAY BLK` |
| `upnp:albumArtURI` | ❌ absent / station logo | ✅ **per-track cover**, sonosradio.imgix.net |

Both mistakes have shipped. Reading `dc:title` globally put `hls.m3u8` on a zone card;
deleting that read left Sonos Radio with no track, no artist and no artwork at all.

So `NowPlayingSource` is declared per adapter — `.streamContent` or `.trackMetadata` —
and defaults to `.streamContent`, which means **a service nobody has taught us about
keeps the behaviour that shipped rather than getting a new guess.**

Two rules that fall out of this:

- **Artwork is not held on a miss.** Track and artist ARE held when Sonos reports an
  empty title between songs, because blanking flickers the card once per track. Artwork
  is cleared, because a cover that outlives its song is worse than no cover — the
  station logo behind it is at least true of what is playing.
- **Per-track art outranks the station logo** everywhere, including in the async
  resolver's completion. A station logo is only ever a stand-in for artwork we could not
  get.

---

## 2b. Identity is what is LOADED, not what is playing

`GetPositionInfo.TrackURI` is the TRACK. `GetMediaInfo.CurrentURI` is the STATION. For
iHeart and SomaFM they are the same string, which is why nothing needed this for months:

```
Sonos Radio, Office, 2026-08-13
  CurrentURI  x-sonosapi-radio:sonos%3a158291?sid=303&flags=0&sn=1     ← the station
  TrackURI    x-sonos-http:sonos%3a4375c80b…-DZR%3a28%3a…              ← changes per song
```

Matching a station against `TrackURI` therefore missed on **every song, forever**, and
the no-blank rule held whatever Sorriva last played — a zone playing Brit Soul reported
Cocktail Hour indefinitely. Always match on `SonosZone.stationIdentityURI`.

**Order matters in the poll:** `GetMediaInfo` runs BEFORE `GetPositionInfo`, because the
now-playing parse asks which service is loaded before deciding where the song title
lives.

**One channel, two spellings.** The stored favorite and the live URI differ in the case
of the percent-encoded colon AND in `flags`, for the same station:

```
stored  x-sonosapi-radio:sonos%3A158291?sid=303&flags=28780&sn=1
live    x-sonosapi-radio:sonos%3a158291?sid=303&flags=0&sn=1
```

Identity is the channel: lowercase, and discard everything from `?` onward.

---

## 2c. When nothing matches, say so

A zone whose loaded URI resolves to nothing shows **Unknown** — or `"<Service> ·
Unknown"` where an adapter claims the URI — never the last thing Sorriva played. Track,
artist and artwork still come from the stream; only identity is withheld.

This requires three states, not two. `pending` (asked, no answer yet) must hold the
current display or the card flashes on every station change; `unidentified` (asked,
nothing matched) is what says Unknown. Collapsing them into "empty name" is what made
holding stale content the only safe response.

---

## 2d. Queue-based services are identified by their TRACK URI

Added 2026-08-16 (`fSpotifyNowPlaying`). Sections 2a–2c assume the loaded URI names a
service. Spotify breaks that: a favorite is a **container**, and playing it expands into
the Sonos queue, so what is loaded afterwards is

```
x-rincon-queue:RINCON_804AF2A73E9901400#0
```

— an address naming no service at all. Asking only the loaded URI meant Spotify fell
through to `r:streamContent`, which it leaves **empty**, so the card showed nothing.

**The rule:** ask the loaded URI first, and only when no adapter claims it, ask the track
URI. Order matters — a station that IS identified must not be overridden by its own
per-song address.

Local albums also play from the queue. Nothing claims `x-file-cifs://`, so they keep the
path they have always had. Any new adapter must not claim it either.

## 2e. Artwork may be served by the speaker, not the service

| Service | `upnp:albumArtURI` |
|---|---|
| Sonos Radio | `https://sonosradio.imgix.net/…` — absolute |
| Spotify | `/getaa?s=1&u=x-sonos-spotify%3a…` — **relative**, served by the speaker on :1400 |

Resolve relative paths against `http://<speaker-host>:1400`. Left alone it renders as a
broken image, which reads as a metadata bug and sends you looking in the wrong place.

---

## 2f. SiriusXM — one channel, two identifier spaces

Added 2026-08-17. A channel arrives differently depending on **who started it**, and no key
function can reconcile the two:

```
stored favorite   x-sonosapi-stream:channel-linear%3A65f04311-…?sid=37&flags=8260&sn=3
Sonos app/Sorriva x-sonosapi-hls:channel-linear%3a65f04311-…?sid=37&flags=8200&sn=4
Alexa             hls-radio://…/AAC_Audio/classicrewind/classicrewind_variant_short_v4.m3u8
```

The first two are one channel — same UUID, differing by scheme, colon case and the account
handle. The third has **no id at all**, only a channel slug in the path.

So `matches(uri:station:)` exists on the adapter protocol: the default compares canonical
keys, and SiriusXM overrides it to fall back to **slug versus station name**. That name
match is the reason the `CH 25 - ` prefix is stripped at import — `ch25classicrewind`
can never equal `classicrewind`.

**Never display this service's `dc:title`:** on an Alexa session it is
`classicrewind_variant_short_v4.m3u8`, the same trap that once put `hls.m3u8` on a card.

## 2g. Artwork is a separate question from song text

`NowPlayingSource` answers only "where does the TEXT come from". Whether a service
publishes a per-song cover is `providesTrackArt`, and it defaults to **false**.

They were one either/or choice until 2026-08-17, and SiriusXM broke it: song text in
`r:streamContent`, cover in `upnp:albumArtURI`. Forced to pick one, it lost the artwork.

| service | text | per-song art |
|---|---|---|
| iHeart, SomaFM | `r:streamContent` | no |
| Sonos Radio, Spotify | track metadata | yes |
| **SiriusXM** | **`r:streamContent`** | **yes** |

**Remote HTTP artwork is blocked** — App Transport Security permits HTTP only on the local
network, so an internet `http://` image renders blank AND displaces the station logo that
would otherwise show. Upgrade to `https` (verified: albumart.siriusxm.com serves the
byte-identical image over TLS). If a service ever turns up whose art host has no TLS, drop
its URL rather than weakening transport security.

SiriusXM's metadata is also **intermittent** — 60s of polling can return no text and no
art. Absence is normal; fall back to the station logo.

---

## 3. URI schemes differ by who started playback

The *same station* arrives under different schemes depending on origin:

```
Sorriva plays SomaFM   →  x-rincon-mp3radio://ice2.somafm.com/secretagent-128-aac
Sonos app plays SomaFM →  aac://http://ice2.somafm.com/secretagent-128-aac
iHeart (either)        →  hls-radio://http://stream.revma.ihrhls.com/zc8681/hls.m3u8
                          ?rj-ttl=…&rj-tok=…&init_id=…&streamid=…&playedFrom=…
```

Note that schemes **nest** (`aac://http://`), and that iHeart appends **session tokens
that change on every poll**.

Raw string comparison therefore cannot identify a station. Use
`PlaybackContextService.normalizedStreamKey`, which strips all nested schemes and the
query string, leaving `host/path`:

```
ice2.somafm.com/secretagent-128-aac
stream.revma.ihrhls.com/zc8681/hls.m3u8
```

That key is stable across origin and across polls. **It is also the cache key** — using
the raw URI instead means iHeart's rotating tokens invalidate the cache on every poll,
which produced ~40 redundant database lookups for one station in a single session
(`bPlaybackContextResolveChurn`).

---

## 4. Checklist for a new service

1. **Store `streamURL` on every station row.** This is the lookup key. A station with
   no stored URL can never be identified when playback starts outside the app.
2. **Store it in a form that normalizes to the same key as playback.** If browse-time
   and play-time URLs differ (a `.pls` playlist vs the resolved stream, or a different
   CDN mirror), the normalized keys will not match and the lookup silently fails.
3. **Store `logoURL`.** Sonos may supply no artwork at all; ours may be the only source.
4. **Backfill on play.** The play path should write the URL it actually used —
   `upsertStation` preserves existing values when passed `nil`, so this only ever
   improves the row. This is what makes an unidentifiable station self-heal after one
   play through Sorriva.
5. **Never scope the reverse lookup to one source.** Use
   `SorrivaDatabase.allStationsAnySource()`. A stream started from the Sonos app could
   be from any provider.

---

## 5. Test matrix

A service is not integrated until all of these pass. The second row is the one that
catches integration bugs — it exercises the path where the app had no involvement in
starting playback and must identify the stream from the URI alone.

| Scenario | Expected |
|---|---|
| Play from Sorriva | Name + artwork immediately (declaration path) |
| **Start from the Sonos app** | Name + artwork within one poll cycle |
| Transfer zone → zone | Name + artwork follow; source clears |
| Round trip A → B → A | A shows current content, not its pre-transfer station |
| Watch the log during steady play | `resolved station from URI` appears **once per station change**, not once per poll |

Diagnosing a failure: the log prints the exact key that failed to match —

```
CONTEXT: no station matches stream key 'host/path' — leaving unnamed
```

Compare that key against the `streamURL` stored for the station. A mismatch is a data
problem (item 1 or 2 above); an absent log line means the lookup never ran.

---

## 5a. Known issue — the resolve cache is not holding (`bStationResolverRerunsEveryPoll`)

Observed 2026-08-04: **every zone re-resolves its station on every poll**, indefinitely.
The `CONTEXT: resolved station from URI` line repeats for the same zone/station pair
dozens of times in a single capture. Each one is a *successful* resolve — the lookup
works, it just runs again next cycle, reading the full stations table and re-running
adapter matching each time.

`resolvedStations` exists precisely to make this run once per URI change, and this same
churn was reportedly fixed once before. It is not diagnosed. The cache read looks correct
on inspection, and rotating session tokens are ruled out — the normalised key strips the
query string, and iHeart URIs measured directly off a speaker carry none.

**Why it matters beyond wasted work:** the raw `dc:title` fallback in `stationDisplay`
only surfaces when the cache misses. A working cache would mask that whole class of
error, so a station showing `hls.m3u8` or a bitrate slug is a *symptom of the cache
missing*, not only of a bad lookup. Bear that in mind when integrating a new service —
if raw names appear, check the cache before blaming the adapter.

Next step is instrumentation: log the stored key beside the computed key on a miss. They
either differ (key instability) or the entry is absent (the write is not landing), and
those need opposite fixes.

---

## 6. Related

- `PlaybackContextService` — `normalizedStreamKey`, `resolveStationFromURI`, the
  `resolvedStations` cache
- `StationMetadataResolver` — validates/cleans Sonos DIDL fields; absolutizes Sonos's
  relative `/getaa?…` art paths against the zone host
- `HANDOFF-playbackstore-design.md` — the declaration model; a declaration is the fast
  path for app-initiated playback, while the URI lookup is the safety net that makes
  every zone converge regardless of origin
- `sonos-upnp-reference.html` — SOAP/UPnP call reference and S2 firmware quirks
