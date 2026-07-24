import SwiftUI

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
    }

    var body: some Scene {
        WindowGroup {
            SplashView()
                .environmentObject(environment)
                .preferredColorScheme(.dark)
                .alert(
                    "Scan Incomplete",
                    isPresented: Binding(
                        get: { environment.scanCoordinator.interruptedScanSource != nil },
                        set: { if !$0 { environment.scanCoordinator.interruptedScanSource = nil } }
                    )
                ) {
                    Button("Restart Scan") {
                        if let source = environment.scanCoordinator.interruptedScanSource {
                            environment.scanCoordinator.confirmAndScanSource(source)
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        if let source = environment.scanCoordinator.interruptedScanSource {
                            Task {
                                try? environment.database.updateScanState(sourceId: source.id, state: "complete")
                            }
                        }
                        environment.scanCoordinator.interruptedScanSource = nil
                    }
                } message: {
                    if let source = environment.scanCoordinator.interruptedScanSource {
                        let root = source.rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        let lastComponent = root.components(separatedBy: "/").filter { !$0.isEmpty }.last ?? root
                        let shareDetail = root.isEmpty ? source.share : "\(source.share) — .../\(lastComponent)"
                        Text("The scan of \(shareDetail) on \(source.displayName) did not complete. Would you like to restart it?")
                    } else {
                        Text("A previous scan did not complete. Would you like to restart it?")
                    }
                }
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
