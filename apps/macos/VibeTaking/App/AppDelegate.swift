import Cocoa
import ApplicationServices
import SystemConfiguration

private struct DraftHistoryEntry: Codable {
    enum Reason: String, Codable {
        case stoppedInput
        case pastedDraft
        case directPaste
        case remoteCleared
        case replacedBeforeInput

        var displayTitle: String {
            switch self {
            case .stoppedInput:
                return "停止输入"
            case .pastedDraft:
                return "已粘贴"
            case .directPaste:
                return "直接粘贴"
            case .remoteCleared:
                return "草稿被清空"
            case .replacedBeforeInput:
                return "开始新输入"
            }
        }
    }

    let id: UUID
    let text: String
    let createdAt: Date
    let reason: Reason
    let sourceAddress: String?
}

private final class DraftHistoryStore {
    private let maxItemCount = 100
    private let fileURL: URL?

    init() {
        let fm = FileManager.default
        guard let appSupportDirectory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fileURL = nil
            return
        }

        fileURL = appSupportDirectory
            .appendingPathComponent("VibeTaking", isDirectory: true)
            .appendingPathComponent("draft-history.json")
    }

    func load() -> [DraftHistoryEntry] {
        guard let fileURL else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DraftHistoryEntry].self, from: data).prefix(maxItemCount).map { $0 }) ?? []
    }

    func save(_ entries: [DraftHistoryEntry]) {
        guard let fileURL else { return }

        let fm = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()

        do {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(Array(entries.prefix(maxItemCount)))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save draft history: \(error)")
        }
    }
}

private enum LaunchAtLoginError: LocalizedError {
    case libraryDirectoryUnavailable
    case bundlePathUnavailable
    case invalidConfiguration
    case writeFailed(Error)
    case removeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .libraryDirectoryUnavailable:
            return "无法定位当前用户的 LaunchAgents 目录。"
        case .bundlePathUnavailable:
            return "无法获取当前应用路径，暂时不能设置开机启动。"
        case .invalidConfiguration:
            return "生成开机启动配置时失败，请稍后重试。"
        case .writeFailed(let error):
            return "写入开机启动配置失败：\(error.localizedDescription)"
        case .removeFailed(let error):
            return "移除开机启动配置失败：\(error.localizedDescription)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .libraryDirectoryUnavailable, .bundlePathUnavailable, .invalidConfiguration:
            return nil
        case .writeFailed, .removeFailed:
            return "请确认应用对 ~/Library/LaunchAgents 目录有写权限。"
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private static let sharedHistoryTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var settingsWindowController: SettingsWindowController?

    private var titleItem: NSMenuItem!
    private var ipItem: NSMenuItem!
    private var portItem: NSMenuItem!
    private var historyItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!

    private var port: UInt16 = 7788
    private var launchAtLogin = false
    private var server: HTTPServer?
    private var serverRunning = false
    private let bonjourAdvertiser = BonjourAdvertiser()
    private var ipTitleResetWorkItem: DispatchWorkItem?

    private let historyStore = DraftHistoryStore()
    private var historyEntries: [DraftHistoryEntry] = []
    private var historyWindowController: DraftHistoryWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        historyEntries = historyStore.load()
        synchronizeLaunchAtLoginState()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton()
        buildMenu()
        updateIcon()
        startServer()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshIPItem()
        updateAccessibilityStatus()
        refreshSettingsWindow()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        titleItem = NSMenuItem(title: "随心记", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        menu.addItem(makeMenuItem(
            title: "关于随心记",
            action: #selector(showAboutPanel(_:)),
            symbolName: "info.circle"
        ))

        menu.addItem(makeMenuItem(
            title: "设置…",
            action: #selector(showSettingsWindow(_:)),
            keyEquivalent: ",",
            symbolName: "gearshape"
        ))
        menu.addItem(.separator())

        ipItem = makeMenuItem(
            title: ipMenuTitle(),
            action: #selector(copyIPSummary(_:)),
            symbolName: "network"
        )
        menu.addItem(ipItem)

        portItem = makeMenuItem(
            title: "端口：\(port)",
            action: #selector(changePort(_:)),
            symbolName: "number"
        )
        menu.addItem(portItem)

        menu.addItem(.separator())

        historyItem = makeMenuItem(
            title: "查看历史记录",
            action: #selector(showHistoryWindow(_:)),
            symbolName: "clock.arrow.circlepath"
        )
        menu.addItem(historyItem)

        menu.addItem(.separator())

        accessibilityItem = makeMenuItem(
            title: "辅助功能",
            action: #selector(openAccessibilitySettings(_:)),
            symbolName: "checkmark.circle.fill"
        )
        menu.addItem(accessibilityItem)
        updateAccessibilityStatus()

        menu.addItem(.separator())

        menu.addItem(makeMenuItem(
            title: "退出随心记",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q",
            symbolName: "power"
        ))

        statusMenu = menu
    }

