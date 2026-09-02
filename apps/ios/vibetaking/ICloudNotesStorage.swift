import Foundation

/// iCloud Drive 笔记目录的解析、占位符识别、下载触发和本地回落迁移。
nonisolated enum ICloudNotesStorage {
    static let containerIdentifier = "iCloud.cn.1pointech.vibetaking"
    static let localFallbackDirectoryName = "Records"
    static let hasUsedICloudKey = "hasUsedICloudStorage"

    enum Kind: String, Sendable, Equatable, Codable {
        case demo
        case iCloud
        case local
    }

    struct Resolution: Sendable, Equatable {
        let url: URL
        let kind: Kind
    }

    enum NoteFileClassification: Sendable, Equatable {
        case skip
        case draft
        case markdown(String)
        case placeholder(String)
    }

    nonisolated static var hasUsedICloud: Bool {
        UserDefaults.standard.bool(forKey: hasUsedICloudKey)
    }

    nonisolated static func rememberUsedICloud() {
        UserDefaults.standard.set(true, forKey: hasUsedICloudKey)
    }

    nonisolated static func makeNoteDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmm-ss"
        return formatter
    }

    nonisolated static func noteStamp(from fileName: String) -> String {
        let lowercased = fileName.lowercased()
        if lowercased.hasSuffix(".md") {
            return String(fileName.dropLast(3))
        }
        return fileName
    }

    nonisolated static func localFallbackURL(using fileManager: FileManager) -> URL {
        let localURL = URL.documentsDirectory.appending(path: localFallbackDirectoryName, directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: localURL.path) {
            try? fileManager.createDirectory(at: localURL, withIntermediateDirectories: true)
        }
        return localURL
    }

    nonisolated static func resolve(using fileManager: FileManager) -> Resolution {
        if DemoModeManager.isEnabledFlag {
            let demoURL = DemoModeManager.demoStorageURL(fileManager: fileManager)
            print("Using demo storage: \(demoURL.path)")
            return Resolution(url: demoURL, kind: .demo)
        }

        if let documentsURL = iCloudDocumentsURL(using: fileManager) {
            rememberUsedICloud()
            return Resolution(url: documentsURL, kind: .iCloud)
        }

        let localURL = localFallbackURL(using: fileManager)
        print("Using local storage: \(localURL.path)")
        return Resolution(url: localURL, kind: .local)
    }

    nonisolated static func iCloudDocumentsURL(using fileManager: FileManager) -> URL? {
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

    nonisolated static func classifyNoteFile(fileName: String, draftFileName: String) -> NoteFileClassification {
        if let logicalName = noteFileName(fromICloudPlaceholder: fileName) {
            return logicalName == draftFileName ? .draft : .placeholder(logicalName)
        }

        guard fileName.lowercased().hasSuffix(".md"), !fileName.hasPrefix(".") else {
            return .skip
        }

        return fileName == draftFileName ? .draft : .markdown(fileName)
    }

    /// `.2026-01-01-0000-00.md.icloud` 或 `2026-01-01-0000-00.md.icloud` → `2026-01-01-0000-00.md`
    nonisolated static func noteFileName(fromICloudPlaceholder fileName: String) -> String? {
        var name = fileName
        if name.hasPrefix(".") {
            name.removeFirst()
        }

        let suffix = ".icloud"
        guard name.lowercased().hasSuffix(suffix) else { return nil }
        name.removeLast(suffix.count)
        guard name.lowercased().hasSuffix(".md"), !name.hasPrefix(".") else { return nil }
        return name
    }

    nonisolated static func isUbiquitousItem(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    nonisolated static func needsDownload(at url: URL) -> Bool {
        guard let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus else {
            return false
        }
        return status != .current
    }

    nonisolated static func startDownloading(at url: URL, fileManager: FileManager) {
        do {
            try fileManager.startDownloadingUbiquitousItem(at: url)
        } catch {
            print("Failed to start iCloud download for \(url.lastPathComponent): \(error)")
        }
    }

    nonisolated static func readUTF8String(at url: URL) -> String? {
        var coordinated: String?
        let coordinator = NSFileCoordinator()
        var error: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { newURL in
            coordinated = try? String(contentsOf: newURL, encoding: .utf8)
        }
        return coordinated
    }

    nonisolated static func removeNoteFiles(
        named fileName: String,
        in directory: URL,
        fileManager: FileManager
    ) {
        let fileURL = directory.appendingPathComponent(fileName)
        try? fileManager.removeItem(at: fileURL)
        let placeholderURL = directory.appendingPathComponent("." + fileName + ".icloud")
        try? fileManager.removeItem(at: placeholderURL)
    }

    /// 把回落期写在本地 `Records/` 的笔记搬回 iCloud，避免切回云端后新笔记从列表消失。
    nonisolated static func migrateLocalFallbackNotes(
        to iCloudDocumentsURL: URL,
        fileManager: FileManager
    ) {
        let localURL = URL.documentsDirectory.appending(path: localFallbackDirectoryName, directoryHint: .isDirectory)
        guard localURL.standardizedFileURL != iCloudDocumentsURL.standardizedFileURL else { return }
        guard fileManager.fileExists(atPath: localURL.path) else { return }

        guard let files = try? fileManager.contentsOfDirectory(
            at: localURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for fileURL in files {
            guard fileURL.pathExtension.lowercased() == "md" else { continue }
            let destination = iCloudDocumentsURL.appendingPathComponent(fileURL.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                continue
            }
            do {
                try fileManager.moveItem(at: fileURL, to: destination)
            } catch {
                print("Failed to migrate \(fileURL.lastPathComponent) to iCloud: \(error)")
            }
        }
    }

#if DEBUG
    static func debugAssertParsing() {
        precondition(noteFileName(fromICloudPlaceholder: ".2026-01-01-0000-00.md.icloud") == "2026-01-01-0000-00.md")
        precondition(noteFileName(fromICloudPlaceholder: "2026-01-01-0000-00.md.icloud") == "2026-01-01-0000-00.md")
        precondition(noteFileName(fromICloudPlaceholder: "notes.md") == nil)
        precondition(classifyNoteFile(fileName: ".2026-01-01-0000-00.md.icloud", draftFileName: "_draft.md") == .placeholder("2026-01-01-0000-00.md"))
        precondition(classifyNoteFile(fileName: "2026-01-01-0000-00.md", draftFileName: "_draft.md") == .markdown("2026-01-01-0000-00.md"))
        precondition(classifyNoteFile(fileName: "_draft.md", draftFileName: "_draft.md") == .draft)
        precondition(classifyNoteFile(fileName: "._draft.md.icloud", draftFileName: "_draft.md") == .draft)
        precondition(classifyNoteFile(fileName: ".DS_Store", draftFileName: "_draft.md") == .skip)
        precondition(noteStamp(from: "2026-01-01-0000-00.md") == "2026-01-01-0000-00")
    }
#endif
}
