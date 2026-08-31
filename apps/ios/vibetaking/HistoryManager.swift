import Foundation
import SwiftUI
import zlib

nonisolated struct HistoryItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var fileName: String
    var text: String
    let createdAt: Date
    var description: String
    var tags: [String]
    var isDraft: Bool
    var isDownloading: Bool
    
    init(id: UUID = UUID(), fileName: String = "", text: String = "", createdAt: Date = .now, description: String = "", tags: [String] = [], isDraft: Bool = false, isDownloading: Bool = false) {
        self.id = id
        self.fileName = fileName
        self.text = text
        self.createdAt = createdAt
        self.description = description.isEmpty && !text.isEmpty ? String(text.prefix(50)) : description
        self.tags = tags
        self.isDraft = isDraft
        self.isDownloading = isDownloading
    }
    
    var preview: String {
        if text.count <= 200 {
            return text
        }
        return String(text.prefix(200)) + "..."
    }
    
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()
    
    var formattedDate: String {
        let now = Date()
        let interval = now.timeIntervalSince(createdAt)
        
        if interval < 3600 {
            return "刚刚"
        }
        
        return Self.relativeDateFormatter.localizedString(for: createdAt, relativeTo: now)
    }
}

nonisolated struct NotesImportResult: Sendable {
    let importedCount: Int
    let skippedCount: Int
}

enum NotesImportError: LocalizedError {
    case noFilesSelected
    case noImportableNotes
    case invalidZipArchive
    case unsupportedZipArchive
    case unsupportedCompressionMethod(Int)
    case corruptZipEntry(String)
    case decompressionFailed
    case fileTooLarge(String)
    
    var errorDescription: String? {
        switch self {
        case .noFilesSelected:
            return "没有选择文件"
        case .noImportableNotes:
            return "没有找到可导入的 Markdown 记录"
        case .invalidZipArchive:
            return "压缩包格式不正确"
        case .unsupportedZipArchive:
            return "暂不支持这个压缩包格式"
        case .unsupportedCompressionMethod(let method):
            return "暂不支持压缩方式 \(method)"
        case .corruptZipEntry(let name):
            return "\(name) 读取失败"
        case .decompressionFailed:
            return "压缩包解压失败"
        case .fileTooLarge(let name):
            return "\(name) 太大，已停止导入"
        }
    }
}

@MainActor
@Observable
class TagManager {
    static let shared = TagManager()
    
    var tags: [String] = []
    
    private(set) var tagCounts: [String: Int] = [:]
    
    private(set) var lastSelectedTags: [String] = []
    
    private let lastSelectedTagsKey = "lastSelectedTags"
    private let lastSelectedTagsTimeKey = "lastSelectedTagsTime"
    private let cachedTagsKey = "cachedTags"
    
    private let tagMemoryExpiration: TimeInterval = 30 * 60
    
    private init() {
        loadLastSelectedTags()
        loadCachedTags()
    }
    
    func reload() {
        tags = []
        tagCounts = [:]
        lastSelectedTags = []
        loadLastSelectedTags()
        loadCachedTags()
    }

    private func loadCachedTags() {
        guard let data = AppDefaults.current.data(forKey: cachedTagsKey),
              let saved = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        tags = saved
    }
    
    nonisolated struct Snapshot: Sendable {
        let tags: [String]
        let counts: [String: Int]
    }

    nonisolated static func snapshot(from items: [HistoryItem]) -> Snapshot {
        var uniqueTags = Set<String>()
        var counts: [String: Int] = [:]

        for item in items {
            for tag in item.tags {
                uniqueTags.insert(tag)
                counts[tag, default: 0] += 1
            }
        }

        return Snapshot(tags: Array(uniqueTags), counts: counts)
    }

    func apply(snapshot: Snapshot) {
        tags = snapshot.tags
        tagCounts = snapshot.counts

        if let data = try? JSONEncoder().encode(tags) {
            AppDefaults.current.set(data, forKey: cachedTagsKey)
        }
    }

    func refreshTags(from items: [HistoryItem]) {
        apply(snapshot: Self.snapshot(from: items))
    }
    
    func count(for tag: String) -> Int {
        return tagCounts[tag, default: 0]
    }
    
    func getTag(by name: String) -> String? {
        tags.first { $0 == name }
    }
    
    private func loadLastSelectedTags() {
        let savedTime = AppDefaults.current.double(forKey: lastSelectedTagsTimeKey)
        if savedTime > 0 {
            let elapsed = Date().timeIntervalSince1970 - savedTime
            if elapsed > tagMemoryExpiration {
                lastSelectedTags = []
                return
            }
        }
        
        guard let data = AppDefaults.current.data(forKey: lastSelectedTagsKey),
              let savedTags = try? JSONDecoder().decode([String].self, from: data) else {
            lastSelectedTags = []
            return
        }
        lastSelectedTags = savedTags
    }
    
    func saveLastSelectedTags(_ tags: [String]) {
        lastSelectedTags = tags
        if let data = try? JSONEncoder().encode(tags) {
            AppDefaults.current.set(data, forKey: lastSelectedTagsKey)
            AppDefaults.current.set(Date().timeIntervalSince1970, forKey: lastSelectedTagsTimeKey)
        }
    }
}

@MainActor
@Observable
class HistoryManager {
    static let shared = HistoryManager()
    
