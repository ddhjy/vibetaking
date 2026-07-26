import Foundation

struct AppConfigurationPackage: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String?
    let ai: AppAIConfiguration
    let workflows: AppWorkflowConfiguration
}

struct AppAIConfiguration: Codable, Equatable {
    var apiToken: String?
    var baseURLString: String
    var modelID: String
}

struct AppWorkflowConfiguration: Codable, Equatable {
    var selectedWorkflowId: UUID?
    var items: [Workflow]
}

enum AppConfigurationImportError: LocalizedError {
    case noFileSelected
    case fileTooLarge
    case invalidFile
    case unsupportedVersion(Int)
    case emptyWorkflows

    var errorDescription: String? {
        switch self {
        case .noFileSelected:
            return "没有选择配置文件"
        case .fileTooLarge:
            return "配置文件太大，已停止导入"
        case .invalidFile:
            return "配置文件格式不正确"
        case .unsupportedVersion(let version):
            return "暂不支持版本 \(version) 的配置文件"
        case .emptyWorkflows:
            return "配置文件中没有可导入的 Workflow"
        }
    }
}

@MainActor
enum AppConfigurationManager {
    private static let maxImportFileSize = 5 * 1024 * 1024

    static func exportConfiguration() throws -> URL {
        let package = AppConfigurationPackage(
            schemaVersion: AppConfigurationPackage.currentSchemaVersion,
            exportedAt: Date.now,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            ai: SettingsManager.shared.exportConfiguration(),
            workflows: WorkflowManager.shared.exportConfiguration()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let data = try encoder.encode(package)
        let fileName = "vibetaking-config_\(fileNameTimestamp()).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func importConfiguration(from urls: [URL]) throws {
        guard let url = urls.first else {
            throw AppConfigurationImportError.noFileSelected
        }

        try importConfiguration(from: url)
    }

    static func importConfiguration(from url: URL) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > maxImportFileSize {
            throw AppConfigurationImportError.fileTooLarge
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let package: AppConfigurationPackage
        do {
            package = try decoder.decode(AppConfigurationPackage.self, from: data)
        } catch {
            throw AppConfigurationImportError.invalidFile
        }

        guard package.schemaVersion == AppConfigurationPackage.currentSchemaVersion else {
            throw AppConfigurationImportError.unsupportedVersion(package.schemaVersion)
        }
        guard !package.workflows.items.isEmpty else {
            throw AppConfigurationImportError.emptyWorkflows
        }

        try apply(package)
    }

    private static func apply(_ package: AppConfigurationPackage) throws {
        SettingsManager.shared.applyConfiguration(package.ai)
        try WorkflowManager.shared.applyConfiguration(package.workflows)
    }

    private static func fileNameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: Date.now)
    }
}
