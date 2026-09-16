import SwiftUI

@main
struct VibetakingApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var demoMode = DemoModeManager.shared

    init() {
        AppAppearance.configureNavigationButtons()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .id(demoMode.isEnabled)
                .modifier(AppAppearance())
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // First load comes from ContentView.onAppear. Refreshing here as well
                // queued a second full disk scan on every cold start.
                if HistoryManager.shared.hasLoadedHistory {
                    HistoryManager.shared.refreshFromEnvironment()
                }
            case .inactive, .background:
                // Debounced draft edits must reach disk before the app can be suspended.
                HistoryManager.shared.flushPendingDraftWrite()
            @unknown default:
                break
            }
        }
    }
}
