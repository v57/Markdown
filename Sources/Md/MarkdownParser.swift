import Foundation
import Markdown

public struct ParsedMarkdown {
  public let attributed: NSAttributedString
  public let syntaxRanges: [NSRange]
  public let blocks: [MarkdownParser.Block]
}

/// Markdown → styled attributed string, built on swift-markdown (CommonMark + GFM:
/// tables, task lists, strikethrough). Replaces the hand-rolled line dispatcher,
/// which could loop forever on inputs like a bare "- [ ]" (the old task-list guard
/// matched while the full pattern did not, so `i` never advanced).
///
/// Architecture: `Document(parsing:)` produces the AST; a styler walks it and emits
/// the SOURCE TEXT VERBATIM (never synthesized characters), so the invariant
/// `parsed.attributed.string == markdown` holds structurally. Each source line gets
/// a role from the AST (heading/quote/list/fence/table/rule/code/html/paragraph);
/// per-line marker ranges come from the same total regexes as before (every line
/// classifies — no loops); inline styling ranges come from the AST's source ranges
/// (cmark byte columns converted to UTF-16 offsets).
public enum MarkdownParser {

  public enum Block: Equatable {
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
  public struct ListItem: Equatable {
    public let text: String
    public let level: Int
    public init(text: String, level: Int) {
      self.text = text
      self.level = level
    }
  }
  public struct TaskItem: Equatable {
    public let text: String
    public let checked: Bool
    public let level: Int
    public init(text: String, checked: Bool, level: Int) {
      self.text = text
      self.checked = checked
      self.level = level
    }
  }
  public enum Alignment: Equatable { case left, center, right }

  // MARK: - Entry

