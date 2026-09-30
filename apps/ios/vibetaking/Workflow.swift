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

// MARK: - 内置工作流

extension Workflow {
    /// 内置工作流靠固定 ID 识别，不新增存储字段：旧版本、导出包和演示数据都按普通工作流读写它们。
    /// 这两个 ID 一旦发布就不能再改，否则已安装用户的内置工作流会被当成自定义的、再补一份。
    static let builtInSaveID = UUID(uuidString: "C4E8EE3B-0068-4C1C-8FFD-5CAB96DAAD20")!
    static let builtInSendID = UUID(uuidString: "71E00288-D5B5-4DEE-9402-78716C4E5266")!

    /// 内置工作流随应用存在，不能删除；名称、图标、步骤和是否显示在主页仍由用户决定。
    var isBuiltIn: Bool {
        id == Self.builtInSaveID || id == Self.builtInSendID
    }

    /// 新用户开箱即用的保存按钮，默认显示在主页。
    static func builtInSave(isOpen: Bool = true) -> Workflow {
        Workflow(
            id: builtInSaveID,
            name: "保存记录",
            icon: "square.and.arrow.down",
            isOpen: isOpen,
            nodes: [WorkflowNode(type: .save)]
        )
    }

    /// 发送到 Mac 需要先绑定设备，默认从主页隐藏，避免新用户误触后看到连接错误。
    static func builtInSend(isOpen: Bool = false) -> Workflow {
        Workflow(
            id: builtInSendID,
            name: "发送到 Mac",
            icon: "laptopcomputer",
            isOpen: isOpen,
            nodes: [WorkflowNode(type: .httpPost)]
        )
    }

    /// 按主页与设置页里的固定顺序返回全部内置工作流。
    static func builtIns() -> [Workflow] {
        [builtInSave(), builtInSend()]
    }

    /// 恢复默认后的样子：名称、图标和步骤回到出厂状态。是否显示在主页和已绑定的 Mac 属于使用设置，
    /// 保持不变，免得恢复后按钮从主页消失或要重新配对。不是内置工作流时返回 nil。
    func restoredToDefault() -> Workflow? {
        guard var restored = Self.builtIns().first(where: { $0.id == id }) else { return nil }
        restored.isOpen = isOpen
        if let connection = nodes.first(where: { $0.type == .httpPost })?.config {
            for index in restored.nodes.indices where restored.nodes[index].type == .httpPost {
                restored.nodes[index].config.httpHost = connection.httpHost
                restored.nodes[index].config.httpPort = connection.httpPort
                restored.nodes[index].config.httpServiceName = connection.httpServiceName
            }
        }
        return restored
    }

    /// 内置工作流已被改过，可以恢复默认。步骤按内容比较，不看每次新建都会变的步骤 ID。
    var canRestoreDefault: Bool {
        guard let restored = restoredToDefault() else { return false }
        let sameSteps = nodes.count == restored.nodes.count
            && zip(nodes, restored.nodes).allSatisfy { current, original in
                current.type == original.type && current.isEnabled == original.isEnabled && current.config == original.config
            }
        return name != restored.name || icon != restored.icon || !sameSteps
    }
}
