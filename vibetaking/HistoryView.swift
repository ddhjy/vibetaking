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
    @State private var appearAnimation = false
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
    @State private var randomScrollTargetId: UUID? = nil
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
                displayedItems = filteredItems.sorted { $0.createdAt < $1.createdAt }
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
            displayedItems = filteredItems.sorted { $0.createdAt < $1.createdAt }
        } else {
            displayedItems = filteredItems
        }

        var cache = listCache
        cache.filteredItems = filteredItems
        cache.displayedItems = displayedItems
        listCache = cache
    }
    
    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
                .ignoresSafeArea()
            
            if (historyManager.isLoading || isRebuildingCache) && listCache.savedItems.isEmpty {
                loadingStateView
            } else if listCache.savedItems.isEmpty {
                emptyStateView
            } else {
                historyContent
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
                    .zIndex(999)
            }
        }
        .background {
            ShakeDetectorView {
                handleShake()
            }
        }
        .navigationTitle("随心记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(id: AppToolbarIdentity.moreButton, placement: .topBarTrailing) {
                if isEditMode && !listCache.savedItems.isEmpty {
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isEditMode = false
                            selectedItems.removeAll()
                        }
                    }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .regular))
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
                                Label("编辑", systemImage: "pencil")
                            }
                            
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
                if isEditMode && !selectedItems.isEmpty {
                    Button(action: {
                        if selectedItems.count == listCache.filteredItems.count {
                            selectedItems.removeAll()
                        } else {
                            selectedItems = Set(listCache.filteredItems.map { $0.id })
                        }
                    }) {
                        Text(selectedItems.count == listCache.filteredItems.count ? "取消全选" : "全选")
                            .font(.body)
                    }
                    .tint(Design.primaryColor)
                    
                    Spacer()
                    
                    Button(action: copySelectedItems) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 20))
                    }
                    .tint(Design.primaryColor)
                    
                    Button(action: { showBatchTagPicker = true }) {
                        Image(systemName: "tag")
                            .font(.system(size: 20))
                    }
                    .tint(Design.primaryColor)
                    
                    Button(action: { showClearConfirmation = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 20))
                    }
                    .tint(Color(.systemRed))
                }
            }
        }
        .toolbarBackgroundVisibility(.visible, for: .bottomBar)
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
            rebuildListCacheAsync()
        }
        .alert("删除 \(selectedItems.count) 条记录？", isPresented: $showClearConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    deleteSelectedItems()
                }
            }
        } message: {
            Text("删除后无法恢复")
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
            StatisticsView(items: listCache.savedItems)
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
            historyManager.loadItemsIfNeeded()
            rebuildListCacheAsync()
            withAnimation(.easeOut(duration: 0.4)) {
                appearAnimation = true
            }
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
                print("Export failed: \(error)")
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
                title: "没有新记录",
                message: result.skippedCount > 0 ? "已跳过 \(result.skippedCount) 条重复或空记录" : "没有找到可导入的内容"
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
        if !listCache.displayedItems.isEmpty {
            let randomIndex = Int.random(in: 0..<listCache.displayedItems.count)
            randomScrollTargetId = listCache.displayedItems[randomIndex].id
        }
    }
    
    private func handleShake() {
        guard !listCache.savedItems.isEmpty else { return }
        
        playDiceHaptics()
        
        if !selectedTags.isEmpty {
            selectedTags = []
        }
        randomizeDisplayOrder()
    }
    
    private func playDiceHaptics() {
        Task { @MainActor in
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.prepare()
            
            let steps: [(delay: Duration, intensity: CGFloat)] = [
                (.zero, 0.90),
                (.milliseconds(60), 0.55),
                (.milliseconds(60), 0.75),
                (.milliseconds(60), 0.50),
                (.milliseconds(60), 0.70),
                (.milliseconds(60), 0.45)
            ]
            
            for step in steps {
                if step.delay > .zero {
                    try? await Task.sleep(for: step.delay)
                }
                generator.impactOccurred(intensity: step.intensity)
            }
        }
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
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 100, height: 100)
                
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color(.secondaryLabel))
            }
            .opacity(appearAnimation ? 1 : 0)
            .scaleEffect(appearAnimation ? 1 : 0.8)
            
            VStack(spacing: 8) {
                Text("还没有记录")
                    .font(.title3.bold())
                    .foregroundStyle(Color(.label))
                
                Text("在主页写下内容，点击保存即可")
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryLabel))
            }
            .opacity(appearAnimation ? 1 : 0)
            .offset(y: appearAnimation ? 0 : 10)
            
            Button(action: { showImportPicker = true }) {
                Label("导入记录", systemImage: "square.and.arrow.down")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Design.primaryColor)
            .disabled(isImporting || historyManager.isLoading)
            .opacity(appearAnimation ? 1 : 0)
        }
        .padding(.horizontal, 40)
    }
    
    private var filteredEmptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tag.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color(.tertiaryLabel))
            
            Text("当前筛选下没有记录")
                .font(.callout)
                .foregroundStyle(Color(.secondaryLabel))
        }
        .frame(maxHeight: .infinity)
    }
    
    private var searchEmptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color(.tertiaryLabel))
            
            Text("没有找到「\(effectiveSearchText)」，试试其他关键词")
                .font(.callout)
                .foregroundStyle(Color(.secondaryLabel))
        }
        .frame(maxHeight: .infinity)
    }
    
    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("ListTopAnchor")
                    
                    LazyVStack(spacing: 12) {
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
                                onTagTap: { tagPickerItem = item },
                                onEdit: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        isEditMode = true
                                        selectedItems.insert(item.id)
                                    }
                                },
                                onDelete: {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                        historyManager.deleteRecord(item)
                                    }
                                }
                            )
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .scrollIndicators(.automatic)
            .onChange(of: selectedTags) { _, _ in
                Task { @MainActor in
                    proxy.scrollTo("ListTopAnchor", anchor: .top)
                }
            }
            .onChange(of: randomScrollTargetId) { _, newValue in
                if let targetId = newValue {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(targetId, anchor: .center)
                    }
                }
            }
        }
    }
    
    private func toggleSelection(_ item: HistoryItem) {
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
    var searchText: String = ""
    let onCopy: () -> Void
    let onToggleSelection: () -> Void
    let onTagTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 14) {
            if isEditMode {
                ZStack {
                    Circle()
                        .stroke(
                            isSelected ? Design.primaryColor : Color(.quaternaryLabel),
                            lineWidth: 1.5
                        )
                        .frame(width: 24, height: 24)
                    
                                    if isSelected {
                                        Circle()
                                            .fill(Design.primaryColor)
                                            .frame(width: 24, height: 24)
                        
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .transition(.scale.combined(with: .opacity))
            }
            
            VStack(alignment: .leading, spacing: 8) {
                highlightedText(item.preview, searchText: searchText)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Divider()
                    
                    HStack(spacing: 8) {
                        Text(item.formattedDate)
                            .font(.caption)
                            .foregroundStyle(Color(.secondaryLabel))
                        
                        let displayTags = item.tags.filter { !filteredTags.contains($0) }
                        if !displayTags.isEmpty {
                            ForEach(displayTags.prefix(4), id: \.self) { tagName in
                                let isTagHighlighted = isTagMatchingSearch(tagName: tagName, searchText: searchText)
                                Text(tagName)
                                    .font(isTagHighlighted ? .caption.bold() : .caption)
                                    .foregroundStyle(isTagHighlighted ? .white : Design.primaryColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(isTagHighlighted ? Design.primaryColor : Design.primaryColor.opacity(0.08))
                                    )
                            }
                            
                            if displayTags.count > 4 {
                                Text("+\(displayTags.count - 4)")
                                    .font(.caption)
                                    .foregroundStyle(Color(.tertiaryLabel))
                            }
                        }
                        
                        Spacer()
                        
                        if !isEditMode {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(Color(.tertiaryLabel))
                                .frame(width: 32, height: 16, alignment: .trailing)
                        }
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .allowsHitTesting(!isEditMode)
                .onTapGesture {
                    onTagTap()
                }
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditMode {
                onToggleSelection()
            }
        }
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            if !isEditMode {
                Button {
                    onCopy()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                
                Button {
                    onTagTap()
                } label: {
                    Label("标签", systemImage: "tag")
                }
                
                Button {
                    onEdit()
                } label: {
                    Label("选择", systemImage: "checkmark.circle")
                }
                
                Divider()
                
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }
    
    @ViewBuilder
    private func highlightedText(_ text: String, searchText: String) -> some View {
        let attributedString = createHighlightedAttributedString(text: text, searchText: searchText)
        Text(attributedString)
    }
    
    private func isTagMatchingSearch(tagName: String, searchText: String) -> Bool {
        guard !searchText.isEmpty else { return false }
        let tokens = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        return tokens.contains { tagName.lowercased().contains($0) }
    }
    
    private func createHighlightedAttributedString(text: String, searchText: String) -> AttributedString {
        var attributedString = AttributedString(text)
        
        let lowercasedText = text.lowercased()
        let tokens = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        
        guard !tokens.isEmpty else { return attributedString }
        
        for token in tokens {
            var searchStartIndex = lowercasedText.startIndex
            while let range = lowercasedText.range(of: token, range: searchStartIndex..<lowercasedText.endIndex) {
                if let attributedRange = Range(NSRange(range, in: text), in: attributedString) {
                    attributedString[attributedRange].backgroundColor = Design.primaryColor.opacity(0.25)
                    attributedString[attributedRange].foregroundColor = Design.primaryColor
                }
                searchStartIndex = range.upperBound
            }
        }
        
        return attributedString
    }
    
    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 16)
                .fill(Design.primaryColor.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Design.primaryColor.opacity(0.25), lineWidth: 1.5)
                )
        } else {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.03), radius: 10, x: 0, y: 2)
        }
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
                } header: {
                    HStack {
                        Text("记录日历")
                        Spacer()
                        if selectedDate != nil {
                            Button("查看全部") {
                                withAnimation {
                                    selectedDate = nil
                                }
                            }
                            .font(.caption)
                            .textCase(nil)
                        }
                    }
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
    @Binding var displayedMonth: Date
    @Binding var selectedDate: Date?
    let recordsByDate: [Date: Int]
    
    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]
    
    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: displayedMonth)
    }
    
    private var daysInMonth: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth),
              let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) else {
            return []
        }
        
        let firstWeekday = calendar.component(.weekday, from: firstDay) - 1
        var days: [Date?] = Array(repeating: nil, count: firstWeekday)
        
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstDay) {
                days.append(date)
            }
        }
        
        return days
    }
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    withAnimation {
                        displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Design.primaryColor)
                }
                
                Spacer()
                
                Text(monthYearString)
                    .font(.callout.bold())
                
                Spacer()
                
                Button {
                    withAnimation {
                        displayedMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Design.primaryColor)
                }
            }
            .padding(.horizontal, 8)
            
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: 24)
                }
            }
            
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(daysInMonth.enumerated(), id: \.offset) { _, date in
                    if let date {
                        let dateOnly = calendar.startOfDay(for: date)
                        let count = recordsByDate[dateOnly] ?? 0
                        let isToday = calendar.isDateInToday(date)
                        let isSelected = selectedDate.map { calendar.isDate($0, inSameDayAs: date) } ?? false
                        
                        VStack(spacing: 2) {
                            Text("\(calendar.component(.day, from: date))")
                                .font(.system(size: 14, weight: isToday || isSelected ? .bold : .regular))
                                .foregroundStyle(isSelected ? .white : (isToday ? Design.primaryColor : .primary))
                            
                            if count > 0 && !isSelected {
                                Circle()
                                    .fill(Design.primaryColor.opacity(min(Double(count) / 5.0, 1.0) * 0.7 + 0.3))
                                    .frame(width: 6, height: 6)
                            } else {
                                Circle()
                                    .fill(Color.clear)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(isSelected ? Design.primaryColor : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if count > 0 {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    if isSelected {
                                        selectedDate = nil
                                    } else {
                                        selectedDate = dateOnly
                                    }
                                }
                            }
                        }
                        .accessibilityAddTraits(.isButton)
                    } else {
                        Color.clear
                            .frame(height: 36)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}