    var items: [HistoryItem] = []
    private(set) var lastClearedText: String = ""
    var isLoading = false
    private(set) var hasLoadedHistory = false
    private(set) var isUsingLocalFallback = false
    private(set) var hasPendingICloudDownloads = false
    private var loadGeneration: UInt = 0
    
    private var _cachedStorage: ICloudNotesStorage.Resolution?
    
    private let fileManager = FileManager.default
    private let dateFormatter: DateFormatter = ICloudNotesStorage.makeNoteDateFormatter()
    
    private var metadataQuery: NSMetadataQuery?
    private var metadataObservers: [NSObjectProtocol] = []
    private var lastMetadataSignature = ""
    private var metadataReloadTask: Task<Void, Never>?
    private var iCloudRetryTask: Task<Void, Never>?
    
    private let maxImportEntrySize = 50 * 1024 * 1024
    
    private init() {
        ensureDraftExists()
        observeUbiquityIdentityChanges()
#if DEBUG
        ICloudNotesStorage.debugAssertParsing()
#endif
    }
    
    private let draftFileName = "_draft.md"
    
    var currentDraft: HistoryItem {
        if let draft = items.first(where: { $0.isDraft }) {
            return draft
        }
        let newDraft = createNewDraft()
        items.insert(newDraft, at: 0)
        return newDraft
    }

    var hasLastClearedText: Bool {
        !lastClearedText.isEmpty
    }
    
    private func ensureDraftExists() {
        if !items.contains(where: { $0.isDraft }) {
            let newDraft = createNewDraft()
            items.insert(newDraft, at: 0)
        }
    }
    
    private func createNewDraft() -> HistoryItem {
        return HistoryItem(tags: TagManager.shared.lastSelectedTags, isDraft: true)
    }
    
    func updateDraftText(_ text: String) {
        guard let index = items.firstIndex(where: { $0.isDraft }) else { return }
        if !text.isEmpty {
            lastClearedText = ""
        }
        items[index].text = text
        saveDraft()
    }

    func clearDraft() {
        guard let index = items.firstIndex(where: { $0.isDraft }) else { return }
        let currentText = items[index].text
        if !currentText.isEmpty {
            lastClearedText = currentText
        }
        items[index].text = ""
        saveDraft()
    }

    func restoreLastClearedDraft() {
        guard let index = items.firstIndex(where: { $0.isDraft }), !lastClearedText.isEmpty else { return }
        items[index].text = lastClearedText
        lastClearedText = ""
        saveDraft()
    }

    func clearDraftTags() {
        guard let index = items.firstIndex(where: { $0.isDraft }) else { return }
        guard !items[index].tags.isEmpty else { return }

        items[index].tags.removeAll()
        saveDraft()
    }
    
    func finalizeDraft() {
        guard let draftIndex = items.firstIndex(where: { $0.isDraft }),
              !items[draftIndex].text.isEmpty else { return }
        
        let draft = items[draftIndex]
        if !draft.text.isEmpty {
            lastClearedText = draft.text
        }
        
        TagManager.shared.saveLastSelectedTags(draft.tags)
        
        let now = Date.now
        let fileName = generateFileName(for: now)
        let finalItem = HistoryItem(
            id: draft.id,
            fileName: fileName,
            text: draft.text,
            createdAt: now,
            description: String(draft.text.prefix(50)),
            tags: draft.tags,
            isDraft: false
        )
        
        items[draftIndex] = finalItem
        saveItem(finalItem)
        
        deleteDraftFile()
        
        let newDraft = createNewDraft()
        items.insert(newDraft, at: 0)
        
        TagManager.shared.refreshTags(from: savedItems)
    }
    
    var savedItems: [HistoryItem] {
        items.filter { !$0.isDraft }
    }
    
    func getSavedItems(filteredBy tagName: String?) -> [HistoryItem] {
        var result = savedItems
        if let tagName = tagName {
            result = result.filter { $0.tags.contains(tagName) }
        }
        return result
    }
    
    func getSavedItems(filteredBy tags: [String]) -> [HistoryItem] {
        guard !tags.isEmpty else { return savedItems }
        return savedItems.filter { item in
            tags.allSatisfy { item.tags.contains($0) }
        }
    }

    func tagRecommendationExamples(excluding itemId: UUID, limit: Int = 200) -> [TagRecommendationExample] {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }

        return savedItems
            .filter { item in
                item.id != itemId
                    && !item.tags.isEmpty
                    && !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(boundedLimit)
            .map { item in
                TagRecommendationExample(
                    text: item.text,
                    tags: item.tags,
                    createdAt: item.createdAt
                )
            }
    }
    
    private func saveDraft() {
        guard let draft = items.first(where: { $0.isDraft }) else { return }
        
        let content = generateMarkdownContent(
            text: draft.text,
            description: String(draft.text.prefix(50)),
            tags: draft.tags,
            createdAt: draft.createdAt
        )
        
        let fileURL = storageURL.appendingPathComponent(draftFileName)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    
    private func loadDraft() -> HistoryItem? {
        let fileURL = storageURL.appendingPathComponent(draftFileName)
        
        guard fileManager.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8),
              let parsed = parseMarkdownFile(content: content) else {
            return nil
        }
        
        return HistoryItem(
            text: parsed.body,
            tags: parsed.tags,
            isDraft: true
        )
    }
    
