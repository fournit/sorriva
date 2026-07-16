import SwiftUI
import GRDB

@main
struct SorrivaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Configure URL cache — large capacity for station logos and artwork
        URLCache.shared = URLCache(
            memoryCapacity: 100 * 1024 * 1024,  // 100MB memory
            diskCapacity:   500 * 1024 * 1024,  // 500MB disk
            diskPath: "sorriva_image_cache"
        )

        // Initialize database on first launch — creates SQLite file and runs migrations
        _ = SorrivaDatabase.shared
        // Reset any sources stuck in "scanning" state from a previous interrupted session
        resetStaleScanStates()
        // Prefetch station logos into URLCache so Library loads instantly
        prefetchStationLogos()
    }

    private func prefetchStationLogos() {
        Task.detached(priority: .background) {
            let iheart = (try? SorrivaDatabase.shared.allStations(source: "iheart")) ?? []
            let somafm = (try? SorrivaDatabase.shared.allStations(source: "somafm")) ?? []
            let urls = (iheart + somafm)
                .compactMap { $0.logoURL }
                .compactMap { URL(string: $0) }

            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask {
                        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
                        guard URLCache.shared.cachedResponse(for: request) == nil else { return }
                        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return }
                        let cached = CachedURLResponse(response: response, data: data)
                        URLCache.shared.storeCachedResponse(cached, for: request)
                    }
                }
            }
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
