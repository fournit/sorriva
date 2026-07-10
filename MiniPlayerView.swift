import SwiftUI

struct MiniPlayerView: View {
    var body: some View {
        HStack(spacing: 12) {

            // Album art placeholder
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.sAccent)
                .frame(width: 40, height: 40)

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing playing")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.sTextPrimary)
                Text("—")
                    .font(.system(size: 11))
                    .foregroundColor(.sTextSecondary)
            }

            Spacer()

            // Play/pause
            Button(action: {}) {
                Image(systemName: "play.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.sTextPrimary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.sGradientBottom.opacity(0.95))
    }
}

#Preview {
    MiniPlayerView()
        .preferredColorScheme(.dark)
}
