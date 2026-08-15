import AppKit

struct ParsedMarkdown {
    let attributed: NSAttributedString
    let syntaxRanges: [NSRange]
    let blocks: [MarkdownParser.Block]
}

enum MarkdownParser {

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case blockquote(String)
        case rule
        case unorderedList(items: [ListItem], level: Int)
        case orderedList(items: [ListItem], level: Int)
        case taskList(items: [TaskItem])
        case codeFence(language: String, code: String)
        case table(header: [String], rows: [[String]], alignments: [Alignment])
    }
    struct ListItem: Equatable { let text: String; let level: Int }
    struct TaskItem: Equatable { let text: String; let checked: Bool; let level: Int }
    enum Alignment: Equatable { case left, center, right }

    // Stub — real block pass lands in Task 4.
    static func parse(_ markdown: String, style: MarkdownStyle = .standard) -> ParsedMarkdown {
        ParsedMarkdown(attributed: NSAttributedString(string: markdown, attributes: style.typingAttributes),
                       syntaxRanges: [],
                       blocks: [])
    }
}
