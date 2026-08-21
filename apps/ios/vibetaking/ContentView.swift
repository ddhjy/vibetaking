import SwiftUI

struct ContentView: View {
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
    @State private var inputSessionResetToken = 0

    @AppStorage("focusedWorkflowID") private var focusedWorkflowIDRaw: String = ""
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
                    Menu {
                        Button {
                            isTextEditorFocused = false
                            showAgentChat = true
                        } label: {
                            Label("AI 助手", systemImage: "sparkles")
                        }

                        Divider()

                        Button {
                            showSettings = true
                        } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                    } label: {
                        AppToolbarMoreLabel()
                    }
                    .accessibilityLabel("更多")
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
            .sheet(isPresented: $showTagSelector) {
                TagPickerView(itemId: historyManager.currentDraft.id, reselectMode: true)
            }
            .sheet(isPresented: $showDebugView) {
                DebugView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showWorkflowConfig) {
                WorkflowConfigView()
            }
            .sheet(item: Binding(
                get: { OffloadPermissionManager.shared.pendingRequest },
                set: { newValue in
                    if newValue == nil, let current = OffloadPermissionManager.shared.pendingRequest {
                        OffloadPermissionManager.shared.respond(to: current.id, allowed: false)
                    }
                }
            )) { request in
                OffloadPermissionDialog(request: request)
            }
            .alert("处理失败", isPresented: $showWorkflowError) {
                Button("好") { workflowError = nil }
            } message: {
                Text(workflowError?.localizedDescription ?? "请检查网络后再试一次")
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
    
    private var focusTransition: Animation {
        .spring(response: 0.32, dampingFraction: 0.9)
    }

    private var accessoryTransition: AnyTransition {
        .scale(scale: 0.55).combined(with: .opacity)
    }

    private var bottomToolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                workflowControlGroup

                if !isFocusMode, !tagManager.tags.isEmpty {
                    tagButton
                        .transition(accessoryTransition)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isFocusMode {
                Button("搜索", systemImage: "magnifyingglass", action: searchDraftInHistory)
                    .labelStyle(.iconOnly)
                    .tint(.primary)
                    .padding(14)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .disabled(processingWorkflowId != nil)
                    .transition(accessoryTransition)
            }

            clearDraftButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(focusTransition, value: isFocusMode)
        .sensoryFeedback(.impact(weight: .medium), trigger: isFocusMode)
    }

    /// 右侧始终是清除草稿；退出专注改由长按 Workflow 完成。
    private var clearDraftButton: some View {
        Button(action: clearText) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 20, height: 20)
        }
        .tint(.primary)
        .padding(14)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("清除")
        .disabled(processingWorkflowId != nil)
    }

    /// 同一颗胶囊就地变宽、上色；不再用 glassEffectID 做跨视图形变。
    private var workflowControlGroup: some View {
        HStack(spacing: 4) {
            if !isFocusMode {
                workflowSettingsButton
                    .transition(accessoryTransition)
            }

            ForEach(workflowManager.openWorkflows) { workflow in
                if !isFocusMode || focusedWorkflow?.id == workflow.id {
                    workflowButton(for: workflow)
                        .transition(accessoryTransition)
                }
            }
        }
        .padding(.horizontal, isFocusMode ? 16 : 7)
        .frame(maxWidth: isFocusMode ? .infinity : nil)
        .frame(height: isFocusMode ? 56 : 46)
        .glassEffect(
            isFocusMode
                ? .regular.tint(Color.black).interactive()
                : .regular.interactive(),
            in: Capsule()
        )
    }

    @ViewBuilder
    private func workflowGlyph(for workflow: Workflow, focused: Bool) -> some View {
        Group {
            if visibleLoadingWorkflowId == workflow.id {
                ProgressView()
                    .tint(focused ? .white : .primary)
                    .scaleEffect(focused ? 1 : 0.8)
            } else {
                Image(systemName: workflow.icon)
                    .font(.system(size: 18, weight: .medium))
            }
        }
        .frame(width: 20, height: 20)
        .scaleEffect(focused ? 1.15 : 1)
    }

    @ViewBuilder
    private var tagButton: some View {
        if selectedTags.isEmpty {
            Button(action: { showTagSelector = true }) {
                Image(systemName: "tag")
                    .font(.system(size: 18))
                    .frame(width: 20, height: 20)
            }
        .tint(.primary)
        .padding(14)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("标签")
        .disabled(processingWorkflowId != nil)
        } else {
            Button(action: { showTagSelector = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "tag")
                        .font(.system(size: 18))
                    
                    let tagFont: Font = selectedTags.count == 1 ? .footnote : .caption
                    
                    VStack(alignment: .leading, spacing: 1) {
                        if let first = selectedTags.first {
                            Text(first)
                                .font(tagFont)
                                .lineLimit(1)
                        }
                        if selectedTags.count >= 2 {
                            HStack(spacing: 3) {
                                Text(selectedTags[1])
                                    .font(tagFont)
                                    .lineLimit(1)
                                if selectedTags.count > 2 {
                                    Text("+\(selectedTags.count - 2)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(height: 20)
            }
            .tint(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityLabel("标签")
            .disabled(processingWorkflowId != nil)
        }
    }
    
    private var workflowSettingsButton: some View {
        Button {
            showWorkflowConfig = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 20, height: 20)
        }
        .tint(.primary)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .accessibilityLabel("工作流设置")
        .disabled(processingWorkflowId != nil)
    }
    
    private func workflowButton(for workflow: Workflow) -> some View {
        let focused = isFocusMode && focusedWorkflow?.id == workflow.id
        return Button {
            handleWorkflowTap(workflow)
        } label: {
            HStack(spacing: 10) {
                workflowGlyph(for: workflow, focused: focused)
                if focused {
                    Text(workflow.name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(focused ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            .frame(width: focused ? nil : 44, height: focused ? 56 : 44)
            .frame(maxWidth: focused ? .infinity : nil)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tint(workflowTintColor(for: workflow))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                if isFocusMode {
                    exitFocusMode(fromLongPress: true)
                } else {
                    enterFocusMode(workflow)
                }
            }
        )
        .accessibilityLabel(focused ? "\(workflow.name)，专注模式" : workflowAccessibilityLabel(for: workflow))
        .accessibilityHint(focused ? "长按退出专注模式" : "长按进入专注模式")
    }
    
    private var fullScreenEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if draftText.isEmpty {
                    Text("开始输入...")
                        .font(.body)
                        .foregroundStyle(Color(.placeholderText))
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
                    font: UIFont.systemFont(ofSize: 17, weight: .regular)
                )
                .padding(.horizontal, 16)
            }
            .frame(maxHeight: .infinity)
        }
    }
    
    private func scheduleKeyboardShow(delay: Double) {
        keyboardTask?.cancel()
        
        keyboardTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, !showHistory else { return }
            isTextEditorFocused = true
            
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, !showHistory else { return }
            if !isTextEditorFocused {
                isTextEditorFocused = true
            }
            
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, !showHistory else { return }
            if !isTextEditorFocused {
                isTextEditorFocused = true
            }
        }
    }
    
    private func navigateToHistory(searchText: String = "") {
        historyManager.loadItemsIfNeeded()
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
        if draftText.isEmpty {
            if historyManager.hasLastClearedText {
                interruptDraftInputSession()
                historyManager.restoreLastClearedDraft()
            } else {
                historyManager.clearDraftTags()
            }
        } else {
            interruptDraftInputSession()
            historyManager.clearDraft()
        }
    }
    
    private func enterFocusMode(_ workflow: Workflow) {
        guard workflow.kind == .manual, processingWorkflowId == nil else { return }
        suppressNextWorkflowTap = true
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
            _ = try await workflowManager.sendReturnKey(workflowID: workflow.id)
            return true
        } catch {
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
            return true
        } catch {
            workflowError = error
            showWorkflowError = true
            if draftText.isEmpty {
                historyManager.restoreLastClearedDraft()
            }
            return false
        }
    }
    
    private func workflowTintColor(for workflow: Workflow) -> Color {
        if processingWorkflowId == workflow.id {
            return Design.primaryColor
        }

        return .primary
    }

    private func workflowAccessibilityLabel(for workflow: Workflow) -> String {
        workflow.name
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
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = font
        textView.text = text
        textView.isScrollEnabled = isScrollEnabled
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.resetInputSessionIfNeeded(on: uiView)
        context.coordinator.syncTextIfNeeded(on: uiView)
        uiView.font = font
        uiView.isScrollEnabled = isScrollEnabled

        if isFocused && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
        
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
        
        init(_ parent: DraftTextView) {
            self.parent = parent
            self.lastText = parent.text
            self.lastInputSessionResetToken = parent.inputSessionResetToken
        }

        func resetInputSessionIfNeeded(on textView: UITextView) {
            guard lastInputSessionResetToken != parent.inputSessionResetToken else { return }

            lastInputSessionResetToken = parent.inputSessionResetToken
            shouldPreferLegacyTextSync = true
        }

        func syncTextIfNeeded(on textView: UITextView) {
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
        
        func textViewDidChange(_ textView: UITextView) {
            lastText = textView.text
            parent.text = textView.text
        }
        
        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused {
                parent.isFocused = true
            }
        }
        
        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused {
                parent.isFocused = false
            }
        }
    }
}


#Preview {
    ContentView()
}
