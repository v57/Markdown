import Foundation

/// A lexical token: a UTF-16 range (relative to the scanned code string) and its
/// Xcode-style syntax kind.
struct CodeToken {
    let range: NSRange
    let kind: SyntaxKind
}

/// Shared regex-scanning engine behind every language in LanguageCatalog.
///
/// Line-based with cross-line state for block comments (nesting, doc comments →
/// prose) and multiline strings. Tolerant of incomplete input — the user is
/// typing: unterminated constructs color to end of line and resume cleanly.
/// All ranges are UTF-16 (NSString coordinates), matching the parser's document
/// offsets (emoji and other surrogate-pair characters never split).
struct CodeScanner {
    private struct Line {
        let start: Int          // UTF-16 offset of the line in the code string
        let text: String
        let hasNewline: Bool
    }

    private enum Pending {
        case blockComment(open: String, close: String, doc: Bool, depth: Int)
        case multilineString(close: String, escape: Character?)
    }

    private let source: NSString
    private let spec: LanguageSpec
    private let lines: [Line]
    private var tokens: [CodeToken] = []
    private var pending: Pending? = nil

    // Precompiled anchored patterns.
    private let declPattern: NSRegularExpression?
    private let numberPattern: NSRegularExpression
    private let identifierPattern: NSRegularExpression
    private let memberPattern: NSRegularExpression
    private let shellVarPattern: NSRegularExpression
    private let urlPattern: NSRegularExpression
    private let hashWordPattern: NSRegularExpression?
    private let atWordPattern: NSRegularExpression?
    private let rustAttrPattern: NSRegularExpression?
    private let directivePattern: NSRegularExpression?

