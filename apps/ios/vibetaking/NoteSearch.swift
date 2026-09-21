import Foundation

/// 记录检索语义的唯一出处：记录页、标签筛选栏与 Agent 的 search_notes 共用。
nonisolated enum NoteSearch {
    /// 按空白切分关键词；多个关键词之间是 AND。
    static func keywords(from searchText: String) -> [String] {
        searchText
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// 每个关键词都要命中正文或任一标签。匹配忽略大小写与变音符号（`localizedStandardContains`）；
    /// 全角拉丁字母与半角不互通，要支持时在这里加 `.widthInsensitive` 即可，调用方不用动。
    static func matches(text: String, tags: [String], keywords: [String]) -> Bool {
        keywords.allSatisfy { keyword in
            text.localizedStandardContains(keyword)
                || tags.contains { $0.localizedStandardContains(keyword) }
        }
    }
}

nonisolated enum TagSelectionState: Equatable, Sendable {
    case positive
    case negative
}

nonisolated struct TagSelection: Equatable, Sendable {
    var tag: String
    var state: TagSelectionState

    static let noTagIdentifier = "__NO_TAG__"

    var isNoTagSelection: Bool {
        tag == Self.noTagIdentifier
    }

    /// 一条记录的标签是否满足这个筛选条件；「无标签」项匹配的是没有任何标签的记录。
    func matches(tags: [String]) -> Bool {
        let isPresent = isNoTagSelection ? tags.isEmpty : tags.contains(tag)
        return state == .positive ? isPresent : !isPresent
    }
}

extension Array where Element == TagSelection {
    /// 多个筛选条件之间是 AND；空数组匹配全部记录。
    nonisolated func allMatch(tags: [String]) -> Bool {
        allSatisfy { $0.matches(tags: tags) }
    }
}