  /// Parses markdown into a styled attributed string.
  /// INVARIANT: `attributed.string == markdown` — the output is the source text
  /// verbatim, with attributes layered on. (The live editor re-applies this to the
  /// text storage, so the characters must never change.)
  ///
  /// The style is a platform-neutral `MarkdownStyling`; the resulting attributed
  /// string is rendered with the platform's native font/color/paragraph types via
  /// `MarkdownRenderer`, so callers (macOS `NSTextView`, iOS `UITextView`) consume
  /// a fully-native `NSAttributedString`.
  public static func parse(
    _ markdown: String, style: any MarkdownStyling = MarkdownStyleSpec.standard
  ) -> ParsedMarkdown {
    let out = NSMutableAttributedString()
    var syntaxRanges: [NSRange] = []

    // --- Line table: UTF-16 offsets of every line in the source ---
    let ns = markdown as NSString
    let rawLines = ns.components(separatedBy: "\n")
    let endsWithNewline = markdown.hasSuffix("\n")
    var lines: [LineInfo] = []
    var offset = 0
    for (idx, l) in rawLines.enumerated() {
      // Every line except the last carries its newline; the phantom "" after a
      // trailing "\n" carries none (its newline belongs to the previous line).
      let hasNL: Bool
      if idx < rawLines.count - 1 { hasNL = true } else { hasNL = endsWithNewline && !l.isEmpty }
      lines.append(LineInfo(start: offset, text: l, hasNewline: hasNL))
      offset += (l as NSString).length + (hasNL ? 1 : 0)
    }

    // --- AST (disable smart typography so source ranges stay byte-accurate) ---
    let doc = Document(parsing: markdown, options: .disableSmartOpts)
    let blocks = blocks(from: doc, source: markdown)
    let planner = LinePlanner(doc: doc, lines: lines, style: style)
    let plans = (0..<lines.count).map { planner.plan(for: $0) }

    // --- Attribute helpers (all ranges are UTF-16) ---
    func blockMarkSyntax(_ range: NSRange) {
      syntaxRanges.append(range)
      out.addAttribute(.markdownSyntax, value: true, range: range)
      out.addAttribute(.markdownLineCommand, value: true, range: range)
      out.addAttribute(.foregroundColor, value: style.syntaxColor, range: range)
    }
    func inlineSyntaxMark(_ range: NSRange) {
      syntaxRanges.append(range)
      out.addAttribute(.markdownSyntax, value: true, range: range)
      out.addAttribute(.foregroundColor, value: style.syntaxColor, range: range)
    }
    /// cmark source range (1-based line + byte column) → UTF-16 NSRange.
    func nsRange(_ r: SourceRange?) -> NSRange? {
      guard let r = r else { return nil }
      let l1 = r.lowerBound.line
      let c1 = r.lowerBound.column
      let l2 = r.upperBound.line
      let c2 = r.upperBound.column
      guard l1 >= 1, l2 >= 1, l1 <= lines.count, l2 <= lines.count else { return nil }
      let line1 = lines[l1 - 1]
      let line2 = lines[l2 - 1]
      let start = line1.start + byteToUTF16(c1 - 1, in: line1.text)
      let end = line2.start + byteToUTF16(c2 - 1, in: line2.text)
      guard end >= start else { return nil }
      return NSRange(location: start, length: end - start)
    }
    /// Marks the delimiters of an inline container: its range minus its children's ranges.
    func markGaps(_ node: Markup, in range: NSRange) {
      var cursor = range.location
      for child in node.children {
        guard let cr = child.range, let ncr = nsRange(cr) else { continue }
        if ncr.location > cursor {
          inlineSyntaxMark(NSRange(location: cursor, length: ncr.location - cursor))
        }
        cursor = max(cursor, NSMaxRange(ncr))
      }
      if cursor < NSMaxRange(range) {
        inlineSyntaxMark(NSRange(location: cursor, length: NSMaxRange(range) - cursor))
      }
    }
    func unionChildrenRanges(_ node: Markup) -> NSRange? {
      var result: NSRange? = nil
      for child in node.children {
        guard let cr = child.range, let ncr = nsRange(cr) else { continue }
        result = result.map { NSUnionRange($0, ncr) } ?? ncr
      }
      return result
    }
    /// Inline styling pass over one paragraph/heading subtree.
    func applyInline(_ container: Markup, base: [NSAttributedString.Key: Any]) {
      let bodyFont = (base[.font] as? MarkdownFont) ?? style.bodyFont()
      let bodyColor = (base[.foregroundColor] as? MarkdownColor) ?? style.textColor
      /// Font already applied at the range's start (nested containers combine
      /// traits with the outer container instead of replacing them).
      func currentFont(_ r: NSRange) -> MarkdownFont {
        (out.attribute(.font, at: r.location, effectiveRange: nil) as? MarkdownFont) ?? bodyFont
      }
      /// Builds a font with the requested traits UNIONED onto the current font.
      /// Only ever ADDS traits — a nested strong must keep the outer emphasis's
      /// italic (`***x***` stays bold-italic), so "false" never removes.
      func traitFont(bold: Bool, italic: Bool, at r: NSRange) -> MarkdownFont {
        let base = currentFont(r)
        var traits = base.traits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return base.addingTraits(traits)
      }
      func walk(_ node: Markup) {
        switch node {
        case let s as Strong:
          if let r = nsRange(s.range) {
            out.addAttribute(.font, value: traitFont(bold: true, italic: false, at: r), range: r)
            out.addAttribute(.markdownCommandSpan, value: NSValue(range: r), range: r)
            markGaps(s, in: r)
          }
        case let e as Emphasis:
          if let r = nsRange(e.range) {
            out.addAttribute(.font, value: traitFont(bold: false, italic: true, at: r), range: r)
            out.addAttribute(.markdownCommandSpan, value: NSValue(range: r), range: r)
            markGaps(e, in: r)
          }
        case let t as Text:
          // Escaped characters: cmark resolves "\X" to literal X in one Text
          // node whose source slice differs from its plain text. Mark the
          // backslash as syntax (command symbol), like any other delimiter.
          if let r = nsRange(t.range) {
            let sourceSlice = (markdown as NSString).substring(with: r)
            if sourceSlice != t.plainText {
              let srcNs = sourceSlice as NSString
              let plainNs = t.plainText as NSString
              var si = 0
              var pi = 0
              while si < srcNs.length && pi < plainNs.length {
                if srcNs.character(at: si) == 0x5C,  // backslash
                  si + 1 < srcNs.length, srcNs.character(at: si + 1) == plainNs.character(at: pi)
                {
                  let esc = NSRange(location: r.location + si, length: 2)
                  inlineSyntaxMark(NSRange(location: r.location + si, length: 1))
                  out.addAttribute(.markdownCommandSpan, value: NSValue(range: esc), range: esc)
                  si += 2
                  pi += 1
                } else {
                  si += 1
                  pi += 1
                }
              }
            }
          }
        case let c as InlineCode:
          if let r = nsRange(c.range) {
            // InlineCode is a cmark LEAF: RawMarkup.inlineCode is created
            // with children: [], so unionChildrenRanges returns nil and
            // markGaps would mark the WHOLE span (backticks + content) as
            // syntax — hiding the code text until the caret entered the
            // span. Derive the content range from the source instead:
            // strip the leading/trailing backtick runs, whatever their
            // length (`` `x` ``, `` ``x`` ``, `` ``a`b`` ``).
            let srcNs = (markdown as NSString).substring(with: r) as NSString
            var open = 0
            while open < srcNs.length && srcNs.character(at: open) == 0x60 { open += 1 }
            var close = 0
            while close < srcNs.length - open
              && srcNs.character(at: srcNs.length - 1 - close) == 0x60
            { close += 1 }
            let content = NSRange(location: r.location + open, length: srcNs.length - open - close)
            // Inline code scales with its container: container font size
            // minus 1 (13→12 in body, 26→25 in an h1) so code is readable
            // inside headings. Kind stays .code → monospaced resolution.
            let containerSize = bodyFont.size
            let inlineCodeFont = MarkdownFont(
              kind: .code, size: max(9, containerSize - 1), weight: .regular)
            let inlineCodeAttrs: [NSAttributedString.Key: Any] = [
              .font: inlineCodeFont, .foregroundColor: style.codeTextColor,
              .markdownInlineCode: true,
            ]
            for (k, v) in inlineCodeAttrs { out.addAttribute(k, value: v, range: content) }
            out.addAttribute(.markdownCommandSpan, value: NSValue(range: r), range: r)
            if open > 0 { inlineSyntaxMark(NSRange(location: r.location, length: open)) }
            if close > 0 { inlineSyntaxMark(NSRange(location: NSMaxRange(content), length: close)) }
          }
        case let st as Strikethrough:
          if let r = nsRange(st.range) {
            out.addAttribute(.strikethroughStyle, value: 1, range: r)
            out.addAttribute(.strikethroughColor, value: bodyColor, range: r)
            out.addAttribute(.markdownCommandSpan, value: NSValue(range: r), range: r)
            markGaps(st, in: r)
          }
        case let l as Link:
          if let r = nsRange(l.range) {
            if let content = unionChildrenRanges(l) {
              out.addAttribute(.foregroundColor, value: style.linkColor, range: content)
              out.addAttribute(.underlineStyle, value: 1, range: content)
              if let dest = l.destination, let url = URL(string: dest) {
                out.addAttribute(.link, value: url, range: content)
              }
            }
            out.addAttribute(.markdownCommandSpan, value: NSValue(range: r), range: r)
            markGaps(l, in: r)
          }
        case let img as Image:
          if let r = nsRange(img.range) {
            if let content = unionChildrenRanges(img) {
              let codeAttrs: [NSAttributedString.Key: Any] = [
                .font: style.codeFont(), .foregroundColor: style.codeTextColor,
                .backgroundColor: style.codeBackground,
              ]
              for (k, v) in codeAttrs { out.addAttribute(k, value: v, range: content) }
            }
            if let src = img.source, let url = URL(string: src) {
              out.addAttribute(.markdownImage, value: url, range: r)
            }
            out.addAttribute(.markdownCommandSpan, value: NSValue(range: r), range: r)
            markGaps(img, in: r)
          }
        case let html as InlineHTML:
          if let r = nsRange(html.range) {
            inlineSyntaxMark(r)
            out.addAttribute(.markdownCommandSpan, value: NSValue(range: r), range: r)
          }
        default: break
        }
        for c in node.children { walk(c) }
      }
      walk(container)
    }

    // --- Line-by-line emission (every character emitted exactly once) ---
    // Contiguous .code lines (fence content, including blank lines inside the
    // fence) form one highlighted span with the fence's language.
    var codeSpans: [(language: String, range: NSRange)] = []
    var currentCodeSpan: (language: String, range: NSRange)? = nil
    for i in 0..<lines.count {
      let li = lines[i]
      let plan = plans[i]

      if plan.role == .code {
        if currentCodeSpan == nil {
          let language: String
          if let top = planner.topBlocks.first(where: {
            $0.startLine <= i + 1 && i + 1 <= $0.endLine
          }), let cb = top.node as? CodeBlock {
            language = cb.language ?? ""
          } else {
            language = ""
          }
          currentCodeSpan = (language: language, range: NSRange(location: li.start, length: 0))
        }
        let len = (li.text as NSString).length + (li.hasNewline ? 1 : 0)
        currentCodeSpan!.range.length += len
      } else if currentCodeSpan != nil {
        codeSpans.append(currentCodeSpan!)
        currentCodeSpan = nil
      }

      switch plan.role {
      case .blank:
        if li.hasNewline {
          out.append(
            NSAttributedString(
              string: "\n",
              attributes: [.paragraphStyle: MarkdownRenderer.resolve(style.bodyParagraph())]))
        }
        continue
      default: break
      }

      out.append(NSAttributedString(string: li.text, attributes: plan.base))
      if let mr = plan.markerRange { blockMarkSyntax(mr) }
      if let lmr = plan.listMarkerRange {
        out.addAttribute(.markdownListMarker, value: true, range: lmr)
        // List markers (`-`, `1.`) render systemBlue, overriding the syntax gray.
        out.addAttribute(.foregroundColor, value: style.listMarkerColor, range: lmr)
      }
      if let cr = plan.checkboxRange, let checked = plan.checked {
        out.addAttribute(.markdownCheckbox, value: checked, range: cr)
        out.addAttribute(.markdownSyntax, value: true, range: cr)
      }

      switch plan.role {
      case .rule:
        let r = NSRange(location: li.start, length: (li.text as NSString).length)
        out.addAttribute(.markdownRule, value: true, range: r)
      case .tableHeader, .tableBody:
        // Mark every pipe as block syntax (header + body rows).
        let lineNs = li.text as NSString
        var idx = 0
        while idx < lineNs.length {
          if lineNs.character(at: idx) == 0x7C {  // |
            blockMarkSyntax(NSRange(location: li.start + idx, length: 1))
          }
          idx += 1
        }
      case .code, .fence, .headingUnderline, .tableSeparator: break  // codeBlock attr rides in base; whole-line syntax via markerRange
      default: break
      }

      if li.hasNewline {
        out.append(
          NSAttributedString(
            string: "\n",
            attributes: [.paragraphStyle: MarkdownRenderer.resolve(plan.paragraphStyle)]))
      }

      // Blockquote bar run: line content + its newline, applied AFTER the
      // newline exists (consecutive quote lines form one contiguous bar).
      if case .quote = plan.role {
        let len = (li.text as NSString).length + (li.hasNewline ? 1 : 0)
        out.addAttribute(
          .markdownBlockquote, value: true, range: NSRange(location: li.start, length: len))
      }
    }
    if let c = currentCodeSpan { codeSpans.append(c) }

    // --- Continuous code-block background ---
    // The WHOLE fence content (every line plus its newline and any interior
    // blank line) is ONE .markdownCodeBlock run. The layout manager walks
    // attribute runs, so with per-line markers the separating newlines were
    // plain runs and each line drew its own small rounded rect. Unioning the
    // span yields a single contiguous run → one full-height rounded block.
    for span in codeSpans { out.addAttribute(.markdownCodeBlock, value: true, range: span.range) }

    // --- Code syntax highlighting (Xcode-style categories, GitHub palette) ---
    // Lex each fenced-code span with its language; per-token foreground colors
    // override the uniform code-text color. Unknown languages keep the plain
    // code style (no tokens). Token colors are applied AFTER the base attrs so
    // they win; link tokens also get the underline matching GitHub's code themes.
    for span in codeSpans where !span.language.isEmpty {
      let code = (markdown as NSString).substring(with: span.range)
      // Language display name for the block's corner label (drawn by the
      // layout manager; independent of tokenization — even an all-plain
      // recognized block gets its name).
      if let spec = CodeHighlighter.spec(forLanguage: span.language) {
        out.addAttribute(.markdownCodeLanguage, value: spec.name, range: span.range)
      }
      let tokens = CodeHighlighter.tokens(in: code, language: span.language)
      guard !tokens.isEmpty else { continue }
      let scheme = MarkdownRenderer.currentCodeScheme()
      for t in tokens {
        let r = NSRange(location: span.range.location + t.range.location, length: t.range.length)
        out.addAttribute(
          .foregroundColor, value: MarkdownColor.rgb(scheme.color(for: t.kind)), range: r)
        if t.kind == .link {
          out.addAttribute(.underlineStyle, value: 1, range: r)
          out.addAttribute(.underlineColor, value: MarkdownColor.rgb(scheme.link), range: r)
        }
      }
    }

    // --- Inline pass over every paragraph/heading subtree (once per container) ---
    // Base attrs = the plan of the container's first covered line (list item lines
    // carry the item's level/checkbox styling into the emphasis font base).
    for ci in planner.containers {
      let startIdx = max(0, ci.startLine - 1)
      guard startIdx < plans.count else { continue }
      let base = plans[startIdx].base
      guard !base.isEmpty else { continue }
      applyInline(ci.node, base: base)
    }

    // --- Platform render pass ---
    // The parser stored platform-neutral attribute values (MarkdownColor,
    // MarkdownFont, MarkdownParagraph); resolve them to the native types
    // (NSColor/NSFont/NSParagraphStyle on macOS, UIColor/UIFont on iOS).
    let native = MarkdownRenderer.render(out)
    return ParsedMarkdown(attributed: native, syntaxRanges: syntaxRanges, blocks: blocks)
  }

