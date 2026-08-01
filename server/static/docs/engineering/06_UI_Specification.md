# 06 — Sorriva UI Specification
Version: 1.1
Status: APPROVED
Audience: AI Engineering Agents

---

## Overview

The UI layer is divided into two modules with a strict dependency direction:

```text
PassioneUI          ← portfolio-wide primitives, zero product knowledge
        ↓
SorrivaMusicUI      ← music screens composed from PassioneUI components
        ↓
SorrivaApp / LumvaraUI  ← product shells, navigation, configuration
```

PassioneUI is shared across all Passione/Lumvara products. SorrivaMusicUI owns music-specific screen composition and presentation only. Neither layer contains business logic.

---

## MODULE: PassioneUI

Name: PassioneUI
Type: Swift Package

Purpose:
Shared presentation framework for all Passione and Lumvara products.

Consumers:
- SorrivaMusicUI
- LumvaraUI
- Future applications

Dependencies:
Allowed:
- SwiftUI
- Foundation

Forbidden:
- MusicDomain
- Playback
- Scanner
- Repository
- Networking
- Sonos
- SMB
- GRDB

Exports:
- Design Tokens
- Theme
- Navigation
- Controls
- Components
- Animation
- Layout
- Icons
- Preview Support

---

## MODULE: SorrivaMusicUI

Name: SorrivaMusicUI
Type: Swift Package (or folder boundary initially)

Purpose:
Composes PassioneUI into Sorriva music workflows. Owns screen composition and presentation only.

Consumers:
- SorrivaApp
- LumvaraMusicHost

Dependencies:
Allowed:
- PassioneUI
- SwiftUI
- Foundation
- ScreenModels (read-only observation)

Forbidden:
- MusicDomain (direct)
- GRDB
- SMB
- Sonos
- Networking
- PlaybackCoordinator (direct)
- Repository (direct)

Responsibilities:
- Music screen layouts
- Screen model binding
- Navigation composition within music flows
- No business logic
- No infrastructure access

---

## PRINCIPLES

P001: PassioneUI contains presentation only.
P002: Business logic is forbidden in both modules.
P003: Product-specific styling is forbidden in PassioneUI.
P004: Reusable visual patterns belong in PassioneUI.
P005: Products compose PassioneUI. PassioneUI never composes products.
P006: Accessibility is implemented once in PassioneUI.
P007: Components are composition-first.
P008: SorrivaMusicUI composes PassioneUI. It does not extend or override it.

---

## PACKAGE STRUCTURE

```text
PassioneUI/
    Tokens/
        Colors
        Typography
        Spacing
        Radius
        Elevation
        Motion
    Theme/
    Icons/
    Controls/
    Components/
    Navigation/
    Layout/
    Animation/
    Utilities/
    PreviewSupport/

SorrivaMusicUI/
    Screens/
        Zones/
        NowPlaying/
        Library/
        AlbumDetail/
        Search/
        Settings/
    ScreenModels/
    Components/     ← music-specific composites not reusable outside Sorriva
```

---

## TOKEN CONTRACT

Rules:
- No hardcoded colors.
- No hardcoded spacing.
- No hardcoded typography.
- No hardcoded animation timing.
- No hardcoded corner radius.

Typography scale:
Display, Headline, Title, Body, Caption, Label, Micro

Spacing scale:
none, xs, sm, md, lg, xl, xxl

Motion scale:
instant, fast, normal, slow

Radius scale:
small, medium, large, pill, circle

---

## DESIGN LANGUAGE

Theme: Dark-first

Color palette (from approved mockup):
- Canvas: #121923
- Surface: #1C2A38
- Surface Elevated: #233445
- Accent Blue: #8EB4D4
- Accent Muted: #587A96
- Brass: #B07D4F

Typography: SF Pro Display (Semibold/Bold for headings), SF Pro Text (Regular/Medium for body)

Visual goals:
- Premium
- Calm
- Content-first
- Large artwork
- Minimal chrome
- Consistent spacing
- Consistent typography
- Motion communicates state only

---

## PRIMITIVE CONTROL CONTRACT

Every primitive defines:
- Purpose
- Inputs
- Outputs
- States
- Accessibility
- Preview
- Tests

Owns:
- Rendering
- Interaction
- Animation
- Accessibility

Forbidden:
- Business logic
- Playback
- Networking
- Persistence
- Repositories

Initial primitives:
Button, IconButton, TextField, SearchField, Slider,
Toggle, ProgressBar, Badge, ArtworkView, Card,
NavigationBar, TabBar, Sheet, Dialog, Menu, Divider.

---

## COMPOSITE COMPONENT CONTRACT

Composed only from PassioneUI primitives.

Initial catalog:
- AlbumCard
- ArtistRow
- PlaylistCard
- TrackRow
- QueueRow
- ZoneCard
- DeviceCard
- MiniPlayer
- PlaybackControls
- SearchResultRow

Composite components never:
- Query repositories
- Start playback
- Navigate
- Hold business state

Components receive value types as inputs only. ScreenModels in SorrivaMusicUI feed them.

---

## NAVIGATION FRAMEWORK

PassioneUI provides:
- Root container
- Tab container
- Navigation stack
- Split view
- Bottom sheet
- Dialog
- Context menu
- Toast
- HUD
- Overlay

Products provide:
- Destinations
- Navigation state
- Actions

---

## SCREEN CONTRACT

```text
View (SorrivaMusicUI)
→ ScreenModel (SorrivaMusicUI)
→ ApplicationService (Sorriva)
→ Repository / Coordinator (Sorriva)
→ Domain (MusicDomain)
```

Forbidden:
- View → Repository
- View → PlaybackCoordinator
- View → Networking
- View → Database

---

## INFORMATION ARCHITECTURE

Primary tabs: Library, Zones, Discover, Settings

Mini-player: persistent above tab bar, always visible during playback.

Now Playing: expands from mini-player, not a tab.

Queue: reachable from Now Playing.

Discover: visual scaffolding only for daily-driver release. No AI or recommendation functionality until explicitly promoted.

Navigation depth:
- Prefer: Library → Artist → Album → Now Playing
- Never: Library → Artist → Album → Track → Options → Queue → ...

---

## ACCESSIBILITY

Required:
- Dynamic Type
- VoiceOver
- Reduced Motion
- High Contrast
- Keyboard
- Pointer

---

## AI IMPLEMENTATION RULES

Before creating a component:
1. Search PassioneUI first.
2. Reuse existing component if appropriate.
3. If reusable by multiple products, implement in PassioneUI.
4. If music-specific but reusable within Sorriva/Lumvara music, implement in SorrivaMusicUI.
5. If product-shell-specific, implement in SorrivaApp or LumvaraUI.

Never:
- Duplicate controls.
- Add business logic to views.
- Bypass ScreenModels.
- Introduce product branding into PassioneUI.
- Access infrastructure from views.

---

## ACCEPTANCE CRITERIA

- PassioneUI compiles independently with zero product dependencies.
- SorrivaMusicUI compiles with PassioneUI only; no infrastructure imports.
- Zero business logic in either module.
- UI redesigns require no changes to MusicDomain, Scanner, PlaybackCoordinator, or Repository layer.
- Products built entirely from PassioneUI and SorrivaMusicUI components.
