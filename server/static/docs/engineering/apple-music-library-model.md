# Apple Music in the Library — the data model

**Status:** proposal, not agreed. **Written:** 2026-08-19.
**Supersedes nothing yet.** Once agreed, `fMusicKitAdapter` slices B–E point here.

---

## 1. What this is for

Tom, 2026-08-19: *"apple music needs to be able to be saved into the library as
albums/playlists with mostly the same features as localplayback."*

Today Apple Music is a search box. You can find an album and play it on a zone, and that
is all — nothing persists, nothing reaches the Library, and closing the app erases any
record it happened. This document is how an Apple album becomes a first-class citizen of
the Library alongside a NAS album, and how a playlist can hold one of each.

The requirement in one line: **an Apple album in the Library should behave like a local
album except where physics genuinely differs.** Section 5 says exactly where that is.

---

## 2. The model — common tables, source-specific detail

Tom's framing, 2026-08-19: *"there should be an apple music table with apple specific
playback data joined to the apple music entry in the main table. only fields in the main
tables that aren't common would be the key to the apple/local/qbuz/etc. tables."*

That is a supertype/subtype schema, and it is the right shape. Common tables hold what is
true of all music; one child table per source holds what only that source has.

```
artists          ← already source-agnostic. NO CHANGE. (see §3)

albums           id, title, sortTitle, primaryArtistId, artistName,
                 year, genre, trackCount, sourceId,
                 artPathThumb, artPathFull, artwork*, art provenance…

  ├─ local_albums    albumId FK, folderPath
  └─ apple_albums    albumId FK, collectionId, artworkBase, copyright

tracks           id, title, albumId, albumTitle, primaryArtistId, artistName,
                 trackNumber, discNumber, year, genre, duration, sourceId

  ├─ local_tracks    trackId FK, filePath, fileFormat, fileSize, bitrate, sampleRate
  └─ apple_tracks    trackId FK, catalogueId, storefront, isStreamable

playlists        id, name, source, artworkPath, trackCount, createdAt, updatedAt
playlist_items   playlistId FK, trackId FK, position

library_sources  id, type ("smb" | "files" | "applemusic"), displayName, …
```

**The foreign key lives in the child, pointing back at the parent.** Not a column per
source on `tracks`. This is the one refinement on Tom's phrasing and it serves his own
stated goal: adding Qobuz later is one new table and *zero* changes to `tracks`,
`albums`, or any query that reads them. Keys in the parent would mean a nullable column
per source — the flat design, one level up.

**`sourceId` already exists** on both `albums` and `tracks`, pointing at
`library_sources`. The "flag on the media" Tom described is therefore already in place;
what is missing is a source row for Apple Music and the child tables behind it.

### Playlists — a header table and a join table

No playlist tables exist today. The "Playlists" row in the Library is `stations` rows with
`kind = "playlist"` — Sonos favorites wearing a label. Sorriva-owned playlists are
entirely new.

`playlists` is the header: name, artwork, `source` (Sorriva's own vs an imported Apple
list), counts. `playlist_items` is the membership.

**The playlist key cannot live on the track row.** Tom, 2026-08-19: *"individual tracks
can have a key to the playlist in the table."* One key per track allows a track to be in
exactly one playlist; the same track needs to appear in several. So the key lives on a
join row — `playlistId`, `trackId`, `position` — one row per appearance. `position` is
what makes a playlist an ordered list rather than a set, and it is also what lets the same
track appear twice in one playlist, which is legitimate.

### Why mixed playlists need no special handling

A playlist item points at a track id. The track knows its source. The source's child
table knows how to address it. A playlist holding one FLAC track and one Apple track is
two rows in `playlist_items` and requires no discriminator, no branching, and no special
case anywhere in the playlist code.

This is the capability Apple's own library cannot offer, and here it is a consequence of
the schema rather than a feature to build.

---

## 3. What does not change

- **`artists`** — no `sourceId`, no file columns, already source-agnostic. An Apple album
  by an artist already in the Library joins the existing artist row. Nothing to do.
- **`albums` and `tracks` keep their common columns and their ids.** Existing rows are not
  rewritten; the file-specific columns move out from under them.
- **Artwork** — Apple serves one URL whose path carries the size, and Sorriva already has
  a cache and an online-artwork pass that writes `artPathThumb` / `artPathFull`. Apple
  artwork goes down that same path. No new artwork mechanism.

