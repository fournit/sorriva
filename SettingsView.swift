import SwiftUI

struct SettingsView: View {
    var body: some View {
        VStack(spacing: 0) {
            // Navigation bar
            HStack {
                Text("Settings")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.sTextPrimary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)
            .padding(.bottom, 20)

            Spacer()

            Text("Settings coming in Phase 1")
                .font(.system(size: 15))
                .foregroundColor(.sTextMuted)

            Spacer()
        }
        .background(Color.sBackground)
    }
}

#Preview {
    SettingsView()
        .preferredColorScheme(.dark)
}
