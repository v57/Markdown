// TextKit (AppKit, UIKit): the editors' attributed text. Elsewhere the portable editor renders swift-markdown's tree.
#if canImport(AppKit) || canImport(UIKit)
import CodeHighlighting
import Foundation
import Markdown

public struct ParsedMarkdown {
  public let attributed: NSAttributedString
  public let syntaxRanges: [NSRange]
  public let blocks: [MarkdownParser.Block]
  /// Natural grid width (pt, excluding the line-fragment padding) of every table the
  /// grid pass measured, by ordinal. An editor compares these with its container width
  /// to know when a resize changes which tables fit (see `maxTableWidth`).
  public var tableWidths: [Int: CGFloat] = [:]
}

extension MarkdownParser {

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
  ///
  /// `maxTableWidth` is the width available to a table (the container width minus its
  /// line-fragment padding). A grid table wider than that cannot be drawn — its rows
  /// would wrap and tear the grid apart — so it renders as RAW markdown instead (pipes
  /// visible, no grid). `nil` (the default) never falls back.
  ///
  /// `resolver` turns the document's relative image sources and link destinations into
  /// absolute URLs (a note resolves against its folder, a GitHub README against its
  /// repository). The default resolves absolute destinations only.
  public static func parse(
    _ markdown: String,
    style: any MarkdownStyling = MarkdownStyleSpec.standard,
    sourceModeTables: Set<Int> = [],
    maxTableWidth: CGFloat? = nil,
    resolver: MarkdownURLResolver = .absoluteOnly
  ) -> ParsedMarkdown {
    let first = parse(
      markdown, style: style, sourceModeTables: sourceModeTables, rawTables: [], resolver: resolver)
    guard let maxTableWidth else { return first }
    let overflowing = Set(first.tableWidths.filter { $0.value > maxTableWidth + 0.5 }.keys)
    guard !overflowing.isEmpty else { return first }
    var fallback = parse(
      markdown, style: style, sourceModeTables: sourceModeTables, rawTables: overflowing,
      resolver: resolver)
    fallback.tableWidths = first.tableWidths
    return fallback
  }

  /// The tables (by ordinal) whose natural grid width does not fit `availableWidth`.
  public static func overflowingTables(_ widths: [Int: CGFloat], availableWidth: CGFloat?)
    -> Set<Int>
  {
    guard let availableWidth else { return [] }
    return Set(widths.filter { $0.value > availableWidth + 0.5 }.keys)
  }

