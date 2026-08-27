// vibetaking Agent 聊天页：消息列表 + 工具调用状态 + 流式渲染。
// 简化自研 UI（不引 OpenMinis 的 MessageList/KaTeX 渲染栈）。
// This file is part of vibetaking, licensed under GPL-3.0 as a combined work
// with code derived from OpenMinis; see LICENSE.

import SwiftUI

// MARK: - Display Model

struct AgentDisplayBlock: Identifiable {
    enum Kind {
        case userText(String)
        case assistantText(String)
        case thinking(String)
        case toolCall(name: String, title: String, status: ToolStatus, result: String, isError: Bool)
        case errorNotice(String)
    }

    enum ToolStatus {
        case running
        case done
        case failed
    }

    let id = UUID()
    var kind: Kind
}

// MARK: - ViewModel

@Observable
class AgentChatViewModel {
    private(set) var blocks: [AgentDisplayBlock] = []
    private(set) var isRunning = false
    var inputText = ""

    private var engine: AgentEngine
    private var session: AgentChatSession
    /// toolId → block 索引，用于把结果写回对应块。
    private var toolBlockIndex: [String: Int] = [:]

    init(session: AgentChatSession? = nil) {
        let registry = Self.makeDefaultRegistry()
        if let session {
            self.session = session
            self.engine = AgentEngine(
                registry: registry,
                history: session.messages.map { $0.toAgentMessage() }
            )
            self.blocks = Self.rebuildBlocks(from: engine.agentHistory)
        } else {
            self.session = AgentChatSession()
            self.engine = AgentEngine(registry: registry)
        }
    }

    var sessionId: UUID { session.id }
    var sessionTitle: String { session.title.isEmpty ? "新会话" : session.title }

    static func makeDefaultRegistry() -> ToolRegistry {
        var tools: [AgentTool] = [
            SearchNotesTool(),
            ReadNoteTool(),
            SaveNoteTool(),
            AddTagsTool(),
            ListTagsTool(),
            FileReadTool(),
            FileWriteTool(),
        ]
        tools.append(contentsOf: AgentToolkitExtras.additionalTools())
        return ToolRegistry(tools: tools)
    }

    private static func makeProvider() throws -> AgentProvider {
        let settings = SettingsManager.shared
        guard let token = settings.aiApiToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw LLMError.missingCredentials
        }
        let base = SettingsManager.normalizedAIBaseURLString(settings.aiBaseURLString)
        let model = settings.aiModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenAIResponsesAgentProvider(
            apiKey: token,
            modelId: model.isEmpty ? SettingsManager.defaultAIModelID : model,
            baseURLString: base
        )
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        inputText = ""
        blocks.append(AgentDisplayBlock(kind: .userText(text)))
        if session.title.isEmpty {
            session.title = String(text.prefix(24))
        }

        isRunning = true
        Task {
            defer {
                isRunning = false
                persist()
            }
            do {
                let provider = try Self.makeProvider()
                let systemPrompt = AgentSystemPrompt.build(
                    memoryFragment: AgentToolkitExtras.memoryPromptFragment(),
                    skillsFragment: AgentToolkitExtras.skillsPromptFragment()
                )
                try await engine.run(
                    userText: text,
                    systemPrompt: systemPrompt,
                    provider: provider
                ) { [weak self] event in
                    self?.handle(event)
                }
            } catch is CancellationError {
                blocks.append(AgentDisplayBlock(kind: .errorNotice("已取消")))
            } catch {
                blocks.append(AgentDisplayBlock(kind: .errorNotice(error.localizedDescription)))
            }
        }
    }

    func cancel() {
        engine.cancel()
    }

    private func handle(_ event: AgentEngineEvent) {
        switch event {
        case .assistantTextDelta(let delta):
            if case .assistantText(let existing) = blocks.last?.kind {
                blocks[blocks.count - 1].kind = .assistantText(existing + delta)
            } else {
                blocks.append(AgentDisplayBlock(kind: .assistantText(delta)))
            }

        case .thinkingDelta(let delta):
            if case .thinking(let existing) = blocks.last?.kind {
                blocks[blocks.count - 1].kind = .thinking(existing + delta)
            } else {
                blocks.append(AgentDisplayBlock(kind: .thinking(delta)))
            }

        case .toolCallStarted(let id, let name):
            let block = AgentDisplayBlock(kind: .toolCall(name: name, title: name, status: .running, result: "", isError: false))
            blocks.append(block)
            toolBlockIndex[id] = blocks.count - 1

        case .toolInputDelta:
            break

        case .toolCallFinished(let id, let name, let result, let isError):
            let title = Self.extractToolTitle(from: engine.agentHistory, toolId: id) ?? name
            if let index = toolBlockIndex[id], index < blocks.count {
                blocks[index].kind = .toolCall(name: name, title: title, status: isError ? .failed : .done, result: result, isError: isError)
            } else {
                blocks.append(AgentDisplayBlock(kind: .toolCall(name: name, title: title, status: isError ? .failed : .done, result: result, isError: isError)))
            }

        case .turnCompleted, .usage:
            break
        }
    }

    /// 从 agentHistory 中找到对应 tool_use 的 tool_title 参数。
    private static func extractToolTitle(from history: [AgentMessage], toolId: String) -> String? {
        for msg in history.reversed() {
            for part in msg.parts {
                if case .toolUse(let id, _, let input) = part, id == toolId {
                    return input["tool_title"] as? String
                }
            }
        }
        return nil
    }

    private func persist() {
        guard !engine.agentHistory.isEmpty else { return }
        session.messages = engine.agentHistory.map { StoredAgentMessage.from($0) }
        AgentSessionStore.shared.save(session)
    }

    private static func rebuildBlocks(from history: [AgentMessage]) -> [AgentDisplayBlock] {
        var blocks: [AgentDisplayBlock] = []
        var resultsByToolId: [String: (content: String, isError: Bool)] = [:]
        for msg in history {
            for part in msg.parts {
                if case .toolResult(let id, _, let content, let isError, _, _) = part {
                    resultsByToolId[id] = (content, isError)
                }
            }
        }
        for msg in history {
            for part in msg.parts {
                switch part {
                case .text(let text):
                    guard !text.isEmpty else { continue }
                    if msg.role == .user {
                        blocks.append(AgentDisplayBlock(kind: .userText(text)))
                    } else {
                        blocks.append(AgentDisplayBlock(kind: .assistantText(text)))
                    }
                case .toolUse(let id, let name, let input):
                    let title = (input["tool_title"] as? String) ?? name
                    let result = resultsByToolId[id]
                    blocks.append(AgentDisplayBlock(kind: .toolCall(
                        name: name,
                        title: title,
                        status: (result?.isError ?? false) ? .failed : .done,
                        result: result?.content ?? "",
                        isError: result?.isError ?? false
                    )))
                case .toolResult, .imageData:
                    break
                }
            }
        }
        return blocks
    }
}

