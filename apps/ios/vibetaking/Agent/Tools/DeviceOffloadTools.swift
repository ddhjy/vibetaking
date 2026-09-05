// vibetaking 设备工具适配层：把 OpenMinis 的 CLI 形态 offload handler
// （apple-calendar / apple-reminders / apple-clipboard，ObjC + 系统框架）
// 包装为 AgentTool。handler 保持 argc/argv + fd 签名原样，本层负责：
// shell 风格分词 → C argv 构造 → 临时文件承接 stdout/stderr → 后台线程执行
// （handler 内部经 noff_dispatch_main_sync 跳主线程，调用方不能阻塞主线程）。
// This file is part of vibetaking, licensed under GPL-3.0 as a combined work
// with code derived from OpenMinis; see LICENSE.

import Foundation

private nonisolated let logger = AppLogger(category: "DeviceOffload")

// MARK: - Offload Runner

nonisolated enum DeviceOffloadRunner {
    typealias OffloadMain = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, Int32, Int32, Int32) -> Int32

    struct Output {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// 在后台线程执行一个 offload handler。argv[0] 是命令名。
    static func run(_ main: @escaping OffloadMain, argv: [String]) async -> Output {
        await Task.detached(priority: .userInitiated) { () -> Output in
            // 临时文件承接 stdout/stderr（无管道缓冲上限问题）。
            let tmpDir = FileManager.default.temporaryDirectory
            let outURL = tmpDir.appendingPathComponent("offload-out-\(UUID().uuidString)")
            let errURL = tmpDir.appendingPathComponent("offload-err-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            FileManager.default.createFile(atPath: errURL.path, contents: nil)
            defer {
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.removeItem(at: errURL)
            }

            let outFD = open(outURL.path, O_WRONLY)
            let errFD = open(errURL.path, O_WRONLY)
            defer {
                if outFD >= 0 { close(outFD) }
                if errFD >= 0 { close(errFD) }
            }
            guard outFD >= 0, errFD >= 0 else {
                return Output(exitCode: -1, stdout: "", stderr: "failed to open temp output files")
            }

            // 构造 C argv（strdup 后必须 free）。
            var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
            cArgv.append(nil)
            defer {
                for ptr in cArgv where ptr != nil { free(ptr) }
            }

            let exitCode = cArgv.withUnsafeMutableBufferPointer { buffer in
                main(Int32(argv.count), buffer.baseAddress, -1, outFD, errFD)
            }

            let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
            let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            return Output(exitCode: exitCode, stdout: stdout, stderr: stderr)
        }.value
    }
}

// MARK: - Base tool implementation

/// 三个设备工具的公共执行路径：权限门控 → 分词 → 执行 → 输出。
private func executeDeviceCommand(
    commandName: String,
    sessionId: String,
    main: @escaping DeviceOffloadRunner.OffloadMain,
    args: [String: Any]
) async -> AgentToolResult {
    let rawArguments = ToolArgs.string(args, "arguments") ?? ""
    var argv = [commandName]
    argv.append(contentsOf: tokenizeCommandLine(rawArguments))

    // 应用层三档权限门控（独立于 iOS 系统权限弹窗）。
    let fullCommand = "\(commandName) \(rawArguments)"
    let permission = await OffloadPermissionManager.shared.checkPermission(
        for: commandName, sessionId: sessionId, fullCommand: fullCommand
    )
    if case .denied(let message) = permission {
        return .failure(message)
    }

    let output = await DeviceOffloadRunner.run(main, argv: argv)

    var content = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let stderrText = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if content.isEmpty && !stderrText.isEmpty {
        content = stderrText
    } else if !stderrText.isEmpty && output.exitCode != 0 {
        content += "\n[stderr]\n\(stderrText)"
    }
    if content.isEmpty {
        content = "(no output, exit code \(output.exitCode))"
    }
    if output.exitCode != 0 {
        return AgentToolResult(content: content, isError: true)
    }
    return .success(content)
}

// MARK: - calendar_manage

struct CalendarManageTool: AgentTool {
    let sessionId: String
    var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: "calendar_manage",
            description: """
            访问 iOS 系统日历（读取/创建/修改/删除日程，查询忙闲）。CLI 风格参数。\
            常用：`list --today` 列今天日程；`list --start -7d --limit 20`；\
            `calendars` 列日历；`freebusy --start 2026-08-01 --end 2026-08-02`；\
            `create --title "标题" --start 2026-08-01T10:00 --end 2026-08-01T11:00 [--location 地点] [--notes 备注] [--alarm -15]`；\
            `update --id <event_id> --title ...`；`delete --id <event_id>`。\
            日期支持 ISO 8601 或相对（-7d/-2h/-30m）。传 `--help` 查看完整用法。输出为 JSON。
            """,
            parameters: [
                "arguments": AgentToolParam(type: .string, description: "CLI 参数串（不含命令名），如：list --today"),
                "tool_title": AgentToolParam(type: .string, description: "简短中文动作标题，如：查看今天日程"),
            ],
            required: ["arguments", "tool_title"]
        )
    }

    func execute(args: [String: Any]) async -> AgentToolResult {
        await executeDeviceCommand(commandName: "apple-calendar", sessionId: sessionId, main: apple_calendar_main, args: args)
    }
}

// MARK: - reminders_manage

struct RemindersManageTool: AgentTool {
    let sessionId: String
    var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: "reminders_manage",
            description: """
            访问 iOS 系统提醒事项（读取/创建/完成/删除提醒）。CLI 风格参数。\
            常用：`list --incomplete` 列未完成提醒；`list --list 购物`；\
            `create --title "标题" [--due 2026-08-01T10:00] [--notes 备注] [--list 列表名] [--priority high]`；\
            `complete --id <reminder_id>`；`delete --id <reminder_id>`。\
            传 `--help` 查看完整用法。输出为 JSON。
            """,
            parameters: [
                "arguments": AgentToolParam(type: .string, description: "CLI 参数串（不含命令名），如：list --incomplete"),
                "tool_title": AgentToolParam(type: .string, description: "简短中文动作标题，如：创建提醒"),
            ],
            required: ["arguments", "tool_title"]
        )
    }

    func execute(args: [String: Any]) async -> AgentToolResult {
        await executeDeviceCommand(commandName: "apple-reminders", sessionId: sessionId, main: apple_reminders_main, args: args)
    }
}

// MARK: - clipboard_access

struct ClipboardAccessTool: AgentTool {
    let sessionId: String
    var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: "clipboard_access",
            description: """
            读写 iOS 系统剪贴板。CLI 风格参数。\
            常用：`get` 读取剪贴板文本；`set --text "内容"` 写入；`clear` 清空；`status` 查看内容类型。\
            输出为 JSON。
            """,
            parameters: [
                "arguments": AgentToolParam(type: .string, description: "CLI 参数串（不含命令名），如：get 或 set --text \"你好\""),
                "tool_title": AgentToolParam(type: .string, description: "简短中文动作标题，如：读取剪贴板"),
            ],
            required: ["arguments", "tool_title"]
        )
    }

    func execute(args: [String: Any]) async -> AgentToolResult {
        await executeDeviceCommand(commandName: "apple-clipboard", sessionId: sessionId, main: apple_clipboard_main, args: args)
    }
}
