import SwiftUI

struct TagPickerView: View {
    let itemId: UUID
    var reselectMode: Bool = false
    
    @State private var historyManager = HistoryManager.shared
    @State private var tagManager = TagManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showCreateTag = false
    @State private var editingTagName: String? = nil
    @State private var searchText: String = ""
    
    @State private var frozenSortedTags: [String] = []
    
    @State private var pendingRenameOperation: (from: String, to: String)? = nil
    
    @State private var localSelectedTags: Set<String> = []
    
    @State private var initialSelectedTags: Set<String> = []
    
    @State private var previousSelectedTags: Set<String> = []
    
    @State private var hasStartedReselection: Bool = false

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
        let availableTags = Array(Set(tagManager.tags).union(locallyCreatedTags))
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
            VStack(spacing: 0) {
                if tagManager.tags.isEmpty {
                    emptyTagsView
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            if displayedTags.isEmpty {
                                VStack(spacing: 12) {
                                    Text("没有找到相关标签")
                                        .font(.subheadline)
                                        .foregroundStyle(Color(.secondaryLabel))

                                    if canCreateTagFromSearch {
                                        Button(action: createTagFromSearch) {
                                            Label("新增标签 \"\(trimmedSearchText)\"", systemImage: "plus.circle.fill")
                                                .font(.callout.weight(.medium))
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(Design.primaryColor)
                                        .padding(.horizontal, 16)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                            } else {
                                ForEach(displayedTags.indices, id: \.self) { index in
                                    let tagName = displayedTags[index]
                                    let isCurrentlySelected = localSelectedTags.contains(tagName)
                                    let isPreviouslySelected = reselectMode && !hasStartedReselection && previousSelectedTags.contains(tagName)
                                    TagRowView(
                                        tagName: tagName,
                                        isSelected: isCurrentlySelected,
                                        isPreviousSelected: isPreviouslySelected,
                                        markers: markers(for: tagName, isSelected: isCurrentlySelected, isPreviousSelected: isPreviouslySelected),
                                        onToggle: { toggleTag(tagName) },
                                        onEdit: { editingTagName = tagName }
                                    )
                                    
                                    if index != displayedTags.count - 1 {
                                        Divider()
                                            .padding(.leading, 52)
                                    }
                                }
                            }
                        }
                        .padding(.top, 16)
                    }
                    Spacer()
                }
            }
            .background(
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
            )
            .navigationTitle(selectedTagCount > 0 ? "标签 (\(selectedTagCount))" : "标签")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索标签")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { showCreateTag = true }) {
                        Image(systemName: "plus")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showCreateTag, onDismiss: {
                refreshSortedTags()
            }) {
                TagCreateSheet(itemId: itemId)
            }
            .sheet(item: $editingTagName, onDismiss: {
                if let operation = pendingRenameOperation {
                    historyManager.renameTag(from: operation.from, to: operation.to)
                    recommendedTags = recommendedTags.map { $0 == operation.from ? operation.to : $0 }
                    refreshSortedTags()
                    pendingRenameOperation = nil
                }
            }) { tagName in
                TagEditSheet(tagName: tagName) { newName in
                    pendingRenameOperation = (from: tagName, to: newName)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if frozenSortedTags.isEmpty {
                let currentTags = Set(currentItem?.tags ?? [])
                initialSelectedTags = currentTags
                
                if reselectMode {
                    localSelectedTags = []
                    previousSelectedTags = currentTags
                    hasStartedReselection = false
                } else {
                    localSelectedTags = currentTags
                }
                
                refreshSortedTags()
                requestRecommendedTagsIfNeeded()
            }
        }
        .onDisappear {
            recommendationTask?.cancel()
            recommendationTask = nil

            let addedTags = localSelectedTags.subtracting(initialSelectedTags)
            let removedTags = initialSelectedTags.subtracting(localSelectedTags)
            
            for tag in addedTags {
                historyManager.addTag(to: itemId, tagName: tag)
            }
            for tag in removedTags {
                historyManager.removeTag(from: itemId, tagName: tag)
            }
        }
    }
    
    private var emptyTagsView: some View {
        VStack(spacing: 12) {
            Text("点击左上角 + 创建第一个标签")
                .font(.subheadline)
                .foregroundStyle(Color(.secondaryLabel))

            if canCreateTagFromSearch {
                Button(action: createTagFromSearch) {
                    Label("新增标签 \"\(trimmedSearchText)\"", systemImage: "plus.circle.fill")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Design.primaryColor)
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
    
    private func toggleTag(_ tagName: String) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            if localSelectedTags.contains(tagName) {
                localSelectedTags.remove(tagName)
            } else {
                selectTag(tagName)
            }
        }
    }

    private func createTagFromSearch() {
        let newTag = trimmedSearchText
        guard !newTag.isEmpty else { return }

        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            locallyCreatedTags.insert(newTag)
            selectTag(newTag)
            refreshSortedTags()
        }
    }