---

## 4. The migration, and where the risk is

Local files move from `tracks` into `local_tracks`; `albums.folderPath` moves into
`local_albums`. Additive per I-008: create the child tables, copy the values across,
then drop the old columns in a later migration once nothing reads them.

**This is the risky part of the whole piece of work, and it has nothing to do with Apple
Music.** It touches `SMBScanner`, `LocalPlaybackService`, `GRDBLibraryRepository` and the
artwork passes — code that currently works, against a library that took hours to scan.
Apple Music is additive and safe; making local a peer rather than the default is the part
that can break something.

Mitigations, in order of value:
1. **Read through a view first.** Define `tracks_local` as a join and point existing code
   at it before moving a single column, so the reads are proven before the writes change.
2. The hosted test suite covers the scanner. This is precisely the change that warrants
   proposing it (per CLAUDE.md, scanner and database work behaves differently on device).
3. Baseline snapshot before migrating — outside the repo, per the existing convention.

---

## 5. Feature parity — local versus Apple

"Mostly the same features" made specific. **Same** means the same code path, not a
parallel one.

| Capability | Local FLAC | Apple Music | Notes |
|---|---|---|---|
| Appears in Albums / Artists | yes | **same** | the point of the exercise |
| Album detail screen | yes | **same** | one screen, not two |
| Play whole album | yes | **same** | already proven |
| Play a single track | yes | **same** | addressing already built and tested |
| Add to a playlist | — | — | greenfield for both; §6 slice E |
| Favourite | yes | **same** | |
| Search within Library | yes | **same** | rows are rows |
| Genre / year / sort | yes | **same** | from the catalogue instead of tags |
| Artwork | files, then online | catalogue URL | same cache, same columns |
| Remove from Library | removes the source | unsaves the album | different verb, same button |
| **Browse offline** | yes | **yes** | what the snapshot in §6 buys |
| **Playable right now** | needs the household network | needs the internet | computed, not labelled — §5a |
| **Quality shown** | format, bitrate, sample rate | service-level | bit depth missing today — §5b |
| Refresh | rescan | on open | |

### 5a. Availability is computed, not labelled

Tom, 2026-08-19: *"we know the source of every piece of media in the library so we should
be able to control when it is available for playback; at home with no internet then all
the media tied to a service are disabled, away from home then all the localplayback media
is unavailable."*

This replaces the weaker idea of a warning badge. Because every row carries its source,
**reachability is derivable**, and the Library can state what is playable right now rather
than letting the user discover it by pressing Play and getting silence.

| Situation | NAS media | Service media |
|---|---|---|
| Home, internet up | playable | playable |
| Home, internet down | playable | **unavailable** |
| Away from home | **unavailable** | playable |
| Away, no connection | unavailable | unavailable |

Two things this needs that do not exist yet: a notion of *"am I on the household network"*
(distinct from *"do I have a connection"* — `NetworkIdentity.swift` is the likely home),
and a per-item availability state the UI reads instead of computing inline at every call
site. The dormant model already anticipated the second: `RepresentationAvailability` has
`available` / `unavailable` / `unknown`.

**This is a product behaviour, not an Apple Music detail**, and it applies equally to
Qobuz, Tidal and an unreachable NAS. It belongs in the product guide
(`sorriva-product-spec.html`) with this document referencing it, not defined here.

### 5b. Quality data — there is none

Audited 2026-08-19, and **measured against the real scanned library**, not read off the
struct definitions. An earlier draft of this section claimed bitrate and sample rate were
stored; that was wrong, and it was wrong because the fields exist on `Track` and are
passed to every constructor call.

`meta.bitrate` and `meta.sampleRate` are **never assigned anywhere in `SMBScanner`**. The
simulator's scanned library:

```
95 tracks · 0 with bitrate · 0 with sampleRate · 95 with fileSize · 81 with duration
```

So the Library knows a track is `flac` and how many bytes it is. It does not know whether
it is 16/44.1 or 24/192. `bitDepth` has no column at all — it exists only on
`MusicDomain.AudioProperties`, which nothing writes.