    private func makeMenuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = "",
        symbolName: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        applyMenuItemImage(item, systemSymbolName: symbolName, accessibilityDescription: title)
        return item
    }

    private func applyMenuItemImage(
        _ item: NSMenuItem,
        systemSymbolName: String,
        accessibilityDescription: String
    ) {
        item.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: accessibilityDescription)
    }

    private func updateIcon() {
        statusItem.button?.image = StatusBarIcon.make()
    }

    private func refreshHistoryWindow() {
        historyWindowController?.update(
            historyText: formattedHistoryText(),
            hasHistory: !historyEntries.isEmpty
        )
    }

    // MARK: - Status Item Interaction

    @objc private func handleStatusItemClick(_ sender: Any?) {
        showStatusMenu()
    }

    private func showStatusMenu() {
        refreshIPItem()
        updateAccessibilityStatus()
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - History

    private func appendHistoryEntry(
        text: String,
        reason: DraftHistoryEntry.Reason,
        sourceAddress: String? = nil
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let entry = DraftHistoryEntry(
            id: UUID(),
            text: text,
            createdAt: Date(),
            reason: reason,
            sourceAddress: sourceAddress
        )

        historyEntries.insert(entry, at: 0)
        if historyEntries.count > 100 {
            historyEntries = Array(historyEntries.prefix(100))
        }

        historyStore.save(historyEntries)
        refreshHistoryWindow()
    }

    private func formattedHistoryText() -> String {
        guard !historyEntries.isEmpty else { return "" }

        return historyEntries.map { entry in
            var header = "[\(entry.reason.displayTitle)] \(historyTimestampFormatter.string(from: entry.createdAt))"
            if let sourceAddress = entry.sourceAddress, !sourceAddress.isEmpty {
                header += " · \(sourceAddress)"
            }
            return "\(header)\n\(entry.text)"
        }.joined(separator: "\n\n──────────\n\n")
    }

    private var historyTimestampFormatter: DateFormatter {
        Self.sharedHistoryTimestampFormatter
    }

    // MARK: - Accessibility

    private func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    private func updateAccessibilityStatus() {
        let granted = checkAccessibilityPermission()
        if granted {
            accessibilityItem.title = "辅助功能：已授权"
            applyMenuItemImage(
                accessibilityItem,
                systemSymbolName: "checkmark.circle.fill",
                accessibilityDescription: "已授权"
            )
        } else {
            accessibilityItem.title = "辅助功能：未授权"
            applyMenuItemImage(
                accessibilityItem,
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "未授权"
            )
        }
        refreshHistoryWindow()
        refreshSettingsWindow()
    }

    @objc private func openAccessibilitySettings(_ sender: NSMenuItem) {
        let granted = checkAccessibilityPermission()
        if !granted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - About

    @objc private func showAboutPanel(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func showSettingsWindow(_ sender: Any?) {
        if settingsWindowController == nil {
            let viewController = SettingsViewController()
            viewController.onShowAbout = { [weak self] in
                self?.showAboutPanel(NSMenuItem())
            }
            viewController.onCopyNetworkInfo = { [weak self] in
                self?.copyIPSummary(NSMenuItem())
            }
            viewController.onChangePort = { [weak self] in
                self?.changePort(NSMenuItem())
            }
            viewController.onToggleLaunchAtLogin = { [weak self] isEnabled in
                self?.setLaunchAtLoginState(isEnabled)
            }
            viewController.onShowHistory = { [weak self] in
                self?.showHistoryWindow(nil)
            }
            viewController.onOpenAccessibilitySettings = { [weak self] in
                self?.openAccessibilitySettings(NSMenuItem())
            }
            settingsWindowController = SettingsWindowController(settingsViewController: viewController)
        }

        refreshSettingsWindow()
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshSettingsWindow() {
        launchAtLogin = isLaunchAtLoginConfigured()
        settingsWindowController?.update(
            ipSummary: ipSummaryLines().joined(separator: "\n"),
            port: port,
            launchAtLogin: launchAtLogin,
            accessibilityGranted: checkAccessibilityPermission()
        )
    }

    @objc private func showHistoryWindow(_ sender: Any?) {
        if historyWindowController == nil {
            historyWindowController = DraftHistoryWindowController()
        }

        historyWindowController?.update(
            historyText: formattedHistoryText(),
            hasHistory: !historyEntries.isEmpty
        )
        historyWindowController?.showWindow(nil)
        historyWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Port

    @objc private func changePort(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "修改监听端口"
        alert.informativeText = "请输入新的端口号（1–65535）"
        alert.addButton(withTitle: "更改")
        alert.addButton(withTitle: "取消")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        inputField.stringValue = String(port)
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        guard let newPort = UInt16(inputField.stringValue), newPort >= 1 else { return }
        guard newPort != port else { return }

        port = newPort
        portItem.title = "端口：\(port)"
        refreshSettingsWindow()

        if serverRunning {
            stopServer()
            startServer()
        }
    }

    // MARK: - Launch At Login

    private var launchAgentLabel: String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.vibetaking.app"
        return "\(bundleIdentifier).launch-at-login"
    }

    private var launchAgentURL: URL? {
        guard let libraryDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }

        return libraryDirectory
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    private func synchronizeLaunchAtLoginState() {
        launchAtLogin = isLaunchAtLoginConfigured()

        guard launchAtLogin else { return }

        do {
            try installLaunchAtLoginAgent()
        } catch {
            print("Failed to refresh launch agent configuration: \(error)")
        }
    }

    private func isLaunchAtLoginConfigured() -> Bool {
        guard let launchAgentURL else { return false }
        return FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    private func setLaunchAtLoginState(_ isEnabled: Bool) {
        guard launchAtLogin != isEnabled else {
            refreshSettingsWindow()
            return
        }

        do {
            if isEnabled {
                try installLaunchAtLoginAgent()
            } else {
                try removeLaunchAtLoginAgent()
            }

            launchAtLogin = isEnabled
            refreshSettingsWindow()
        } catch {
            launchAtLogin = isLaunchAtLoginConfigured()
            refreshSettingsWindow()
            showLaunchAtLoginError(error)
        }
    }

    private func installLaunchAtLoginAgent() throws {
        guard let launchAgentURL else {
            throw LaunchAtLoginError.libraryDirectoryUnavailable
        }

        let bundlePath = Bundle.main.bundleURL.path
        guard !bundlePath.isEmpty else {
            throw LaunchAtLoginError.bundlePathUnavailable
        }

        let launchAgent: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": ["/usr/bin/open", "-gj", bundlePath],
            "RunAtLoad": true
        ]

        guard PropertyListSerialization.propertyList(launchAgent, isValidFor: .xml) else {
            throw LaunchAtLoginError.invalidConfiguration
        }

        do {
            let fm = FileManager.default
            try fm.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: launchAgent, format: .xml, options: 0)
            try data.write(to: launchAgentURL, options: .atomic)
        } catch {
            throw LaunchAtLoginError.writeFailed(error)
        }
    }

    private func removeLaunchAtLoginAgent() throws {
        guard let launchAgentURL else {
            throw LaunchAtLoginError.libraryDirectoryUnavailable
        }

        guard FileManager.default.fileExists(atPath: launchAgentURL.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: launchAgentURL)
        } catch {
            throw LaunchAtLoginError.removeFailed(error)
        }
    }

    private func showLaunchAtLoginError(_ error: Error) {
        let alert = NSAlert()
        let localizedError = error as? LocalizedError

        alert.alertStyle = .warning
        alert.messageText = "无法更新开机启动"
        alert.informativeText = localizedError?.errorDescription ?? error.localizedDescription

        if let recoverySuggestion = localizedError?.recoverySuggestion, !recoverySuggestion.isEmpty {
            alert.informativeText += "\n\n\(recoverySuggestion)"
        }

        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        stopServer()
        NSApplication.shared.terminate(self)
    }

    // MARK: - Network Info

    private func localIPAddresses() -> [(label: String, address: String, rank: Int)] {
        var addresses: [(label: String, address: String, rank: Int)] = []
        var seen = Set<String>()
        let interfaceKinds = networkInterfaceKinds()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return addresses }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            guard let addrPointer = ptr.pointee.ifa_addr else { continue }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            let sa = addrPointer.pointee
            guard sa.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            guard let info = displayInfo(for: name, kinds: interfaceKinds) else { continue }

            var addr = addrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }

            let ip = String(cString: buf)
            let key = "\(name)|\(ip)"
            guard seen.insert(key).inserted else { continue }

            addresses.append((label: info.label, address: ip, rank: info.rank))
        }

        return addresses.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.label != $1.label { return $0.label < $1.label }
            return $0.address < $1.address
        }
    }

    private func networkInterfaceKinds() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var kinds: [String: String] = [:]

        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let interfaceType = SCNetworkInterfaceGetInterfaceType(interface) as String? else {
                continue
            }

            if interfaceType == kSCNetworkInterfaceTypeIEEE80211 as String {
                kinds[bsdName] = "Wi-Fi"
            } else if interfaceType == kSCNetworkInterfaceTypeEthernet as String {
                kinds[bsdName] = "Ethernet"
            }
        }

        return kinds
    }

    private func displayInfo(for bsdName: String, kinds: [String: String]) -> (label: String, rank: Int)? {
        if let kind = kinds[bsdName] {
            return kind == "Wi-Fi" ? ("Wi-Fi", 0) : ("Ethernet", 1)
        }

        if bsdName.hasPrefix("en") {
            return ("Ethernet", 1)
        }

        return nil
    }

    private func refreshIPItem() {
        ipItem.title = ipMenuTitle()
    }

    private func ipSummaryLines() -> [String] {
        localIPAddresses().map { "\($0.label): \($0.address)" }
    }

    private func ipMenuTitle(copied: Bool = false) -> String {
        let lines = ipSummaryLines()
        guard !lines.isEmpty else { return "未检测到局域网地址" }

        if copied {
            if lines.count == 1 {
                return "\(lines[0])（已复制）"
            }
            var displayLines = lines
            displayLines[displayLines.count - 1] = "\(displayLines[displayLines.count - 1])（已复制）"
            return displayLines.joined(separator: "\n")
        }

        return lines.joined(separator: "\n")
    }

    private func ipCopyValue() -> String? {
        let entries = localIPAddresses()
        guard !entries.isEmpty else { return nil }
        return entries.map { $0.address }.joined(separator: " | ")
    }

    @objc private func copyIPSummary(_ sender: NSMenuItem) {
        guard let value = ipCopyValue() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)

        ipTitleResetWorkItem?.cancel()
        ipItem.title = ipMenuTitle(copied: true)

        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshIPItem()
        }
        ipTitleResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    // MARK: - Server

    private func startServer() {
        guard !serverRunning else { return }
        let srv = HTTPServer()
        srv.onPasteRequest = { [weak self] text in
            DispatchQueue.main.async {
                self?.appendHistoryEntry(text: text, reason: .directPaste)
            }
            PasteService.copyAndPaste(
                text: text,
                preserveExistingClipboard: true
            )
        }
        srv.onSendRequest = {
            DispatchQueue.main.async {
                PasteService.send()
            }
        }

        do {
            try srv.start(port: port)
            server = srv
            serverRunning = true
            updateIcon()
            bonjourAdvertiser.start(port: port)
            print("VibeTaking listening on http://0.0.0.0:\(port)")
        } catch {
            print("Failed to start server: \(error)")
        }
    }

    private func stopServer() {
        guard serverRunning else { return }
        bonjourAdvertiser.stop()
        server?.stop()
        server = nil
        serverRunning = false
        updateIcon()
    }
}

