import Foundation

// Compiles the production NoteSearch.swift on its own. The record list, the tag filter bar
// and the assistant's search_notes tool all go through these functions.

@main
struct NoteSearchChecks {
    static func main() {
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            precondition(condition(), name)
            print("PASS: \(name)")
        }

        func matches(_ query: String, text: String, tags: [String] = []) -> Bool {
            NoteSearch.matches(text: text, tags: tags, keywords: NoteSearch.keywords(from: query))
        }

        check("keywords split on any whitespace and drop empties",
              NoteSearch.keywords(from: "  周报 \n 设计\t评审  ") == ["周报", "设计", "评审"])
        check("an empty query has no keywords and matches everything",
              NoteSearch.keywords(from: " \n ").isEmpty && matches("", text: "任意内容"))

        check("every keyword has to match", matches("周报 设计", text: "本周周报：设计评审通过"))
        check("one missing keyword rejects the record", !matches("周报 预算", text: "本周周报：设计评审通过"))
        check("a keyword can match a tag instead of the text", matches("周报 工作", text: "本周周报", tags: ["工作"]))
        check("tags match by substring like the text does", matches("读书", text: "摘抄", tags: ["读书笔记"]))

        // Only the documented guarantees of localizedStandardContains are pinned here.
        // Width folding is not one of them: full-width Latin letters do not match half-width ones.
        check("case is ignored", matches("swiftui", text: "SwiftUI 导航栏"))
        check("diacritics are ignored", matches("cafe", text: "Café 见面"))

        let positive = TagSelection(tag: "工作", state: .positive)
        let negative = TagSelection(tag: "工作", state: .negative)
        let untagged = TagSelection(tag: TagSelection.noTagIdentifier, state: .positive)
        let tagged = TagSelection(tag: TagSelection.noTagIdentifier, state: .negative)

        check("a positive selection requires the tag",
              positive.matches(tags: ["工作", "待办"]) && !positive.matches(tags: ["待办"]))
        check("a negative selection excludes the tag",
              negative.matches(tags: ["待办"]) && !negative.matches(tags: ["工作"]))
        check("tag selections compare whole tags, not substrings", !positive.matches(tags: ["工作日志"]))
        check("the no-tag selection matches records without any tag",
              untagged.matches(tags: []) && !untagged.matches(tags: ["工作"]))
        check("the negated no-tag selection matches records with at least one tag",
              tagged.matches(tags: ["工作"]) && !tagged.matches(tags: []))

        check("selections combine with AND",
              [positive, TagSelection(tag: "待办", state: .negative)].allMatch(tags: ["工作"])
              && ![positive, TagSelection(tag: "待办", state: .negative)].allMatch(tags: ["工作", "待办"]))
        check("no selections match every record", [TagSelection]().allMatch(tags: []))
    }
}
