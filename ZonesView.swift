import SwiftUI

struct ZonesView: View {
    var body: some View {
        VStack(spacing: 0) {
            // Navigation bar
            HStack {
                Text("Zones")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.sTextPrimary)
                Spacer()
                Button(action: {}) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 20))
                        .foregroundColor(.sHighlight)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)
            .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Playing section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Playing")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.sTextMuted)
                            .textCase(.uppercase)
                            .kerning(0.8)
                            .padding(.horizontal, 20)

                        Text("No active zones")
                            .font(.system(size: 15))
                            .foregroundColor(.sTextMuted)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }

                    // Available section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Available")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.sTextMuted)
                            .textCase(.uppercase)
                            .kerning(0.8)
                            .padding(.horizontal, 20)

                        Text("No zones found")
                            .font(.system(size: 15))
                            .foregroundColor(.sTextMuted)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .background(Color.sBackground)
    }
}

#Preview {
    ZonesView()
        .preferredColorScheme(.dark)
}
