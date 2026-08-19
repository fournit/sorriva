import SwiftUI

// MARK: - AppleMusicServiceView
//
// Apple Music's card in Settings → Services. It has no station list to manage, because it
// is not a favorites-backed service: Sorriva reaches the WHOLE catalogue through Apple's
// public endpoints, and browsing happens in Discover.
//
// So this screen exists to answer two questions a person would come here to ask — is
// Apple Music working, and what do I have to do — rather than to configure anything.

struct AppleMusicServiceView: View {
    /// Whether the household has Apple Music linked, asked of the speakers rather than
    /// assumed. See SonosCommands.availableServiceIds.
    let linked: Bool
    /// Whether a favorite carrying the household token has been found. Playback needs it;
    /// browsing does not.
    let hasToken: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [.sGradientTop, .sGradientMid, .sGradientBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ServiceHeaderCard(name: "Apple Music", subtitle: subtitle) {
                        Image(systemName: "music.note")
                            .font(.system(size: 26))
                            .foregroundColor(Color(hex: "#FC3C44"))
                            .frame(width: 56, height: 56)
                            .background(Color.sSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    step(number: 1,
                         title: "Search in Discover",
                         detail: "Apple's whole catalogue is searchable — no account needed, "
                               + "nothing to add here.",
                         done: true)

                    step(number: 2,
                         title: linked ? "Apple Music is on your Sonos"
                                       : "Add Apple Music to your Sonos",
                         detail: linked
                             ? "Your speakers can play it, using your household's subscription."
                             : "Add it as a service in the Sonos app. Sorriva can find music "
                             + "without it, but your speakers can't play it.",
                         done: linked)

                    step(number: 3,
                         title: hasToken ? "Ready to play"
                                         : "Save one favourite in the Sonos app",
                         detail: hasToken
                             ? "Sorriva found your household's Apple Music access."
                             : "Save any Apple Music album or playlist as a Sonos favourite. "
                             + "Sorriva reads your household's access from it — the same "
                             + "one-time step SiriusXM and Spotify need. You only do this once.",
                         done: hasToken)
                }
                .padding(.bottom, 48)
            }
        }
        .navigationTitle("Apple Music")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var subtitle: String {
        if !linked { return "Not on your Sonos yet" }
        return hasToken ? "Ready — browse in Discover" : "One step left"
    }

    /// A step, and whether it is done. Deliberately shows what is ALREADY true as well as
    /// what remains: a screen that only lists outstanding work leaves the reader unsure
    /// whether anything is working at all.
    private func step(number: Int, title: String, detail: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.system(size: 19))
                .foregroundColor(done ? Color(hex: "#FC3C44") : .sTextMuted)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.sTextPrimary)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.sTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(14)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }
}