    private func deleteDraftFile() {
        let fileURL = storageURL.appendingPathComponent(draftFileName)
        try? fileManager.removeItem(at: fileURL)
    }
    
    private var storageURL: URL {
        resolvedStorage.url
    }

    private var resolvedStorage: ICloudNotesStorage.Resolution {
        if let cached = _cachedStorage {
            return cached
        }

        let resolved = ICloudNotesStorage.resolve(using: fileManager)
        _cachedStorage = resolved
        return resolved
    }

    /// 记录存储根目录（iCloud Documents 或本地回落），供 Agent 文件工具
    /// 作为沙箱作用域使用。
    var agentStorageRootURL: URL { storageURL }
    
    private func generateFileName(for date: Date) -> String {
        return dateFormatter.string(from: date) + ".md"
    }
    
    private func parseDate(from fileName: String) -> Date? {
        let name = fileName.replacing(".md", with: "")
        return dateFormatter.date(from: name)
    }
    
    private func parseMarkdownFile(content: String) -> (description: String, tags: [String], body: String)? {
        Self.parseMarkdownFile(content: content)
    }

    nonisolated private static func parseMarkdownFile(content: String) -> (description: String, tags: [String], body: String)? {
        let lines = content.components(separatedBy: "\n")
        
        guard lines.first == "---" else {
            return ("", [], content)
        }
        
        var endIndex = -1
        for i in 1..<lines.count {
            if lines[i] == "---" {
                endIndex = i
                break
            }
        }
        
        guard endIndex > 0 else {
            return ("", [], content)
        }
        
        let frontMatterLines = Array(lines[1..<endIndex])
        var description = ""
        var tags: [String] = []
        var inTags = false
        
        for line in frontMatterLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("description:") {
                let value = trimmed.replacing("description:", with: "").trimmingCharacters(in: .whitespaces)
                description = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("tags:") {
                inTags = true
            } else if inTags && trimmed.hasPrefix("- ") {
                let tagValue = trimmed.replacing("- ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !tagValue.isEmpty {
                    tags.append(tagValue)
                }
            } else if !trimmed.hasPrefix("-") && trimmed.contains(":") {
                inTags = false
            }
        }
        
        var bodyStartIndex = endIndex + 1
        while bodyStartIndex < lines.count && lines[bodyStartIndex].trimmingCharacters(in: .whitespaces).isEmpty {
            bodyStartIndex += 1
        }
        
        let body = lines[bodyStartIndex...].joined(separator: "\n")
        
        return (description, tags, body)
    }
    
    private func parseCreatedDate(from content: String) -> Date? {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---" else { return nil }
        
        for line in lines.dropFirst() {
            if line == "---" { break }
            
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("created:") else { continue }
            
            let value = trimmed
                .replacing("created:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            
            return dateFormatter.date(from: value)
        }
        
        return nil
    }

    nonisolated private struct DiskLoadResult: Sendable {
        let storage: ICloudNotesStorage.Resolution
        let loadedItems: [HistoryItem]
        let draft: HistoryItem?
        let tagSnapshot: TagManager.Snapshot
    }

    nonisolated private static func loadItemsFromDisk(
        fileManager: FileManager,
        resolution: ICloudNotesStorage.Resolution,
        draftFileName: String
    ) -> DiskLoadResult {
        let documentsURL = resolution.url
        let dateFormatter = ICloudNotesStorage.makeNoteDateFormatter()
        var itemsByFileName: [String: HistoryItem] = [:]

        let fileURLs = (try? fileManager.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey
            ]
        )) ?? []

        for fileURL in fileURLs {
            if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                continue
            }

