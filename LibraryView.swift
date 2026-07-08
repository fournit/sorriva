import SwiftUI

struct LibraryView: View {
    var body: some View {
        VStack(spacing: 0) {
            // Navigation bar
            HStack {
                Text("Library")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.sTextPrimary)
                Spacer()
                Button(action: {}) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundColor(.sHighlight)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)
            .padding(.bottom, 20)

            Spacer()

            Text("Library coming in Phase 2")
                .font(.system(size: 15))
                .foregroundColor(.sTextMuted)

            Spacer()
        }
        .background(Color.sBackground)
    }
}

#Preview {
    LibraryView()
        .preferredColorScheme(.dark)
}
