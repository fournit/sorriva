import SwiftUI

struct DiscoverView: View {
    var body: some View {
        VStack(spacing: 0) {
            // Navigation bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Discover")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.sTextPrimary)
                    Text("Powered by Deriva")
                        .font(.system(size: 12))
                        .foregroundColor(.sBrass)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)
            .padding(.bottom, 20)

            Spacer()

            Text("Deriva AI coming in Phase 7")
                .font(.system(size: 15))
                .foregroundColor(.sTextMuted)

            Spacer()
        }
        .background(Color.sBackground)
    }
}

#Preview {
    DiscoverView()
        .preferredColorScheme(.dark)
}