**The data is one line away in both parsers.** The FLAC reader decodes bytes 10–12 of
STREAMINFO to get the sample rate for its duration calculation and discards it
(`SMBScanner.swift:1214`); `bitsPerSample` is packed into those same three bytes. The WAV
reader does the same with the `fmt` chunk and its own comment documents where
`bitsPerSample` sits without ever reading it (`SMBScanner.swift:1022`).

**Proposed fix** — not yet approved:
- `bitDepth` column on `tracks` (moves to `local_tracks` with everything else in slice 2)
- FLAC: store sample rate and bit depth from STREAMINFO; derive bitrate from size ÷ duration
- WAV: the same from the `fmt` chunk
- AIFF: the same from `COMM`, which the parser already walks
- Lossy formats deferred — bit depth is meaningless there and bitrate needs its own work

Existing libraries show nothing until a rescan. This touches the scanner, so it is a
candidate for the hosted suite rather than the fast one.

### 5c. How quality is shown — tiers in lists, numbers on detail

Settled with Tom, 2026-08-19. Sonos today shows only a bare "Lossless" label from Apple
Music, and nothing at all for local playback.

**Store the measured facts; derive the label at display time. Never store the tier.** A
stored tier is a second source of truth that can drift from the numbers behind it, and
moving a boundary later becomes a migration instead of a one-line change.

| Tier | Rule | Badge |
|---|---|---|
| Hi-Res | lossless, and 24-bit or above 48kHz | `Hi-Res` |
| Lossless | lossless at 16/44.1 or 16/48 | `Lossless` |
| Lossy | anything compressed | `Lossy 320` — label **and** rate |
| Unknown | no data captured yet | `Unknown` |

**Lossy carries its bitrate in the badge and the others do not**, because for lossy the
rate *is* the distinction — 128 and 320 are different products, while two 16/44.1 files
are not. Two consequences: a VBR file yields an average rather than a rate, so round it
rather than printing a precise-looking number that moves if the derivation changes; and
`Lossy 320` is roughly twice the width of `Hi-Res`, which the track row layout has to
allow for.

The audience is people who know what 24/96 means, so the full numbers have to be reachable
somewhere; the tier is for scanning, not a substitute for them.

**WHERE the badge appears is TBD** (Tom, 2026-08-19) — album or playlist header, per track
row, Now Playing, or some combination. Deliberately not settled here: it is a UI question
and it should be answered as part of the UI work, not decided in advance by a schema
document. What §5b captures is source data; every placement option is served by the same
stored facts, so nothing downstream is blocked by leaving this open.

**The tier cannot be derived from the file extension.** A `.flac` may be 16/44.1 or
24/192 — same extension, different tier. So §5b is a prerequisite for this, not a
companion to it.

**For service media, nothing is stored** because nothing persists yet, and Apple's
catalogue endpoints do not expose codec detail. Quality for Apple is a property of the
service and the playback path, not of the individual track, and should be modelled that
way rather than by inventing per-track numbers Sorriva cannot verify.

### 5d. Open — file quality versus delivered quality

**No signal-path UI exists.** The only trace in the codebase is a comment on `sBrass`
reading "Premium moments, signal path hi-res".

What matters to this buyer is not only what the file is but what reaches the speaker. A
24/192 FLAC does not arrive at a Sonos as 24/192 — the speaker converts, and the ceiling
varies by model. Showing both would be something neither Sonos nor Apple does.

**Unmeasured. Do not design from the commonly-repeated figures.** It is answerable the
same way §14 of the playback contract was answered: play known 24/96 and 24/192 files to a
nominated zone and ask the speaker what it is actually rendering. That measurement should
happen before any signal-path UI is specified.

---

## 6. Slices

