import Foundation

// MARK: - Shell-style tokenizer

/// 把一条命令行参数串分词（支持双引号/单引号与反斜杠转义）。
nonisolated func tokenizeCommandLine(_ input: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var inSingle = false
    var inDouble = false
    var escaped = false
    var hasContent = false

    for ch in input {
        if escaped {
            current.append(ch)
            escaped = false
            continue
        }
        switch ch {
        case "\\" where !inSingle:
            escaped = true
            hasContent = true
        case "'" where !inDouble:
            inSingle.toggle()
            hasContent = true
        case "\"" where !inSingle:
            inDouble.toggle()
            hasContent = true
        case " ", "\t", "\n":
            if inSingle || inDouble {
                current.append(ch)
            } else if hasContent || !current.isEmpty {
                tokens.append(current)
                current = ""
                hasContent = false
            }
        default:
            current.append(ch)
            hasContent = true
        }
    }
    if hasContent || !current.isEmpty {
        tokens.append(current)
    }
    return tokens
}

