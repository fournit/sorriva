import SwiftUI
import GRDB

@main
struct SorrivaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Initialize database on first launch — creates SQLite file and runs migrations
        _ = SorrivaDatabase.shared
    }

    var body: some Scene {
        WindowGroup {
            SplashView()
                .preferredColorScheme(.dark)
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .portrait
    }
}
