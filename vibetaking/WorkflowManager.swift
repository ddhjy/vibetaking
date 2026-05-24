import Foundation
import SwiftUI

enum WorkflowKind: String, Codable, Equatable {
    case manual
    case autoPasteSync
}

enum WorkflowNodeType: String, Codable, CaseIterable {
    case aiProcess = "ai_process"
    case copyToClipboard = "copy"
    case save = "save"
    case httpPost = "http_post"
    
    var displayName: String {
        switch self {
        case .aiProcess: "AI 处理"
        case .copyToClipboard: "复制"
        case .save: "保存记录"
        case .httpPost: "HTTP 发送"
        }
    }
    
    var icon: String {
        switch self {
        case .aiProcess: "sparkles"
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
        var httpHost: String?
        var httpPort: Int?
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
    var kind: WorkflowKind
    var isOpen: Bool
    var isActive: Bool
    var syncConfig: SyncConfig
    var nodes: [WorkflowNode]

    struct SyncConfig: Codable, Equatable {
        var host: String
        var port: Int

        init(host: String = "", port: Int = 7788) {
            self.host = host
            self.port = port
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, kind, isOpen, isActive, syncConfig, nodes
    }

    init(
        id: UUID = UUID(),
        name: String = "默认 Workflow",
        icon: String = "arrow.triangle.branch",
        kind: WorkflowKind = .manual,
        isOpen: Bool = true,
        isActive: Bool = false,
        syncConfig: SyncConfig = SyncConfig(),
        nodes: [WorkflowNode] = WorkflowNode.defaultNodes()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.kind = kind
        self.isOpen = isOpen
        self.isActive = isActive
        self.syncConfig = syncConfig
        self.nodes = nodes
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "arrow.triangle.branch"
        kind = try container.decodeIfPresent(WorkflowKind.self, forKey: .kind) ?? .manual
        isOpen = try container.decodeIfPresent(Bool.self, forKey: .isOpen) ?? false
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        syncConfig = try container.decodeIfPresent(SyncConfig.self, forKey: .syncConfig) ?? SyncConfig()
        nodes = try container.decodeIfPresent([WorkflowNode].self, forKey: .nodes) ?? []
    }

    static func autoPasteSync(host: String = "", port: Int = 7788, isActive: Bool = false) -> Workflow {
        Workflow(
            name: "Auto Paste",
            icon: "wave.3.right",
            kind: .autoPasteSync,
            isOpen: true,
            isActive: isActive,
            syncConfig: SyncConfig(host: host, port: port),
            nodes: []
        )
    }
}


struct WorkflowExecutionResult: Identifiable {
    let id = UUID()
    let finalText: String
    let originalText: String
    let tags: [String]
    let shouldSave: Bool
    let didCopyToClipboard: Bool
}


@MainActor
@Observable
class WorkflowManager {
    static let shared = WorkflowManager()
    
    var workflows: [Workflow] = []
    var selectedWorkflowId: UUID?
    var isExecuting: Bool = false
    var currentNodeIndex: Int = 0
    var executionError: Error?
    
    private let workflowsStorageKey = "workflows_v2"
    private let selectedWorkflowIdKey = "selectedWorkflowId"
    private let legacyActiveWorkflowIdKey = "activeWorkflowId"
    private let legacyAutoPasteSyncEnabledKey = "autoPasteSyncEnabled"
    private let legacyAutoPasteHostKey = "autoPasteHost"
    private let legacyAutoPastePortKey = "autoPastePort"
    private init() {
        loadWorkflows()
    }
    
    var selectedWorkflow: Workflow {
        if let id = selectedWorkflowId,
           let wf = workflows.first(where: { $0.id == id }) {
            return wf
        }
        return workflows.first ?? Workflow()
    }
    
    var openWorkflows: [Workflow] {
        workflows.filter(\.isOpen)
    }
    
    var closedWorkflows: [Workflow] {
        workflows.filter { !$0.isOpen }
    }
    
    var nodes: [WorkflowNode] {
        get { selectedWorkflow.nodes }
        set {
            guard selectedWorkflow.kind == .manual else { return }
            guard let idx = workflows.firstIndex(where: { $0.id == selectedWorkflow.id }) else { return }
            workflows[idx].nodes = newValue
            saveWorkflows()
        }
    }

    var autoPasteSyncWorkflows: [Workflow] {
        workflows.filter { $0.kind == .autoPasteSync }
    }

    func selectWorkflow(_ id: UUID) {
        selectedWorkflowId = id
        UserDefaults.standard.set(id.uuidString, forKey: selectedWorkflowIdKey)
    }
    
    func canCloseWorkflow(_ id: UUID) -> Bool {
        guard let workflow = workflows.first(where: { $0.id == id }), workflow.isOpen else {
            return true
        }
        return openWorkflows.count > 1
    }
    
    func toggleWorkflowOpen(_ id: UUID) {
        guard let idx = workflows.firstIndex(where: { $0.id == id }) else { return }
        let shouldOpen = !workflows[idx].isOpen
        if !shouldOpen && !canCloseWorkflow(id) {
            return
        }

        if shouldOpen && workflows[idx].kind == .autoPasteSync {
            for i in workflows.indices where workflows[i].kind == .autoPasteSync {
                workflows[i].isOpen = false
            }
        }

        workflows[idx].isOpen = shouldOpen
        saveWorkflows()
    }
    
    func addWorkflow(_ workflow: Workflow) {
        var wf = workflow
        guard wf.kind == .manual else { return }
        normalizeNodes(&wf.nodes)
        workflows.append(wf)
        if selectedWorkflowId == nil {
            selectWorkflow(wf.id)
        }
        saveWorkflows()
    }
    
    func deleteWorkflow(_ id: UUID) {
        guard let workflow = workflows.first(where: { $0.id == id }) else { return }

        switch workflow.kind {
        case .manual:
            guard workflows.filter({ $0.kind == .manual }).count > 1 else { return }
        case .autoPasteSync:
            guard workflows.filter({ $0.kind == .autoPasteSync }).count > 1 else { return }
        }

        workflows.removeAll { $0.id == id }
        if selectedWorkflowId == id, let firstWorkflowId = workflows.first?.id {
            selectWorkflow(firstWorkflowId)
        }
        ensureOpenWorkflowExists()
        saveWorkflows()
    }
    
    func updateWorkflow(_ workflow: Workflow) {
        if let idx = workflows.firstIndex(where: { $0.id == workflow.id }) {
            var updated = workflow
            if updated.kind == .autoPasteSync {
                updated.nodes = []
            }
            workflows[idx] = updated
            ensureOpenWorkflowExists()
            saveWorkflows()
        }
    }

    func duplicateWorkflow(_ id: UUID) {
        guard let source = workflows.first(where: { $0.id == id }) else { return }

        let copy: Workflow
        switch source.kind {
        case .manual:
            copy = Workflow(
                name: source.name + " 副本",
                icon: source.icon,
                kind: .manual,
                isOpen: source.isOpen,
                nodes: source.nodes
            )
        case .autoPasteSync:
            copy = Workflow(
                name: source.name + " 副本",
                icon: source.icon,
                kind: .autoPasteSync,
                isOpen: false,
                isActive: false,
                syncConfig: source.syncConfig,
                nodes: []
            )
        }

        workflows.append(copy)
        saveWorkflows()
    }

    func addNode(_ node: WorkflowNode) {
        guard selectedWorkflow.kind == .manual else { return }
        guard let idx = workflows.firstIndex(where: { $0.id == selectedWorkflow.id }) else { return }
        workflows[idx].nodes.append(node)
        saveWorkflows()
    }

    func updateNode(_ node: WorkflowNode) {
        guard selectedWorkflow.kind == .manual else { return }
        guard let wIdx = workflows.firstIndex(where: { $0.id == selectedWorkflow.id }),
              let nIdx = workflows[wIdx].nodes.firstIndex(where: { $0.id == node.id }) else { return }
        workflows[wIdx].nodes[nIdx] = node
        saveWorkflows()
    }

    func moveNode(from source: IndexSet, to destination: Int) {
        guard selectedWorkflow.kind == .manual else { return }
        guard let idx = workflows.firstIndex(where: { $0.id == selectedWorkflow.id }) else { return }
        workflows[idx].nodes.move(fromOffsets: source, toOffset: destination)
        saveWorkflows()
    }

    func deleteNodes(at offsets: IndexSet) {
        guard selectedWorkflow.kind == .manual else { return }
        guard let idx = workflows.firstIndex(where: { $0.id == selectedWorkflow.id }) else { return }
        workflows[idx].nodes.remove(atOffsets: offsets)
        saveWorkflows()
    }

    func canDuplicateWorkflow(_ id: UUID) -> Bool {
        workflows.contains(where: { $0.id == id })
    }

    func canDeleteWorkflow(_ id: UUID) -> Bool {
        guard let workflow = workflows.first(where: { $0.id == id }) else { return false }
        switch workflow.kind {
        case .manual:
            return workflows.filter { $0.kind == .manual }.count > 1
        case .autoPasteSync:
            return workflows.filter { $0.kind == .autoPasteSync }.count > 1
        }
    }

    func toggleWorkflowActive(_ id: UUID) {
        guard let idx = workflows.firstIndex(where: { $0.id == id }),
              workflows[idx].kind == .autoPasteSync else { return }

        let shouldActivate = !workflows[idx].isActive
        if shouldActivate {
            for i in workflows.indices where workflows[i].kind == .autoPasteSync {
                workflows[i].isActive = false
            }
        }
        workflows[idx].isActive = shouldActivate

        saveWorkflows()
        notifyAutoPasteSyncWorkflowChanged()
    }

    func updateAutoPasteSyncConfig(workflowID: UUID, host: String? = nil, port: Int? = nil) {
        guard let idx = workflows.firstIndex(where: { $0.id == workflowID }),
              workflows[idx].kind == .autoPasteSync else { return }

        if let host {
            workflows[idx].syncConfig.host = host
        }
        if let port {
            workflows[idx].syncConfig.port = Self.normalizedPort(port)
        }

        saveWorkflows()
        notifyAutoPasteSyncWorkflowChanged()
    }

    func moveWorkflows(inOpenState isOpen: Bool, from source: IndexSet, to destination: Int) {
        var subset = workflows.filter { $0.isOpen == isOpen }
        subset.move(fromOffsets: source, toOffset: destination)
        
        let reorderedByID = Dictionary(uniqueKeysWithValues: subset.map { ($0.id, $0) })
        var reorderedIDs = subset.map(\.id).makeIterator()
        
        workflows = workflows.map { workflow in
            guard workflow.isOpen == isOpen,
                  let nextID = reorderedIDs.next(),
                  let replacement = reorderedByID[nextID] else {
                return workflow
            }
            return replacement
        }
        saveWorkflows()
    }
    
    func saveNodes() { saveWorkflows() }
    
    private func loadWorkflows() {
        if let data = UserDefaults.standard.data(forKey: workflowsStorageKey),
           let saved = try? JSONDecoder().decode([Workflow].self, from: data),
           !saved.isEmpty {
            workflows = saved
        } else {
            workflows = [Workflow()]
        }

        migrateLegacyAutoPasteSyncIfNeeded()
        ensureAutoPasteSyncWorkflowExists()
        
        let persistedSelection = UserDefaults.standard.string(forKey: selectedWorkflowIdKey)
            ?? UserDefaults.standard.string(forKey: legacyActiveWorkflowIdKey)
        
        if let idStr = persistedSelection,
           let id = UUID(uuidString: idStr),
           workflows.contains(where: { $0.id == id }) {
            selectedWorkflowId = id
        } else {
            selectedWorkflowId = workflows.first?.id
        }
        
        for i in workflows.indices {
            normalizeNodes(&workflows[i].nodes)
        }
        normalizeAutoPasteSyncState()
        ensureOpenWorkflowExists()
        saveWorkflows()
    }
    
    func saveWorkflows() {
        normalizeAutoPasteSyncState()
        for i in workflows.indices {
            if workflows[i].kind == .autoPasteSync {
                workflows[i].nodes = []
            }
            normalizeNodes(&workflows[i].nodes)
        }
        if let data = try? JSONEncoder().encode(workflows) {
            UserDefaults.standard.set(data, forKey: workflowsStorageKey)
        }
    }
    
    private func normalizeNodes(_ nodes: inout [WorkflowNode]) {
    }

    func execute(workflowID: UUID, input: String, tags: [String]) async throws -> WorkflowExecutionResult {
        guard let workflow = workflows.first(where: { $0.id == workflowID }) else {
            throw NSError(
                domain: "WorkflowManager",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "该 Workflow 已不存在"]
            )
        }

        guard workflow.kind == .manual else {
            throw NSError(
                domain: "WorkflowManager",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "该 Workflow 为开关型，请直接切换开关"]
            )
        }
        
        isExecuting = true
        currentNodeIndex = 0
        executionError = nil
        
        defer {
            isExecuting = false
        }
        
        var currentText = input
        let enabledNodes = workflow.nodes.filter { $0.isEnabled }
        var didCopy = false
        var shouldSave = false
        
        for (index, node) in enabledNodes.enumerated() {
            currentNodeIndex = index
            
            switch node.type {
            case .aiProcess:
                if let prompt = node.config.aiPrompt, !prompt.isEmpty {
                    currentText = try await AIService.shared.process(text: currentText, prompt: prompt)
                }
                
            case .httpPost:
                let host = node.config.httpHost ?? "localhost"
                let port = node.config.httpPort ?? 9999
                let urlString = "http://\(host):\(port)"
                guard let url = URL(string: urlString) else {
                    throw NSError(domain: "WorkflowManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "目标地址格式有误，请检查主机和端口"])
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = currentText.data(using: .utf8)
                request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    throw NSError(domain: "WorkflowManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "发送失败，请检查目标地址是否正确"])
                }

            case .copyToClipboard:
                let textToCopy = currentText
                await MainActor.run {
                    UIPasteboard.general.string = textToCopy
                }
                didCopy = true
                
            case .save:
                shouldSave = true
            }
        }
        
        return WorkflowExecutionResult(
            finalText: currentText,
            originalText: input,
            tags: tags,
            shouldSave: shouldSave,
            didCopyToClipboard: didCopy
        )
    }
    
    private func ensureOpenWorkflowExists() {
        guard !workflows.isEmpty else { return }
        guard !workflows.contains(where: \.isOpen) else { return }
        
        if let selectedWorkflowId,
           let idx = workflows.firstIndex(where: { $0.id == selectedWorkflowId }) {
            workflows[idx].isOpen = true
        } else {
            workflows[0].isOpen = true
        }
    }

    private func ensureAutoPasteSyncWorkflowExists() {
        guard workflows.contains(where: { $0.kind == .autoPasteSync }) else {
            workflows.append(.autoPasteSync())
            return
        }
    }

    private func normalizeAutoPasteSyncState() {
        var activeAutoPasteFound = false
        var openAutoPasteFound = false

        for i in workflows.indices where workflows[i].kind == .autoPasteSync {
            workflows[i].nodes = []

            if workflows[i].isActive {
                if activeAutoPasteFound {
                    workflows[i].isActive = false
                } else {
                    activeAutoPasteFound = true
                }
            }

            if workflows[i].isOpen {
                if openAutoPasteFound {
                    workflows[i].isOpen = false
                } else {
                    openAutoPasteFound = true
                }
            }
        }
    }

    private func migrateLegacyAutoPasteSyncIfNeeded() {
        let defaults = UserDefaults.standard
        let hasEnabled = defaults.object(forKey: legacyAutoPasteSyncEnabledKey) != nil
        let hasHost = defaults.object(forKey: legacyAutoPasteHostKey) != nil
        let hasPort = defaults.object(forKey: legacyAutoPastePortKey) != nil
        guard hasEnabled || hasHost || hasPort else { return }

        let host = defaults.string(forKey: legacyAutoPasteHostKey) ?? ""
        let storedPort = defaults.integer(forKey: legacyAutoPastePortKey)
        let port = storedPort == 0 ? 7788 : Self.normalizedPort(storedPort)
        let isActive = defaults.bool(forKey: legacyAutoPasteSyncEnabledKey)

        if let idx = workflows.firstIndex(where: { $0.kind == .autoPasteSync }) {
            if workflows[idx].syncConfig.host.isEmpty {
                workflows[idx].syncConfig.host = host
            }
            workflows[idx].syncConfig.port = port
            workflows[idx].isActive = isActive
        } else {
            workflows.append(.autoPasteSync(host: host, port: port, isActive: isActive))
        }

        defaults.removeObject(forKey: legacyAutoPasteSyncEnabledKey)
        defaults.removeObject(forKey: legacyAutoPasteHostKey)
        defaults.removeObject(forKey: legacyAutoPastePortKey)
    }

    private func notifyAutoPasteSyncWorkflowChanged() {
        Task { @MainActor in
            AutoPasteSyncManager.shared.settingsDidChange()
        }
    }

    private static func normalizedPort(_ value: Int) -> Int {
        min(max(value, 1), 65535)
    }
}
