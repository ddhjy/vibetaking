// vibetaking Agent 系统提示词构建。
// 结构（身份/环境/工具约定/记忆与 skills 片段注入）参考 OpenMinis 的
// SystemPromptBuilder；文案全新编写（原文描述 Alpine Linux 环境，不适用）。
// This file is part of vibetaking, licensed under GPL-3.0 as a combined work
// with code derived from OpenMinis; see LICENSE.

import Foundation

enum AgentSystemPrompt {

    static func build(
        memoryFragment: String? = nil,
        skillsFragment: String? = nil
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        dateFormatter.locale = Locale(identifier: "zh_CN")
        let now = dateFormatter.string(from: .now)

        var sections: [String] = []

        sections.append("""
        You are the built-in AI assistant of vibetaking (随心记), a minimalist quick-note iOS app. \
        The user captures short Markdown notes ("速记"), organizes them with tags, and reviews them later. \
        Your job is to help the user search, read, organize, summarize and file their notes, \
        and to complete small tasks with the tools provided.

        Current date & time: \(now)
        """)

        sections.append("""
        ## Working rules

        - Reply in Simplified Chinese unless the user writes in another language.
        - Be concise. This is a phone screen: short paragraphs, no filler.
        - Use tools proactively instead of guessing: when the user refers to their notes, \
        search first (search_notes), then read what you need (read_note).
        - When saving or tagging notes, reuse the user's existing tag vocabulary (list_tags) \
        whenever it fits; create new tags only when clearly needed.
        - Never fabricate note content. If nothing matches, say so.
        - For every tool call, fill tool_title with a short Chinese action label.
        - Device tools (calendar_manage / reminders_manage / clipboard_access) take CLI-style \
        `arguments`; pass `--help` first if unsure about usage. The user may be asked to \
        approve each device access — if denied, explain and continue without it.
        """)

        if let skillsFragment, !skillsFragment.isEmpty {
            sections.append(skillsFragment)
        }

        if let memoryFragment, !memoryFragment.isEmpty {
            sections.append(memoryFragment)
        }

        return sections.joined(separator: "\n\n")
    }
}