  // MARK: - AST → Block (test surface; nested lists flattened like the old parser)

  /// Plain text of a block for the test-surface mapping: paragraphs and list items
  /// use their RAW source text (matches the old parser's line-joined semantics,
  /// inline markup preserved); headings use plainText; containers join children.
  private static func blockText(
    _ node: Markup, source: NSString, lineStarts: [Int], lineTexts: [String]
  ) -> String {
    if let p = node as? Paragraph, let r = p.range {
      return sourceText(r, source: source, lineStarts: lineStarts, lineTexts: lineTexts)
    }
    if let h = node as? Heading { return h.plainText }
    if let item = node as? Markdown.ListItem {
      return itemText(item, source: source, lineStarts: lineStarts, lineTexts: lineTexts)
    }
    if let q = node as? BlockQuote {
      return q.children.compactMap {
        ($0 as? Paragraph).map {
          blockText($0, source: source, lineStarts: lineStarts, lineTexts: lineTexts)
        }
      }.joined(separator: "\n")
    }
    if let l = node as? UnorderedList, let items = l.children as? [Markdown.ListItem] {
      return items.map {
        itemText($0, source: source, lineStarts: lineStarts, lineTexts: lineTexts)
      }.joined(separator: "\n")
    }
    if let l = node as? OrderedList, let items = l.children as? [Markdown.ListItem] {
      return items.map {
        itemText($0, source: source, lineStarts: lineStarts, lineTexts: lineTexts)
      }.joined(separator: "\n")
    }
    if let cb = node as? CodeBlock { return cb.code }
    if let t = node as? Table {
      return blockText(t.head, source: source, lineStarts: lineStarts, lineTexts: lineTexts)
    }
    return ""
  }

