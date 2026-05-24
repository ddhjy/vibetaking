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
    
    init(id: UUID = UUID(), fileName: String = "", text: String = "", createdAt: Date = .now, description: String = "", tags: [String] = [], isDraft: Bool = false) {
        self.id = id
        self.fileName = fileName
        self.text = text
        self.createdAt = createdAt
        self.description = description.isEmpty && !text.isEmpty ? String(text.prefix(50)) : description
        self.tags = tags
        self.isDraft = isDraft
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
    
    private func loadCachedTags() {
        guard let data = UserDefaults.standard.data(forKey: cachedTagsKey),
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
            UserDefaults.standard.set(data, forKey: cachedTagsKey)
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
        let savedTime = UserDefaults.standard.double(forKey: lastSelectedTagsTimeKey)
        if savedTime > 0 {
            let elapsed = Date().timeIntervalSince1970 - savedTime
            if elapsed > tagMemoryExpiration {
                lastSelectedTags = []
                return
            }
        }
        
        guard let data = UserDefaults.standard.data(forKey: lastSelectedTagsKey),
              let savedTags = try? JSONDecoder().decode([String].self, from: data) else {
            lastSelectedTags = []
            return
        }
        lastSelectedTags = savedTags
    }
    
    func saveLastSelectedTags(_ tags: [String]) {
        lastSelectedTags = tags
        if let data = try? JSONEncoder().encode(tags) {
            UserDefaults.standard.set(data, forKey: lastSelectedTagsKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSelectedTagsTimeKey)
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
    
    private var _cachedStorageURL: URL?
    
    private let fileManager = FileManager.default
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm-ss"
        return formatter
    }()
    
    private let maxImportEntrySize = 50 * 1024 * 1024
    
    private init() {
        ensureDraftExists()
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
        notifyDraftDidChange(text)
    }

    func clearDraft() {
        guard let index = items.firstIndex(where: { $0.isDraft }) else { return }
        let currentText = items[index].text
        if !currentText.isEmpty {
            lastClearedText = currentText
        }
        items[index].text = ""
        saveDraft()
        notifyDraftDidChange("")
    }

    func restoreLastClearedDraft() {
        guard let index = items.firstIndex(where: { $0.isDraft }), !lastClearedText.isEmpty else { return }
        items[index].text = lastClearedText
        lastClearedText = ""
        saveDraft()
        notifyDraftDidChange(items[index].text)
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
        notifyDraftDidChange(newDraft.text)
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
        if let cached = _cachedStorageURL {
            return cached
        }
        
        let url = resolveStorageURL()
        _cachedStorageURL = url
        return url
    }
    
    private func resolveStorageURL() -> URL {
        Self.resolveStorageURL(using: fileManager)
    }

    nonisolated private static func resolveStorageURL(using fileManager: FileManager) -> URL {
        if let documentsURL = iCloudDocumentsURL(using: fileManager) {
            return documentsURL
        }
        
        let localURL = URL.documentsDirectory.appending(path: "Records")
        
        if !fileManager.fileExists(atPath: localURL.path) {
            try? fileManager.createDirectory(at: localURL, withIntermediateDirectories: true)
        }
        
        print("Using local storage: \(localURL.path)")
        return localURL
    }

    nonisolated private static func iCloudDocumentsURL(using fileManager: FileManager) -> URL? {
        let containerIdentifier = "iCloud.cn.1pointech.vibetaking"

        guard fileManager.ubiquityIdentityToken != nil else {
            print("iCloud unavailable: no signed-in iCloud account or iCloud Drive is disabled")
            return nil
        }

        guard let containerURL = fileManager.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            print("iCloud container unavailable: \(containerIdentifier)")
            return nil
        }

        let documentsURL = containerURL.appendingPathComponent("Documents", isDirectory: true)

        do {
            try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        } catch {
            print("Failed to create iCloud Documents directory: \(error)")
            return nil
        }

        print("Using iCloud storage: \(documentsURL.path)")
        return documentsURL
    }
    
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
        let storageURL: URL
        let loadedItems: [HistoryItem]
        let draft: HistoryItem?
        let tagSnapshot: TagManager.Snapshot
    }

    nonisolated private static func loadItemsFromDisk(
        fileManager: FileManager,
        cachedStorageURL: URL?,
        draftFileName: String
    ) -> DiskLoadResult {
        let documentsURL = cachedStorageURL ?? resolveStorageURL(using: fileManager)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmm-ss"

        var loadedItems: [HistoryItem] = []

        if let fileURLs = try? fileManager.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) {
            for fileURL in fileURLs {
                guard fileURL.pathExtension == "md" else { continue }

                let fileName = fileURL.lastPathComponent
                if fileName == draftFileName { continue }

                let name = fileName.replacing(".md", with: "")
                guard let createdAt = dateFormatter.date(from: name) else { continue }

                guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
                      let parsed = parseMarkdownFile(content: content) else {
                    continue
                }

                loadedItems.append(
                    HistoryItem(
                        fileName: fileName,
                        text: parsed.body,
                        createdAt: createdAt,
                        description: parsed.description,
                        tags: parsed.tags
                    )
                )
            }
        }

        let draftURL = documentsURL.appendingPathComponent(draftFileName)
        var loadedDraft: HistoryItem?
        if fileManager.fileExists(atPath: draftURL.path),
           let content = try? String(contentsOf: draftURL, encoding: .utf8),
           let parsed = parseMarkdownFile(content: content) {
            loadedDraft = HistoryItem(
                text: parsed.body,
                tags: parsed.tags,
                isDraft: true
            )
        }

        let sortedItems = loadedItems.sorted { $0.createdAt > $1.createdAt }
        let tagSnapshot = TagManager.snapshot(from: sortedItems)

        return DiskLoadResult(
            storageURL: documentsURL,
            loadedItems: sortedItems,
            draft: loadedDraft,
            tagSnapshot: tagSnapshot
        )
    }

    private func mergeLoadedItems(_ result: DiskLoadResult) {
        _cachedStorageURL = result.storageURL

        // Keep any edits made before disk load finishes, otherwise adopt disk draft.
        let liveDraft = currentDraft
        let hasLiveDraftEdits = !liveDraft.text.isEmpty || !liveDraft.tags.isEmpty
        let mergedDraft = hasLiveDraftEdits ? liveDraft : (result.draft ?? liveDraft)

        items = [mergedDraft] + result.loadedItems
        TagManager.shared.apply(snapshot: result.tagSnapshot)
        hasLoadedHistory = true
        isLoading = false
        notifyDraftDidChange(mergedDraft.text)
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
        let documentsURL = storageURL
        
        let fileURL = documentsURL.appendingPathComponent(item.fileName)
        
        do {
            try fileManager.removeItem(at: fileURL)
            items.removeAll { $0.id == item.id }
            TagManager.shared.refreshTags(from: items)
        } catch {
            print("Failed to delete record: \(error)")
            items.removeAll { $0.id == item.id }
        }
    }
    
    func deleteRecords(at offsets: IndexSet) {
        let documentsURL = storageURL
        for index in offsets {
            let item = items[index]
            let fileURL = documentsURL.appendingPathComponent(item.fileName)
            try? fileManager.removeItem(at: fileURL)
        }
        items.remove(atOffsets: offsets)
        TagManager.shared.refreshTags(from: items)
    }
    
    func deleteRecords(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        
        let documentsURL = storageURL
        
        for item in items where ids.contains(item.id) {
            let fileURL = documentsURL.appendingPathComponent(item.fileName)
            try? fileManager.removeItem(at: fileURL)
        }
        
        items.removeAll { ids.contains($0.id) }
        
        TagManager.shared.refreshTags(from: items)
    }
    
    func clearAll() {
        let documentsURL = storageURL
        
        for item in items {
            let fileURL = documentsURL.appendingPathComponent(item.fileName)
            try? fileManager.removeItem(at: fileURL)
        }
        items.removeAll()
        TagManager.shared.refreshTags(from: items)
    }
    
    func addTag(to itemId: UUID, tagName: String) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        
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
            if let tagIndex = items[index].tags.firstIndex(of: oldName) {
                items[index].tags[tagIndex] = trimmedNewName
                saveItem(items[index])
            }
        }
        
        TagManager.shared.refreshTags(from: items)
    }
    
    private func saveItem(_ item: HistoryItem) {
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
    
    func loadItems() {
        loadItemsIfNeeded(force: true)
    }

    func loadItemsIfNeeded(force: Bool = false) {
        if isLoading { return }
        if hasLoadedHistory && !force { return }

        isLoading = true

        let fileManager = self.fileManager
        let cachedStorageURL = self._cachedStorageURL
        let draftFileName = self.draftFileName

        Task.detached(priority: .userInitiated) {
            let result = Self.loadItemsFromDisk(
                fileManager: fileManager,
                cachedStorageURL: cachedStorageURL,
                draftFileName: draftFileName
            )

            await MainActor.run {
                self.mergeLoadedItems(result)
            }
        }
    }
    
    func refresh() {
        loadItemsIfNeeded(force: true)
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

    private func notifyDraftDidChange(_ text: String) {
        Task { @MainActor in
            AutoPasteSyncManager.shared.scheduleDraftSync(text: text)
        }
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
