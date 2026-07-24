import SwiftUI

// MARK: - SplashView
// Shown on app launch for 2 seconds before transitioning to ContentView.
// Displays Sorriva wordmark + app icon concept (soundwave dot).

struct SplashView: View {
    @EnvironmentObject private var env: SorrivaAppEnvironment
    @State private var opacity: Double = 0
    @State private var scale: Double = 0.92
    @State private var isDone = false

    var body: some View {
        if isDone {
            ContentView(env: env)
                .environmentObject(env)
                .transition(.opacity)
        } else {
            ZStack {
                // Gradient background — same as app
                LinearGradient(
                    colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 24) {
                    // App icon — soundwave dot concept
                    ZStack {
                        // Outer rings
                        Circle()
                            .stroke(Color.sHighlight.opacity(0.15), lineWidth: 1.5)
                            .frame(width: 100, height: 100)
                        Circle()
                            .stroke(Color.sHighlight.opacity(0.25), lineWidth: 1.5)
                            .frame(width: 72, height: 72)
                        Circle()
                            .stroke(Color.sHighlight.opacity(0.4), lineWidth: 1.5)
                            .frame(width: 46, height: 46)
                        // Center dot
                        Circle()
                            .fill(Color.sHighlight)
                            .frame(width: 18, height: 18)
                    }

                    // Wordmark
                    HStack(alignment: .top, spacing: 0) {
                        Text("sorriva")
                            .font(.system(size: 36, weight: .heavy))
                            .tracking(-0.05 * 36)
                            .foregroundColor(.white)
                            .kerning(-1.8)

                        // Dot
                        Circle()
                            .fill(Color.sAccent)
                            .frame(width: 7, height: 7)
                            .offset(x: 1, y: 1)
                    }
                }
                .scaleEffect(scale)
                .opacity(opacity)
            }
            .onAppear {
                // Fade + scale in
                withAnimation(.easeOut(duration: 0.5)) {
                    opacity = 1
                    scale = 1
                }
                // Fade out after 2 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.easeIn(duration: 0.4)) {
                        opacity = 0
                        scale = 1.04
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        withAnimation { isDone = true }
                    }
                }
            }
        }
    }
}
