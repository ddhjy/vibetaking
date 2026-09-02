import Foundation

nonisolated struct NoteCacheEntry: Codable, Sendable, Equatable {
    let fileName: String
    let createdAt: Date
    let text: String
    let description: String
    let tags: [String]
    let modificationDate: Date?
    let fileSize: Int?

    func matches(modificationDate: Date?, fileSize: Int?) -> Bool {
        guard let modificationDate, let fileSize,
              let cachedDate = self.modificationDate, let cachedSize = self.fileSize else {
            return false
        }
        return abs(cachedDate.timeIntervalSince(modificationDate)) < 0.5 && cachedSize == fileSize
    }

    func makeItem(isDownloading: Bool) -> HistoryItem {
        HistoryItem(
            fileName: fileName,
            text: text,
            createdAt: createdAt,
            description: description,
            tags: tags,
            isDownloading: isDownloading
        )
    }
}

nonisolated struct HistorySnapshot: Codable, Sendable {
    var version: Int
    var storageKind: ICloudNotesStorage.Kind
    var storagePath: String
    var entries: [NoteCacheEntry]
}

nonisolated enum HistorySnapshotStore {
    static let currentVersion = 1

    nonisolated private static var fileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        return caches.appending(path: "history-snapshot.json", directoryHint: .notDirectory)
    }

    nonisolated static func load() -> HistorySnapshot? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let snapshot = try decoder.decode(HistorySnapshot.self, from: Data(contentsOf: url))
            guard snapshot.version == currentVersion else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return snapshot
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    nonisolated static func save(_ snapshot: HistorySnapshot) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to write history snapshot: \(error)")
        }
    }
}