  /// Source substring of a cmark range (verbatim, UTF-16-accurate).
  private static func sourceText(
    _ r: SourceRange, source: NSString, lineStarts: [Int], lineTexts: [String]
  ) -> String {
    guard let nr = sourceRange(r, lineStarts: lineStarts, lineTexts: lineTexts) else { return "" }
    return source.substring(with: nr)
  }

  private static func sourceRange(_ r: SourceRange, lineStarts: [Int], lineTexts: [String])
    -> NSRange?
  {
    let l1 = r.lowerBound.line
    let c1 = r.lowerBound.column
    let l2 = r.upperBound.line
    let c2 = r.upperBound.column
    guard l1 >= 1, l2 >= 1, l1 <= lineStarts.count, l2 <= lineStarts.count else { return nil }
    let s = lineStarts[l1 - 1] + byteToUTF16(c1 - 1, in: lineTexts[l1 - 1])
    let e = lineStarts[l2 - 1] + byteToUTF16(c2 - 1, in: lineTexts[l2 - 1])
    guard e >= s else { return nil }
    return NSRange(location: s, length: e - s)
  }

  public static func blocks(from doc: Markup, source: String) -> [Block] {
    let ns = source as NSString
    let rawLines = ns.components(separatedBy: "\n")
    let endsWithNewline = source.hasSuffix("\n")
    var lineStarts: [Int] = []
    var lineTexts: [String] = []
    var off = 0
    for (idx, l) in rawLines.enumerated() {
      lineStarts.append(off)
      lineTexts.append(l)
      let hasNL = idx < rawLines.count - 1 || (endsWithNewline && !l.isEmpty)
      off += (l as NSString).length + (hasNL ? 1 : 0)
    }
    func txt(_ node: Markup) -> String {
      blockText(node, source: ns, lineStarts: lineStarts, lineTexts: lineTexts)
    }
    return doc.children.compactMap { child in
      switch child {
      case let h as Heading: return .heading(level: h.level, text: h.plainText)
      case is ThematicBreak: return .rule
      case let q as BlockQuote: return .blockquote(txt(q))
      case let ul as UnorderedList: return listBlock(ul, ordered: false, text: txt)
      case let ol as OrderedList: return listBlock(ol, ordered: true, text: txt)
      case let cb as CodeBlock: return .codeFence(language: cb.language ?? "", code: cb.code)
      case let t as Table: return tableBlock(t)
      case let p as Paragraph: return .paragraph(txt(p))
      default: return .paragraph(txt(child))
      }
    }
  }