            switch ICloudNotesStorage.classifyNoteFile(
                fileName: fileURL.lastPathComponent,
                draftFileName: draftFileName
            ) {
            case .skip, .draft:
                continue

            case .placeholder(let fileName):
                guard itemsByFileName[fileName] == nil else { continue }
                guard let createdAt = dateFormatter.date(from: ICloudNotesStorage.noteStamp(from: fileName)) else {
                    continue
                }
                ICloudNotesStorage.startDownloading(at: fileURL, fileManager: fileManager)
                itemsByFileName[fileName] = HistoryItem(
                    fileName: fileName,
                    createdAt: createdAt,
                    isDownloading: true
                )

            case .markdown(let fileName):
                guard let createdAt = dateFormatter.date(from: ICloudNotesStorage.noteStamp(from: fileName)) else {
                    continue
                }

                if ICloudNotesStorage.needsDownload(at: fileURL) {
                    ICloudNotesStorage.startDownloading(at: fileURL, fileManager: fileManager)
                    if itemsByFileName[fileName] == nil {
                        itemsByFileName[fileName] = HistoryItem(
                            fileName: fileName,
                            createdAt: createdAt,
                            isDownloading: true
                        )
                    }
                    continue
                }

                if let content = ICloudNotesStorage.readUTF8String(at: fileURL),
                   let parsed = parseMarkdownFile(content: content) {
                    itemsByFileName[fileName] = HistoryItem(
                        fileName: fileName,
                        text: parsed.body,
                        createdAt: createdAt,
                        description: parsed.description,
                        tags: parsed.tags
                    )
                } else if ICloudNotesStorage.isUbiquitousItem(at: fileURL) {
                    ICloudNotesStorage.startDownloading(at: fileURL, fileManager: fileManager)
                    if itemsByFileName[fileName] == nil {
                        itemsByFileName[fileName] = HistoryItem(
                            fileName: fileName,
                            createdAt: createdAt,
                            isDownloading: true
                        )
                    }
                }
            }
        }

        startDownloadingDraftIfNeeded(
            documentsURL: documentsURL,
            draftFileName: draftFileName,
            fileManager: fileManager
        )

        let draftURL = documentsURL.appendingPathComponent(draftFileName)
        var loadedDraft: HistoryItem?
        if let content = ICloudNotesStorage.readUTF8String(at: draftURL),
           let parsed = parseMarkdownFile(content: content) {
            loadedDraft = HistoryItem(
                text: parsed.body,
                tags: parsed.tags,
                isDraft: true
            )
        }

        let sortedItems = itemsByFileName.values.sorted { $0.createdAt > $1.createdAt }
        let tagSnapshot = TagManager.snapshot(from: sortedItems.filter { !$0.isDownloading })

        return DiskLoadResult(
            storage: resolution,
            loadedItems: sortedItems,
            draft: loadedDraft,
            tagSnapshot: tagSnapshot
        )
    }

    nonisolated private static func startDownloadingDraftIfNeeded(
        documentsURL: URL,
        draftFileName: String,
        fileManager: FileManager
    ) {
        let draftURL = documentsURL.appendingPathComponent(draftFileName)
        if fileManager.fileExists(atPath: draftURL.path) {
            if ICloudNotesStorage.needsDownload(at: draftURL) || ICloudNotesStorage.readUTF8String(at: draftURL) == nil {
                if ICloudNotesStorage.isUbiquitousItem(at: draftURL) || ICloudNotesStorage.needsDownload(at: draftURL) {
                    ICloudNotesStorage.startDownloading(at: draftURL, fileManager: fileManager)
                }
            }
            return
        }

        let placeholderURL = documentsURL.appendingPathComponent("." + draftFileName + ".icloud")
        if fileManager.fileExists(atPath: placeholderURL.path) {
            ICloudNotesStorage.startDownloading(at: placeholderURL, fileManager: fileManager)
        }
    }

    private func mergeLoadedItems(_ result: DiskLoadResult) {
        if _cachedStorage?.url != result.storage.url {
            lastMetadataSignature = ""
        }
        _cachedStorage = result.storage

        var loadedItems = result.loadedItems
        let existingNames = Set(loadedItems.map(\.fileName))
        let extras = downloadingItemsFromMetadataQuery(existing: existingNames)
        if !extras.isEmpty {
            loadedItems.append(contentsOf: extras)
            loadedItems.sort { $0.createdAt > $1.createdAt }
        }

        let previousIDsByFileName = Dictionary(
            savedItems.map { ($0.fileName, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        loadedItems = loadedItems.map { item in
            guard let previousID = previousIDsByFileName[item.fileName] else { return item }
            return HistoryItem(
                id: previousID,
                fileName: item.fileName,
                text: item.text,
                createdAt: item.createdAt,
                description: item.description,
                tags: item.tags,
                isDraft: item.isDraft,
                isDownloading: item.isDownloading
            )
        }

        // Keep any edits made before disk load finishes, otherwise adopt disk draft.
        let liveDraft = currentDraft
        let hasLiveDraftEdits = !liveDraft.text.isEmpty || !liveDraft.tags.isEmpty
        let mergedDraft = hasLiveDraftEdits ? liveDraft : (result.draft ?? liveDraft)

        items = [mergedDraft] + loadedItems
        TagManager.shared.apply(snapshot: result.tagSnapshot)
        isUsingLocalFallback = result.storage.kind == .local
            && ICloudNotesStorage.hasUsedICloud
            && !DemoModeManager.isEnabledFlag
        hasPendingICloudDownloads = loadedItems.contains(where: \.isDownloading)
        hasLoadedHistory = true
        isLoading = false

        syncMetadataQuery(for: result.storage.kind)
        scheduleICloudResolutionRetryIfNeeded(kind: result.storage.kind)
    }
    
    private func generateMarkdownContent(text: String, description: String, tags: [String], createdAt: Date) -> String {
        var content = "---\n"
        content += "created: \(dateFormatter.string(from: createdAt))\n"
        content += "description: \"\(description)\"\n"
        
        if !tags.isEmpty {
            content += "tags:\n"
            for tag in tags {
                content += "  - \"\(tag)\"\n"
            }
        }
        
        content += "---\n\n"
        content += text
        
        return content
    }
    
    func addRecord(_ text: String, tags: [String] = []) {
        guard !text.isEmpty else { return }
        let documentsURL = storageURL
        
        if let existingItem = items.first(where: { $0.text == text }) {
            deleteRecord(existingItem)
        }
        
        let now = Date.now
        let fileName = generateFileName(for: now)
        let description = String(text.prefix(50))
        let content = generateMarkdownContent(text: text, description: description, tags: tags, createdAt: now)
        
        let fileURL = documentsURL.appendingPathComponent(fileName)
        
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            
            let newItem = HistoryItem(
                fileName: fileName,
                text: text,
                createdAt: now,
                description: description,
                tags: tags
            )
            items.insert(newItem, at: 0)
            TagManager.shared.refreshTags(from: items)
            
        } catch {
            print("Failed to write record to iCloud: \(error)")
        }
    }
    
    func deleteRecord(_ item: HistoryItem) {
        removeFiles(for: item)
        items.removeAll { $0.id == item.id }
        TagManager.shared.refreshTags(from: items)
    }
    
    func deleteRecords(at offsets: IndexSet) {
        for index in offsets {
            removeFiles(for: items[index])
        }
        items.remove(atOffsets: offsets)
        TagManager.shared.refreshTags(from: items)
    }
    
    func deleteRecords(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        
        for item in items where ids.contains(item.id) {
            removeFiles(for: item)
        }
        
        items.removeAll { ids.contains($0.id) }
        
        TagManager.shared.refreshTags(from: items)
    }
    
    func clearAll() {
        for item in items {
            removeFiles(for: item)
        }
        items.removeAll()
        TagManager.shared.refreshTags(from: items)
    }

    private func removeFiles(for item: HistoryItem) {
        guard !item.fileName.isEmpty else { return }
        ICloudNotesStorage.removeNoteFiles(
            named: item.fileName,
            in: storageURL,
            fileManager: fileManager
        )
    }
    
    func addTag(to itemId: UUID, tagName: String) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        guard !items[index].isDownloading else { return }
        
        let trimmedTag = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTag.isEmpty else { return }
        
        if !items[index].tags.contains(trimmedTag) {
            items[index].tags.append(trimmedTag)
            if items[index].isDraft {
                saveDraft()
            } else {
                saveItem(items[index])
            }
            TagManager.shared.refreshTags(from: savedItems)
        }
    }
    
    func removeTag(from itemId: UUID, tagName: String) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        guard !items[index].isDownloading else { return }
        
        items[index].tags.removeAll { $0 == tagName }
        if items[index].isDraft {
            saveDraft()
        } else {
            saveItem(items[index])
        }
        TagManager.shared.refreshTags(from: savedItems)
    }
    
    func toggleTag(for itemId: UUID, tagName: String) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        guard !items[index].isDownloading else { return }
        
        if items[index].tags.contains(tagName) {
            items[index].tags.removeAll { $0 == tagName }
        } else {
            items[index].tags.append(tagName)
        }
        if items[index].isDraft {
            saveDraft()
        } else {
            saveItem(items[index])
        }
        TagManager.shared.refreshTags(from: savedItems)
    }
    
    func getItems(filteredBy tagName: String?) -> [HistoryItem] {
        guard let tagName = tagName else { return items }
        return items.filter { $0.tags.contains(tagName) }
    }
    
    func batchAddTag(to itemIds: Set<UUID>, tagName: String) {
        let trimmedTag = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTag.isEmpty else { return }
        
        for index in items.indices {
            guard itemIds.contains(items[index].id) else { continue }
            guard !items[index].isDownloading else { continue }
            guard !items[index].tags.contains(trimmedTag) else { continue }
            items[index].tags.append(trimmedTag)
            if items[index].isDraft {
                saveDraft()
            } else {
                saveItem(items[index])
            }
        }
        TagManager.shared.refreshTags(from: savedItems)
    }
    
    func batchRemoveTag(from itemIds: Set<UUID>, tagName: String) {
        for index in items.indices {
            guard itemIds.contains(items[index].id) else { continue }
            guard !items[index].isDownloading else { continue }
            guard items[index].tags.contains(tagName) else { continue }
            items[index].tags.removeAll { $0 == tagName }
            if items[index].isDraft {
                saveDraft()
            } else {
                saveItem(items[index])
            }
        }
        TagManager.shared.refreshTags(from: savedItems)
    }
    
    func renameTag(from oldName: String, to newName: String) {
        let trimmedNewName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNewName.isEmpty, oldName != trimmedNewName else { return }
        
        for index in items.indices {
            guard !items[index].isDownloading else { continue }
            if let tagIndex = items[index].tags.firstIndex(of: oldName) {
                items[index].tags[tagIndex] = trimmedNewName
                saveItem(items[index])
            }
        }
        
        TagManager.shared.refreshTags(from: items)
    }
    
    private func saveItem(_ item: HistoryItem) {
        guard !item.isDownloading, !item.fileName.isEmpty else { return }
        let documentsURL = storageURL
        
        let content = generateMarkdownContent(
            text: item.text,
            description: item.description,
            tags: item.tags,
            createdAt: item.createdAt
        )
        
        let fileURL = documentsURL.appendingPathComponent(item.fileName)
        
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to update record: \(error)")
        }
    }
    
    func switchDataset() {
        iCloudRetryTask?.cancel()
        metadataReloadTask?.cancel()
        stopMetadataQuery()
        loadGeneration += 1
        _cachedStorage = nil
        items = []
        lastClearedText = ""
        hasLoadedHistory = false
        isUsingLocalFallback = false
        hasPendingICloudDownloads = false
        isLoading = false
        lastMetadataSignature = ""
        loadItemsIfNeeded(force: true, reevaluateStorage: true)
    }

    func loadItems() {
        loadItemsIfNeeded(force: true)
    }

    func refreshFromEnvironment() {
        guard !DemoModeManager.isEnabledFlag else { return }
        loadItemsIfNeeded(force: true, reevaluateStorage: true)
    }

    func loadItemsIfNeeded(force: Bool = false, reevaluateStorage: Bool = false) {
        if isLoading && !force && !reevaluateStorage { return }
        if hasLoadedHistory && !force && !hasPendingICloudDownloads && !reevaluateStorage { return }

        isLoading = true
        loadGeneration += 1
        let generation = loadGeneration

        let fileManager = self.fileManager
        let cachedStorage = reevaluateStorage ? nil : self._cachedStorage
        let draftFileName = self.draftFileName

        Task.detached(priority: .userInitiated) {
            let resolution = cachedStorage ?? ICloudNotesStorage.resolve(using: fileManager)
            if resolution.kind == .iCloud {
                ICloudNotesStorage.migrateLocalFallbackNotes(
                    to: resolution.url,
                    fileManager: fileManager
                )
            }

            let result = Self.loadItemsFromDisk(
                fileManager: fileManager,
                resolution: resolution,
                draftFileName: draftFileName
            )

            await MainActor.run {
                guard generation == self.loadGeneration else { return }
                self.mergeLoadedItems(result)
            }
        }
    }
    
    func refresh() {
        loadItemsIfNeeded(force: true)
    }

    private func observeUbiquityIdentityChanges() {
        NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                HistoryManager.shared.refreshFromEnvironment()
            }
        }
    }

    private func scheduleICloudResolutionRetryIfNeeded(kind: ICloudNotesStorage.Kind) {
        iCloudRetryTask?.cancel()
        guard kind == .local, !DemoModeManager.isEnabledFlag else { return }

        iCloudRetryTask = Task.detached { [weak self] in
            var delay: Double = 2
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }

                let resolved = ICloudNotesStorage.resolve(using: FileManager.default)
                if resolved.kind == .iCloud {
                    await self?.refreshFromEnvironment()
                    return
                }
                delay = min(delay * 2, 300)
            }
        }
    }

    private func syncMetadataQuery(for kind: ICloudNotesStorage.Kind) {
        if kind == .iCloud {
            startMetadataQueryIfNeeded()
        } else {
            stopMetadataQuery()
        }
    }

    private func startMetadataQueryIfNeeded() {
        guard metadataQuery == nil else { return }

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(
            format: "%K LIKE[c] '*.md' OR %K LIKE[c] '*.icloud'",
            NSMetadataItemFSNameKey,
            NSMetadataItemFSNameKey
        )

        let finishObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { _ in
            Task { @MainActor in
                HistoryManager.shared.handleMetadataQueryChange()
            }
        }
        let updateObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { _ in
            Task { @MainActor in
                HistoryManager.shared.handleMetadataQueryChange()
            }
        }

        metadataObservers = [finishObserver, updateObserver]
        metadataQuery = query
        query.start()
    }

    private func stopMetadataQuery() {
        metadataReloadTask?.cancel()
        metadataReloadTask = nil

        if let query = metadataQuery {
            query.stop()
        }
        metadataQuery = nil

        for observer in metadataObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        metadataObservers = []
        lastMetadataSignature = ""
    }

    private func handleMetadataQueryChange() {
        guard let query = metadataQuery else { return }

        query.disableUpdates()
        defer { query.enableUpdates() }

        var parts: [String] = []
        for object in query.results {
            guard let item = object as? NSMetadataItem else { continue }
            let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? ""
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String ?? ""
            parts.append("\(name):\(status)")

            if status != NSMetadataUbiquitousItemDownloadingStatusCurrent,
               let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
                ICloudNotesStorage.startDownloading(at: url, fileManager: fileManager)
            }
        }

        let signature = parts.sorted().joined(separator: "|")
        guard signature != lastMetadataSignature else { return }
        lastMetadataSignature = signature

        metadataReloadTask?.cancel()
        metadataReloadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.loadItemsIfNeeded(force: true)
        }
    }

    private func downloadingItemsFromMetadataQuery(existing: Set<String>) -> [HistoryItem] {
        guard let query = metadataQuery else { return [] }

        let formatter = ICloudNotesStorage.makeNoteDateFormatter()
        var extras: [HistoryItem] = []
        var seen = existing

        for object in query.results {
            guard let item = object as? NSMetadataItem else { continue }
            let rawName = item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? ""

            let fileName: String
            switch ICloudNotesStorage.classifyNoteFile(fileName: rawName, draftFileName: draftFileName) {
            case .markdown(let name), .placeholder(let name):
                fileName = name
            case .skip, .draft:
                continue
            }

            guard seen.insert(fileName).inserted else { continue }
            guard let createdAt = formatter.date(from: ICloudNotesStorage.noteStamp(from: fileName)) else {
                continue
            }

            if let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
                ICloudNotesStorage.startDownloading(at: url, fileManager: fileManager)
            }

            extras.append(
                HistoryItem(
                    fileName: fileName,
                    createdAt: createdAt,
                    isDownloading: true
                )
            )
        }

        return extras
    }
    
    func exportAllNotes() throws -> URL {
        let documentsURL = storageURL
        
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("NotesExport_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let fileURLs = try fileManager.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        
        for fileURL in fileURLs {
            guard fileURL.pathExtension == "md" else { continue }
            let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
            try fileManager.copyItem(at: fileURL, to: destURL)
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let zipName = "Notes_\(dateFormatter.string(from: Date.now)).zip"
        let zipURL = fileManager.temporaryDirectory.appendingPathComponent(zipName)
        
        try? fileManager.removeItem(at: zipURL)
        
        let coordinator = NSFileCoordinator()
        var error: NSError?
        
        coordinator.coordinate(readingItemAt: tempDir, options: .forUploading, error: &error) { zippedURL in
            try? fileManager.copyItem(at: zippedURL, to: zipURL)
        }
        
        try? fileManager.removeItem(at: tempDir)
        
        if let error = error {
            throw error
        }
        
        return zipURL
    }
    
    func importNotes(from urls: [URL]) throws -> NotesImportResult {
        guard !urls.isEmpty else { throw NotesImportError.noFilesSelected }
        
        var candidates: [ImportCandidate] = []
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            candidates.append(contentsOf: try importCandidates(from: url))
        }
        
        guard !candidates.isEmpty else { throw NotesImportError.noImportableNotes }
        
        let documentsURL = storageURL
        var existingTexts = Set(savedItems.map(\.text))
        var reservedFileNames = Set(savedItems.map(\.fileName))
        reservedFileNames.insert(draftFileName)
        
        var importedItems: [HistoryItem] = []
        var skippedCount = 0
        
        for candidate in candidates {
            guard let parsed = parseMarkdownFile(content: candidate.content) else {
                skippedCount += 1
                continue
            }
            
            guard !parsed.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                skippedCount += 1
                continue
            }
            
            guard !existingTexts.contains(parsed.body) else {
                skippedCount += 1
                continue
            }
            
            let preferredDate = parseDate(from: candidate.fileName) ?? parseCreatedDate(from: candidate.content) ?? Date.now
            let createdAt = uniqueImportDate(startingAt: preferredDate, reservedFileNames: &reservedFileNames)
            let fileName = generateFileName(for: createdAt)
            let description = parsed.description.isEmpty ? String(parsed.body.prefix(50)) : parsed.description
            let item = HistoryItem(
                fileName: fileName,
                text: parsed.body,
                createdAt: createdAt,
                description: description,
                tags: parsed.tags
            )
            let content = generateMarkdownContent(
                text: item.text,
                description: item.description,
                tags: item.tags,
                createdAt: item.createdAt
            )
            let fileURL = documentsURL.appendingPathComponent(fileName)
            
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            
            importedItems.append(item)
            existingTexts.insert(parsed.body)
        }
        
        guard !importedItems.isEmpty else {
            return NotesImportResult(importedCount: 0, skippedCount: skippedCount)
        }
        
        let draft = currentDraft
        let mergedSavedItems = (importedItems + savedItems).sorted { $0.createdAt > $1.createdAt }
        items = [draft] + mergedSavedItems
        TagManager.shared.refreshTags(from: savedItems)
        
        return NotesImportResult(importedCount: importedItems.count, skippedCount: skippedCount)
    }

}

