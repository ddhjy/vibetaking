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
            let trimmedBaseURL = aiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBaseURL.isEmpty {
                UserDefaults.standard.removeObject(forKey: aiBaseURLStringKey)
            } else {
                UserDefaults.standard.set(trimmedBaseURL, forKey: aiBaseURLStringKey)
            }
        }
    }

    var aiModelID: String {
        didSet {
            let trimmedModelID = aiModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedModelID.isEmpty {
                UserDefaults.standard.removeObject(forKey: aiModelIDKey)
            } else {
                UserDefaults.standard.set(trimmedModelID, forKey: aiModelIDKey)
            }
        }
    }
    
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
        let storedBaseURLString = UserDefaults.standard
            .string(forKey: aiBaseURLStringKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseURLString: String
        if let storedBaseURLString,
           !storedBaseURLString.isEmpty,
           !Self.isLegacyAIBaseURLString(storedBaseURLString) {
            resolvedBaseURLString = storedBaseURLString
        } else {
            resolvedBaseURLString = Self.defaultAIBaseURLString
        }
        self.aiBaseURLString = resolvedBaseURLString
        UserDefaults.standard.set(resolvedBaseURLString, forKey: aiBaseURLStringKey)

        let storedModelID = UserDefaults.standard
            .string(forKey: aiModelIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.aiModelID = storedModelID?.isEmpty == false ? storedModelID! : Self.defaultAIModelID

        if let legacyToken = UserDefaults.standard.string(forKey: aiApiTokenKey) {
            KeychainHelper.saveString(legacyToken, forKey: aiApiTokenKey)
            UserDefaults.standard.removeObject(forKey: aiApiTokenKey)
        }
        self.aiApiToken = KeychainHelper.loadString(forKey: aiApiTokenKey)
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
    @State private var settingsManager = SettingsManager.shared
    @State private var models: [AIModel] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
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
                    SecureField("API Key", text: Binding(
                        get: { settingsManager.aiApiToken ?? "" },
                        set: { settingsManager.aiApiToken = $0.isEmpty ? nil : $0 }
                    ))

                    TextField("API 前缀", text: Binding(
                        get: { settingsManager.aiBaseURLString },
                        set: { settingsManager.aiBaseURLString = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                    if normalizedBaseURLString != SettingsManager.defaultAIBaseURLString {
                        Button {
                            settingsManager.aiBaseURLString = SettingsManager.defaultAIBaseURLString
                            models = []
                            modelLoadError = nil
                        } label: {
                            Label("恢复默认网关", systemImage: "arrow.uturn.backward")
                        }
                    }
                } header: {
                    Text("AI 配置")
                } footer: {
                    Text("使用 Sub2API 网关，密钥会保存在钥匙串中。默认地址为 https://api.infingrow.asia/v1。")
                }

                Section {
                    if models.isEmpty {
                        HStack {
                            Text("当前模型")
                            Spacer()
                            Text(settingsManager.aiModelID)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("模型", selection: selectedModelBinding) {
                            ForEach(models) { model in
                                Text(modelLabel(for: model))
                                    .tag(model.id)
                            }
                        }
                    }

                    if isLoadingModels {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在请求模型列表")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task {
                            await loadModels()
                        }
                    } label: {
                        Label(models.isEmpty ? "请求模型列表" : "刷新模型列表", systemImage: "arrow.clockwise")
                    }
                    .disabled(!hasToken || isLoadingModels)

                    if let modelLoadError {
                        Text(modelLoadError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("模型")
                } footer: {
                    Text("模型列表来自 /v1/models，并会过滤掉图片模型。")
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
                    Text("导出为 JSON 文件（包含 AI 密钥）；导入后会覆盖当前 AI 与 Workflow 配置。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
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
                    dismissButton: .default(Text("好"))
                )
            }
            .task {
                await loadModelsIfPossible()
            }
            .onChange(of: settingsManager.aiApiToken ?? "") { _, _ in
                models = []
                modelLoadError = nil
            }
            .onChange(of: settingsManager.aiBaseURLString) { _, _ in
                models = []
                modelLoadError = nil
            }
        }
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
                    title: "导出失败",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func handleConfigurationImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            importConfiguration(from: urls)
        case .failure(let error):
            configurationTransferAlert = ConfigurationTransferAlert(
                title: "导入失败",
                message: error.localizedDescription
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
                    title: "导入完成",
                    message: "已覆盖当前 AI 与 Workflow 配置"
                )
            } catch {
                isImportingConfiguration = false
                configurationTransferAlert = ConfigurationTransferAlert(
                    title: "导入失败",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func modelLabel(for model: AIModel) -> String {
        model.title == model.id ? model.id : "\(model.title) (\(model.id))"
    }

    private func loadModelsIfPossible() async {
        guard hasToken else { return }
        await loadModels()
    }

    private func loadModels() async {
        guard hasToken else {
            models = []
            modelLoadError = "请先填写 AI 密钥"
            return
        }

        isLoadingModels = true
        modelLoadError = nil

        defer {
            isLoadingModels = false
        }

        do {
            let fetchedModels = try await AIService.shared.fetchModels()
            let textModels = fetchedModels
                .filter { $0.supportsTextGeneration }
                .sorted { $0.id.localizedCompare($1.id) == .orderedAscending }

            guard !textModels.isEmpty else {
                models = []
                modelLoadError = "模型列表为空"
                return
            }

            models = textModels

            if !textModels.contains(where: { $0.id == settingsManager.aiModelID }),
               let firstModel = textModels.first {
                settingsManager.aiModelID = firstModel.id
            }
        } catch is CancellationError {
            return
        } catch {
            models = []
            modelLoadError = error.localizedDescription
        }
    }
}

#Preview {
    SettingsView()
}
