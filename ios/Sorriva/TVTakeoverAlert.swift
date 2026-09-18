import SwiftUI

// MARK: - TVTakeoverAlert
// The one alert shown before Sorriva takes a room away from a television.
//
// Playback in Sorriva is not funnelled through a single door — the local library goes
// via PlaybackCoordinator, Apple Music and radio call SonosCommands directly, and
// transfer and grouping are their own paths. Four call sites raise this alert, so the
// words and the buttons live here rather than being retyped four times.
//
// House style, matching ServiceSetupView: .alert(title, isPresented: .constant(...),
// presenting:) with a trailing message closure. The presentation binding is .constant,
// so BOTH buttons must clear the pending state themselves.

extension View {

    /// Single-zone form — play into a room, or transfer into one.
    func tvTakeoverAlert(zone: Binding<SonosZone?>,
                         onPlay: @escaping (SonosZone) -> Void) -> some View {
        alert(TVTakeover.title(zoneName: zone.wrappedValue?.name ?? ""),
              isPresented: .constant(zone.wrappedValue != nil),
              presenting: zone.wrappedValue) { pending in
            // No role on Play: it is consequential but not destructive, and Cancel
            // carries .cancel so iOS already makes the safe choice the default.
            Button("Play") {
                zone.wrappedValue = nil
                onPlay(pending)
            }
            Button("Cancel", role: .cancel) { zone.wrappedValue = nil }
        } message: { _ in
            Text(TVTakeover.message())
        }
    }

    /// Grouping form — one or more rooms being added to a group are on their TV input.
    /// There is no single SonosZone to hand back, so the caller keeps the pending work.
    func tvTakeoverAlert(zoneNames: Binding<[String]?>,
                         onPlay: @escaping () -> Void) -> some View {
        alert(TVTakeover.title(zoneNames: zoneNames.wrappedValue ?? []),
              isPresented: .constant(zoneNames.wrappedValue != nil),
              presenting: zoneNames.wrappedValue) { _ in
            Button("Play") {
                zoneNames.wrappedValue = nil
                onPlay()
            }
            Button("Cancel", role: .cancel) { zoneNames.wrappedValue = nil }
        } message: { _ in
            Text(TVTakeover.message())
        }
    }
}
