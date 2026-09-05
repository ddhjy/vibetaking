import SwiftUI

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var accessibilityFocus: SheetTrigger?
    private enum SheetTrigger: Hashable { case more, tags, workflows }

    @State private var showHistory: Bool = false
    @State private var showAgentChat: Bool = false
    @State private var historySearchText: String = ""
    @State private var showTagSelector: Bool = false
    @State private var showDebugView: Bool = false
    @State private var historyManager = HistoryManager.shared
    @State private var tagManager = TagManager.shared
    
    @State private var showSettings: Bool = false

    @State private var isTextEditorFocused: Bool = false
    
    @State private var showWorkflowConfig = false
    @State private var workflowManager = WorkflowManager.shared
    @State private var processingWorkflowId: UUID? = nil
    @State private var visibleLoadingWorkflowId: UUID? = nil
    @State private var workflowError: Error? = nil
    
    @State private var keyboardTask: Task<Void, Never>?
    @State private var workflowLoadingTask: Task<Void, Never>?
    @State private var sendPipelineTask: Task<Void, Never>?
    @State private var sendGeneration: UInt = 0
    
    @State private var hasLaunched = false
    
    @State private var showWorkflowError = false
    @State private var workflowErrorTitle = "工作流未完成"
    @State private var workflowErrorContext = ""
    @State private var statusMessage: String?
    @State private var statusMessageTask: Task<Void, Never>?
    @State private var inputSessionResetToken = 0
    @State private var lastClearedTags: [String] = []

    @AppStorage("focusedWorkflowID", store: AppDefaults.current) private var focusedWorkflowIDRaw: String = ""
    /// 长按切换专注模式后，吞掉同一次按压在松手时触发的 Button 点击。
    @State private var suppressNextWorkflowTap = false
    
    private var draftText: String {
        historyManager.currentDraft.text
    }
    
    private var selectedTags: [String] {
        historyManager.currentDraft.tags
    }

    private var trimmedDraftText: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var focusedWorkflow: Workflow? {
        guard let id = UUID(uuidString: focusedWorkflowIDRaw) else { return nil }
        return workflowManager.openWorkflows.first { $0.id == id && $0.kind == .manual }
    }

    private var isFocusMode: Bool { focusedWorkflow != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    fullScreenEditor
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("记录", systemImage: "rectangle.stack") {
                        navigateToHistory()
                    }
                        .labelStyle(.iconOnly)
                }
                
                ToolbarItem(id: AppToolbarIdentity.moreButton, placement: .topBarTrailing) {
                    Menu("更多操作", systemImage: "ellipsis") {
                        Button {
                            isTextEditorFocused = false
                            showAgentChat = true
                        } label: {
                            Label("AI 助手", systemImage: "sparkles")
                        }

                        Button("工作流", systemImage: "arrow.triangle.branch") {
                            showWorkflowConfig = true
                        }

                        Menu("进入专注模式", systemImage: "viewfinder") {
                            ForEach(workflowManager.openWorkflows) { workflow in
                                Button(workflow.name, systemImage: workflow.icon) {
                                    enterFocusMode(workflow)
                                }
                            }
                        }
                        .disabled(processingWorkflowId != nil)

                        Divider()

                        Button {
                            showSettings = true
                        } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("更多操作")
                    .accessibilityFocused($accessibilityFocus, equals: .more)
                    .id(AppToolbarIdentity.moreButton)
                }
            }
            .toolbar(isFocusMode ? .hidden : .automatic, for: .navigationBar)

            .navigationDestination(isPresented: $showHistory) {
                HistoryView(initialSearchText: historySearchText)
            }
            .navigationDestination(isPresented: $showAgentChat) {
                AgentChatView()
            }
            .safeAreaInset(edge: .bottom) {
                bottomToolbar
            }
            .sheet(isPresented: $showTagSelector, onDismiss: { restoreEditorFocus(to: .tags) }) {
                TagPickerView(itemId: historyManager.currentDraft.id)
            }
            .sheet(isPresented: $showDebugView) {
                DebugView()
            }
            .sheet(isPresented: $showSettings, onDismiss: { restoreEditorFocus(to: .more) }) {
                SettingsView()
            }
            .sheet(isPresented: $showWorkflowConfig, onDismiss: { restoreEditorFocus(to: .workflows) }) {
                WorkflowConfigView()
            }
            .sheet(item: Binding(
                get: { showAgentChat ? nil : OffloadPermissionManager.shared.pendingRequest },
                set: { newValue in
                    if newValue == nil, !showAgentChat, let current = OffloadPermissionManager.shared.pendingRequest {
                        OffloadPermissionManager.shared.respond(to: current.id, allowed: false)
                    }
                }
            )) { request in
                OffloadPermissionDialog(request: request)
            }
            .alert(workflowErrorTitle, isPresented: $showWorkflowError) {
                if workflowError is AIServiceError || workflowError is LLMError {
                    Button("检查 AI 设置") { showSettings = true }
                }
                Button("检查工作流") { showWorkflowConfig = true }
                Button("继续记录", role: .cancel) { workflowError = nil }
            } message: {
                Text([workflowError?.userFacingDescription ?? "请检查工作流设置后再试一次。", workflowErrorContext]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n"))
            }

        }
        .onAppear {
            historyManager.loadItemsIfNeeded()
            if !hasLaunched {
                hasLaunched = true
                isTextEditorFocused = true
            } else {
                scheduleKeyboardShow(delay: 0.5)
            }
        }
        .onChange(of: showHistory) { _, isShowing in
            if isShowing {
                keyboardTask?.cancel()
                keyboardTask = nil
            } else {
                scheduleKeyboardShow(delay: 0.5)
            }
        }
        .onChange(of: showAgentChat) { _, isShowing in
            if isShowing {
                keyboardTask?.cancel()
                keyboardTask = nil
            } else {
                scheduleKeyboardShow(delay: 0.5)
            }
        }
        .onChange(of: draftText) { _, text in
            if !text.isEmpty { lastClearedTags = [] }
        }
        .onChange(of: selectedTags) { _, tags in
            if !tags.isEmpty { lastClearedTags = [] }
        }
        .onChange(of: isPresentingSheet) { _, isPresenting in
            if isPresenting {
                keyboardTask?.cancel()
                isTextEditorFocused = false
            }
        }
        .onDisappear {
            keyboardTask?.cancel()
            statusMessageTask?.cancel()
            statusMessage = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: isTextEditorFocused) { _, isFocused in
            UIApplication.shared.isIdleTimerDisabled = isFocused
        }
        .onChange(of: workflowManager.workflows) { _, _ in
            // 专注中的 Workflow 被删除或关闭时，清掉持久化的专注状态。
            guard !focusedWorkflowIDRaw.isEmpty, focusedWorkflow == nil else { return }
            withAnimation(focusTransition) {
                focusedWorkflowIDRaw = ""
            }
        }
    }
    
    private var isPresentingSheet: Bool {
        showTagSelector || showSettings || showWorkflowConfig || showDebugView
            || OffloadPermissionManager.shared.pendingRequest != nil
    }

    private var focusTransition: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    private var bottomToolbar: some View {
        VStack(spacing: 8) {
            if let workflowID = visibleLoadingWorkflowId,
               let workflow = workflowManager.workflows.first(where: { $0.id == workflowID }) {
                Text("正在运行“\(workflow.name)”：第 \(workflowManager.currentNodeIndex + 1) 步，共 \(workflow.nodes.filter(\.isEnabled).count) 步")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            } else if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }
            HStack(spacing: 8) {
                if isFocusMode, let workflow = focusedWorkflow {
                    workflowButton(for: workflow)
                        .frame(maxWidth: .infinity)
                        .controlSurface(emphasized: true)

                    Button("退出专注", systemImage: "viewfinder") {
                        exitFocusMode()
                    }
                    .labelStyle(.iconOnly)
                    .font(Design.controlFont)
                    .frame(width: 44, height: 44)
                    .controlSurface()
                    .accessibilityHint("显示导航和其他工作流")
                } else {
                    if dynamicTypeSize.isAccessibilitySize {
                        Menu {
                            ForEach(workflowManager.openWorkflows) { workflow in
                                Button(workflow.name, systemImage: workflow.icon) { handleWorkflowTap(workflow) }
                            }
                            Divider()
                            Button("工作流设置", systemImage: "slider.horizontal.3") { showWorkflowConfig = true }
                        } label: {
                            Image(systemName: "arrow.triangle.branch")
                                .font(Design.controlFont)
                                .frame(width: 44, height: 44)
                        }
                        .controlSurface()
                        .accessibilityLabel("选择工作流")
                        Spacer(minLength: 0)
                    } else {
                        workflowToolbar
                    }
                    tagButton

                    Button("搜索记录", systemImage: "magnifyingglass", action: searchDraftInHistory)
                        .labelStyle(.iconOnly)
                        .font(Design.controlFont)
                        .frame(width: 44, height: 44)
                        .controlSurface()
                        .disabled(processingWorkflowId != nil)
                }

                clearDraftButton
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .animation(focusTransition, value: isFocusMode)
            .sensoryFeedback(.impact(weight: .medium), trigger: isFocusMode)
        }
    }

    private var workflowToolbar: some View {
        GeometryReader { geometry in
            let buttonWidth = Design.minimumTarget
            let spacing: CGFloat = 4
            let inset: CGFloat = 4
            let buttonCount = workflowManager.openWorkflows.count + 1
            let capacity = max(1, Int((geometry.size.width - 2 * inset + spacing) / (buttonWidth + spacing)))
            let visibleCount = min(buttonCount, capacity)
            // An integral number of buttons makes both edges align, including at the end of the list.
            let width = CGFloat(visibleCount) * (buttonWidth + spacing) - spacing + 2 * inset

            ScrollView(.horizontal) {
                HStack(spacing: spacing) {
                    workflowSettingsButton
                    ForEach(workflowManager.openWorkflows) { workflow in
                        workflowButton(for: workflow)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, inset, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollIndicators(.hidden)
            .frame(width: width, height: buttonWidth)
            // Keep the glass outside the scroll view so its shadow isn't clipped into a rectangle.
            .controlSurface()
        }
        .frame(height: Design.minimumTarget)
    }

    private var canRestoreDraft: Bool {
        draftText.isEmpty && (historyManager.hasLastClearedText || !lastClearedTags.isEmpty)
    }

    private var clearDraftLabel: String {
        if canRestoreDraft { return historyManager.hasLastClearedText ? "恢复草稿" : "恢复标签" }
        return draftText.isEmpty ? "清除标签" : "清除草稿"
    }

    private var clearDraftButton: some View {
        Button(action: clearText) {
            Image(systemName: canRestoreDraft ? "arrow.uturn.backward" : "xmark")
                .font(Design.controlFont)
                .frame(width: 44, height: 44)
        }
        .controlSurface()
        .accessibilityLabel(clearDraftLabel)
        .accessibilityHint(canRestoreDraft ? "撤销上一次清除" : "清除后可使用恢复按钮撤销")
        .disabled(processingWorkflowId != nil || (draftText.isEmpty && selectedTags.isEmpty && !canRestoreDraft))
    }

    private var tagButton: some View {
        Button { showTagSelector = true } label: {
            Image(systemName: selectedTags.isEmpty ? "tag" : "tag.fill")
                .font(Design.controlFont)
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if !selectedTags.isEmpty && !dynamicTypeSize.isAccessibilitySize {
                        Text(selectedTags.count.formatted())
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 4)
                            .background(Color(.systemBackground), in: Capsule())
                            .accessibilityHidden(true)
                    }
                }
        }
        .controlSurface()
        .accessibilityLabel("草稿标签")
        .accessibilityValue(selectedTags.isEmpty ? "未选择" : selectedTags.joined(separator: "、"))
        .accessibilityFocused($accessibilityFocus, equals: .tags)
        .disabled(processingWorkflowId != nil)
    }

    private var workflowSettingsButton: some View {
        Button { showWorkflowConfig = true } label: {
            Image(systemName: "slider.horizontal.3")
                .font(Design.controlFont)
                .frame(width: Design.minimumTarget, height: Design.minimumTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("工作流设置")
        .accessibilityFocused($accessibilityFocus, equals: .workflows)
        .disabled(processingWorkflowId != nil)
    }

    private func workflowButton(for workflow: Workflow) -> some View {
        let focused = isFocusMode && focusedWorkflow?.id == workflow.id
        return Button {
            handleWorkflowTap(workflow)
        } label: {
            HStack(spacing: 8) {
                if visibleLoadingWorkflowId == workflow.id {
                    ProgressView()
                } else {
                    Image(systemName: workflow.icon).font(Design.controlFont)
                }
                if focused {
                    Text(workflow.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .foregroundStyle(focused ? Color.white : Color.primary)
            .tint(focused ? Color.white : Design.primaryColor)
            .padding(.horizontal, focused ? 16 : 0)
            .frame(width: focused ? nil : Design.minimumTarget, height: focused ? 48 : Design.minimumTarget)
            .frame(maxWidth: focused ? .infinity : nil)
            .contentShape(Capsule())
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                if isFocusMode {
                    exitFocusMode(fromLongPress: true)
                } else {
                    enterFocusMode(workflow, fromLongPress: true)
                }
            }
        )
        .accessibilityLabel(workflow.name)
        .accessibilityValue(visibleLoadingWorkflowId == workflow.id ? "正在运行工作流" : (focused ? "专注模式" : ""))
        .accessibilityHint(workflowActionHint(for: workflow))
        .accessibilityAction(named: focused ? "退出专注模式" : "进入专注模式") {
            if focused { exitFocusMode() } else { enterFocusMode(workflow) }
        }
    }

    private var fullScreenEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if draftText.isEmpty {
                    Text("写下此刻的想法…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
                
                DraftTextView(
                    text: Binding(
                        get: { draftText },
                        set: { historyManager.updateDraftText($0) }
                    ),
                    isFocused: $isTextEditorFocused,
                    inputSessionResetToken: inputSessionResetToken,
                    isScrollEnabled: !draftText.isEmpty,
                    font: UIFont.preferredFont(forTextStyle: .body),
                    returnKeyType: isFocusMode ? .send : .default,
                    onReturnKeySubmit: focusedWorkflow.map { workflow in
                        { performWorkflowSend(workflow) }
                    }
                )
                .padding(.horizontal, 16)
            }
            .frame(maxWidth: Design.readingWidth, maxHeight: .infinity)
            .frame(maxWidth: .infinity)

            if draftText.isEmpty && historyManager.savedItems.isEmpty && !isFocusMode {
                VStack(alignment: .leading, spacing: 4) {
                    Text("草稿随输入保存。要在记录列表中回顾，请运行含“保存记录”步骤的工作流。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("设置保存步骤") { showWorkflowConfig = true }
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: Design.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func workflowActionHint(for workflow: Workflow) -> String {
        if draftText.isEmpty && workflow.nodes.contains(where: { $0.isEnabled && $0.type == .httpPost }) {
            return "草稿为空，将向接收端发送回车指令"
        }
        return "按顺序处理当前草稿，开始运行时清空输入框，可继续写下一条"
    }

    private func showStatus(_ message: String) {
        statusMessageTask?.cancel()
        statusMessage = message
        UIAccessibility.post(notification: .announcement, argument: message)
        statusMessageTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
    }
    
    private func scheduleKeyboardShow(delay: Double) {
        keyboardTask?.cancel()
        
        keyboardTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, !showHistory, !showAgentChat, !isPresentingSheet else { return }
            isTextEditorFocused = true
            
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, !showHistory, !showAgentChat, !isPresentingSheet else { return }
            if !isTextEditorFocused {
                isTextEditorFocused = true
            }
            
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, !showHistory, !showAgentChat, !isPresentingSheet else { return }
            if !isTextEditorFocused {
                isTextEditorFocused = true
            }
        }
    }
    
    private func restoreEditorFocus(to trigger: SheetTrigger) {
        accessibilityFocus = trigger
        if !UIAccessibility.isVoiceOverRunning {
            scheduleKeyboardShow(delay: 0.3)
        }
    }

    private func navigateToHistory(searchText: String = "") {
        if historyManager.isUsingLocalFallback || historyManager.hasPendingICloudDownloads {
            historyManager.refreshFromEnvironment()
        } else {
            historyManager.loadItemsIfNeeded()
        }
        historySearchText = searchText
        isTextEditorFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            showHistory = true
        }
    }

    private func searchDraftInHistory() {
        if trimmedDraftText.isEmpty {
            navigateToHistory()
        } else {
            navigateToHistory(searchText: trimmedDraftText)
        }
    }
    
    private func clearText() {
        let announcement = canRestoreDraft ? "已\(clearDraftLabel)" : "已\(clearDraftLabel)，可以撤销"
        if draftText.isEmpty {
            if historyManager.hasLastClearedText {
                interruptDraftInputSession()
                historyManager.restoreLastClearedDraft()
            } else if !lastClearedTags.isEmpty {
                let tags = lastClearedTags
                lastClearedTags = []
                for tag in tags { historyManager.addTag(to: historyManager.currentDraft.id, tagName: tag) }
            } else {
                lastClearedTags = selectedTags
                historyManager.clearDraftTags()
            }
        } else {
            interruptDraftInputSession()
            historyManager.clearDraft()
        }
        showStatus(announcement)
    }

    private func enterFocusMode(_ workflow: Workflow, fromLongPress: Bool = false) {
        guard workflow.kind == .manual, processingWorkflowId == nil else { return }
        suppressNextWorkflowTap = fromLongPress
        withAnimation(focusTransition) {
            focusedWorkflowIDRaw = workflow.id.uuidString
        }
    }

    private func exitFocusMode(fromLongPress: Bool = false) {
        guard isFocusMode, processingWorkflowId == nil else { return }
        if fromLongPress {
            suppressNextWorkflowTap = true
        }
        withAnimation(focusTransition) {
            focusedWorkflowIDRaw = ""
        }
    }

    private func handleWorkflowTap(_ workflow: Workflow) {
        if suppressNextWorkflowTap {
            suppressNextWorkflowTap = false
            return
        }

        performWorkflowSend(workflow)
    }

    private func performWorkflowSend(_ workflow: Workflow) {
        if draftText.isEmpty {
            enqueueSend {
                await sendReturnKey(for: workflow)
            }
            return
        }

        interruptDraftInputSession()

        if draftText.hasPrefix("打开调试模式") {
            historyManager.clearDraft()
            showDebugView = true
            return
        }

        if let issue = workflow.configurationIssue {
            workflowErrorTitle = "“\(workflow.name)”还未设置完成"
            workflowErrorContext = ""
            workflowError = NSError(domain: "WorkflowManager", code: -4,
                                    userInfo: [NSLocalizedDescriptionKey: issue])
            showWorkflowError = true
            return
        }

        let text = draftText
        let tags = selectedTags
        historyManager.clearDraft()
        enqueueSend {
            await executeWorkflow(workflow, input: text, tags: tags)
        }
    }

    /// 串行发送管线：后一次操作等前一次完成；失败后丢弃已排队的后续操作。
    private func enqueueSend(_ operation: @escaping @MainActor () async -> Bool) {
        let previous = sendPipelineTask
        let generation = sendGeneration
        sendPipelineTask = Task { @MainActor in
            _ = await previous?.value
            guard !Task.isCancelled, generation == sendGeneration else { return }
            let succeeded = await operation()
            if !succeeded {
                sendGeneration &+= 1
            }
        }
    }

    private func sendReturnKey(for workflow: Workflow) async -> Bool {
        do {
            let didSend = try await workflowManager.sendReturnKey(workflowID: workflow.id)
            showStatus(didSend ? "已向接收端发送回车指令" : "先写下一段文字，再运行“\(workflow.name)”。")
            return true
        } catch {
            workflowErrorTitle = "回车指令未能发送"
            workflowErrorContext = "请先检查接收端，再决定是否重新发送。"
            workflowError = error
            showWorkflowError = true
            return false
        }
    }
    
    private func executeWorkflow(_ workflow: Workflow, input: String, tags: [String]) async -> Bool {
        processingWorkflowId = workflow.id
        visibleLoadingWorkflowId = nil
        workflowLoadingTask?.cancel()
        workflowLoadingTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard processingWorkflowId == workflow.id else { return }
                visibleLoadingWorkflowId = workflow.id
            }
        }

        defer {
            workflowLoadingTask?.cancel()
            workflowLoadingTask = nil
            visibleLoadingWorkflowId = nil
            processingWorkflowId = nil
        }

        do {
            let result = try await workflowManager.execute(
                workflowID: workflow.id,
                input: input,
                tags: tags
            )

            if result.shouldSave {
                if draftText.isEmpty {
                    performSave(text: result.finalText)
                } else {
                    historyManager.addRecord(result.finalText, tags: result.tags)
                }
            }
            showStatus(result.didCopyToClipboard ? "“\(workflow.name)”已完成，文本已复制到剪贴板。" : "“\(workflow.name)”已完成。")
            return true
        } catch {
            workflowErrorTitle = "“\(workflow.name)”未完成"
            workflowError = error
            if draftText.isEmpty {
                historyManager.restoreLastClearedDraft()
            }
            workflowErrorContext = draftText == input ? "原文已恢复到输入框。" : ""
            if workflowManager.currentNodeIndex > 0 {
                workflowErrorContext += "前面的步骤可能已完成，请检查结果后再运行。"
            }
            showWorkflowError = true
            return false
        }
    }
    
    private func performSave(text: String) {
        historyManager.updateDraftText(text)
        historyManager.finalizeDraft()
    }

    private func interruptDraftInputSession() {
        inputSessionResetToken &+= 1
    }
}

struct DraftTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let inputSessionResetToken: Int
    let isScrollEnabled: Bool
    let font: UIFont
    var returnKeyType: UIReturnKeyType = .default
    var onReturnKeySubmit: (() -> Void)?
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = font
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.tintColor = .systemIndigo
        textView.accessibilityLabel = "草稿内容"
        textView.accessibilityHint = "实时保存草稿，使用工作流保存为记录"
        textView.accessibilityIdentifier = "draft-editor"
        textView.text = text
        textView.isScrollEnabled = isScrollEnabled
        textView.isEditable = true
        textView.isSelectable = true
        textView.returnKeyType = returnKeyType
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.resetInputSessionIfNeeded(on: uiView)
        context.coordinator.syncTextIfNeeded(on: uiView)
        if uiView.font != font { uiView.font = font }
        if uiView.isScrollEnabled != isScrollEnabled { uiView.isScrollEnabled = isScrollEnabled }

        context.coordinator.applyReturnKeyTypeIfNeeded(on: uiView)

        if context.coordinator.isRefreshingKeyboard {
            return
        }

        context.coordinator.scheduleFocusUpdate(on: uiView)
        
        if context.coordinator.lastText != text {
            let wasNonEmpty = !context.coordinator.lastText.isEmpty
            let isNowEmpty = text.isEmpty
            context.coordinator.lastText = text
            
            if wasNonEmpty && isNowEmpty {
                uiView.setContentOffset(.zero, animated: false)
                uiView.selectedRange = NSRange(location: 0, length: 0)
                uiView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: DraftTextView
        var lastText: String
        var lastInputSessionResetToken: Int
        var shouldPreferLegacyTextSync = false
        var appliedReturnKeyType: UIReturnKeyType
        var isRefreshingKeyboard = false
        private var isSynchronizingText = false
        private var isApplyingFocusUpdate = false
        private var focusUpdateGeneration: UInt = 0
        private var keyboardRefreshGeneration: UInt = 0
        
        init(_ parent: DraftTextView) {
            self.parent = parent
            self.lastText = parent.text
            self.lastInputSessionResetToken = parent.inputSessionResetToken
            self.appliedReturnKeyType = parent.returnKeyType
        }

        func applyReturnKeyTypeIfNeeded(on textView: UITextView) {
            guard appliedReturnKeyType != parent.returnKeyType || textView.returnKeyType != parent.returnKeyType else { return }
            textView.returnKeyType = parent.returnKeyType
            appliedReturnKeyType = parent.returnKeyType
            scheduleKeyboardAppearanceRefresh(on: textView)
        }

        func scheduleFocusUpdate(on textView: UITextView) {
            focusUpdateGeneration &+= 1
            let generation = focusUpdateGeneration
            guard parent.isFocused != textView.isFirstResponder else { return }
            // First-responder changes can invoke SwiftUI layout and delegate callbacks.
            // Perform them after updateUIView's transaction has completed.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, self.focusUpdateGeneration == generation,
                      textView.window != nil, !self.isRefreshingKeyboard else { return }
                self.isApplyingFocusUpdate = true
                defer { self.isApplyingFocusUpdate = false }
                if self.parent.isFocused { textView.becomeFirstResponder() }
                else { textView.resignFirstResponder() }
            }
        }

        /// 中文九宫格会忽略 `reloadInputViews()`；进出专注又包在 SwiftUI 动画事务里，必须跳出事务并短暂交接 first responder，键盘才会改键帽。
        private func scheduleKeyboardAppearanceRefresh(on textView: UITextView) {
            keyboardRefreshGeneration &+= 1
            let generation = keyboardRefreshGeneration
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, self.keyboardRefreshGeneration == generation else { return }
                self.refreshKeyboardAppearance(on: textView)
            }
        }

        private func refreshKeyboardAppearance(on textView: UITextView) {
            textView.returnKeyType = parent.returnKeyType
            appliedReturnKeyType = parent.returnKeyType

            let shouldKeepKeyboard = textView.isFirstResponder || parent.isFocused
            guard shouldKeepKeyboard, textView.window != nil else {
                textView.reloadInputViews()
                return
            }

            isRefreshingKeyboard = true
            let animationsWereEnabled = UIView.areAnimationsEnabled
            UIView.setAnimationsEnabled(false)
            defer {
                UIView.setAnimationsEnabled(animationsWereEnabled)
                isRefreshingKeyboard = false
            }

            let probe = UITextView()
            probe.returnKeyType = parent.returnKeyType
            probe.keyboardType = textView.keyboardType
            probe.autocorrectionType = textView.autocorrectionType
            probe.spellCheckingType = textView.spellCheckingType
            probe.textContentType = textView.textContentType
            probe.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            probe.alpha = 0.01
            probe.isUserInteractionEnabled = false
            (textView.window ?? textView.superview)?.addSubview(probe)

            probe.becomeFirstResponder()
            textView.reloadInputViews()
            textView.becomeFirstResponder()
            probe.removeFromSuperview()
        }

        func resetInputSessionIfNeeded(on textView: UITextView) {
            guard lastInputSessionResetToken != parent.inputSessionResetToken else { return }

            lastInputSessionResetToken = parent.inputSessionResetToken
            shouldPreferLegacyTextSync = true
        }

        func syncTextIfNeeded(on textView: UITextView) {
            isSynchronizingText = true
            defer { isSynchronizingText = false }
            if shouldPreferLegacyTextSync {
                textView.text = parent.text
                if parent.text.isEmpty {
                    shouldPreferLegacyTextSync = false
                }
                return
            }

            guard textView.text != parent.text else { return }

            if textView.isFirstResponder,
               let fullRange = textView.textRange(from: textView.beginningOfDocument, to: textView.endOfDocument) {
                textView.replace(fullRange, withText: parent.text)
            } else {
                textView.text = parent.text
            }
        }
        
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", let onSubmit = parent.onReturnKeySubmit else { return true }
            // 中文输入法组字阶段，回车用于确认候选词，不拦截
            guard textView.markedTextRange == nil else { return true }
            onSubmit()
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isSynchronizingText else { return }
            lastText = textView.text
            parent.text = textView.text
        }
        
        func textViewDidBeginEditing(_ textView: UITextView) {
            guard !isRefreshingKeyboard, !isApplyingFocusUpdate else { return }
            if !parent.isFocused {
                parent.isFocused = true
            }
        }
        
        func textViewDidEndEditing(_ textView: UITextView) {
            guard !isRefreshingKeyboard, !isApplyingFocusUpdate else { return }
            if parent.isFocused {
                parent.isFocused = false
            }
        }
    }
}


#Preview {
    ContentView()
}
