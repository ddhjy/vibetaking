import SwiftUI

/// Native text blocks keep streamed Markdown readable and respond to Dynamic Type.
struct AgentMarkdownText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text)
                        .font(level == 1 ? .title2.bold() : .headline)
                        .accessibilityAddTraits(.isHeader)
                case .paragraph(let text):
                    inline(text).font(.body)
                case .item(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).accessibilityHidden(true)
                        inline(text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.body)
                    .accessibilityElement(children: .combine)
                case .quote(let text):
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: 3)
                        inline(text).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .code(let text):
                    ScrollView(.horizontal) {
                        Text(text)
                            .font(.system(.footnote, design: .monospaced))
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(12)
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }

    private enum Block {
        case heading(Int, String), paragraph(String), item(String, String), quote(String), code(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        func flushParagraph() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                if let codeLines = code {
                    result.append(.code(codeLines.joined(separator: "\n")))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil { code?.append(line); continue }
            if trimmed.isEmpty { flushParagraph(); continue }
            let headingLevel = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(headingLevel), trimmed.dropFirst(headingLevel).hasPrefix(" ") {
                flushParagraph()
                result.append(.heading(headingLevel, String(trimmed.dropFirst(headingLevel + 1))))
            } else if ["- ", "* ", "+ "].contains(where: trimmed.hasPrefix) {
                flushParagraph()
                result.append(.item("•", String(trimmed.dropFirst(2))))
            } else if let range = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flushParagraph()
                result.append(.item(String(trimmed[range]).trimmingCharacters(in: .whitespaces), String(trimmed[range.upperBound...])))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                result.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        if let code { result.append(.code(code.joined(separator: "\n"))) }
        return result
    }
}
