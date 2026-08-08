import SwiftUI

// MARK: - ServiceHeaderCard
//
// The header for a service's detail screen — iHeartRADIO, SomaFM, and whatever
// comes next. One component, so a new service inherits the treatment instead of
// copying it.
//
// It was two copies before this existed: IHeartServiceView and SomaFMServiceView
// each drew their own header, identical apart from the icon and the words. A third
// service would have made three, and they would have drifted, which is how the
// share and server cards ended up with three different action affordances between
// them.
//
// A CARD, ALWAYS. Tom's rule, 2026-08-08: every service gets the same header card
// whether or not it needs credentials. Making the card itself conditional — a plain
// header for simple services, a card for credentialed ones — is the inconsistency,
// because then the shape of the screen tells you about the service's auth model
// rather than about the service.
//
// THE ELLIPSIS IS WHAT VARIES, and only appears when there is genuinely a menu
// behind it. Same rule as everywhere else in the app: a chevron promises the body
// opens something, an ellipsis promises a menu, and showing one with nothing behind
// it is the lie the share card was telling until this morning. Services needing
// sign-in pass `onActions`; iHeart and SomaFM do not.
//
// Sized to match the server header in Local Library, since it does the same job:
// this is the thing the list below belongs to.

struct ServiceHeaderCard<Icon: View>: View {

    let name: String
    let subtitle: String
    /// Non-nil shows the ellipsis and makes the card tappable. Leave nil when the
    /// service has nothing to configure.
    var onActions: (() -> Void)? = nil
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            icon()
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.sTextPrimary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.sTextMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if onActions != nil {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17))
                    .foregroundColor(.sTextMuted)
                    .padding(.top, 2)
            }
        }
        .padding(18)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .contentShape(Rectangle())
        .onTapGesture { onActions?() }
    }
}
