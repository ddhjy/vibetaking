// vibetaking 笔记工具集：把速记库暴露给 Agent。
// 薄封装调用现有 HistoryManager / TagManager。
// This file is part of vibetaking, licensed under GPL-3.0 as a combined work
// with code derived from OpenMinis; see LICENSE.

import Foundation

// MARK: - Shared arg helpers

nonisolated enum ToolArgs {
    static func string(_ args: [String: Any], _ key: String) -> String? {
        if let s = args[key] as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    static func int(_ args: [String: Any], _ key: String) -> Int? {
        if let n = args[key] as? Int { return n }
        if let n = args[key] as? NSNumber { return n.intValue }
        if let s = args[key] as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    static func bool(_ args: [String: Any], _ key: String) -> Bool? {
        if let b = args[key] as? Bool { return b }
        if let n = args[key] as? NSNumber { return n.boolValue }
        if let s = args[key] as? String {
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// 逗号/顿号分隔的标签串 → 数组。
    static func tagList(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .components(separatedBy: CharacterSet(charactersIn: ",，、"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private let noteDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.locale = Locale(identifier: "zh_CN")
    return formatter
}()

private func formatItemHeader(_ item: HistoryItem) -> String {
    var header = "[\(item.fileName)] \(noteDateFormatter.string(from: item.createdAt))"
    if !item.tags.isEmpty {
        header += " | 标签: \(item.tags.joined(separator: ", "))"
    }
    return header
}

// MARK: - search_notes

struct SearchNotesTool: AgentTool {
    var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: "search_notes",
            description: "全文搜索用户的速记库。多个关键词用空格分隔（AND 语义，命中任意位置）。可选按标签过滤。返回匹配记录的文件名、时间、标签和内容摘录。要读取完整内容请用 read_note。不带 query 且不带 tags 时返回最近的记录。",
            parameters: [
                "query": AgentToolParam(type: .string, description: "搜索关键词，空格分隔多个词（AND）。可为空。"),
                "tags": AgentToolParam(type: .string, description: "按标签过滤，逗号分隔多个标签（AND）。可为空。"),
                "limit": AgentToolParam(type: .integer, description: "最多返回条数，默认 10，上限 50。"),
                "tool_title": AgentToolParam(type: .string, description: "简短中文动作标题，如：搜索「会议」"),
            ],
            required: ["tool_title"]
        )
    }

    func execute(args: [String: Any]) async -> AgentToolResult {
        let query = ToolArgs.string(args, "query") ?? ""
        let tagFilter = ToolArgs.tagList(ToolArgs.string(args, "tags"))
        let limit = min(max(ToolArgs.int(args, "limit") ?? 10, 1), 50)

        let keywords = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }

        var matches = HistoryManager.shared.savedItems
        if !tagFilter.isEmpty {
            matches = matches.filter { item in
                tagFilter.allSatisfy { filterTag in
                    item.tags.contains { $0.localizedCaseInsensitiveCompare(filterTag) == .orderedSame }
                }
            }
        }
        if !keywords.isEmpty {
            matches = matches.filter { item in
                let haystack = (item.text + " " + item.tags.joined(separator: " ")).lowercased()
                return keywords.allSatisfy { haystack.contains($0) }
            }
        }

        let total = matches.count
        let selected = Array(matches.prefix(limit))
        guard !selected.isEmpty else {
            return .success("没有找到匹配的记录（速记库共 \(HistoryManager.shared.savedItems.count) 条）。")
        }

        var lines: [String] = ["共匹配 \(total) 条，显示前 \(selected.count) 条："]
        for item in selected {
            let excerpt = item.text
                .components(separatedBy: .newlines)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let capped = excerpt.count > 120 ? String(excerpt.prefix(120)) + "…" : excerpt
            lines.append("\(formatItemHeader(item))\n  \(capped)")
        }
        return .success(lines.joined(separator: "\n"))
    }
}

// MARK: - read_note

struct ReadNoteTool: AgentTool {
    var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: "read_note",
            description: "按文件名读取一条速记的完整内容（含标签和创建时间）。文件名来自 search_notes 的结果，如 2026-07-20-1430-00.md。",
            parameters: [
                "file_name": AgentToolParam(type: .string, description: "记录文件名，例如 2026-07-20-1430-00.md"),
                "tool_title": AgentToolParam(type: .string, description: "简短中文动作标题，如：读取笔记"),
            ],
            required: ["file_name", "tool_title"]
        )
    }

    func execute(args: [String: Any]) async -> AgentToolResult {
        guard let fileName = ToolArgs.string(args, "file_name") else {
            return .failure("缺少 file_name 参数")
        }
        guard let item = HistoryManager.shared.savedItems.first(where: { $0.fileName == fileName }) else {
            return .failure("没有找到文件名为 \(fileName) 的记录，请先用 search_notes 确认文件名")
        }
        return .success("\(formatItemHeader(item))\n---\n\(item.text)")
    }
}

// MARK: - save_note

struct SaveNoteTool: AgentTool {
    var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: "save_note",
            description: "把文本保存为一条新的速记记录，可同时打标签。用于帮用户整理、归纳后落盘新记录。相同正文的旧记录会被替换。",
            parameters: [
                "text": AgentToolParam(type: .string, description: "记录正文（Markdown 纯文本）"),
                "tags": AgentToolParam(type: .string, description: "标签，逗号分隔。优先复用 list_tags 中已有的标签。可为空。"),
                "tool_title": AgentToolParam(type: .string, description: "简短中文动作标题，如：保存整理结果"),
            ],
            required: ["text", "tool_title"]
        )
    }

    func execute(args: [String: Any]) async -> AgentToolResult {
        guard let text = ToolArgs.string(args, "text") else {
            return .failure("缺少 text 参数")
        }
        let tags = ToolArgs.tagList(ToolArgs.string(args, "tags"))
        HistoryManager.shared.addRecord(text, tags: tags)
        guard let saved = HistoryManager.shared.savedItems.first(where: { $0.text == text }) else {
            return .failure("保存失败，请重试")
        }
        return .success("已保存为 \(saved.fileName)" + (tags.isEmpty ? "" : "，标签: \(tags.joined(separator: ", "))"))
    }
}

