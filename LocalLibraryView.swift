import SwiftUI

// MARK: - LocalLibraryView
// Placeholder — full SMB/NAS scanning coming in a future session.

struct LocalLibraryView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 44))
                    .foregroundColor(.sBrass)

                Text("Local Library")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.sTextPrimary)

                Text("SMB / NAS scanning coming soon.")
                    .font(.system(size: 14))
                    .foregroundColor(.sTextMuted)
            }
        }
        .navigationTitle("Local Library")
        .navigationBarTitleDisplayMode(.inline)
    }
}
