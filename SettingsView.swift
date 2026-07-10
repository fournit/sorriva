import SwiftUI

struct SettingsView: View {
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

            Text("Settings coming in Phase 1")
                .font(.system(size: 15))
                .foregroundColor(.sTextMuted)

            Spacer()
        }
        .background(Color.clear)
    }
}