private final class SettingsWindowController: NSWindowController {
    private let settingsViewController: SettingsViewController

    init(settingsViewController: SettingsViewController) {
        self.settingsViewController = settingsViewController

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.contentViewController = settingsViewController
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 520))
        window.contentMinSize = NSSize(width: 520, height: 460)
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        ipSummary: String,
        port: UInt16,
        launchAtLogin: Bool,
        accessibilityGranted: Bool
    ) {
        settingsViewController.update(
            ipSummary: ipSummary,
            port: port,
            launchAtLogin: launchAtLogin,
            accessibilityGranted: accessibilityGranted
        )
    }
}

private final class SettingsViewController: NSViewController {
    var onShowAbout: (() -> Void)?
    var onCopyNetworkInfo: (() -> Void)?
    var onChangePort: (() -> Void)?
    var onToggleLaunchAtLogin: ((Bool) -> Void)?
    var onShowHistory: (() -> Void)?
    var onOpenAccessibilitySettings: (() -> Void)?

    private let ipValueLabel = SettingsViewController.makeDetailLabel()
    private let portValueLabel = SettingsViewController.makeDetailLabel()
    private let launchAtLoginSwitch = NSSwitch(frame: .zero)
    private let accessibilityValueLabel = SettingsViewController.makeDetailLabel()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 520))
        preferredContentSize = NSSize(width: 520, height: 520)

        let aboutButton = Self.makeActionButton(title: "关于")
        aboutButton.target = self
        aboutButton.action = #selector(handleShowAbout)

        let titleLabel = NSTextField(labelWithString: "设置")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)

        let subtitleLabel = NSTextField(labelWithString: "管理连接与系统权限")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        let titleGroup = NSStackView(views: [titleLabel, subtitleLabel])
        titleGroup.orientation = .vertical
        titleGroup.alignment = .leading
        titleGroup.spacing = 4

        let headerRow = NSStackView(views: [titleGroup, NSView(), aboutButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = 12
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = Self.makeActionButton(title: "复制")
        copyButton.target = self
        copyButton.action = #selector(handleCopyNetworkInfo)

        let changePortButton = Self.makeActionButton(title: "修改")
        changePortButton.target = self
        changePortButton.action = #selector(handleChangePort)

        let networkCard = Self.makeCard(rows: [
            makeRow(title: "局域网地址", detail: ipValueLabel, accessory: copyButton),
            makeRow(title: "监听端口", detail: portValueLabel, accessory: changePortButton)
        ])

        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(handleLaunchAtLoginChanged)

        let historyButton = Self.makeActionButton(title: "查看")
        historyButton.target = self
        historyButton.action = #selector(handleShowHistory)

        let behaviorCard = Self.makeCard(rows: [
            makeRow(title: "开机启动", detail: Self.makeHintLabel("登录 macOS 后自动启动随心记"), accessory: launchAtLoginSwitch),
            makeRow(title: "历史记录", detail: Self.makeHintLabel("回顾已粘贴的文本"), accessory: historyButton)
        ])

        let accessibilityButton = Self.makeActionButton(title: "打开系统设置")
        accessibilityButton.target = self
        accessibilityButton.action = #selector(handleOpenAccessibilitySettings)

        let permissionsCard = Self.makeCard(rows: [
            makeRow(title: "辅助功能", detail: accessibilityValueLabel, accessory: accessibilityButton)
        ])

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 20
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        mainStack.addArrangedSubview(headerRow)

        let sections: [(String, NSView)] = [
            ("网络", networkCard),
            ("行为", behaviorCard),
            ("权限", permissionsCard)
        ]

        for (title, card) in sections {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .secondaryLabelColor

            let section = NSStackView(views: [label, card])
            section.orientation = .vertical
            section.alignment = .leading
            section.spacing = 8
            section.translatesAutoresizingMaskIntoConstraints = false

            mainStack.addArrangedSubview(section)

            NSLayoutConstraint.activate([
                card.widthAnchor.constraint(equalTo: section.widthAnchor),
                section.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
            ])
        }

        NSLayoutConstraint.activate([
            headerRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        ])

        view.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            mainStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24)
        ])
    }

    func update(
        ipSummary: String,
        port: UInt16,
        launchAtLogin: Bool,
        accessibilityGranted: Bool
    ) {
        ipValueLabel.stringValue = ipSummary.isEmpty ? "未检测到局域网地址" : ipSummary
        portValueLabel.stringValue = "\(port)"
        launchAtLoginSwitch.state = launchAtLogin ? .on : .off

        accessibilityValueLabel.stringValue = accessibilityGranted ? "已授权" : "未授权"
        accessibilityValueLabel.textColor = accessibilityGranted ? .systemGreen : .systemOrange
    }

    @objc private func handleShowAbout() { onShowAbout?() }
    @objc private func handleCopyNetworkInfo() { onCopyNetworkInfo?() }
    @objc private func handleChangePort() { onChangePort?() }
    @objc private func handleLaunchAtLoginChanged() { onToggleLaunchAtLogin?(launchAtLoginSwitch.state == .on) }
    @objc private func handleShowHistory() { onShowHistory?() }
    @objc private func handleOpenAccessibilitySettings() { onOpenAccessibilitySettings?() }

    // MARK: - Row & Card Builders

    private func makeRow(title: String, detail: NSView, accessory: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let leftStack = NSStackView(views: [titleLabel, detail])
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        leftStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let rowContent = NSStackView(views: [leftStack, NSView(), accessory])
        rowContent.orientation = .horizontal
        rowContent.alignment = .centerY
        rowContent.spacing = 12
        rowContent.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(rowContent)

        NSLayoutConstraint.activate([
            rowContent.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            rowContent.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            rowContent.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            rowContent.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])

        return container
    }

    private static func makeCard(rows: [NSView]) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 0.5
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        box.titlePosition = .noTitle

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(separator)
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
        }

        if let contentView = box.contentView {
            contentView.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                stack.topAnchor.constraint(equalTo: contentView.topAnchor),
                stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }

        for subview in stack.arrangedSubviews {
            subview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return box
    }

    private static func makeActionButton(title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private static func makeDetailLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func makeHintLabel(_ string: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabelColor
        return label
    }
}

