import SwiftUI

// MARK: - SorrivaWordmark
// Passione brand standard: Inter 800, -0.05em tracking, product-color dot.
// Used in the top-left of every screen header.

struct SorrivaWordmark: View {
    var size: CGFloat = 22

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("sorriva")
                .font(.system(size: size, weight: .heavy))
                .kerning(-size * 0.05)
                .foregroundColor(.white)

            Circle()
                .fill(Color.sAccent)
                .frame(width: size * 0.28, height: size * 0.28)
                .offset(x: 1, y: 1)
        }
    }
}