private struct ImportCandidate {
    let fileName: String
    let content: String
}

private extension HistoryManager {
    func uniqueImportDate(startingAt preferredDate: Date, reservedFileNames: inout Set<String>) -> Date {
        var candidateDate = preferredDate
        
        while reservedFileNames.contains(generateFileName(for: candidateDate)) {
            candidateDate = candidateDate.addingTimeInterval(1)
        }
        
        reservedFileNames.insert(generateFileName(for: candidateDate))
        return candidateDate
    }
    
    func importCandidates(from url: URL) throws -> [ImportCandidate] {
        if url.hasDirectoryPath {
            return try importCandidatesFromDirectory(url)
        }
        
        switch url.pathExtension.lowercased() {
        case "zip":
            return try Self.importCandidatesFromZip(url: url, maxEntrySize: maxImportEntrySize)
        case "md", "markdown":
            return [try importCandidateFromMarkdownFile(url)]
        default:
            return []
        }
    }
    
    func importCandidatesFromDirectory(_ url: URL) throws -> [ImportCandidate] {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        
        var candidates: [ImportCandidate] = []
        for case let fileURL as URL in enumerator {
            guard Self.isImportableMarkdownFileName(fileURL.lastPathComponent) else { continue }
            candidates.append(try importCandidateFromMarkdownFile(fileURL))
        }
        return candidates
    }
    
