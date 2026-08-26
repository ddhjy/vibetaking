// Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis) —
// Agent/Session/SkillStore.swift (trimmed).
// Copyright (C) OpenMinis contributors. Licensed under GPL-3.0; see LICENSE.
// Modifications for vibetaking: skills live in the iCloud records folder
// (_skills/<id>/SKILL.md) and are discovered by directory scan; use counts and
// disabled-set persist in UserDefaults; removed SQLite metadata DB, GitHub /
// ZIP import, iCloud sync tables, per-session overrides and rootfs mirroring.
// The YAML frontmatter parser and the priority-based prompt disclosure are
// ported as-is.

import Foundation

private nonisolated let logger = AppLogger(category: "SkillStore")

// MARK: - Skill Model

struct Skill: Identifiable {
    let id: String
    var name: String
    var description: String
    var version: String
    var isEnabled: Bool
    var updatedAt: Date

    /// Raw body content (everything after YAML frontmatter)
    var body: String

    /// Normalized usage count (0–100 range after normalization, raw count before).
    var useCount: Double = 0
}

// MARK: - SkillStore

@Observable
class SkillStore {
    static let shared = SkillStore()

    private static let useCountsKey = "agentSkillUseCounts"
    private static let disabledSkillsKey = "agentSkillsDisabled"

    private(set) var skills: [Skill] = []
    private var loaded = false

    private init() {}

    /// Skills 根目录：记录目录 _skills/（随 iCloud 同步）。
    var skillsDirectory: URL {
        let dir = HistoryManager.shared.agentStorageRootURL
            .appendingPathComponent("_skills", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Discovery (directory scan)

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    func resetAndReload() {
        loaded = false
        skills = []
        loadIfNeeded()
    }

    func reload() {
        let fm = FileManager.default
        let dir = skillsDirectory
        let useCounts = (AppDefaults.current.dictionary(forKey: Self.useCountsKey) as? [String: Double]) ?? [:]
        let disabled = Set(AppDefaults.current.stringArray(forKey: Self.disabledSkillsKey) ?? [])

        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            skills = []
            return
        }

        var found: [Skill] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let skillMD = entry.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillMD.path),
                  let content = try? String(contentsOf: skillMD, encoding: .utf8) else { continue }
            let parsed = Self.parse(skillMD: content)
            let id = entry.lastPathComponent
            let modified = (try? skillMD.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            var name = parsed.name
            if name == Self.defaultSkillName { name = id }
            found.append(Skill(
                id: id,
                name: name,
                description: parsed.description,
                version: parsed.version,
                isEnabled: !disabled.contains(id),
                updatedAt: modified,
                body: parsed.body,
                useCount: useCounts[id] ?? 0
            ))
        }
        skills = found.sorted { $0.updatedAt > $1.updatedAt }
        logger.info("Loaded \(found.count) skills from \(dir.path)")
    }

    func setEnabled(_ enabled: Bool, for skillId: String) {
        guard let index = skills.firstIndex(where: { $0.id == skillId }) else { return }
        skills[index].isEnabled = enabled
        var disabled = Set(AppDefaults.current.stringArray(forKey: Self.disabledSkillsKey) ?? [])
        if enabled {
            disabled.remove(skillId)
        } else {
            disabled.insert(skillId)
        }
        AppDefaults.current.set(Array(disabled), forKey: Self.disabledSkillsKey)
    }

    // MARK: - YAML Frontmatter Parser (ported as-is from OpenMinis)

    nonisolated static let defaultSkillName = "Untitled Skill"

    nonisolated struct ParsedSkillMD {
        var name: String = SkillStore.defaultSkillName
        var description: String = ""
        var version: String = "1.0.0"
        var body: String = ""
    }

