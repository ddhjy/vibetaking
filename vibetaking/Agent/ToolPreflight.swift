// Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis) —
// Agent/Chat/AIChatViewModel+ToolPreflight.swift
// Copyright (C) OpenMinis contributors. Licensed under GPL-3.0; see LICENSE.
// Modifications for vibetaking: extracted from the AIChatViewModel extension
// into a standalone namespace enum.

import Foundation

// MARK: - Tool Preflight + JSON Repair

nonisolated enum ToolPreflight {

    /// Outcome of running the JSON-repair strategies on a tool call's args.
    /// `args` is the (possibly mutated) dict to use downstream; `repairs`
    /// is a list of human-readable strategy tags (empty when nothing was
    /// changed) suitable for warning logs.
    struct ToolArgsRepairOutcome {
        let args: [String: Any]
        let repairs: [String]
    }

    /// Attempt to salvage a malformed / incomplete tool call's args BEFORE
    /// the preflight validator rejects it. Three strategies, applied in
    /// order, each gated on actually being needed:
    ///
    /// 1. **Truncation repair** — if `args` is empty but the raw stream
    ///    tail is a non-empty string, retry JSON parsing with up to a
    ///    handful of `}` / `]` / `"` closures appended. Models occasionally
    ///    cut off mid-stream and leave a parseable object behind a single
    ///    missing brace.
    /// 2. **Type coercion** — for each required field whose value is
    ///    present but not a String, convert so downstream parsers (which
    ///    uniformly expect strings) see a usable value.
    /// 3. **Fuzzy field-name match** — for each missing required field,
    ///    look for a sibling key whose Levenshtein distance is ≤ 1 and
    ///    rename it. Catches one-off typos like `comand` → `command`.
    static func repairToolArgs(
        name: String,
        args: [String: Any],
        rawTail: String?,
        tools: [AgentToolDefinition]
    ) -> ToolArgsRepairOutcome {
        guard let toolDef = tools.first(where: { $0.name == name }) else {
            return ToolArgsRepairOutcome(args: args, repairs: [])
        }
        var working = args
        var repairs: [String] = []

        // Strategy 1: truncation repair. Only fires when the dict is empty
        // but the raw stream tail looks like a JSON object that just got cut.
        if working.isEmpty, let tail = rawTail?.trimmingCharacters(in: .whitespacesAndNewlines), !tail.isEmpty {
            let suffixes: [String] = [
                "", "\"", "\"}", "\"]}", "}", "}}", "]}", "]}}", "]", "]]"
            ]
            for suffix in suffixes {
                let candidate = tail + suffix
                guard let data = candidate.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                working = parsed
                repairs.append("truncation+\(suffix.isEmpty ? "noop" : suffix)")
                break
            }
        }

        // Strategy 2: type coercion on required fields. Restricted to
        // PRIMITIVE scalars; Array / Dict are NOT coerced — a Swift debug
        // rendering would break far worse than rejecting.
        for field in toolDef.required {
            guard let raw = working[field] else { continue }
            if raw is String { continue }
            if raw is NSNull {
                working.removeValue(forKey: field)
                repairs.append("null-strip:\(field)")
                continue
            }
            if raw is [Any] || raw is [String: Any] { continue }
            let coerced: String?
            if let n = raw as? NSNumber {
                // CFBoolean and Bool NSNumbers share NSNumber type — disambiguate
                // via CFGetTypeID so bools render "true"/"false", not "1"/"0".
                if CFGetTypeID(n) == CFBooleanGetTypeID() {
                    coerced = n.boolValue ? "true" : "false"
                } else {
                    coerced = n.stringValue
                }
            } else if let b = raw as? Bool {
                coerced = b ? "true" : "false"
            } else {
                let desc = String(describing: raw)
                coerced = desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : desc
            }
            if let coerced, !coerced.isEmpty {
                working[field] = coerced
                repairs.append("type-coerce:\(field)")
            }
        }

        // Strategy 3: fuzzy field-name match for missing required fields.
        // Only consider sibling keys that are themselves NOT already a
        // recognized schema field. Sibling key iteration is .sorted() to
        // make the match deterministic.
        let schemaFields = Set(toolDef.parameters.keys)
        for field in toolDef.required {
            if working[field] != nil { continue }
            var bestKey: String? = nil
            for key in working.keys.sorted() {
                if schemaFields.contains(key) { continue }
                if levenshteinAtMostOne(key, field) {
                    bestKey = key
                    break
                }
            }
            if let bestKey {
                working[field] = working.removeValue(forKey: bestKey)
                repairs.append("fuzzy:\(bestKey)->\(field)")
            }
        }

        return ToolArgsRepairOutcome(args: working, repairs: repairs)
    }

    /// `true` iff Levenshtein edit distance between `a` and `b` is ≤ 1
    /// (case-insensitive).
    private static func levenshteinAtMostOne(_ a: String, _ b: String) -> Bool {
        let aLower = a.lowercased()
        let bLower = b.lowercased()
        if aLower == bLower { return true }
        let ac = Array(aLower)
        let bc = Array(bLower)
        let diff = ac.count - bc.count
        if diff > 1 || diff < -1 { return false }
        if ac.count == bc.count {
            // One substitution allowed.
            var mismatches = 0
            for i in 0..<ac.count where ac[i] != bc[i] {
                mismatches += 1
                if mismatches > 1 { return false }
            }
            return mismatches == 1
        }
        // One insertion / deletion allowed.
        let (longer, shorter) = ac.count > bc.count ? (ac, bc) : (bc, ac)
        var i = 0, j = 0
        var skipped = false
        while i < longer.count && j < shorter.count {
            if longer[i] == shorter[j] {
                i += 1; j += 1
            } else if !skipped {
                i += 1; skipped = true
            } else {
                return false
            }
        }
        return true
    }

    /// Fields that stay in each tool's `required` list (so the schema keeps
    /// nudging the model to always emit them) but must NOT block the call
    /// when absent. They carry no execution semantics.
    static let preflightNonBlockingFields: Set<String> = ["tool_title"]

    /// (tool name → field names) where an EMPTY STRING is a semantically valid
    /// value and must not be treated as "missing". The canonical case is
    /// `file_edit.new_string`: "use empty string to delete old_string".
    static let preflightEmptyStringAllowedFields: [String: Set<String>] = [
        "file_edit": ["new_string"],
    ]

    static func preflightEmptyStringAllowed(tool: String, field: String) -> Bool {
        preflightEmptyStringAllowedFields[tool]?.contains(field) ?? false
    }

    /// Reject tool calls that have empty args or are missing required fields
    /// BEFORE the tool helper runs. Returns nil when the call is well-formed,
    /// or a human-readable reason string when it should be blocked.
    static func preflightValidateToolCall(name: String,
                                          args: [String: Any],
                                          tools: [AgentToolDefinition]) -> String? {
        // Unknown tool names go through to the dispatch default branch which
        // already returns an "Unknown tool" error to the model.
        guard let toolDef = tools.first(where: { $0.name == name }) else {
            return nil
        }
        let enforced = toolDef.required.filter { !Self.preflightNonBlockingFields.contains($0) }
        if args.isEmpty && !enforced.isEmpty {
            return "Tool '\(name)' was called with empty arguments {} but requires: \(enforced.joined(separator: ", "))."
        }
        var missing: [String] = []
        for field in enforced {
            // Absent — or present as JSON null (NSNull): both are genuinely
            // missing values.
            guard let raw = args[field], !(raw is NSNull) else {
                missing.append(field)
                continue
            }
            // String fields: only reject the truly-empty literal "" (and even
            // that is legal for whitelisted (tool, field) pairs). Whitespace-
            // only payloads are valid — e.g. replacing a block with "\n".
            if let s = raw as? String, s.isEmpty,
               !Self.preflightEmptyStringAllowed(tool: name, field: field) {
                missing.append(field)
            }
        }
        if !missing.isEmpty {
            return "Tool '\(name)' is missing required parameter(s): \(missing.joined(separator: ", "))."
        }
        return nil
    }
}
