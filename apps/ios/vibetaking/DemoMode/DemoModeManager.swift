import Foundation

enum AppDefaults {
    static let demoSuiteName = "cn.1pointech.vibetaking.demo"

    static let demo: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: demoSuiteName) else {
            preconditionFailure("Unable to create demo UserDefaults suite")
        }
        return defaults
    }()

    static var current: UserDefaults {
        DemoModeManager.isEnabledFlag ? demo : .standard
    }
}

@MainActor
@Observable
final class DemoModeManager {
    static let shared = DemoModeManager()

    static let enabledKey = "demoModeEnabled"

    private(set) var isEnabled: Bool

    /// 供后台线程的存储根解析使用。标志位始终写在 `UserDefaults.standard`，不随配置组切换。
    nonisolated static var isEnabledFlag: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    nonisolated static func demoStorageURL(fileManager: FileManager = .default) -> URL {
        let url = URL.documentsDirectory.appending(path: "Demo", directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }

        if enabled {
            resetDemoStorage()
            DemoSeedData.seed(into: Self.demoStorageURL(), defaults: AppDefaults.demo)
        }

        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        reloadManagers()
        isEnabled = enabled
    }

    private func resetDemoStorage() {
        let url = Self.demoStorageURL()
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        AppDefaults.demo.removePersistentDomain(forName: AppDefaults.demoSuiteName)
        AppDefaults.demo.synchronize()
    }

    private func reloadManagers() {
        TagManager.shared.reload()
        WorkflowManager.shared.reload()
        SettingsManager.shared.reload()
        HistoryManager.shared.switchDataset()
        SkillStore.shared.resetAndReload()
        AgentSessionStore.shared.resetAndReload()
    }
}
