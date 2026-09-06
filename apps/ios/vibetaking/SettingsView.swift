import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
class SettingsManager {
    static let shared = SettingsManager()
    static let defaultAIBaseURLString = "https://api.infingrow.asia/v1"
    static let defaultAIModelID = "gpt-5.5"
    private static let legacyAIBaseURLStrings = [
        "http://infingrow.asia:8080",
        "http://infingrow.asia:8080/v1"
    ]
    
    private let aiApiTokenKey = "aiApiToken"
    private let aiBaseURLStringKey = "aiBaseURLString"
    private let aiModelIDKey = "aiModelID"
    
    var aiApiToken: String? {
        didSet {
            if let token = aiApiToken?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                KeychainHelper.saveString(token, forKey: aiApiTokenKey)
            } else {
                KeychainHelper.delete(forKey: aiApiTokenKey)
            }
        }
    }

    var aiBaseURLString: String {
        didSet {
            guard !isReloading else { return }
            persistBaseURLString()
        }
    }

    var aiModelID: String {
        didSet {
            guard !isReloading else { return }
            persistModelID()
        }
    }

    private var isReloading = false
    
    static func normalizedAIBaseURLString(_ rawValue: String) -> String {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseValue = trimmedValue.isEmpty ? Self.defaultAIBaseURLString : trimmedValue
        let trimmedSlashes = baseValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmedSlashes.hasSuffix("/v1") ? trimmedSlashes : "\(trimmedSlashes)/v1"
    }

    private static func isLegacyAIBaseURLString(_ rawValue: String) -> Bool {
        let normalizedValue = normalizedAIBaseURLString(rawValue)
        return legacyAIBaseURLStrings
            .map(normalizedAIBaseURLString)
            .contains(normalizedValue)
    }

    private init() {
        let snapshot = Self.loadSnapshot()
        self.aiBaseURLString = snapshot.baseURLString
        self.aiModelID = snapshot.modelID
        persistBaseURLString()
        persistModelID()

        if let legacyToken = AppDefaults.current.string(forKey: aiApiTokenKey) {
            KeychainHelper.saveString(legacyToken, forKey: aiApiTokenKey)
            AppDefaults.current.removeObject(forKey: aiApiTokenKey)
        }
        self.aiApiToken = KeychainHelper.loadString(forKey: aiApiTokenKey)
    }

    func reload() {
        isReloading = true
        let snapshot = Self.loadSnapshot()
        aiBaseURLString = snapshot.baseURLString
        aiModelID = snapshot.modelID
        isReloading = false
        persistBaseURLString()
        persistModelID()

        if let legacyToken = AppDefaults.current.string(forKey: aiApiTokenKey) {
            KeychainHelper.saveString(legacyToken, forKey: aiApiTokenKey)
            AppDefaults.current.removeObject(forKey: aiApiTokenKey)
        }
        aiApiToken = KeychainHelper.loadString(forKey: aiApiTokenKey)
    }

    private func persistBaseURLString() {
        let trimmedBaseURL = aiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBaseURL.isEmpty {
            AppDefaults.current.removeObject(forKey: aiBaseURLStringKey)
        } else {
            AppDefaults.current.set(trimmedBaseURL, forKey: aiBaseURLStringKey)
        }
    }

    private func persistModelID() {
        let trimmedModelID = aiModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedModelID.isEmpty {
            AppDefaults.current.removeObject(forKey: aiModelIDKey)
        } else {
            AppDefaults.current.set(trimmedModelID, forKey: aiModelIDKey)
        }
    }

    private struct Snapshot {
        let baseURLString: String
        let modelID: String
    }

    private static func loadSnapshot() -> Snapshot {
        let defaults = AppDefaults.current
        let storedBaseURLString = defaults
            .string(forKey: "aiBaseURLString")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseURLString: String
        if let storedBaseURLString,
           !storedBaseURLString.isEmpty,
           !isLegacyAIBaseURLString(storedBaseURLString) {
            resolvedBaseURLString = storedBaseURLString
        } else {
            resolvedBaseURLString = defaultAIBaseURLString
        }

        let storedModelID = defaults
            .string(forKey: "aiModelID")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModelID = storedModelID?.isEmpty == false ? storedModelID! : defaultAIModelID
        return Snapshot(baseURLString: resolvedBaseURLString, modelID: resolvedModelID)
    }

    func exportConfiguration() -> AppAIConfiguration {
        AppAIConfiguration(
            apiToken: aiApiToken,
            baseURLString: aiBaseURLString,
            modelID: aiModelID
        )
    }

    func applyConfiguration(_ configuration: AppAIConfiguration) {
        let importedBaseURLString = configuration.baseURLString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        aiBaseURLString = importedBaseURLString.isEmpty
            ? Self.defaultAIBaseURLString
            : importedBaseURLString

        let importedModelID = configuration.modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        aiModelID = importedModelID.isEmpty
            ? Self.defaultAIModelID
            : importedModelID

        let importedToken = configuration.apiToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        aiApiToken = importedToken?.isEmpty == false ? importedToken : nil
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pendingConfigurationURLs: [URL] = []
    @State private var confirmConfigurationImport = false

    @State private var settingsManager = SettingsManager.shared
    @State private var demoMode = DemoModeManager.shared
    @State private var versionTapCount = 0
    @State private var showDemoModeSection = false
    @State private var memoryStore = AgentMemoryStore.shared
    @State private var skillStore = SkillStore.shared
    @State private var models: [AIModel] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
    @State private var modelLoadTask: Task<Void, Never>?
    @State private var modelRequestID = UUID()
    @State private var isExportingConfiguration = false
    @State private var isImportingConfiguration = false
    @State private var showConfigurationImportPicker = false
    @State private var exportedConfigurationURL: URL?
    @State private var configurationTransferAlert: ConfigurationTransferAlert?

    private static let importableConfigurationContentTypes: [UTType] = [
        .json,
        UTType(filenameExtension: "json") ?? .json
    ]

    private struct ConfigurationTransferAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var hasToken: Bool {
        guard let token = settingsManager.aiApiToken else { return false }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { settingsManager.aiModelID },
            set: { settingsManager.aiModelID = $0 }
        )
    }

    private var normalizedBaseURLString: String {
        SettingsManager.normalizedAIBaseURLString(settingsManager.aiBaseURLString)
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AI 密钥（API Key）").font(.subheadline).foregroundStyle(.secondary)
                        SecureField("粘贴服务商提供的密钥", text: Binding(
                            get: { settingsManager.aiApiToken ?? "" },
                            set: { settingsManager.aiApiToken = $0.isEmpty ? nil : $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.done)
                        .privacySensitive()
                        .accessibilityLabel("AI 密钥，API Key")
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("AI 服务地址").font(.subheadline).foregroundStyle(.secondary)
                        TextField("例如：https://api.example.com/v1", text: Binding(
                            get: { settingsManager.aiBaseURLString },
                            set: { settingsManager.aiBaseURLString = $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .accessibilityLabel("AI 服务地址")
                    }
                    .padding(.vertical, 4)

                    if normalizedBaseURLString != SettingsManager.defaultAIBaseURLString {
                        Button {
                            settingsManager.aiBaseURLString = SettingsManager.defaultAIBaseURLString
                            models = []
                            modelLoadError = nil
                        } label: {
                            Label("恢复默认地址", systemImage: "arrow.uturn.backward")
                        }
                    }
                } header: {
                    Text("连接 AI 服务")
                } footer: {
                    Text("密钥存入本机钥匙串，使用 AI 时相关文本会发送到你设置的服务。普通记录无需配置 AI。")
                }

                Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("模型 ID").font(.subheadline).foregroundStyle(.secondary)
                            TextField("例如：gpt-5.5", text: selectedModelBinding)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .accessibilityLabel("模型 ID")
                        }
                        .padding(.vertical, 4)
                    if !models.isEmpty {
                        Picker("可用模型", selection: selectedModelBinding) {
                            if !models.contains(where: { $0.id == settingsManager.aiModelID }) {
                                Text("\(settingsManager.aiModelID)（当前）")
                                    .tag(settingsManager.aiModelID)
                            }
                            ForEach(models) { model in
                                Text(modelLabel(for: model))
                                    .tag(model.id)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }

                    if isLoadingModels {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在获取可用模型…")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        modelLoadTask?.cancel()
                        modelLoadTask = Task {
                            await loadModels()
                        }
                    } label: {
                        Label(models.isEmpty ? "获取可用模型" : "刷新模型列表", systemImage: "arrow.clockwise")
                    }
                    .disabled(!hasToken || isLoadingModels)

                    if let modelLoadError {
                        Label(modelLoadError, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.primary)
                    }
                } header: {
                    Text("模型")
                } footer: {
                    Text(hasToken ? "填写服务商提供的模型 ID，或从可用模型中选择。刷新列表不会更改当前模型。" : "填写 AI 密钥后可获取模型列表，也可以直接输入模型 ID。")
                }

                Section {
                    Toggle("记住对话中的偏好", isOn: Bindable(memoryStore).isEnabled)

                    NavigationLink {
                        AgentSkillsSettingsView()
                    } label: {
                        HStack {
                            Text("助手技能")
                            Spacer()
                            Text("\(skillStore.skills.count)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink("设备权限") {
                        OffloadPermissionSettingsView()
                    }
                } header: {
                    Text("AI 助手")
                } footer: {
                    Text("开启后，助手会在后续对话中使用记下的偏好。技能可保存可复用的任务指引。iCloud 可用时随记录同步。")
                }

                Section {
                    Button {
                        exportConfiguration()
                    } label: {
                        Label("导出配置", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isExportingConfiguration || isImportingConfiguration)

                    Button {
                        showConfigurationImportPicker = true
                    } label: {
                        Label("导入配置", systemImage: "square.and.arrow.down")
                    }
                    .disabled(isExportingConfiguration || isImportingConfiguration)

                    if isExportingConfiguration || isImportingConfiguration {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(isExportingConfiguration ? "正在导出配置" : "正在导入配置")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("配置迁移")
                } footer: {
                    Text("导出包含 AI 设置、全部工作流和可直接读取的密钥，仅存放或传给你信任的设备。导入会替换这些设置，记录不受影响。")
                }

                if shouldShowHiddenToolsSection {
                    Section {
                        Toggle("演示模式", isOn: Binding(
                            get: { demoMode.isEnabled },
                            set: { setDemoModeEnabled($0) }
                        ))
                    } header: {
                        Text("演示模式")
                    } footer: {
                        Text("使用独立的示例数据，不影响你的真实记录。")
                    }

                    Section {
                        Button(action: showFlexExplorer) {
                            Label("打开 FLEX", systemImage: "hammer")
                        }
                        .disabled(!InAppDebugger.canShowExplorer)
                    } header: {
                        Text("调试")
                    } footer: {
                        Text(InAppDebugger.canShowExplorer
                             ? "打开 FLEX 悬浮工具条，查看界面层级、网络请求和运行时对象。"
                             : "FLEX 仅在 Debug 构建中可用。")
                    }
                }

                Section {
                    Button(action: handleVersionTap) {
                        LabeledContent("版本", value: appVersionLabel)
                            .foregroundStyle(.primary)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .task { skillStore.loadIfNeeded() }
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭设置") { dismiss() }.fontWeight(.semibold)
                }
            }
            .confirmationDialog("替换当前配置？", isPresented: $confirmConfigurationImport, titleVisibility: .visible) {
                Button("替换配置", role: .destructive) {
                    let urls = pendingConfigurationURLs
                    pendingConfigurationURLs = []
                    importConfiguration(from: urls)
                }
                Button("保留当前配置", role: .cancel) { pendingConfigurationURLs = [] }
            } message: {
                Text("当前 AI 密钥、服务地址、模型和全部工作流将被替换。此操作无法撤销，记录不受影响。")
            }
            .sheet(isPresented: Binding(
                get: { exportedConfigurationURL != nil },
                set: { if !$0 { exportedConfigurationURL = nil } }
            )) {
                if let url = exportedConfigurationURL {
                    ShareSheet(items: [url])
                }
            }
            .fileImporter(
                isPresented: $showConfigurationImportPicker,
                allowedContentTypes: Self.importableConfigurationContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handleConfigurationImportSelection(result)
            }
            .alert(item: $configurationTransferAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("返回设置"))
                )
            }
            .onChange(of: settingsManager.aiApiToken ?? "") { _, _ in
                invalidateModelList()
            }
            .onChange(of: settingsManager.aiBaseURLString) { _, _ in
                invalidateModelList()
            }
        }
    }

    private var shouldShowHiddenToolsSection: Bool {
        demoMode.isEnabled || showDemoModeSection
    }

    private var appVersionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private func handleVersionTap() {
        versionTapCount += 1
        if versionTapCount >= 5 {
            showDemoModeSection = true
        }
    }

    private func setDemoModeEnabled(_ enabled: Bool) {
        demoMode.setEnabled(enabled)
    }

    private func showFlexExplorer() {
        InAppDebugger.showExplorer()
    }

    private func exportConfiguration() {
        isExportingConfiguration = true

        Task {
            do {
                let url = try AppConfigurationManager.exportConfiguration()
                isExportingConfiguration = false
                exportedConfigurationURL = url
            } catch {
                isExportingConfiguration = false
                configurationTransferAlert = ConfigurationTransferAlert(
                    title: "配置未能导出",
                    message: error.userFacingDescription
                )
            }
        }
    }

    private func handleConfigurationImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            pendingConfigurationURLs = urls
            confirmConfigurationImport = true
        case .failure(let error):
            configurationTransferAlert = ConfigurationTransferAlert(
                title: "配置未能导入",
                message: error.userFacingDescription
            )
        }
    }

    private func importConfiguration(from urls: [URL]) {
        isImportingConfiguration = true

        Task {
            do {
                try AppConfigurationManager.importConfiguration(from: urls)
                models = []
                modelLoadError = nil
                isImportingConfiguration = false
                configurationTransferAlert = ConfigurationTransferAlert(
                    title: "配置已导入",
                    message: "AI 设置和全部工作流已替换，现在即可使用。"
                )
            } catch {
                isImportingConfiguration = false
                configurationTransferAlert = ConfigurationTransferAlert(
                    title: "配置未能导入",
                    message: error.userFacingDescription
                )
            }
        }
    }

    private func modelLabel(for model: AIModel) -> String {
        model.title == model.id ? model.id : "\(model.title) (\(model.id))"
    }

    private func loadModels() async {
        guard hasToken else {
            models = []
            modelLoadError = "填写上方的 AI 密钥后，再获取模型列表。"
            return
        }

        let requestID = UUID()
        modelRequestID = requestID
        isLoadingModels = true
        modelLoadError = nil

        defer {
            if modelRequestID == requestID { isLoadingModels = false }
        }

        do {
            let fetchedModels = try await AIService.shared.fetchModels()
            guard modelRequestID == requestID, !Task.isCancelled else { return }
            let textModels = fetchedModels
                .filter { $0.supportsTextGeneration }
                .sorted { $0.id.localizedCompare($1.id) == .orderedAscending }

            guard !textModels.isEmpty else {
                models = []
                modelLoadError = "服务没有返回可用的文本模型。可直接填写服务商提供的模型 ID，或检查 AI 服务地址。"
                return
            }

            models = textModels

        } catch is CancellationError {
            return
        } catch {
            guard modelRequestID == requestID, !Task.isCancelled else { return }
            models = []
            modelLoadError = error.userFacingDescription
        }
    }

    private func invalidateModelList() {
        modelLoadTask?.cancel()
        modelLoadTask = nil
        modelRequestID = UUID()
        isLoadingModels = false
        models = []
        modelLoadError = nil
    }
}

struct AgentSkillsSettingsView: View {
    @State private var store = SkillStore.shared

    var body: some View {
        List {
            if store.skills.isEmpty {
                ContentUnavailableView {
                    Label("还没有助手技能", systemImage: "sparkles")
                } description: {
                    Text("技能让助手复用任务指引。在记录目录中按“_skills/技能名/SKILL.md”存放文件，再刷新技能列表。")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.skills) { skill in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(
                            get: { skill.isEnabled },
                            set: { store.setEnabled($0, for: skill.id) }
                        )) {
                            Text(skill.name)
                                .font(.body)
                        }
                        if !skill.description.isEmpty {
                            Text(skill.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if skill.useCount > 0 {
                            Text("已使用 \(Int(skill.useCount)) 次")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("助手技能")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新技能列表", systemImage: "arrow.clockwise") {
                    store.reload()
                }
            }
        }
        .onAppear {
            store.loadIfNeeded()
        }
    }
}

#Preview {
    SettingsView()
}
