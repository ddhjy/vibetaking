import SwiftUI

struct TagPickerView: View {
    let itemId: UUID
    
    @State private var historyManager = HistoryManager.shared
    @State private var tagManager = TagManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showCreateTag = false
    @State private var editingTagName: String? = nil
    @State private var searchText: String = ""
    
    @State private var frozenSortedTags: [String] = []
    
    @State private var didInitialize = false
    
    @State private var localSelectedTags: Set<String> = []
    
    @State private var initialSelectedTags: Set<String> = []
    
    

    @State private var locallyCreatedTags: Set<String> = []

    @State private var recommendedTags: [String] = []
    @State private var recommendationTask: Task<Void, Never>? = nil
    
    private var currentItem: HistoryItem? {
        historyManager.items.first { $0.id == itemId }
    }
    
    private var selectedTagCount: Int {
        localSelectedTags.count
    }
    
    private var sortedTags: [String] {
        return frozenSortedTags
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedTags: [String] {
        if trimmedSearchText.isEmpty {
            return sortedTags
        }
        return sortedTags.filter { $0.localizedStandardContains(trimmedSearchText) }
    }

    private var canCreateTagFromSearch: Bool {
        !trimmedSearchText.isEmpty && displayedTags.isEmpty && !sortedTags.contains(trimmedSearchText)
    }

    private var recommendedTagSet: Set<String> {
        Set(recommendedTags)
    }
    
    private func computeInitialSortedTags(recommendedTags: [String] = []) -> [String] {
        let selectedTagsSet = Set(currentItem?.tags ?? [String]())
        var recommendationRank: [String: Int] = [:]
        for (index, tag) in recommendedTags.enumerated() {
            if recommendationRank[tag] == nil {
                recommendationRank[tag] = index
            }
        }
        let availableTags = Array(Set(tagManager.tags)
            .union(selectedTagsSet)
            .union(initialSelectedTags)
            .union(locallyCreatedTags))
        return availableTags.sorted { tag1, tag2 in
            let tag1Selected = selectedTagsSet.contains(tag1)
            let tag2Selected = selectedTagsSet.contains(tag2)
            if tag1Selected != tag2Selected {
                return tag1Selected
            }

            let tag1Rank = recommendationRank[tag1]
            let tag2Rank = recommendationRank[tag2]
            if let tag1Rank, let tag2Rank, tag1Rank != tag2Rank {
                return tag1Rank < tag2Rank
            }
            if tag1Rank != nil || tag2Rank != nil {
                return tag1Rank != nil
            }

            let tag1Count = tagManager.count(for: tag1)
            let tag2Count = tagManager.count(for: tag2)
            if tag1Count != tag2Count {
                return tag1Count > tag2Count
            }

            return tag1.localizedCompare(tag2) == .orderedAscending
        }
    }

    private func refreshSortedTags() {
        frozenSortedTags = computeInitialSortedTags(recommendedTags: recommendedTags)
    }

    private func requestRecommendedTagsIfNeeded() {
        guard recommendationTask == nil else { return }

        guard let text = currentItem?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              !tagManager.tags.isEmpty else {
            return
        }

        guard let token = SettingsManager.shared.aiApiToken,
              !token.isEmpty else {
            return
        }

        let availableTags = tagManager.tags
        let historyExamples = historyManager.tagRecommendationExamples(excluding: itemId)
        recommendationTask = Task {
            let recommended = (try? await AIService.shared.recommendTags(
                for: text,
                from: availableTags,
                historyExamples: historyExamples
            )) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.recommendedTags = recommended
                self.refreshSortedTags()
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                if displayedTags.isEmpty {
                    ContentUnavailableView {
                        Label(trimmedSearchText.isEmpty ? "还没有标签" : "没有匹配的标签", systemImage: "tag")
                    } description: {
                        Text("创建标签，方便之后找到相关记录。")
                    } actions: {
                        Button(canCreateTagFromSearch ? "创建“\(trimmedSearchText)”" : "新建标签") {
                            if canCreateTagFromSearch { createTagFromSearch() } else { showCreateTag = true }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(displayedTags, id: \.self) { tagName in
                            TagRowView(
                                tagName: tagName,
                                isSelected: localSelectedTags.contains(tagName),
                                markers: recommendedTagSet.contains(tagName) ? [.aiRecommended] : [],
                                onToggle: { toggleTag(tagName) },
                                onEdit: { editingTagName = tagName }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("重命名", systemImage: "pencil") { editingTagName = tagName }
                            }
                        }
                    } footer: {
                        Text("已选择 \(selectedTagCount) 个标签，关闭时自动保存。")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("标签")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索或创建标签")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("新建标签", systemImage: "plus") { showCreateTag = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showCreateTag) {
                TagCreateSheet { name in
                    addLocalTag(name)
                }
            }
            .sheet(item: $editingTagName) { tagName in
                TagEditSheet(tagName: tagName) { newName in
                    historyManager.renameTag(from: tagName, to: newName)
                    if localSelectedTags.remove(tagName) != nil { localSelectedTags.insert(newName) }
                    if initialSelectedTags.remove(tagName) != nil { initialSelectedTags.insert(newName) }
                    if locallyCreatedTags.remove(tagName) != nil { locallyCreatedTags.insert(newName) }
                    recommendedTags = recommendedTags.map { $0 == tagName ? newName : $0 }
                    refreshSortedTags()
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            let currentTags = Set(currentItem?.tags ?? [])
            initialSelectedTags = currentTags
            localSelectedTags = currentTags
            refreshSortedTags()
            requestRecommendedTagsIfNeeded()
        }
        .onDisappear {
            recommendationTask?.cancel()
            recommendationTask = nil
            for tag in localSelectedTags.subtracting(initialSelectedTags) {
                historyManager.addTag(to: itemId, tagName: tag)
            }
            for tag in initialSelectedTags.subtracting(localSelectedTags) {
                historyManager.removeTag(from: itemId, tagName: tag)
            }
            initialSelectedTags = localSelectedTags
        }
    }

    private func toggleTag(_ tagName: String) {
        if !localSelectedTags.insert(tagName).inserted {
            localSelectedTags.remove(tagName)
        }
    }

    private func addLocalTag(_ name: String) {
        locallyCreatedTags.insert(name)
        localSelectedTags.insert(name)
        refreshSortedTags()
        searchText = ""
    }

    private func createTagFromSearch() {
        guard !trimmedSearchText.isEmpty else { return }
        addLocalTag(trimmedSearchText)
    }
}

enum TagRowMarker: String, Identifiable {
    case selected = "已选"
    case recent = "最近使用"
    case aiRecommended = "AI 推荐"

    var id: String { rawValue }

    var tintColor: Color {
        switch self {
        case .selected:
            return Design.primaryColor
        case .recent:
            return Color(.systemOrange)
        case .aiRecommended:
            return Color(.systemTeal)
        }
    }
}

struct TagRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let tagName: String
    let isSelected: Bool
    var markers: [TagRowMarker] = []
    let onToggle: () -> Void
    var onEdit: (() -> Void)? = nil

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Design.primaryColor : Color.secondary)
                    .accessibilityHidden(true)

                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                    : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    Text(tagName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(markers) { marker in
                        TagRowMarkerBadge(marker: marker)
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tagName)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(markers.contains(.aiRecommended) ? "AI 推荐标签" : "轻点更改选择")
        .contextMenu {
            if let onEdit {
                Button("重命名标签", systemImage: "pencil", action: onEdit)
            }
        }
        .accessibilityActions {
            if let onEdit { Button("重命名标签", action: onEdit) }
        }
    }
}

struct TagRowMarkerBadge: View {
    let marker: TagRowMarker

    var body: some View {
        Label(marker.rawValue, systemImage: marker == .aiRecommended ? "sparkles" : "clock")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

struct TagEditSheet: View {
    let tagName: String
    var onSave: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var newTagName = ""
    @FocusState private var isInputFocused: Bool

    private var trimmedName: String { newTagName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("标签名称").font(.subheadline).foregroundStyle(.secondary)
                        TextField("输入标签名称", text: $newTagName)
                            .focused($isInputFocused)
                            .submitLabel(.done)
                            .onSubmit { saveTag() }
                            .accessibilityLabel("标签名称")
                    }
                } footer: {
                    Text(TagManager.shared.tags.contains(trimmedName) && trimmedName != tagName
                         ? "保存后，使用此标签的记录会合并到已有的“\(trimmedName)”标签。"
                         : "重命名会更新所有使用此标签的记录。")
                }
            }
            .navigationTitle("重命名标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: saveTag)
                        .fontWeight(.semibold)
                        .disabled(trimmedName.isEmpty || trimmedName == tagName)
                }
            }
            .onAppear { newTagName = tagName; isInputFocused = true }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func saveTag() {
        guard !trimmedName.isEmpty, trimmedName != tagName else { return }
        if let onSave { onSave(trimmedName) }
        else { HistoryManager.shared.renameTag(from: tagName, to: trimmedName) }
        dismiss()
    }
}

struct TagCreateSheet: View {
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var tagName = ""
    @FocusState private var isInputFocused: Bool

    private var trimmedName: String { tagName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("标签名称").font(.subheadline).foregroundStyle(.secondary)
                        TextField("例如：灵感", text: $tagName)
                            .focused($isInputFocused)
                            .submitLabel(.done)
                            .onSubmit { addTag() }
                            .accessibilityLabel("标签名称")
                    }
                } footer: {
                    Text("添加后会自动选中这个标签。")
                }
            }
            .navigationTitle("新建标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加", action: addTag)
                        .fontWeight(.semibold)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear { isInputFocused = true }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func addTag() {
        guard !trimmedName.isEmpty else { return }
        onCreate(trimmedName)
        dismiss()
    }
}

