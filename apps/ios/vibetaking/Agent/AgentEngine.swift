// Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis) — the core
// agent loop extracted from Agent/Chat/AIChatViewModel.swift `runAgentLoop()`
// and Agent/Chat/AIChatViewModel+ConcurrentTools.swift.
// Copyright (C) OpenMinis contributors. Licensed under GPL-3.0; see LICENSE.
// Modifications for vibetaking: standalone engine class (no God-ViewModel),
// tool dispatch via ToolRegistry instead of hard-coded switches, removed iSH
// shell / browser / MCP / TTS / Live Activity / in-loop compaction / model
// fallback; persistence is handled by the caller.

import Foundation

private nonisolated let logger = AppLogger(category: "AgentEngine")

/// 引擎在执行过程中向 UI 层发出的事件。
enum AgentEngineEvent {
    /// 助手可见文本增量。
    case assistantTextDelta(String)
    /// 思考内容增量（reasoning summary / <think> 前缀）。
    case thinkingDelta(String)
    /// 一个工具调用开始（参数还在流式累积中）。
    case toolCallStarted(id: String, name: String)
    /// 工具参数流式累积。
    case toolInputDelta(id: String, name: String, accumulatedJSON: String)
    /// 一个工具执行完成。
    case toolCallFinished(id: String, name: String, result: String, isError: Bool)
    /// 一轮 API 往返结束（assistant 消息已定型）。
    case turnCompleted
    /// 用量统计。
    case usage(LLMUsage)
}

/// 多轮工具调用循环引擎。一个实例对应一次会话（持有 agentHistory）。
@Observable
class AgentEngine {
    /// Hard backstop against runaway tool loops that slip past ToolLoopDetector.
    static let maxAgentTurns = 50
    /// In-flight cap for concurrent tool dispatch.
    static let maxConcurrentTools = 5

    /// Provider 无关的会话历史（发给 API 的形态）。
    private(set) var agentHistory: [AgentMessage] = []
    private(set) var isRunning = false

    let registry: ToolRegistry
    private let loopDetector = ToolLoopDetector()
    private var runTask: Task<Void, Never>?

    init(registry: ToolRegistry, history: [AgentMessage] = []) {
        self.registry = registry
        self.agentHistory = history
    }

    func replaceHistory(_ history: [AgentMessage]) {
        agentHistory = history
        loopDetector.reset()
    }

    func cancel() {
        runTask?.cancel()
    }

    /// 运行一次完整的 agent loop：追加用户消息 → 多轮「模型流式响应 + 工具执行」
    /// 直到模型不再请求工具。返回最终 assistant 文本。
    /// - Parameter onEvent: 流式事件回调（MainActor 上调用）。
    @discardableResult
    func run(
        userText: String,
        systemPrompt: String,
        provider: AgentProvider,
        thinkingLevel: ThinkingLevel = .off,
        onEvent: @escaping (AgentEngineEvent) -> Void
    ) async throws -> String {
        guard !isRunning else { throw LLMError.providerError(message: "助手还在处理上一条消息。请等待完成，或先停止处理。") }
        isRunning = true
        defer { isRunning = false }

        agentHistory.append(AgentMessage(role: .user, parts: [.text(userText)]))
        repairHistoryPairing()

        let tools = registry.definitions
        var finalText = ""

        // Counted instead of `while true` so we have a hard backstop against
        // runaway tool loops.
        var turnCount = 0
        while turnCount < Self.maxAgentTurns {
            defer { turnCount += 1 }
            try Task.checkCancellation()

            let turn = try await streamOneTurn(
                provider: provider,
                systemPrompt: systemPrompt,
                tools: tools,
                thinkingLevel: thinkingLevel,
                onEvent: onEvent
            )

            if !turn.assistantParts.isEmpty || turn.reasoningContent != nil {
                var assistantMessage = AgentMessage(role: .assistant, parts: turn.assistantParts)
                assistantMessage.reasoningContent = turn.reasoningContent
                assistantMessage.reasoningEcho = turn.reasoningEcho
                agentHistory.append(assistantMessage)
            }
            finalText += turn.assistantText

            onEvent(.turnCompleted)

            // No tool calls → the model has finished its answer.
            guard turn.stopReason == .toolUse, !turn.toolEntries.isEmpty else {
                if turn.stopReason == .refusal {
                    throw LLMError.providerError(message: "AI 服务无法协助这次请求。可以尝试其他记录整理任务。")
                }
                break
            }

            // Execute tools concurrently with an in-flight cap; stitch results
            // back in original tool_use order so tool_result blocks pair
            // correctly with the assistant message's tool_use blocks.
            let toolResultParts = await executeToolBatch(
                turn.toolEntries, tools: tools, onEvent: onEvent
            )
            agentHistory.append(AgentMessage(role: .user, parts: toolResultParts))
        }

        if turnCount >= Self.maxAgentTurns {
            logger.warning("Agent loop exhausted the \(Self.maxAgentTurns)-turn ceiling")
        }
        return finalText
    }

