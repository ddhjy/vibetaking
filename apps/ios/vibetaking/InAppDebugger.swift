#if DEBUG && canImport(FLEX)
import FLEX
#endif

enum InAppDebugger {
    static var canShowExplorer: Bool {
        #if DEBUG && canImport(FLEX)
        true
        #else
        false
        #endif
    }

    @MainActor
    static func showExplorer() {
        #if DEBUG && canImport(FLEX)
        FLEXManager.shared.showExplorer()
        #endif
    }
}
