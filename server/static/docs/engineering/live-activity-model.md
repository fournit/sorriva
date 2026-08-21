# Live Activities in Sorriva — what fits, what doesn't, and why

**Status:** design analysis, unbuilt. **Written:** 2026-08-20.
**Feature:** `fLiveActivity`. **Depends on:** `fAppIntents`, `fSonosEventSubscriber`.

---

## 1. What a Live Activity actually is

Not a miniature app running in the background. The app calls `Activity.request()`, and
from that moment **the operating system owns the presentation**. A WidgetKit extension
defines how it looks; ActivityKit manages its lifecycle; iOS renders it on the Lock Screen
and in the Dynamic Island.

**Dynamic Island is not a second feature.** It is one of the presentations of a Live
Activity — compact leading, compact trailing, minimal, expanded. Build the activity and
the Island comes with it. Design the four states separately; they are not one layout
scaled down.

Two kinds of data: `ActivityAttributes` are fixed for the activity's lifetime, and
`ContentState` changes while it runs. For Sorriva the zone is plausibly an attribute and
everything about the music is content state — but see §6, because that choice interacts
with when an activity ends.

---

## 2. The standard architecture, and why Sorriva cannot use it

Every reference treatment of Live Activities resolves to the same picture:

```
backend (source of truth) → APNs → ActivityKit → Lock Screen / Dynamic Island
```

The app is just another client of the backend. Crucially, **the app does not need to be
running** for a push-driven activity to update. That is Apple's blessed answer, and it is
robust precisely because it does not depend on the phone.

**It is also what Sonos does.** Measured 2026-08-20 on Tom's phone: with Wi-Fi off, the
Sonos widget kept working and the volume genuinely changed in the room. Cloud-relayed in
both directions.

**Sorriva has no backend by design**, so this whole architecture is unavailable. Note the
distinction Tom drew, 2026-08-19: no backend means Sorriva does not *run* a server. It
already calls other people's APIs. What it cannot do is host the HTTPS endpoint that
APNs-driven Live Activity updates require.

Sonos's own Control API is not a way round this — see §7.

---

## 3. The one hard constraint: iOS suspends apps

An iOS app is **not guaranteed to keep running in the background**, and a suspended
process is not servicing sockets. This is the single fact that shapes everything below.

Sorriva's state lives on the speakers, on the LAN. So the update path must be one of:

| Path | Needs | Verdict |
|---|---|---|
| App polls the speakers | app running | fails on suspension |
| APNs push | a backend we host | unavailable by design |
| GENA callback to a listener | app running to receive it | **the spike — §4** |
| Local push connectivity | an Apple entitlement | contingency — §5 |
| Update on user interaction | nothing | **always works — §6** |

---

## 4. The spike, and the honest expectation

`fSonosEventSubscriber` builds a GENA subscriber. The exit question: **does a suspended
app still receive callbacks?** Subscribe, log every callback with a timestamp, background
the app, lock the phone, change the track from another controller, and watch when they
stop.

**Expect them to stop.** The background-execution rule above is a strong prior. The spike
is still worth running — "probably" is not "measured", and this project has been wrong in
both directions from reasoning alone — but the plan should be built for the fallback
rather than surprised by it.

---

## 5. Local push connectivity — the contingency, not the plan

`NEAppPushProvider` is a Network Extension that stays alive on designated Wi-Fi networks
so an app can receive traffic from a local server while suspended. It exists for on-prem
systems.

**Nothing is registered with Apple about the network.** `matchSSIDs` is an array the app
sets at runtime via `NEAppPushManager` and saves to the device. Apple grants the
*entitlement to use the capability*; the SSID list never leaves the phone.

Two real costs before anyone reaches for it:

1. **The entitlement is requested, not switched on**, and it has historically been aimed
   at enterprise and carrier use cases. Whether Apple grants it for a consumer music
   controller is genuinely uncertain.
