// Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis) —
// Views/Chat/OffloadPermissionDialog.swift (simplified) and
// Views/Settings/OffloadPermissionSettingsView.swift.
// Copyright (C) OpenMinis contributors. Licensed under GPL-3.0; see LICENSE.
// Modifications for vibetaking: SwiftUI sheet driven by @Observable manager;
// command list trimmed to calendar / reminders / clipboard.

import SwiftUI

// MARK: - 授权弹窗

struct OffloadPermissionDialog: View {
    let request: PermissionRequest
    @State private var manager = OffloadPermissionManager.shared

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: iconName)
                .font(.system(size: 40))
                .foregroundStyle(Design.primaryColor)
                .padding(.top, 28)

            VStack(spacing: 6) {
                Text("允许 AI 访问\(request.displayLabel)？")
                    .font(.headline)
                if !request.description.isEmpty {
                    Text(request.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            let arguments = request.parsedArguments
            if !arguments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(arguments.enumerated()), id: \.offset) { _, pair in
                        HStack(alignment: .top, spacing: 8) {
                            Text(pair.key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .trailing)
                            Text(pair.value)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
            }

            Text("本次会话内不再重复询问")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 12) {
                Button {
                    manager.respond(to: request.id, allowed: false)
                } label: {
                    Text("拒绝")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Button {
                    manager.respond(to: request.id, allowed: true)
                } label: {
                    Text("允许")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    private var iconName: String {
        switch request.commandName {
        case "apple-calendar": return "calendar"
        case "apple-reminders": return "checklist"
        case "apple-clipboard": return "doc.on.clipboard"
        default: return "questionmark.circle"
        }
    }
}

// MARK: - 设置页权限段落

struct OffloadPermissionSettingsView: View {
    @State private var manager = OffloadPermissionManager.shared

    var body: some View {
        List {
            Section {
                ForEach(OffloadPermissionManager.allCommands, id: \.name) { command in
                    Picker(selection: Binding(
                        get: { manager.permissionLevel(for: command.name) },
                        set: { manager.setPermissionLevel($0, for: command.name) }
                    )) {
                        ForEach(OffloadPermissionLevel.allCases, id: \.rawValue) { level in
                            Text(level.displayName).tag(level)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.displayLabel)
                            Text(command.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("控制 AI 助手对设备能力的访问。「每次询问」在每个会话首次使用时弹窗确认；iOS 系统级权限弹窗仍会独立出现。")
            }
        }
        .navigationTitle("设备权限")
        .navigationBarTitleDisplayMode(.inline)
    }
}