  private static func listBlock(_ list: Markup, ordered: Bool, text: (Markup) -> String) -> Block {
    var items: [ListItem] = []
    var tasks: [TaskItem] = []
    var allTask = true
    var lastLevel = 0
    func collect(_ container: Markup) {
      for child in container.children {
        if let item = child as? Markdown.ListItem {
          let level = itemLevel(item)
          lastLevel = level
          let itemTextValue = text(item)
          if let cb = item.checkbox {
            tasks.append(TaskItem(text: itemTextValue, checked: cb == .checked, level: level))
          } else {
            allTask = false
            items.append(ListItem(text: itemTextValue, level: level))
          }
        }
        collect(child)  // recurse through nested lists/paragraphs too
      }
    }
    collect(list)
    if allTask && !tasks.isEmpty { return .taskList(items: tasks) }
    return ordered
      ? .orderedList(items: items, level: lastLevel)
      : .unorderedList(items: items, level: lastLevel)
  }

  private static func itemText(
    _ item: Markdown.ListItem, source: NSString, lineStarts: [Int], lineTexts: [String]
  ) -> String {
    for c in item.children {
      if let p = c as? Paragraph {
        return sourceText(p.range!, source: source, lineStarts: lineStarts, lineTexts: lineTexts)
      }
    }
    return ""
  }

  private static func itemLevel(_ item: Markdown.ListItem) -> Int {
    max(0, ((item.range?.lowerBound.column ?? 1) - 1) / 2)
  }

  private static func tableBlock(_ t: Table) -> Block {
    let header = t.head.children.compactMap { $0 as? Table.Cell }.map { $0.plainText }
    let rows: [[String]] = t.body.children.compactMap { $0 as? Table.Row }.map { row in
      row.children.compactMap { $0 as? Table.Cell }.map { $0.plainText }
    }
    let aligns = t.columnAlignments.map { a -> Alignment in
      switch a {
      case .center: return .center
      case .right: return .right
      default: return .left
      }
    }
    return .table(header: header, rows: rows, alignments: aligns)
  }

