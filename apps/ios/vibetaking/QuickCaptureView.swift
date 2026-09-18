import SwiftUI

struct QuickCaptureView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var titleWordmarkHeight: CGFloat = 34
    @AccessibilityFocusState private var accessibilityFocus: SheetTrigger?
    @Namespace private var toolbarGlassNamespace
    private enum SheetTrigger: Hashable { case more, tags, workflows }

    @State private var isNoteLibraryPresented: Bool = false
    @State private var isAgentChatPresented: Bool = false
    @State private var noteSearchText: String = ""
    @State private var isTagPickerPresented: Bool = false
    @State private var isDebugPresented: Bool = false
    @State private var noteStore = NoteStore.shared
    @State private var tagIndex = TagIndex.shared
    
    @State private var isSettingsPresented: Bool = false

    @State private var isTextEditorFocused: Bool = false
    
    @State private var isWorkflowSettingsPresented = false
    @State private var workflowManager = WorkflowManager.shared
    @State private var processingWorkflowID: UUID? = nil
    @State private var visibleLoadingWorkflowID: UUID? = nil
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

    @AppStorage("focusedWorkflowID", store: AppDefaults.current) private var focusedWorkflowIDRaw: String = ""
    /// 长按切换专注模式后，吞掉同一次按压在松手时触发的 Button 点击。
    @State private var suppressNextWorkflowTap = false
    
    private var draftText: String {
        noteStore.currentDraft.text
    }
    
    private var selectedTags: [String] {
        noteStore.currentDraft.tags
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
        GeometryReader { navigationGeometry in
            navigationContent(topEdge: navigationGeometry.frame(in: .global).minY)
        }
    }

    private func navigationContent(topEdge: CGFloat) -> some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()
                
                fullScreenEditor
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { contentGeometry in
                    // Draw the page title in the navigation bar's visual band,
                    // without making it a navigation item or reserving another row.
                    let navigationHeight = max(0, contentGeometry.frame(in: .global).minY - topEdge)
                    AppTitleWordmark(height: min(titleWordmarkHeight, max(0, navigationHeight - 12)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 20)
                        .padding(.trailing, 130)
                        // The native toolbar reserves 12 pt below its controls.
                        .frame(height: max(0, navigationHeight - 12), alignment: .bottom)
                        .offset(y: -navigationHeight)
                }
                .allowsHitTesting(false)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("记录", systemImage: "rectangle.stack") {
                        openNoteLibrary()
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("记录")
                    .accessibilityHint("打开记录列表")
                    .disabled(processingWorkflowID != nil)
                }

                ToolbarSpacer(.fixed, placement: .topBarTrailing)

                ToolbarItem(id: AppToolbarIdentity.moreButton, placement: .topBarTrailing) {
                    Menu("更多操作", systemImage: "ellipsis") {
                        Button {
                            isTextEditorFocused = false
                            // Resign while the home page is visible so it receives
                            // the keyboard hide event before navigation starts.
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            Task { @MainActor in
                                isAgentChatPresented = true
                            }
                        } label: {
                            Label("AI 助手", systemImage: "sparkles")
                        }

                        Button("工作流", systemImage: "arrow.triangle.branch") {
                            isWorkflowSettingsPresented = true
                        }

                        Menu("进入专注模式", systemImage: "viewfinder") {
                            ForEach(workflowManager.openWorkflows) { workflow in
                                Button(workflow.name, systemImage: workflow.icon) {
                                    enterFocusMode(workflow)
                                }
                            }
                        }
                        .disabled(processingWorkflowID != nil)

                        Divider()

                        Button {
                            isSettingsPresented = true
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
            .navigationDestination(isPresented: $isNoteLibraryPresented) {
                NoteLibraryDestination(initialSearchText: noteSearchText).equatable()
            }
            .navigationDestination(isPresented: $isAgentChatPresented) {
                AgentChatDestination().equatable()
            }
            .safeAreaInset(edge: .bottom) {
                bottomToolbar
            }
            .sheet(isPresented: $isTagPickerPresented, onDismiss: { restoreEditorFocus(to: .tags) }) {
                TagPickerView(noteID: noteStore.currentDraft.id)
            }
            .sheet(isPresented: $isDebugPresented) {
                DebugView()
            }
            .sheet(isPresented: $isSettingsPresented, onDismiss: { restoreEditorFocus(to: .more) }) {
                SettingsView()
            }
            .sheet(isPresented: $isWorkflowSettingsPresented, onDismiss: { restoreEditorFocus(to: .workflows) }) {
                WorkflowConfigView()
            }
            .sheet(item: Binding(
                get: { isAgentChatPresented ? nil : OffloadPermissionManager.shared.pendingRequest },
                set: { newValue in
                    if newValue == nil, !isAgentChatPresented, let current = OffloadPermissionManager.shared.pendingRequest {
                        OffloadPermissionManager.shared.respond(to: current.id, allowed: false)
                    }
                }
            )) { request in
                OffloadPermissionDialog(request: request)
            }
            .alert(workflowErrorTitle, isPresented: $showWorkflowError) {
                if workflowError is AIServiceError || workflowError is LLMError {
                    Button("检查 AI 设置") { isSettingsPresented = true }
                }
                Button("检查工作流") { isWorkflowSettingsPresented = true }
                Button("继续记录", role: .cancel) { workflowError = nil }
            } message: {
                Text([workflowError?.userFacingDescription ?? "请检查工作流设置后再试一次。", workflowErrorContext]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n"))
            }

        }
        .onAppear {
            noteStore.loadItemsIfNeeded()
            if !hasLaunched {
                hasLaunched = true
                PerformanceLog.mark("ui.editor.appeared")
                isTextEditorFocused = true
            } else {
                scheduleKeyboardShow(delay: 0.5)
            }
        }
        .onChange(of: isNoteLibraryPresented) { _, isShowing in
            if isShowing {
                keyboardTask?.cancel()
                keyboardTask = nil
            } else {
                scheduleKeyboardShow(delay: 0.5)
            }
        }
        .onChange(of: isAgentChatPresented) { _, isShowing in
            if isShowing {
                keyboardTask?.cancel()
                keyboardTask = nil
            } else {
                scheduleKeyboardShow(delay: 0.5)
            }
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
            focusedWorkflowIDRaw = ""
        }
    }
    
    private var isPresentingSheet: Bool {
        isTagPickerPresented || isSettingsPresented || isWorkflowSettingsPresented || isDebugPresented
            || OffloadPermissionManager.shared.pendingRequest != nil
    }

    private var toolbarFocusTransition: Animation? {
        reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.08)
    }

    private var bottomToolbar: some View {
        VStack(spacing: 8) {
            if !isFocusMode,
               let workflowID = visibleLoadingWorkflowID,
               let workflow = workflowManager.workflows.first(where: { $0.id == workflowID }) {
                Text("正在运行“\(workflow.name)”：第 \(workflowManager.currentNodeIndex + 1) 步，共 \(workflow.nodes.filter(\.isEnabled).count) 步")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            } else if !isFocusMode, let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }
            // Keep the three surfaces alive in both modes. Only the leading capsule expands.
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 12) {
                    workflowToolbar
                    focusOrTagButton
                        .controlSurface()
                        .glassEffectID("secondary", in: toolbarGlassNamespace)
                    clearDraftButton
                        .glassEffectID("clear", in: toolbarGlassNamespace)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            // Keep the keyboard inset and trailing controls stable throughout the focus transition.
            .frame(height: AppTheme.minimumTarget)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .animation(toolbarFocusTransition, value: isFocusMode)
            .sensoryFeedback(.impact(weight: .medium), trigger: isFocusMode)
        }
    }

    private var workflowToolbar: some View {
        GeometryReader { geometry in
            let buttonWidth = AppTheme.minimumTarget
            let spacing: CGFloat = 4
            let inset: CGFloat = 4
            let buttonCount = workflowManager.openWorkflows.count + 1
            let capacity = max(1, Int((geometry.size.width - 2 * inset + spacing) / (buttonWidth + spacing)))
            let visibleCount = min(buttonCount, capacity)
            // An integral number of buttons makes both edges align, including at the end of the list.
            let compactWidth = dynamicTypeSize.isAccessibilitySize
                ? buttonWidth
                : CGFloat(visibleCount) * (buttonWidth + spacing) - spacing + 2 * inset

            ZStack {
                if let workflow = focusedWorkflow {
                    workflowButton(for: workflow, focused: true)
                        .transition(.blurReplace)
                } else if dynamicTypeSize.isAccessibilitySize {
                    Menu {
                        ForEach(workflowManager.openWorkflows) { workflow in
                            Button(workflow.name, systemImage: workflow.icon) { handleWorkflowTap(workflow) }
                        }
                        Divider()
                        Button("工作流设置", systemImage: "slider.horizontal.3") { isWorkflowSettingsPresented = true }
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                            .font(AppTheme.controlFont)
                            .frame(width: buttonWidth, height: buttonWidth)
                    }
                    .accessibilityLabel("选择工作流")
                    .transition(.blurReplace)
                } else {
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
                    .transition(.blurReplace)
                }
            }
            .frame(width: isFocusMode ? geometry.size.width : compactWidth, height: buttonWidth)
            .clipShape(Capsule())
            // Keep the glass outside the scroll view so its shadow isn't clipped into a rectangle.
            .controlSurface(emphasized: isFocusMode)
            .glassEffectID("workflow", in: toolbarGlassNamespace)
        }
        .frame(height: AppTheme.minimumTarget)
    }

    private var canRestoreDraft: Bool {
        draftText.isEmpty && selectedTags.isEmpty && noteStore.hasRestorableDraft
    }

    private var clearDraftLabel: String {
        if canRestoreDraft { return noteStore.hasLastClearedText ? "恢复草稿" : "恢复标签" }
        return draftText.isEmpty ? "清除标签" : "清除草稿"
    }

    private var clearDraftButton: some View {
        Button(action: clearText) {
            Image(systemName: canRestoreDraft ? "arrow.uturn.backward" : "xmark")
                .font(AppTheme.controlFont)
                .frame(width: AppTheme.minimumTarget, height: AppTheme.minimumTarget)
        }
        .controlSurface()
        .accessibilityLabel(clearDraftLabel)
        .accessibilityHint(canRestoreDraft ? "撤销上一次清除" : "清除后可使用恢复按钮撤销")
        .disabled(processingWorkflowID != nil || (draftText.isEmpty && selectedTags.isEmpty && !canRestoreDraft))
    }

    private var focusOrTagButton: some View {
        Button {
            if isFocusMode {
                exitFocusMode()
            } else {
                isTagPickerPresented = true
            }
        } label: {
            Image(systemName: isFocusMode ? "viewfinder" : "tag")
                .font(AppTheme.controlFont)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: AppTheme.minimumTarget, height: AppTheme.minimumTarget)
                .overlay(alignment: .topTrailing) {
                    if !isFocusMode && !selectedTags.isEmpty && !dynamicTypeSize.isAccessibilitySize {
                        Text(selectedTags.count.formatted())
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 4)
                            .background(Color(.systemBackground), in: Capsule())
                            .accessibilityHidden(true)
                    }
                }
        }
        .accessibilityLabel(isFocusMode ? "退出专注" : "草稿标签")
        .accessibilityValue(isFocusMode ? "" : (selectedTags.isEmpty ? "未选择" : selectedTags.joined(separator: "、")))
        .accessibilityHint(isFocusMode ? "显示其他工作流" : "")
        .accessibilityFocused($accessibilityFocus, equals: .tags)
        .disabled(processingWorkflowID != nil)
    }

    private var workflowSettingsButton: some View {
        Button { isWorkflowSettingsPresented = true } label: {
            Image(systemName: "slider.horizontal.3")
                .font(AppTheme.controlFont)
                .frame(width: AppTheme.minimumTarget, height: AppTheme.minimumTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("工作流设置")
        .accessibilityFocused($accessibilityFocus, equals: .workflows)
        .disabled(processingWorkflowID != nil)
    }

    private func workflowButton(for workflow: Workflow, focused: Bool = false) -> some View {
        Button {
            handleWorkflowTap(workflow)
        } label: {
            HStack(spacing: 8) {
                if visibleLoadingWorkflowID == workflow.id {
                    ProgressView()
                } else {
                    Image(systemName: workflow.icon).font(AppTheme.controlFont)
                }
                if focused {
                    Text(workflow.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .foregroundStyle(focused ? Color.white : Color.primary)
            .tint(focused ? Color.white : AppTheme.controlColor)
            .padding(.horizontal, focused ? 16 : 0)
            .frame(width: focused ? nil : AppTheme.minimumTarget, height: AppTheme.minimumTarget)
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
        .accessibilityValue(visibleLoadingWorkflowID == workflow.id ? "正在运行工作流" : (focused ? "专注模式" : ""))
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
                        set: { noteStore.updateDraftText($0) }
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
            .frame(maxWidth: AppTheme.readingWidth, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)

            // Wait for the first load so the hint doesn't flash before existing records arrive.
            if !isFocusMode && draftText.isEmpty && noteStore.hasLoadedNotes && !noteStore.hasSavedItems {
                VStack(alignment: .leading, spacing: 4) {
                    Text("草稿随输入自动保存。添加“保存记录”步骤后，就能在记录列表中回顾。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("添加保存步骤") { isWorkflowSettingsPresented = true }
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: AppTheme.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func workflowActionHint(for workflow: Workflow) -> String {
        if draftText.isEmpty && workflow.nodes.contains(where: { $0.isEnabled && $0.type == .httpPost }) {
            return "草稿为空，将向接收端发送回车指令"
        }
        return "运行后清空输入框，可继续写下一条"
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
            guard !Task.isCancelled, !isNoteLibraryPresented, !isAgentChatPresented, !isPresentingSheet else { return }
            isTextEditorFocused = true
            
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, !isNoteLibraryPresented, !isAgentChatPresented, !isPresentingSheet else { return }
            if !isTextEditorFocused {
                isTextEditorFocused = true
            }
            
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, !isNoteLibraryPresented, !isAgentChatPresented, !isPresentingSheet else { return }
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

    private func openNoteLibrary(searchText: String = "") {
        if noteStore.isUsingLocalFallback || noteStore.hasPendingICloudDownloads {
            noteStore.refreshFromEnvironment()
        } else {
            noteStore.loadItemsIfNeeded()
        }
        noteSearchText = searchText
        isTextEditorFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            isNoteLibraryPresented = true
        }
    }

    private func clearText() {
        let announcement = canRestoreDraft ? "已\(clearDraftLabel)" : "已\(clearDraftLabel)，可以撤销"
        if canRestoreDraft {
            if noteStore.hasLastClearedText {
                interruptDraftInputSession()
            }
            noteStore.restoreLastClearedDraft()
        } else {
            if !draftText.isEmpty {
                interruptDraftInputSession()
            }
            noteStore.clearDraft()
        }
        showStatus(announcement)
    }

    private func enterFocusMode(_ workflow: Workflow, fromLongPress: Bool = false) {
        guard workflow.kind == .manual, processingWorkflowID == nil else { return }
        suppressNextWorkflowTap = fromLongPress
        focusedWorkflowIDRaw = workflow.id.uuidString
    }

    private func exitFocusMode(fromLongPress: Bool = false) {
        guard isFocusMode, processingWorkflowID == nil else { return }
        if fromLongPress {
            suppressNextWorkflowTap = true
        }
        focusedWorkflowIDRaw = ""
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
            if !selectedTags.isEmpty {
                noteStore.clearDraft()
            }
            enqueueSend {
                await sendReturnKey(for: workflow)
            }
            return
        }

        interruptDraftInputSession()

        if draftText.hasPrefix("打开调试模式") {
            noteStore.clearDraft()
            isDebugPresented = true
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
        noteStore.clearDraft()
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
        processingWorkflowID = workflow.id
        visibleLoadingWorkflowID = nil
        workflowLoadingTask?.cancel()
        workflowLoadingTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard processingWorkflowID == workflow.id else { return }
                visibleLoadingWorkflowID = workflow.id
            }
        }

        defer {
            workflowLoadingTask?.cancel()
            workflowLoadingTask = nil
            visibleLoadingWorkflowID = nil
            processingWorkflowID = nil
        }

        do {
            let result = try await workflowManager.execute(
                workflowID: workflow.id,
                input: input,
                tags: tags
            )

            if result.shouldSave {
                if draftText.isEmpty {
                    performSave(text: result.finalText, tags: result.tags)
                } else {
                    noteStore.addRecord(result.finalText, tags: result.tags)
                }
            }
            showStatus(result.didCopyToClipboard ? "“\(workflow.name)”已完成，文本已复制到剪贴板。" : "“\(workflow.name)”已完成。")
            return true
        } catch {
            workflowErrorTitle = "“\(workflow.name)”未完成"
            workflowError = error
            if draftText.isEmpty {
                noteStore.restoreLastClearedDraft()
            }
            workflowErrorContext = draftText == input ? "原文已恢复到输入框。" : ""
            if workflowManager.currentNodeIndex > 0 {
                workflowErrorContext += "前面的步骤可能已完成，请检查结果后再运行。"
            }
            showWorkflowError = true
            return false
        }
    }
    
    private func performSave(text: String, tags: [String]) {
        noteStore.updateDraftText(text)
        noteStore.replaceDraftTags(tags)
        noteStore.finalizeDraft()
    }

    private func interruptDraftInputSession() {
        inputSessionResetToken &+= 1
    }
}

/// Keeps the pushed screen's initializer out of QuickCaptureView's update path. QuickCaptureView
/// re-evaluates on every keystroke; these wrappers only rebuild when their inputs change.
private struct NoteLibraryDestination: View, Equatable {
    let initialSearchText: String

    var body: some View {
        NoteLibraryView(initialSearchText: initialSearchText)
            .background { RootReturnButtonBehavior() }
    }
}

private struct AgentChatDestination: View, Equatable {
    var body: some View {
        AgentChatView()
            .background { RootReturnButtonBehavior() }
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
        textView.accessibilityHint = "内容随输入自动保存"
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

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        coordinator.cancelPendingUpdates()
        uiView.delegate = nil
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

        /// 中文九宫格会忽略 `reloadInputViews()`；在 SwiftUI 更新完成后短暂交接 first responder，确保键盘更新回车键样式。
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

        func cancelPendingUpdates() {
            focusUpdateGeneration &+= 1
            keyboardRefreshGeneration &+= 1
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
    QuickCaptureView()
}