    private func selectTag(_ tagName: String) {
        if reselectMode && !hasStartedReselection {
            hasStartedReselection = true
            previousSelectedTags = []
            localSelectedTags = [tagName]
        } else {
            localSelectedTags.insert(tagName)
        }
    }

    private func markers(for tagName: String, isSelected: Bool, isPreviousSelected: Bool) -> [TagRowMarker] {
        var markers: [TagRowMarker] = []

        if !isSelected && isPreviousSelected {
            markers.append(.recent)
        }

        if recommendedTagSet.contains(tagName) {
            markers.append(.aiRecommended)
        }

        return markers
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
    let tagName: String
    let isSelected: Bool
    var isPreviousSelected: Bool = false
    var markers: [TagRowMarker] = []
    let onToggle: () -> Void
    var onEdit: (() -> Void)? = nil
    private let selectionCircleSize: CGFloat = 20
    private let selectionIconSlotSize: CGFloat = 24
    
    private var circleColor: Color {
        if isSelected {
            return Design.primaryColor
        } else if isPreviousSelected {
            return Color(.systemGray3)
        } else {
            return Color(.secondaryLabel)
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(circleColor, lineWidth: 1.8)
                    .frame(width: selectionCircleSize, height: selectionCircleSize)

                if isSelected || isPreviousSelected {
                    Circle()
                        .fill(circleColor)
                        .frame(width: selectionCircleSize, height: selectionCircleSize)

                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: selectionIconSlotSize, height: selectionIconSlotSize)

            Text(tagName)
                .font(.callout)
                .foregroundStyle(Color(.label))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if !markers.isEmpty {
                HStack(spacing: 6) {
                    ForEach(markers) { marker in
                        TagRowMarkerBadge(marker: marker)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
        .contextMenu {
            if let onEdit = onEdit {
                Button(action: onEdit) {
                    Label("编辑", systemImage: "pencil")
                }
            }
        }
        .accessibilityAddTraits(.isButton)
    }
}

struct TagRowMarkerBadge: View {
    let marker: TagRowMarker

    var body: some View {
        Text(marker.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(marker.tintColor.opacity(0.12))
            )
            .foregroundStyle(marker.tintColor)
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

struct TagEditSheet: View {
    let tagName: String
    var onSave: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var newTagName: String = ""
    @State private var hapticTrigger = 0
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TextField("标签名称", text: $newTagName)
                    .font(.body)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.regularMaterial)
                    )
                    .padding(.horizontal, 16)
                    .focused($isInputFocused)
                
                Spacer()
            }
            .padding(.top, 20)
            .background(
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
            )
            .navigationTitle("编辑标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        saveTag()
                    }
                    .fontWeight(.semibold)
                    .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                newTagName = tagName
                isInputFocused = true
            }
        .sensoryFeedback(.impact(weight: .medium), trigger: hapticTrigger)
        }
        .presentationDetents([.height(200)])
        .presentationDragIndicator(.visible)
    }
    
    private func saveTag() {
        hapticTrigger += 1
        
        let trimmedName = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let onSave = onSave {
            onSave(trimmedName)
        } else {
            HistoryManager.shared.renameTag(from: tagName, to: trimmedName)
        }
        dismiss()
    }
}

struct TagCreateSheet: View {
    let itemId: UUID
    @State private var historyManager = HistoryManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tagName: String = ""
    @State private var hapticTrigger = 0
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TextField("标签名称", text: $tagName)
                    .font(.body)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.regularMaterial)
                    )
                    .padding(.horizontal, 16)
                    .focused($isInputFocused)
                
                Spacer()
            }
            .padding(.top, 20)
            .background(
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
            )
            .navigationTitle("新建标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加") {
                        addTag()
                    }
                    .fontWeight(.semibold)
                    .disabled(tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                isInputFocused = true
            }
        .sensoryFeedback(.impact(weight: .medium), trigger: hapticTrigger)
        }
        .presentationDetents([.height(200)])
        .presentationDragIndicator(.visible)
    }
    
    private func addTag() {
        hapticTrigger += 1
        
        historyManager.addTag(to: itemId, tagName: tagName)
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
    @Binding var selectedTags: [TagSelection]
    @Binding var isRandomMode: Bool
    var availableItems: [HistoryItem]
    var availableTagSet: Set<String> = []
    var level0TagCounts: [String: Int] = [:]
    var level0NoTagCount: Int = 0
    var isSearching: Bool = false
    var onRandomize: () -> Void
    
    @State private var tagManager = TagManager.shared
    let historyManager = HistoryManager.shared
    
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
                                        FilterIconChipWithState(
                                            systemImage: "tag.slash",
                                            accessibilityLabel: "无标签",
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
    
    private var isSelected: Bool { selectionState != nil }
    private var isNegative: Bool { selectionState == .negative }
    
    private var activeColor: Color {
        isNegative ? Design.negativeColor : Design.primaryColor
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.footnote)
                    .strikethrough(isNegative, color: Design.negativeColor)
                
                if let count = count {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(isSelected ? activeColor.opacity(0.7) : Color(.tertiaryLabel))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? activeColor.opacity(0.15) : Color(.tertiarySystemFill))
            )
            .foregroundStyle(isSelected ? activeColor : Color(.secondaryLabel))
        }
        .buttonStyle(.plain)
        .animation(.none, value: selectionState)
    }
}

