// Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis) — Providers/AgentProvider.swift
// and portions of Providers/LLMTypes.swift, Providers/LLMError.swift.
// Copyright (C) OpenMinis contributors. Licensed under GPL-3.0; see LICENSE.
// Modifications for vibetaking: removed iSH linux-path fields, Gemini/Anthropic
// metadata, model-catalog thinking clamp; merged the minimal LLM base types.

import Foundation

// MARK: - Cross-Provider Helpers

/// Sanitize a tool-use ID so it is valid for all providers.
/// Anthropic requires `^[a-zA-Z0-9_-]+$`; OpenAI Responses API can produce
/// IDs containing `|` (e.g. `call_xxx|fc_yyy`). Replace any disallowed
/// character with `-`.
nonisolated func sanitizeToolId(_ id: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    return String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") })
}

// MARK: - Canonical Tool Definitions

/// Canonical tool definition used by the agent loop — provider-agnostic.
nonisolated struct AgentToolDefinition: Sendable {
    let name: String
    let description: String
    let parameters: [String: AgentToolParam]
    let required: [String]

    init(name: String, description: String, parameters: [String: AgentToolParam], required: [String]) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.required = required
    }
}

nonisolated struct AgentToolParam: Sendable {
    let type: AgentParamType
    let description: String
    let enumValues: [String]?

    init(type: AgentParamType, description: String, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }
}

nonisolated enum AgentParamType: String, Sendable {
    case string
    case integer
    case boolean
}

// MARK: - Agent Messages

/// A single content part in agent messages — provider-agnostic.
nonisolated enum AgentContentPart: @unchecked Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    case toolResult(id: String, name: String, content: String, isError: Bool, imageData: Data? = nil, imageMimeType: String? = nil)
    case imageData(data: Data, mimeType: String)
}

/// Native reasoning payload captured from the provider response, used to
/// preserve chain-of-thought across multi-turn requests. Lives **in memory
/// only** (not persisted) — restart loses encrypted content, which is
/// acceptable because the visible text + tool history is unchanged.
///
/// Each echo is tagged with the producing model so cross-model switches
/// can be detected and the encrypted payload stripped — encrypted_content
/// is model-specific and meaningless to a different model family.
nonisolated struct ReasoningEcho: @unchecked Sendable {
    /// Stable provider family tag.
    let providerKind: String
    /// Concrete model id. Encrypted payloads are only safe to echo back to
    /// the **same** model id within the same provider family.
    let modelId: String
    /// Reasoning items captured in original emission order — must be
    /// re-inserted into the next request's input array in the same order
    /// (Responses API rejects out-of-order reasoning items).
    let items: [Item]

    enum Item: @unchecked Sendable {
        /// OpenAI Responses API reasoning item.
        case openaiReasoning(id: String, encryptedContent: String?, summary: [String])
    }
}

/// A message in the agent conversation.
nonisolated struct AgentMessage: @unchecked Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    var parts: [AgentContentPart]
    /// True when this assistant message was interrupted mid-stream (e.g. network drop).
    /// tool_use blocks inside may have incomplete/empty inputs (partialJson never finished).
    /// Placeholder tool_results must NOT be injected for interrupted messages, because
    /// sending a tool_result for a tool_use with empty input causes API 400 errors.
    var isInterrupted: Bool = false
    /// Opaque reasoning content from thinking models. Echoed back on
    /// assistant messages for multi-turn conversations.
    var reasoningContent: String?
    /// Native reasoning payload (Responses-API encrypted items, etc.). In
    /// memory only — see `ReasoningEcho` for cross-model isolation rules.
    var reasoningEcho: ReasoningEcho?
}

// MARK: - Stream Events

/// Stream events from an agent provider.
nonisolated enum AgentStreamEvent: @unchecked Sendable {
    /// A new content block started (text or tool).
    case contentBlockStart(AgentBlockStart)
    /// Incremental text delta.
    case textDelta(String)
    /// Tool input update (for streaming JSON preview).
    /// `accumulated` is the full JSON so far, `name` is the tool name.
    case toolInputDelta(name: String, accumulated: String)
    /// Tool call completed with final parsed arguments.
    case toolCallComplete(id: String, name: String, args: [String: Any], rawArgsJSON: String)
    /// Usage stats.
    case usage(LLMUsage)
    /// Real-time thinking content delta for live UI display.
    case thinkingDelta(String)
    /// Accumulated reasoning content from thinking models (opaque, echoed back).
    case reasoningContent(String)
    /// Native reasoning payload (e.g. OpenAI Responses-API encrypted items)
    /// for in-memory multi-turn replay.
    case reasoningEcho(ReasoningEcho)
    /// Response finished.
    case done(stopReason: AgentStopReason)
}

nonisolated enum AgentBlockStart: Sendable {
    case text
    case toolUse(id: String, name: String)
}

nonisolated enum AgentStopReason: Sendable {
    case endTurn
    case toolUse
    case maxTokens
    /// The provider's safety layer declined the request. Distinct from
    /// `.endTurn` so the agent loop can surface an actionable message
    /// instead of a generic "empty response".
    case refusal
}

// MARK: - Base LLM Types

nonisolated struct LLMUsage: Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?
}

nonisolated enum ThinkingLevel: String, Codable, Hashable, CaseIterable, Comparable, Sendable {
    case off
    case low
    case medium
    case high

    static func < (lhs: ThinkingLevel, rhs: ThinkingLevel) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    var isEnabled: Bool { self != .off }
}

nonisolated enum LLMError: LocalizedError {
    case providerError(message: String)
    /// Transient family (server_error / rate_limit): worth retrying on the same model.
    case transientError(message: String)
    case networkError(underlying: Error)
    case invalidResponse(message: String)
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .providerError(let message): return message
        case .transientError(let message): return message
        case .networkError(let underlying): return "网络错误：\(underlying.localizedDescription)"
        case .invalidResponse(let message): return "服务返回异常：\(message)"
        case .missingCredentials: return "请先在设置中填写 AI 密钥"
        }
    }

    var isTransient: Bool {
        switch self {
        case .transientError, .networkError: return true
        default: return false
        }
    }
}

// MARK: - Protocol

/// Protocol for providers that support the agent loop (streaming + tool use).
nonisolated protocol AgentProvider: Sendable {
    var name: String { get }
    var modelId: String { get }
    /// Default max output tokens for this provider.
    var defaultMaxTokens: Int { get }

    func streamAgentMessage(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error>
}

extension AgentProvider {
    /// Default: thinking off.
    func streamAgentMessage(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        try await streamAgentMessage(messages: messages, systemPrompt: systemPrompt, tools: tools, maxTokens: maxTokens, thinkingLevel: .off)
    }
}