  private static func parse(
    _ markdown: String, style: any MarkdownStyling, sourceModeTables: Set<Int>,
    rawTables: Set<Int>, resolver: MarkdownURLResolver
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

    // --- Table modes ---
    // Tables are numbered in document order. Every table renders as a GRID (aligned
    // columns, hidden pipes, drawn separators) unless its ordinal is pinned to source
    // mode, where it renders as its raw markdown text (today's look) so it can be edited.
    var tables: [(table: Table, top: TopBlock, ordinal: Int, isGrid: Bool)] = []
    var gridTableLines: Set<Int> = []
    var rawTableLines: Set<Int> = []
    var tableOrdinal = 0
    for child in doc.children {
      guard let table = child as? Table, let r = table.range else { continue }
      // A table the user is editing stays in source mode even when it is too wide; a
      // too-wide table that is not being edited renders raw (see `maxTableWidth`).
      let isSource = sourceModeTables.contains(tableOrdinal)
      let isRaw = !isSource && rawTables.contains(tableOrdinal)
      let isGrid = !isSource && !isRaw
      if isGrid { gridTableLines.insert(r.lowerBound.line) }
      if isRaw { rawTableLines.insert(r.lowerBound.line) }
      tables.append(
        (
          table: table,
          top: TopBlock(node: table, startLine: r.lowerBound.line, endLine: r.upperBound.line),
          ordinal: tableOrdinal, isGrid: isGrid
        ))
      tableOrdinal += 1
    }

    let planner = LinePlanner(
      doc: doc, lines: lines, style: style, gridTables: gridTableLines, rawTables: rawTableLines)
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
    /// Marks a table row's pipe characters. GRID mode: hidden syntax with no line
    /// command, so the caret never reveals them (the grid draws the separators; the
    /// table pass also gives each pipe a nulling kern, because SF Mono has no
    /// zero-width glyph to substitute). SOURCE mode: a line command like any other
    /// block marker, i.e. today's behavior.
    func markTablePipes(of li: LineInfo, grid: Bool, raw: Bool) {
      let lineNs = li.text as NSString
      var idx = 0
      while idx < lineNs.length {
        if lineNs.character(at: idx) == 0x7C {  // |
          let r = NSRange(location: li.start + idx, length: 1)
          if raw {
            // RAW (too wide for a grid): the pipes are the only column separators left,
            // so they stay visible — syntax-colored, never hidden.
            out.addAttribute(.foregroundColor, value: style.syntaxColor, range: r)
            idx += 1
            continue
          }
          syntaxRanges.append(r)
          out.addAttribute(.markdownSyntax, value: true, range: r)
          if !grid { out.addAttribute(.markdownLineCommand, value: true, range: r) }
          out.addAttribute(.foregroundColor, value: style.syntaxColor, range: r)
        }
        idx += 1
      }
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
    /// HTML tags found so far, in document order: inline HTML from the inline pass, then
    /// the HTML blocks' tags (`inBlock`: revealed per LINE, like other block syntax).
    var htmlTags: [(tag: MarkdownHTML.Tag, inBlock: Bool)] = []
    /// Hides an entity's source and has its first character draw `codeUnit` instead.
    func markEntity(_ r: NSRange, codeUnit: UInt16, lineCommand: Bool) {
      if lineCommand { blockMarkSyntax(r) } else { inlineSyntaxMark(r) }
      out.addAttribute(.markdownCommandSpan, value: NSValue(range: r), range: r)
      out.addAttribute(
        .markdownGlyphSubstitute, value: NSNumber(value: codeUnit),
        range: NSRange(location: r.location, length: 1))
      // The substitute glyph reads as text: undo the syntax gray on that one character.
      out.addAttribute(
        .foregroundColor, value: style.textColor, range: NSRange(location: r.location, length: 1))
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
      func walk(_ node: Markup, inLink: Bool = false) {
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
            if !inLink {
              // Bare URLs (GFM "extended autolinks"): swift-markdown does not enable
              // cmark's autolink extension, so `https://…` / `www.…` in plain text
              // would otherwise render as ordinary, unclickable text.
              for (range, url) in bareURLs(in: sourceSlice) {
                let linkRange = NSRange(location: r.location + range.location, length: range.length)
                out.addAttribute(.foregroundColor, value: style.linkColor, range: linkRange)
                out.addAttribute(.link, value: url, range: linkRange)
              }
            }
            if sourceSlice != t.plainText {
              let srcNs = sourceSlice as NSString
              let plainNs = t.plainText as NSString
              // Entities: cmark decoded `&copy;` to © in the plain text. Each is hidden
              // syntax whose first character draws the decoded glyph (see
              // `.markdownGlyphSubstitute`), and the escape walk below steps over it.
              var entityAt: [Int: Int] = [:]
              for e in MarkdownHTML.entities(in: sourceSlice) {
                markEntity(
                  NSRange(location: r.location + e.range.location, length: e.range.length),
                  codeUnit: e.codeUnit, lineCommand: false)
                entityAt[e.range.location] = e.range.length
              }
              var si = 0
              var pi = 0
              while si < srcNs.length && pi < plainNs.length {
                if let length = entityAt[si] {
                  si += length
                  pi += 1
                } else if srcNs.character(at: si) == 0x5C,  // backslash
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
              if let dest = l.destination, let url = resolver.resolveLink(dest) {
                out.addAttribute(.link, value: url, range: content)
              }
            }
            out.addAttribute(.markdownCommandSpan, value: NSValue(range: r), range: r)
            markGaps(l, in: r)
          }
        case let img as Image:
          if let r = nsRange(img.range) {
            // Alt text shows until the image loads (or when it cannot): secondary color
            // in the CONTAINER's font. Not the code font — SF Mono has no zero-width
            // glyph, so a hidden alt run would leave a space-wide gap per character
            // beside the drawn image.
            if let content = unionChildrenRanges(img) {
              out.addAttribute(.foregroundColor, value: style.quoteTextColor, range: content)
            }
            if let src = img.source, let url = resolver.resolveImage(src) {
              out.addAttribute(.markdownImage, value: url, range: r)
              out.addAttribute(
                .markdownImageSpec,
                value: MarkdownImageSpec(url: url, range: r, alt: img.plainText), range: r)
            }
            out.addAttribute(.markdownCommandSpan, value: NSValue(range: r), range: r)
            markGaps(img, in: r)
          }
        case let html as InlineHTML:
          if let r = nsRange(html.range) {
            inlineSyntaxMark(r)
            out.addAttribute(.markdownCommandSpan, value: NSValue(range: r), range: r)
            // Rendered by the HTML pass (images, links, styling) with the block tags.
            htmlTags.append(
              contentsOf: MarkdownHTML.tags(
                in: (markdown as NSString).substring(with: r), base: r.location
              ).map { (tag: $0, inBlock: false) })
          }
        default: break
        }
        let childInLink = inLink || node is Link || node is Image
        for c in node.children { walk(c, inLink: childInLink) }
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
      if let hr = plan.hiddenRange { inlineSyntaxMark(hr) }
      if let lmr = plan.listMarkerRange {
        out.addAttribute(.markdownListMarker, value: true, range: lmr)
        // List markers (`-`, `1.`) render systemRed, overriding the syntax gray.
        out.addAttribute(.foregroundColor, value: style.listMarkerColor, range: lmr)
      }
      if let br = plan.bulletRange {
        // Plain unordered marker character ("-", "*", "+") renders as "•" via
        // glyph substitution — source keeps the literal "-", so the verbatim
        // invariant holds. The marker stays listMarkerColor/always-visible.
        out.addAttribute(.markdownBullet, value: true, range: br)
      }
      if let cr = plan.checkboxRange, let checked = plan.checked {
        out.addAttribute(.markdownCheckbox, value: checked, range: cr)
        out.addAttribute(.markdownSyntax, value: true, range: cr)
      }

      switch plan.role {
      case .rule:
        let r = NSRange(location: li.start, length: (li.text as NSString).length)
        out.addAttribute(.markdownRule, value: true, range: r)
      case .tableHeader, .tableBody, .tableSeparator:
        markTablePipes(of: li, grid: plan.tableGrid, raw: plan.tableRaw)
      case .code, .fence, .headingUnderline: break  // codeBlock attr rides in base; whole-line syntax via markerRange
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
      // The value is the nesting depth (`> > x` = 2): one bar is drawn per level.
      if case .quote = plan.role {
        let len = (li.text as NSString).length + (li.hasNewline ? 1 : 0)
        out.addAttribute(
          .markdownBlockquote, value: NSNumber(value: plan.quoteDepth),
          range: NSRange(location: li.start, length: len))
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

    // --- Full-block background (content + ``` fence lines) ---
    // The background FILL should cover the fence lines too. The enclosing
    // CodeBlock's AST range spans the opening ``` line through the closing ```
    // line (line 1..4 of "```swift\nlet a\nlet b\n```"). For each content span,
    // compute the full block range and attach it as `.markdownCodeBlockFill` over
    // the WHOLE block (content + fences), so the fill draws over every line.
    // `.markdownCodeBlock` stays content-only — it drives chrome anchor / language
    // label / Copy, which must NOT include the fence lines.
    for span in codeSpans {
      guard
        let fill = fullCodeRange(
          for: span.range, lines: lines, topBlocks: planner.topBlocks)
      else { continue }
      out.addAttribute(.markdownCodeBlockFill, value: NSValue(range: fill), range: fill)
    }

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

    // --- HTML (blocks + inline) and link reference definitions ---
    applyHTML(
      tags: &htmlTags, plans: plans, lines: lines, out: out, markdown: markdown, style: style,
      resolver: resolver, blockMarkSyntax: blockMarkSyntax, inlineSyntaxMark: inlineSyntaxMark,
      markEntity: markEntity)

    // --- Platform render pass ---
    // The parser stored platform-neutral attribute values (MarkdownColor,
    // MarkdownFont, MarkdownParagraph); resolve them to the native types
    // (NSColor/NSFont/NSParagraphStyle on macOS, UIColor/UIFont/NSParagraphStyle
    // on iOS). The table grid pass runs AFTER this: it needs the real fonts to
    // measure cell widths and to cancel each pipe's advance.
    let native = NSMutableAttributedString(attributedString: MarkdownRenderer.render(out))
    let tableWidths = applyTableGrid(
      tables: tables, native: native, ns: ns, lines: lines, style: style)
    applyHangingIndents(plans: plans, lines: lines, native: native)

    return ParsedMarkdown(
      attributed: native, syntaxRanges: syntaxRanges, blocks: blocks, tableWidths: tableWidths)
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
    var bulletRange: NSRange?
    var checkboxRange: NSRange?
    var checked: Bool?
    /// True when this line belongs to a table rendered as a GRID (pipes hidden, columns
    /// aligned, separators drawn).
    var tableGrid: Bool = false
    /// A range to mark as hidden syntax WITHOUT a line command: revealed by nothing, not
    /// even the caret. Used for a grid-mode table's `|---|` separator row, whose visible
    /// stand-in is a drawn rule, and for a nested list line's leading indentation (the
    /// paragraph indent replaces it).
    var hiddenRange: NSRange?
    /// True when this line belongs to a table too wide for a grid, rendered as RAW
    /// markdown (pipes always visible).
    var tableRaw: Bool = false
    /// Blockquote nesting depth (`> > x` = 2).
    var quoteDepth: Int = 0
    /// Hanging-indent inputs for a list line, resolved after rendering (they need real
    /// font metrics) by `applyHangingIndents`.
    var hang: Hang?
  }

  /// A list line's indentation, measured from what is actually drawn.
  ///
  /// The first line starts at `parentItemLine`'s content x (so a nested item's marker
  /// sits under its parent's text), else at `baseIndent`. Wrapped lines hang at the
  /// first line's start plus the drawn width of `prefix` — the marker and the space after
  /// it — so they line up with the item's text, whatever the marker ("•", "10.", a
  /// checkbox) and font.
  private struct Hang {
    var baseIndent: CGFloat
    /// 1-based line this line starts an item on (nil for a continuation line).
    var itemLine: Int?
    /// 1-based start line of the item whose content column this line hangs from.
    var parentItemLine: Int?
    /// The drawn marker characters before the content (empty for a continuation line).
    var prefix: NSRange
    /// The marker character drawn as "•" (glyph substitution).
    var bulletIndex: Int?
    /// The checkbox's middle character, drawn as an EN SPACE slot.
    var checkboxMiddle: Int?
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
    /// Start line of the enclosing list item (nil for a top-level item).
    let parentStartLine: Int?
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
    /// Start lines (1-based) of the tables rendered as a GRID.
    let gridTables: Set<Int>
    /// Start lines (1-based) of the tables too wide for a grid, rendered RAW.
    let rawTables: Set<Int>

    init(
      doc: Markup, lines: [LineInfo], style: any MarkdownStyling, gridTables: Set<Int> = [],
      rawTables: Set<Int> = []
    ) {
      self.lines = lines
      self.style = style
      self.gridTables = gridTables
      self.rawTables = rawTables
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
        } else if let cell = node as? Table.Cell, let r = cell.range {
          // A table cell is an INLINE container (BasicInlineContainer) — without this
          // branch the paragraph/heading rules never matched it and inline markup inside
          // a cell (bold/italic/code/links) rendered as its literal delimiters.
          containers.append(
            ContainerInfo(
              node: cell, startLine: r.lowerBound.line, endLine: r.upperBound.line,
              length: (r.upperBound.line - r.lowerBound.line) * 10000
                + (r.upperBound.column - r.lowerBound.column)))
        }
        if let item = node as? Markdown.ListItem, let r = item.range {
          let checked: Bool? = item.checkbox.map { $0 == .checked }
          let parent = (item.parent?.parent as? Markdown.ListItem)?.range?.lowerBound.line
          items.append(
            ItemInfo(
              item: item, startLine: r.lowerBound.line, endLine: r.upperBound.line,
              checked: checked, ordered: ordered, parentStartLine: parent))
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
        let isSetext = t.endLine > t.startLine
        // Setext underline: whole line is syntax (ATX marker regex won't match it).
        // Hidden, it would still be a full heading-sized line plus the heading's
        // spacing on both sides — a large gap under the heading. So the underline gets
        // a tiny font, no spacing before, and carries the heading's spacing AFTER
        // (which the text line above drops).
        // (cmark ends the heading's range at column 1 of the line AFTER the underline,
        // so `endLine` cannot identify the underline; any later line matching it does.)
        if isSetext, lineNo > t.startLine,
          match(li.text, pattern: "^\\s*(=+|-+)\\s*$") != nil
        {
          let full = NSRange(location: li.start, length: (li.text as NSString).length)
          var underlinePara = para
          underlinePara.paragraphSpacingBefore = 0
          let underlineBase: [NSAttributedString.Key: Any] = [
            .font: MarkdownFont(kind: .body, size: style.metrics.setextUnderlineFontSize),
            .foregroundColor: style.textColor, .paragraphStyle: underlinePara,
          ]
          return LinePlan(
            role: .headingUnderline, base: underlineBase, paragraphStyle: underlinePara,
            markerRange: full)
        }
        var textPara = para
        if isSetext {
          textPara.paragraphSpacing = 0
          if lineNo > t.startLine { textPara.paragraphSpacingBefore = 0 }
        }
        let textBase: [NSAttributedString.Key: Any] = [
          .font: style.headingFont(level: h.level), .foregroundColor: style.textColor,
          .paragraphStyle: textPara,
        ]
        var plan = LinePlan(
          role: .heading(level: h.level), base: textBase, paragraphStyle: textPara)
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
        // Every leading `>` (with its optional space) is marker syntax, so a nested
        // `> > x` hides both levels; the depth drives the indent and one bar per level.
        let quoteMatch = match(li.text, pattern: "^([ \\t]*(?:>[ \\t]?)+)")
        let markerLen = quoteMatch.map { ($0[1] as NSString).length } ?? 0
        let depth = max(1, quoteMatch.map { $0[1].filter { $0 == ">" }.count } ?? 1)
        var para = style.quoteParagraph()
        para.firstLineHeadIndent *= CGFloat(depth)
        para.headIndent *= CGFloat(depth)
        let base: [NSAttributedString.Key: Any] = [
          .font: style.bodyFont(), .foregroundColor: style.quoteTextColor, .paragraphStyle: para,
        ]
        var plan = LinePlan(role: .quote, base: base, paragraphStyle: para)
        plan.quoteDepth = depth
        if markerLen > 0 { plan.markerRange = NSRange(location: li.start, length: markerLen) }
        // A list item inside the quote (`> - item`, `> 1. item`, `> - [ ] task`) gets the
        // same marker rendering as a top-level item.
        let rest = (li.text as NSString).substring(from: markerLen)
        applyListMarker(
          to: &plan, text: rest, start: li.start + markerLen, isTask: nil,
          baseIndent: para.firstLineHeadIndent, itemLine: nil, parentItemLine: nil)
        return plan

      case is UnorderedList, is OrderedList:
        let ordered = t.node is OrderedList
        if let m = match(li.text, pattern: "^([ \\t]*)([-*+]|\\d+[.)])([ \\t]+)(.*)$") {
          let level = (m[1] as NSString).length / 2
          let item = innermostItem(covering: lineNo)
          let isTask = item?.checked != nil
          let width = style.listMarkerWidth(task: isTask, ordered: ordered)
          let checked = item?.checked
          // Indents here are placeholders: `applyHangingIndents` replaces them with ones
          // measured from the drawn marker once real fonts exist.
          let para = style.listParagraph(level: 0, markerWidth: width)
          let base: [NSAttributedString.Key: Any] = [
            .font: style.bodyFont(),
            .foregroundColor: checked == true ? style.checkedTextColor : style.textColor,
            .paragraphStyle: para,
          ]
          var plan = LinePlan(
            role: .listItem(ordered: ordered, level: level, width: width, checked: checked),
            base: base, paragraphStyle: para)
          // Leading indentation is ALWAYS hidden: the nesting indent comes from the
          // paragraph style (aligned under the parent item's text). Drawing the literal
          // spaces too indented nested items twice.
          let leading = (m[1] as NSString).length
          if leading > 0 { plan.hiddenRange = NSRange(location: li.start, length: leading) }
          let rest = (li.text as NSString).substring(from: leading)
          applyListMarker(
            to: &plan, text: rest, start: li.start + leading, isTask: isTask, baseIndent: 0,
            itemLine: item?.startLine == lineNo ? lineNo : nil,
            parentItemLine: item?.parentStartLine)
          plan.checked = checked
          return plan
        }
        // Line inside a list that has no marker (a continuation of an item's text):
        // aligned with the item's content, its own leading indentation hidden.
        var plan = LinePlan(
          role: .listFallback, base: bodyBase(), paragraphStyle: style.bodyParagraph())
        if let item = innermostItem(covering: lineNo) {
          let leading = (li.text as NSString).length
            - (String(li.text.drop(while: { $0 == " " || $0 == "\t" })) as NSString).length
          let hide = min(leading, contentColumn(ofItemAt: item.startLine))
          if hide > 0 { plan.hiddenRange = NSRange(location: li.start, length: hide) }
          plan.hang = Hang(
            baseIndent: 0, itemLine: nil, parentItemLine: item.startLine,
            prefix: NSRange(location: li.start, length: 0))
        }
        return plan

      case is Table:
        let tablePara = tableParagraph()
        let isGrid = gridTables.contains(t.startLine)
        let isRaw = rawTables.contains(t.startLine)
        let offset = lineNo - t.startLine  // 0 = header row, 1 = separator row
        if offset == 0 {
          let base: [NSAttributedString.Key: Any] = [
            .font: style.emphasisFont(base: style.codeFont(), bold: true, italic: false),
            .foregroundColor: style.textColor, .paragraphStyle: tablePara,
          ]
          var plan = LinePlan(
            role: .tableHeader, base: base, paragraphStyle: tablePara, tableGrid: isGrid)
          plan.tableRaw = isRaw
          return plan
        }
        let base: [NSAttributedString.Key: Any] = [
          .font: style.codeFont(), .foregroundColor: style.textColor, .paragraphStyle: tablePara,
        ]
        if offset == 1 {
          let full = NSRange(location: li.start, length: (li.text as NSString).length)
          if isGrid {
            // Grid mode: the `|---|` characters are invisible, so giving the row a tiny
            // font only shortens it — which pulls the drawn header rule up against the
            // header text instead of leaving a full blank line under it. Hidden with NO
            // line command (the rule is the visible stand-in, revealed by nothing).
            return LinePlan(
              role: .tableSeparator,
              base: [
                .font: MarkdownFont(kind: .code, size: style.metrics.tableSeparatorFontSize),
                .foregroundColor: style.textColor, .paragraphStyle: tablePara,
              ], paragraphStyle: tablePara, tableGrid: true, hiddenRange: full)
          }
          if isRaw {
            // RAW: the `|---|` row stays visible (syntax-colored), like the pipes.
            var rawBase = base
            rawBase[.foregroundColor] = style.syntaxColor
            var plan = LinePlan(role: .tableSeparator, base: rawBase, paragraphStyle: tablePara)
            plan.tableRaw = true
            return plan
          }
          return LinePlan(
            role: .tableSeparator, base: base, paragraphStyle: tablePara, markerRange: full)
        }
        var plan = LinePlan(
          role: .tableBody, base: base, paragraphStyle: tablePara, tableGrid: isGrid)
        plan.tableRaw = isRaw
        return plan

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

    /// Marks a list marker at the start of `text` (which begins at document offset
    /// `start`): a task's `-` is a line command and its `[ ]` a checkbox; a plain marker
    /// is always shown (an unordered one drawn as "•"). Also records the hanging-indent
    /// inputs. `isTask` nil means "detect from the text" (lists inside quotes, where the
    /// AST lookup is not used). No-op when `text` does not start with a marker.
    private func applyListMarker(
      to plan: inout LinePlan, text: String, start: Int, isTask: Bool?, baseIndent: CGFloat,
      itemLine: Int?, parentItemLine: Int?
    ) {
      if isTask ?? true,
        let tm = match(text, pattern: "^([-*+])([ \\t]+)(\\[[ xX]\\])([ \\t]+)(.*)$")
      {
        let dashLen = (tm[1] as NSString).length + (tm[2] as NSString).length
        let boxLen = (tm[3] as NSString).length
        let boxStart = start + dashLen
        // The task "-" is a LINE COMMAND (hidden/collapsed until the caret is on the
        // line), like heading '#'. It is NOT a persistent list marker and NOT a bullet —
        // the checkbox keeps its slot (image drawn), the "-" reveals only when active.
        let dash = NSRange(location: start, length: dashLen)
        plan.markerRange = plan.markerRange.map { NSUnionRange($0, dash) } ?? dash
        plan.checkboxRange = NSRange(location: boxStart, length: boxLen)
        if plan.checked == nil {
          plan.checked = tm[3].contains("x") || tm[3].contains("X")
        }
        plan.hang = Hang(
          baseIndent: baseIndent, itemLine: itemLine, parentItemLine: parentItemLine,
          prefix: NSRange(location: boxStart, length: boxLen + (tm[4] as NSString).length),
          checkboxMiddle: boxStart + 1)
        return
      }
      guard let m = match(text, pattern: "^([-*+]|\\d+[.)])([ \\t]+)") else { return }
      let markerLen = (m[1] as NSString).length
      let marker = NSRange(location: start, length: markerLen + (m[2] as NSString).length)
      if plan.markerRange == nil { plan.markerRange = marker }
      plan.listMarkerRange = marker
      let unordered = markerLen == 1 && "-*+".contains(m[1])
      // Plain unordered bullet "-"/"*"/"+": the marker CHARACTER renders as "•" via
      // glyph substitution (source keeps the literal "-").
      if unordered { plan.bulletRange = NSRange(location: start, length: 1) }
      plan.hang = Hang(
        baseIndent: baseIndent, itemLine: itemLine, parentItemLine: parentItemLine,
        prefix: marker, bulletIndex: unordered ? start : nil)
    }

    /// Characters before an item's content on its first line (indent + marker + space,
    /// plus the checkbox and its space for a task) — how far a continuation line's own
    /// indentation reaches into the item.
    private func contentColumn(ofItemAt line: Int) -> Int {
      guard line >= 1, line <= lines.count else { return 0 }
      let text = lines[line - 1].text
      if let m = match(text, pattern: "^([ \\t]*[-*+][ \\t]+\\[[ xX]\\][ \\t]+)") {
        return (m[1] as NSString).length
      }
      if let m = match(text, pattern: "^([ \\t]*(?:[-*+]|\\d+[.)])[ \\t]+)") {
        return (m[1] as NSString).length
      }
      return 0
    }

    private func codeParagraph() -> MarkdownParagraph { style.codeParagraph() }

    private func tableParagraph() -> MarkdownParagraph { style.tableParagraph() }
  }

  // MARK: - Table grid (column alignment; never touches characters)

  /// cmark source range → UTF-16 NSRange against the parser's line table (the same math
  /// as the local `nsRange` in `parse`, exposed for the table pass).
  private static func nsRange(_ r: SourceRange?, lines: [LineInfo]) -> NSRange? {
    guard let r else { return nil }
    let l1 = r.lowerBound.line
    let c1 = r.lowerBound.column
    let l2 = r.upperBound.line
    let c2 = r.upperBound.column
    guard l1 >= 1, l2 >= 1, l1 <= lines.count, l2 <= lines.count else { return nil }
    let start = lines[l1 - 1].start + byteToUTF16(c1 - 1, in: lines[l1 - 1].text)
    let end = lines[l2 - 1].start + byteToUTF16(c2 - 1, in: lines[l2 - 1].text)
    guard end >= start else { return nil }
    return NSRange(location: start, length: end - start)
  }

  /// A cell range without its surrounding horizontal padding. cmark's cell range covers
  /// the padded cell (`" bbb "` between two pipes), not the content.
  private static func trimmedRange(_ r: NSRange, in ns: NSString) -> NSRange {
    var start = r.location
    var end = min(NSMaxRange(r), ns.length)
    while start < end, isHorizontalSpace(ns.character(at: start)) { start += 1 }
    while end > start, isHorizontalSpace(ns.character(at: end - 1)) { end -= 1 }
    return NSRange(location: start, length: end - start)
  }

  private static func isHorizontalSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }

  /// Runs the table grid pass over the resolved attributed string.
  ///
  /// For every GRID-mode table: nulls each pipe's advance (attribute-only — the pipe
  /// characters must stay in the string), measures the columns, aligns every row onto the
  /// grid with `.kern` deltas, and attaches the grid / ordinal / header-rule attributes.
  /// Source-mode tables are untouched (raw markdown, today's rendering).
  @discardableResult
  private static func applyTableGrid(
    tables: [(table: Table, top: TopBlock, ordinal: Int, isGrid: Bool)],
    native: NSMutableAttributedString, ns: NSString, lines: [LineInfo],
    style: any MarkdownStyling
  ) -> [Int: CGFloat] {
    var tableWidths: [Int: CGFloat] = [:]
    for entry in tables where entry.isGrid {
      let top = entry.top
      func cellRanges(_ row: Markup) -> [NSRange] {
        row.children.compactMap { ($0 as? Table.Cell)?.range }
          .compactMap { nsRange($0, lines: lines) }
      }
      // Header first, then the body's data rows. The `|---|` separator is NOT an AST row,
      // so data row n is source line `top.startLine + 2 + n`.
      var rowCells: [[NSRange]] = [cellRanges(entry.table.head)]
      for row in entry.table.body.children {
        if let r = row as? Table.Row { rowCells.append(cellRanges(r)) }
      }
      let columnCount = rowCells.map(\.count).max() ?? 0
      guard columnCount > 0, top.endLine > top.startLine else { continue }
      let alignments = entry.table.columnAlignments

      // Measure on a snapshot: the deltas written below would otherwise be measured back
      // into the prefixes of the same row.
      let snapshot = NSAttributedString(attributedString: native)

      var widths = [CGFloat](repeating: 0, count: columnCount)
      var cellWidths = [[CGFloat]](repeating: [], count: rowCells.count)
      for (ri, cells) in rowCells.enumerated() {
        for c in 0..<columnCount {
          let content =
            c < cells.count ? trimmedRange(cells[c], in: ns) : NSRange(location: 0, length: 0)
          let w = content.length > 0 ? TableColumnLayout.measuredWidth(of: content, in: snapshot) : 0
          cellWidths[ri].append(w)
          widths[c] = max(widths[c], w)
        }
      }

      let model = TableColumnLayout.model(
        columnContentWidths: widths, padding: style.metrics.tableCellPadding)
      tableWidths[entry.ordinal] = model.tableWidth

      // Whole-block range (every line of the table, newlines included) — carries the grid
      // line positions and the ordinal the editor uses to flip this table's mode.
      let blockStart = lines[top.startLine - 1].start
      let lastIndex = min(top.endLine - 1, lines.count - 1)
      let last = lines[lastIndex]
      let blockEnd = min(
        last.start + (last.text as NSString).length + (last.hasNewline ? 1 : 0), ns.length)
      guard blockEnd > blockStart else { continue }
      let blockRange = NSRange(location: blockStart, length: blockEnd - blockStart)
      native.addAttribute(
        .markdownTableGrid,
        value: model.separatorTargets.map { NSNumber(value: Double($0)) }, range: blockRange)
      native.addAttribute(
        .markdownTableOrdinal, value: NSNumber(value: entry.ordinal), range: blockRange)

      // Null every pipe in the block (header, separator and body rows alike): zero width,
      // still present in the string. SF Mono has no zero-width glyph for the layout
      // manager's substitution to use, so the advance is cancelled with a kern instead —
      // the pipes keep their full advance and every row drifts.
      var pipeIdx = blockRange.location
      while pipeIdx < NSMaxRange(blockRange) {
        if ns.character(at: pipeIdx) == 0x7C,
          let font = snapshot.attribute(.font, at: pipeIdx, effectiveRange: nil) as? PlatformFont
        {
          native.addAttribute(
            .kern, value: TableColumnLayout.nullingKern(of: 0x7C, in: font),
            range: NSRange(location: pipeIdx, length: 1))
        }
        pipeIdx += 1
      }

      // The `|---|` row (source line `top.startLine + 1`): its characters are hidden, so
      // the drawn rule gets the table's width instead.
      let separatorIndex = top.startLine  // 0-based index of the separator line
      if separatorIndex <= top.endLine - 1, separatorIndex < lines.count {
        let li = lines[separatorIndex]
        let length = min((li.text as NSString).length, max(0, ns.length - li.start))
        if length > 0 {
          native.addAttribute(
            .markdownTableRule, value: NSNumber(value: Double(model.tableWidth)),
            range: NSRange(location: li.start, length: length))
        }
      }

      for (ri, cells) in rowCells.enumerated() {
        let lineIndex = top.startLine - 1 + (ri == 0 ? 0 : ri + 1)
        guard lineIndex < lines.count else { continue }
        let rowStart = lines[lineIndex].start
        let rowEnd = min(rowStart + (lines[lineIndex].text as NSString).length, ns.length)
        guard rowEnd >= rowStart else { continue }

        // One anchor per non-empty cell: the character BEFORE its content. Everything
        // from that character onward is shifted by the delta, landing the content on the
        // column's grid position.
        var anchors: [(anchorCharIndex: Int, targetX: CGFloat, naturalEndX: CGFloat)] = []
        var indentShift = false
        var indentExtra: CGFloat = 0
        for c in 0..<columnCount where c < cells.count {
          let content = trimmedRange(cells[c], in: ns)
          guard content.length > 0 else { continue }
          // Column alignment (`|:---:|`, `|---:|`): instead of kerning the opening pipe
          // (which would desynchronize the chain), the cell's target x is pushed right
          // within its column.
          var extra: CGFloat = 0
          let alignment = c < alignments.count ? alignments[c] : nil
          let slack = widths[c] - cellWidths[ri][c]
          if alignment == .right {
            extra = slack
          } else if alignment == .center {
            extra = slack / 2
          }
          let target = model.contentTargets[c] + extra
          if content.location - 1 >= rowStart {
            anchors.append(
              (anchorCharIndex: content.location - 1, targetX: target, naturalEndX: 0))
          } else if !indentShift {
            // No outer pipe: nothing precedes column 0's content, so the row is shifted
            // with a paragraph indent instead (still attributes only).
            indentShift = true
            indentExtra =
              target
              - TableColumnLayout.measuredWidth(
                of: NSRange(location: rowStart, length: content.location - rowStart),
                in: snapshot)
          }
        }
        guard !anchors.isEmpty || indentShift else { continue }
        if indentShift {
          shiftRowIndent(
            lineIndex: lineIndex, extra: indentExtra, lines: lines, native: native)
        }
        for k in anchors.indices {
          anchors[k].naturalEndX = TableColumnLayout.measuredWidth(
            of: NSRange(
              location: rowStart, length: anchors[k].anchorCharIndex - rowStart + 1),
            in: snapshot)
        }
        if indentShift, !anchors.isEmpty {
          // The line's indent already moved every anchor right by `indentExtra`; folding it
          // into the first target keeps the rest of the chain consistent.
          anchors[0].targetX -= indentExtra
        }
        for d in TableColumnLayout.deltas(anchors: anchors)
        where d.anchorCharIndex >= 0 && d.anchorCharIndex < native.length {
          guard abs(d.delta) > 0.001 else { continue }
          let existing =
            (native.attribute(.kern, at: d.anchorCharIndex, effectiveRange: nil) as? CGFloat) ?? 0
          native.addAttribute(
            .kern, value: existing + d.delta,
            range: NSRange(location: d.anchorCharIndex, length: 1))
        }
      }
    }
    // Source-mode tables still carry their ordinal: the editor reads it at the caret to
    // know when the caret has left the table (which returns it to the grid).
    for entry in tables where !entry.isGrid {
      let top = entry.top
      guard top.startLine >= 1, top.startLine <= lines.count else { continue }
      let blockStart = lines[top.startLine - 1].start
      let lastIndex = min(top.endLine - 1, lines.count - 1)
      let last = lines[lastIndex]
      let blockEnd = min(
        last.start + (last.text as NSString).length + (last.hasNewline ? 1 : 0), ns.length)
      guard blockEnd > blockStart else { continue }
      native.addAttribute(
        .markdownTableOrdinal, value: NSNumber(value: entry.ordinal),
        range: NSRange(location: blockStart, length: blockEnd - blockStart))
    }
    return tableWidths
  }

  // MARK: - List hanging indents (measured from the drawn marker)

  /// Rewrites every list line's paragraph indents from real font metrics: the first line
  /// starts under the parent item's text (or at the quote indent / 0), and wrapped lines
  /// hang at the start of the item's own text. Attributes only.
  private static func applyHangingIndents(
    plans: [LinePlan], lines: [LineInfo], native: NSMutableAttributedString
  ) {
    let ns = native.string as NSString
    var contentX: [Int: CGFloat] = [:]  // item start line → x where its text starts
    for (index, plan) in plans.enumerated() {
      guard let hang = plan.hang, index < lines.count else { continue }
      let li = lines[index]
      let first = hang.parentItemLine.flatMap { contentX[$0] } ?? hang.baseIndent
      var width: CGFloat = 0
      var i = hang.prefix.location
      while i < NSMaxRange(hang.prefix), i < ns.length {
        if let font = native.attribute(.font, at: i, effectiveRange: nil) as? PlatformFont {
          let original = ns.character(at: i)
          var advance: CGFloat = 0
          if i == hang.bulletIndex {
            advance = TableColumnLayout.advance(of: 0x2022, in: font)  // •
          } else if i == hang.checkboxMiddle {
            // The same slot glyph the layout manager substitutes: EN SPACE, EN QUAD.
            advance = TableColumnLayout.advance(of: 0x2002, in: font)
            if advance == 0 { advance = TableColumnLayout.advance(of: 0x2000, in: font) }
          }
          if advance == 0 { advance = TableColumnLayout.advance(of: original, in: font) }
          width += advance
        }
        i += 1
      }
      let head = first + width
      if let itemLine = hang.itemLine { contentX[itemLine] = head }
      let length = min(
        (li.text as NSString).length + (li.hasNewline ? 1 : 0), max(0, native.length - li.start))
      guard length > 0,
        let style = MarkdownRenderer.settingIndents(
          native.attribute(.paragraphStyle, at: li.start, effectiveRange: nil),
          firstLine: first, head: head)
      else { continue }
      native.addAttribute(
        .paragraphStyle, value: style, range: NSRange(location: li.start, length: length))
    }
  }

  // MARK: - Bare URLs

  /// `https://…`, `http://…` and `www.…` runs in plain text, with trailing punctuation
  /// (and an unbalanced closing parenthesis) trimmed the way GFM does.
  static func bareURLs(in text: String) -> [(NSRange, URL)] {
    guard text.contains("://") || text.contains("www.") else { return [] }
    guard
      let re = regex(
        "(?<![\\w/@.])(?:https?://|www\\.)[^\\s<>]+", options: [.caseInsensitive])
    else { return [] }
    let ns = text as NSString
    var out: [(NSRange, URL)] = []
    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      var candidate = ns.substring(with: m.range)
      while let last = candidate.last {
        if ".,:;!?'\"*_~".contains(last) {
          candidate.removeLast()
        } else if last == ")",
          candidate.filter({ $0 == ")" }).count > candidate.filter({ $0 == "(" }).count
        {
          candidate.removeLast()
        } else {
          break
        }
      }
      let host = candidate.lowercased().hasPrefix("www.") ? "https://" + candidate : candidate
      guard candidate.count > 8 || candidate.lowercased().hasPrefix("www."),
        let url = URL(string: host), url.host != nil
      else { continue }
      out.append(
        (NSRange(location: m.range.location, length: (candidate as NSString).length), url))
    }
    return out
  }

  /// Adds `extra` to a line's first-line indent — used for a table row with no outer pipe,
  /// where there is no character before column 0's content to kern. Attributes only (the
  /// platform-native paragraph copy comes from `MarkdownRenderer`).
  private static func shiftRowIndent(
    lineIndex: Int, extra: CGFloat, lines: [LineInfo], native: NSMutableAttributedString
  ) {
    guard lineIndex >= 0, lineIndex < lines.count, abs(extra) > 0.01 else { return }
    let li = lines[lineIndex]
    guard li.start < native.length,
      let shifted = MarkdownRenderer.addingFirstLineIndent(
        native.attribute(.paragraphStyle, at: li.start, effectiveRange: nil), by: extra)
    else { return }
    let length = min((li.text as NSString).length + (li.hasNewline ? 1 : 0), native.length - li.start)
    guard length > 0 else { return }
    native.addAttribute(
      .paragraphStyle, value: shifted, range: NSRange(location: li.start, length: length))
  }

  /// The FULL fenced-code block range for a content `.markdownCodeBlock` span:
  /// extends the content span up to include the enclosing CodeBlock's ``` open
  /// fence line and closing ``` fence line. Returns the union of the content span
  /// and the enclosing block's AST line range (converted to UTF-16 offsets). This
  /// is used only to drive the background fill so fence lines get the fill too,
  /// while the content-only `.markdownCodeBlock` span keeps chrome/Copy correct.
  private static func fullCodeRange(
    for contentRange: NSRange, lines: [LineInfo], topBlocks: [TopBlock]
  ) -> NSRange? {
    // Which top-level block contains the content span's first line?
    let startLine = lines.firstIndex { $0.start == contentRange.location }.map { $0 + 1 } ?? 1
    guard
      let top = topBlocks.first(where: { $0.startLine <= startLine && startLine <= $0.endLine }),
      top.node is CodeBlock
    else { return contentRange }
    let openLine = top.startLine - 1  // 0-based index of the opening ``` line
    let closeLine = top.endLine - 1  // 0-based index of the closing ``` line (or last content)
    guard openLine >= 0, openLine < lines.count else { return contentRange }
    let openStart = lines[openLine].start
    let closeLineIndex = min(closeLine, lines.count - 1)
    let closeEnd =
      lines[closeLineIndex].start + (lines[closeLineIndex].text as NSString).length
      + (lines[closeLineIndex].hasNewline ? 1 : 0)
    return NSRange(location: min(openStart, contentRange.location), length: closeEnd - openStart)
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

}

// MARK: - HTML

extension MarkdownParser {
  /// Renders the HTML a README carries: hides every tag (block tags per line, like other
  /// block syntax; inline tags per span), draws `<img>` (and the `<picture>` source for
  /// the current appearance), links `<a href>`, styles `<b>`/`<i>`/`<code>`/`<kbd>`/
  /// `<del>`/`<sup>`/`<hN>`, aligns `align="center"` blocks, draws `<hr>` as a rule,
  /// decodes entities in block text, hides link reference definitions — and marks the
  /// lines left with nothing visible as collapsible.
  ///
  /// `tags` arrives holding the inline HTML found by the inline pass; the HTML blocks'
  /// tags are added here. Attribute values are still platform-neutral (pre-render),
  /// except the newline paragraph styles, which line emission already resolved.
  private static func applyHTML(
    tags: inout [(tag: MarkdownHTML.Tag, inBlock: Bool)], plans: [LinePlan], lines: [LineInfo],
    out: NSMutableAttributedString, markdown: String, style: any MarkdownStyling,
    resolver: MarkdownURLResolver, blockMarkSyntax: (NSRange) -> Void,
    inlineSyntaxMark: (NSRange) -> Void,
    markEntity: (_ range: NSRange, _ codeUnit: UInt16, _ lineCommand: Bool) -> Void
  ) {
    let ns = markdown as NSString
    func contentRange(_ i: Int) -> NSRange {
      NSRange(location: lines[i].start, length: (lines[i].text as NSString).length)
    }
    /// Index of the line holding UTF-16 offset `location` (binary search on line starts).
    func lineIndex(at location: Int) -> Int {
      var lo = 0
      var hi = lines.count - 1
      while lo < hi {
        let mid = (lo + hi + 1) / 2
        if lines[mid].start <= location { lo = mid } else { hi = mid - 1 }
      }
      return max(0, lo)
    }
    /// Hides `range` as block syntax one line at a time: visibility is decided per line
    /// (the caret's line reveals it), so a multi-line comment must not be one run.
    func blockHide(_ range: NSRange) {
      var i = lineIndex(at: range.location)
      while i < lines.count, lines[i].start < NSMaxRange(range) {
        let piece = NSIntersectionRange(range, contentRange(i))
        if piece.length > 0 { blockMarkSyntax(piece) }
        i += 1
      }
    }

    // --- HTML block runs: consecutive .html lines tokenized together (a comment or a
    // tag may span lines) ---
    var htmlLines: [Int] = []
    var runOfLine: [Int: ClosedRange<Int>] = [:]
    var i = 0
    while i < plans.count {
      guard plans[i].role == .html else {
        i += 1
        continue
      }
      var j = i
      while j + 1 < plans.count, plans[j + 1].role == .html { j += 1 }
      for k in i...j { runOfLine[k] = i...j }
      htmlLines.append(contentsOf: i...j)
      let start = lines[i].start
      let end = NSMaxRange(contentRange(j))
      let text = ns.substring(with: NSRange(location: start, length: end - start))
      let blockTags = MarkdownHTML.tags(in: text, base: start)
      for tag in blockTags { blockHide(tag.range) }
      tags.append(contentsOf: blockTags.map { (tag: $0, inBlock: true) })
      for e in MarkdownHTML.entities(in: text, base: start)
      where !blockTags.contains(where: { NSIntersectionRange($0.range, e.range).length > 0 }) {
        markEntity(e.range, e.codeUnit, true)
      }
      // Indentation inside an HTML block is source formatting, not content (and it
      // would push a centered line off-center).
      for k in i...j {
        let text = lines[k].text as NSString
        var n = 0
        while n < text.length, text.character(at: n) == 0x20 || text.character(at: n) == 0x09 {
          n += 1
        }
        if n > 0, n < text.length { blockMarkSyntax(NSRange(location: lines[k].start, length: n)) }
      }
      i = j + 1
    }

    // --- Link reference definitions (`[id]: url "title"`): no rendered form ---
    var referenceLines: [Int] = []
    for (k, plan) in plans.enumerated() where plan.role == .plain {
      if match(lines[k].text, pattern: "^ {0,3}\\[[^\\]]+\\]:\\s*\\S") != nil {
        blockMarkSyntax(contentRange(k))
        referenceLines.append(k)
      }
    }

    // --- Tags in document order ---
    tags.sort { $0.tag.range.location < $1.tag.range.location }
    let isDark = MarkdownRenderer.currentAppearanceIsDark()
    var pictureSources: [MarkdownHTML.Tag]? = nil
    struct Open {
      var tag: MarkdownHTML.Tag
      var inBlock: Bool
    }
    var stack: [Open] = []

    func updateParagraphs(lines range: ClosedRange<Int>, _ change: (inout MarkdownParagraph) -> Void) {
      for k in range where k < lines.count {
        let content = contentRange(k)
        var para = style.bodyParagraph()
        if content.length > 0 {
          out.enumerateAttribute(.paragraphStyle, in: content, options: []) { value, r, _ in
            guard var p = value as? MarkdownParagraph else { return }
            change(&p)
            out.addAttribute(.paragraphStyle, value: p, range: r)
          }
          if let first = out.attribute(.paragraphStyle, at: content.location, effectiveRange: nil)
            as? MarkdownParagraph
          {
            para = first
          }
        } else {
          change(&para)
        }
        // The newline's style was resolved at emission; replace it with the new one.
        if lines[k].hasNewline, NSMaxRange(content) < out.length {
          out.addAttribute(
            .paragraphStyle, value: MarkdownRenderer.resolve(para),
            range: NSRange(location: NSMaxRange(content), length: 1))
        }
      }
    }
    func updateFonts(_ range: NSRange, _ change: (MarkdownFont) -> MarkdownFont) {
      guard range.length > 0 else { return }
      out.enumerateAttribute(.font, in: range, options: []) { value, r, _ in
        let font = (value as? MarkdownFont) ?? style.bodyFont()
        out.addAttribute(.font, value: change(font), range: r)
      }
    }
    func close(_ open: Open, at closeLocation: Int?) {
      let tag = open.tag
      let contentStart = NSMaxRange(tag.range)
      let contentEnd = closeLocation ?? contentStart
      let content = NSRange(location: contentStart, length: max(0, contentEnd - contentStart))
      switch tag.name {
      case "a":
        if let href = tag.attributes["href"], let url = resolver.resolveLink(href),
          content.length > 0
        {
          out.addAttribute(.link, value: url, range: content)
          out.addAttribute(.foregroundColor, value: style.linkColor, range: content)
        }
      case "b", "strong", "summary":
        updateFonts(content) { $0.addingTraits([.bold]) }
      case "i", "em":
        updateFonts(content) { $0.addingTraits([.italic]) }
      case "code", "kbd", "samp", "tt":
        updateFonts(content) { MarkdownFont(kind: .code, size: max(9, $0.size - 1), weight: .regular) }
        out.addAttribute(.foregroundColor, value: style.codeTextColor, range: content)
        out.addAttribute(.markdownInlineCode, value: true, range: content)
      case "del", "s", "strike":
        if content.length > 0 {
          out.addAttribute(.strikethroughStyle, value: 1, range: content)
          out.addAttribute(.strikethroughColor, value: style.textColor, range: content)
        }
      case "sup", "sub", "small":
        updateFonts(content) { f in
          var smaller = f
          smaller.size = max(8, (f.size * 0.8).rounded())
          return smaller
        }
      case "h1", "h2", "h3", "h4", "h5", "h6":
        let level = Int(String(tag.name.dropFirst())) ?? 1
        updateFonts(content) { _ in style.headingFont(level: level) }
        let first = lineIndex(at: tag.range.location)
        let last = lineIndex(at: max(tag.range.location, contentEnd))
        let heading = style.headingParagraph(level: level)
        updateParagraphs(lines: first...last) { p in
          p.paragraphSpacing = heading.paragraphSpacing
          p.paragraphSpacingBefore = first == lineIndex(at: tag.range.location) ? heading.paragraphSpacingBefore : 0
        }
      default:
        break
      }
      if let align = tag.attributes["align"]?.lowercased() {
        let alignment: MarkdownParagraph.Alignment? =
          align == "center" ? .center : align == "right" ? .right : align == "left" ? .left : nil
        if let alignment {
          let first = lineIndex(at: tag.range.location)
          var last = lineIndex(at: max(tag.range.location, contentEnd))
          // Unclosed: through the end of its own HTML block.
          if closeLocation == nil, let run = runOfLine[first] { last = run.upperBound }
          updateParagraphs(lines: first...last) { $0.alignment = alignment }
        }
      }
    }

    for (tag, inBlock) in tags {
      if tag.isComment { continue }
      switch tag.name {
      case "img":
        var src = tag.attributes["src"] ?? ""
        if let sources = pictureSources, let chosen = MarkdownHTML.pictureSource(sources, isDark: isDark) {
          src = chosen
        }
        guard !src.isEmpty, let url = resolver.resolveImage(src) else { continue }
        let width = MarkdownHTML.dimension(tag.attributes["width"])
        let height = MarkdownHTML.dimension(tag.attributes["height"])
        let valign = (tag.attributes["valign"] ?? tag.attributes["align"] ?? "").lowercased()
        let spec = MarkdownImageSpec(
          url: url, range: tag.range, width: width.points, height: height.points,
          widthFraction: width.fraction, alt: tag.attributes["alt"] ?? "",
          verticalAlignment: ["middle", "absmiddle", "center"].contains(valign) ? .middle : .baseline)
        out.addAttribute(.markdownImage, value: url, range: tag.range)
        out.addAttribute(.markdownImageSpec, value: spec, range: tag.range)
      case "picture":
        pictureSources = tag.isClosing ? nil : []
      case "source":
        pictureSources?.append(tag)
      case "hr":
        guard inBlock else { continue }
        let line = contentRange(lineIndex(at: tag.range.location))
        if ns.substring(with: line).trimmingCharacters(in: .whitespaces)
          == ns.substring(with: tag.range)
        {
          out.addAttribute(.markdownRule, value: true, range: line)
        }
      default:
        if tag.isClosing {
          if let index = stack.lastIndex(where: { $0.tag.name == tag.name }) {
            let open = stack.remove(at: index)
            close(open, at: tag.range.location)
          }
        } else if !tag.isSelfClosing {
          stack.append(Open(tag: tag, inBlock: inBlock))
        }
      }
    }
    // Unclosed elements still apply their alignment (to the end of their block).
    for open in stack where open.tag.attributes["align"] != nil { close(open, at: nil) }

    // --- Collapsible lines: nothing left to see (tags, comments, definitions) ---
    for k in htmlLines + referenceLines {
      let content = contentRange(k)
      guard content.length > 0 else { continue }
      var hidden = 0
      out.enumerateAttribute(.markdownSyntax, in: content, options: []) { value, r, _ in
        if value != nil { hidden += r.length }
      }
      guard hidden == content.length else { continue }
      var visible = false
      for key: NSAttributedString.Key in [.markdownImage, .markdownGlyphSubstitute, .markdownRule] {
        out.enumerateAttribute(key, in: content, options: []) { value, _, stop in
          if value != nil {
            visible = true
            stop.pointee = true
          }
        }
      }
      // A `<br>` line is deliberate vertical space.
      if visible || ns.substring(with: content).lowercased().contains("<br") { continue }
      let length = content.length + (lines[k].hasNewline ? 1 : 0)
      out.addAttribute(
        .markdownCollapsibleLine, value: true,
        range: NSRange(location: content.location, length: length))
    }
  }
}
#endif
