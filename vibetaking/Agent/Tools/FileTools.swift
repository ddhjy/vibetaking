// Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis) —
// Agent/Chat/AIChatViewModel+FileTools.swift (simplified).
// Copyright (C) OpenMinis contributors. Licensed under GPL-3.0; see LICENSE.
// Modifications for vibetaking: single-scope path resolution rooted at the
// records directory (no iSH mount table / fakefs metadata), size-capped reads.

import Foundation

/// 把模型给出的相对路径解析到记录目录内，拒绝越界。
nonisolated private func resolveScopedPath(_ rawPath: String, root: URL) -> URL? {
    var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }
    // 容忍模型输出绝对路径形态（/notes/xxx.md）——当作相对处理。
    while path.hasPrefix("/") { path.removeFirst() }
    let candidate = root.appendingPathComponent(path).standardizedFileURL
    let rootPath = root.standardizedFileURL.path
    guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else {
        return nil
    }
    return candidate
}

private let maxFileReadBytes = 256 * 1024

// MARK: - file_read

struct FileReadTool: AgentTool {
    var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: "file_read",
            description: "读取记录目录内的一个文本文件（相对路径）。速记记录是根目录下的 .md 文件；skills 在 _skills/ 目录。读取速记请优先用 read_note。",
            parameters: [
                "path": AgentToolParam(type: .string, description: "相对记录目录的路径，例如 _skills/foo/SKILL.md"),
                "tool_title": AgentToolParam(type: .string, description: "简短中文动作标题，如：读取文件"),
            ],
            required: ["path", "tool_title"]
        )
    }

    func execute(args: [String: Any]) async -> AgentToolResult {
        guard let rawPath = ToolArgs.string(args, "path") else {
            return .failure("缺少 path 参数")
        }
        // Skill 使用计数：读取 _skills/<id>/SKILL.md 视为一次 skill 触发
        // （与 OpenMinis 在工具分发处的计数钩子同机制）。
        if let skillId = SkillStore.shared.skillIdFromPath(rawPath) {
            SkillStore.shared.recordSkillUse(skillId)
        }
        let root = HistoryManager.shared.agentStorageRootURL
        guard let url = resolveScopedPath(rawPath, root: root) else {
            return .failure("路径越界：只允许访问记录目录内的文件")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure("文件不存在：\(rawPath)")
        }
        if isDirectory.boolValue {
            // 目录：列出内容。
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                return .failure("无法列出目录：\(rawPath)")
            }
            return .success("目录 \(rawPath) 包含 \(entries.count) 项：\n" + entries.sorted().joined(separator: "\n"))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure("读取失败：\(rawPath)")
        }
        if data.count > maxFileReadBytes {
            let truncated = data.prefix(maxFileReadBytes)
            let text = String(decoding: truncated, as: UTF8.self)
            return .success(text + "\n\n[文件过大，已截断到 \(maxFileReadBytes / 1024)KB / 共 \(data.count / 1024)KB]")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure("不是 UTF-8 文本文件：\(rawPath)")
        }
        return .success(text.isEmpty ? "[空文件]" : text)
    }
}

// MARK: - file_write

struct FileWriteTool: AgentTool {
    var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: "file_write",
            description: "在记录目录内写入一个文本文件（相对路径，自动创建中间目录，整体覆盖）。保存速记请优先用 save_note；本工具用于写 skills、报告等辅助文件。",
            parameters: [
                "path": AgentToolParam(type: .string, description: "相对记录目录的路径，例如 _skills/foo/SKILL.md"),
                "content": AgentToolParam(type: .string, description: "完整文件内容（UTF-8）"),
                "tool_title": AgentToolParam(type: .string, description: "简短中文动作标题，如：写入文件"),
            ],
            required: ["path", "content", "tool_title"]
        )
    }

    func execute(args: [String: Any]) async -> AgentToolResult {
        guard let rawPath = ToolArgs.string(args, "path") else {
            return .failure("缺少 path 参数")
        }
        guard let content = args["content"] as? String else {
            return .failure("缺少 content 参数")
        }
        let root = HistoryManager.shared.agentStorageRootURL
        guard let url = resolveScopedPath(rawPath, root: root) else {
            return .failure("路径越界：只允许写入记录目录内的文件")
        }
        // 保护速记数据：不允许覆盖根目录下的 .md 记录文件（草稿与历史记录）。
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        if parent.path == rootPath && url.pathExtension.lowercased() == "md" {
            return .failure("不允许直接写记录根目录下的 .md 文件，请用 save_note 保存记录")
        }
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return .success("已写入 \(rawPath)（\(content.utf8.count) 字节）")
        } catch {
            return .failure("写入失败：\(error.localizedDescription)")
        }
    }
}