// MARK: - add_tags

struct AddTagsTool: AgentTool {
    var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: "add_tags",
            description: "给一条已有记录追加标签（保留原有标签）。优先复用已有标签体系（见 list_tags）。",
            parameters: [
                "file_name": AgentToolParam(type: .string, description: "记录文件名，来自 search_notes"),
                "tags": AgentToolParam(type: .string, description: "要追加的标签，逗号分隔"),
                "tool_title": AgentToolParam(type: .string, description: "简短中文动作标题，如：打标签"),
            ],
            required: ["file_name", "tags", "tool_title"]
        )
    }

    func execute(args: [String: Any]) async -> AgentToolResult {
        guard let fileName = ToolArgs.string(args, "file_name") else {
            return .failure("缺少 file_name 参数")
        }
        let tags = ToolArgs.tagList(ToolArgs.string(args, "tags"))
        guard !tags.isEmpty else {
            return .failure("缺少 tags 参数")
        }
        guard let item = HistoryManager.shared.savedItems.first(where: { $0.fileName == fileName }) else {
            return .failure("没有找到文件名为 \(fileName) 的记录")
        }
        for tag in tags {
            HistoryManager.shared.addTag(to: item.id, tagName: tag)
        }
        let updated = HistoryManager.shared.savedItems.first(where: { $0.id == item.id })
        return .success("已更新标签: \(updated?.tags.joined(separator: ", ") ?? tags.joined(separator: ", "))")
    }
}

// MARK: - list_tags

struct ListTagsTool: AgentTool {
    var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: "list_tags",
            description: "列出用户速记库的全部标签及每个标签的记录数，用于了解用户的标签体系。打标签前先调用它。",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "简短中文动作标题，如：查看标签体系"),
            ],
            required: ["tool_title"]
        )
    }

    func execute(args: [String: Any]) async -> AgentToolResult {
        let tagManager = TagManager.shared
        let tags = tagManager.tags
        guard !tags.isEmpty else {
            return .success("用户还没有任何标签。")
        }
        let lines = tags.map { "\($0) (\(tagManager.count(for: $0)))" }
        return .success("共 \(tags.count) 个标签：\n" + lines.joined(separator: "\n"))
    }
}
