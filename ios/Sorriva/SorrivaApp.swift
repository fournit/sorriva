import SwiftUI

// MARK: - InterruptedScanAlert
// The alert MUST observe ScanCoordinator directly.
//
// SorrivaAppEnvironment declares `@Published var scanCoordinator: ScanCoordinator = .shared`,
// but @Published on a reference type fires only when the REFERENCE changes —
// never here, since it is assigned once. Mutating interruptedScanSource fires
// objectWillChange on ScanCoordinator, which nothing was observing, so the alert
// binding was never re-evaluated and no alert appeared.
//
// It worked intermittently, which made it look like a detection bug rather than
// a rendering one: any unrelated publish on `environment` triggered a re-render
// that then found the non-nil value. Killing during the file scan happened to
// produce that churn; killing during the quieter artwork phase did not
// (observed 2026-07-30 — the log showed "interrupted scan detected" with no
// alert on screen).
//
// This is the same pitfall ContentView.swift already documents for tabState,
// discovery and playbackStore.

private struct InterruptedScanAlert: ViewModifier {
    @ObservedObject var coordinator: ScanCoordinator
    let database: SorrivaDatabase

    func body(content: Content) -> some View {
        content.alert(
            "Scan Incomplete",
            isPresented: Binding(
                get: { coordinator.interruptedScanSource != nil },
                set: { if !$0 { coordinator.interruptedScanSource = nil } }
            )
        ) {
            Button("Resume Scan") {
                if let source = coordinator.interruptedScanSource {
                    coordinator.resumeScan(source: source)
                }
            }
            Button("Start Over") {
                if let source = coordinator.interruptedScanSource {
                    coordinator.confirmAndScanSource(source)
                }
            }
            Button("Cancel", role: .cancel) {
                if let source = coordinator.interruptedScanSource {
                    Task {
                        try? database.updateScanState(sourceId: source.id, state: "complete")
                    }
                }
                coordinator.interruptedScanSource = nil
            }
        } message: {
            if let source = coordinator.interruptedScanSource {
                let root = source.rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let lastComponent = root.components(separatedBy: "/").filter { !$0.isEmpty }.last ?? root
                let shareDetail = root.isEmpty ? source.share : "\(source.share) — .../\(lastComponent)"
                Text("The scan of \(shareDetail) on \(source.displayName) did not complete. Resume continues where it stopped; Start Over rescans everything.")
            } else {
                Text("A previous scan did not complete. Resume continues where it stopped; Start Over rescans everything.")
            }
        }
    }
}

@main
struct SorrivaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    // Single composition root — owns all long-lived services for the app session.
    @StateObject private var environment = SorrivaAppEnvironment()
    @State private var hasLaunched = false

    init() {
        // Configure URL cache — large capacity for station logos and artwork.
        URLCache.shared = URLCache(
            memoryCapacity: 100 * 1024 * 1024,  // 100MB memory
            diskCapacity:   500 * 1024 * 1024,  // 500MB disk
            diskPath: "sorriva_image_cache"
        )

        // Give ArtistInfoService its database hooks. They are inert until this runs, because
        // the service is compiled Foundation-only into the fast test suite and cannot see
        // GRDB — see ArtistInfoCache.
        ArtistInfoCache.install()
    }

    var body: some Scene {
        WindowGroup {
            SplashView()
                .environmentObject(environment)
                .preferredColorScheme(.dark)
                .modifier(InterruptedScanAlert(
                    coordinator: environment.scanCoordinator,
                    database: environment.database
                ))
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                ScanCoordinator.shared.checkForChanges()
                // WP-14: Only refresh on foreground if we've been backgrounded — not on first launch.
                // SorrivaAppEnvironment.init already calls startDiscovery() on first launch.
                if hasLaunched && !environment.discovery.zones.isEmpty {
                    // Only notify if we have zones — avoids double-discovery on launch
                    NotificationCenter.default.post(name: .sorrivaAppDidBecomeActive, object: nil)
                    LocalPlaybackService.shared.resetShareRegistrations()
                }
                hasLaunched = true
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        return true
    }
}