    func importCandidateFromMarkdownFile(_ url: URL) throws -> ImportCandidate {
        let content = try String(contentsOf: url, encoding: .utf8)
        return ImportCandidate(fileName: url.lastPathComponent, content: content)
    }
    
    static func importCandidatesFromZip(url: URL, maxEntrySize: Int) throws -> [ImportCandidate] {
        let data = try Data(contentsOf: url)
        let entries = try zipEntries(in: data)
        var candidates: [ImportCandidate] = []
        
        for entry in entries {
            guard isImportableMarkdownFileName(entry.fileName) else { continue }
            guard entry.uncompressedSize <= maxEntrySize else {
                throw NotesImportError.fileTooLarge(entry.fileName)
            }
            
            let fileData = try zipEntryData(entry, in: data)
            guard let content = String(data: fileData, encoding: .utf8) else {
                throw NotesImportError.corruptZipEntry(entry.fileName)
            }
            
            candidates.append(ImportCandidate(fileName: entry.fileName, content: content))
        }
        
        return candidates
    }
    
    static func isImportableMarkdownFileName(_ fileName: String) -> Bool {
        let lowercased = fileName.lowercased()
        guard lowercased.hasSuffix(".md") || lowercased.hasSuffix(".markdown") else { return false }
        guard !fileName.hasPrefix(".") else { return false }
        guard lowercased != "_draft.md" else { return false }
        return true
    }
}

