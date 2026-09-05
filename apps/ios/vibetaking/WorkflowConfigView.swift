import SwiftUI

private enum WorkflowConfigPresentation: Identifiable {
    case addNode
    case editNode(UUID)
    case iconPicker(UUID)

    var id: String {
        switch self {
        case .addNode:
            "add-node"
        case .editNode(let id):
            "edit-node-\(id.uuidString)"
        case .iconPicker(let id):
            "icon-picker-\(id.uuidString)"
        }
    }
}

private enum WorkflowToolbarIdentity {
    static let editButton = "workflow-edit-button"
}

private struct WorkflowEditButton: View {
    @Environment(\.editMode) private var editMode

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing == true
    }

    var body: some View {
        Button(isEditing ? "完成" : "编辑") {
            withAnimation {
                editMode?.wrappedValue = isEditing ? .inactive : .active
            }
        }
        .tint(Design.primaryColor)
        .id(WorkflowToolbarIdentity.editButton)
    }
}

private struct WorkflowEditToolbarItem: ToolbarContent {
    let isVisible: Bool

    init(isVisible: Bool = true) {
        self.isVisible = isVisible
    }

    var body: some ToolbarContent {
        ToolbarItem(id: WorkflowToolbarIdentity.editButton, placement: .topBarTrailing) {
            if isVisible {
                WorkflowEditButton()
            }
        }
    }
}

private enum WorkflowConfigStyle {
    static let controlTint = Design.primaryColor
    static let selectedForeground = Color.white
    static let nodeBadgeFill = Design.primaryColor.opacity(0.10)
}

