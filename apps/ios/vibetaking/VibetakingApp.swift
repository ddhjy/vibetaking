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
            if newPhase == .active {
                HistoryManager.shared.refreshFromEnvironment()
            }
        }
    }
}
