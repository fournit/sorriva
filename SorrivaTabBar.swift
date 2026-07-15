import SwiftUI
import Combine

// MARK: - SorrivaTabBar
// Custom floating tab bar that sits above the mini player.
// Uses brand tokens from Color+Theme.swift throughout — no hardcoded colors.
// Auto-hides behavior driven by SorrivaTabBarState environment object.

enum SorrivaTab: CaseIterable {
    case library, zones, discover, settings

    var label: String {
        switch self {
        case .library:  return "Library"
        case .zones:    return "Zones"
        case .discover: return "Discover"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .library:  return "music.note.list"
        case .zones:    return "hifispeaker.2"
        case .discover: return "sparkles"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - SorrivaTabBarState
// Environment object that controls tab bar visibility.
// Scroll views write to isVisible to auto-hide/show.

final class SorrivaTabBarState: ObservableObject {
    @Published var isVisible: Bool = true
    @Published var selectedTab: SorrivaTab = .zones

    func show() {
        withAnimation(.easeOut(duration: 0.2)) { isVisible = true }
    }

    func hide() {
        withAnimation(.easeOut(duration: 0.2)) { isVisible = false }
    }
}

// MARK: - SorrivaTabBar View

struct SorrivaTabBar: View {
    @ObservedObject var state: SorrivaTabBarState

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SorrivaTab.allCases, id: \.self) { tab in
                Button(action: { state.selectedTab = tab }) {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 22))
                            .foregroundColor(
                                state.selectedTab == tab ? .sTabActive : .sTextMuted
                            )
                        Text(tab.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(
                                state.selectedTab == tab ? .sTabActive : .sTextMuted
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(Color.sHighlight.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)
        )
        .padding(.horizontal, 20)
        .offset(y: state.isVisible ? 0 : 100)
        .opacity(state.isVisible ? 1 : 0)
    }
}
