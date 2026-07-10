import SwiftUI

struct DiscoverView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SorrivaWordmark()
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
        .background(Color.clear)
    }
}