private final class DraftHistoryWindowController: NSWindowController {
    private let historyViewController = DraftHistoryViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "历史记录"
        window.contentViewController = historyViewController
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(historyText: String, hasHistory: Bool) {
        historyViewController.update(historyText: historyText, hasHistory: hasHistory)
    }
}

private final class DraftHistoryViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "历史记录")
    private let hintLabel = NSTextField(labelWithString: "保留已粘贴或被替换的草稿，方便回溯。")
    private let textView = NSTextView(frame: .zero)
    private let scrollView = NSScrollView()
    private let placeholderLabel = NSTextField(labelWithString: "暂无记录")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))

        titleLabel.font = .preferredFont(forTextStyle: .title3)
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 2

        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.textColor = .tertiaryLabelColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = NSColor.separatorColor.cgColor

        let stack = NSStackView(views: [titleLabel, hintLabel, scrollView])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(14, after: hintLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        view.addSubview(placeholderLabel)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            placeholderLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 14),
            placeholderLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 12),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -14)
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        let size = scrollView.contentSize
        textView.frame = NSRect(origin: .zero, size: size)
        textView.minSize = NSSize(width: size.width, height: size.height)
        textView.maxSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
    }

    func update(historyText: String, hasHistory: Bool) {
        if textView.string != historyText {
            textView.string = historyText
        }
        placeholderLabel.isHidden = hasHistory
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshIPItem()
        updateAccessibilityStatus()
    }
}
