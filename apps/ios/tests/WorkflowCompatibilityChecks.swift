import Foundation

// Compiles the production Workflow.swift on its own. Covers what is stored in
// UserDefaults ("workflows_v2") and what travels inside exported configuration files.

/// Mirrors the reader shipped before `kind`, `isActive` and `syncConfig` were removed,
/// to prove that older app versions still understand what this version writes.
private struct PreviousReleaseWorkflow: Decodable {
    enum Kind: String, Decodable { case manual, autoPasteSync }
    struct SyncConfig: Decodable {
        var host = ""
        var port = 7788
    }
    struct Node: Decodable {
        let id: UUID
        let type: String
        let isEnabled: Bool
    }

    let id: UUID
    let name: String
    let icon: String
    let kind: Kind
    let isOpen: Bool
    let isActive: Bool
    let nodes: [Node]

    enum CodingKeys: String, CodingKey { case id, name, icon, kind, isOpen, isActive, syncConfig, nodes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "arrow.triangle.branch"
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .manual
        isOpen = try container.decodeIfPresent(Bool.self, forKey: .isOpen) ?? false
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        _ = try container.decodeIfPresent(SyncConfig.self, forKey: .syncConfig)
        nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
    }
}

@main
struct WorkflowCompatibilityChecks {
    @MainActor static func main() throws {
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            precondition(condition(), name)
            print("PASS: \(name)")
        }

        // What the previous release stored: every workflow carries kind / isActive / syncConfig,
        // and an Auto Paste workflow may still be present.
        let storedByPreviousRelease = Data("""
        [
          {
            "id": "C12BD424-70DC-40DD-B592-4BE8FE4AA20F",
            "name": "润色并保存",
            "icon": "sparkles",
            "kind": "manual",
            "isOpen": true,
            "isActive": false,
            "syncConfig": { "host": "", "port": 7788 },
            "nodes": [
              { "id": "0A5F3C0E-3B7D-4E57-9B59-0C6A6B0A8E11", "type": "ai_process", "isEnabled": true,
                "config": { "aiPrompt": "整理成三条要点", "httpHost": "localhost", "httpPort": 9999 } },
              { "id": "5C1E51B4-6D0B-4A0C-8C42-2C8A51B0F4D2", "type": "agent", "isEnabled": false,
                "config": { "agentPrompt": "查找相关记录" } },
              { "id": "7E0B7F0D-51F4-46B2-8B0B-6F6E4E1B9A33", "type": "copy", "isEnabled": true, "config": {} },
              { "id": "9B9C2B57-2C2A-4C40-9A64-3B0C8D6D2F44", "type": "http_post", "isEnabled": true,
                "config": { "httpHost": "192.168.1.10", "httpPort": 7788, "httpServiceName": "书房的 Mac" } },
              { "id": "B3D5B7A1-0F0E-4D8E-8F65-5A2B7C9D1E55", "type": "save", "isEnabled": true, "config": {} }
            ]
          },
          {
            "id": "2F9C6D1A-8E3B-4B7A-A1C5-7D4E9F0B2C66",
            "name": "实时同步",
            "icon": "arrow.triangle.2.circlepath",
            "kind": "autoPasteSync",
            "isOpen": true,
            "isActive": true,
            "syncConfig": { "host": "192.168.1.10", "port": 7788, "serviceName": "书房的 Mac" },
            "nodes": []
          }
        ]
        """.utf8)

        let decoded = try JSONDecoder().decode([Workflow].self, from: storedByPreviousRelease)
        check("an Auto Paste workflow in stored data does not fail the whole array", decoded.count == 2)
        check("manual workflows are kept", decoded[0].isUnsupportedKind == false)
        check("the removed Auto Paste kind is flagged so the loader can drop it", decoded[1].isUnsupportedKind)

        let manual = decoded[0]
        check("name, icon and open state survive", manual.name == "润色并保存" && manual.icon == "sparkles" && manual.isOpen)
        check("step types keep their stored identifiers",
              manual.nodes.map(\.type) == [.aiProcess, .agentProcess, .copyToClipboard, .httpPost, .save])
        check("step configuration survives",
              manual.nodes[0].config.aiPrompt == "整理成三条要点"
              && manual.nodes[1].config.agentPrompt == "查找相关记录"
              && manual.nodes[1].isEnabled == false
              && manual.nodes[3].config.httpHost == "192.168.1.10"
              && manual.nodes[3].config.httpPort == 7788
              && manual.nodes[3].config.httpServiceName == "书房的 Mac")
        check("an explicitly stored port is never rewritten", manual.nodes[0].config.httpPort == 9999)

        // The earliest format only had id and name.
        let earliest = try JSONDecoder().decode([Workflow].self, from: Data("""
        [{ "id": "C12BD424-70DC-40DD-B592-4BE8FE4AA20F", "name": "默认工作流" }]
        """.utf8))
        check("absent optional fields fall back to defaults",
              earliest[0].icon == "arrow.triangle.branch" && earliest[0].isOpen == false
              && earliest[0].nodes.isEmpty && earliest[0].isUnsupportedKind == false)

        // What this version writes.
        let encoded = try JSONEncoder().encode([manual])
        guard let objects = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]],
              let written = objects.first else {
            fatalError("Unexpected workflow JSON structure")
        }
        check("removed fields are no longer written",
              Set(written.keys) == ["id", "name", "icon", "isOpen", "nodes"])

        let reread = try JSONDecoder().decode([Workflow].self, from: encoded)
        check("round trip is lossless", reread == [manual])

        let previousRelease = try JSONDecoder().decode([PreviousReleaseWorkflow].self, from: encoded)
        check("the previous release still reads what this version writes",
              previousRelease.count == 1
              && previousRelease[0].kind == .manual
              && previousRelease[0].isOpen
              && previousRelease[0].isActive == false
              && previousRelease[0].nodes.map(\.type) == ["ai_process", "agent", "copy", "http_post", "save"])

        // Validation moved files together with the model; pin it.
        check("a workflow without enabled steps reports an issue",
              Workflow(nodes: [WorkflowNode(type: .save, isEnabled: false)]).configurationIssue != nil)
        check("an AI step without instructions reports an issue",
              Workflow(nodes: [WorkflowNode(type: .aiProcess, config: .init(aiPrompt: "  "))]).configurationIssue != nil)
        check("a complete workflow reports no issue",
              Workflow(nodes: [WorkflowNode(type: .aiProcess, config: .init(aiPrompt: "摘要")),
                               WorkflowNode(type: .save)]).configurationIssue == nil)
    }
}
