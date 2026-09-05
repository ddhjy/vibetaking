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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var manager = OffloadPermissionManager.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(spacing: 12) {
                        Image(systemName: iconName)
                            .font(.largeTitle)
                            .foregroundStyle(Design.primaryColor)
                            .accessibilityHidden(true)
                        Text("允许 AI 助手访问\(request.displayLabel)？")
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        if !request.description.isEmpty {
                            Text(request.description).font(.body).foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                    if !request.parsedArguments.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("本次操作详情").font(.headline).accessibilityAddTraits(.isHeader)
                            ForEach(Array(request.parsedArguments.enumerated()), id: \.offset) { _, pair in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(pair.key).font(.subheadline).foregroundStyle(.secondary)
                                    Text(pair.value)
                                        .font(.system(.footnote, design: .monospaced))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("允许后，这次对话内再访问\(request.displayLabel)时不再询问。如果不允许，这次操作会跳过。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: Design.readingWidth)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("设备访问")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    Button { manager.respond(to: request.id, allowed: true) } label: {
                        Text("允许本次对话访问").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { manager.respond(to: request.id, allowed: false) } label: {
                        Text("不允许").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(16)
                .background(Color(.systemBackground))
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .interactiveDismissDisabled()
        .accessibilityAction(.escape) { manager.respond(to: request.id, allowed: false) }
    }

    private var iconName: String {
        switch request.commandName {
        case "apple-calendar": "calendar"
        case "apple-reminders": "checklist"
        case "apple-clipboard": "doc.on.clipboard"
        default: "questionmark.circle"
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
                    .pickerStyle(.navigationLink)
                }
            } footer: {
                Text("新对话首次访问时会征求同意。选择“始终允许”可跳过确认，“不允许”则阻止访问。系统日历和提醒事项权限需在系统设置中单独开启。")
            }
        }
        .navigationTitle("设备权限")
        .navigationBarTitleDisplayMode(.inline)
    }
}