  // MARK: - Per-line plan (AST decides the role; regexes give exact marker ranges)

  private struct LineInfo {
    let start: Int  // UTF-16 offset of the line in the document
    let text: String  // line content, no newline
    let hasNewline: Bool
  }

  private struct LinePlan {
    enum Role: Equatable {
      case blank
      case heading(level: Int)
      case headingUnderline
      case quote
      case listItem(ordered: Bool, level: Int, width: CGFloat, checked: Bool?)
      case listFallback
      case fence
      case code
      case tableHeader
      case tableSeparator
      case tableBody
      case rule
      case html
      case paragraph
      case plain
    }
    var role: Role
    var base: [NSAttributedString.Key: Any]
    var paragraphStyle: MarkdownParagraph
    var markerRange: NSRange?
    var listMarkerRange: NSRange?
    var checkboxRange: NSRange?
    var checked: Bool?
  }

  private struct TopBlock {
    let node: Markup
    let startLine: Int  // 1-based, inclusive
    let endLine: Int  // 1-based, inclusive
  }

  private struct ItemInfo {
    let item: Markdown.ListItem
    let startLine: Int
    let endLine: Int
    let checked: Bool?
    let ordered: Bool
  }

  private struct ContainerInfo {
    let node: Markup
    let startLine: Int
    let endLine: Int
    let length: Int  // range length for "innermost" selection
  }

  private struct LinePlanner {
    let lines: [LineInfo]
    let style: any MarkdownStyling
    let topBlocks: [TopBlock]
    let items: [ItemInfo]
    let containers: [ContainerInfo]

    init(doc: Markup, lines: [LineInfo], style: any MarkdownStyling) {
      self.lines = lines
      self.style = style
      topBlocks = doc.children.compactMap { node in
        guard let r = node.range else { return nil }
        return TopBlock(node: node, startLine: r.lowerBound.line, endLine: r.upperBound.line)
      }
      var items: [ItemInfo] = []
      var containers: [ContainerInfo] = []
      func walk(_ node: Markup, ordered: Bool) {
        if let p = node as? Paragraph, let r = p.range {
          containers.append(
            ContainerInfo(
              node: p, startLine: r.lowerBound.line, endLine: r.upperBound.line,
              length: (r.upperBound.line - r.lowerBound.line) * 10000
                + (r.upperBound.column - r.lowerBound.column)))
        } else if let h = node as? Heading, let r = h.range {
          containers.append(
            ContainerInfo(
              node: h, startLine: r.lowerBound.line, endLine: r.upperBound.line,
              length: (r.upperBound.line - r.lowerBound.line) * 10000
                + (r.upperBound.column - r.lowerBound.column)))
        }
        if let item = node as? Markdown.ListItem, let r = item.range {
          let checked: Bool? = item.checkbox.map { $0 == .checked }
          items.append(
            ItemInfo(
              item: item, startLine: r.lowerBound.line, endLine: r.upperBound.line,
              checked: checked, ordered: ordered))
        }
        if let ol = node as? OrderedList {
          for c in ol.children { walk(c, ordered: true) }
        } else if let ul = node as? UnorderedList {
          for c in ul.children { walk(c, ordered: false) }
        } else {
          for c in node.children { walk(c, ordered: ordered) }
        }
      }
      walk(doc, ordered: false)
      self.items = items
      self.containers = containers
    }

