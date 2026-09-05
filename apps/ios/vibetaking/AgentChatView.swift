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
    private var sendTask: Task<Void, Never>?
    /// toolId → block 索引，用于把结果写回对应块。
    private var toolBlockIndex: [String: Int] = [:]

    init(session: AgentChatSession? = nil) {
        let chatSession = session ?? AgentChatSession()
        let registry = Self.makeDefaultRegistry(sessionId: chatSession.id.uuidString)
        if let session {
            self.session = session
            self.engine = AgentEngine(
                registry: registry,
                history: session.messages.map { $0.toAgentMessage() }
            )
            self.blocks = Self.rebuildBlocks(from: engine.agentHistory)
        } else {
            self.session = chatSession
            self.engine = AgentEngine(registry: registry)
        }
    }

    var sessionId: UUID { session.id }
    var sessionTitle: String { session.title.isEmpty ? "新会话" : session.title }

    static func makeDefaultRegistry(sessionId: String = UUID().uuidString) -> ToolRegistry {
        var tools: [AgentTool] = [
            SearchNotesTool(),
            ReadNoteTool(),
            SaveNoteTool(),
            AddTagsTool(),
            ListTagsTool(),
            FileReadTool(),
            FileWriteTool(),
        ]
        tools.append(contentsOf: AgentToolkitExtras.additionalTools(sessionId: sessionId))
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
        let provider: AgentProvider
        do {
            provider = try Self.makeProvider()
        } catch {
            blocks.append(AgentDisplayBlock(kind: .errorNotice(error.userFacingDescription)))
            return
        }
        inputText = ""
        blocks.append(AgentDisplayBlock(kind: .userText(text)))
        if session.title.isEmpty {
            session.title = String(text.prefix(24))
        }

        isRunning = true
        sendTask = Task {
            defer {
                isRunning = false
                sendTask = nil
                persist()
            }
            do {
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
                blocks.append(AgentDisplayBlock(kind: .errorNotice(Task.isCancelled ? "已取消" : error.userFacingDescription)))
            }
        }
    }

    func cancel() {
        sendTask?.cancel()
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
    static func additionalTools(sessionId: String) -> [AgentTool] {
        var tools: [AgentTool] = []
        tools.append(contentsOf: AgentMemoryStore.shared.memoryTools())
        tools.append(CalendarManageTool(sessionId: sessionId))
        tools.append(RemindersManageTool(sessionId: sessionId))
        tools.append(ClipboardAccessTool(sessionId: sessionId))
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var followsConversation = true
    @State private var isInteractingWithConversation = false

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
                        Color.clear.frame(height: 1).id("conversation-bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: Design.readingWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onScrollPhaseChange { _, phase, context in
                    switch phase {
                    case .tracking, .interacting, .decelerating:
                        isInteractingWithConversation = true
                        followsConversation = false
                    case .idle:
                        if isInteractingWithConversation {
                            isInteractingWithConversation = false
                            let geometry = context.geometry
                            followsConversation = geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 100
                        }
                    default: break
                    }
                }
                .onChange(of: viewModel.blocks.count) { _, _ in
                    guard let last = viewModel.blocks.last else { return }
                    if case .userText = last.kind {
                        followsConversation = true
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    } else if followsConversation {
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.isRunning) { _, running in
                    if running {
                        followsConversation = true
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.sessionId) { _, _ in
                    followsConversation = true
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
                    if followsConversation, viewModel.isRunning {
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    }
                }
            }

        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
        .navigationTitle(viewModel.blocks.isEmpty ? "AI 助手" : viewModel.sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新会话", systemImage: "square.and.pencil") {
                        viewModel.cancel()
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
                viewModel.cancel()
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
        ContentUnavailableView {
            Label("向你的笔记提问", systemImage: "sparkles")
        } description: {
            Text("查找想法、整理记录，或为笔记推荐标签。")
        } actions: {
            VStack(spacing: 10) {
                ForEach(["回顾上周关于工作的想法", "整理最近的读书笔记", "为未分类的记录推荐标签"], id: \.self) { prompt in
                    Button {
                        viewModel.inputText = prompt
                        inputFocused = true
                    } label: {
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("填入输入框，可以修改后发送")
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: AgentDisplayBlock) -> some View {
        switch block.kind {
        case .userText(let text):
            HStack {
                Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 16 : 48)
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityLabel("你：\(text)")
            }
        case .assistantText(let text):
            AgentMarkdownText(source: text)
        case .thinking(let text):
            DisclosureGroup {
                Text(text).font(.subheadline).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("思考过程", systemImage: "brain")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
            }
        case .toolCall(let name, let title, let status, let result, let isError):
            let statusLabel = status == .running ? "正在执行" : (status == .done ? "已完成" : "执行失败")
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("工具：\(name)").font(.caption).foregroundStyle(.secondary)
                    if !result.isEmpty {
                        Text(result)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if isError { Label("执行失败", systemImage: "exclamationmark.circle").font(.footnote) }
                }
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    switch status {
                    case .running: ProgressView()
                    case .done: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(Design.negativeColor)
                    }
                    Text(title).font(.subheadline).foregroundStyle(.primary)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(statusLabel)
            }
            .padding(.horizontal, 12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        case .errorNotice(let message):
            Label {
                Text(message).foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Design.negativeColor)
            }
            .font(.subheadline)
            .padding(.vertical, 8)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("问点什么…", text: Bindable(viewModel).inputText, axis: .vertical)
                .font(.body)
                .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 3 : 6))
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                .accessibilityLabel("发给 AI 助手的消息")
                .onSubmit { viewModel.send() }

            if viewModel.isRunning {
                Button("停止生成", systemImage: "stop.fill") { viewModel.cancel() }
                    .labelStyle(.iconOnly)
                    .font(Design.controlFont)
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .tint(Design.negativeColor)
            } else {
                Button("发送消息", systemImage: "arrow.up") { viewModel.send() }
                    .labelStyle(.iconOnly)
                    .font(Design.controlFont)
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: Design.readingWidth)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - Session List

struct AgentSessionListView: View {
    @State private var sessionToDelete: AgentChatSession?
    @Environment(\.dismiss) private var dismiss
    @State private var store = AgentSessionStore.shared
    let onSelect: (AgentChatSession) -> Void

    var body: some View {
        NavigationStack {
            List {
                if store.sessions.isEmpty {
                    ContentUnavailableView("还没有会话", systemImage: "bubble.left.and.bubble.right", description: Text("向助手发送消息后，会话会保存在这里。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(store.sessions) { session in
                    Button {
                        onSelect(session)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title.isEmpty ? "未命名会话" : session.title)
                                .font(.body)
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                            Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions(allowsFullSwipe: false) {
                        Button("删除会话", systemImage: "trash", role: .destructive) { sessionToDelete = session }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .alert(item: $sessionToDelete) { session in
                Alert(title: Text("删除这段会话？"), message: Text("会话内容删除后不可恢复。"),
                      primaryButton: .destructive(Text("删除会话")) { store.delete(session.id) },
                      secondaryButton: .cancel(Text("取消")))
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