struct WorkflowConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var workflowToDelete: Workflow?
    @State private var nodeOffsetsToDelete = IndexSet()
    @State private var confirmNodeDeletion = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var workflowManager = WorkflowManager.shared
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    @State private var compactPath: [UUID] = []
    @State private var detailWorkflowId: UUID?
    @State private var presentation: WorkflowConfigPresentation?

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactWorkflowNavigation
            } else {
                regularWorkflowSplitView
            }
        }
        .alert(item: $workflowToDelete) { workflow in
            Alert(
                title: Text("删除“\(displayName(for: workflow))”？"),
                message: Text("此工作流及其步骤将被删除，记录内容不受影响。"),
                primaryButton: .destructive(Text("删除工作流")) {
                    workflowManager.deleteWorkflow(workflow.id)
                    compactPath.removeAll { $0 == workflow.id }
                    detailWorkflowId = workflowManager.selectedWorkflowId
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .confirmationDialog("删除所选步骤？", isPresented: $confirmNodeDeletion, titleVisibility: .visible) {
            Button("删除步骤", role: .destructive) {
                workflowManager.deleteNodes(at: nodeOffsetsToDelete)
                nodeOffsetsToDelete = []
            }
            Button("取消", role: .cancel) { nodeOffsetsToDelete = [] }
        } message: {
            Text("删除后，此工作流将不再执行这些步骤。")
        }
        .sheet(item: $presentation) { item in
            presentationView(for: item)
        }
        .onAppear {
            ensureSelection()
            resetNavigationForCurrentSizeClass()
        }
        .onChange(of: horizontalSizeClass) { _, _ in
            resetNavigationForCurrentSizeClass()
        }
        .onChange(of: workflowManager.selectedWorkflowId) { oldValue, _ in
            if let oldValue {
                normalizeWorkflowName(oldValue)
            }
        }
        .onDisappear {
            normalizeWorkflowNames()
        }
    }

    private var regularWorkflowSplitView: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            workflowSidebar
        } detail: {
            if let workflow = detailWorkflow {
                workflowDetail(for: workflow)
            } else {
                ContentUnavailableView("选择一个工作流", systemImage: "arrow.triangle.branch")
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var compactWorkflowNavigation: some View {
        NavigationStack(path: $compactPath) {
            compactWorkflowList
                .navigationDestination(for: UUID.self) { workflowID in
                    if let workflow = workflowManager.workflows.first(where: { $0.id == workflowID }) {
                        workflowDetail(for: workflow)
                            .onAppear {
                                activateWorkflowDetail(workflow.id)
                            }
                    } else {
                        ContentUnavailableView("工作流已被删除", systemImage: "exclamationmark.triangle")
                    }
                }
        }
    }

    private var compactWorkflowList: some View {
        List {
            Section {
                ForEach(workflowManager.openWorkflows) { workflow in
                    NavigationLink(value: workflow.id) {
                        WorkflowSidebarRow(workflow: workflow)
                    }
                    .contextMenu { workflowContextMenu(for: workflow) }
                }
                .onMove { workflowManager.moveWorkflows(inOpenState: true, from: $0, to: $1) }
            } header: {
                Text("主页显示")
            }

            if !workflowManager.closedWorkflows.isEmpty {
                Section {
                    ForEach(workflowManager.closedWorkflows) { workflow in
                        NavigationLink(value: workflow.id) {
                            WorkflowSidebarRow(workflow: workflow)
                        }
                        .contextMenu { workflowContextMenu(for: workflow) }
                    }
                    .onMove { workflowManager.moveWorkflows(inOpenState: false, from: $0, to: $1) }
                } header: {
                    Text("不显示")
                }
            }

            Section {
                Button {
                    addWorkflow()
                } label: {
                    Label("新建工作流", systemImage: "plus.circle.fill")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("工作流")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            WorkflowEditToolbarItem()
        }
    }

    private var detailWorkflow: Workflow? {
        guard let detailWorkflowId else { return nil }
        return workflowManager.workflows.first { $0.id == detailWorkflowId }
    }

    private var workflowSelection: Binding<UUID?> {
        Binding {
            detailWorkflowId
        } set: { newValue in
            guard let newValue else { return }
            selectWorkflowForEditing(newValue)
        }
    }

    private var workflowSidebar: some View {
        List(selection: workflowSelection) {
            Section {
                ForEach(workflowManager.openWorkflows) { workflow in
                    NavigationLink(value: workflow.id) {
                        WorkflowSidebarRow(workflow: workflow)
                    }
                    .tag(workflow.id)
                    .contextMenu { workflowContextMenu(for: workflow) }
                }
                .onMove { workflowManager.moveWorkflows(inOpenState: true, from: $0, to: $1) }
            } header: {
                Text("主页显示")
            }

            if !workflowManager.closedWorkflows.isEmpty {
                Section {
                    ForEach(workflowManager.closedWorkflows) { workflow in
                        NavigationLink(value: workflow.id) {
                            WorkflowSidebarRow(workflow: workflow)
                        }
                        .tag(workflow.id)
                        .contextMenu { workflowContextMenu(for: workflow) }
                    }
                    .onMove { workflowManager.moveWorkflows(inOpenState: false, from: $0, to: $1) }
                } header: {
                    Text("不显示")
                }
            }

            Section {
                Button {
                    addWorkflow()
                } label: {
                    Label("新建工作流", systemImage: "plus.circle.fill")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("工作流")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            WorkflowEditToolbarItem()
        }
    }

    private func workflowDetail(for workflow: Workflow) -> some View {
        List {
            Section {
                workflowHeader(for: workflow)
            }

            manualWorkflowEditor(for: workflow)
        }
        .listStyle(.insetGrouped)
        .navigationTitle(displayName(for: workflow))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            WorkflowEditToolbarItem(isVisible: !workflow.nodes.isEmpty)
        }
    }

    @ViewBuilder
    private func workflowHeader(for workflow: Workflow) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
            layout {
                Button {
                    presentation = .iconPicker(workflow.id)
                } label: {
                    Image(systemName: workflow.icon)
                        .font(.title.weight(.medium))
                        .foregroundStyle(WorkflowConfigStyle.controlTint)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更换图标")

                VStack(alignment: .leading, spacing: 6) {
                    TextField("工作流名称", text: workflowNameBinding(for: workflow.id))
                        .font(.title3.weight(.semibold))
                        .textFieldStyle(.plain)
                        .submitLabel(.done)
                        .onSubmit { normalizeWorkflowName(workflow.id) }

                    Text(workflowSummary(for: workflow))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle("在主页显示", isOn: Binding(
                get: { workflow.isOpen },
                set: { value in
                    if value != workflow.isOpen { workflowManager.toggleWorkflowOpen(workflow.id) }
                }
            ))
            .disabled(workflow.isOpen && !workflowManager.canCloseWorkflow(workflow.id))

            if workflow.isOpen && !workflowManager.canCloseWorkflow(workflow.id) {
                Text("主页至少保留一个工作流。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Menu { workflowContextMenu(for: workflow) } label: {
                Label("工作流操作", systemImage: "ellipsis.circle")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func manualWorkflowEditor(for workflow: Workflow) -> some View {
        Section {
            if workflow.nodes.isEmpty {
                EmptyWorkflowNodesView {
                    presentation = .addNode
                }
            } else {
                ForEach(Array(workflowManager.nodes.enumerated()), id: \.element.id) { index, node in
                    NodeRowView(
                        node: node,
                        position: index + 1,
                        onEdit: { presentation = .editNode(node.id) }
                    )
                }
                .onMove { workflowManager.moveNode(from: $0, to: $1) }
                .onDelete {
                    nodeOffsetsToDelete = $0
                    confirmNodeDeletion = true
                }
            }
        } header: {
            Text("处理步骤")
        } footer: {
            if !workflow.nodes.isEmpty {
                Text("步骤从上到下依次执行。点按步骤编辑，点按“编辑”调整顺序。")
            }
        }

        if !workflow.nodes.isEmpty {
            Section {
                Button {
                    presentation = .addNode
                } label: {
                    Label {
                        Text("添加步骤")
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "plus.circle.fill")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(WorkflowConfigStyle.controlTint)
                    }
                }
                .tint(WorkflowConfigStyle.controlTint)
            }
        }
    }

    @ViewBuilder
    private func workflowContextMenu(for workflow: Workflow) -> some View {
        Button {
            workflowManager.toggleWorkflowOpen(workflow.id)
        } label: {
            Label(workflow.isOpen ? "从主页隐藏" : "显示到主页", systemImage: workflow.isOpen ? "eye.slash" : "eye")
        }
        .disabled(!workflowManager.canCloseWorkflow(workflow.id))

        Button {
            presentation = .iconPicker(workflow.id)
        } label: {
            Label("更换图标", systemImage: "square.grid.2x2")
        }

        if workflowManager.canDuplicateWorkflow(workflow.id) {
            Button {
                workflowManager.duplicateWorkflow(workflow.id)
            } label: {
                Label("创建副本", systemImage: "doc.on.doc")
            }
        }

        if workflowManager.canDeleteWorkflow(workflow.id) {
            Divider()
            Button(role: .destructive) {
                workflowToDelete = workflow
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func presentationView(for item: WorkflowConfigPresentation) -> some View {
        switch item {
        case .addNode:
            AddNodeSheet()
        case .editNode(let nodeID):
            if let node = workflowManager.nodes.first(where: { $0.id == nodeID }) {
                EditNodeSheet(node: node)
            } else {
                NavigationStack {
                    ContentUnavailableView("步骤已被删除", systemImage: "exclamationmark.triangle")
                        .navigationTitle("编辑步骤")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium])
            }
        case .iconPicker(let workflowID):
            IconPickerView(selectedIcon: iconName(for: workflowID)) { newIcon in
                updateWorkflow(workflowID) { workflow in
                    workflow.icon = newIcon
                }
            }
        }
    }

    private func workflowSummary(for workflow: Workflow) -> String {
        let visibility = workflow.isOpen ? "主页显示" : "未在主页显示"

        let enabledCount = workflow.nodes.filter { $0.isEnabled }.count
        let totalCount = workflow.nodes.count
        return "\(visibility) · \(enabledCount)/\(totalCount) 步骤启用"
    }

    private func displayName(for workflow: Workflow) -> String {
        let trimmed = workflow.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名工作流" : trimmed
    }

    private func iconName(for workflowID: UUID) -> String {
        workflowManager.workflows.first { $0.id == workflowID }?.icon ?? "arrow.triangle.branch"
    }

    private func workflowNameBinding(for workflowID: UUID) -> Binding<String> {
        Binding {
            workflowManager.workflows.first { $0.id == workflowID }?.name ?? ""
        } set: { newValue in
            updateWorkflow(workflowID) { workflow in
                workflow.name = newValue
            }
        }
    }

    private func addWorkflow() {
        let count = workflowManager.workflows.count + 1
        let workflow = Workflow(name: "工作流 \(count)", kind: .manual)
        workflowManager.addWorkflow(workflow)
        selectWorkflowForEditing(workflow.id)
        if horizontalSizeClass == .compact {
            compactPath = [workflow.id]
        }
    }

    private func updateWorkflow(_ workflowID: UUID, mutate: (inout Workflow) -> Void) {
        guard var workflow = workflowManager.workflows.first(where: { $0.id == workflowID }) else { return }
        mutate(&workflow)
        workflowManager.updateWorkflow(workflow)
    }

    private func ensureSelection() {
        if let selectedWorkflowId = workflowManager.selectedWorkflowId,
           workflowManager.workflows.contains(where: { $0.id == selectedWorkflowId }) {
            return
        }

        if let firstWorkflowId = workflowManager.workflows.first?.id {
            workflowManager.selectWorkflow(firstWorkflowId)
        }
    }

    private func selectWorkflowForEditing(_ workflowID: UUID) {
        activateWorkflowDetail(workflowID)
        showWorkflowDetailInCompact()
    }

    private func activateWorkflowDetail(_ workflowID: UUID) {
        detailWorkflowId = workflowID
        workflowManager.selectWorkflow(workflowID)
    }

    private func resetNavigationForCurrentSizeClass() {
        guard horizontalSizeClass == .compact else {
            detailWorkflowId = workflowManager.selectedWorkflowId ?? workflowManager.workflows.first?.id
            return
        }

        compactPath = []
        detailWorkflowId = nil
        preferredCompactColumn = .sidebar
    }

    private func showWorkflowDetailInCompact() {
        guard horizontalSizeClass == .compact else { return }
        preferredCompactColumn = .detail
    }

    private func normalizeWorkflowName(_ workflowID: UUID) {
        updateWorkflow(workflowID) { workflow in
            let trimmed = workflow.name.trimmingCharacters(in: .whitespacesAndNewlines)
            workflow.name = trimmed.isEmpty ? "未命名工作流" : trimmed
        }
    }

    private func normalizeWorkflowNames() {
        for workflow in workflowManager.workflows {
            normalizeWorkflowName(workflow.id)
        }
    }
}

private struct WorkflowSidebarRow: View {
    let workflow: Workflow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: workflow.icon)
                .font(.body.weight(.medium))
                .foregroundStyle(iconColor)
                .frame(width: 24)

            Text(displayName)
                .font(.body)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private var displayName: String {
        let trimmed = workflow.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名工作流" : trimmed
    }

    private var iconColor: Color {
        .primary
    }
}

private struct EmptyWorkflowNodesView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("还没有步骤")
                    .font(.headline)
                Text("添加步骤来定义草稿的处理方式。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                onAdd()
            } label: {
                Label("添加步骤", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(WorkflowConfigStyle.controlTint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}


struct NodeRowView: View {
    let node: WorkflowNode
    let position: Int
    let onEdit: () -> Void
    @State private var workflowManager = WorkflowManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                HStack(alignment: .top, spacing: 12) {
                    Text(position.formatted())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(minWidth: 24, minHeight: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        Label(node.type.displayName, systemImage: node.type.icon)
                            .font(.body)
                            .foregroundStyle(Color.primary)
                        if let detail = nodeDetail {
                            Text(detail).font(.subheadline).foregroundStyle(Color.secondary).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(node.type == .copyToClipboard || node.type == .save ? "查看" : "编辑")第 \(position) 步，\(node.type.displayName)")

            Toggle("启用步骤", isOn: Binding(
                get: { node.isEnabled },
                set: { value in
                    var updated = node
                    updated.isEnabled = value
                    workflowManager.updateNode(updated)
                }
            ))
            .labelsHidden()
            .accessibilityLabel("启用第 \(position) 步，\(node.type.displayName)")
        }
        .padding(.vertical, 4)
    }

    private var nodeDetail: String? {
        if !node.isEnabled {
            return "已关闭"
        }

        if node.type == .aiProcess, let prompt = node.config.aiPrompt, !prompt.isEmpty {
            return prompt
        }

        if node.type == .agentProcess, let prompt = node.config.agentPrompt, !prompt.isEmpty {
            return prompt
        }

        if node.type == .httpPost {
            if let serviceName = node.config.httpServiceName, !serviceName.isEmpty {
                return serviceName
            }
            let host = node.config.httpHost ?? "localhost"
            let port = node.config.httpPort ?? 9999
            return "\(host):\(port)"
        }

        return nil
    }
}


struct AddNodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var workflowManager = WorkflowManager.shared

    var body: some View {
        NavigationStack {
            List {
                ForEach(WorkflowNodeType.allCases, id: \.self) { type in
                    Button {
                        let newNode = WorkflowNode(type: type)
                        workflowManager.addNode(newNode)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(type.displayName, systemImage: type.icon).font(.body)
                            Text(type.explanation).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("添加\(type.displayName)步骤")
                    .accessibilityHint(type.explanation)
                }
            }
            .listStyle(.insetGrouped)
            .tint(WorkflowConfigStyle.controlTint)
            .navigationTitle("添加步骤")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .tint(Design.primaryColor)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}


struct EditNodeSheet: View {
    let node: WorkflowNode
    @Environment(\.dismiss) private var dismiss
    @State private var workflowManager = WorkflowManager.shared
    @State private var aiPrompt: String = ""
    @State private var agentPrompt: String = ""
    @State private var httpHost: String = ""
    @State private var httpPort: String = ""
    @State private var boundServiceName: String?
    @State private var deviceResolutionTask: Task<Void, Never>?
    @State private var isResolvingDevice = false
    @State private var resolutionError: String?

    private var hasEditableConfiguration: Bool {
        node.type != .copyToClipboard && node.type != .save
    }

    private var isValid: Bool {
        guard !isResolvingDevice else { return false }
        if node.type == .aiProcess {
            return !aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if node.type == .agentProcess {
            return !agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard node.type == .httpPost, boundServiceName == nil else { return true }
        guard let port = Int(httpPort.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return HTTPTargetURL.make(host: httpHost, port: port) != nil
    }


    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(node.type.displayName, systemImage: node.type.icon)
                    Text(node.type.explanation).font(.subheadline).foregroundStyle(.secondary)
                }
                if node.type == .aiProcess {
                    Section("AI 提示词") {
                        TextEditor(text: $aiPrompt)
                            .font(.body)
                            .frame(minHeight: 140)
                            .accessibilityLabel("AI 提示词")
                    }
                }

                if node.type == .agentProcess {
                    Section {
                        TextEditor(text: $agentPrompt)
                            .font(.body)
                            .frame(minHeight: 140)
                            .accessibilityLabel("助手指令")
                    } header: {
                        Text("助手指令")
                    } footer: {
                        Text("AI 助手可调用工具完成任务，最终结果传给下一步。")
                    }
                }

                if node.type == .httpPost {
                    DeviceBindingSection(
                        boundServiceName: boundServiceName,
                        onSelect: { device in
                            deviceResolutionTask?.cancel()
                            boundServiceName = device.serviceName
                            isResolvingDevice = true
                            resolutionError = nil
                            deviceResolutionTask = Task { @MainActor in
                                let resolved = await BonjourResolver.resolve(serviceName: device.serviceName)
                                guard !Task.isCancelled, boundServiceName == device.serviceName else { return }
                                isResolvingDevice = false
                                if let resolved {
                                    httpHost = resolved.host
                                    httpPort = "\(resolved.port)"
                                } else {
                                    resolutionError = "暂时无法连接此设备。保存后，发送时会重新查找。"
                                }
                            }
                        },
                        onUnbind: {
                            deviceResolutionTask?.cancel()
                            isResolvingDevice = false
                            resolutionError = nil
                            boundServiceName = nil
                        }
                    )

                    if isResolvingDevice { ProgressView("正在连接设备…") }
                    if let resolutionError {
                        Label(resolutionError, systemImage: "exclamationmark.circle").font(.footnote)
                    }
                    if boundServiceName == nil {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("主机地址").font(.subheadline).foregroundStyle(.secondary)
                                TextField("例如：192.168.1.10", text: $httpHost)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.URL)
                                    .accessibilityLabel("主机地址")
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("端口").font(.subheadline).foregroundStyle(.secondary)
                                TextField("9999", text: $httpPort)
                                    .keyboardType(.numberPad)
                                    .accessibilityLabel("端口")
                            }
                        } header: {
                            Text("HTTP 配置")
                        } footer: {
                            Text(isValid ? "未绑定设备时，内容发送到此地址。" : "填写主机名或 IP 地址（不含 http:// 和路径），以及 1–65535 之间的端口。")
                        }
                    }
                }

            }
            .navigationTitle(hasEditableConfiguration ? "编辑步骤" : "步骤详情")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .onDisappear { deviceResolutionTask?.cancel() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if hasEditableConfiguration { Button("取消") { dismiss() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if hasEditableConfiguration {
                        Button("保存") { saveChanges() }
                            .disabled(!isValid)
                            .fontWeight(.semibold)
                    } else {
                        Button("完成") { dismiss() }.fontWeight(.semibold)
                    }
                }
            }
            .onAppear {
                aiPrompt = node.config.aiPrompt ?? ""
                agentPrompt = node.config.agentPrompt ?? ""
                httpHost = node.config.httpHost ?? "localhost"
                httpPort = "\(node.config.httpPort ?? 9999)"
                boundServiceName = node.config.httpServiceName
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func saveChanges() {
        guard isValid else { return }
        var updated = node
        updated.config.aiPrompt = aiPrompt.isEmpty ? nil : aiPrompt
        updated.config.agentPrompt = agentPrompt.isEmpty ? nil : agentPrompt
        updated.config.httpHost = httpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : httpHost.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.config.httpPort = Int(httpPort.trimmingCharacters(in: .whitespacesAndNewlines))
        updated.config.httpServiceName = boundServiceName
        workflowManager.updateNode(updated)
        dismiss()
    }
}

struct DeviceBindingSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let boundServiceName: String?
    let onSelect: (DiscoveredDevice) -> Void
    let onUnbind: () -> Void

    @Bindable private var discovery = DeviceDiscoveryManager.shared

    var body: some View {
        Section {
            if let boundServiceName {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    Image(systemName: "laptopcomputer")
                        .foregroundStyle(WorkflowConfigStyle.controlTint)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(boundServiceName)
                            .font(.callout.weight(.medium))
                        Text(isBoundDeviceOnline ? "在线" : "离线，发送时自动重连")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("解除绑定", role: .destructive, action: onUnbind)
                        .font(.body)
                        .frame(minHeight: 44)
                        .buttonStyle(.borderless)
                }
            }

            if candidates.isEmpty && boundServiceName == nil {
                discoveryEmptyState
            }

            ForEach(candidates) { device in
                Button {
                    onSelect(device)
                } label: {
                    Label(device.serviceName, systemImage: "laptopcomputer")
                        .foregroundStyle(.primary)
                }
            }
        } header: {
            Text("附近设备")
        } footer: {
            Text("需要 Mac 端应用已运行，且两台设备连接同一网络。首次使用会请求「本地网络」权限。")
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private var candidates: [DiscoveredDevice] {
        discovery.devices.filter { $0.serviceName != boundServiceName }
    }

    private var isBoundDeviceOnline: Bool {
        discovery.devices.contains { $0.serviceName == boundServiceName }
    }

    @ViewBuilder
    private var discoveryEmptyState: some View {
        switch discovery.status {
        case .idle, .searching:
            HStack(spacing: 10) {
                ProgressView()
                Text("正在查找附近的 Mac…")
                    .foregroundStyle(.secondary)
            }
        case .ready:
            VStack(alignment: .leading, spacing: 6) {
                Text("未找到 Mac")
                    .font(.callout)
                Text("请确认 Mac 已打开随心记，且两台设备在同一 Wi‑Fi。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text("无法搜索附近设备")
                    .font(.callout)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("请在「设置 → 隐私与安全性 → 本地网络」中允许随心记访问。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}


struct IconPickerView: View {
    @ScaledMetric(relativeTo: .title2) private var iconSize = 52.0

    let selectedIcon: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private let icons: [(category: String, symbols: [String])] = [
        ("常用", [
            "arrow.triangle.branch", "bolt", "wand.and.stars",
            "sparkles", "gearshape", "terminal",
            "text.bubble", "envelope", "paperplane",
            "doc.text", "folder", "tray.full",
            "square.and.arrow.up", "square.and.arrow.down", "arrow.right.circle",
            "arrow.2.circlepath", "arrow.up.forward.app", "play",
            "stop", "forward", "backward",
            "arrow.clockwise", "arrow.counterclockwise", "arrow.triangle.2.circlepath"
        ]),
        ("工作", [
            "briefcase", "chart.bar", "calendar",
            "clock", "flag", "bookmark",
            "link", "network", "externaldrive",
            "server.rack", "cpu", "memorychip",
            "desktopcomputer", "laptopcomputer", "printer",
            "doc.richtext", "doc.append", "list.bullet.clipboard",
            "chart.pie", "chart.line.uptrend.xyaxis", "building.2",
            "banknote", "creditcard", "cart"
        ]),
        ("创意", [
            "paintbrush", "pencil.and.outline", "scissors",
            "wand.and.rays", "camera", "photo",
            "music.note", "film", "theatermasks",
            "lightbulb", "star", "heart",
            "paintpalette", "eyedropper.halffull", "swatchpalette",
            "pianokeys", "guitars", "music.mic",
            "photo.on.rectangle.angled", "camera.aperture", "wand.and.stars.inverse",
            "sparkle", "flame", "leaf"
        ]),
        ("沟通", [
            "bubble.left", "bubble.left.and.bubble.right",
            "phone", "video", "mic",
            "megaphone", "bell", "hand.wave",
            "person", "person.2", "globe",
            "antenna.radiowaves.left.and.right",
            "bubble.middle.bottom", "ellipsis.bubble",
            "phone.arrow.up.right", "envelope.open",
            "person.3", "person.crop.circle",
            "shared.with.you", "hand.thumbsup", "hand.raised",
            "ear", "eye", "mouth"
        ]),
        ("符号", [
            "checkmark.seal", "xmark.octagon",
            "exclamationmark.triangle", "info.circle",
            "questionmark.circle", "plus.circle",
            "minus.circle", "shuffle",
            "repeat", "infinity", "number",
            "equal.circle", "lessthan.circle", "greaterthan.circle",
            "chevron.left.forwardslash.chevron.right", "curlybraces",
            "at", "hashtag", "percent", "textformat"
        ]),
        ("自然与天气", [
            "sun.max", "moon", "cloud",
            "cloud.rain", "cloud.bolt", "snowflake",
            "wind", "tornado", "rainbow",
            "drop", "leaf", "tree",
            "mountain.2", "water.waves", "sun.haze"
        ]),
        ("出行与地图", [
            "car", "bus", "tram",
            "airplane", "ferry", "bicycle",
            "figure.walk", "figure.run", "map",
            "mappin.and.ellipse", "location", "compass.drawing",
            "fuelpump", "ev.charger", "parkingsign"
        ]),
        ("安全与隐私", [
            "lock", "lock.open", "key",
            "shield", "shield.checkered", "lock.shield",
            "faceid", "touchid", "opticid",
            "eye.slash", "hand.raised.slash", "exclamationmark.lock"
        ]),
        ("健康与生活", [
            "heart.text.square", "cross.case", "pills",
            "bed.double", "cup.and.saucer", "fork.knife",
            "house", "sofa", "washer",
            "dumbbell", "sportscourt", "figure.yoga",
            "pawprint", "gift", "party.popper"
        ])
    ]

    private var filteredIcons: [(category: String, symbols: [String])] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let available = icons.map { group in
            (category: group.category, symbols: group.symbols.filter { UIImage(systemName: $0) != nil })
        }
        guard !trimmed.isEmpty else { return available }
        return available.compactMap { group in
            let filtered = group.symbols.filter {
                group.category.localizedStandardContains(trimmed)
                    || $0.lowercased().contains(trimmed)
                    || symbolLabel($0).localizedStandardContains(trimmed)
            }
            return filtered.isEmpty ? nil : (group.category, filtered)
        }
    }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: iconSize), spacing: 12)] }

    private func symbolLabel(_ symbol: String) -> String {
        let names = ["arrow.triangle.branch": "工作流", "bolt": "闪电", "sparkles": "星光", "gearshape": "设置", "terminal": "终端", "text.bubble": "文字气泡", "envelope": "信封", "paperplane": "发送", "doc.text": "文档", "folder": "文件夹", "tray.full": "收件箱", "play": "播放", "stop": "停止", "briefcase": "公文包", "chart.bar": "统计", "calendar": "日历", "clock": "时钟", "flag": "旗帜", "bookmark": "书签", "link": "链接", "network": "网络", "laptopcomputer": "笔记本电脑", "desktopcomputer": "台式电脑", "camera": "相机", "photo": "照片", "music.note": "音乐", "lightbulb": "灯泡", "star": "星星", "heart": "爱心", "phone": "电话", "video": "视频", "mic": "麦克风", "bell": "铃铛", "person": "人物", "globe": "地球", "shuffle": "随机", "sun.max": "太阳", "moon": "月亮", "cloud": "云", "leaf": "叶子", "lock": "锁", "key": "钥匙", "shield": "盾牌", "house": "房屋", "gift": "礼物"]
        return names[symbol] ?? symbol.replacingOccurrences(of: ".", with: " ")
    }


    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(filteredIcons, id: \.category) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.category)
                                .font(.footnote.bold())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(group.symbols, id: \.self) { symbol in
                                    let isSelected = symbol == selectedIcon
                                    Button {
                                        onSelect(symbol)
                                        dismiss()
                                    } label: {
                                        Image(systemName: symbol)
                                            .font(.title2)
                                            .frame(maxWidth: .infinity, minHeight: iconSize)
                                            .foregroundStyle(isSelected ? WorkflowConfigStyle.selectedForeground : .primary)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(isSelected ? WorkflowConfigStyle.controlTint : Color(.tertiarySystemFill))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .overlay(alignment: .topTrailing) {
                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.caption)
                                                .foregroundStyle(.white, Design.primaryColor)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    .accessibilityLabel("\(group.category)，\(symbolLabel(symbol))")
                                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .overlay {
                if filteredIcons.isEmpty {
                    ContentUnavailableView("没有匹配的图标", systemImage: "magnifyingglass",
                                           description: Text("试试其他图标名称或类别。"))
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("选择图标")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索图标名称")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                        .tint(Design.primaryColor)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemGroupedBackground))
    }
}

private extension WorkflowNodeType {
    var explanation: String {
        switch self {
        case .aiProcess: "根据提示词处理文本，把结果交给下一步。"
        case .agentProcess: "让 AI 助手结合笔记和工具完成任务。"
        case .copyToClipboard: "将当前文本复制到系统剪贴板，供其他 App 粘贴。"
        case .save: "将处理后的文本和草稿标签保存到记录中。"
        case .httpPost: "将文本发送到同一网络中的 Mac 或指定地址。"
        }
    }
}
