import SwiftUI

@main
struct VibetakingApp: App {
    @State private var demoMode = DemoModeManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .id(demoMode.isEnabled)
        }
    }
}
