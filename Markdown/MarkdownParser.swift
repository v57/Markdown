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

    // MARK: - Entry

    /// Parses markdown into a styled attributed string.
    /// INVARIANT: `attributed.string == markdown` — the output is the source text verbatim,
    /// with attributes and syntax ranges layered on. (The live editor re-applies this to the
    /// text storage, so the characters must never change.)
    static func parse(_ markdown: String, style: MarkdownStyle = .standard) -> ParsedMarkdown {
        let out = NSMutableAttributedString()
        var syntaxRanges: [NSRange] = []
        var blocks: [Block] = []

        let lines = (markdown as NSString).components(separatedBy: "\n")
        let count = lines.count
        let endsWithNewline = markdown.hasSuffix("\n")

        func endOfLine(_ idx: Int) -> Bool { idx < count - 1 || endsWithNewline }
        func lineLen(_ idx: Int) -> Int { (lines[idx] as NSString).length }

        func emit(_ text: String, attrs: [NSAttributedString.Key: Any]) {
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        func emitNewline(_ idx: Int, para: NSParagraphStyle) {
            if endOfLine(idx) { emit("\n", attrs: [.paragraphStyle: para]) }
        }
        func markSyntax(_ range: NSRange) {
            syntaxRanges.append(range)
            out.addAttribute(.markdownSyntax, value: true, range: range)
            out.addAttribute(.foregroundColor, value: style.syntaxColor, range: range)
        }
        /// Runs the inline pass over an already-emitted character range (same characters, richer attrs).
        func applyInline(_ range: NSRange, base: [NSAttributedString.Key: Any]) {
            guard range.length > 0 else { return }
            let text = out.attributedSubstring(from: range).string
            let styled = inline(text, style: style, base: base)
            out.replaceCharacters(in: range, with: styled.attributed)
            for r in styled.syntax {
                syntaxRanges.append(NSRange(location: range.location + r.location, length: r.length))
            }
        }

        var i = 0
        while i < count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let rawLen = lineLen(i)

            // Blank line: emit its newline only, so the output stays character-identical.
            if trimmed.isEmpty {
                // The split of a trailing "\n" produces a phantom "" line — it carries no characters.
                let isPhantom = (i == count - 1) && endsWithNewline
                if endOfLine(i) && !isPhantom { emit("\n", attrs: [.paragraphStyle: style.bodyParagraph()]) }
                i += 1
                continue
            }

            // ATX heading: ^(\s*)(#{1,6})([ \t]+)(.*)$
            if let m = match(raw, pattern: "^(\\s*)(#{1,6})([ \\t]+)(.*)$") {
                let level = m[2].count
                let prefixLen = m[1].count + m[2].count + m[3].count
                let text = m[4]
                let para = style.headingParagraph(level: level)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: style.headingFont(level: level),
                    .foregroundColor: style.textColor,
                    .paragraphStyle: para,
                ]
                let start = out.length
                emit(raw, attrs: attrs)
                markSyntax(NSRange(location: start, length: prefixLen))
                applyInline(NSRange(location: start + prefixLen, length: rawLen - prefixLen), base: attrs)
                emitNewline(i, para: para)
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }

            // Horizontal rule: ^\s*([-*_])(\s*\1){2,}\s*$ (alone on the line)
            if match(raw, pattern: "^\\s*([-*_])(\\s*\\1){2,}\\s*$") != nil {
                let para = style.bodyParagraph()
                let start = out.length
                emit(raw, attrs: [.paragraphStyle: para, .foregroundColor: style.textColor, .font: style.bodyFont])
                markSyntax(NSRange(location: start, length: rawLen))
                emitNewline(i, para: para)
                blocks.append(.rule)
                i += 1
                continue
            }

            // Blockquote: leading whitespace + one or more '>' + following whitespace
            if trimmed.hasPrefix(">") {
                let para = style.quoteParagraph()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: style.bodyFont,
                    .foregroundColor: style.quoteTextColor,
                    .paragraphStyle: para,
                ]
                var quoteLines: [String] = []
                var markers: [Int] = []
                var j = i
                while j < count {
                    let l = lines[j]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    let leadingWs = (l as NSString).length - (t as NSString).length
                    let markerCount = t.prefix(while: { $0 == ">" }).count
                    let rest = t.dropFirst(markerCount)
                    let wsLen = rest.prefix(while: { $0 == " " || $0 == "\t" }).count
                    let markerLen = leadingWs + markerCount + wsLen
                    markers.append(markerLen)
                    quoteLines.append((l as NSString).substring(from: markerLen))
                    j += 1
                }
                for (k, lineIdx) in (i..<j).enumerated() {
                    let l = lines[lineIdx]
                    let start = out.length
                    emit(l, attrs: attrs)
                    markSyntax(NSRange(location: start, length: markers[k]))
                    applyInline(NSRange(location: start + markers[k], length: lineLen(lineIdx) - markers[k]), base: attrs)
                    emitNewline(lineIdx, para: para)
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                i = j
                continue
            }

            // Paragraph / setext heading — consume until blank line or a line starting a new block.
            // (Fence/list/task/table handlers are added by later tasks and intercept first.)
            var j = i
            var paraLines: [String] = []
            while j < count {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if j > i && isUnderline(lines[j]) { break }        // setext underline ends the paragraph
                if j > i && startsNewBlock(t) { break }
                paraLines.append(lines[j])
                j += 1
            }

            // Setext heading: collected paragraph immediately followed by an underline line
            if j < count, isUnderline(lines[j]) {
                let m = match(lines[j], pattern: "^\\s*(=+|-+)\\s*$")!
                let level = m[1].hasPrefix("=") ? 1 : 2
                let hPara = style.headingParagraph(level: level)
                let hAttrs: [NSAttributedString.Key: Any] = [
                    .font: style.headingFont(level: level),
                    .foregroundColor: style.textColor,
                    .paragraphStyle: hPara,
                ]
                for lineIdx in i..<j {
                    let start = out.length
                    emit(lines[lineIdx], attrs: hAttrs)
                    applyInline(NSRange(location: start, length: lineLen(lineIdx)), base: hAttrs)
                    emitNewline(lineIdx, para: hPara)
                }
                let uStart = out.length
                emit(lines[j], attrs: hAttrs)
                markSyntax(NSRange(location: uStart, length: lineLen(j)))
                emitNewline(j, para: hPara)
                blocks.append(.heading(level: level, text: paraLines.joined(separator: "\n")))
                i = j + 1
                continue
            }

            // Plain paragraph
            let para = style.bodyParagraph()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: style.bodyFont,
                .foregroundColor: style.textColor,
                .paragraphStyle: para,
            ]
            for lineIdx in i..<j {
                let start = out.length
                emit(lines[lineIdx], attrs: attrs)
                applyInline(NSRange(location: start, length: lineLen(lineIdx)), base: attrs)
                emitNewline(lineIdx, para: para)
            }
            blocks.append(.paragraph(paraLines.joined(separator: "\n")))
            i = j
        }

        return ParsedMarkdown(attributed: out, syntaxRanges: syntaxRanges, blocks: blocks)
    }

    // MARK: - Block classification

    static func startsNewBlock(_ line: String) -> Bool {
        line.hasPrefix("#") || line.hasPrefix(">")
            || line.hasPrefix("```") || line.hasPrefix("~~~")
            || match(line, pattern: "^\\s*([-*_])(\\s*\\1){2,}\\s*$") != nil
            || match(line, pattern: "^\\s*[-*+]\\s+") != nil
            || match(line, pattern: "^\\s*\\d+[.)]\\s+") != nil
            || line.contains("|")
    }

    static func isUnderline(_ line: String) -> Bool {
        match(line, pattern: "^\\s*(=+|-+)\\s*$") != nil
    }

    static func match(_ s: String, pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    // MARK: - Inline pass (Task 5 replaces this stub)

    static func inline(_ text: String, style: MarkdownStyle, base: [NSAttributedString.Key: Any])
        -> (attributed: NSAttributedString, syntax: [NSRange]) {
        (NSAttributedString(string: text, attributes: base), [])
    }
}