struct TagBadgeView: View {
    let tagName: String
    
    var body: some View {
        Text(tagName)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color(.tertiarySystemFill))
            )
            .foregroundStyle(Color(.secondaryLabel))
    }
}

nonisolated enum TagSelectionState: Equatable, Sendable {
    case positive
    case negative
}

nonisolated struct TagSelection: Equatable, Sendable {
    var tag: String
    var state: TagSelectionState
    
    static let noTagIdentifier = "__NO_TAG__"
    
    var isNoTagSelection: Bool {
        tag == Self.noTagIdentifier
    }
}

struct TagFilterBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var filterTextHeight = 20.0
    private var filterRowHeight: Double { max(44, filterTextHeight + 16) + 16 }

    @Binding var selectedTags: [TagSelection]
    @Binding var isRandomMode: Bool
    var availableItems: [HistoryItem]
    var availableTagSet: Set<String> = []
    var level0TagCounts: [String: Int] = [:]
    var level0NoTagCount: Int = 0
    var isSearching: Bool = false
    var onRandomize: () -> Void
    
    @State private var tagManager = TagManager.shared
    
    private func computeAvailableTagsFromItems() -> Set<String> {
        var tags = Set<String>()
        for item in availableItems {
            for tag in item.tags {
                tags.insert(tag)
            }
        }
        return tags
    }
    
    private func selectionState(for tagName: String, at level: Int) -> TagSelectionState? {
        guard level < selectedTags.count else { return nil }
        let selection = selectedTags[level]
        return selection.tag == tagName ? selection.state : nil
    }
    
    var body: some View {
        let availableTagsFromItems = availableTagSet.isEmpty
            ? computeAvailableTagsFromItems()
            : availableTagSet
        
        if availableTagsFromItems.isEmpty {
            EmptyView()
        } else {
            ScrollView(.vertical) {
              VStack(spacing: 0) {
                ForEach(0...selectedTags.count, id: \.self) { level in
                    let filteredItemCount = getFilteredItemCount(at: level)
                    let availableTagsWithCounts = getAvailableTagsWithCounts(at: level, availableTagsFromItems: availableTagsFromItems)
                    
                    if !availableTagsWithCounts.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                FilterChip(
                                    title: "全部",
                                    selectionState: level >= selectedTags.count && !(level == 0 && isRandomMode) ? .positive : nil,
                                    count: isSearching ? filteredItemCount : nil
                                ) {
                                    selectAll(at: level)
                                }

                                if level == 0 {
                                    let noTagCount = getNoTagCount(at: level)
                                    if noTagCount > 0 {
                                        FilterChip(
                                            title: "无标签",
                                            selectionState: selectionState(for: TagSelection.noTagIdentifier, at: level)
                                        ) {
                                            handleTagTap(TagSelection.noTagIdentifier, at: level)
                                        }
                                    }
                                    
                                    FilterIconChip(
                                        systemImage: "shuffle",
                                        accessibilityLabel: "随机",
                                        isSelected: isRandomMode,
                                        usesDiceHaptics: true
                                    ) {
                                        selectRandom()
                                    }
                                }
                                
                                ForEach(availableTagsWithCounts, id: \.tag) { item in
                                    FilterChip(
                                        title: item.tag,
                                        selectionState: selectionState(for: item.tag, at: level),
                                        count: isSearching ? item.count : nil
                                    ) {
                                        handleTagTap(item.tag, at: level)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
              }
            }
            .frame(height: min(filterRowHeight * Double(selectedTags.count + 1), dynamicTypeSize.isAccessibilitySize ? 110 : 180))
        }
    }
    
    private func getFilteredItemCount(at level: Int) -> Int {
        let currentSelections = Array(selectedTags.prefix(level))
        if currentSelections.isEmpty {
            return availableItems.count
        }
        return availableItems.reduce(into: 0) { count, item in
            if matchesSelections(item: item, selections: currentSelections) {
                count += 1
            }
        }
    }
    
    private func getNoTagCount(at level: Int) -> Int {
        let currentSelections = Array(selectedTags.prefix(level))
        if currentSelections.isEmpty {
            return level0NoTagCount
        }
        return availableItems.reduce(into: 0) { count, item in
            if item.tags.isEmpty && matchesSelections(item: item, selections: currentSelections) {
                count += 1
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
    
    private func getAvailableTagsWithCounts(at level: Int, availableTagsFromItems: Set<String>) -> [(tag: String, count: Int)] {
        let currentSelections = Array(selectedTags.prefix(level))
        let usedTags = Set(currentSelections.map { $0.tag })
        
        if currentSelections.isEmpty {
            return level0TagCounts
                .filter { !usedTags.contains($0.key) && availableTagsFromItems.contains($0.key) }
                .map { (tag: $0.key, count: $0.value) }
                .sorted {
                    if $0.count != $1.count { return $0.count > $1.count }
                    return $0.tag < $1.tag
                }
        }
        
        var filteredItems = availableItems
        if !currentSelections.isEmpty {
            filteredItems = filteredItems.filter { item in
                matchesSelections(item: item, selections: currentSelections)
            }
        }
        
        guard !filteredItems.isEmpty else { return [] }
        
        var tagCounts: [String: Int] = [:]
        for item in filteredItems {
            for tag in item.tags {
                if !usedTags.contains(tag) && availableTagsFromItems.contains(tag) {
                    tagCounts[tag, default: 0] += 1
                }
            }
        }
        
        guard !tagCounts.isEmpty else { return [] }
        
        return tagCounts.map { (tag: $0.key, count: $0.value) }.sorted {
            if $0.count != $1.count {
                return $0.count > $1.count
            }
            return $0.tag < $1.tag
        }
    }
    
    private func selectAll(at level: Int) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if level < selectedTags.count {
                selectedTags = Array(selectedTags.prefix(level))
            }
            isRandomMode = false
        }
    }
    
    private func handleTagTap(_ tagName: String, at level: Int) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if level < selectedTags.count && selectedTags[level].tag == tagName {
                let currentState = selectedTags[level].state
                switch currentState {
                case .positive:
                    var newTags = Array(selectedTags.prefix(level))
                    newTags.append(TagSelection(tag: tagName, state: .negative))
                    selectedTags = newTags
                case .negative:
                    selectedTags = Array(selectedTags.prefix(level))
                }
            } else {
                var newTags = Array(selectedTags.prefix(level))
                newTags.append(TagSelection(tag: tagName, state: .positive))
                selectedTags = newTags
            }
            isRandomMode = false
        }
    }

    private func selectRandom() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if !selectedTags.isEmpty {
                selectedTags = []
            }
            isRandomMode = true
        }
        onRandomize()
    }
}

