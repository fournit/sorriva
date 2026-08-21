import SwiftUI

// MARK: - DiscoverView — a hub of services
//
// LIBRARY IS WHAT YOU HAVE; DISCOVER IS HOW YOU FIND WHAT YOU DO NOT. Tom, 2026-08-18.
//
// This was a bare Apple Music search box returning a flat list of albums. It is now a set of
// SERVICE ENTRIES, and tapping one dives into that service's own content. Tom, 2026-08-19:
// "discover is more than apple music… first slice would be having an Apple Music selection
// in Discover that you tap and then you are into Apple only content."
//
// WHICH SERVICES BELONG HERE, and the rule is not "all of them". Tom, 2026-08-20:
// discovery needs DIRECT API ACCESS. SiriusXM, Sonos Radio and Spotify can only surface what
// is already saved as a Sonos favorite, so there is nothing to discover against and they are
// deliberately absent — they remain in Settings → Services, where setting them up is the job.
// iHeart and SomaFM DO have direct APIs and could join later; Tom is still deciding, so they
// are not listed rather than listed wrongly.
//
// Tidal and Qobuz appear dimmed because they are the named v1 streaming targets. A dimmed row
// says "this is where this is going" without pretending it works.

struct DiscoverView: View {
    @EnvironmentObject private var discovery: ZoneDiscoveryService

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SorrivaWordmark()
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)
            .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionLabel(title: "Services")

                    NavigationLink {
                        AppleMusicSearchView()
                            .environmentObject(discovery)
                    } label: {
                        DiscoverServiceRow(
                            name: "Apple Music",
                            detail: "Search Apple's whole catalogue",
                            icon: { AppleMusicMark(size: 44) })
                    }
                    .buttonStyle(.plain)

                    DiscoverServiceRow(
                        name: "Tidal",
                        detail: "Coming soon",
                        available: false,
                        icon: { ComingSoonMark(letter: "T", tint: Color(hex: "#00FFFF")) })

                    DiscoverServiceRow(
                        name: "Qobuz",
                        detail: "Coming soon",
                        available: false,
                        icon: { ComingSoonMark(letter: "Q", tint: Color(hex: "#7BC1E8")) })
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 48)
            }
        }
        .background(Color.clear)
    }
}

// MARK: - DiscoverServiceRow
//
// Deliberately the same silhouette as ConnectedServiceRow in Settings → Services — 56pt tile,
// name, detail line — so a service reads as the same thing in both places. What differs is the
// VERB: there you set a service up, here you browse it.

private struct DiscoverServiceRow<Icon: View>: View {
    let name: String
    let detail: String
    var available: Bool = true
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 14) {
            icon()

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.sTextPrimary)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.sTextMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if available {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.sTextMuted)
            }
        }
        .padding(14)
        .background(Color.sSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Dimmed rather than hidden: an unavailable service should be findable and
        // self-explaining, not absent. Same principle the availability model uses.
        .opacity(available ? 1 : 0.45)
        .allowsHitTesting(available)
    }
}

// MARK: - Marks

/// Apple Music's own symbol. NOT a template image — the gradient is the mark, and tinting it
/// would flatten it to a solid block.
struct AppleMusicMark: View {
    var size: CGFloat = 44

    var body: some View {
        Image("AppleMusicSymbol")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}

private struct ComingSoonMark: View {
    let letter: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.sCard)
            .frame(width: 44, height: 44)
            .overlay(
                Text(letter)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(tint))
    }
}