    // MARK: - Single Turn Streaming

    /// 一次 API 往返收集到的结果。
    private struct TurnResult {
        var assistantParts: [AgentContentPart] = []
        var assistantText: String = ""
        var toolEntries: [ToolEntry] = []
        var reasoningContent: String?
        var reasoningEcho: ReasoningEcho?
        var stopReason: AgentStopReason = .endTurn
    }

    struct ToolEntry {
        let id: String
        let name: String
        let args: [String: Any]
    }

    private func streamOneTurn(
        provider: AgentProvider,
        systemPrompt: String,
        tools: [AgentToolDefinition],
        thinkingLevel: ThinkingLevel,
        onEvent: @escaping (AgentEngineEvent) -> Void
    ) async throws -> TurnResult {
        var turn = TurnResult()
        var currentText = ""

        func flushTextPart() {
            if !currentText.isEmpty {
                turn.assistantParts.append(.text(currentText))
                turn.assistantText += currentText
                currentText = ""
            }
        }

        do {
            let stream = try await provider.streamAgentMessage(
                messages: agentHistory,
                systemPrompt: systemPrompt,
                tools: tools,
                maxTokens: provider.defaultMaxTokens,
                thinkingLevel: thinkingLevel
            )

            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .contentBlockStart(let blockStart):
                    if case .toolUse(let id, let name) = blockStart {
                        onEvent(.toolCallStarted(id: id, name: name))
                    }

                case .textDelta(let delta):
                    currentText += delta
                    onEvent(.assistantTextDelta(delta))

                case .thinkingDelta(let delta):
                    onEvent(.thinkingDelta(delta))

                case .toolInputDelta(let name, let accumulated):
                    onEvent(.toolInputDelta(id: "", name: name, accumulatedJSON: accumulated))

                case .toolCallComplete(let id, let name, let rawArgs, let rawJSON):
                    // JSON repair BEFORE preflight: salvage truncated /
                    // type-mismatched / typo'd args when possible.
                    let repaired = ToolPreflight.repairToolArgs(
                        name: name, args: rawArgs, rawTail: rawJSON, tools: tools
                    )
                    if !repaired.repairs.isEmpty {
                        logger.warning("Repaired tool args for \(name): \(repaired.repairs.joined(separator: ", "))")
                    }
                    // Keep tool_use in the assistant parts BEFORE its results —
                    // text so far becomes its own part first.
                    flushTextPart()
                    turn.assistantParts.append(.toolUse(id: id, name: name, input: repaired.args))
                    turn.toolEntries.append(ToolEntry(id: id, name: name, args: repaired.args))

                case .usage(let usage):
                    onEvent(.usage(usage))

                case .reasoningContent(let content):
                    turn.reasoningContent = content

                case .reasoningEcho(let echo):
                    turn.reasoningEcho = echo

                case .done(let stopReason):
                    turn.stopReason = stopReason
                }
            }
            flushTextPart()
        } catch {
            // Stream interrupted mid-turn: keep what we have, marked
            // interrupted so history repair won't inject placeholder
            // tool_results for incomplete tool_use blocks (API 400 otherwise).
            flushTextPart()
            if !turn.assistantParts.isEmpty {
                var interrupted = AgentMessage(role: .assistant, parts: turn.assistantParts)
                interrupted.isInterrupted = true
                interrupted.reasoningContent = turn.reasoningContent
                agentHistory.append(interrupted)
            }
            throw error
        }
        return turn
    }

    // MARK: - Concurrent Tool Execution

    private func executeToolBatch(
        _ toolEntries: [ToolEntry],
        tools: [AgentToolDefinition],
        onEvent: @escaping (AgentEngineEvent) -> Void
    ) async -> [AgentContentPart] {
        var outcomesByIndex: [Int: AgentContentPart] = [:]

        await withTaskGroup(of: (Int, AgentContentPart).self) { group in
            var added = 0
            var harvested = 0
            for (idx, entry) in toolEntries.enumerated() {
                // Rate-limit: hold here until we're below the in-flight cap.
                while added - harvested >= Self.maxConcurrentTools {
                    if let pair = await group.next() {
                        outcomesByIndex[pair.0] = pair.1
                        harvested += 1
                    } else {
                        break
                    }
                }
                group.addTask { @MainActor in
                    let part = await self.executeSingleTool(entry, tools: tools, onEvent: onEvent)
                    return (idx, part)
                }
                added += 1
            }
            for await pair in group {
                outcomesByIndex[pair.0] = pair.1
            }
        }

        // Stitch outcomes back in original tool_use order.
        var parts: [AgentContentPart] = []
        for idx in 0..<toolEntries.count {
            if let part = outcomesByIndex[idx] {
                parts.append(part)
            }
        }
        return parts
    }

    private func executeSingleTool(
        _ entry: ToolEntry,
        tools: [AgentToolDefinition],
        onEvent: @escaping (AgentEngineEvent) -> Void
    ) async -> AgentContentPart {
        let toolId = entry.id
        let name = entry.name

        // 1. Loop detector pre-check: blocked calls never execute.
        let loopCheck = loopDetector.check(toolName: name, params: entry.args)
        if loopCheck.level == .critical, let message = loopCheck.message {
            loopDetector.record(toolName: name, params: entry.args, result: nil, errorMessage: message, toolCallId: toolId)
            onEvent(.toolCallFinished(id: toolId, name: name, result: message, isError: true))
            return .toolResult(id: toolId, name: name, content: message, isError: true)
        }

        // 2. Preflight validation against the canonical schema.
        if let reason = ToolPreflight.preflightValidateToolCall(name: name, args: entry.args, tools: tools) {
            loopDetector.record(toolName: name, params: entry.args, result: nil, errorMessage: reason, toolCallId: toolId)
            onEvent(.toolCallFinished(id: toolId, name: name, result: reason, isError: true))
            return .toolResult(id: toolId, name: name, content: reason, isError: true)
        }

        // 3. Dispatch through the registry.
        guard let tool = registry.tool(named: name) else {
            let message = "Error: Unknown tool '\(name)'. Available tools: \(tools.map(\.name).joined(separator: ", "))"
            loopDetector.record(toolName: name, params: entry.args, result: nil, errorMessage: "unknown tool: \(name)", toolCallId: toolId)
            onEvent(.toolCallFinished(id: toolId, name: name, result: message, isError: true))
            return .toolResult(id: toolId, name: name, content: message, isError: true)
        }

        let result = await tool.execute(args: entry.args)

        // 4. Post-hoc loop record; append any warning so the model sees it.
        var content = result.content
        let postCheck = loopDetector.record(
            toolName: name,
            params: entry.args,
            result: result.isError ? nil : result.content,
            errorMessage: result.isError ? result.content : nil,
            toolCallId: toolId
        )
        if postCheck.level == .warning, let warning = postCheck.message {
            content += "\n\n\(warning)"
        }

        onEvent(.toolCallFinished(id: toolId, name: name, result: content, isError: result.isError))
        return .toolResult(
            id: toolId, name: name, content: content, isError: result.isError,
            imageData: result.imageData, imageMimeType: result.imageMimeType
        )
    }

    // MARK: - History Pairing Repair

    /// Scan the history for orphaned tool_uses / tool_results and repair
    /// pairing before a new API call. Orphaned tool_results cause API 400
    /// ("unexpected tool_use_id found in tool_result blocks"); orphaned
    /// tool_uses need placeholder results injected.
    private func repairHistoryPairing() {
        // Drop a trailing interrupted assistant message whose tool_use blocks
        // may carry incomplete inputs — replaying them 400s.
        if let last = agentHistory.last, last.role == .assistant, last.isInterrupted {
            let hasToolUse = last.parts.contains { if case .toolUse = $0 { return true }; return false }
            if hasToolUse {
                agentHistory.removeLast()
                logger.warning("Dropped interrupted assistant message with partial tool_use(s)")
            }
        }

        var allToolUseIds = Set<String>()
        var allToolResultIds = Set<String>()
        for msg in agentHistory {
            for part in msg.parts {
                if case .toolUse(let id, _, _) = part {
                    allToolUseIds.insert(id)
                }
                if case .toolResult(let id, _, _, _, _, _) = part {
                    allToolResultIds.insert(id)
                }
            }
        }

        // 1. Remove orphaned tool_results (tool_result without matching tool_use).
        var removedOrphanedResults = 0
        for i in (0..<agentHistory.count).reversed() {
            let msg = agentHistory[i]
            guard msg.role == .user else { continue }
            let beforeCount = msg.parts.count
            let cleanedParts = msg.parts.filter { part in
                if case .toolResult(let id, _, _, _, _, _) = part {
                    if !allToolUseIds.contains(id) {
                        logger.warning("Removing orphaned tool_result id=\(id) at history[\(i)]")
                        removedOrphanedResults += 1
                        return false
                    }
                }
                return true
            }
            if cleanedParts.count < beforeCount {
                if cleanedParts.isEmpty {
                    agentHistory.remove(at: i)
                } else {
                    agentHistory[i] = AgentMessage(role: .user, parts: cleanedParts)
                }
            }
        }
        if removedOrphanedResults > 0 {
            logger.warning("Removed \(removedOrphanedResults) orphaned tool_result(s)")
        }

        // 2. Inject placeholder tool_results for orphaned tool_uses.
        //    Skip interrupted assistant messages — their tool_use inputs may be
        //    incomplete and a tool_result for an empty-input tool_use 400s.
        allToolResultIds.removeAll()
        for msg in agentHistory {
            for part in msg.parts {
                if case .toolResult(let id, _, _, _, _, _) = part {
                    allToolResultIds.insert(id)
                }
            }
        }

        var insertions: [(index: Int, message: AgentMessage)] = []
        for (i, msg) in agentHistory.enumerated() {
            guard msg.role == .assistant, !msg.isInterrupted else { continue }
            let orphanedToolUses = msg.parts.compactMap { part -> (String, String)? in
                if case .toolUse(let id, let name, _) = part, !allToolResultIds.contains(id) {
                    return (id, name)
                }
                return nil
            }
            guard !orphanedToolUses.isEmpty else { continue }

            let placeholderParts = orphanedToolUses.map { (id, name) in
                AgentContentPart.toolResult(
                    id: id, name: name,
                    content: "Tool execution was interrupted by an unexpected error.",
                    isError: true
                )
            }
            insertions.append((index: i + 1, message: AgentMessage(role: .user, parts: placeholderParts)))
            logger.warning("Found \(orphanedToolUses.count) orphaned tool_use(s) in assistant message at index \(i)")
        }
        for insertion in insertions.reversed() {
            agentHistory.insert(insertion.message, at: insertion.index)
        }
    }
}
