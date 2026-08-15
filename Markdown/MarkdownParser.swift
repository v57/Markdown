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

            // Task list: ^(\s*)[-*+][ \t]+\[[ xX]\][ \t]+content
            if match(raw, pattern: "^[ \\t]*[-*+][ \\t]+\\[[ xX]\\]") != nil {
                var items: [TaskItem] = []
                while i < count,
                      let mm = match(lines[i], pattern: "^([ \\t]*)([-*+])([ \\t]+)(\\[[ xX]\\])([ \\t]+)(.*)$") {
                    let level = mm[1].count / 2
                    let marker = mm[1] + mm[2] + mm[3]          // indent + bullet + spaces
                    let checkbox = mm[4]
                    let spacing = mm[5]
                    let text = mm[6]
                    let checked = checkbox.contains("x") || checkbox.contains("X")
                    let para = style.bodyParagraph()
                    let baseAttrs: [NSAttributedString.Key: Any] = [
                        .font: style.bodyFont,
                        .foregroundColor: checked ? style.checkedTextColor : style.textColor,
                        .paragraphStyle: style.listParagraph(level: level, markerWidth: 24),
                    ]
                    let start = out.length
                    emit(lines[i], attrs: baseAttrs)
                    markSyntax(NSRange(location: start, length: marker.count))
                    let cbRange = NSRange(location: start + marker.count, length: checkbox.count)
                    out.addAttribute(.markdownCheckbox, value: checked, range: cbRange)
                    out.addAttribute(.markdownSyntax, value: true, range: cbRange)
                    let contentStart = start + marker.count + checkbox.count + spacing.count
                    let contentLen = lineLen(i) - (marker.count + checkbox.count + spacing.count)
                    applyInline(NSRange(location: contentStart, length: contentLen), base: baseAttrs)
                    emitNewline(i, para: para)
                    items.append(TaskItem(text: text, checked: checked, level: level))
                    i += 1
                }
                blocks.append(.taskList(items: items))
                continue
            }

            // Unordered / ordered list: ^(\s*)([-*+]|\d+[.)])[ \t]+content
            if let m = match(raw, pattern: "^([ \\t]*)([-*+]|\\d+[.)])([ \\t]+)(.*)$") {
                let isOrdered = m[2].first?.isNumber == true
                var items: [ListItem] = []
                var listLevel = 0
                while i < count,
                      let mm = match(lines[i], pattern: "^([ \\t]*)([-*+]|\\d+[.)])([ \\t]+)(.*)$") {
                    let level = mm[1].count / 2
                    let marker = mm[1] + mm[2] + mm[3]
                    let text = mm[4]
                    let width: CGFloat = isOrdered ? 30 : 18
                    let para = style.bodyParagraph()
                    let baseAttrs: [NSAttributedString.Key: Any] = [
                        .font: style.bodyFont,
                        .foregroundColor: style.textColor,
                        .paragraphStyle: style.listParagraph(level: level, markerWidth: width),
                    ]
                    let start = out.length
                    emit(lines[i], attrs: baseAttrs)
                    markSyntax(NSRange(location: start, length: marker.count))
                    applyInline(NSRange(location: start + marker.count, length: lineLen(i) - marker.count), base: baseAttrs)
                    emitNewline(i, para: para)
                    items.append(ListItem(text: text, level: level))
                    listLevel = level
                    i += 1
                }
                blocks.append(isOrdered
                    ? .orderedList(items: items, level: listLevel)
                    : .unorderedList(items: items, level: listLevel))
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

    // MARK: - Inline pass

    /// Styles inline markdown: **bold**, *italic*, ***both***, __…__, _…_ (word-boundary
    /// guarded), ~~strikethrough~~, `code` spans (equal-length backtick runs), \escapes.
    /// Returns the styled text (character-identical to `text`) plus syntax ranges
    /// (relative to the returned string) for the delimiter characters.
    static func inline(_ text: String, style: MarkdownStyle, base: [NSAttributedString.Key: Any])
        -> (attributed: NSAttributedString, syntax: [NSRange]) {
        let ns = text as NSString
        let len = ns.length
        let out = NSMutableAttributedString()
        var syntax: [NSRange] = []

        let bodyFont = base[.font] as? NSFont ?? style.bodyFont
        let bodyColor = base[.foregroundColor] as? NSColor ?? style.textColor

        func appendSyntax(_ s: String) {
            let r = NSRange(location: out.length, length: (s as NSString).length)
            out.append(NSAttributedString(string: s, attributes: style.syntaxAttributes()))
            syntax.append(r)
        }
        func appendPlain(_ s: String) {
            out.append(NSAttributedString(string: s, attributes: base))
        }

        var i = 0
        while i < len {
            let c = ns.character(at: i)

            // Escape: \X → '\' (syntax) + literal X
            if c == 0x5C, i + 1 < len, isPunctuation(ns.character(at: i + 1)) {
                appendSyntax("\\")
                appendPlain(String(UnicodeScalar(ns.character(at: i + 1))!))
                i += 2
                continue
            }

            // Code span: backtick run of length n, closed by an equal-length run
            if c == 0x60 {
                var run = 1
                while i + run < len && ns.character(at: i + run) == 0x60 { run += 1 }
                if let close = findRun(ns, char: 0x60, len: run, from: i + run) {
                    var codeRange = NSRange(location: i + run, length: close - (i + run))
                    // CommonMark: if code starts AND ends with a space, drop one on each side
                    if codeRange.length >= 2,
                       ns.character(at: codeRange.location) == 0x20,
                       ns.character(at: NSMaxRange(codeRange) - 1) == 0x20 {
                        codeRange = NSRange(location: codeRange.location + 1, length: codeRange.length - 2)
                    }
                    appendSyntax(String(repeating: "`", count: run))
                    out.append(NSAttributedString(string: ns.substring(with: codeRange), attributes: style.codeAttributes()))
                    appendSyntax(String(repeating: "`", count: run))
                    i = close + run
                    continue
                }
                appendPlain(String(repeating: "`", count: run))
                i += run
                continue
            }

            // Link / image: handled in a later task; '[' stays plain here.

            // Strikethrough: ~~…~~
            if c == 0x7E, i + 1 < len, ns.character(at: i + 1) == 0x7E {
                if let close = findRun(ns, char: 0x7E, len: 2, from: i + 2) {
                    appendSyntax("~~")
                    let inner = NSMutableAttributedString(string: ns.substring(with: NSRange(location: i + 2, length: close - (i + 2))), attributes: base)
                    inner.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: inner.length))
                    inner.addAttribute(.strikethroughColor, value: bodyColor, range: NSRange(location: 0, length: inner.length))
                    out.append(inner)
                    appendSyntax("~~")
                    i = close + 2
                    continue
                }
                appendPlain("~")
                i += 1
                continue
            }

            // Emphasis delimiters: * and _
            if c == 0x2A || c == 0x5F {
                var run = 1
                while i + run < len && ns.character(at: i + run) == c { run += 1 }
                // '_' does not open intraword (between two alphanumerics)
                let prevAlnum = i > 0 && isAlnum(ns.character(at: i - 1))
                let nextAlnum = i + run < len && isAlnum(ns.character(at: i + run))
                if c == 0x5F, prevAlnum, nextAlnum {
                    appendPlain(ns.substring(with: NSRange(location: i, length: run)))
                    i += run
                    continue
                }
                if let close = findEmphasisClose(ns, char: c, from: i + run) {
                    let closerLen = closeRunLen(ns, close, char: c)
                    let bold = run >= 2 || closerLen >= 2
                    let italic = run % 2 == 1 || closerLen % 2 == 1
                    appendSyntax(ns.substring(with: NSRange(location: i, length: run)))
                    let inner = ns.substring(with: NSRange(location: i + run, length: close - (i + run)))
                    out.append(NSAttributedString(string: inner, attributes: [
                        .font: style.emphasisFont(base: bodyFont, bold: bold, italic: italic),
                        .foregroundColor: bodyColor,
                    ]))
                    appendSyntax(ns.substring(with: NSRange(location: close, length: closerLen)))
                    i = close + closerLen
                    continue
                }
                appendPlain(ns.substring(with: NSRange(location: i, length: run)))
                i += run
                continue
            }

            // Plain character — use composed sequences so emoji (surrogate pairs) survive intact.
            let chRange = ns.rangeOfComposedCharacterSequence(at: i)
            appendPlain(ns.substring(with: chRange))
            i = NSMaxRange(chRange)
        }
        return (out, syntax)
    }

    private static func isPunctuation(_ c: unichar) -> Bool {
        guard let s = UnicodeScalar(c) else { return false }
        return "\\`*_{}[]()#+-.!>~|".unicodeScalars.contains(s)
    }
    private static func isAlnum(_ c: unichar) -> Bool {
        guard let s = UnicodeScalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(s)
    }
    /// Finds a run of exactly `len` copies of `char`, starting the search at `start`.
    private static func findRun(_ ns: NSString, char: unichar, len: Int, from start: Int) -> Int? {
        var j = start
        while j < ns.length {
            if ns.character(at: j) == char {
                var k = 0
                while j + k < ns.length && ns.character(at: j + k) == char { k += 1 }
                if k == len { return j }
                j += k
            } else {
                j += 1
            }
        }
        return nil
    }
    private static func closeRunLen(_ ns: NSString, _ pos: Int, char: unichar) -> Int {
        var k = 0
        while pos + k < ns.length && ns.character(at: pos + k) == char { k += 1 }
        return k
    }
    /// Finds the first same-char run that can close emphasis (skipping intraword '_').
    private static func findEmphasisClose(_ ns: NSString, char: unichar, from start: Int) -> Int? {
        var j = start
        while j < ns.length {
            if ns.character(at: j) == char {
                if char == 0x5F, j > 0, j + 1 < ns.length,
                   isAlnum(ns.character(at: j - 1)), isAlnum(ns.character(at: j + 1)) {
                    j += 1
                    continue
                }
                return j
            }
            j += 1
        }
        return nil
    }
}
