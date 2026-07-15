import SwiftUI
import GRDB

@main
struct SorrivaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Initialize database on first launch — creates SQLite file and runs migrations
        _ = SorrivaDatabase.shared
        // Reset any sources stuck in "scanning" state from a previous interrupted session
        resetStaleScanStates()
        // TEMP: smoke test — start HTTP server on launch, check console for IP
        do {
            try SorrivaHTTPServer.shared.start()
        } catch {
            print("HTTPSERVER: failed to start — \(error)")
        }
    }

    private func resetStaleScanStates() {
        let sources = (try? SorrivaDatabase.shared.allLibrarySources()) ?? []
        for source in sources where source.scanState == "scanning" {
            try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "error")
        }
    }

    var body: some Scene {
        WindowGroup {
            SplashView()
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                ScanCoordinator.shared.checkForChanges()
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .portrait
    }
}
