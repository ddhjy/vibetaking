import SwiftUI
import UniformTypeIdentifiers

struct ShakeDetectorView: UIViewControllerRepresentable {
    let onShake: () -> Void
    
    func makeUIViewController(context: Context) -> ShakeDetectorViewController {
        let controller = ShakeDetectorViewController()
        controller.onShake = onShake
        return controller
    }
    
    func updateUIViewController(_ uiViewController: ShakeDetectorViewController, context: Context) {
        uiViewController.onShake = onShake
    }
}

class ShakeDetectorViewController: UIViewController {
    var onShake: (() -> Void)?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        becomeFirstResponder()
    }
    
    override var canBecomeFirstResponder: Bool { true }
    
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            onShake?()
        }
    }
}

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var historyManager = HistoryManager.shared
    @State private var showClearConfirmation = false
    @State private var copiedItemId: UUID?
    @State private var isEditMode = false
    @State private var selectedItems: Set<UUID> = []
    @State private var selectedTags: [TagSelection] = []
    @State private var tagPickerItem: HistoryItem? = nil
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var showImportPicker = false
    @State private var importAlert: ImportAlert? = nil
    @State private var exportedFileURL: URL? = nil
    @State private var searchText = ""
    @State private var committedSearchText = ""
    @State private var isSearchTextComposing = false
    @State private var isSearchActive = false
    @State private var searchUpdateWorkItem: DispatchWorkItem?
    @State private var showStatistics = false
    @State private var showBatchTagPicker = false
    @State private var isRandomMode = false
    @State private var listProjectionID = UUID()
    @State private var listCache = HistoryListCache()
    @State private var showBatchCopiedToast = false
    @State private var batchCopiedCount: Int = 0
    @State private var batchCopyToastWorkItem: DispatchWorkItem?
    @State private var isRebuildingCache = false
    @State private var rebuildToken = UUID()
    @State private var mediumHapticTrigger = 0
    
    private static let importableContentTypes: [UTType] = [
        .zip,
        .folder,
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "markdown") ?? .plainText
    ]
    
    private struct ImportAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    
    nonisolated private struct HistoryListCache: Sendable {
        var savedItems: [HistoryItem] = []
        var searchFilteredItems: [HistoryItem] = []
        var filteredItems: [HistoryItem] = []
        var displayedItems: [HistoryItem] = []
        var searchTagCounts: [String: Int] = [:]
        var searchNoTagCount: Int = 0
        var searchTagSet: Set<String> = []
        
        private static func tokenize(_ searchText: String) -> [String] {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
        }
        
        private static func matchesSelections(item: HistoryItem, selections: [TagSelection]) -> Bool {
            for selection in selections {
                if selection.isNoTagSelection {
                    switch selection.state {
                    case .positive:
                        if !item.tags.isEmpty { return false }
                    case .negative:
                        if item.tags.isEmpty { return false }
                    }
                } else {
                    switch selection.state {
                    case .positive:
                        if !item.tags.contains(selection.tag) { return false }
                    case .negative:
                        if item.tags.contains(selection.tag) { return false }
                    }
                }
            }
            return true
        }
        
        static func build(
            items: [HistoryItem],
            searchText: String,
            selectedTags: [TagSelection],
            isRandomMode: Bool
        ) -> HistoryListCache {
            let savedItems = items.filter { !$0.isDraft }
            
            let searchFilteredItems: [HistoryItem]
            let tokens = tokenize(searchText)
            if tokens.isEmpty {
                searchFilteredItems = savedItems
            } else {
                searchFilteredItems = savedItems.filter { item in
                    tokens.allSatisfy { token in
                        let textMatch = item.text.localizedStandardContains(token)
                        let tagMatch = item.tags.contains { $0.localizedStandardContains(token) }
                        return textMatch || tagMatch
                    }
                }
            }
            
            let filteredItems: [HistoryItem]
            if selectedTags.isEmpty {
                filteredItems = searchFilteredItems
            } else {
                filteredItems = searchFilteredItems.filter { item in
                    matchesSelections(item: item, selections: selectedTags)
                }
            }
            
            let displayedItems: [HistoryItem]
            if isRandomMode {
                displayedItems = filteredItems.shuffled()
            } else {
                displayedItems = filteredItems
            }
            
            var tagCounts: [String: Int] = [:]
            var noTagCount = 0
            for item in searchFilteredItems {
                if item.tags.isEmpty { noTagCount += 1 }
                for tag in item.tags {
                    tagCounts[tag, default: 0] += 1
                }
            }
            
            return HistoryListCache(
                savedItems: savedItems,
                searchFilteredItems: searchFilteredItems,
                filteredItems: filteredItems,
                displayedItems: displayedItems,
                searchTagCounts: tagCounts,
                searchNoTagCount: noTagCount,
                searchTagSet: Set(tagCounts.keys)
            )
        }
    }
    
    init(initialSearchText: String = "") {
        let trimmedSearchText = initialSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        _searchText = State(initialValue: trimmedSearchText)
        _committedSearchText = State(initialValue: trimmedSearchText)
        _listCache = State(initialValue: HistoryListCache.build(
            items: HistoryManager.shared.items,
            searchText: trimmedSearchText,
            selectedTags: [],
            isRandomMode: false
        ))
    }

    private var effectiveSearchText: String {
        committedSearchText
    }

    private var searchPrompt: String {
        isSearchActive ? "多个关键词用空格分隔" : "搜索内容或标签"
    }
    
    private func rebuildListCacheAsync() {
        let token = UUID()
        rebuildToken = token
        isRebuildingCache = true

        let itemsSnapshot = historyManager.items
        let searchTextSnapshot = effectiveSearchText
        let selectedTagsSnapshot = selectedTags
        let randomModeSnapshot = isRandomMode

        Task.detached(priority: .userInitiated) {
            let cache = HistoryListCache.build(
                items: itemsSnapshot,
                searchText: searchTextSnapshot,
                selectedTags: selectedTagsSnapshot,
                isRandomMode: randomModeSnapshot
            )

            await MainActor.run { [self] in
                guard self.rebuildToken == token else { return }
                self.listCache = cache
                self.isRebuildingCache = false
            }
        }
    }

    private func matchesSelections(item: HistoryItem, selections: [TagSelection]) -> Bool {
        for selection in selections {
            if selection.isNoTagSelection {
                switch selection.state {
                case .positive:
                    if !item.tags.isEmpty { return false }
                case .negative:
                    if item.tags.isEmpty { return false }
                }
            } else {
                switch selection.state {
                case .positive:
                    if !item.tags.contains(selection.tag) { return false }
                case .negative:
                    if item.tags.contains(selection.tag) { return false }
                }
            }
        }
        return true
    }

    private func applyListProjectionImmediately() {
        let baseItems = listCache.searchFilteredItems
        let filteredItems: [HistoryItem]

        if selectedTags.isEmpty {
            filteredItems = baseItems
        } else {
            filteredItems = baseItems.filter { item in
                matchesSelections(item: item, selections: selectedTags)
            }
        }

        let displayedItems: [HistoryItem]
        if isRandomMode {
            displayedItems = filteredItems.shuffled()
        } else {
            displayedItems = filteredItems
        }

        var cache = listCache
        cache.filteredItems = filteredItems
        cache.displayedItems = displayedItems
        listCache = cache
        listProjectionID = UUID()
        if isRebuildingCache {
            // Refresh the in-flight search with the latest filter instead of letting
            // an older query result replace the new projection.
            rebuildListCacheAsync()
        }
    }
    
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            
            if (historyManager.isLoading || isRebuildingCache) && listCache.savedItems.isEmpty {
                loadingStateView
            } else if listCache.savedItems.isEmpty {
                emptyStateView
            } else {
                historyContent
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if historyManager.isUsingLocalFallback {
                iCloudUnavailableBanner
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: mediumHapticTrigger)
        .overlay(alignment: .top) {
            if showBatchCopiedToast {
                Text("已复制 \(batchCopiedCount) 条")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityLabel("已复制 \(batchCopiedCount) 条记录")
            }
        }
        .background {
            ShakeDetectorView {
                handleShake()
            }
        }
        .navigationTitle(isEditMode ? "已选择 \(selectedItems.count) 条" : "记录")
        .navigationBarTitleDisplayMode(isEditMode ? .inline : .large)
        .toolbar {
            ToolbarItem(id: AppToolbarIdentity.moreButton, placement: .topBarTrailing) {
                if isEditMode && !listCache.savedItems.isEmpty {
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isEditMode = false
                            selectedItems.removeAll()
                        }
                    }) {
                        Text("完成").fontWeight(.semibold)
                    }
                } else {
                    Menu {
                        Button(action: { showImportPicker = true }) {
                            Label("导入", systemImage: "square.and.arrow.down")
                        }
                        .disabled(isImporting || historyManager.isLoading)
                        
                        if !listCache.savedItems.isEmpty {
                            Divider()
                            
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    isEditMode = true
                                }
                            }) {
                                Label("选择记录", systemImage: "checkmark.circle")
                            }
                            
                            Button("随机回顾", systemImage: "shuffle") { randomizeDisplayOrder() }

                            Button(action: { showStatistics = true }) {
                                Label("统计", systemImage: "chart.bar")
                            }
                            
                            Button(action: exportNotes) {
                                Label("导出", systemImage: "square.and.arrow.up")
                            }
                            .disabled(isExporting)
                        }
                    } label: {
                        AppToolbarMoreLabel(isLoading: isExporting || isImporting)
                    }
                    .accessibilityLabel("更多")
                    .id(AppToolbarIdentity.moreButton)
                }
            }
            
            ToolbarItemGroup(placement: .bottomBar) {
                if isEditMode {
                    let selectableIDs = Set(listCache.filteredItems.filter { !$0.isDownloading }.map(\.id))
                    let allSelected = !selectableIDs.isEmpty && selectableIDs.isSubset(of: selectedItems)
                    Button(action: {
                        if allSelected {
                            selectedItems.removeAll()
                        } else {
                            selectedItems = selectableIDs
                        }
                    }) {
                        Text(allSelected ? "取消全选" : "全选")
                            .font(.body)
                    }
                    .tint(Design.primaryColor)
                    .disabled(selectableIDs.isEmpty)
                    
                    Spacer()
                    
                    Button(action: copySelectedItems) {
                        Label("复制所选记录", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                    }
                    .tint(Design.primaryColor)
                    .disabled(selectedItems.isEmpty)

                    Button(action: { showBatchTagPicker = true }) {
                        Label("批量标签", systemImage: "tag").labelStyle(.iconOnly)
                    }
                    .tint(Design.primaryColor)
                    .disabled(selectedItems.isEmpty)

                    Button(action: { showClearConfirmation = true }) {
                        Label("删除所选记录", systemImage: "trash").labelStyle(.iconOnly)
                    }
                    .tint(Color(.systemRed))
                    .disabled(selectedItems.isEmpty)
                }
            }
        }
        .toolbar(isEditMode ? .visible : .hidden, for: .bottomBar)
        .onChange(of: isRandomMode) { _, _ in
            applyListProjectionImmediately()
        }
        .onChange(of: selectedTags) { _, _ in
            applyListProjectionImmediately()
        }
        .onChange(of: committedSearchText) { _, _ in
            rebuildListCacheAsync()
        }
        .onChange(of: historyManager.items) { _, _ in
            selectedItems.formIntersection(Set(historyManager.savedItems.map(\.id)))
            rebuildListCacheAsync()
        }
        .alert("删除这 \(selectedItems.count) 条记录？", isPresented: $showClearConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    deleteSelectedItems()
                }
            }
        } message: {
            Text("删除后不可恢复")
        }
        .sheet(item: $tagPickerItem) { item in
            TagPickerView(itemId: item.id)
        }
        .sheet(isPresented: $showBatchTagPicker) {
            BatchTagPickerView(itemIds: selectedItems)
        }
        .sheet(isPresented: Binding(
            get: { exportedFileURL != nil },
            set: { if !$0 { exportedFileURL = nil } }
        )) {
            if let url = exportedFileURL {
                ShareSheet(items: [url])
            }
        }
        .sheet(isPresented: $showStatistics) {
            StatisticsView(items: listCache.savedItems.filter { !$0.isDownloading })
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: Self.importableContentTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImportSelection(result)
        }
        .alert(item: $importAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .onAppear {
            if historyManager.isUsingLocalFallback || historyManager.hasPendingICloudDownloads {
                historyManager.refreshFromEnvironment()
            } else {
                historyManager.loadItemsIfNeeded()
            }
            rebuildListCacheAsync()

        }
    }
    
    private func deleteSelectedItems() {
        historyManager.deleteRecords(ids: selectedItems)
        selectedItems.removeAll()
        if historyManager.savedItems.isEmpty {
            isEditMode = false
        }
    }
    
    private func exportNotes() {
        isExporting = true
        
        Task {
            do {
                let url = try historyManager.exportAllNotes()
                isExporting = false
                exportedFileURL = url
            } catch {
                isExporting = false
                importAlert = ImportAlert(title: "导出失败", message: error.localizedDescription)
            }
        }
    }
    
    private func handleImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            importNotes(from: urls)
        case .failure(let error):
            importAlert = ImportAlert(title: "导入失败", message: error.localizedDescription)
        }
    }
    
    private func importNotes(from urls: [URL]) {
        isImporting = true
        
        Task {
            do {
                let result = try historyManager.importNotes(from: urls)
                isImporting = false
                rebuildListCacheAsync()
                showImportResult(result)
            } catch {
                isImporting = false
                importAlert = ImportAlert(title: "导入失败", message: error.localizedDescription)
                print("Import failed: \(error)")
            }
        }
    }
    
    private func showImportResult(_ result: NotesImportResult) {
        let skippedText = result.skippedCount > 0 ? "，跳过 \(result.skippedCount) 条重复或空记录" : ""
        
        if result.importedCount > 0 {
            importAlert = ImportAlert(
                title: "导入完成",
                message: "已导入 \(result.importedCount) 条记录\(skippedText)"
            )
        } else {
            importAlert = ImportAlert(
                title: "没有新内容",
                message: result.skippedCount > 0 ? "已跳过 \(result.skippedCount) 条重复或空记录" : "未找到可导入的记录"
            )
        }
    }
    
    private func handleSearchTextChange(_ newValue: String) {
        searchUpdateWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [newValue] in
            let responder = UIApplication.shared.currentFirstResponder()
            let textField = responder as? UITextField
            let hasMarkedText = textField?.markedTextRange != nil
            let isChineseInput = textField?.textInputMode?.primaryLanguage?.hasPrefix("zh") == true
            let containsHanCharacters = newValue.range(of: "\\p{Han}", options: .regularExpression) != nil
            let shouldDeferUpdate = hasMarkedText || (isChineseInput && !containsHanCharacters && !newValue.isEmpty)
            
            if isSearchTextComposing != shouldDeferUpdate {
                isSearchTextComposing = shouldDeferUpdate
            }
            
            guard !shouldDeferUpdate else { return }
            committedSearchText = newValue
        }
        
        searchUpdateWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func randomizeDisplayOrder() {
        isRandomMode = true
        applyListProjectionImmediately()
    }
    
    private func handleShake() {
        guard !listCache.savedItems.isEmpty, !isEditMode, !isSearchActive else { return }

        playDiceHaptics()
        
        if !selectedTags.isEmpty {
            selectedTags = []
        }
        randomizeDisplayOrder()
    }
    
    private func playDiceHaptics() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @ViewBuilder
    private var historyContent: some View {
        Group {
            if listCache.filteredItems.isEmpty {
                VStack(spacing: 0) {
                    if !effectiveSearchText.isEmpty {
                        searchEmptyStateView
                    } else {
                        filteredEmptyStateView
                    }
                }
            } else {
                historyList
            }
        }
        .overlay {
            SearchActiveDetector(isSearching: $isSearchActive)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            TagFilterBar(
                selectedTags: $selectedTags,
                isRandomMode: $isRandomMode,
                availableItems: listCache.searchFilteredItems,
                availableTagSet: listCache.searchTagSet,
                level0TagCounts: listCache.searchTagCounts,
                level0NoTagCount: listCache.searchNoTagCount,
                isSearching: isSearchActive,
                onRandomize: randomizeDisplayOrder
            )
            .background {
                Color.clear
                    .background(.bar)
            }
        }
        .searchable(text: $searchText, prompt: searchPrompt)
        .onChange(of: searchText) { _, newValue in
            handleSearchTextChange(newValue)
        }
        .onSubmit(of: .search) {
            searchUpdateWorkItem?.cancel()
            isSearchTextComposing = false
            committedSearchText = searchText
        }
    }
    
    private var loadingStateView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("加载中…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var iCloudUnavailableBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "icloud.slash")
                .font(.subheadline.weight(.semibold))
            Text("iCloud 暂时不可用，正在显示本地数据")
                .font(.footnote)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label(historyManager.isUsingLocalFallback ? "暂无本地记录" : "还没有记录", systemImage: "rectangle.stack")
        } description: {
            Text(historyManager.isUsingLocalFallback
                 ? "可以继续记录。iCloud 恢复后，云端记录会自动加载。"
                 : "写下想法后，运行包含“保存记录”步骤的工作流，即可在这里回顾。")
        } actions: {
            Button("开始记录") { dismiss() }.buttonStyle(.borderedProminent)
            Button("从文件导入", systemImage: "square.and.arrow.down") { showImportPicker = true }
                .buttonStyle(.bordered)
                .disabled(isImporting || historyManager.isLoading)
        }
    }

    private var filteredEmptyStateView: some View {
        ContentUnavailableView {
            Label("没有匹配的记录", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("试试减少筛选条件。")
        } actions: {
            Button("清除筛选") { selectedTags = [] }.buttonStyle(.bordered)
        }
    }

    private var searchEmptyStateView: some View {
        ContentUnavailableView {
            Label("没有搜索结果", systemImage: "magnifyingglass")
        } description: {
            Text("没有找到“\(effectiveSearchText)”的相关记录。试试其他关键词或清除筛选。")
        } actions: {
            Button("清除搜索与筛选") {
                searchText = ""
                committedSearchText = ""
                selectedTags = []
            }
            .buttonStyle(.bordered)
        }
    }

    private var historyList: some View {
        List {
            ForEach(listCache.displayedItems) { item in
                HistoryRowView(
                    item: item,
                    isCopied: copiedItemId == item.id,
                    isEditMode: isEditMode,
                    isSelected: selectedItems.contains(item.id),
                    filteredTags: selectedTags.filter { $0.state == .positive }.map { $0.tag },
                    searchText: effectiveSearchText,
                    onCopy: { copyItem(item) },
                    onToggleSelection: { toggleSelection(item) },
                    onTagTap: { if !item.isDownloading { tagPickerItem = item } },
                    onEdit: { isEditMode = true; selectedItems.insert(item.id) },
                    onDelete: { historyManager.deleteRecord(item) }
                )
                .id(item.id)
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .id(listProjectionID)
    }

    private func toggleSelection(_ item: HistoryItem) {
        guard !item.isDownloading else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            if selectedItems.contains(item.id) {
                selectedItems.remove(item.id)
            } else {
                selectedItems.insert(item.id)
            }
        }
    }
    
    private func copySelectedItems() {
        guard !selectedItems.isEmpty else { return }
        
        mediumHapticTrigger += 1
        
        let items = selectedHistoryItemsInCopyOrder()
        let text = buildBatchCopyText(items: items)
        
        guard !text.isEmpty else { return }
        
        UIPasteboard.general.string = text
        showBatchCopiedToast(count: items.count)
    }
    
    private func selectedHistoryItemsInCopyOrder() -> [HistoryItem] {
        let displayed = listCache.displayedItems.filter { selectedItems.contains($0.id) }
        let displayedIds = Set(displayed.map { $0.id })
        
        let remaining = historyManager.savedItems
            .filter { selectedItems.contains($0.id) && !displayedIds.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
        
        return displayed + remaining
    }
    
    private func buildBatchCopyText(items: [HistoryItem]) -> String {
        let separator = "\n\n---\n\n"
        return items
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }
    
    private func showBatchCopiedToast(count: Int) {
        batchCopiedCount = count
        UIAccessibility.post(notification: .announcement, argument: "已复制 \(count) 条记录")
        
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            showBatchCopiedToast = true
        }
        
        batchCopyToastWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.25)) {
                showBatchCopiedToast = false
            }
        }
        batchCopyToastWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: workItem)
    }
    
    private func copyItem(_ item: HistoryItem) {
        mediumHapticTrigger += 1
        
        UIPasteboard.general.string = item.text
        UIAccessibility.post(notification: .announcement, argument: "已复制记录")
        
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            copiedItemId = item.id
        }
        
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.3)) {
                if copiedItemId == item.id {
                    copiedItemId = nil
                }
            }
        }
    }
}