2. **Filling in `matchSSIDs` means knowing the home network's name.** Reading the current
   SSID on iOS requires location permission — a heavy ask for a music app. The alternative
   is asking the user to confirm the network rather than detecting it.

Evaluate only if §4 fails *and* §6 proves insufficient.

---

## 6. The fallback, which is most of the value

**Controls always work. The display is correct whenever you interact, and stale otherwise.**

Tapping a control fires an App Intent, which runs in the app's process. That gives it
enough execution to send the SOAP command *and* refresh what the activity shows. So:
glance at the Lock Screen and it may show the previous track; touch anything and it
corrects immediately.

This needs no entitlement, no backend, no key, and no agreement with anyone. It is worth
shipping on its own, and everything above is an upgrade to it rather than a precondition.

**The controls are the point; the display is context.** A design that treats it the other
way round will conclude this feature is not worth building, which would be wrong.

---

## 7. Sonos's Control API is not a route

Investigated 2026-08-20, not adopted.

- **Cloud Control API** — event subscription requires a registered public HTTPS callback
  URL that we would have to host, returning 403 without one. That is the backend Sorriva
  does not have.
- **Local Control API** — port 1443 is open on the speakers and answers, so it exists
  despite Sonos documenting the LAN API as "not available for wide release". But it
  enforces a key: `ERROR_API_KEY_VALIDATION_FAILED`.

The key is a hard gate at the endpoint, on both. That the household's speakers are already
talking to Sonos's cloud creates no opening — that is their app with their key over TLS to
their servers.

So there are two ways in: register for a key and accept Sonos's partner terms, or extract
a key from their app. **The second is not a foundation for a shipping product** — it
circumvents an access control and would break the day they rotate it. The first is a
business decision, not a technical step: Sorriva is a paid App Store app competing with
the Sonos app, built on an interface Sonos publishes for its own use, and today there is
no agreement with them at all.

Parked deliberately. GENA needs none of it.

---

## 8. Design decisions still to make

- **When does an activity start and end?** Playback starting is the obvious trigger. Ending
  is the interesting one: Tom observed the Sonos activity *disappear* rather than grey out
  when the system became unreachable, and that is the right behaviour — a stale control
  with dead buttons on a Lock Screen is worse than no control. Whether that is driven by
  `staleDate` lapsing or an explicit `end()` is worth establishing when building.
- **Zone as attribute or content state.** If the zone is an immutable attribute, moving
  playback to another room means ending one activity and starting another. That may be
  correct, or it may be jarring.
- **Which controls belong there** — play/pause and skip are obvious; volume is what Tom
  reached for first on the Sonos widget.
- **What each of the four presentations shows.** Lock Screen, compact, minimal, expanded
  are four designs, not one.
- **Multiple zones playing at once.** See §8a — it is the largest open question here.

### 8a. Multiple zones — the constraints, measured against Apple's documentation

Sorriva is a multi-room controller, so several zones playing at once is the NORMAL case,
not an edge case. Two facts bound the design, both confirmed 2026-08-20:

**Only `Button` and `Toggle` are supported**, and only when driven by an App Intent.
Pickers, scroll views and every other interactive control do not work. This is
architectural rather than arbitrary: while the activity is on screen the app's code is not
running, so only discrete one-shot actions are possible. **A zone picker inside the
activity is therefore impossible.**

A zone *switcher* is not. Buttons can do the same job — a "next zone" control that cycles,
or a row of zone buttons in the expanded Dynamic Island presentation, which has the most
room of the four.

**The Dynamic Island shows at most TWO activities** — one attached to the TrueDepth
camera, one rendered detached. The Lock Screen has no documented limit and stacks them.
So three zones playing means three cards on the Lock Screen and only two ever visible in
the Island.

**The two candidate designs:**

1. *One activity, last zone started.* This is what Sonos does — Tom confirmed it 2026-08-20
   and was not sure he liked it. Simple, and never fights for Island space. Wrong whenever
   the user was not the last person to press play, which in a household with several
   listeners is often.
