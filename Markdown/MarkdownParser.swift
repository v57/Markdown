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
                out.addAttribute(.markdownRule, value: true, range: NSRange(location: start, length: rawLen))
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

            // Fenced code block: ^[ \t]{0,3}(`{3,}|~{3,})(.*)$
            if let m = match(raw, pattern: "^[ \\t]{0,3}(`{3,}|~{3,})(.*)$") {
                let fence = m[1]
                let lang = m[2].trimmingCharacters(in: .whitespaces)
                let closePrefix = String(fence.prefix(3))
                var closingFenceLine: Int? = nil
                var j = i + 1
                while j < count {
                    if lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(closePrefix) {
                        closingFenceLine = j
                        break
                    }
                    j += 1
                }
                let codePara = NSMutableParagraphStyle()
                codePara.lineSpacing = 0
                codePara.paragraphSpacing = 0
                let codeAttrs: [NSAttributedString.Key: Any] = [
                    .font: style.codeFont,
                    .foregroundColor: style.codeTextColor,
                    .markdownCodeBlock: true,
                    .paragraphStyle: codePara,
                ]
                // Opening fence line (marker + language): syntax-marked
                let start = out.length
                emit(lines[i], attrs: codeAttrs)
                markSyntax(NSRange(location: start, length: lineLen(i)))
                emitNewline(i, para: codePara)
                // Code content — verbatim, no inline interpretation
                var codeLines: [String] = []
                let contentEnd = closingFenceLine ?? count
                for lineIdx2 in (i + 1)..<contentEnd {
                    codeLines.append(lines[lineIdx2])
                    emit(lines[lineIdx2], attrs: codeAttrs)
                    emitNewline(lineIdx2, para: codePara)
                }
                // Closing fence: syntax-marked
                if let cf = closingFenceLine {
                    let s = out.length
                    emit(lines[cf], attrs: codeAttrs)
                    markSyntax(NSRange(location: s, length: lineLen(cf)))
                    emitNewline(cf, para: codePara)
                }
                blocks.append(.codeFence(language: lang, code: codeLines.joined(separator: "\n")))
                i = (closingFenceLine ?? count) + (closingFenceLine == nil ? 0 : 1)
                continue
            }

            // Table: current line has '|' and the next line is a GFM separator row.
            // Rendering note: NSTextTable would replace the structural '|' characters with
            // layout, breaking the verbatim-source invariant — so tables render as monospace
            // blocks with pipes as syntax (hidden when inactive, tertiary when active).
            if trimmed.contains("|"), i + 1 < count,
               match(lines[i + 1], pattern: "^\\s*\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)*\\|?\\s*$") != nil,
               lines[i + 1].contains("-") {
                let headerCells = splitCells(trimmed)
                let alignments = splitCells(lines[i + 1]).map { cell -> Alignment in
                    let c = cell.trimmingCharacters(in: .whitespaces)
                    if c.hasPrefix(":") && c.hasSuffix(":") { return .center }
                    if c.hasSuffix(":") { return .right }
                    return .left
                }
                var rows: [[String]] = []
                var j = i + 2
                while j < count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    guard t.contains("|"), !t.isEmpty else { break }
                    rows.append(splitCells(t))
                    j += 1
                }
                let tablePara = NSMutableParagraphStyle()
                tablePara.lineSpacing = 0
                tablePara.paragraphSpacing = 0
                let cellAttrs: [NSAttributedString.Key: Any] = [
                    .font: style.codeFont, .foregroundColor: style.textColor, .paragraphStyle: tablePara,
                ]
                let headerAttrs: [NSAttributedString.Key: Any] = [
                    .font: style.emphasisFont(base: style.codeFont, bold: true, italic: false),
                    .foregroundColor: style.textColor, .paragraphStyle: tablePara,
                ]
                func markPipes(_ line: String, at start: Int) {
                    let ns = line as NSString
                    var idx = 0
                    while idx < ns.length {
                        if ns.character(at: idx) == 0x7C { // |
                            markSyntax(NSRange(location: start + idx, length: 1))
                        }
                        idx += 1
                    }
                }
                // Header row: bold, pipes syntax
                let hs = out.length
                emit(raw, attrs: headerAttrs)
                markPipes(raw, at: hs)
                emitNewline(i, para: tablePara)
                // Separator row: entirely syntax
                let ss = out.length
                emit(lines[i + 1], attrs: cellAttrs)
                markSyntax(NSRange(location: ss, length: lineLen(i + 1)))
                emitNewline(i + 1, para: tablePara)
                // Body rows: pipes syntax
                for (k, rowLine) in lines[(i + 2)..<j].enumerated() {
                    let rs = out.length
                    emit(rowLine, attrs: cellAttrs)
                    markPipes(rowLine, at: rs)
                    emitNewline(i + 2 + k, para: tablePara)
                }
                blocks.append(.table(header: headerCells, rows: rows, alignments: alignments))
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

    /// Splits a GFM table row into cells ("| a | b |" -> ["a", "b"]).
    static func splitCells(_ line: String) -> [String] {
        let t = line.trimmingCharacters(in: .whitespaces)
        let inner = t.hasPrefix("|") ? String(t.dropFirst()) : t
        let trimmedEnd = inner.hasSuffix("|") ? String(inner.dropLast()) : inner
        return trimmedEnd.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
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

            // Image: ![alt](url) — handled at the '!' so the whole construct is consumed
            if c == 0x21, i + 1 < len, ns.character(at: i + 1) == 0x5B,
               let (textRange, urlRange, _) = tryLink(ns, at: i + 1) {
                let urlString = ns.substring(with: urlRange)
                appendSyntax("![")
                out.append(NSAttributedString(string: ns.substring(with: textRange), attributes: style.codeAttributes())) // alt placeholder
                let wholeStart = out.length - (2 + textRange.length)
                appendSyntax("](" + urlString + ")")
                if let url = URL(string: urlString) {
                    out.addAttribute(.markdownImage, value: url,
                                     range: NSRange(location: wholeStart, length: out.length - wholeStart))
                }
                i = NSMaxRange(urlRange) + 1   // past ')'
                continue
            }

            // Link: [text](url)
            if c == 0x5B {
                if let (textRange, urlRange, _) = tryLink(ns, at: i) {
                    let urlString = ns.substring(with: urlRange)
                    appendSyntax("[")
                    let styledText = NSMutableAttributedString(string: ns.substring(with: textRange), attributes: base)
                    styledText.addAttribute(.foregroundColor, value: style.linkColor, range: NSRange(location: 0, length: styledText.length))
                    styledText.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: styledText.length))
                    if let url = URL(string: urlString) {
                        styledText.addAttribute(.link, value: url, range: NSRange(location: 0, length: styledText.length))
                    }
                    out.append(styledText)
                    appendSyntax("](" + urlString + ")")
                    i = NSMaxRange(urlRange) + 1   // past ')'
                    continue
                }
                // Not a link — '[' stays plain
                let chRange = ns.rangeOfComposedCharacterSequence(at: i)
                appendPlain(ns.substring(with: chRange))
                i = NSMaxRange(chRange)
                continue
            }

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

    /// At a '[' position, returns (textRange, urlRange, isImage) for [t](u) / ![t](u), or nil.
    /// textRange is the link text / alt text; urlRange is the URL between '(' and ')'.
    private static func tryLink(_ ns: NSString, at i: Int) -> (NSRange, NSRange, Bool)? {
        let isImage = i > 0 && ns.character(at: i - 1) == 0x21 // '!'
        let textStart = i + 1                                 // always past the '['
        var j = textStart
        while j < ns.length && ns.character(at: j) != 0x5D {   // ]
            if ns.character(at: j) == 0x0A { return nil }
            j += 1
        }
        guard j < ns.length, j + 1 < ns.length, ns.character(at: j + 1) == 0x28 else { return nil } // (
        var k = j + 2
        while k < ns.length && ns.character(at: k) != 0x29 {    // )
            if ns.character(at: k) == 0x0A { return nil }
            k += 1
        }
        guard k < ns.length else { return nil }
        return (NSRange(location: textStart, length: j - textStart),
                NSRange(location: j + 2, length: k - (j + 2)), isImage)
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