private struct SearchActiveDetector: View {
    @Binding var isSearching: Bool
    @Environment(\.isSearching) private var envIsSearching

    var body: some View {
        Color.clear
            .onChange(of: envIsSearching) { _, newValue in
                isSearching = newValue
            }
            .onAppear {
                isSearching = envIsSearching
            }
    }
}

private final class FirstResponderTracker {
    static weak var current: UIResponder?
}

private extension UIResponder {
    @objc func captureFirstResponder() {
        FirstResponderTracker.current = self
    }
}

private extension UIApplication {
    func currentFirstResponder() -> UIResponder? {
        FirstResponderTracker.current = nil
        sendAction(#selector(UIResponder.captureFirstResponder), to: nil, from: nil, for: nil)
        return FirstResponderTracker.current
    }
}

struct HistoryRowView: View {
    let item: HistoryItem
    let isCopied: Bool
    let isEditMode: Bool
    let isSelected: Bool
    var filteredTags: [String] = []
    var searchText = ""
    let onCopy: () -> Void
    let onToggleSelection: () -> Void
    let onTagTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var isExpanded = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        Group {
            if isEditMode {
                Button(action: onToggleSelection) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Design.primaryColor : Color.secondary)
                            .accessibilityHidden(true)
                        recordContent
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.isDownloading)
                .accessibilityValue(isSelected ? "已选择" : "未选择")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    recordContent.textSelection(.enabled)
                    if item.text.count > 200 {
                        Button(isExpanded ? "收起全文" : "展开全文") { isExpanded.toggle() }
                            .font(.subheadline)
                            .frame(minHeight: 44)
                            .buttonStyle(.borderless)
                    }
                    HStack(alignment: .center, spacing: 8) {
                        Button(action: onTagTap) {
                            Label(item.tags.isEmpty ? "添加标签" : item.tags.joined(separator: " · "), systemImage: "tag")
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .disabled(item.isDownloading)
                        .accessibilityLabel("编辑记录标签")
                        .accessibilityValue(item.tags.isEmpty ? "无标签" : item.tags.joined(separator: "、"))
                        Spacer(minLength: 0)
                        Menu { rowActions } label: {
                            Image(systemName: "ellipsis")
                                .font(Design.controlFont)
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("记录操作")
                    }
                }
                .contextMenu { rowActions }
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(isSelected ? Design.primaryColor.opacity(0.10) : Color(.secondarySystemGroupedBackground))
        .alert("删除这条记录？", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除记录", role: .destructive, action: onDelete)
        } message: {
            Text("删除后不可恢复。")
        }
    }

