import SwiftUI

// MARK: - Sorriva Color Palette
// Single source of truth. To change the entire app palette, edit only this file.
// Prefix: s = Sorriva (distinguishes from system colors)
// Current palette: Warm Slate

extension Color {

    // MARK: Backgrounds
    // sBackground is not used directly — use gradient stops for the full-screen gradient
    static let sBackground      = Color(hex: "#3A6880")   // Mid-point reference
    static let sGradientTop     = Color(hex: "#5580A8")   // Gradient top — steel blue
    static let sGradientMid     = Color(hex: "#3A6880")   // Gradient mid — blue-teal transition
    static let sGradientBottom  = Color(hex: "#1E4E60")   // Gradient bottom — deep teal
    static let sSurface         = Color(hex: "#253E58")   // Cards, sheets (slightly lighter than card)
    static let sCard            = Color(hex: "#1A3048")   // Zone cards, elevated surfaces

    // MARK: Accent
    static let sAccent      = Color(hex: "#3D5A99")   // Primary accent, active states
    static let sHighlight   = Color(hex: "#89B4D4")   // Secondary text, icons, sliders

    // MARK: Secondary
    static let sBrass       = Color(hex: "#B07D4F")   // Premium moments, signal path hi-res

    // MARK: Text
    static let sTextPrimary   = Color.white
    static let sTextSecondary = Color(hex: "#89B4D4")
    static let sTextMuted     = Color.white.opacity(0.35)

    // MARK: Semantic
    static let sActive        = Color(hex: "#3D5A99")  // Active zone indicator
    static let sIdle          = Color.white.opacity(0.2) // Idle zone indicator
    static let sSeparator     = Color.white.opacity(0.08)

    // MARK: Tab bar
    static let sTabActive     = Color(hex: "#89B4D4")
    static let sTabInactive   = Color.white.opacity(0.85)
}

// MARK: - Hex Initializer
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
