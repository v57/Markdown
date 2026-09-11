#if canImport(AppKit)
  import AppKit
  import CoreText
  import Testing

  @testable import Md

  // MARK: - GFM tables: grid mode (aligned columns, hidden pipes, drawn separators) and
  // source mode (today's raw-markdown rendering), plus the pure column geometry.
  //
  // All layout probes are headless (NSTextStorage + EditorLayoutManager + NSTextContainer,
  // no window), the same technique the ParserTests layout helpers use.

  @Suite struct TableTests {

    /// A laid-out headless stack for `text`. The caret is parked at index 0 — the
    /// "reading, not editing" state.
    ///
    /// The three objects are returned as ONE value that the caller must hold for the
    /// duration of the test: `NSLayoutManager` does NOT retain its text storage (TextKit 1
    /// keeps an unretained back-pointer), so discarding the storage while using the layout
    /// manager leaves it reading freed memory — which shows up as a layout manager with
    /// numberOfGlyphs == 0 and intermittent crashes.
    private struct Stack {
      let storage: NSTextStorage
      let lm: EditorLayoutManager
      let container: NSTextContainer
    }

    private func stack(_ text: String, width: CGFloat = 600, padding: CGFloat = 0) -> Stack {
      let storage = NSTextStorage(attributedString: MarkdownParser.parse(text).attributed)
      let lm = EditorLayoutManager()
      storage.addLayoutManager(lm)
      let container = NSTextContainer(size: NSSize(width: width, height: 4000))
      // Zero the padding by default so the measured glyph x IS the parser's
      // container-relative grid coordinate; `drawnGridAlignsWithTheText` uses the AppKit
      // default (5) to prove the drawn grid adds the same padding the glyphs do.
      container.lineFragmentPadding = padding
      lm.addTextContainer(container)
      lm.activeCharacterRange = NSRange(location: 0, length: 0)
      lm.ensureLayout(for: container)
      return Stack(storage: storage, lm: lm, container: container)
    }

    /// Moves the caret to `caret` and forces a full relayout (glyphs AND line positions —
    /// `invalidateGlyphs` alone is not enough).
    private func relayout(_ lm: EditorLayoutManager, caret: Int, storage: NSTextStorage) {
      lm.activeCharacterRange = NSRange(location: caret, length: 0)
      lm.invalidateGlyphs(
        forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0,
        actualCharacterRange: nil)
      lm.invalidateLayout(
        forCharacterRange: NSRange(location: 0, length: storage.length),
        actualCharacterRange: nil)
      lm.ensureLayout(for: lm.textContainers.first!)
    }

    /// The x position (container-relative) of the character at `index`.
    private func x(of index: Int, lm: EditorLayoutManager) -> CGFloat? {
      let g = lm.glyphRange(
        forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
      guard g.length > 0 else { return nil }
      return lm.location(forGlyphAt: g.location).x
    }

    /// Start index of each 0-based line.
    private func lineStart(_ text: String, _ line: Int) -> Int {
      let ns = text as NSString
      var loc = 0
      for _ in 0..<line {
        loc = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0)))
      }
      return loc
    }

    /// Index of the first non-space character after the `cell`-th pipe on `line` — i.e.
    /// where that cell's content starts (0-based line/cell).
    private func lineContentIndex(_ text: String, line: Int, cell: Int) -> Int {
      let ns = text as NSString
      let start = lineStart(text, line)
      let end = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0)))
      var seen = -1
      var i = start
      while i < end {
        if ns.character(at: i) == 0x7C {
          seen += 1
          if seen == cell {
            var j = i + 1
            while j < end, ns.character(at: j) == 0x20 { j += 1 }
            return min(j, end - 1)
          }
        }
        i += 1
      }
      return NSNotFound
    }

    private func gridXs(_ attributed: NSAttributedString, at index: Int = 0) -> [CGFloat] {
      let value = attributed.attribute(.markdownTableGrid, at: index, effectiveRange: nil)
      return (value as? [NSNumber])?.map { CGFloat($0.doubleValue) } ?? []
    }

    // MARK: - Pure geometry

    @Test func columnModelGeometry() {
      let model = TableColumnLayout.model(columnContentWidths: [20, 40], padding: 8)
      #expect(model.contentTargets == [8, 44])
      #expect(model.separatorTargets == [0, 36, 92])
      #expect(model.tableWidth == 92)
    }

    @Test func kernDeltasAccumulate() {
      let deltas = TableColumnLayout.deltas(anchors: [
        (anchorCharIndex: 3, targetX: 50, naturalEndX: 30),
        (anchorCharIndex: 9, targetX: 120, naturalEndX: 100),
      ])
      #expect(deltas.count == 2)
      #expect(abs(deltas[0].delta - 20) < 0.001)
      #expect(abs(deltas[1].delta - 0) < 0.001)  // 120 − (100 + 20): the chain accumulates
    }

    @Test func measuredWidthSkipsHiddenSyntax() {
      // "**b**" must measure as "b": its delimiters are hidden syntax, i.e. zero-width at
      // layout time. (Measuring them would misalign any column holding markup.)
      let attributed = MarkdownParser.parse("| **b** |").attributed
      let whole = TableColumnLayout.measuredWidth(
        of: NSRange(location: 2, length: 5), in: attributed)  // "**b**"
      let bold = TableColumnLayout.measuredWidth(
        of: NSRange(location: 4, length: 1), in: attributed)  // "b"
      #expect(abs(whole - bold) < 0.01)
      #expect(bold > 0)
    }

    @Test func measuredWidthCountsTrailingWhitespace() {
      // Guard against the CTLineGetTypographicBounds trap: that returns INK bounds, which
      // drop trailing whitespace, so a row prefix ending in a cell's padding space would
      // under-measure by one space and shift every column by a character.
      let attributed = MarkdownParser.parse("| a | b |\n|---|---|\n| c | d |").attributed
      // Row 0's prefix "| " (pipe + padding space): the pipe is hidden syntax, so only the
      // space counts — and a trailing space must count as an advance, not as zero.
      let prefix = TableColumnLayout.measuredWidth(
        of: NSRange(location: 0, length: 2), in: attributed)
      let space = TableColumnLayout.measuredWidth(
        of: NSRange(location: 1, length: 1), in: attributed)
      #expect(space > 0)
      #expect(abs(prefix - space) < 0.01)
    }

    // MARK: - Grid mode: hidden pipes

    @Test func gridModeHidesPipesWithoutChangingText() {
      let text = "| a | b |\n|---|---|\n| 1 | 2 |"
      let doc = MarkdownParser.parse(text)
      let ns = text as NSString

      var pipes = 0
      for i in 0..<ns.length where ns.character(at: i) == 0x7C {
        pipes += 1
        // Hidden syntax, and deliberately NOT a line command: the caret must never reveal
        // a pipe in grid mode (a revealed pipe would shift its whole row).
        #expect(doc.attributed.attribute(.markdownSyntax, at: i, effectiveRange: nil) != nil)
        #expect(doc.attributed.attribute(.markdownLineCommand, at: i, effectiveRange: nil) == nil)
        // Each pipe carries a nulling kern that cancels exactly its own advance (SF Mono
        // has no zero-width glyph to substitute, so without this the pipe keeps a full
        // advance and the row drifts). The `|---|` row runs at the tiny separator font, so
        // its pipes need a smaller kern than the header/body rows.
        guard
          let font = doc.attributed.attribute(.font, at: i, effectiveRange: nil) as? NSFont
        else { continue }
        let kern = doc.attributed.attribute(.kern, at: i, effectiveRange: nil) as? CGFloat
        let expected = -TableColumnLayout.advance(of: 0x7C, in: font)
        #expect(expected < -1)
        #expect(abs((kern ?? 0) - expected) < 0.01)
      }
      #expect(pipes == 9)
      #expect(doc.attributed.string == text)  // the characters are all still there
    }

    @Test func gridPipesOccupyNoWidth() {
      // A pipe contributes zero width: the first cell's content sits exactly at the
      // padding offset, and every row agrees.
      let text = "| a | bbb |\n|---|---|\n| cc | d |\n| eee | f |"
      let s = stack(text)
      let lm = s.lm
      let pad = MarkdownMetrics.standard.tableCellPadding
      let first = x(of: lineStart(text, 0) + 2, lm: lm)  // 'a' in row 0
      #expect(first != nil)
      #expect(abs((first ?? 0) - pad) < 0.3)
    }

    // MARK: - Grid mode: alignment across ragged rows

    @Test func tableColumnsAlign() {
      let text = "| a | bbb |\n|---|---|\n| cc | d |\n| eee | f |"
      let doc = MarkdownParser.parse(text)
      let s = stack(text)
      let lm = s.lm

      // Content start of each cell, per row (skipping the separator line).
      var byColumn: [Int: [CGFloat]] = [:]
      for line in [0, 2, 3] {
        for cell in [0, 1] {
          let idx = lineContentIndex(text, line: line, cell: cell)
          guard idx != NSNotFound, let px = x(of: idx, lm: lm) else { continue }
          byColumn[cell, default: []].append(px)
        }
      }
      #expect(byColumn[0]?.count == 3)
      #expect(byColumn[1]?.count == 3)

      // Every row's column lands on the same x (0.3pt tolerance: per-character advance
      // sums differ by a few hundredths across rows).
      for column in [0, 1] {
        let xs = byColumn[column]!
        for px in xs { #expect(abs(px - xs[0]) < 0.3) }
      }
      // Column 1 starts one padding to the right of column 0's widest cell (3 chars).
      let advance = TableColumnLayout.advance(
        of: 0x61,
        in: NSFont.monospacedSystemFont(
          ofSize: MarkdownMetrics.standard.codeFontSize, weight: .regular))
      let expectedSecond = MarkdownMetrics.standard.tableCellPadding + 3 * advance
        + 2 * MarkdownMetrics.standard.tableCellPadding
      #expect(abs((byColumn[1]!.first ?? 0) - expectedSecond) < 0.4)

      // The grid attribute matches the drawn column boundaries.
      let grid = gridXs(doc.attributed)
      #expect(grid.count == 3)
      #expect(abs(grid[0]) < 0.01)
      #expect(abs(grid[1] - (MarkdownMetrics.standard.tableCellPadding + 3 * advance
        + MarkdownMetrics.standard.tableCellPadding)) < 0.4)
      #expect(abs(grid[2] - grid[1] - (3 * advance + 2 * MarkdownMetrics.standard
        .tableCellPadding)) < 0.4)
      #expect(doc.attributed.string == text)
    }

    @Test func tableWithOuterPipesLessRowsAlign() {
      // Rows written without outer pipes: there is no character before column 0's content
      // to kern, so the row is shifted with a paragraph indent instead.
      let text = "a | b\n---|---\ncc | d"
      let doc = MarkdownParser.parse(text)
      let s = stack(text)
      let lm = s.lm
      let x0 = x(of: 0, lm: lm)  // 'a'
      let x1 = x(of: lineStart(text, 2), lm: lm)  // 'c' of "cc"
      #expect(x0 != nil)
      #expect(x1 != nil)
      #expect(abs((x0 ?? 0) - (x1 ?? 0)) < 0.3)
      #expect((x0 ?? 0) > 1)  // shifted onto the grid, not flush at 0
      #expect(doc.attributed.string == text)
    }

    // MARK: - Grid mode: attributes

    @Test func gridAttributesAndHeaderRule() {
      let text = "| a | b |\n|---|---|\n| 1 | 2 |"
      let doc = MarkdownParser.parse(text)
      let ns = text as NSString

      #expect(gridXs(doc.attributed).count == 3)
      let ordinal = doc.attributed.attribute(.markdownTableOrdinal, at: 0, effectiveRange: nil)
        as? NSNumber
      #expect(ordinal?.intValue == 0)

      // Header rule: the drawn rule needs the table's width. Its characters stay hidden.
      let sep = ns.range(of: "|---").location
      let width = doc.attributed.attribute(.markdownTableRule, at: sep, effectiveRange: nil)
        as? NSNumber
      #expect((width?.doubleValue ?? 0) > 0)
      #expect(doc.attributed.attribute(.markdownSyntax, at: sep, effectiveRange: nil) != nil)
      // …and nothing reveals the separator row on caret focus.
      #expect(doc.attributed.attribute(.markdownLineCommand, at: sep, effectiveRange: nil) == nil)
    }

    @Test func gridSeparatorRowIsCompactAndOrdinalsCount() {
      let text = "| a | b |\n|---|---|\n| 1 | 2 |\n\n| c | d |\n|---|---|\n| 3 | 4 |"
      let doc = MarkdownParser.parse(text)
      let ns = text as NSString
      let s = stack(text)
      let lm = s.lm

      // The `|---|` characters are invisible, so grid mode gives the row a tiny font: it
      // only shortens the row, pulling the drawn rule up against the header.
      let sep = ns.range(of: "|---").location
      let sepFont = doc.attributed.attribute(.font, at: sep, effectiveRange: nil) as? NSFont
      #expect(sepFont?.pointSize == MarkdownMetrics.standard.tableSeparatorFontSize)
      let sepGlyph = lm.glyphRange(
        forCharacterRange: NSRange(location: sep, length: 3), actualCharacterRange: nil)
      #expect(sepGlyph.length > 0)
      let fragHeight = lm.lineFragmentRect(
        forGlyphAt: sepGlyph.location, effectiveRange: nil
      ).height
      let headerGlyph = lm.glyphRange(
        forCharacterRange: NSRange(location: 2, length: 1), actualCharacterRange: nil)
      let headerHeight = lm.lineFragmentRect(
        forGlyphAt: headerGlyph.location, effectiveRange: nil
      ).height
      #expect(fragHeight < headerHeight)

      // Two tables → ordinals 0 and 1 (document order).
      let second = ns.range(of: "| c | d |").location
      #expect(
        (doc.attributed.attribute(.markdownTableOrdinal, at: second, effectiveRange: nil)
          as? NSNumber)?.intValue == 1)
      #expect(
        (doc.attributed.attribute(.markdownTableOrdinal, at: 0, effectiveRange: nil)
          as? NSNumber)?.intValue == 0)
      #expect(doc.attributed.string == text)
    }

    // MARK: - Grid mode: cell inline markup

    @Test func tableCellsRenderInlineMarkup() {
      let text = "| h | h2 |\n|---|---|\n| **b** | `c` |"
      let doc = MarkdownParser.parse(text)
      let ns = text as NSString

      // Bold cell: monospaced (the table font) AND bold — the cell is an inline container,
      // so the same pass that styles a paragraph styles it.
      let bold = ns.range(of: "b").location
      let boldFont = doc.attributed.attribute(.font, at: bold, effectiveRange: nil) as? NSFont
      #expect(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
      #expect(boldFont?.fontName.contains("Mono") == true)
      #expect(doc.attributed.attribute(.markdownSyntax, at: bold - 1, effectiveRange: nil) != nil)

      // Inline code cell: a chip marker on the content, backticks hidden syntax.
      let ticks = ns.range(of: "`c`").location
      #expect(
        doc.attributed.attribute(.markdownInlineCode, at: ticks + 1, effectiveRange: nil) != nil)
      #expect(doc.attributed.attribute(.markdownSyntax, at: ticks, effectiveRange: nil) != nil)

      #expect(doc.attributed.string == text)
    }

    // MARK: - Column alignment (`|:---:|`, `|---:|`)

    @Test func columnAlignmentIsHonored() {
      // Column 0 right-aligned, column 1 centered. Column 0's widest cell is "eee" and
      // column 1's is "bbb" (in the header), so both columns are three characters wide.
      let text = "| a | bbb |\n|---:|:---:|\n| eee | f |"
      let doc = MarkdownParser.parse(text)
      let s = stack(text)
      let lm = s.lm
      let pad = MarkdownMetrics.standard.tableCellPadding
      let advance = TableColumnLayout.advance(
        of: 0x61,
        in: NSFont.monospacedSystemFont(
          ofSize: MarkdownMetrics.standard.codeFontSize, weight: .regular))
      let columnWidth = 3 * advance

      // Body row: "eee" fills column 0 exactly, so right alignment is a no-op there; "f" is
      // one character centred inside a three-character column.
      let bodyStart = lineStart(text, 2)
      let eee = x(of: bodyStart + 2, lm: lm)!
      #expect(abs(eee - pad) < 0.4)
      let f = x(of: bodyStart + 8, lm: lm)!
      let centred = pad + columnWidth + 2 * pad + (columnWidth - advance) / 2
      #expect(abs(f - centred) < 0.5)

      // Header row: "a" is one character right-aligned in a three-character column, so it
      // lands two characters in; "bbb" fills column 1 exactly.
      let a = x(of: 2, lm: lm)!
      #expect(abs(a - (pad + 2 * advance)) < 0.4)
      let bbb = x(of: 6, lm: lm)!
      #expect(abs(bbb - (pad + columnWidth + 2 * pad)) < 0.4)
      #expect(doc.attributed.string == text)
    }

    // MARK: - Source mode

    @Test func sourceModeTableIsRawMarkdown() {
      let text = "| a | b |\n|---|---|\n| 1 | 2 |"
      let doc = MarkdownParser.parse(text, sourceModeTables: [0])
      let ns = text as NSString

      // No grid: no grid lines, no kerns, and the pipes go back to being caret-revealed
      // line commands (today's rendering, which is what you edit).
      #expect(doc.attributed.attribute(.markdownTableGrid, at: 0, effectiveRange: nil) == nil)
      #expect(doc.attributed.attribute(.kern, at: 1, effectiveRange: nil) == nil)
      #expect(doc.attributed.attribute(.markdownLineCommand, at: 0, effectiveRange: nil) != nil)

      // The separator row keeps the full-size font so it stays comfortable to edit.
      let sep = ns.range(of: "|---").location
      let sepFont = doc.attributed.attribute(.font, at: sep, effectiveRange: nil) as? NSFont
      #expect(sepFont?.pointSize == MarkdownMetrics.standard.codeFontSize)
      #expect(doc.attributed.string == text)
    }

    @Test func sourceModeIsPerTable() {
      let text = "| a | b |\n|---|---|\n| 1 | 2 |\n\n| c | d |\n|---|---|\n| 3 | 4 |"
      let doc = MarkdownParser.parse(text, sourceModeTables: [1])
      let ns = text as NSString
      let second = ns.range(of: "| c | d |").location

      // Table 0 is still a grid…
      #expect(doc.attributed.attribute(.markdownTableGrid, at: 0, effectiveRange: nil) != nil)
      // …while table 1 is raw markdown: no grid, no kerns, and its ordinal is still
      // attached so the editor can tell when the caret leaves it.
      #expect(
        doc.attributed.attribute(.markdownTableGrid, at: second, effectiveRange: nil) == nil)
      #expect(doc.attributed.attribute(.kern, at: second, effectiveRange: nil) == nil)
      #expect(
        (doc.attributed.attribute(.markdownTableOrdinal, at: second, effectiveRange: nil)
          as? NSNumber)?.intValue == 1)
      #expect(doc.attributed.string == text)
    }

    @Test func gridModeKeepsCaretOutsideTableStable() {
      // Moving the caret away from the table must not change any row's geometry: a grid
      // mode table has no caret-dependent attribute at all.
      let text = "| a | bbb |\n|---|---|\n| cc | d |\ntail"
      let s = stack(text)
      let storage = s.storage
      let lm = s.lm
      let tail = (text as NSString).range(of: "tail").location
      let body = lineContentIndex(text, line: 2, cell: 0)
      let before = x(of: body, lm: lm)
      relayout(lm, caret: tail, storage: storage)
      let after = x(of: body, lm: lm)
      #expect(before != nil)
      #expect(abs((before ?? 0) - (after ?? 0)) < 0.01)
    }

    // MARK: - Drawn grid geometry

    @Test func drawnGridAlignsWithTheText() {
      // The drawn grid must coincide with the aligned text — including the container's
      // lineFragmentPadding (glyph x and line-fragment x are offset by it, while the
      // parser's grid values are relative to the container's left edge). Drawn for real,
      // offscreen, so the geometry the layout manager computes is exercised.
      let text = "| a | bbb |\n|---|---|\n| cc | d |\ntail"
      let s = stack(text, padding: 5)
      let lm = s.lm
      let container = s.container
      let attributed: NSAttributedString = s.storage
      // Park the caret outside the table: the corner toggle is hidden while the caret is on
      // the header line (editing the header), exactly like the code-block chrome.
      lm.activeCharacterRange = NSRange(location: s.storage.length, length: 0)

      let canvas = NSImage(size: NSSize(width: 600, height: 400))
      canvas.lockFocus()
      lm.drawBackground(
        forGlyphRange: lm.glyphRange(
          forCharacterRange: NSRange(location: 0, length: s.storage.length),
          actualCharacterRange: nil),
        at: .zero)
      canvas.unlockFocus()

      let grid = gridXs(attributed)
      let pad = MarkdownMetrics.standard.tableCellPadding
      #expect(grid.count == 3)

      // Every column's text sits exactly `tableCellPadding` right of its grid line — the
      // same offset on both sides of the padding.
      for cell in [0, 1] {
        let idx = lineContentIndex(text, line: 0, cell: cell)
        guard let px = x(of: idx, lm: lm) else {
          Issue.record("no glyph for cell \(cell) of row 0")
          continue
        }
        #expect(abs(px - (grid[cell] + container.lineFragmentPadding + pad)) < 0.3)
      }

      // The toggle sits at the table's top-right, on the header row — and is recorded for
      // the editor's hit test.
      #expect(lm.tableToggles.count == 1)
      guard let toggle = lm.tableToggles.first else { return }
      #expect(toggle.tableOrdinal == 0)
      let m = MarkdownMetrics.standard
      let expectedMaxX = grid.last! + container.lineFragmentPadding - m.tableToggleInset
      #expect(abs(toggle.frame.maxX - expectedMaxX) < 0.01)
      #expect(abs(toggle.frame.width - m.tableToggleSize) < 0.01)
      let sepGlyph = lm.glyphRange(
        forCharacterRange: NSRange(location: (text as NSString).range(of: "|---").location, length: 1),
        actualCharacterRange: nil)
      let sepTop = lm.lineFragmentRect(forGlyphAt: sepGlyph.location, effectiveRange: nil).minY
      #expect(toggle.frame.maxY <= sepTop + 0.5)  // above the separator row
      #expect(toggle.frame.minY >= -0.5)
    }
  }
#endif