struct FilterChip: View {
    let title: String
    var selectionState: TagSelectionState? = nil
    var count: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let selectionState {
                    Image(systemName: selectionState == .positive ? "checkmark" : "minus.circle")
                        .foregroundStyle(selectionState == .negative ? Design.negativeColor : Design.primaryColor)
                }
                Text(title)
                if let count { Text(count.formatted()).foregroundStyle(.secondary) }
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 44, minHeight: 44)
            .background(selectionState == nil ? Color(.tertiarySystemFill) : Design.primaryColor.opacity(0.10), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selectionState == .positive ? "已包含" : (selectionState == .negative ? "已排除" : "未筛选"))
        .accessibilityAddTraits(selectionState != nil ? .isSelected : [])
        .accessibilityHint(title == "全部" ? "清除此级筛选" : "依次切换包含、排除和取消筛选")
    }
}

struct FilterIconChip: View {
    let systemImage: String
    let accessibilityLabel: String
    let isSelected: Bool
    var usesDiceHaptics: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            if usesDiceHaptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.body)
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(isSelected ? Design.primaryColor : Color.primary)
                .background(isSelected ? Design.primaryColor.opacity(0.10) : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "已开启" : "未开启")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct BatchTagPickerView: View {
    @State private var didInitialize = false
    let itemIds: Set<UUID>
    
    @State private var historyManager = HistoryManager.shared
    @State private var tagManager = TagManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showCreateTag = false
    @State private var searchText: String = ""
    @State private var frozenSortedTags: [String] = []
    @State private var locallyCreatedTags: Set<String> = []
    
    @State private var tagStates: [String: Bool?] = [:]
    @State private var initialTagStates: [String: Bool?] = [:]
    
    private var sortedTags: [String] { frozenSortedTags }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var displayedTags: [String] {
        if trimmedSearchText.isEmpty { return sortedTags }
        return sortedTags.filter { $0.localizedStandardContains(trimmedSearchText) }
    }

    private var canCreateTagFromSearch: Bool {
        !trimmedSearchText.isEmpty && displayedTags.isEmpty && !sortedTags.contains(trimmedSearchText)
    }
    
    private func computeTagStates() -> [String: Bool?] {
        let items = historyManager.items.filter { itemIds.contains($0.id) }
        var states: [String: Bool?] = [:]
        for tag in tagManager.tags {
            let count = items.filter { $0.tags.contains(tag) }.count
            if count == 0 {
                states[tag] = false
            } else if count == items.count {
                states[tag] = true
            } else {
                states[tag] = .some(nil)
            }
        }
        return states
    }
    
    private func computeSortedTags() -> [String] {
        Array(Set(tagManager.tags).union(locallyCreatedTags)).sorted { tag1, tag2 in
            let s1 = tagStates[tag1] ?? nil
            let s2 = tagStates[tag2] ?? nil
            let order1 = s1 == true ? 0 : (s1 == nil ? 1 : 2)
            let order2 = s2 == true ? 0 : (s2 == nil ? 1 : 2)
            if order1 != order2 { return order1 < order2 }
            let count1 = tagManager.count(for: tag1)
            let count2 = tagManager.count(for: tag2)
            if count1 != count2 { return count1 > count2 }
            return tag1.localizedStandardCompare(tag2) == .orderedAscending
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                if displayedTags.isEmpty {
                    ContentUnavailableView {
                        Label(trimmedSearchText.isEmpty ? "还没有标签" : "没有匹配的标签", systemImage: "tag")
                    } description: {
                        Text("为所选的 \(itemIds.count) 条记录添加标签。")
                    } actions: {
                        Button(canCreateTagFromSearch ? "创建“\(trimmedSearchText)”" : "新建标签") {
                            if canCreateTagFromSearch { createTagFromSearch() } else { showCreateTag = true }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(displayedTags, id: \.self) { tagName in
                            BatchTagRowView(tagName: tagName, state: tagStates[tagName] ?? nil) {
                                toggleTag(tagName)
                            }
                        }
                    } footer: {
                        Text("更改会应用于所选的 \(itemIds.count) 条记录。减号表示部分记录已使用此标签。")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("批量标签")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索或创建标签")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("新建标签", systemImage: "plus") { showCreateTag = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showCreateTag) {
                TagCreateSheet { name in
                    addLocalTag(name)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            tagStates = computeTagStates()
            initialTagStates = tagStates
            frozenSortedTags = computeSortedTags()
        }
        .onDisappear {
            applyChanges()
            initialTagStates = tagStates
        }
    }

    private func addLocalTag(_ name: String) {
        locallyCreatedTags.insert(name)
        tagStates[name] = true
        if initialTagStates[name] == nil { initialTagStates[name] = false }
        frozenSortedTags = computeSortedTags()
        searchText = ""
    }

    private func toggleTag(_ tagName: String) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            let current = tagStates[tagName] ?? nil
            switch current {
            case true:
                tagStates[tagName] = false
            case false:
                tagStates[tagName] = true
            case nil:
                tagStates[tagName] = true
            }
        }
    }

    private func createTagFromSearch() {
        guard !trimmedSearchText.isEmpty else { return }
        addLocalTag(trimmedSearchText)
    }

    private func applyChanges() {
        for (tag, newState) in tagStates {
            let oldState = initialTagStates[tag] ?? false
            guard newState != oldState else { continue }
            
            switch newState {
            case true:
                historyManager.batchAddTag(to: itemIds, tagName: tag)
            case false:
                historyManager.batchRemoveTag(from: itemIds, tagName: tag)
            default:
                break
            }
        }
    }
}

struct BatchTagRowView: View {
    let tagName: String
    let state: Bool?
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: state == true ? "checkmark.circle.fill" : (state == nil ? "minus.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(state == false ? Color.secondary : Design.primaryColor)
                    .accessibilityHidden(true)
                Text(tagName).font(.body).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tagName)
        .accessibilityValue(state == true ? "全部记录已选择" : (state == nil ? "部分记录已选择" : "未选择"))
        .accessibilityAddTraits(state == true ? .isSelected : [])
    }
}

#Preview {
    TagPickerView(itemId: UUID())
}
