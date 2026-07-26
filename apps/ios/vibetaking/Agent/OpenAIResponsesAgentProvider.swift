// Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis) —
// Providers/OpenAI/OpenAIAgentProvider.swift (Responses API path) merged with
// Providers/OpenAI/OpenAIProvider.swift (streamRaw HTTP/SSE layer).
// Copyright (C) OpenMinis contributors. Licensed under GPL-3.0; see LICENSE.
// Modifications for vibetaking: removed Codex OAuth / Azure / OpenRouter /
// DashScope / Chat Completions paths and the provider-config store; init takes
// explicit (apiKey, modelId, baseURLString) resolved from SettingsManager.

import Foundation

/// URLSession with a long read timeout for SSE streaming.
/// URLSession.shared uses a 60-second timeoutIntervalForRequest which can kill
/// long agent turns between token deltas.
private nonisolated let streamingSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 600
    config.timeoutIntervalForResource = 3600
    return URLSession(configuration: config)
}()

private nonisolated let logger = AppLogger(category: "OpenAIResponsesProvider")

nonisolated final class OpenAIResponsesAgentProvider: AgentProvider {
    static let providerKind: String = "openai-responses"

    let name = "OpenAI Responses"
    let modelId: String
    let defaultMaxTokens: Int
    private let apiKey: String
    /// Normalized base URL ending in `/v1` (e.g. `https://api.infingrow.asia/v1`).
    private let baseURLString: String

    init(apiKey: String, modelId: String, baseURLString: String, defaultMaxTokens: Int = 16384) {
        self.apiKey = apiKey
        self.modelId = modelId
        self.baseURLString = baseURLString
        self.defaultMaxTokens = defaultMaxTokens
    }

    // MARK: - AgentProvider

    func streamAgentMessage(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let inputMessages = convertMessagesResponsesAPI(messages)
        let responsesTools = Self.convertToolsResponsesAPI(tools)

        var body: [String: Any] = [
            "model": modelId,
            "stream": true,
            "store": false,
            "parallel_tool_calls": true,
            "input": inputMessages,
            // Stable per-conversation key so the Responses API can hit prompt cache
            // across turns. Derived from a stable hash of the first user message's
            // text, which is prepended every turn of the same chat. Required for
            // custom/third-party endpoints that do not synthesize a fallback key.
            "prompt_cache_key": Self.derivePromptCacheKey(from: messages),
        ]
        // Thinking level → Responses API `reasoning.effort`. `summary: "auto"`
        // opts in to streaming the human-readable reasoning summary; without it
        // the API only returns encrypted_content.
        var reasoningRequested = false
        if thinkingLevel.isEnabled {
            body["reasoning"] = ["effort": thinkingLevel.rawValue, "summary": "auto"]
            reasoningRequested = true
        }
        // Request the encrypted reasoning payload whenever reasoning is
        // requested; captured each turn and echoed back to the SAME model id
        // on subsequent requests (see ReasoningEcho).
        if reasoningRequested {
            body["include"] = ["reasoning.encrypted_content"]
        }
        // Responses API official field is max_output_tokens (NOT
        // max_completion_tokens). Without it, third-party vendors fall back to
        // their own tiny defaults and truncate long outputs.
        if maxTokens > 0 {
            body["max_output_tokens"] = maxTokens
        }
        if let sys = systemPrompt, !sys.isEmpty {
            body["instructions"] = sys
        }
        if !responsesTools.isEmpty {
            body["tools"] = responsesTools
            body["tool_choice"] = "auto"
        }

        let lineStream = try await streamRaw(body: body)

        return AsyncThrowingStream { continuation in
            let task = Task {
                var emittedTextStart = false
                var hasToolCalls = false
                // Track current function call items: [item_id: (call_id, name, accumulatedJSON)]
                var functionCallAccum: [String: (callId: String, name: String, json: String)] = [:]
                // Per-item streamed summary text, keyed by reasoning item id. The
                // Responses API can emit multiple reasoning items in a single
                // response (think → tool → think → tool …).
                var reasoningTextPerItem: [String: String] = [:]
                var reasoningItemOrder: [String] = []
                var currentReasoningItemId: String? = nil
                // Streaming parser for models that embed reasoning as a
                // `<think>…</think>` prefix of the visible text (some gateways
                // front DeepSeek/Qwen-style models behind a Responses facade).
                var thinkParser = ThinkPrefixStreamParser()

                do {
                    for try await line in lineStream {
                        guard let payload = Self.ssePayload(from: line) else { continue }
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                        let type = event["type"] as? String ?? ""

                        switch type {
                        case "response.reasoning_text.delta",
                             "response.reasoning_summary_text.delta":
                            if let delta = event["delta"] as? String, !delta.isEmpty {
                                let itemId = (event["item_id"] as? String) ?? currentReasoningItemId
                                if let itemId {
                                    if reasoningTextPerItem[itemId] == nil {
                                        reasoningTextPerItem[itemId] = ""
                                        if !reasoningItemOrder.contains(itemId) {
                                            reasoningItemOrder.append(itemId)
                                        }
                                    }
                                    reasoningTextPerItem[itemId, default: ""] += delta
                                }
                                continuation.yield(.thinkingDelta(delta))
                            }

                        case "response.output_text.delta":
                            if let delta = event["delta"] as? String {
                                let out = thinkParser.consume(delta)
                                if !out.thinking.isEmpty {
                                    continuation.yield(.thinkingDelta(out.thinking))
                                }
                                if !out.visible.isEmpty {
                                    if !emittedTextStart {
                                        continuation.yield(.contentBlockStart(.text))
                                        emittedTextStart = true
                                    }
                                    continuation.yield(.textDelta(out.visible))
                                }
                            }

                        case "response.function_call_arguments.delta":
                            if let itemId = event["item_id"] as? String,
                               let delta = event["delta"] as? String,
                               var entry = functionCallAccum[itemId] {
                                entry.json += delta
                                functionCallAccum[itemId] = entry
                                continuation.yield(.toolInputDelta(name: entry.name, accumulated: entry.json))
                            }

                        case "response.output_item.done":
                            if let item = event["item"] as? [String: Any],
                               let itemType = item["type"] as? String,
                               itemType == "reasoning" {
                                // Encrypted-only reasoning items (no streamed
                                // summary) are not rendered; encrypted_content
                                // is still captured at response.completed.
                                let itemId = item["id"] as? String ?? ""
                                if currentReasoningItemId == itemId {
                                    currentReasoningItemId = nil
                                }
                            } else if let item = event["item"] as? [String: Any],
                               let itemType = item["type"] as? String,
                               itemType == "function_call",
                               let itemId = item["id"] as? String,
                               let entry = functionCallAccum[itemId] {
                                let combinedId = Self.combineResponsesAPIIds(callId: entry.callId, fcId: itemId)
                                let args = Self.parseJsonToDict(entry.json)
                                if args.isEmpty {
                                    Self.diagEmptyToolArgs(rawJson: entry.json, toolName: entry.name, toolId: combinedId, model: self.modelId)
                                }
                                continuation.yield(.toolCallComplete(
                                    id: combinedId, name: entry.name, args: args, rawArgsJSON: entry.json
                                ))
                                functionCallAccum.removeValue(forKey: itemId)
                            }

                        case "response.output_item.added":
                            if let item = event["item"] as? [String: Any],
                               let itemType = item["type"] as? String,
                               itemType == "reasoning" {
                                let itemId = item["id"] as? String ?? ""
                                currentReasoningItemId = itemId
                                if !itemId.isEmpty {
                                    reasoningTextPerItem[itemId] = ""
                                    if !reasoningItemOrder.contains(itemId) {
                                        reasoningItemOrder.append(itemId)
                                    }
                                }
                            } else if let item = event["item"] as? [String: Any],
                               let itemType = item["type"] as? String,
                               itemType == "function_call",
                               let itemId = item["id"] as? String,
                               let callId = item["call_id"] as? String,
                               let name = item["name"] as? String {
                                // Content preceding a tool call can no longer
                                // become a think prefix — flush now.
                                let resolved = thinkParser.resolveAtToolBoundary()
                                if !resolved.visible.isEmpty {
                                    if !emittedTextStart {
                                        continuation.yield(.contentBlockStart(.text))
                                        emittedTextStart = true
                                    }
                                    continuation.yield(.textDelta(resolved.visible))
                                }
                                emittedTextStart = false
                                hasToolCalls = true
                                let combinedId = Self.combineResponsesAPIIds(callId: callId, fcId: itemId)
                                functionCallAccum[itemId] = (callId: callId, name: name, json: "")
                                continuation.yield(.contentBlockStart(.toolUse(id: combinedId, name: name)))
                            }

                        case "response.failed":
                            // Pull the structured error off the response object
                            // so the thrown LLMError carries the real reason.
                            let response = event["response"] as? [String: Any]
                            let err = response?["error"] as? [String: Any]
                            let code = (err?["code"] as? String) ?? "unknown"
                            let message = (err?["message"] as? String) ?? "response.failed with no error detail"
                            logger.error("response.failed — code: \(code), message: \(message)")
                            if code == "server_error" || code == "rate_limit_exceeded" {
                                throw LLMError.transientError(message: "[\(code)] \(message)")
                            }
                            throw LLMError.providerError(message: "[\(code)] \(message)")

                        case "response.incomplete":
                            // Server ended the response early; partial output
                            // has already streamed — surface WHY it stopped.
                            let response = event["response"] as? [String: Any]
                            let reason = ((response?["incomplete_details"] as? [String: Any])?["reason"] as? String) ?? "unknown"
                            logger.error("response.incomplete — reason: \(reason)")
                            throw LLMError.providerError(
                                message: "Response ended incomplete (reason: \(reason))"
                                    + (reason == "max_output_tokens"
                                       ? " — output hit max_output_tokens; raise the limit or shorten the request."
                                       : ""))

                        case "response.completed":
                            let response = event["response"] as? [String: Any]
                            let apiStatus = response?["status"] as? String
                            let apiStopReason = response?["stop_reason"] as? String
                                ?? (response?["incomplete_details"] as? [String: Any])?["reason"] as? String

                            // Flush any withheld think-parser tail.
                            let finished = thinkParser.finishTurn()
                            if !finished.thinking.isEmpty {
                                continuation.yield(.thinkingDelta(finished.thinking))
                            }
                            if !finished.visible.isEmpty {
                                if !emittedTextStart {
                                    continuation.yield(.contentBlockStart(.text))
                                    emittedTextStart = true
                                }
                                continuation.yield(.textDelta(finished.visible))
                            }

                            let outputItems = (response?["output"] as? [[String: Any]]) ?? []
                            let reasoningItems = outputItems.filter { ($0["type"] as? String) == "reasoning" }
                            let usage = response?["usage"] as? [String: Any]

                            // Aggregate per-item streamed summary text into a
                            // single reasoningContent carry-back.
                            let allText = reasoningItemOrder
                                .compactMap { reasoningTextPerItem[$0] }
                                .filter { !$0.isEmpty }
                                .joined(separator: "\n\n")
                            if !allText.isEmpty {
                                continuation.yield(.reasoningContent(allText))
                            }

                            // Capture native reasoning items (id + encrypted_content
                            // + summary[]) for in-memory multi-turn replay — echoed
                            // back to the SAME model id only.
                            if !reasoningItems.isEmpty {
                                let captured: [ReasoningEcho.Item] = reasoningItems.compactMap { item in
                                    guard let id = item["id"] as? String else { return nil }
                                    let encrypted = item["encrypted_content"] as? String
                                    let summary: [String] = ((item["summary"] as? [[String: Any]]) ?? []).compactMap { part in
                                        part["text"] as? String
                                    }
                                    if encrypted == nil && summary.isEmpty { return nil }
                                    return .openaiReasoning(id: id, encryptedContent: encrypted, summary: summary)
                                }
                                if !captured.isEmpty {
                                    continuation.yield(.reasoningEcho(ReasoningEcho(
                                        providerKind: Self.providerKind,
                                        modelId: self.modelId,
                                        items: captured
                                    )))
                                }
                            }
                            if let usage {
                                let inputDetails = usage["input_tokens_details"] as? [String: Any]
                                let cacheRead = inputDetails?["cached_tokens"] as? Int
                                continuation.yield(.usage(LLMUsage(
                                    inputTokens: usage["input_tokens"] as? Int ?? 0,
                                    outputTokens: usage["output_tokens"] as? Int ?? 0,
                                    cacheCreationInputTokens: nil,
                                    cacheReadInputTokens: cacheRead
                                )))
                            }
                            // Use the API's actual stop reason to decide loop continuation.
                            let reason: AgentStopReason
                            if hasToolCalls {
                                reason = .toolUse
                            } else if apiStatus == "incomplete" && apiStopReason == "content_filter" {
                                logger.warning("response.completed status=incomplete reason=content_filter")
                                reason = .refusal
                            } else if apiStatus == "incomplete" {
                                reason = .maxTokens
                            } else {
                                reason = .endTurn
                            }
                            continuation.yield(.done(stopReason: reason))

                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - HTTP / SSE Layer

    private func streamRaw(body: [String: Any]) async throws -> AsyncThrowingStream<String, Error> {
        guard !apiKey.isEmpty else { throw LLMError.missingCredentials }
        guard let url = URL(string: "\(baseURLString)/responses") else {
            throw LLMError.invalidResponse(message: "AI 服务地址异常")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // .sortedKeys so every request with the same body produces byte-identical
        // JSON, letting prefix-based provider caches match from the 0th token.
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (byteStream, response) = try await streamingSession.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        if !(200..<300).contains(statusCode) {
            var errBody = ""
            for try await line in byteStream.lines { errBody += line }
            throw Self.mapHTTPError(statusCode: statusCode, body: errBody)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in byteStream.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Error Mapping

    static func mapHTTPError(statusCode: Int, body: String) -> LLMError {
        var message = "HTTP \(statusCode)"
        if let data = body.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = dict["error"] as? [String: Any], let msg = err["message"] as? String {
                message = "HTTP \(statusCode)：\(msg)"
            } else if let msg = dict["message"] as? String {
                message = "HTTP \(statusCode)：\(msg)"
            }
        } else if !body.isEmpty {
            message = "HTTP \(statusCode)：\(String(body.prefix(180)))"
        }
        if statusCode == 429 || (500...599).contains(statusCode) {
            return .transientError(message: message)
        }
        return .providerError(message: message)
    }

    static func mapError(_ error: Error) -> Error {
        if error is LLMError { return error }
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            return LLMError.networkError(underlying: urlError)
        }
        return error
    }

    // MARK: - Prompt Cache Key

    static func derivePromptCacheKey(from messages: [AgentMessage]) -> String {
        for msg in messages where msg.role == .user {
            for part in msg.parts {
                if case .text(let text) = part, !text.isEmpty {
                    var hash: UInt64 = 5381
                    for byte in text.utf8 {
                        hash = 127 * (hash & 0x00FF_FFFF_FFFF_FFFF) + UInt64(byte)
                    }
                    return "vibetaking-\(String(hash, radix: 36))"
                }
            }
        }
        return "vibetaking-empty"
    }

    // MARK: - Responses API Message Conversion

    private func convertMessagesResponsesAPI(_ messages: [AgentMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for msg in messages {
            // Replay native reasoning items at the head of this assistant turn.
            // Order matters: the Responses API rejects reasoning items that
            // appear after function_call items belonging to the same turn.
            // Cross-model payloads are stripped — encrypted_content is
            // model-specific and 400-inducing elsewhere.
            if msg.role == .assistant,
               let echo = msg.reasoningEcho,
               echo.providerKind == Self.providerKind,
               echo.modelId == self.modelId {
                for item in echo.items {
                    if case .openaiReasoning(let id, let encrypted, let summary) = item {
                        // `summary` is required on input reasoning items even
                        // when empty (400 otherwise).
                        var entry: [String: Any] = [
                            "type": "reasoning",
                            "id": id,
                            "summary": summary.map { ["type": "summary_text", "text": $0] },
                        ]
                        if let encrypted, !encrypted.isEmpty {
                            entry["encrypted_content"] = encrypted
                        }
                        result.append(entry)
                    }
                }
            }
            for part in msg.parts {
                switch part {
                case .text(let text):
                    let role = msg.role == .user ? "user" : "assistant"
                    result.append(["role": role, "content": text])

                case .toolUse(let id, let name, let input):
                    let argsStr = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    let (callId, fcId) = Self.splitResponsesAPIIds(id)
                    let safeCallId = Self.capResponsesId(callId)
                    var entry: [String: Any] = [
                        "type": "function_call",
                        "call_id": safeCallId,
                        "name": name,
                        "arguments": argsStr,
                    ]
                    // Responses API requires `function_call.id` to begin with
                    // `fc_` — history may carry non-`fc_` item ids; sanitize by
                    // synthesizing a deterministic `fc_syn_` id when needed.
                    let safeFcId = fcId.map { Self.capResponsesId($0) }
                    if let safeFcId, safeFcId.hasPrefix("fc_") {
                        entry["id"] = safeFcId
                    } else {
                        entry["id"] = "fc_syn_\(safeCallId.suffix(24))"
                    }
                    result.append(entry)

                case .toolResult(let id, _, let content, _, let imageData, let imageMime):
                    let (callId, _) = Self.splitResponsesAPIIds(id)
                    result.append([
                        "type": "function_call_output",
                        "call_id": Self.capResponsesId(callId),
                        "output": content,
                    ])
                    // function_call_output items don't carry images — attach any
                    // tool-emitted image as a synthetic user item with input_image.
                    if let data = imageData {
                        let mime = imageMime ?? "image/jpeg"
                        let base64 = data.base64EncodedString()
                        result.append([
                            "role": "user",
                            "content": [
                                ["type": "input_image", "image_url": "data:\(mime);base64,\(base64)"],
                            ],
                        ])
                    }

                case .imageData(let data, let mimeType):
                    let base64 = data.base64EncodedString()
                    result.append([
                        "role": msg.role == .user ? "user" : "assistant",
                        "content": [
                            ["type": "input_image", "image_url": "data:\(mimeType);base64,\(base64)"],
                        ],
                    ])
                }
            }
        }
        return result
    }

    // MARK: - Tool Conversion

    static func convertToolsResponsesAPI(_ tools: [AgentToolDefinition]) -> [[String: Any]] {
        tools.map { tool in
            var properties: [String: [String: Any]] = [:]
            for (name, param) in tool.parameters {
                var prop: [String: Any] = [
                    "type": param.type.rawValue,
                    "description": param.description,
                ]
                if let enumValues = param.enumValues {
                    prop["enum"] = enumValues
                }
                properties[name] = prop
            }

            return [
                "type": "function",
                "name": tool.name,
                "description": tool.description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": tool.required,
                ] as [String: Any],
            ]
        }
    }

    // MARK: - Helpers

    /// Extract the JSON payload from an SSE `data:` line. Tolerates the
    /// optional space after the colon — some OpenAI-compatible servers ship
    /// `data:{...}` with no space and a strict `data: ` check drops every chunk.
    static func ssePayload(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let after = line.dropFirst(5)
        if after.first == " " {
            return String(after.dropFirst())
        }
        return String(after)
    }

    static func parseJsonToDict(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    /// Diagnose empty-args tool calls: distinguish "no delta ever arrived"
    /// (raw == "") vs "model truly sent `{}`" vs "stream truncated mid-JSON".
    static func diagEmptyToolArgs(rawJson: String, toolName: String, toolId: String, model: String) {
        let utf8Bytes = rawJson.utf8.count
        let parseOk = (try? JSONSerialization.jsonObject(with: Data(rawJson.utf8), options: [])) != nil
        logger.warning("[ToolArgsProbe] EMPTY ARGS model=\(model) tool=\(toolName) id=\(toolId) bytes=\(utf8Bytes) parseOk=\(parseOk ? 1 : 0) raw=<<<\(rawJson)>>>")
    }

    // MARK: - Responses API Dual ID Helpers

    private static let maxResponsesAPIIdLength = 64

    /// Combine call_id and fc_id (item id) into a single string for transport
    /// through the agent loop. Format: "call_id|fc_id"
    static func combineResponsesAPIIds(callId: String, fcId: String) -> String {
        "\(callId)|\(fcId)"
    }

    /// Split a combined ID back into (call_id, fc_id). If the ID doesn't
    /// contain "|", treats it as call_id only (backward compatible).
    static func splitResponsesAPIIds(_ combined: String) -> (callId: String, fcId: String?) {
        if let pipe = combined.firstIndex(of: "|") {
            let callId = String(combined[combined.startIndex..<pipe])
            let fcId = String(combined[combined.index(after: pipe)...])
            return (callId, fcId)
        }
        return (combined, nil)
    }

    /// Cap a tool ID to the Responses API limit (64 chars).
    static func capResponsesId(_ id: String) -> String {
        id.count <= maxResponsesAPIIdLength ? id : String(id.prefix(maxResponsesAPIIdLength))
    }
}

// MARK: - <think> Tag Extraction

/// Streaming parser for models that embed reasoning as a `<think>…</think>`
/// PREFIX of the content instead of using a reasoning field. Rules:
///
///  - Only a `<think>` at the very START of the turn's content (leading
///    whitespace tolerated and dropped) enters thinking mode. A `<think>`
///    appearing mid-text stays in the visible body verbatim.
///  - Thinking text is returned incrementally so the caller can yield
///    live thinking deltas.
///  - After `</think>` the remainder is the reply body with whitespace
///    trimmed at both ends; interior whitespace is untouched.
///  - Turns that do NOT start with `<think>` pass through verbatim.
nonisolated struct ThinkPrefixStreamParser {
    private enum Mode { case undecided, thinking, body }
    private var mode: Mode = .undecided
    private var buf = ""
    /// True when this turn opened with a think prefix — enables body trim.
    private var hadThinkPrefix = false
    /// Leading-body trim armed from `</think>` until the first
    /// non-whitespace body character.
    private var trimLeadingBody = false

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    /// Feed one streamed content chunk. Returns text to emit now.
    mutating func consume(_ chunk: String) -> (thinking: String, visible: String) {
        buf += chunk
        var thinking = ""
        var visible = ""

        loop: while !buf.isEmpty {
            switch mode {
            case .undecided:
                let t = buf.drop(while: { $0.isWhitespace })
                if t.isEmpty { break loop }          // whitespace so far — wait
                if t.count < Self.openTag.count {
                    if Self.openTag.hasPrefix(String(t)) { break loop }  // may still become <think>
                } else if t.hasPrefix(Self.openTag) {
                    // Think turn: drop the pre-tag whitespace + the tag itself.
                    hadThinkPrefix = true
                    trimLeadingBody = true
                    mode = .thinking
                    buf = String(t.dropFirst(Self.openTag.count))
                    continue loop
                }
                // Plain turn: everything buffered is body, verbatim from here on.
                mode = .body
                visible += buf
                buf = ""

            case .thinking:
                if let close = buf.range(of: Self.closeTag) {
                    thinking += String(buf[..<close.lowerBound])
                    buf = String(buf[close.upperBound...])
                    mode = .body
                    continue loop
                }
                // No close tag yet — emit all but the last 8 chars, which
                // could be a partial "</think>" spanning chunks.
                if buf.count > 8 {
                    thinking += String(buf.dropLast(8))
                    buf = String(buf.suffix(8))
                }
                break loop

            case .body:
                if !hadThinkPrefix {
                    visible += buf
                    buf = ""
                    break loop
                }
                if trimLeadingBody {
                    buf = String(buf.drop(while: { $0.isWhitespace }))
                    if buf.isEmpty { break loop }
                    trimLeadingBody = false
                }
                // Withhold any trailing-whitespace run: emitted next chunk
                // if interior, dropped at end-of-turn if truly trailing.
                if let lastNonWS = buf.lastIndex(where: { !$0.isWhitespace }) {
                    let emitEnd = buf.index(after: lastNonWS)
                    visible += String(buf[..<emitEnd])
                    buf = String(buf[emitEnd...])
                }
                break loop
            }
        }
        return (thinking, visible)
    }

    /// Flush at a hard end-of-content boundary. Idempotent.
    mutating func finishTurn() -> (thinking: String, visible: String) {
        defer { buf = "" }
        switch mode {
        case .undecided:
            mode = .body
            return ("", buf)
        case .thinking:
            // Unclosed think — remainder is reasoning, not body.
            return (buf, "")
        case .body:
            return ("", hadThinkPrefix ? "" : buf)
        }
    }

    /// Resolve a still-undecided buffer when a tool_call arrives — content
    /// preceding a tool call can no longer become a think prefix.
    mutating func resolveAtToolBoundary() -> (thinking: String, visible: String) {
        guard mode == .undecided, !buf.isEmpty else { return ("", "") }
        mode = .body
        defer { buf = "" }
        return ("", buf)
    }
}