    private var recordContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if item.isDownloading && item.text.isEmpty {
                Label("正在从 iCloud 下载", systemImage: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
            } else {
                Text(highlightedText(isExpanded ? item.text : item.preview))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(item.formattedDate)
                    .accessibilityLabel(item.createdAt.formatted(date: .complete, time: .shortened))
                if item.isDownloading { ProgressView().accessibilityLabel("正在下载") }
                if isCopied { Label("已复制", systemImage: "checkmark") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var rowActions: some View {
        if !item.isDownloading {
            Button("复制记录", systemImage: "doc.on.doc", action: onCopy)
            Button("编辑标签", systemImage: "tag", action: onTagTap)
            Button("选择记录", systemImage: "checkmark.circle", action: onEdit)
        }
        Button("删除记录", systemImage: "trash", role: .destructive) { showDeleteConfirmation = true }
    }

    private func highlightedText(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let tokens = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
        for token in tokens {
            var start = text.startIndex
            while let range = text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
                if let attributedRange = Range(NSRange(range, in: text), in: result) {
                    result[attributedRange].backgroundColor = Design.primaryColor.opacity(0.16)
                    result[attributedRange].font = .body.bold()
                }
                start = range.upperBound
            }
        }
        return result
    }
}

#Preview {
    NavigationStack {
        HistoryView()
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct StatisticsView: View {
    @Environment(\.dismiss) private var dismiss
    let items: [HistoryItem]
    @State private var displayedMonth = Date()
    @State private var selectedDate: Date? = nil
    
    private let calendar = Calendar.current
    
    private var filteredItems: [HistoryItem] {
        guard let selectedDate = selectedDate else { return items }
        return items.filter { calendar.isDate($0.createdAt, inSameDayAs: selectedDate) }
    }
    
    private var totalRecords: Int {
        filteredItems.count
    }
    
    private var totalCharacters: Int {
        filteredItems.reduce(0) { $0 + $1.text.count }
    }
    
    private var tagStatistics: [(tag: String, count: Int)] {
        var tagCounts: [String: Int] = [:]
        for item in filteredItems {
            for tag in item.tags {
                tagCounts[tag, default: 0] += 1
            }
        }
        return tagCounts.map { ($0.key, $0.value) }
            .sorted { $0.count > $1.count }
    }
    
    private var untaggedCount: Int {
        filteredItems.filter { $0.tags.isEmpty }.count
    }
    
    private var recordsByDate: [Date: Int] {
        var counts: [Date: Int] = [:]
        for item in items {
            let dateOnly = calendar.startOfDay(for: item.createdAt)
            counts[dateOnly, default: 0] += 1
        }
        return counts
    }
    
    private var selectedDateString: String {
        guard let date = selectedDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    CalendarGridView(
                        displayedMonth: $displayedMonth,
                        selectedDate: $selectedDate,
                        recordsByDate: recordsByDate
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    if selectedDate != nil {
                        Button("查看全部日期") { selectedDate = nil }
                            .frame(minHeight: 44)
                    }
                } header: {
                    Text("记录日历")
                }
                
                Section {
                    HStack {
                        Label("记录数", systemImage: "doc.text")
                        Spacer()
                        Text("\(totalRecords)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("总字数", systemImage: "character.cursor.ibeam")
                        Spacer()
                        Text("\(totalCharacters)")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    if let _ = selectedDate {
                        Text("\(selectedDateString) 统计")
                    } else {
                        Text("总览")
                    }
                }
                
                if !tagStatistics.isEmpty || untaggedCount > 0 {
                    Section {
                        ForEach(tagStatistics, id: \.tag) { stat in
                            HStack {
                                Text(stat.tag)
                                Spacer()
                                Text("\(stat.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        if untaggedCount > 0 {
                            HStack {
                                Text("无标签")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(untaggedCount)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("标签统计")
                    }
                }
            }
            .navigationTitle("统计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
    }
}

struct CalendarGridView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var displayedMonth: Date
    @Binding var selectedDate: Date?
    let recordsByDate: [Date: Int]

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(minimum: 44), spacing: 0), count: 7)

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...]) + Array(symbols[..<offset])
    }

    private var daysInMonth: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth),
              let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) else { return [] }
        let offset = (calendar.component(.weekday, from: firstDay) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: offset) + range.map {
            calendar.date(byAdding: .day, value: $0 - 1, to: firstDay)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                Button("上个月", systemImage: "chevron.left") { changeMonth(by: -1) }
                    .labelStyle(.iconOnly)
                    .font(Design.controlFont)
                    .frame(width: 44, height: 44)
                Text(displayedMonth.formatted(.dateTime.year().month(dynamicTypeSize.isAccessibilitySize ? .abbreviated : .wide)))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                Button("下个月", systemImage: "chevron.right") { changeMonth(by: 1) }
                    .labelStyle(.iconOnly)
                    .font(Design.controlFont)
                    .frame(width: 44, height: 44)
            }
            if dynamicTypeSize.isAccessibilitySize {
                dateList
            } else {
                ViewThatFits(in: .horizontal) {
                    calendarGrid.frame(minWidth: 308)
                    dateList
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
    }

    private var calendarGrid: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol).font(.caption).foregroundStyle(.secondary)
                    .frame(minHeight: 28)
                    .accessibilityHidden(true)
            }
            ForEach(Array(daysInMonth.enumerated()), id: \.offset) { _, date in
                if let date {
                    let count = count(for: date)
                    let selected = isSelected(date)
                    Button { select(date) } label: {
                        VStack(spacing: 2) {
                            Text(date.formatted(.dateTime.day()))
                                .font(.callout.weight(calendar.isDateInToday(date) || selected ? .bold : .regular))
                            Circle()
                                .fill(count > 0 ? (selected ? Color.white : Design.primaryColor) : .clear)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(selected ? Color.white : (count > 0 ? Color.primary : Color.secondary))
                        .background(selected ? Design.primaryColor : .clear, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .disabled(count == 0)
                    .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                    .accessibilityValue("\(count) 条记录")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                } else {
                    Color.clear.frame(minHeight: 44).accessibilityHidden(true)
                }
            }
        }
    }

    private var dateList: some View {
        VStack(spacing: 0) {
            let dates = daysInMonth.compactMap { $0 }.filter { count(for: $0) > 0 }
            if dates.isEmpty {
                Text("本月还没有记录").foregroundStyle(.secondary).padding()
            }
            ForEach(dates, id: \.self) { date in
                Button { select(date) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(date.formatted(.dateTime.month().day().weekday(.wide)))
                            Text("\(count(for: date)) 条记录").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if isSelected(date) { Image(systemName: "checkmark").foregroundStyle(Design.primaryColor) }
                    }
                    .foregroundStyle(.primary)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(isSelected(date) ? .isSelected : [])
                Divider()
            }
        }
        .padding(.horizontal, 8)
    }

    private func count(for date: Date) -> Int { recordsByDate[calendar.startOfDay(for: date)] ?? 0 }
    private func isSelected(_ date: Date) -> Bool { selectedDate.map { calendar.isDate($0, inSameDayAs: date) } ?? false }
    private func select(_ date: Date) { selectedDate = isSelected(date) ? nil : calendar.startOfDay(for: date) }
    private func changeMonth(by offset: Int) {
        displayedMonth = calendar.date(byAdding: .month, value: offset, to: displayedMonth) ?? displayedMonth
        selectedDate = nil
    }
}
