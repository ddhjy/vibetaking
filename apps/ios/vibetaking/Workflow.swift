import Foundation

enum WorkflowNodeType: String, Codable, CaseIterable {
    case aiProcess = "ai_process"
    case agentProcess = "agent"
    case copyToClipboard = "copy"
    case save = "save"
    case httpPost = "http_post"

    var displayName: String {
        switch self {
        case .aiProcess: "AI 改写"
        case .agentProcess: "AI 助手"
        case .copyToClipboard: "复制文本"
        case .save: "保存记录"
        case .httpPost: "发送到 Mac 或网址"
        }
    }

    var icon: String {
        switch self {
        case .aiProcess: "sparkles"
        case .agentProcess: "brain.head.profile"
        case .copyToClipboard: "doc.on.doc"
        case .save: "square.and.arrow.down"
        case .httpPost: "paperplane.circle"
        }
    }
}


struct WorkflowNode: Identifiable, Codable, Equatable {
    let id: UUID
    var type: WorkflowNodeType
    var isEnabled: Bool
    var config: NodeConfig

    struct NodeConfig: Codable, Equatable {
        var aiPrompt: String?
        /// Agent 节点的任务指令（可用全部工具的多轮处理）。
        var agentPrompt: String?
        var httpHost: String?
        var httpPort: Int?
        var httpServiceName: String?
    }

    init(id: UUID = UUID(), type: WorkflowNodeType, isEnabled: Bool = true, config: NodeConfig = NodeConfig()) {
        self.id = id
        self.type = type
        self.isEnabled = isEnabled
        self.config = config
    }

    static func defaultNodes() -> [WorkflowNode] {
        []
    }
}


struct Workflow: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var icon: String
    var isOpen: Bool
    var nodes: [WorkflowNode]

    /// 旧数据里 `kind` 不是 `manual` 的工作流（已移除的 Auto Paste 开关型）。只在解码时为 true，
    /// 加载后即被丢弃，不会再写回；单独标记是为了不让一条旧数据拖垮整个数组的解码。
    private(set) var isUnsupportedKind = false

    /// Validate before consuming the draft so an unfinished workflow cannot discard input.
    var configurationIssue: String? {
        let enabledNodes = nodes.filter(\.isEnabled)
        guard !enabledNodes.isEmpty else {
            return "这个工作流还没有可运行的步骤。添加一个步骤（如“保存记录”）后再运行，草稿已保留。"
        }
        for node in enabledNodes {
            let prompt: String?
            switch node.type {
            case .aiProcess: prompt = node.config.aiPrompt
            case .agentProcess: prompt = node.config.agentPrompt
            default: continue
            }
            if prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                return "请先填写“\(node.type.displayName)”步骤的指令。草稿已保留。"
            }
        }
        return nil
    }

    /// 写出的字段。旧版的 `kind`、`isActive`、`syncConfig` 不再写出；旧版读取时均为可缺省字段。
    enum CodingKeys: String, CodingKey {
        case id, name, icon, isOpen, nodes
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case kind
    }

    init(
        id: UUID = UUID(),
        name: String = "默认工作流",
        icon: String = "arrow.triangle.branch",
        isOpen: Bool = true,
        nodes: [WorkflowNode] = WorkflowNode.defaultNodes()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isOpen = isOpen
        self.nodes = nodes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "arrow.triangle.branch"
        isOpen = try container.decodeIfPresent(Bool.self, forKey: .isOpen) ?? false
        nodes = try container.decodeIfPresent([WorkflowNode].self, forKey: .nodes) ?? []

        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let kind = try legacy.decodeIfPresent(String.self, forKey: .kind)
        isUnsupportedKind = kind != nil && kind != "manual"
    }

}
