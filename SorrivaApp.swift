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
        for source in sources {
            if source.scanState == "scanning" {
                // Killed mid-scan — mark as error so checkForChanges surfaces restart alert
                try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "error")
            }
            // "retrying" state is left intact — checkForChanges will resume the scheduler
        }
    }

    @ObservedObject private var coordinator = ScanCoordinator.shared

    var body: some Scene {
        WindowGroup {
            SplashView()
                .preferredColorScheme(.dark)
                .alert(
                    "Scan Incomplete",
                    isPresented: Binding(
                        get: { coordinator.interruptedScanSource != nil },
                        set: { if !$0 { coordinator.interruptedScanSource = nil } }
                    )
                ) {
                    Button("Restart Scan") {
                        if let source = coordinator.interruptedScanSource {
                            coordinator.confirmAndScanSource(source)
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        if let source = coordinator.interruptedScanSource {
                            // User chose not to restart — mark complete so alert never fires again
                            Task {
                                try? SorrivaDatabase.shared.updateScanState(sourceId: source.id, state: "complete")
                            }
                        }
                        coordinator.interruptedScanSource = nil
                    }
                } message: {
                    if let source = coordinator.interruptedScanSource {
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
