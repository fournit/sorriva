# Availability — what can actually play, right now

**Status:** agreed in principle 2026-08-19, unbuilt.
**Scope:** all sources. Not an Apple Music detail.

---

## The rule

Tom, 2026-08-19: *"we know the source of every piece of media in the library so we should
be able to control when it is available for playback; at home with no internet then all
the media tied to a service are disabled, away from home then all the localplayback media
is unavailable."*

Every row in the Library carries its source. **Reachability is therefore derivable**, and
the Library can state what is playable now rather than letting the user find out by
pressing Play and getting silence.

This replaces an earlier, weaker proposal to show a warning badge on service content. A
badge describes; this decides.

| Situation | NAS / local media | Service media (Apple, Qobuz, Tidal…) |
|---|---|---|
| Home, internet up | playable | playable |
| Home, internet down | playable | **unavailable** |
| Away from home | **unavailable** | playable |
| Away, no connection | unavailable | unavailable |

The asymmetry is the point. Local music needs the household network and does not need the
internet. Service music needs the internet and does not care which network you are on.
Neither condition is "online".

## Why this is not a Sonos question

The speakers are on the household network by definition. When Sorriva is away from home it
cannot reach the speakers *or* the NAS, so playback is a different conversation entirely
(remote control of a household is its own unbuilt feature). What this model governs is
**what the Library offers**, which is a question even when nothing can play at all.

## What it needs that does not exist

1. **"Am I on the household network?"** — distinct from "do I have a connection", and the
   two are routinely conflated. `NetworkIdentity.swift` is the likely home. Sonos discovery
   already answers a version of this implicitly; making it explicit and cheap to ask is the
   work.
2. **A per-item availability state the UI reads**, rather than every call site recomputing
   the rule inline. The dormant `MusicDomain.RepresentationAvailability` already models
   exactly this: `available` / `unavailable` / `unknown`.

`unknown` matters. On a cold launch, before discovery has answered, the honest state is
"not yet known" — and greying the whole Library for a second while it settles would be
worse than the problem.

## Boundaries

- **Unavailable means visibly unavailable, not hidden.** A user looking for an album should
  find it and be told why it cannot play, not conclude it is gone. Hiding rows would make
  the Library appear to change size with the network.
- **This is availability, not quality.** What a track *is* (`apple-music-library-model.md`
  §5c) and whether it can play right now are separate facts and separate indicators.
- **It applies to an unreachable NAS too**, not only to travel — a NAS that is powered off
  at home is the same state as being away from it.

## Open

- Where the indicator lives, and whether an unavailable row is dimmed, badged, or both.
  Deferred with the rest of the quality-badge placement question — a UI decision, to be
  answered during the UI work rather than settled by this document.
- Whether an unavailable item should still be openable (track list visible, Play disabled)
  or inert. Leaning openable: the snapshot data is local, so there is nothing to gain by
  refusing to show it.

## Related

- `apple-music-library-model.md` — the source-per-row model this depends on
- `01_Constitution.md` I-006 — late source resolution
- `MusicDomain.swift` — `RepresentationAvailability`, currently unused