2. *One activity per playing zone.* Honest to what is happening — three rooms playing is
   three things happening. Lock Screen carries them all; the Island degrades past two.

**SETTLE THIS BY LOOKING, NOT BY REASONING.** Three stacked cards may feel cluttered in a
way no amount of specification will predict. Build a throwaway that starts three activities
early in the work and look at it on a real phone before committing. Tom, 2026-08-20:
"we'd have to see how it looks with stacking them and/or how much flexibility it has".

---

## 9. Verify against current Apple documentation before building

Not assumed here, and worth checking rather than inheriting from a general guide:
duration limits, update frequency, push budgets, `staleDate` semantics, push-to-start,
what an App Intent is allowed to do and for how long, privacy of Lock Screen content, and
who owns termination.

**Deployment target is iOS 26.5**, so nothing is version-gated.

---

## 10. Related

- `fLiveActivity`, `fAppIntents`, `fSonosEventSubscriber`, `fiOSWidgets` — roadmap
- `availability-model.md` — the same LAN boundary, in the Library
- `sonos-playback-contract.md` §12 — event-only fields a GENA subscriber would expose

---

## 11. Implementation shape

The material in this section is adapted from a general ActivityKit analysis Tom supplied
on 2026-08-20. **It is received guidance, not measured fact** — unlike the Sonos findings
elsewhere in this document, none of it has been verified against a build. Treat §9's
checklist as still owed.

### Target layout, and why the App Group is not optional

`ActivityAttributes` must be visible to **both** the app and the widget extension — the
app constructs it, the extension renders it. That means a shared target or shared file,
and it lands on the same plumbing `fiOSWidgets` already needs:

```
Sorriva/                  the app — starts, updates and ends activities
Shared/                   ActivityAttributes — visible to both
SorrivaLiveActivity/      widget extension — Lock Screen + the three Island presentations
```

Neither the extension nor the App Group exists today. The extension runs in its own
process, so anything it needs from the GRDB database goes through the App Group container.

### State model

The activity should render a state, not compute one. Sorriva already has the authoritative
answer in `PlaybackStore` — `ZonePlaybackSnapshot` is close to what the content state
needs, and the activity should be a projection of it rather than a second source of truth
that can disagree with the app.

```swift
struct ContentState: Codable, Hashable {
    var status: PlaybackStatus      // idle, starting, playing, paused, unreachable
    var title: String?
    var artist: String?
    var elapsed: Int?
    var duration: Int?
    var volume: Int
    var isStale: Bool               // display is last-known, not confirmed — see §6
}
```

`isStale` is Sorriva-specific and follows directly from §6: when the display is
last-known rather than confirmed, say so rather than presenting old data as current. That
is the same honesty rule the Library applies to availability.

### Error and unreachable states

The activity must be able to represent failure, not only playback. `unreachable` is the
one that matters here and it is not an error — it is the normal state of a LAN controller
whose phone has left the network. §8's decision on ending versus displaying it applies.

A failed command should be visible rather than silently swallowed; a control that appears
to work and does not is worse than one that reports it could not.

### Encapsulate ActivityKit behind a service

`LiveActivityManager` with `start` / `update` / `end`, rather than ActivityKit calls
scattered through the app. Two reasons beyond tidiness: it keeps ActivityKit out of the
domain model, and it gives the update path a single place to live — which matters because
§4 may change what that path is.

### Widget and Live Activity are different things

Kept distinct on the roadmap (`fiOSWidgets` versus `fLiveActivity`) for a reason:

| | Widget | Live Activity |
|---|---|---|
| Purpose | information available periodically | something happening right now |
| Lifetime | indefinite | temporary, tied to the event |
| Dynamic Island | no | yes |
| Frequent state change | refresh budget is stingy | designed for it |

Which is why a home-screen widget suits *starting* something — a zone switcher, a library
shortcut — while tracking what is playing belongs to the Live Activity.
