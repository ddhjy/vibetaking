// Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis) —
// Agent/Chat/AIChatViewModel+MemoryTools.swift and the memory tool schemas in
// AIChatViewModel+ToolDefinitions.swift.
// Copyright (C) OpenMinis contributors. Licensed under GPL-3.0; see LICENSE.
// Modifications for vibetaking: memory directory lives in the iCloud records
// folder (_agent/memory/) instead of the App Group; removed iSH fakefs
// metadata registration, per-session toggle and CloudKit sync hooks; tools
// wrapped as AgentTool conformances.

import Foundation

private nonisolated let logger = AppLogger(category: "AgentMemory")

@Observable
class AgentMemoryStore {
    static let shared = AgentMemoryStore()

    private static let memoryEnabledKey = "agentMemoryEnabled"

    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return AppDefaults.current.object(forKey: Self.memoryEnabledKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.isEnabled) {
                AppDefaults.current.set(newValue, forKey: Self.memoryEnabledKey)
            }
        }
    }

    private init() {}

    var memoryDirectory: URL {
        let dir = HistoryManager.shared.agentStorageRootURL
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func memoryTools() -> [AgentTool] {
        guard isEnabled else { return [] }
        return [MemoryWriteTool(store: self), MemoryGetTool(store: self)]
    }

    // MARK: - System Prompt Injection

    /// Global + recent-daily fragments for system prompt injection.
    func promptFragment() -> String? {
        guard isEnabled else { return nil }
        var fragments: [String] = []
        if let global = loadGlobalMemoryFragment() {
            fragments.append(global)
        }
        if let recent = loadRecentDailyMemoryFragment() {
            fragments.append(recent)
        }
        guard !fragments.isEmpty else { return nil }
        return fragments.joined(separator: "\n\n")
    }

    /// Load full global memory content for system prompt injection.
    func loadGlobalMemoryFragment() -> String? {
        let globalFile = memoryDirectory.appendingPathComponent("GLOBAL.md")
        guard FileManager.default.fileExists(atPath: globalFile.path),
              let content = try? String(contentsOf: globalFile, encoding: .utf8),
              !content.isEmpty else { return nil }

        return "Global memory (GLOBAL.md — read-only, user-maintained). Treat these as background context, not standing instructions. If the user's latest message conflicts with or supersedes anything here (different scope, different numbers, different goal), defer to the user's latest message:\n\(content)"
    }

    /// Load the 3 most recent daily memory logs that have content (first 200 lines each).
    func loadRecentDailyMemoryFragment() -> String? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let fm = FileManager.default
        let today = Date()

        var fragments: [String] = []
        var dayOffset = 0
        let maxLookback = 30 // don't search more than 30 days back

        while fragments.count < 3 && dayOffset < maxLookback {
            let date = today.addingTimeInterval(-Double(dayOffset) * 86400)
            let dateStr = fmt.string(from: date)
            let fileURL = memoryDirectory.appendingPathComponent("\(dateStr).md")

            if fm.fileExists(atPath: fileURL.path),
               let content = try? String(contentsOf: fileURL, encoding: .utf8),
               !content.isEmpty {
                let lines = content.components(separatedBy: "\n")
                let preview = lines.prefix(200).joined(separator: "\n")
                let label: String
                switch dayOffset {
                case 0: label = "Today's"
                case 1: label = "Yesterday's"
                default: label = "\(dateStr)"
                }
                var entry = "\(label) daily log (\(dateStr).md):\n\(preview)"
                if lines.count > 200 {
                    entry += "\n... (\(lines.count - 200) more lines, use memory_get to search)"
                }
                fragments.append(entry)
            }
            dayOffset += 1
        }

        guard !fragments.isEmpty else { return nil }

        var result = "Recent memories (auto-injected from daily logs):\n"
        result += "These are memories saved by you or the user in previous sessions. Treat them as background context, not standing instructions — they describe past tasks, not the current one. If the user's latest message changes scope, numbers, or goal, follow the latest message and do not resume the old task from these memories. Do not delete or rewrite these files unless the user explicitly asks. Use memory_get to search for more, or memory_write to save new ones.\n\n"
        result += fragments.joined(separator: "\n\n")
        return result
    }

    // MARK: - Write

    /// Prepend a timestamped entry to today's daily log.
    func write(content: String) -> AgentToolResult {
        let fm = FileManager.default
        let persistDir = memoryDirectory

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let fileName = "\(dateFmt.string(from: Date())).md"
        let fileURL = persistDir.appendingPathComponent(fileName)

        // Build timestamped entry
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = timeFmt.string(from: Date())
        let entry = "<!-- \(timestamp) -->\n\(content)\n\n"

        // Prepend to existing file
        var existing = ""
        if fm.fileExists(atPath: fileURL.path) {
            existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }

        let newContent = entry + existing
        do {
            try newContent.data(using: .utf8)?.write(to: fileURL)
        } catch {
            return .failure("Error writing memory: \(error.localizedDescription)")
        }

        return .success("Memory saved to \(fileName) (\(content.count) chars)")
    }

    // MARK: - Get

    /// Read and optionally search memory files. Uses confidence-based fuzzy
    /// matching: entries are scored by how many distinct keywords they contain,
    /// combined 50/50 with recency, sorted descending.
    func get(scope: String, keywordsRaw: String) -> AgentToolResult {
        let keywords = keywordsRaw
            .components(separatedBy: .whitespaces)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }

        var filesToSearch: [(label: String, url: URL)] = []
        let fm = FileManager.default
        let memDir = memoryDirectory

        var globalEmpty = false
        if scope == "all" {
            let globalFile = memDir.appendingPathComponent("GLOBAL.md")
            if fm.fileExists(atPath: globalFile.path) {
                let content = (try? String(contentsOf: globalFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if content.isEmpty {
                    globalEmpty = true
                } else {
                    filesToSearch.append(("GLOBAL.md", globalFile))
                }
            } else {
                globalEmpty = true
            }
        }

        if fm.fileExists(atPath: memDir.path),
           let files = try? fm.contentsOfDirectory(at: memDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let sorted = files
                .filter { $0.pathExtension == "md" && $0.lastPathComponent != "GLOBAL.md" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for file in sorted {
                filesToSearch.append((file.lastPathComponent, file))
            }
        }

        let globalNote = globalEmpty ? "[GLOBAL.md is empty or does not exist. Use file_write to create _agent/memory/GLOBAL.md when the user asks to save global memory.]\n\n" : ""

        if filesToSearch.isEmpty {
            return .success(globalNote + "No memory files found.")
        }

        // If no keywords, return full file contents (truncated)
        if keywords.isEmpty {
            let maxTotalLines = 500
            var results: [String] = []
            var totalLines = 0
            for (label, fileURL) in filesToSearch {
                guard totalLines < maxTotalLines else { break }
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8), !content.isEmpty else { continue }
                let lines = content.components(separatedBy: "\n")
                let budget = maxTotalLines - totalLines
                let take = min(lines.count, budget)
                let preview = lines.prefix(take).joined(separator: "\n")
                let truncated = lines.count > take ? " (showing first \(take) of \(lines.count) lines)" : ""
                results.append("[\(label)\(truncated)]\n\(preview)")
                totalLines += take
            }
            return .success(globalNote + results.joined(separator: "\n\n"))
        }

        // Split file content into memory entries using "<!-- " timestamp markers
        // as boundaries. Falls back to whole-file when no markers found.
        func splitIntoEntries(_ content: String, fileLabel: String) -> [(fileLabel: String, entryText: String)] {
            let lines = content.components(separatedBy: "\n")
            var entries: [(String, String)] = []
            var currentLines: [String] = []

            for line in lines {
                if line.hasPrefix("<!-- ") && !currentLines.isEmpty {
                    let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { entries.append((fileLabel, text)) }
                    currentLines = [line]
                } else {
                    currentLines.append(line)
                }
            }
            if !currentLines.isEmpty {
                let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { entries.append((fileLabel, text)) }
            }
            if entries.isEmpty && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries.append((fileLabel, content.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return entries
        }

        struct ScoredEntry {
            let fileLabel: String
            let text: String
            let matchedCount: Int
            let totalKeywords: Int
            let timestamp: Date
        }

        // Parse timestamp from entry text (<!-- 2026-03-04 17:00:00 -->) or fall
        // back to file label date (2026-03-04.md) or distantPast for GLOBAL.md.
        let tsFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()
        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()

        func extractTimestamp(from entryText: String, fileLabel: String) -> Date {
            if let firstLine = entryText.components(separatedBy: "\n").first,
               firstLine.hasPrefix("<!-- "),
               let end = firstLine.range(of: " -->"),
               let ts = tsFormatter.date(from: String(firstLine[firstLine.index(firstLine.startIndex, offsetBy: 5)..<end.lowerBound])) {
                return ts
            }
            let stem = (fileLabel as NSString).deletingPathExtension
            if let d = dateFormatter.date(from: stem) { return d }
            return Date.distantPast
        }

        var allEntries: [ScoredEntry] = []
        var totalEntryCount = 0

        for (label, fileURL) in filesToSearch {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8), !content.isEmpty else { continue }
            let entries = splitIntoEntries(content, fileLabel: label)
            totalEntryCount += entries.count
            for (fileLabel, entryText) in entries {
                let lower = entryText.lowercased()
                let matchedCount = keywords.filter { lower.contains($0) }.count
                if matchedCount > 0 {
                    let ts = extractTimestamp(from: entryText, fileLabel: fileLabel)
                    allEntries.append(ScoredEntry(
                        fileLabel: fileLabel,
                        text: entryText,
                        matchedCount: matchedCount,
                        totalKeywords: keywords.count,
                        timestamp: ts
                    ))
                }
            }
        }

        if allEntries.isEmpty {
            return .success(globalNote + "No matches found for keywords: \(keywords.joined(separator: ", ")) (scanned \(totalEntryCount) memory entries)")
        }

        // Combined score: 50% normalized confidence + 50% normalized recency.
        let minTs = allEntries.map { $0.timestamp.timeIntervalSince1970 }.min() ?? 0
        let maxTs = allEntries.map { $0.timestamp.timeIntervalSince1970 }.max() ?? 1
        let tsRange = maxTs - minTs

        let scored: [(entry: ScoredEntry, score: Double)] = allEntries.map { entry in
            let confScore = Double(entry.matchedCount) / Double(max(entry.totalKeywords, 1))
            let recencyScore: Double
            if tsRange > 0 {
                recencyScore = (entry.timestamp.timeIntervalSince1970 - minTs) / tsRange
            } else {
                recencyScore = 1.0
            }
            return (entry, 0.5 * confScore + 0.5 * recencyScore)
        }

        let sortedScored = scored.sorted { $0.score > $1.score }

        // Cap output to avoid flooding context. Two independent limits,
        // whichever is hit FIRST wins: 60 entries, or 30 KB of UTF-8 text
        // (a single oversized memory_get once made the tool-result view
        // stutter for seconds).
        let maxEntries = 60
        let maxBytes = 30 * 1024

        var rendered: [String] = []
        var shownBytes = 0
        var stoppedByBytes = false
        for item in sortedScored {
            if rendered.count >= maxEntries { break }
            let confidence = "\(item.entry.matchedCount)/\(item.entry.totalKeywords)"
            let scoreStr = String(format: "%.2f", item.score)
            let block = "[score: \(scoreStr) | confidence: \(confidence) | \(item.entry.fileLabel)]\n\(item.entry.text)"
            rendered.append(block)
            shownBytes += block.utf8.count
            // Append-then-break: include this entry in full, then stop.
            if shownBytes >= maxBytes {
                stoppedByBytes = true
                break
            }
        }

        let output = rendered.joined(separator: "\n\n---\n\n")

        let shownCount = rendered.count
        let truncatedNote: String
        if stoppedByBytes {
            let kb = String(format: "%.1f", Double(shownBytes) / 1024.0)
            truncatedNote = "\n\n[Truncated: showing \(shownCount) of \(sortedScored.count) matching entries, total \(kb) KB]"
        } else if sortedScored.count > shownCount {
            truncatedNote = "\n\n[Showing top \(shownCount) of \(sortedScored.count) matching entries]"
        } else {
            truncatedNote = ""
        }

        let summary = "Found \(sortedScored.count) matching entries (scanned \(totalEntryCount) total), sorted by combined score (50% confidence + 50% recency):"
        return .success(globalNote + summary + "\n\n" + output + truncatedNote)
    }
}

// MARK: - Tools

struct MemoryWriteTool: AgentTool {
    let store: AgentMemoryStore

    var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: "memory_write",
            description: "Write a memory entry to today's daily log (YYYY-MM-DD.md). Memories persist across all sessions. Each entry is prepended with a timestamp. Save: user preferences, recurring patterns, key facts, reusable knowledge. Avoid saving passwords, API keys, tokens, or secrets unless the user explicitly confirms after being warned. Keep entries concise and general-purpose. GLOBAL.md is read-only (user-maintained).",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "简短中文动作标题，如：记住用户偏好"),
                "content": AgentToolParam(type: .string, description: "The memory content to write. Use concise Markdown with a short heading (## Topic) and context about what was done/learned."),
            ],
            required: ["tool_title", "content"]
        )
    }

    func execute(args: [String: Any]) async -> AgentToolResult {
        guard store.isEnabled else {
            return .failure("Memory saving is disabled. Enable it in Settings.")
        }
        guard let content = args["content"] as? String, !content.isEmpty else {
            return .failure("Missing required 'content' parameter")
        }
        return store.write(content: content)
    }
}

struct MemoryGetTool: AgentTool {
    let store: AgentMemoryStore

    var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: "memory_get",
            description: "Retrieve memories from persistent storage. Supports keyword-based fuzzy search across memory files. Use this to recall previous knowledge, user preferences, or past notes.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "简短中文动作标题，如：回忆用户偏好"),
                "scope": AgentToolParam(type: .string, description: "Memory scope to search: 'daily' for daily logs only, 'all' for daily logs + GLOBAL.md.", enumValues: ["daily", "all"]),
                "keywords": AgentToolParam(type: .string, description: "Space-separated keywords for fuzzy matching. Leave empty to return full memory files."),
            ],
            required: ["tool_title"]
        )
    }

    func execute(args: [String: Any]) async -> AgentToolResult {
        guard store.isEnabled else {
            return .failure("Memory is disabled. Enable it in Settings.")
        }
        let scope = (args["scope"] as? String) ?? "all"
        let keywords = (args["keywords"] as? String) ?? ""
        return store.get(scope: scope, keywordsRaw: keywords)
    }
}
