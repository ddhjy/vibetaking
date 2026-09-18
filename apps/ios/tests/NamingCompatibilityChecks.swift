import Foundation

// Only isolate dependencies of the production configuration models.
// These doubles do not exercise Workflow serialization, Keychain, or app state.
struct Workflow: Codable, Equatable {}

@MainActor final class AISettingsStore {
    static let shared = AISettingsStore()

    func exportConfiguration() -> AppAIConfiguration {
        AppAIConfiguration(apiKey: nil, baseURLString: "https://example.invalid/v1", modelID: "test-model")
    }

    func applyConfiguration(_ configuration: AppAIConfiguration) {}
}

@MainActor final class WorkflowManager {
    static let shared = WorkflowManager()

    func exportConfiguration() -> AppWorkflowConfiguration {
        AppWorkflowConfiguration(selectedWorkflowID: nil, items: [])
    }

    func applyConfiguration(_ configuration: AppWorkflowConfiguration) throws {}
}

private struct LegacyAIConfiguration: Decodable {
    let apiToken: String?
    let baseURLString: String
    let modelID: String
}

private struct LegacyWorkflowConfiguration: Decodable {
    let selectedWorkflowId: UUID?
    let items: [Workflow]
}

private struct LegacyConfigurationPackage: Decodable {
    let schemaVersion: Int
    let ai: LegacyAIConfiguration
    let workflows: LegacyWorkflowConfiguration
}

@main struct NamingCompatibilityChecks {
    @MainActor static func main() throws {
        let selectedID = UUID(uuidString: "C12BD424-70DC-40DD-B592-4BE8FE4AA20F")!
        let oldJSON = Data("""
        {
          "schemaVersion": 1,
          "exportedAt": "2026-09-17T00:00:00Z",
          "appVersion": "1.0",
          "ai": {
            "apiToken": "fixture-only-key",
            "baseURLString": "https://example.invalid/v1",
            "modelID": "test-model"
          },
          "workflows": {
            "selectedWorkflowId": "C12BD424-70DC-40DD-B592-4BE8FE4AA20F",
            "items": []
          }
        }
        """.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(AppConfigurationPackage.self, from: oldJSON)
        precondition(package.schemaVersion == AppConfigurationPackage.currentSchemaVersion)
        precondition(package.ai.apiKey == "fixture-only-key")
        precondition(package.workflows.selectedWorkflowID == selectedID)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(package)
        guard let root = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let ai = root["ai"] as? [String: Any],
              let workflows = root["workflows"] as? [String: Any] else {
            fatalError("Unexpected configuration JSON structure")
        }
        precondition(ai["apiToken"] as? String == "fixture-only-key")
        precondition(ai["apiKey"] == nil)
        precondition(workflows["selectedWorkflowId"] as? String == selectedID.uuidString)
        precondition(workflows["selectedWorkflowID"] == nil)

        // Verify that the previous reader still understands the new output.
        let legacy = try decoder.decode(LegacyConfigurationPackage.self, from: encoded)
        precondition(legacy.schemaVersion == 1)
        precondition(legacy.ai.apiToken == "fixture-only-key")
        precondition(legacy.workflows.selectedWorkflowId == selectedID)

        // Optional fields could be absent in existing files.
        let noKey = try decoder.decode(AppAIConfiguration.self, from: Data("""
        {"baseURLString":"https://example.invalid/v1","modelID":"test-model"}
        """.utf8))
        let noSelection = try decoder.decode(AppWorkflowConfiguration.self, from: Data("""
        {"items":[]}
        """.utf8))
        precondition(noKey.apiKey == nil)
        precondition(noSelection.selectedWorkflowID == nil)

        print("PASS: legacy decode, legacy-key encoding, old-reader compatibility, absent optional fields")
    }
}
