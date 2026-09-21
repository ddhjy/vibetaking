import Foundation
import SwiftUI

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
    var selectedWorkflowID: UUID?
    var isExecuting: Bool = false
    var currentNodeIndex: Int = 0
    var executionError: Error?
    
    private let workflowsStorageKey = "workflows_v2"
    private let selectedWorkflowIDKey = "selectedWorkflowId"
    private let legacyActiveWorkflowIDKey = "activeWorkflowId"
    private let legacyAutoPasteSyncEnabledKey = "autoPasteSyncEnabled"
    private let legacyAutoPasteHostKey = "autoPasteHost"
    private let legacyAutoPastePortKey = "autoPastePort"
    private init() {
        loadWorkflows()
    }
    
    var selectedWorkflow: Workflow {
        if let id = selectedWorkflowID,
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
            guard let idx = workflows.firstIndex(where: { $0.id == selectedWorkflow.id }) else { return }
            workflows[idx].nodes = newValue
            saveWorkflows()
        }
    }

    func selectWorkflow(_ id: UUID) {
        selectedWorkflowID = id
        persistSelectedWorkflowID()
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

        workflows[idx].isOpen = shouldOpen
        saveWorkflows()
    }
    
    func addWorkflow(_ workflow: Workflow) {
        var wf = workflow
        normalizeNodes(&wf.nodes)
        workflows.append(wf)
        if selectedWorkflowID == nil {
            selectWorkflow(wf.id)
        }
        saveWorkflows()
    }
    
    func deleteWorkflow(_ id: UUID) {
        guard workflows.contains(where: { $0.id == id }) else { return }
        guard workflows.count > 1 else { return }

        workflows.removeAll { $0.id == id }
        if selectedWorkflowID == id, let firstWorkflowId = workflows.first?.id {
            selectWorkflow(firstWorkflowId)
        }
        ensureOpenWorkflowExists()
        saveWorkflows()
    }
    
    func updateWorkflow(_ workflow: Workflow) {
        if let idx = workflows.firstIndex(where: { $0.id == workflow.id }) {
            workflows[idx] = workflow
            ensureOpenWorkflowExists()
            saveWorkflows()
        }
    }

    func duplicateWorkflow(_ id: UUID) {
        guard let source = workflows.first(where: { $0.id == id }) else { return }

        let copy = Workflow(
            name: source.name + " 副本",
            icon: source.icon,
            isOpen: source.isOpen,
            nodes: source.nodes
        )

        workflows.append(copy)
        saveWorkflows()
    }

    func addNode(_ node: WorkflowNode) {
        guard let idx = workflows.firstIndex(where: { $0.id == selectedWorkflow.id }) else { return }
        workflows[idx].nodes.append(node)
        saveWorkflows()
    }

    func updateNode(_ node: WorkflowNode) {
        guard let wIdx = workflows.firstIndex(where: { $0.id == selectedWorkflow.id }),
              let nIdx = workflows[wIdx].nodes.firstIndex(where: { $0.id == node.id }) else { return }
        workflows[wIdx].nodes[nIdx] = node
        saveWorkflows()
    }

    func moveNode(from source: IndexSet, to destination: Int) {
        guard let idx = workflows.firstIndex(where: { $0.id == selectedWorkflow.id }) else { return }
        workflows[idx].nodes.move(fromOffsets: source, toOffset: destination)
        saveWorkflows()
    }

    func deleteNodes(at offsets: IndexSet) {
        guard let idx = workflows.firstIndex(where: { $0.id == selectedWorkflow.id }) else { return }
        workflows[idx].nodes.remove(atOffsets: offsets)
        saveWorkflows()
    }

    func canDuplicateWorkflow(_ id: UUID) -> Bool {
        workflows.contains(where: { $0.id == id })
    }

    func canDeleteWorkflow(_ id: UUID) -> Bool {
        guard workflows.contains(where: { $0.id == id }) else { return false }
        return workflows.count > 1
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
    
    func reload() {
        loadWorkflows()
    }

    private func loadWorkflows() {
        if let data = AppDefaults.current.data(forKey: workflowsStorageKey),
           let saved = try? JSONDecoder().decode([Workflow].self, from: data),
           !saved.isEmpty {
            workflows = saved
        } else {
            workflows = [Workflow()]
        }

        stripRemovedAutoPasteWorkflows()
        
        let persistedSelection = AppDefaults.current.string(forKey: selectedWorkflowIDKey)
            ?? AppDefaults.current.string(forKey: legacyActiveWorkflowIDKey)
        
        if let idStr = persistedSelection,
           let id = UUID(uuidString: idStr),
           workflows.contains(where: { $0.id == id }) {
            selectedWorkflowID = id
        } else {
            selectedWorkflowID = workflows.first?.id
        }
        
        for i in workflows.indices {
            normalizeNodes(&workflows[i].nodes)
        }
        ensureOpenWorkflowExists()
        saveWorkflows()
    }
    
    func saveWorkflows() {
        for i in workflows.indices {
            normalizeNodes(&workflows[i].nodes)
        }
        if let data = try? JSONEncoder().encode(workflows) {
            AppDefaults.current.set(data, forKey: workflowsStorageKey)
        }
    }

    func exportConfiguration() -> AppWorkflowConfiguration {
        AppWorkflowConfiguration(
            selectedWorkflowID: selectedWorkflowID,
            items: workflows
        )
    }

    func applyConfiguration(_ configuration: AppWorkflowConfiguration) throws {
        guard !configuration.items.isEmpty else {
            throw AppConfigurationImportError.emptyWorkflows
        }

        workflows = configuration.items
        stripRemovedAutoPasteWorkflows()
        for i in workflows.indices {
            normalizeNodes(&workflows[i].nodes)
        }

        if let selectedWorkflowID = configuration.selectedWorkflowID,
           workflows.contains(where: { $0.id == selectedWorkflowID }) {
            self.selectedWorkflowID = selectedWorkflowID
        } else {
            selectedWorkflowID = workflows.first?.id
        }

        ensureOpenWorkflowExists()
        saveWorkflows()
        persistSelectedWorkflowID()
    }
    
    private func normalizeNodes(_ nodes: inout [WorkflowNode]) {
    }

    func execute(workflowID: UUID, input: String, tags: [String]) async throws -> WorkflowExecutionResult {
        guard let workflow = workflows.first(where: { $0.id == workflowID }) else {
            throw NSError(
                domain: "WorkflowManager",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "这个工作流已被删除。请返回工作流设置，选择其他工作流。"]
            )
        }

        if let issue = workflow.configurationIssue {
            throw NSError(domain: "WorkflowManager", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: issue])
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

            case .agentProcess:
                if let prompt = node.config.agentPrompt, !prompt.isEmpty {
                    currentText = try await executeAgentNode(prompt: prompt, input: currentText)
                }
                
            case .httpPost:
                let target = await resolveHTTPNodeTarget(node.config)
                guard let url = HTTPTargetURL.make(host: target.host, port: target.port) else {
                    throw NSError(domain: "WorkflowManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "发送地址无法使用。请检查发送步骤中的主机地址和端口，确保与 Mac 端设置一致。"])
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = currentText.data(using: .utf8)
                request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    throw NSError(domain: "WorkflowManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "接收端未接受请求。请确认 Mac 上已打开随心记，并检查发送步骤中的地址和端口。"])
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

    /// 草稿为空时，向 Workflow 内已启用的 HTTP 发送节点 POST `/send`，让 Mac 端模拟回车。
    /// - Returns: 是否至少向一个 HTTP 节点发起了请求
    func sendReturnKey(workflowID: UUID) async throws -> Bool {
        guard let workflow = workflows.first(where: { $0.id == workflowID }) else {
            throw NSError(
                domain: "WorkflowManager",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "这个工作流已被删除。请返回工作流设置，选择其他工作流。"]
            )
        }

        let httpNodes = workflow.nodes.filter { $0.isEnabled && $0.type == .httpPost }
        guard !httpNodes.isEmpty else { return false }

        for node in httpNodes {
            let target = await resolveHTTPNodeTarget(node.config)
            guard let url = HTTPTargetURL.make(host: target.host, port: target.port, path: "/send") else {
                throw NSError(domain: "WorkflowManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "发送地址无法使用。请检查发送步骤中的主机地址和端口，确保与 Mac 端设置一致。"])
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                throw NSError(domain: "WorkflowManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "接收端未接受请求。请确认 Mac 上已打开随心记，并检查发送步骤中的地址和端口。"])
            }
        }

        return true
    }

    private func resolveHTTPNodeTarget(_ config: WorkflowNode.NodeConfig) async -> (host: String, port: Int) {
        let cachedHost = config.httpHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cachedPort = config.httpPort ?? VibetakingBonjour.defaultPort

        if let serviceName = config.httpServiceName, !serviceName.isEmpty {
            if let resolved = await BonjourResolver.resolve(serviceName: serviceName),
               HTTPTargetURL.make(host: resolved.host, port: resolved.port) != nil {
                return (resolved.host, resolved.port)
            }
            if !cachedHost.isEmpty {
                return (cachedHost, cachedPort)
            }
        }

        if !cachedHost.isEmpty {
            return (cachedHost, cachedPort)
        }
        return ("localhost", cachedPort)
    }

    /// Agent 节点：把草稿交给多轮工具循环处理，返回最终文本。
    /// 复用聊天页的完整工具集（笔记 / 文件 / 记忆 / 设备）。
    private func executeAgentNode(prompt: String, input: String) async throws -> String {
        let settings = AISettingsStore.shared
        guard let token = settings.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw LLMError.missingCredentials
        }
        let base = AISettingsStore.normalizedBaseURLString(settings.baseURLString)
        let model = settings.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = OpenAIResponsesAgentProvider(
            apiKey: token,
            modelId: model.isEmpty ? AISettingsStore.defaultModelID : model,
            baseURLString: base
        )
        noff_set_storage_root(NoteStore.shared.agentStorageRootURL.path)

        let engine = AgentEngine(registry: AgentChatViewModel.makeDefaultRegistry())
        let systemPrompt = AgentSystemPrompt.build(
            memoryFragment: AgentToolkitExtras.memoryPromptFragment(),
            skillsFragment: AgentToolkitExtras.skillsPromptFragment()
        ) + "\n\n## Workflow mode\nYou are running inside a one-shot workflow pipeline. Complete the task with tools as needed, then output ONLY the final text result (it feeds the next pipeline node) — no preamble, no explanation."

        let userText = """
        任务指令：
        \(prompt)

        输入文本：
        \(input)
        """

        let result = try await engine.run(
            userText: userText,
            systemPrompt: systemPrompt,
            provider: provider
        ) { _ in }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "WorkflowManager",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "AI 助手没有返回文本。请在步骤指令中说明需要输出什么，再运行工作流。"]
            )
        }
        return trimmed
    }
    
    private func ensureOpenWorkflowExists() {
        guard !workflows.isEmpty else { return }
        guard !workflows.contains(where: \.isOpen) else { return }
        
        if let selectedWorkflowID,
           let idx = workflows.firstIndex(where: { $0.id == selectedWorkflowID }) {
            workflows[idx].isOpen = true
        } else {
            workflows[0].isOpen = true
        }
    }

    private func stripRemovedAutoPasteWorkflows() {
        let defaults = AppDefaults.current
        defaults.removeObject(forKey: legacyAutoPasteSyncEnabledKey)
        defaults.removeObject(forKey: legacyAutoPasteHostKey)
        defaults.removeObject(forKey: legacyAutoPastePortKey)

        workflows.removeAll(where: \.isUnsupportedKind)
        if workflows.isEmpty {
            workflows = [Workflow()]
        }
    }

    private func persistSelectedWorkflowID() {
        if let selectedWorkflowID {
            AppDefaults.current.set(selectedWorkflowID.uuidString, forKey: selectedWorkflowIDKey)
        } else {
            AppDefaults.current.removeObject(forKey: selectedWorkflowIDKey)
        }
    }

    private static func normalizedPort(_ value: Int) -> Int {
        min(max(value, 1), 65535)
    }
}