private struct ZipEntry {
    let path: String
    let compressionMethod: Int
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
    
    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

private extension HistoryManager {
    static func zipEntries(in data: Data) throws -> [ZipEntry] {
        let endOffset = try endOfCentralDirectoryOffset(in: data)
        let entryCount = try intFromUInt16(data, at: endOffset + 10)
        let centralDirectoryOffset = try intFromUInt32(data, at: endOffset + 16)
        
        guard centralDirectoryOffset < data.count else {
            throw NotesImportError.invalidZipArchive
        }
        
        var offset = centralDirectoryOffset
        var entries: [ZipEntry] = []
        
        for _ in 0..<entryCount {
            guard offset + 46 <= data.count else {
                throw NotesImportError.invalidZipArchive
            }
            guard try uint32(data, at: offset) == 0x02014b50 else {
                throw NotesImportError.invalidZipArchive
            }
            
            let compressionMethod = try intFromUInt16(data, at: offset + 10)
            let compressedSize = try intFromUInt32(data, at: offset + 20)
            let uncompressedSize = try intFromUInt32(data, at: offset + 24)
            let fileNameLength = try intFromUInt16(data, at: offset + 28)
            let extraFieldLength = try intFromUInt16(data, at: offset + 30)
            let fileCommentLength = try intFromUInt16(data, at: offset + 32)
            let localHeaderOffset = try intFromUInt32(data, at: offset + 42)
            let nameStart = offset + 46
            let nameEnd = nameStart + fileNameLength
            
            guard nameEnd <= data.count else {
                throw NotesImportError.invalidZipArchive
            }
            
            let nameData = data.subdata(in: nameStart..<nameEnd)
            let path = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .ascii) ?? ""
            
            if !path.isEmpty && !path.hasSuffix("/") && !pathComponents(path).contains("__MACOSX") {
                entries.append(ZipEntry(
                    path: path,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                ))
            }
            
            offset = nameEnd + extraFieldLength + fileCommentLength
        }
        