    func plan(for index: Int) -> LinePlan {
      let lineNo = index + 1
      let li = lines[index]
      let top = topBlocks.first { $0.startLine <= lineNo && lineNo <= $0.endLine }

      // Code blocks FIRST: blank lines inside a fence stay code.
      if let t = top, let cb = t.node as? CodeBlock {
        let codePara = codeParagraph()
        let codeBase: [NSAttributedString.Key: Any] = [
          .font: style.codeFont(), .foregroundColor: style.codeTextColor, .paragraphStyle: codePara,
        ]
        let firstLineText = lines[t.startLine - 1].text
        let openMatch = match(firstLineText, pattern: "^[ \\t]{0,3}(`{3,}|~{3,})(.*)$")
        let fenceChar: unichar? = openMatch.flatMap { ($0[1] as NSString).character(at: 0) }
        let isFenceLine: Bool
        if index == t.startLine - 1 {
          isFenceLine = openMatch != nil
        } else if index == t.endLine - 1, let fc = fenceChar {
          let c = Character(UnicodeScalar(fc) ?? "`")
          let prefix3 = String(repeating: c, count: 3)
          isFenceLine = li.text.trimmingCharacters(in: .whitespaces).hasPrefix(prefix3)
        } else {
          isFenceLine = false
        }
        if isFenceLine {
          let full = NSRange(location: li.start, length: (li.text as NSString).length)
          return LinePlan(role: .fence, base: codeBase, paragraphStyle: codePara, markerRange: full)
        }
        return LinePlan(role: .code, base: codeBase, paragraphStyle: codePara)
      }

      // Blank line: plain newline (body paragraph style).
      if li.text.trimmingCharacters(in: .whitespaces).isEmpty {
        return LinePlan(role: .blank, base: [:], paragraphStyle: style.bodyParagraph())
      }

      guard let t = top else {
        return LinePlan(role: .plain, base: bodyBase(), paragraphStyle: style.bodyParagraph())
      }

      switch t.node {
      case let h as Heading:
        let para = style.headingParagraph(level: h.level)
        let base: [NSAttributedString.Key: Any] = [
          .font: style.headingFont(level: h.level), .foregroundColor: style.textColor,
          .paragraphStyle: para,
        ]
        // Setext underline: whole line is syntax (ATX marker regex won't match it).
        if match(li.text, pattern: "^\\s*(=+|-+)\\s*$") != nil {
          let full = NSRange(location: li.start, length: (li.text as NSString).length)
          return LinePlan(
            role: .headingUnderline, base: base, paragraphStyle: para, markerRange: full)
        }
        var plan = LinePlan(role: .heading(level: h.level), base: base, paragraphStyle: para)
        if let m = match(li.text, pattern: "^([ \\t]*)(#{1,6})([ \\t]+)(.*)$") {
          let prefixLen =
            (m[1] as NSString).length + (m[2] as NSString).length + (m[3] as NSString).length
          plan.markerRange = NSRange(location: li.start, length: prefixLen)
        }
        return plan

      case is ThematicBreak:
        let full = NSRange(location: li.start, length: (li.text as NSString).length)
        return LinePlan(
          role: .rule, base: bodyBase(), paragraphStyle: style.bodyParagraph(), markerRange: full)

      case is BlockQuote:
        let base: [NSAttributedString.Key: Any] = [
          .font: style.bodyFont(), .foregroundColor: style.quoteTextColor,
          .paragraphStyle: style.quoteParagraph(),
        ]
        var plan = LinePlan(role: .quote, base: base, paragraphStyle: style.quoteParagraph())
        let trimmed = li.text.trimmingCharacters(in: .whitespaces)
        let leadingWs = (li.text as NSString).length - (trimmed as NSString).length
        let markerCount = trimmed.prefix(while: { $0 == ">" }).count
        let rest = trimmed.dropFirst(markerCount)
        let wsLen = rest.prefix(while: { $0 == " " || $0 == "\t" }).count
        let markerLen = leadingWs + markerCount + wsLen
        plan.markerRange = NSRange(location: li.start, length: markerLen)
        return plan

      case is UnorderedList, is OrderedList:
        let ordered = t.node is OrderedList
        if let m = match(li.text, pattern: "^([ \\t]*)([-*+]|\\d+[.)])([ \\t]+)(.*)$") {
          let level = (m[1] as NSString).length / 2
          let item = innermostItem(covering: lineNo)
          let isTask = item?.checked != nil
          let width = style.listMarkerWidth(task: isTask, ordered: ordered)
          let checked = item?.checked
          let para = style.listParagraph(level: level, markerWidth: width)
          let base: [NSAttributedString.Key: Any] = [
            .font: style.bodyFont(),
            .foregroundColor: checked == true ? style.checkedTextColor : style.textColor,
            .paragraphStyle: para,
          ]
          var plan = LinePlan(
            role: .listItem(ordered: ordered, level: level, width: width, checked: checked),
            base: base, paragraphStyle: para)
          if isTask,
            let tm = match(
              li.text, pattern: "^([ \\t]*)([-*+])([ \\t]+)(\\[[ xX]\\])([ \\t]+)(.*)$")
          {
            let m1 = (tm[1] as NSString).length
            let m2 = (tm[2] as NSString).length
            let m3 = (tm[3] as NSString).length
            let markerEnd = li.start + m1 + m2 + m3
            plan.markerRange = NSRange(location: li.start, length: m1 + m2 + m3)
            plan.checkboxRange = NSRange(location: markerEnd, length: (tm[4] as NSString).length)
            plan.checked = checked
          } else {
            plan.markerRange = NSRange(
              location: li.start,
              length: (m[1] as NSString).length + (m[2] as NSString).length
                + (m[3] as NSString).length)
          }
          plan.listMarkerRange = plan.markerRange
          return plan
        }
        // Line inside a list that has no marker (lazy continuation): plain body.
        var plan = LinePlan(
          role: .listFallback, base: bodyBase(), paragraphStyle: style.bodyParagraph())
        return plan

      case is Table:
        let tablePara = tableParagraph()
        let offset = lineNo - t.startLine  // 0 = header row, 1 = separator row
        if offset == 0 {
          let base: [NSAttributedString.Key: Any] = [
            .font: style.emphasisFont(base: style.codeFont(), bold: true, italic: false),
            .foregroundColor: style.textColor, .paragraphStyle: tablePara,
          ]
          return LinePlan(role: .tableHeader, base: base, paragraphStyle: tablePara)
        }
        let base: [NSAttributedString.Key: Any] = [
          .font: style.codeFont(), .foregroundColor: style.textColor, .paragraphStyle: tablePara,
        ]
        if offset == 1 {
          let full = NSRange(location: li.start, length: (li.text as NSString).length)
          return LinePlan(
            role: .tableSeparator, base: base, paragraphStyle: tablePara, markerRange: full)
        }
        return LinePlan(role: .tableBody, base: base, paragraphStyle: tablePara)

      case is Paragraph:
        var plan = LinePlan(
          role: .paragraph, base: bodyBase(), paragraphStyle: style.bodyParagraph())
        return plan

      default:  // HTMLBlock, CustomBlock, block directives: visible plain text
        return LinePlan(role: .html, base: bodyBase(), paragraphStyle: style.bodyParagraph())
      }
    }