**1 — Discover becomes a hub.** *(Agreed with Tom, 2026-08-19. His framing: "discover is
more than apple music… first slice would be having an Apple Music selection in Discover
that you tap and then you are into Apple only content.")* Today Discover is a bare Apple
Music search box. It becomes a set of service entries; tapping Apple Music is the first
dive, into Apple-only content. Decides nothing about data, so it can go first and
independently of everything below.

**2 — The schema.** Child tables, the local migration, the Apple Music `library_sources`
row. No user-visible change. This is §4 and it is the load-bearing slice.

**3 — Save.** An Apple album is stored as a **full snapshot** — track list, durations,
artwork, metadata — refreshed whenever the album is opened. *(Settled with Tom: staleness
is not a real objection when open refreshes.)* Nothing is written to Apple Music; the
Music app is never launched.

**4 — Library integration.** Saved Apple albums appear in Albums and Artists next to NAS
albums, source visible, actions differing only where §5 says they must.

**5 — Track-level play.** UI for playing and enqueuing a single Apple track. The addresses
and DIDL exist and are tested; this is surface only.

**6 — Playlists, both kinds.** *(Tom: "both".)* They are different things and must look
different:
- **Sorriva playlists** — yours, editable, mixed-source. The §2 payoff.
- **Apple playlists** — Apple's curated and personal lists, browsable and playable,
  read-only. Personal ones need MusicKit; curated may not.

**7 — Browse.** Artist pages, more-by-this-artist, genres, new releases. Wants MusicKit
for artist-correct structure, because the public search is relevance-ranked and has no
"this artist's albums" call.

---

## 6a. Sequencing — agreed 2026-08-19, for the next session

Ordered so that each step is independently useful and nothing later is blocked by a
decision still open. Nothing below is built.

**1. Capture audio quality in the scanner** — `bAudioQualityNeverCaptured`.
Independent of everything else, unblocks every quality feature, and fixes a defect rather
than adding scope. FLAC, WAV and AIFF: sample rate, bit depth, and bitrate derived from
size ÷ duration; new `bitDepth` column. Touches `SMBScanner.swift` only. **Propose the
hosted suite** — this is scanner and database work, which is exactly the case CLAUDE.md
says the fast suite cannot see. Needs a rescan to backfill.

**2. Discover becomes a hub** — `fDiscoverHub`.
Slice 1 of §6. Service entries; Apple Music is the first dive. Pure UI, no data decisions,
no dependencies. Good second item because it is visible progress while the schema work is
still on paper.

**3. Signal-path measurement** — no code, a measurement pass.
Play known 24/96 and 24/192 files to a nominated zone and ask the speaker what it is
actually rendering (§5d). Findings go to `sonos-playback-contract.md`, same discipline as
§14. Cheap, and it decides whether "what you are hearing" is a real feature or an
assumption.

**4. The schema** — slice 2 of §6, and the load-bearing one.
Child tables, the local migration, the Apple Music source row. Read through a join view
before moving any column (§4). This is where the risk is, and it should start a session
rather than end one.

**5 onward** — Save, Library integration, track-level play, playlists, browse, in the
order §6 gives them.

**Deferred, deliberately:**
- Quality-badge and availability-indicator PLACEMENT — a UI decision, answered during the
  UI redo (§5c).
- Search design — Tom: *"search and results needs to really be thought out."* Its own pass
  before slice 7, and re-check the premise first (§7).
- The inert canonical tables — own roadmap entry, not folded into this work (§7).

## 7. Open — not to be assumed

- **Search design.** Tom: *"search and results needs to really be thought out."* Not
  designed here. Today it returns a flat list of albums only — no artists, no songs, no
  playlists as result types, and no dedupe of the same album under two catalogue ids.
  Worth its own pass before slice 7.
- **Search quality may have already improved.** The `fMusicKitAdapter` entry records "Pat
  Metheny" returning a Jaco Pastorius record and a Kronos Quartet album. Re-run on
  2026-08-19 it returned five genuine Metheny albums. Recheck the premise before acting on
  the recorded complaint.
- **The playback token** comes from an existing Sonos favorite of Apple Music, not from
  Sorriva's database. A runtime precondition for playing, not for storing.
- **Storefront.** Catalogue ids are storefront-specific and untested outside the US.
- **The inert canonical tables.** `music_tracks` / `track_representations` etc. were
  created and backfilled by the v13 migration and nothing has read them since. They are an
  earlier, more generic expression of this same idea. They must be finished or deleted —
  a backfilled copy of the library that nothing maintains will drift from the real one and
  will eventually be trusted by someone. **Separate job**; opening a roadmap entry is the
  right move, not folding it in here.

---

## 8. Related

- `fMusicKitAdapter` — the roadmap entry; its build order A–G is the parent of §6
- `sonos-playback-contract.md` §13 — Apple Music addresses, DIDL rules, the `<res>` rule
- `01_Constitution.md` I-006, I-008 — late source resolution, additive migration
- `02_Architecture.md` — the canonical/representation model referenced in §7