        return entries
    }
    
    static func zipEntryData(_ entry: ZipEntry, in archiveData: Data) throws -> Data {
        let localHeaderOffset = entry.localHeaderOffset
        guard localHeaderOffset + 30 <= archiveData.count else {
            throw NotesImportError.invalidZipArchive
        }
        guard try uint32(archiveData, at: localHeaderOffset) == 0x04034b50 else {
            throw NotesImportError.invalidZipArchive
        }
        
        let localFileNameLength = try intFromUInt16(archiveData, at: localHeaderOffset + 26)
        let localExtraFieldLength = try intFromUInt16(archiveData, at: localHeaderOffset + 28)
        let dataStart = localHeaderOffset + 30 + localFileNameLength + localExtraFieldLength
        let dataEnd = dataStart + entry.compressedSize
        
        guard dataStart <= archiveData.count, dataEnd <= archiveData.count else {
            throw NotesImportError.invalidZipArchive
        }
        
        let compressedData = archiveData.subdata(in: dataStart..<dataEnd)
        switch entry.compressionMethod {
        case 0:
            return compressedData
        case 8:
            return try inflateRawDeflate(compressedData, uncompressedSize: entry.uncompressedSize)
        default:
            throw NotesImportError.unsupportedCompressionMethod(entry.compressionMethod)
        }
    }
    
    static func endOfCentralDirectoryOffset(in data: Data) throws -> Int {
        guard data.count >= 22 else {
            throw NotesImportError.invalidZipArchive
        }
        
        let minimumOffset = max(0, data.count - 65_557)
        var offset = data.count - 22
        
        while offset >= minimumOffset {
            if try uint32(data, at: offset) == 0x06054b50 {
                return offset
            }
            offset -= 1
        }
        
        throw NotesImportError.invalidZipArchive
    }
    
    static func inflateRawDeflate(_ data: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        
        var output = Data(count: uncompressedSize)
        let outputCount = output.count
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw NotesImportError.decompressionFailed
        }
        defer { inflateEnd(&stream) }
        
        let status = data.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                guard let inputBase = inputBuffer.bindMemory(to: Bytef.self).baseAddress,
                      let outputBase = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    return Z_STREAM_ERROR
                }
                
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
                stream.avail_in = uInt(data.count)
                stream.next_out = outputBase
                stream.avail_out = uInt(outputCount)
                
                return inflate(&stream, Z_FINISH)
            }
        }
        
        guard status == Z_STREAM_END else {
            throw NotesImportError.decompressionFailed
        }
        
        return output
    }
    
    static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
    
    static func intFromUInt16(_ data: Data, at offset: Int) throws -> Int {
        Int(try uint16(data, at: offset))
    }
    
    static func intFromUInt32(_ data: Data, at offset: Int) throws -> Int {
        let value = try uint32(data, at: offset)
        guard value < UInt32.max else {
            throw NotesImportError.unsupportedZipArchive
        }
        return Int(value)
    }
    
    static func uint16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw NotesImportError.invalidZipArchive
        }
        
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
    
    static func uint32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw NotesImportError.invalidZipArchive
        }
        
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