    private func bodyBase() -> [NSAttributedString.Key: Any] {
      [
        .font: style.bodyFont(), .foregroundColor: style.textColor,
        .paragraphStyle: style.bodyParagraph(),
      ]
    }

    private func innermostItem(covering lineNo: Int) -> ItemInfo? {
      var best: ItemInfo? = nil
      for it in items where it.startLine <= lineNo && lineNo <= it.endLine {
        if best == nil || (it.endLine - it.startLine) < (best!.endLine - best!.startLine) {
          best = it
        }
      }
      return best
    }

    private func codeParagraph() -> MarkdownParagraph { style.codeParagraph() }

    private func tableParagraph() -> MarkdownParagraph { style.tableParagraph() }
  }

  /// Byte offset (cmark column - 1) within a line → UTF-16 offset. cmark advances
  /// one column per UTF-8 byte; multibyte chars consume their byte count.
  private static func byteToUTF16(_ byteOffset: Int, in lineText: String) -> Int {
    let bytes = Array(lineText.utf8)
    var b = 0
    var u16 = 0
    let target = max(0, min(byteOffset, bytes.count))
    while b < target {
      let byte = bytes[b]
      if byte < 0x80 {
        b += 1
        u16 += 1
      } else if byte >= 0xF0 {
        b += 4
        u16 += 2
      }  // 4-byte → surrogate pair
      else if byte >= 0xE0 {
        b += 3
        u16 += 1
      } else if byte >= 0xC0 {
        b += 2
        u16 += 1
      } else {
        b += 1
      }  // stray continuation byte
    }
    return u16
  }

  // MARK: - Smart-newline continuation for list items / quotes (used by insertNewline)

  /// Given a line (without its trailing newline), returns the marker to prepend to
  /// the next line — ordered-list numbers are incremented, task checkboxes keep
  /// their state — or nil if the line is not a list item. `empty` is true when the
  /// line holds only the marker; the editor then removes the marker on Return
  /// (exits the list) instead of continuing it.
  public struct ListContinuation: Equatable {
    public let marker: String
    public let empty: Bool
  }

  public static func listContinuation(for line: String) -> ListContinuation? {
    // Task item FIRST: "- [x] text" also matches the plain bullet pattern below.
    if let m = match(line, pattern: "^([ \\t]*)([-*+])([ \\t]+)(\\[[ xX]\\])([ \\t]+)(.*)$") {
      let marker = m[1] + m[2] + m[3] + m[4] + m[5]
      return ListContinuation(
        marker: marker, empty: m[6].trimmingCharacters(in: .whitespaces).isEmpty)
    }
    if let m = match(line, pattern: "^([ \\t]*)(\\d+)([.)])([ \\t]+)(.*)$") {
      let n = Int(m[2]) ?? 0
      let marker = m[1] + String(n + 1) + m[3] + m[4]
      return ListContinuation(
        marker: marker, empty: m[5].trimmingCharacters(in: .whitespaces).isEmpty)
    }
    if let m = match(line, pattern: "^([ \\t]*)([-*+])([ \\t]+)(.*)$") {
      let marker = m[1] + m[2] + m[3]
      return ListContinuation(
        marker: marker, empty: m[4].trimmingCharacters(in: .whitespaces).isEmpty)
    }
    return nil
  }

  /// Given a line (without its trailing newline), returns the quote marker to
  /// prepend to the next line when the line is a blockquote ("> "), preserving
  /// any leading indentation. `empty` is true when the line holds only the quote
  /// marker ("> "); the editor then removes the marker on Return (exits the
  /// quote) instead of continuing it.
  public static func quoteContinuation(for line: String) -> ListContinuation? {
    if let m = match(line, pattern: "^([ \\t]*)(>+)([ \\t]*)(.*)$") {
      let marker = m[1] + m[2] + (m[3].isEmpty ? " " : m[3])
      return ListContinuation(
        marker: marker, empty: m[4].trimmingCharacters(in: .whitespaces).isEmpty)
    }
    return nil
  }

  // MARK: - Regex helper

  public static func match(_ s: String, pattern: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
      return nil
    }
    return (0..<m.numberOfRanges).map {
      m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0))
    }
  }
}
