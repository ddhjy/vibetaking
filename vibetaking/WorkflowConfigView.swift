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
        .tint(.primary)
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
    static let controlTint = Color(.label)
    static let selectedForeground = Color(.systemBackground)
    static let nodeBadgeFill = Color(.label).opacity(0.10)
}

struct WorkflowConfigView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var workflowManager = WorkflowManager.shared
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    @State private var compactPath: [UUID] = []
    @State private var detailWorkflowId: UUID?
    @State private var presentation: WorkflowConfigPresentation?
    @State private var syncWarningWorkflowId: UUID?

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactWorkflowNavigation
            } else {
                regularWorkflowSplitView
            }
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
                ContentUnavailableView("未选择 Workflow", systemImage: "arrow.triangle.branch")
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
                        ContentUnavailableView("Workflow 已不存在", systemImage: "exclamationmark.triangle")
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
                    Label("新建 Workflow", systemImage: "plus.circle.fill")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Workflow")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
                    Label("新建 Workflow", systemImage: "plus.circle.fill")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Workflow")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            WorkflowEditToolbarItem()
        }
    }

    private func workflowDetail(for workflow: Workflow) -> some View {
        List {
            Section {
                workflowHeader(for: workflow)
            }

            if workflow.kind == .autoPasteSync {
                autoPasteSyncEditor(for: workflow)
            } else {
                manualWorkflowEditor(for: workflow)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(displayName(for: workflow))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            WorkflowEditToolbarItem(isVisible: workflow.kind == .manual)
        }
    }

    @ViewBuilder
    private func workflowHeader(for workflow: Workflow) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Button {
                    presentation = .iconPicker(workflow.id)
                } label: {
                    Image(systemName: workflow.icon)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(WorkflowConfigStyle.controlTint)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更换图标")

                VStack(alignment: .leading, spacing: 6) {
                    TextField("Workflow 名称", text: workflowNameBinding(for: workflow.id))
                        .font(.title3.weight(.semibold))
                        .textFieldStyle(.plain)
                        .submitLabel(.done)
                        .onSubmit { normalizeWorkflowName(workflow.id) }

                    Text(workflowSummary(for: workflow))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 10) {
                Button {
                    workflowManager.toggleWorkflowOpen(workflow.id)
                } label: {
                    Label(workflow.isOpen ? "从主页隐藏" : "显示到主页", systemImage: workflow.isOpen ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
                .tint(WorkflowConfigStyle.controlTint)
                .disabled(!workflowManager.canCloseWorkflow(workflow.id))

                Menu {
                    workflowContextMenu(for: workflow)
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .buttonStyle(.bordered)
                .tint(WorkflowConfigStyle.controlTint)
            }
            .labelStyle(.titleAndIcon)
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
                .onDelete { workflowManager.deleteNodes(at: $0) }
            }
        } header: {
            Text("节点流水线")
        } footer: {
            Text("执行时按从上到下顺序运行，可进入编辑模式拖动排序或删除。")
        }

        Section {
            Button {
                presentation = .addNode
            } label: {
                Label {
                    Text("添加节点")
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

    @ViewBuilder
    private func autoPasteSyncEditor(for workflow: Workflow) -> some View {
        let host = workflow.syncConfig.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsHost = host.isEmpty

        Section {
            Toggle("开启同步", isOn: autoPasteActiveBinding(for: workflow.id))
                .tint(WorkflowConfigStyle.controlTint)

            TextField("AutoPaste 主机地址", text: autoPasteHostBinding(for: workflow.id))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            TextField("AutoPaste 端口", value: autoPastePortBinding(for: workflow.id), format: .number)
                .keyboardType(.numberPad)
        } header: {
            Text("同步配置")
        } footer: {
            Text("主页点亮后会实时同步当前草稿，并接收远端清空指令。同一时间只允许一个 Auto Paste 开启同步、一个显示在主页。")
        }

        Section {
            HStack(spacing: 10) {
                Image(systemName: needsHost ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(needsHost ? .orange : WorkflowConfigStyle.controlTint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(needsHost ? "未配置目标" : "\(host):\(workflow.syncConfig.port)")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    Text(needsHost ? "填写主机地址后才能开启同步" : "当前同步目标")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("目标预览")
        }

        if syncWarningWorkflowId == workflow.id && needsHost {
            Section {
                Label("请先填写 AutoPaste 主机地址", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
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
                withAnimation {
                    workflowManager.deleteWorkflow(workflow.id)
                }
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
                    ContentUnavailableView("节点已不存在", systemImage: "exclamationmark.triangle")
                        .navigationTitle("编辑节点")
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

        if workflow.kind == .autoPasteSync {
            let state = workflow.isActive ? "同步已开启" : "同步已关闭"
            let host = workflow.syncConfig.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = host.isEmpty ? "未配置目标" : "\(host):\(workflow.syncConfig.port)"
            return "\(visibility) · \(state) · \(target)"
        }

        let enabledCount = workflow.nodes.filter { $0.isEnabled }.count
        let totalCount = workflow.nodes.count
        return "\(visibility) · \(enabledCount)/\(totalCount) 节点启用"
    }

    private func displayName(for workflow: Workflow) -> String {
        let trimmed = workflow.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名 Workflow" : trimmed
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

    private func autoPasteActiveBinding(for workflowID: UUID) -> Binding<Bool> {
        Binding {
            workflowManager.workflows.first { $0.id == workflowID }?.isActive ?? false
        } set: { newValue in
            let workflow = workflowManager.workflows.first { $0.id == workflowID }
            let isActive = workflow?.isActive ?? false
            guard isActive != newValue else { return }

            if newValue {
                let host = workflow?.syncConfig.host.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !host.isEmpty else {
                    syncWarningWorkflowId = workflowID
                    return
                }
            }

            syncWarningWorkflowId = nil
            workflowManager.toggleWorkflowActive(workflowID)
        }
    }

    private func autoPasteHostBinding(for workflowID: UUID) -> Binding<String> {
        Binding {
            workflowManager.workflows.first { $0.id == workflowID }?.syncConfig.host ?? ""
        } set: { newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                syncWarningWorkflowId = nil
            }
            workflowManager.updateAutoPasteSyncConfig(workflowID: workflowID, host: newValue)
        }
    }

    private func autoPastePortBinding(for workflowID: UUID) -> Binding<Int> {
        Binding {
            workflowManager.workflows.first { $0.id == workflowID }?.syncConfig.port ?? 7788
        } set: { newValue in
            workflowManager.updateAutoPasteSyncConfig(workflowID: workflowID, port: newValue)
        }
    }

    private func addWorkflow() {
        let count = workflowManager.workflows.count + 1
        let workflow = Workflow(name: "Workflow \(count)", kind: .manual)
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
            workflow.name = trimmed.isEmpty ? "未命名 Workflow" : trimmed
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
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 24)

            Text(displayName)
                .font(.callout)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var displayName: String {
        let trimmed = workflow.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名 Workflow" : trimmed
    }

    private var iconColor: Color {
        if workflow.kind == .autoPasteSync && workflow.isActive {
            return WorkflowConfigStyle.controlTint
        }
        return .primary
    }
}

private struct EmptyWorkflowNodesView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("还没有节点")
                    .font(.headline)
                Text("添加节点后，这个 Workflow 会按顺序处理当前草稿。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                onAdd()
            } label: {
                Label("添加节点", systemImage: "plus.circle.fill")
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
            Text("\(position)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(node.isEnabled ? WorkflowConfigStyle.controlTint : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(node.isEnabled ? WorkflowConfigStyle.nodeBadgeFill : Color(.tertiarySystemFill))
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: node.type.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(node.isEnabled ? .primary : .secondary)
                        .frame(width: 18)

                    Text(node.type.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(node.isEnabled ? .primary : .secondary)
                }

                if let detail = nodeDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { node.isEnabled },
                set: { newValue in
                    var updated = node
                    updated.isEnabled = newValue
                    workflowManager.updateNode(updated)
                }
            ))
            .labelsHidden()
            .tint(WorkflowConfigStyle.controlTint)
        }
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(position). \(node.type.displayName)")
    }

    private var nodeDetail: String? {
        if !node.isEnabled {
            return "已停用"
        }

        if node.type == .aiProcess, let prompt = node.config.aiPrompt, !prompt.isEmpty {
            return prompt
        }

        if node.type == .httpPost {
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
                        HStack(spacing: 12) {
                            Image(systemName: type.icon)
                                .font(.system(size: 18))
                                .foregroundStyle(.primary)
                                .frame(width: 28)
                            Text(type.displayName)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .tint(WorkflowConfigStyle.controlTint)
            .navigationTitle("添加节点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .tint(.primary)
                }
            }
        }
        .presentationDetents([.medium])
    }
}


struct EditNodeSheet: View {
    let node: WorkflowNode
    @Environment(\.dismiss) private var dismiss
    @State private var workflowManager = WorkflowManager.shared
    @State private var aiPrompt: String = ""
    @State private var httpHost: String = ""
    @State private var httpPort: String = ""

    var body: some View {
        NavigationStack {
            Form {
                if node.type == .aiProcess {
                    Section("提示词") {
                        TextField("输入 AI 提示词", text: $aiPrompt, axis: .vertical)
                            .lineLimit(5...)
                    }
                }

                if node.type == .httpPost {
                    Section {
                        TextField("主机地址", text: $httpHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("端口", text: $httpPort)
                            .keyboardType(.numberPad)
                    } header: {
                        Text("HTTP 配置")
                    } footer: {
                        Text("内容将发送到以下地址")
                    }
                }

            }
            .navigationTitle("编辑节点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .tint(.primary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { saveChanges() }
                        .fontWeight(.semibold)
                        .tint(.primary)
                }
            }
            .onAppear {
                aiPrompt = node.config.aiPrompt ?? ""
                httpHost = node.config.httpHost ?? "localhost"
                httpPort = "\(node.config.httpPort ?? 9999)"
            }
        }
        .presentationDetents([.medium])
    }

    private func saveChanges() {
        var updated = node
        updated.config.aiPrompt = aiPrompt.isEmpty ? nil : aiPrompt
        updated.config.httpHost = httpHost.isEmpty ? nil : httpHost
        updated.config.httpPort = Int(httpPort)
        workflowManager.updateNode(updated)
        dismiss()
    }
}


struct IconPickerView: View {
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
            "fuelpump", "ev.charger", "parking"
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
        guard !trimmed.isEmpty else { return icons }
        return icons.compactMap { group in
            let filtered = group.symbols.filter { $0.lowercased().contains(trimmed) }
            return filtered.isEmpty ? nil : (group.category, filtered)
        }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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
                                            .font(.system(size: 22))
                                            .frame(width: 48, height: 48)
                                            .foregroundStyle(isSelected ? WorkflowConfigStyle.selectedForeground : .primary)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(isSelected ? WorkflowConfigStyle.controlTint : Color(.tertiarySystemFill))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("选择图标")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索图标名称")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                        .tint(.primary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