    nonisolated static func parse(skillMD content: String) -> ParsedSkillMD {
        var result = ParsedSkillMD()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        let lines = content.components(separatedBy: "\n")
        let hasOpeningFence = trimmed.hasPrefix("---")

        // Locate the closing `---` fence. When the file starts with `---` we
        // skip the opening line; otherwise we accept a "headless" frontmatter
        // (a leading run of `key: value` lines followed by a `---` separator)
        // so files generated by tools that omit the opening fence still parse.
        var frontmatterEnd: Int?
        let scanStart = hasOpeningFence ? 1 : 0
        if scanStart < lines.count {
            for i in scanStart..<lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                    frontmatterEnd = i
                    break
                }
            }
        }

        guard let endIdx = frontmatterEnd else {
            result.body = content
            return result
        }

        // For the headless variant, only treat the leading block as
        // frontmatter when it actually looks like one — every non-blank line
        // before the fence must start with `key:`, AND at least one of those
        // keys must be a recognized frontmatter field (name / description /
        // version).
        if !hasOpeningFence {
            var sawRecognizedKey = false
            let looksLikeFrontmatter = (scanStart..<endIdx).allSatisfy { idx in
                let line = lines[idx]
                let stripped = line.trimmingCharacters(in: .whitespaces)
                if stripped.isEmpty { return true }
                if line.first?.isWhitespace == true { return true } // continuation of a previous block scalar
                guard let colon = line.firstIndex(of: ":") else { return false }
                let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty,
                      key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
                    return false
                }
                let lowered = key.lowercased()
                if lowered == "name" || lowered == "description" || lowered == "version" {
                    sawRecognizedKey = true
                }
                return true
            }
            guard looksLikeFrontmatter, sawRecognizedKey else {
                result.body = content
                return result
            }
        }

        var i = scanStart
        while i < endIdx {
            let line = lines[i]
            guard let colonIdx = line.firstIndex(of: ":") else { i += 1; continue }
            let key = line[line.startIndex..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)

            // Handle YAML block scalars. Indicator is a leading `|` or `>`,
            // optionally followed by a chomping suffix (`-` strip, `+` keep)
            // and/or a 1-9 indentation digit, e.g. `|`, `|-`, `>-`, `>2`.
            let resolvedValue: String
            let isBlockScalar: Bool = {
                guard let first = value.first, first == "|" || first == ">" else { return false }
                let rest = value.dropFirst()
                return rest.allSatisfy { $0 == "-" || $0 == "+" || $0.isNumber }
            }()
            if isBlockScalar, i + 1 < endIdx {
                let fold = (value.first == ">")
                var blockLines: [String] = []
                var j = i + 1
                while j < endIdx {
                    let next = lines[j]
                    if next.isEmpty || next.first?.isWhitespace == true {
                        blockLines.append(next.trimmingCharacters(in: .whitespaces))
                    } else {
                        break
                    }
                    j += 1
                }
                if fold {
                    resolvedValue = blockLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                } else {
                    resolvedValue = blockLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                i = j
            } else {
                resolvedValue = String(value)
                i += 1
            }

            switch key {
            case "name": result.name = resolvedValue
            case "description": result.description = resolvedValue
            case "version": result.version = resolvedValue
            default: break
            }
        }

        let bodyLines = Array(lines[(endIdx + 1)...])
        result.body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .newlines)

        return result
    }

    // MARK: - Usage Tracking

    /// Record a skill usage when its SKILL.md is read via file_read.
    /// If any skill's count exceeds 1000, all counts are normalized to 0–100.
    func recordSkillUse(_ skillId: String) {
        guard let idx = skills.firstIndex(where: { $0.id == skillId }) else { return }
        skills[idx].useCount += 1

        if skills[idx].useCount > 1000 {
            normalizeAllUseCounts()
        }
        persistUseCounts()
    }

    /// Normalize all skill use_count values to 0–100, preserving relative order.
    private func normalizeAllUseCounts() {
        let maxCount = skills.map(\.useCount).max() ?? 0
        guard maxCount > 0 else { return }
        for i in skills.indices {
            skills[i].useCount = (skills[i].useCount / maxCount) * 100.0
        }
    }

    private func persistUseCounts() {
        var counts: [String: Double] = [:]
        for skill in skills where skill.useCount > 0 {
            counts[skill.id] = skill.useCount
        }
        AppDefaults.current.set(counts, forKey: Self.useCountsKey)
    }

    /// Extract skill ID from a relative path like _skills/<skillId>/SKILL.md.
    /// Only matches SKILL.md reads (the trigger for skill usage).
    func skillIdFromPath(_ path: String) -> String? {
        var normalized = path
        while normalized.hasPrefix("/") { normalized.removeFirst() }
        let prefix = "_skills/"
        guard normalized.hasPrefix(prefix) else { return nil }
        let rest = String(normalized.dropFirst(prefix.count))
        guard let slashIdx = rest.firstIndex(of: "/") else { return nil }
        let candidate = String(rest[rest.startIndex..<slashIdx])
        guard rest.hasSuffix("SKILL.md") else { return nil }
        return skills.contains(where: { $0.id == candidate }) ? candidate : nil
    }

    // MARK: - Prompt Fragment (Claude Code style: metadata only)

    /// Maximum number of skill metadata entries to include in the prompt.
    private static let maxSkillMetadataCount = 20

    /// Build a discovery-only prompt fragment with priority-based disclosure:
    /// 1. Recently modified/created skills within last 7 days (up to 10)
    /// 2. Frequently used skills by normalized use count (fill remaining slots)
    func promptFragment() -> String? {
        loadIfNeeded()
        let enabled = skills.filter { $0.isEnabled }
        guard !enabled.isEmpty else { return nil }

        let totalCount = enabled.count
        let selected: [Skill]
        let hasMore: Bool

        if totalCount <= Self.maxSkillMetadataCount {
            selected = enabled.sorted { $0.updatedAt > $1.updatedAt }
            hasMore = false
        } else {
            var picked: [Skill] = []
            var seen = Set<String>()

            // Priority 1: Recently modified/created (within 7 days), up to 10
            let oneWeekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
            let recent = enabled
                .filter { $0.updatedAt > oneWeekAgo }
                .sorted { $0.updatedAt > $1.updatedAt }
            for s in recent.prefix(10) {
                if seen.insert(s.id).inserted {
                    picked.append(s)
                }
            }

            // Priority 2: By usage frequency (fill remaining slots, most-used first)
            if picked.count < Self.maxSkillMetadataCount {
                let remaining = Self.maxSkillMetadataCount - picked.count
                let byUsage = enabled
                    .filter { !seen.contains($0.id) }
                    .sorted { $0.useCount > $1.useCount }
                for s in byUsage.prefix(remaining) {
                    if seen.insert(s.id).inserted {
                        picked.append(s)
                    }
                }
            }

            selected = picked
            hasMore = totalCount > selected.count
        }

        // Cap each description to avoid bloating the system prompt.
        let maxDescLength = 200

        var xml = "<available_skills>\n"
        for skill in selected {
            let escapedName = skill.name.skillXMLEscaped
            var desc = skill.description
            if desc.count > maxDescLength {
                desc = String(desc.prefix(maxDescLength)) + "…"
            }
            let escapedDesc = desc.skillXMLEscaped
            xml += "  <skill>\n"
            xml += "    <name>\(escapedName)</name>\n"
            xml += "    <description>\(escapedDesc)</description>\n"
            xml += "    <path>_skills/\(skill.id)/SKILL.md</path>\n"
            xml += "  </skill>\n"
        }
        xml += "</available_skills>"

        var fragment = "## Skills\n"
        fragment += "Reusable instruction sets stored at _skills/<name>/SKILL.md inside the records folder. Use file_read to load the SKILL.md body before applying a skill. Skills may reference extra files in the same folder — read them via file_read as needed.\n\n"
        fragment += xml

        if hasMore {
            let omitted = enabled.filter { s in !selected.contains(where: { $0.id == s.id }) }
            let maxUndisclosed = 100 - selected.count
            let undisclosedNames = omitted.prefix(maxUndisclosed).map(\.name).joined(separator: ", ")
            fragment += "\n\n\(omitted.count) more skills not shown above: \(undisclosedNames). Use file_read on _skills/ to list all."
        }

        return fragment
    }
}

// MARK: - XML Escape Helper

nonisolated extension String {
    var skillXMLEscaped: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
