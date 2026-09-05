// Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis) —
// Agent/Offload/OffloadPermissionManager.swift
// Copyright (C) OpenMinis contributors. Licensed under GPL-3.0; see LICENSE.
// Modifications for vibetaking: command list trimmed to calendar / reminders /
// clipboard; @Observable instead of ObservableObject; deep link text points
// to the in-app settings sheet.

import Foundation
import SwiftUI

// MARK: - Types

enum OffloadPermissionLevel: Int, CaseIterable {
    case bypass = 0
    case askOnce = 1
    case notAllowed = 2

    var displayName: String {
        switch self {
        case .bypass: return "直接允许"
        case .askOnce: return "每段会话询问"
        case .notAllowed: return "禁止"
        }
    }
}

enum PermissionResult {
    case allowed
    case denied(String)
}

struct PermissionRequest: Identifiable {
    let id: String
    let sessionID: String
    let commandName: String
    let displayLabel: String
    let description: String
    /// The full command string, e.g. "apple-calendar list --today"
    let fullCommand: String
    let continuation: CheckedContinuation<Bool, Never>

    /// Parse the command arguments into displayable key-value pairs.
    /// Handles patterns like: `command subcommand --key value --flag`.
    var parsedArguments: [(key: String, value: String)] {
        let parts = tokenizeCommandLine(fullCommand)
        guard parts.count > 1 else { return [] }

        var result: [(key: String, value: String)] = []
        var idx = 1
        if idx < parts.count && !parts[idx].hasPrefix("-") {
            result.append((key: "操作", value: parts[idx]))
            idx += 1
        }
        while idx < parts.count {
            let token = parts[idx]
            if token.hasPrefix("--") || token.hasPrefix("-") {
                let key = token.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                if idx + 1 < parts.count && !Self.isOption(parts[idx + 1]) {
                    result.append((key: key, value: parts[idx + 1]))
                    idx += 2
                } else {
                    result.append((key: key, value: "true"))
                    idx += 1
                }
            } else {
                result.append((key: "arg", value: token))
                idx += 1
            }
        }
        return result
    }

    private static func isOption(_ token: String) -> Bool {
        token.hasPrefix("--") || (token.hasPrefix("-") && token.dropFirst().first?.isLetter == true)
    }
}

// MARK: - Command Definitions

struct OffloadCommandInfo {
    let name: String
    let displayLabel: String
    let description: String
}

// MARK: - Manager

@Observable
final class OffloadPermissionManager {
    static let shared = OffloadPermissionManager()

    static let allCommands: [OffloadCommandInfo] = [
        .init(name: "apple-calendar", displayLabel: "日历", description: "读取与创建日程、查询忙闲"),
        .init(name: "apple-reminders", displayLabel: "提醒事项", description: "读取与创建提醒、标记完成"),
        .init(name: "apple-clipboard", displayLabel: "剪贴板", description: "读取与写入系统剪贴板"),
    ]

    var pendingRequest: PermissionRequest?
    private var queuedRequests: [PermissionRequest] = []

    /// Per-session "Ask Once" grants: [sessionId: Set<commandName>]
    private var sessionGrants: [String: Set<String>] = [:]

    private var defaults: UserDefaults { AppDefaults.current }
    private let logger = AppLogger(category: "OffloadPermission")

    private init() {}

    // MARK: - Storage

    private func defaultsKey(for command: String) -> String {
        "offloadPermission.\(command)"
    }

    func permissionLevel(for command: String) -> OffloadPermissionLevel {
        guard let stored = defaults.object(forKey: defaultsKey(for: command)) as? Int else {
            // vibetaking 默认「每次询问」——设备数据默认不静默放行。
            return .askOnce
        }
        return OffloadPermissionLevel(rawValue: stored) ?? .askOnce
    }

    func setPermissionLevel(_ level: OffloadPermissionLevel, for command: String) {
        defaults.set(level.rawValue, forKey: defaultsKey(for: command))
    }

    // MARK: - Permission Check

    func checkPermission(for command: String, sessionId: String?, fullCommand: String = "") async -> PermissionResult {
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionId = trimmed.isEmpty ? "offload-global" : trimmed
        let level = permissionLevel(for: command)

        switch level {
        case .bypass:
            return .allowed

        case .notAllowed:
            logger.info("Permission denied (Not Allowed): \(command)")
            let label = Self.allCommands.first(where: { $0.name == command })?.displayLabel ?? command
            return .denied("\(label)访问已禁用。如需允许，可前往设置 > AI 助手 > 设备权限修改。")

        case .askOnce:
            // Check session grant
            if sessionGrants[sessionId]?.contains(command) == true {
                return .allowed
            }

            let cmdInfo = Self.allCommands.first(where: { $0.name == command })
            let displayLabel = cmdInfo?.displayLabel ?? command
            let description = cmdInfo?.description ?? ""

            let requestID = UUID().uuidString
            let allowed = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: false)
                        return
                    }
                    let request = PermissionRequest(
                        id: requestID,
                        sessionID: sessionId,
                        commandName: command,
                        displayLabel: displayLabel,
                        description: description,
                        fullCommand: fullCommand,
                        continuation: continuation
                    )
                    if self.pendingRequest == nil {
                        self.pendingRequest = request
                    } else {
                        self.queuedRequests.append(request)
                    }
                }
            } onCancel: {
                Task { @MainActor in
                    self.respond(to: requestID, allowed: false)
                }
            }

            if allowed {
                sessionGrants[sessionId, default: []].insert(command)
                logger.info("Permission granted (Ask Once): \(command)")
                return .allowed
            } else {
                logger.info("Permission denied (Ask Once): \(command)")
                return .denied("未获得\(displayLabel)访问授权，本次操作未执行。")
            }
        }
    }

    // MARK: - UI Response

    func respond(to requestId: String, allowed: Bool) {
        if let request = pendingRequest, request.id == requestId {
            pendingRequest = nil
            finish(request, allowed: allowed)
            presentNextRequest()
        } else if let index = queuedRequests.firstIndex(where: { $0.id == requestId }) {
            let request = queuedRequests.remove(at: index)
            finish(request, allowed: allowed)
        }
    }

    private func finish(_ request: PermissionRequest, allowed: Bool) {
        if allowed {
            sessionGrants[request.sessionID, default: []].insert(request.commandName)
        }
        request.continuation.resume(returning: allowed)
    }

    private func presentNextRequest() {
        while pendingRequest == nil, !queuedRequests.isEmpty {
            let next = queuedRequests.removeFirst()
            if sessionGrants[next.sessionID]?.contains(next.commandName) == true {
                finish(next, allowed: true)
            } else {
                pendingRequest = next
            }
        }
    }

    // MARK: - Session Reset

    func resetSessionGrants(for sessionId: String) {
        sessionGrants.removeValue(forKey: sessionId)
    }
}
