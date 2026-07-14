import SwiftUI

// MARK: - SorrivaContextAction

struct SorrivaContextAction {
    let label: String
    let icon: String
    let iconColor: Color
    let role: ButtonRole?
    let action: () -> Void

    init(label: String, icon: String = "ellipsis", iconColor: Color = .sTextPrimary,
         role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.iconColor = iconColor
        self.role = role
        self.action = action
    }
}

// MARK: - SorrivaContextMenuSheet

struct SorrivaContextMenuSheet: View {
    let title: String
    let subtitle: String?
    let album: Album?        // optional — shows album art in header if provided
    let actions: [SorrivaContextAction]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                if let album = album {
                    AlbumArtView(album: album, size: 56)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.sTextPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.sTextMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(Color.sSeparator)

            VStack(spacing: 0) {
                ForEach(actions.indices, id: \.self) { i in
                    let action = actions[i]
                    ActionRow(
                        icon: action.icon,
                        iconColor: action.role == .destructive ? .red : action.iconColor,
                        title: action.label,
                        action: {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                action.action()
                            }
                        }
                    )
                    if i < actions.count - 1 {
                        Divider().background(Color.sSeparator).padding(.leading, 56)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - SorrivaContextMenuModifier

struct SorrivaContextMenuModifier: ViewModifier {
    let title: String
    let subtitle: String?
    let album: Album?
    let actions: [SorrivaContextAction]
    let sheetHeight: CGFloat

    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4)
                    .onEnded { _ in isPresented = true }
            )
            .sheet(isPresented: $isPresented) {
                SorrivaContextMenuSheet(
                    title: title,
                    subtitle: subtitle,
                    album: album,
                    actions: actions
                )
                .presentationDetents([.height(sheetHeight)])
                .presentationDragIndicator(.visible)
            }
    }
}

extension View {
    func sorrivaContextMenu(
        title: String,
        subtitle: String? = nil,
        album: Album? = nil,
        actions: [SorrivaContextAction],
        sheetHeight: CGFloat = 240
    ) -> some View {
        modifier(SorrivaContextMenuModifier(
            title: title,
            subtitle: subtitle,
            album: album,
            actions: actions,
            sheetHeight: sheetHeight
        ))
    }
}

// MARK: - SorrivaContextActions
// Central factory for all context menu action sets.
// Add new actions here — all menus pick up the change automatically.

enum SorrivaContextActions {

    static func track(_ track: Track, album: Album? = nil,
                      onRemove: @escaping () -> Void) -> [SorrivaContextAction] {
        [
            SorrivaContextAction(label: "Add to Favorites", icon: "heart") {},
            SorrivaContextAction(label: "Play on...", icon: "hifispeaker.2") {},
            SorrivaContextAction(label: "Remove from Library", icon: "trash",
                                 role: .destructive, action: onRemove)
        ]
    }

    static func album(_ album: Album, onRemove: @escaping () -> Void) -> [SorrivaContextAction] {
        [
            SorrivaContextAction(label: "Add to Favorites", icon: "heart") {},
            SorrivaContextAction(label: "Play on...", icon: "hifispeaker.2") {},
            SorrivaContextAction(label: "Remove from Library", icon: "trash",
                                 role: .destructive, action: onRemove)
        ]
    }

    static func artist(_ artist: Artist) -> [SorrivaContextAction] {
        [
            SorrivaContextAction(label: "Add to Favorites", icon: "heart") {},
            SorrivaContextAction(label: "Play on...", icon: "hifispeaker.2") {}
        ]
    }

    static func radioStation(isFavorite: Bool,
                              onFavorite: @escaping () -> Void,
                              onPlayOn: @escaping () -> Void,
                              onRemove: @escaping () -> Void) -> [SorrivaContextAction] {
        [
            SorrivaContextAction(
                label: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                icon: isFavorite ? "heart.fill" : "heart",
                iconColor: isFavorite ? .sBrass : .sTextPrimary,
                action: onFavorite
            ),
            SorrivaContextAction(label: "Play on...", icon: "hifispeaker.2", action: onPlayOn),
            SorrivaContextAction(label: "Remove from Library", icon: "trash",
                                 role: .destructive, action: onRemove)
        ]
    }
}