    init(code: String, spec: LanguageSpec) {
        self.spec = spec
        source = code as NSString

        // Line table (UTF-16 offsets), same convention as MarkdownParser.
        let raw = source.components(separatedBy: "\n")
        let endsWithNL = code.hasSuffix("\n")
        var ls: [Line] = []
        var off = 0
        for (i, l) in raw.enumerated() {
            let hasNL = i < raw.count - 1 || (endsWithNL && !l.isEmpty)
            ls.append(Line(start: off, text: l, hasNewline: hasNL))
            off += (l as NSString).length + (hasNL ? 1 : 0)
        }
        lines = ls

        func re(_ p: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: p) }
        let ident = "[A-Za-z_$][A-Za-z0-9_$]*"
        if !spec.declKeywords.isEmpty {
            let alt = spec.declKeywords.keys.sorted { $0.count > $1.count }.joined(separator: "|")
            declPattern = re("\\b(" + alt + ")\\s+(" + ident + ")")
        } else {
            declPattern = nil
        }
        numberPattern = re("(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*(?:\\.[0-9_]+)?(?:[eE][+-]?[0-9]+)?)[uUlLfF]*")!
        identifierPattern = re(ident)!
        memberPattern = re("\\." + ident)!
        shellVarPattern = re("(?:\\$" + ident + "|\\$\\{" + ident + "\\})")!
        urlPattern = re("(?:https?|ftp)://[^\\s<>\"'()]+")!
        hashWordPattern = (spec.hashDirectives && !spec.hashDirectivesAnchored) ? re("#" + ident) : nil
        atWordPattern = spec.atWords ? re("@" + ident) : nil
        rustAttrPattern = spec.rustAttributes ? re("#!?\\[[^\\]]*\\]") : nil
        directivePattern = (spec.hashDirectives && spec.hashDirectivesAnchored) ? re("[ \\t]*#[ \\t]*([A-Za-z_][A-Za-z0-9_]*)") : nil
    }

    mutating func scan() -> [CodeToken] {
        for line in lines { scanLine(line) }
        return tokens
    }

    // MARK: - Line scanning

    private mutating func scanLine(_ line: Line) {
        let text = line.text as NSString
        var pos = 0

        // Cross-line state first: the rest of the line belongs to a comment or
        // string unless it closes here.
        if let p = pending {
            switch p {
            case .blockComment(let open, let close, let doc, let depth):
                if let closeIdx = findBlockClose(in: text, from: 0, open: open, close: close, depth: depth) {
                    emitContent(range: NSRange(location: line.start, length: closeIdx), doc: doc)
                    emit(.comment, NSRange(location: line.start + closeIdx, length: (close as NSString).length))
                    pending = nil
                    pos = closeIdx + (close as NSString).length
                } else {
                    emitContent(range: NSRange(location: line.start, length: text.length), doc: doc)
                    return
                }
            case .multilineString(let close, let escape):
                if let closeIdx = findStringClose(in: text, from: 0, close: close, escape: escape) {
                    emit(.string, NSRange(location: line.start, length: closeIdx + (close as NSString).length))
                    pending = nil
                    pos = closeIdx + (close as NSString).length
                } else {
                    emit(.string, NSRange(location: line.start, length: text.length))
                    return
                }
            }
        }

        // Anchored preprocessor directive must start the line (C family).
        if let d = directivePattern, pos == 0,
           let m = matchAnchor(text, at: 0, pattern: d) {
            emit(.preprocessor, NSRange(location: line.start, length: m.range.length))
            pos = m.range.length
            // #include <header.h>: the header name is a string (GitHub colors it
            // so); consumes up to the '>' (or the line end while typing).
            if spec.headerStrings, m.groups.count > 1, m.groups[1].length > 0 {
                let word = text.substring(with: m.groups[1]).lowercased()
                if ["include", "import", "include_next"].contains(word) {
                    var i = pos
                    while i < text.length && (text.character(at: i) == 0x20 || text.character(at: i) == 0x09) { i += 1 }
                    if i < text.length && text.character(at: i) == 0x3C {   // '<'
                        i += 1
                        let contentStart = i
                        while i < text.length && text.character(at: i) != 0x3E { i += 1 }   // '>'
                        emit(.string, NSRange(location: line.start + contentStart, length: i - contentStart))
                        pos = i < text.length ? i + 1 : text.length
                    }
                }
            }
        }

        while pos < text.length {
            // 1. Block comment open (before line comments: Lua --[[ ]])
            if let bc = spec.blockComments.first(where: { prefix(text, $0.open, at: pos) }) {
                let openLen = (bc.open as NSString).length
                // Doc comment: "/*" whose third char is '*' but fourth is not '/'
                // ("/**/  */" ambiguity: "/**/" is an empty non-doc comment).
                let isDoc = bc.open == "/*" && pos + 2 < text.length && text.character(at: pos + 2) == 0x2A
                    && (pos + 3 >= text.length || text.character(at: pos + 3) != 0x2F)
                let markerLen = (isDoc ? 3 : openLen)
                emit(.comment, NSRange(location: line.start + pos, length: markerLen))
                let contentStart = pos + markerLen
                if let closeIdx = findBlockClose(in: text, from: contentStart, open: bc.open, close: bc.close, depth: 1) {
                    emitContent(range: NSRange(location: line.start + contentStart, length: closeIdx - contentStart), doc: isDoc)
                    emit(.comment, NSRange(location: line.start + closeIdx, length: (bc.close as NSString).length))
                    pos = closeIdx + (bc.close as NSString).length
                } else {
                    emitContent(range: NSRange(location: line.start + contentStart, length: text.length - contentStart), doc: isDoc)
                    pending = .blockComment(open: bc.open, close: bc.close, doc: isDoc, depth: 1)
                    return
                }
                continue
            }

            // 2. Line comment (longest marker first) — consumes the rest of the line.
            if let marker = spec.lineComments.sorted(by: { ($0 as NSString).length > ($1 as NSString).length })
                .first(where: { prefix(text, $0, at: pos) }) {
                let markerLen = (marker as NSString).length
                // Doc line comment: "///" or "//!" (Swift/Rust/Kotlin conventions).
                let isDoc = marker == "//" && pos + markerLen < text.length &&
                    (text.character(at: pos + markerLen) == 0x2F || text.character(at: pos + markerLen) == 0x21)
                let docLen = isDoc ? markerLen + 1 : markerLen
                let start = line.start + pos
                if isDoc {
                    emit(.comment, NSRange(location: start, length: docLen))
                    emitContent(range: NSRange(location: start + docLen, length: text.length - pos - docLen), doc: true)
                } else {
                    emitContent(range: NSRange(location: start, length: text.length - pos), doc: false)
                }
                return
            }

            // 3. Strings (longest open first: """ before ", @" before ").
            if let delim = spec.strings.sorted(by: { ($0.open as NSString).length > ($1.open as NSString).length })
                .first(where: { prefix(text, $0.open, at: pos) }) {
                let openLen = (delim.open as NSString).length
                let closeLen = (delim.close as NSString).length
                if let closeIdx = findStringClose(in: text, from: pos + openLen, close: delim.close, escape: delim.escape) {
                    emit(.string, NSRange(location: line.start + pos, length: closeIdx + closeLen - pos))
                    pos = closeIdx + closeLen
                } else if delim.multiline {
                    emit(.string, NSRange(location: line.start + pos, length: text.length - pos))
                    pending = .multilineString(close: delim.close, escape: delim.escape)
                    return
                } else {
                    emit(.string, NSRange(location: line.start + pos, length: text.length - pos))
                    return
                }
                continue
            }

            // 4. Character literals (C family): 'x', '\n', '\'' — but NOT Rust lifetimes
            // or Scala symbol literals ('a, 'foo): those are `'` + identifier +
            // non-quote, colored plain. A `'x'` char literal closes after exactly
            // one character; escapes ('\n') scan to their closing quote.
            if let ch = spec.charLiteral, text.character(at: pos) == charUTF16(ch) {
                let next: unichar? = pos + 1 < text.length ? text.character(at: pos + 1) : nil
                let nextIsIdent = next.map { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F } ?? false
                let closesShortly = pos + 2 < text.length && text.character(at: pos + 2) == 0x27   // 'x'
                if nextIsIdent && !closesShortly {
                    pos += 1   // lifetime / symbol literal: plain
                } else if let closeIdx = findStringClose(in: text, from: pos + 1, close: "'", escape: "\\") {
                    emit(.string, NSRange(location: line.start + pos, length: closeIdx + 1 - pos))
                    pos = closeIdx + 1
                } else {
                    pos += 1
                }
                continue
            }

            // 5. Preprocessor: Rust attributes, Swift hash words, @-words.
            if let r = rustAttrPattern, let m = matchAnchor(text, at: pos, pattern: r) {
                emit(.preprocessor, NSRange(location: line.start + pos, length: m.range.length))
                pos = NSMaxRange(m.range)
                continue
            }
            if let h = hashWordPattern, let m = matchAnchor(text, at: pos, pattern: h) {
                emit(.preprocessor, NSRange(location: line.start + pos, length: m.range.length))
                pos = NSMaxRange(m.range)
                continue
            }
            if let a = atWordPattern, let m = matchAnchor(text, at: pos, pattern: a) {
                emit(.preprocessor, NSRange(location: line.start + pos, length: m.range.length))
                pos = NSMaxRange(m.range)
                continue
            }

            // 6. URLs → links (also extracted inside comments by emitContent).
            if let m = matchAnchor(text, at: pos, pattern: urlPattern) {
                emit(.link, NSRange(location: line.start + pos, length: m.range.length))
                pos = NSMaxRange(m.range)
                continue
            }

            // 7. Numbers.
            if let m = matchAnchor(text, at: pos, pattern: numberPattern) {
                emit(.number, NSRange(location: line.start + pos, length: m.range.length))
                pos = NSMaxRange(m.range)
                continue
            }

            // 8. Declarations: "class Foo" / "func bar" → keyword + declared name.
            if let d = declPattern, let m = matchAnchor(text, at: pos, pattern: d) {
                let kwRange = m.groups[1], nameRange = m.groups[2]
                if kwRange.length > 0 {
                    emit(.keyword, NSRange(location: line.start + kwRange.location, length: kwRange.length))
                }
                if nameRange.length > 0 {
                    let kw = text.substring(with: kwRange)
                    let kind = spec.declKeywords[kw] ?? .plainText
                    if kind != .plainText {
                        emit(kind, NSRange(location: line.start + nameRange.location, length: nameRange.length))
                    }
                }
                pos = NSMaxRange(m.range)
                continue
            }

            // 9. Member accesses: obj.name → otherMember.
            if spec.memberAccess, let m = matchAnchor(text, at: pos, pattern: memberPattern) {
                emit(.otherMember, NSRange(location: line.start + pos, length: m.range.length))
                pos = NSMaxRange(m.range)
                continue
            }

            // 10. Shell variables: $name / ${name} → otherMember.
            if spec.shellVars, let m = matchAnchor(text, at: pos, pattern: shellVarPattern) {
                emit(.otherMember, NSRange(location: line.start + pos, length: m.range.length))
                pos = NSMaxRange(m.range)
                continue
            }

            // 11. Identifiers → keyword, capitalized type reference, or plain.
            if let m = matchAnchor(text, at: pos, pattern: identifierPattern) {
                let word = text.substring(with: m.range)
                let key = spec.keywordsCaseInsensitive ? word.uppercased() : word
                if spec.keywords.contains(key) {
                    emit(.keyword, NSRange(location: line.start + pos, length: m.range.length))
                } else if spec.capitalizedIsType,
                          let first = word.unicodeScalars.first,
                          CharacterSet.uppercaseLetters.contains(first) {
                    emit(.otherType, NSRange(location: line.start + pos, length: m.range.length))
                }
                pos = NSMaxRange(m.range)
                continue
            }

            // 12. Anything else: plain character.
            pos += 1
        }
    }

    // MARK: - Helpers

    private func prefix(_ text: NSString, _ s: String, at pos: Int) -> Bool {
        let len = (s as NSString).length
        guard pos >= 0, pos + len <= text.length else { return false }
        return text.substring(with: NSRange(location: pos, length: len)) == s
    }

    /// Anchored regex match at `pos` (NSRegularExpression .anchored option is
    /// available on macOS 10.13+; this SDK's NSRegularExpression supports it).
    /// Returns the match range plus group ranges.
    private func matchAnchor(_ text: NSString, at pos: Int, pattern: NSRegularExpression) -> (range: NSRange, groups: [NSRange])? {
        guard pos < text.length else { return nil }
        let full = NSRange(location: pos, length: text.length - pos)
        guard let m = pattern.firstMatch(in: text as String, options: .anchored, range: full) else { return nil }
        let groups = (0..<m.numberOfRanges).map { m.range(at: $0) }
        return (m.range, groups)
    }

    /// Index of the close marker's first character, or nil when the block stays
    /// open past this line. Honors nesting when the spec nests (Swift).
    private func findBlockClose(in text: NSString, from start: Int, open: String, close: String, depth startingDepth: Int) -> Int? {
        let openLen = (open as NSString).length
        let closeLen = (close as NSString).length
        var depth = startingDepth
        var i = start
        while i < text.length {
            if spec.nestedBlockComments, prefix(text, open, at: i) {
                depth += 1
                i += openLen
                continue
            }
            if prefix(text, close, at: i) {
                if depth > 1 { depth -= 1; i += closeLen; continue }
                return i
            }
            i += 1
        }
        return nil
    }

    /// Index of the close marker's first character, or nil. `escape` (e.g. "\")
    /// skips the following character (nil = raw string, no escapes).
    private func findStringClose(in text: NSString, from start: Int, close: String, escape: Character?) -> Int? {
        let esc = escape.map { charUTF16($0) }
        var i = start
        while i < text.length {
            if let e = esc, text.character(at: i) == e {
                i += 2
                continue
            }
            if prefix(text, close, at: i) { return i }
            i += 1
        }
        return nil
    }

    /// Emits the comment token over `range` (prose for doc comments), then link
    /// tokens for URLs inside it. Later tokens win when applied in order, so the
    /// link subranges override the comment/prose color.
    private mutating func emitContent(range: NSRange, doc: Bool) {
        guard range.length > 0 else { return }
        emit(doc ? .prose : .comment, range)
        let content = source.substring(with: range)
        urlPattern.enumerateMatches(in: content, options: [], range: NSRange(location: 0, length: (content as NSString).length)) { m, _, _ in
            guard let m, m.range.length > 0 else { return }
            tokens.append(CodeToken(range: NSRange(location: range.location + m.range.location, length: m.range.length), kind: .link))
        }
    }

    private mutating func emit(_ kind: SyntaxKind, _ range: NSRange) {
        guard range.length > 0 else { return }
        tokens.append(CodeToken(range: range, kind: kind))
    }

    private func charUTF16(_ c: Character) -> unichar {
        Array(String(c).utf16)[0]
    }
}