struct FilterIconChip: View {
    let systemImage: String
    let accessibilityLabel: String
    let isSelected: Bool
    var usesDiceHaptics: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: {
            if usesDiceHaptics {
                playDiceHaptics()
            }
            action()
        }) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(height: 16)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? Design.primaryColor.opacity(0.15) : Color(.tertiarySystemFill))
                )
                .foregroundStyle(isSelected ? Design.primaryColor : Color(.secondaryLabel))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .animation(.none, value: isSelected)
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
}

struct FilterIconChipWithState: View {
    let systemImage: String
    let accessibilityLabel: String
    let selectionState: TagSelectionState?
    let action: () -> Void
    
    private var isSelected: Bool { selectionState != nil }
    private var isNegative: Bool { selectionState == .negative }
    
    private var activeColor: Color {
        isNegative ? Design.negativeColor : Design.primaryColor
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(height: 16)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? activeColor.opacity(0.15) : Color(.tertiarySystemFill))
                )
                .foregroundStyle(isSelected ? activeColor : Color(.secondaryLabel))
                .overlay(
                    isNegative ? 
                        Capsule()
                            .stroke(Design.negativeColor.opacity(0.3), lineWidth: 1)
                        : nil
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .animation(.none, value: selectionState)
    }
}

struct BatchTagPickerView: View {
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
                states[tag] = nil
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
            return tagManager.count(for: tag1) > tagManager.count(for: tag2)
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if tagManager.tags.isEmpty {
                    VStack(spacing: 12) {
                        Text("还没有标签，点击 + 创建")
                            .font(.subheadline)
                            .foregroundStyle(Color(.secondaryLabel))

                        if canCreateTagFromSearch {
                            Button(action: createTagFromSearch) {
                                Label("新增标签 \"\(trimmedSearchText)\"", systemImage: "plus.circle.fill")
                                    .font(.callout.weight(.medium))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Design.primaryColor)
                            .padding(.horizontal, 16)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            if displayedTags.isEmpty {
                                VStack(spacing: 12) {
                                    Text("没有找到相关标签")
                                        .font(.subheadline)
                                        .foregroundStyle(Color(.secondaryLabel))

                                    if canCreateTagFromSearch {
                                        Button(action: createTagFromSearch) {
                                            Label("新增标签 \"\(trimmedSearchText)\"", systemImage: "plus.circle.fill")
                                                .font(.callout.weight(.medium))
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(Design.primaryColor)
                                        .padding(.horizontal, 16)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                            } else {
                                ForEach(displayedTags.indices, id: \.self) { index in
                                    let tagName = displayedTags[index]
                                    let state = tagStates[tagName] ?? nil
                                    
                                    BatchTagRowView(
                                        tagName: tagName,
                                        state: state,
                                        onToggle: { toggleTag(tagName) }
                                    )
                                    
                                    if index != displayedTags.count - 1 {
                                        Divider().padding(.leading, 52)
                                    }
                                }
                            }
                        }
                        .padding(.top, 16)
                    }
                    Spacer()
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("标签 · \(itemIds.count) 条记录")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索标签")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { showCreateTag = true }) {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showCreateTag, onDismiss: {
                let newStates = computeTagStates()
                for tag in tagManager.tags where !frozenSortedTags.contains(tag) {
                    frozenSortedTags.insert(tag, at: 0)
                    tagStates[tag] = newStates[tag] ?? false
                    initialTagStates[tag] = newStates[tag] ?? false
                }
            }) {
                TagCreateSheet(itemId: itemIds.first ?? UUID())
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            tagStates = computeTagStates()
            initialTagStates = tagStates
            frozenSortedTags = computeSortedTags()
        }
        .onDisappear {
            applyChanges()
        }
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
        let newTag = trimmedSearchText
        guard !newTag.isEmpty else { return }

        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            locallyCreatedTags.insert(newTag)
            tagStates[newTag] = true
            initialTagStates[newTag] = false
            frozenSortedTags = computeSortedTags()
        }
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
    
    private var circleColor: Color {
        switch state {
        case true: return Design.primaryColor
        case nil: return Design.primaryColor.opacity(0.5)
        default: return Color(.secondaryLabel)
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(circleColor, lineWidth: 2)
                    .frame(width: 24, height: 24)
                
                if state == true {
                    Circle()
                        .fill(circleColor)
                        .frame(width: 24, height: 24)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else if state == nil {
                    Circle()
                        .fill(circleColor)
                        .frame(width: 24, height: 24)
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            
            Text(tagName)
                .font(.callout)
                .foregroundStyle(Color(.label))
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    TagPickerView(itemId: UUID())
}
