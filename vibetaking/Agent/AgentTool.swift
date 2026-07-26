// vibetaking Agent 工具协议与注册表。
// 设计替代 OpenMinis 中散布 5 处的平行 switch 派发（AIChatViewModel+ToolDefinitions
// / +ConcurrentTools 等），收敛为协议 + 字典注册表。
// This file is part of vibetaking, licensed under GPL-3.0 as a combined work
// with code derived from OpenMinis; see LICENSE.

import Foundation

/// 单个工具的执行结果。
struct AgentToolResult {
    let content: String
    let isError: Bool
    var imageData: Data? = nil
    var imageMimeType: String? = nil

    static func success(_ content: String) -> AgentToolResult {
        AgentToolResult(content: content, isError: false)
    }

    static func failure(_ message: String) -> AgentToolResult {
        AgentToolResult(content: "Error: \(message)", isError: true)
    }
}

/// Agent 可调用工具。默认 MainActor 隔离（工程全局默认），execute 内部可
/// await 系统异步 API，多个工具的等待可在 TaskGroup 中重叠。
protocol AgentTool {
    /// 提供给模型的工具 schema。
    var definition: AgentToolDefinition { get }
    func execute(args: [String: Any]) async -> AgentToolResult
}

/// 工具注册表：name → AgentTool。
@Observable
class ToolRegistry {
    private(set) var tools: [String: AgentTool] = [:]
    /// 注册顺序，保证发给模型的工具列表稳定（利于 prompt cache 命中）。
    private var order: [String] = []

    init(tools: [AgentTool] = []) {
        for tool in tools { register(tool) }
    }

    func register(_ tool: AgentTool) {
        let name = tool.definition.name
        if tools[name] == nil {
            order.append(name)
        }
        tools[name] = tool
    }

    func tool(named name: String) -> AgentTool? {
        tools[name]
    }

    var definitions: [AgentToolDefinition] {
        order.compactMap { tools[$0]?.definition }
    }
}