/// memory / skills / 设备工具的接入挂点。
enum AgentToolkitExtras {
    static func additionalTools() -> [AgentTool] {
        var tools: [AgentTool] = []
        tools.append(contentsOf: AgentMemoryStore.shared.memoryTools())
        tools.append(CalendarManageTool())
        tools.append(RemindersManageTool())
        tools.append(ClipboardAccessTool())
        return tools
    }

    static func memoryPromptFragment() -> String? {
        AgentMemoryStore.shared.promptFragment()
    }

    static func skillsPromptFragment() -> String? {
        SkillStore.shared.promptFragment()
    }
}

// MARK: - View

struct AgentChatView: View {
    @State private var viewModel: AgentChatViewModel
    @State private var permissionManager = OffloadPermissionManager.shared
    @State private var showSessionList = false
    @FocusState private var inputFocused: Bool

    init(session: AgentChatSession? = nil) {
        _viewModel = State(initialValue: AgentChatViewModel(session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if viewModel.blocks.isEmpty {
                            emptyState
                        }
                        ForEach(viewModel.blocks) { block in
                            blockView(block)
                                .id(block.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: viewModel.blocks.count) { _, _ in
                    if let last = viewModel.blocks.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            inputBar
        }
        .navigationTitle(viewModel.sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新会话", systemImage: "square.and.pencil") {
                        viewModel = AgentChatViewModel()
                    }
                    Button("历史会话", systemImage: "clock.arrow.circlepath") {
                        showSessionList = true
                    }
                } label: {
                    AppToolbarMoreLabel()
                }
                .accessibilityLabel("更多")
            }
        }
        .sheet(isPresented: $showSessionList) {
            AgentSessionListView { selected in
                viewModel = AgentChatViewModel(session: selected)
                showSessionList = false
            }
        }
        .sheet(item: Binding(
            get: { permissionManager.pendingRequest },
            set: { newValue in
                // 任何把弹窗置空的路径（如系统级 dismiss）都视为拒绝，
                // 避免权限 continuation 悬挂导致 agent 卡死。
                if newValue == nil, let current = permissionManager.pendingRequest {
                    permissionManager.respond(to: current.id, allowed: false)
                }
            }
        )) { request in
            OffloadPermissionDialog(request: request)
        }
        .onAppear {
            AgentSessionStore.shared.loadIfNeeded()
            // 注册 offload 图片输出的落盘根目录（apple-clipboard get --image）。
            noff_set_storage_root(HistoryManager.shared.agentStorageRootURL.path)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("向你的笔记提问")
                .font(.headline)
            Text("试试问：\n· 上周我记了哪些关于工作的想法？\n· 把散落的读书笔记整理成一条新记录\n· 给最近没打标签的记录推荐标签")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 32)
    }

    @ViewBuilder
    private func blockView(_ block: AgentDisplayBlock) -> some View {
        switch block.kind {
        case .userText(let text):
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Design.primaryColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            }

        case .assistantText(let text):
            Text(LocalizedStringKey(text))
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .thinking(let text):
            DisclosureGroup {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("思考过程", systemImage: "brain")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .toolCall(let name, let title, let status, let result, let isError):
            DisclosureGroup {
                if !result.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(result)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(isError ? .red : .secondary)
                            .textSelection(.enabled)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    switch status {
                    case .running:
                        ProgressView().scaleEffect(0.7)
                    case .done:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    Text(title)
                        .font(.footnote)
                        .lineLimit(1)
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

        case .errorNotice(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("问点什么…", text: Bindable(viewModel).inputText, axis: .vertical)
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
                .onSubmit { viewModel.send() }

            if viewModel.isRunning {
                Button {
                    viewModel.cancel()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .tint(.red)
                .padding(12)
                .glassEffect(.regular.interactive(), in: Circle())
            } else {
                Button {
                    viewModel.send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                }
                .tint(Design.primaryColor)
                .padding(12)
                .glassEffect(.regular.interactive(), in: Circle())
                .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Session List

struct AgentSessionListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = AgentSessionStore.shared
    let onSelect: (AgentChatSession) -> Void

    var body: some View {
        NavigationStack {
            List {
                if store.sessions.isEmpty {
                    Text("还没有会话")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.sessions) { session in
                    Button {
                        onSelect(session)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title.isEmpty ? "未命名会话" : session.title)
                                .font(.body)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for offset in offsets {
                        store.delete(store.sessions[offset].id)
                    }
                }
            }
            .navigationTitle("历史会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { store.loadIfNeeded() }
        }
    }
}

#Preview {
    NavigationStack {
        AgentChatView()
    }
}
