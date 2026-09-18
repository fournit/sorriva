import SwiftUI

// MARK: - PlaybackSettingsView
// Settings → Playback. Behaviour that applies when Sorriva starts audio, as opposed to
// what it plays. Previously a stub row labelled "Coming in Phase 4".
//
// One section today: the volume a room is set to when Sorriva takes it off its TV input.

struct PlaybackSettingsView: View {

    // Absent defaults mean ON at TVTakeover.defaultVolume — the same fallback
    // TVTakeover.startingVolume applies, so a fresh install behaves identically whether
    // or not this screen has ever been opened. Keys live on TVTakeover so the decision
    // and the control cannot drift apart.
    @AppStorage(TVTakeover.volumeEnabledKey) private var setVolumeOnTVTakeover = true
    @AppStorage(TVTakeover.volumeLevelKey)   private var startingVolume = TVTakeover.defaultVolume

    // Split out because a `...` operator cannot open a continuation line inside the
    // Slider's argument list — Swift reads it as a missing separator.
    private var volumeBounds: ClosedRange<Double> {
        Double(TVTakeover.volumeRange.lowerBound)...Double(TVTakeover.volumeRange.upperBound)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSectionLabel(title: "TV rooms")

                        VStack(alignment: .leading, spacing: 0) {

                            Toggle(isOn: $setVolumeOnTVTakeover) {
                                Text("Set volume when taking a room from TV")
                                    .font(.system(size: 15))
                                    .foregroundColor(.sTextPrimary)
                            }
                            .tint(.sAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)

                            Divider()
                                .background(Color.sSeparator)
                                .padding(.leading, 16)

                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Starting volume")
                                        .font(.system(size: 15))
                                        .foregroundColor(setVolumeOnTVTakeover ? .sTextPrimary : .sTextMuted)
                                    Spacer()
                                    Text("\(startingVolume)")
                                        .font(.system(size: 15, weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundColor(setVolumeOnTVTakeover ? .sHighlight : .sTextMuted)
                                }

                                Slider(
                                    value: Binding(
                                        get: { Double(startingVolume) },
                                        set: { startingVolume = Int($0.rounded()) }
                                    ),
                                    in: volumeBounds,
                                    step: 1
                                )
                                .tint(.sAccent)
                                .disabled(!setVolumeOnTVTakeover)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .background(Color.sSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        // The reason, in the place it is decided. A soundbar sits at the
                        // level the television left it at, which is not a music level —
                        // measured at 6 on the Living Room Arc Ultra straight after a
                        // film, against 12 in the rooms playing music.
                        Text("A room playing TV audio is set to the volume its television left behind. "
                           + "When Sorriva takes the room for music, it starts at this level instead. "
                           + "Only that room changes — other rooms in a group keep their own volume.")
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                            .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 24)
                // Clearance for the floating tab bar and mini player, which overlay the
                // scroll view rather than taking up layout space — same as SettingsView.
                .padding(.bottom, 180)
            }
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
    }
}
