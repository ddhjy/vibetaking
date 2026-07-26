// vibetaking Agent 会话持久化：JSON 文件，存储在记录目录 _agent/sessions/。
// 序列化设计（parts 整体编码为一个数组，tool 输入存 JSON 字符串）参考 OpenMinis
// 的 ChatStore parts_json 方案；实现为 vibetaking 重写（文件存储替代 SQLite）。
// This file is part of vibetaking, licensed under GPL-3.0 as a combined work
// with code derived from OpenMinis; see LICENSE.

import Foundation

private nonisolated let logger = AppLogger(category: "AgentSessionStore")

// MARK: - Stored Models

/// AgentContentPart 的 Codable 镜像。图片数据不持久化（占位文本代替）。
nonisolated struct StoredAgentPart: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case text, toolUse, toolResult }
    var kind: Kind
    var text: String?
    var toolId: String?
    var toolName: String?
    /// toolUse 的参数（JSON 字符串）。
    var inputJSON: String?
    /// toolResult 的内容。
    var content: String?
    var isError: Bool?

    func toContentPart() -> AgentContentPart? {
        switch kind {
        case .text:
            guard let text else { return nil }
            return .text(text)
        case .toolUse:
            guard let toolId, let toolName else { return nil }
            let input: [String: Any]
            if let inputJSON,
               let data = inputJSON.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                input = dict
            } else {
                input = [:]
            }
            return .toolUse(id: toolId, name: toolName, input: input)
        case .toolResult:
            guard let toolId, let toolName else { return nil }
            return .toolResult(id: toolId, name: toolName, content: content ?? "", isError: isError ?? false)
        }
    }

    static func from(_ part: AgentContentPart) -> StoredAgentPart? {
        switch part {
        case .text(let text):
            return StoredAgentPart(kind: .text, text: text)
        case .toolUse(let id, let name, let input):
            let json = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) }
            return StoredAgentPart(kind: .toolUse, toolId: id, toolName: name, inputJSON: json ?? "{}")
        case .toolResult(let id, let name, let content, let isError, let imageData, _):
            var stored = content
            if imageData != nil {
                stored += "\n[图片结果未持久化]"
            }
            return StoredAgentPart(kind: .toolResult, toolId: id, toolName: name, content: stored, isError: isError)
        case .imageData:
            return nil
        }
    }
}

nonisolated struct StoredAgentMessage: Codable, Sendable {
    var role: String
    var parts: [StoredAgentPart]
    var isInterrupted: Bool?
    var reasoningContent: String?

    func toAgentMessage() -> AgentMessage {
        var msg = AgentMessage(
            role: role == "user" ? .user : .assistant,
            parts: parts.compactMap { $0.toContentPart() }
        )
        msg.isInterrupted = isInterrupted ?? false
        msg.reasoningContent = reasoningContent
        return msg
    }

    static func from(_ message: AgentMessage) -> StoredAgentMessage {
        StoredAgentMessage(
            role: message.role.rawValue,
            parts: message.parts.compactMap { StoredAgentPart.from($0) },
            isInterrupted: message.isInterrupted ? true : nil,
            reasoningContent: message.reasoningContent
        )
    }
}

nonisolated struct AgentChatSession: Codable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [StoredAgentMessage]

    init(id: UUID = UUID(), title: String = "", createdAt: Date = .now, updatedAt: Date = .now, messages: [StoredAgentMessage] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

// MARK: - Store

@Observable
class AgentSessionStore {
    static let shared = AgentSessionStore()

    /// 会话元数据列表（按更新时间倒序）。
    private(set) var sessions: [AgentChatSession] = []
    private var loaded = false

    private init() {}

    private var sessionsDirectory: URL {
        let dir = HistoryManager.shared.agentStorageRootURL
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    func reload() {
        let dir = sessionsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            sessions = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loadedSessions: [AgentChatSession] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(AgentChatSession.self, from: data) else {
                logger.warning("Failed to decode session file \(file.lastPathComponent)")
                continue
            }
            loadedSessions.append(session)
        }
        sessions = loadedSessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ session: AgentChatSession) {
        var updated = session
        updated.updatedAt = .now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(updated)
            let url = sessionsDirectory.appendingPathComponent("\(session.id.uuidString).json")
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save session: \(error.localizedDescription)")
        }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = updated
        } else {
            sessions.insert(updated, at: 0)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }

    func delete(_ sessionId: UUID) {
        let url = sessionsDirectory.appendingPathComponent("\(sessionId.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        sessions.removeAll { $0.id == sessionId }
    }
}
