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
                .onAppear {
                    // TEMP: prove local playback — plays hardcoded track on Living Room
                    // after 5 seconds to give discovery time to find zones
                    Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        guard let zone = ZoneDiscoveryService.sharedInstance?.zones.first(where: { $0.name == "Living Room" }) else {
                            print("LOCALPLAY TEST: Living Room not found — zones: \(ZoneDiscoveryService.sharedInstance?.zones.map(\.name) ?? [])")
                            return
                        }
                        guard let track = try? SorrivaDatabase.shared.track(id: "83C137BC-4010-4375-B140-55A2DE5E4431") else {
                            print("LOCALPLAY TEST: track not found")
                            return
                        }
                        print("LOCALPLAY TEST: firing — \(track.title) on \(zone.name)")
                        await LocalPlaybackService.shared.playTrack(track, on: zone)
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
