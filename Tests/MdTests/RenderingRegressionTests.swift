#if canImport(AppKit)
  import Testing
  import AppKit
  @testable import Md

  /// Regressions for visible rendering defects: each test pins one behavior that was
  /// wrong on screen (dead buttons, misaligned indents, gaps, unstyled markup).
  @Suite @MainActor struct RenderingRegressionTests {
    /// A text view hosted in a (never shown) window and sized, so layout and drawing run.
    private func hostedEditor(_ text: String?, width: CGFloat = 560, appearance: NSAppearance.Name = .aqua)
      -> (NSWindow, EditorTextView)
    {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: appearance)
      let tv = EditorTextView(metrics: .standard)
      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
      scroll.documentView = tv
      window.contentView = scroll
      tv.frame = NSRect(x: 0, y: 0, width: width, height: 900)
      if let text { tv.setText(text) }
      tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
      tv.layoutManager?.ensureLayout(for: tv.textContainer!)
      return (window, tv)
    }

    private func paragraph(_ attributed: NSAttributedString, at index: Int) -> NSParagraphStyle? {
      attributed.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    }

    /// Copy and the table toggle were cached by the LAST draw pass, so a partial redraw
    /// elsewhere (typing in another paragraph) emptied them and the buttons went dead.
    @Test func buttonsSurviveAPartialRedraw() {
      let (window, tv) = hostedEditor(nil)
      defer { _ = window }
      let top = NSRect(x: 0, y: 0, width: 560, height: 60)
      let rep = tv.bitmapImageRepForCachingDisplay(in: top)!
      tv.cacheDisplay(in: top, to: rep)
      let lm = tv.layoutManager as! EditorLayoutManager
      #expect(lm.copyButtons(origin: tv.textContainerOrigin).count == 1)
      #expect(lm.tableToggles(origin: tv.textContainerOrigin).count == 1)
    }

    /// Wrapped list lines hang under the item's TEXT (measured marker width), and a
    /// nested item's marker sits at its parent's text — not at the literal spaces PLUS a
    /// per-level indent.
    @Test func listIndentsFollowTheDrawnMarker() {
      let md = "- parent\n  - child\n10. ten"
      let parsed = MarkdownParser.parse(md)
      let ns = md as NSString
      let font = NSFont.systemFont(ofSize: MarkdownMetrics.standard.bodyFontSize)
      let bullet = TableColumnLayout.advance(of: 0x2022, in: font)
      let space = TableColumnLayout.advance(of: 0x20, in: font)
      guard let parent = paragraph(parsed.attributed, at: 0),
        let child = paragraph(parsed.attributed, at: ns.range(of: "child").location),
        let ten = paragraph(parsed.attributed, at: ns.range(of: "ten").location)
      else {
        Issue.record("missing paragraph styles")
        return
      }
      #expect(parent.firstLineHeadIndent == 0)
      #expect(abs(parent.headIndent - (bullet + space)) < 0.01)
      #expect(abs(child.firstLineHeadIndent - parent.headIndent) < 0.01)
      #expect(abs(child.headIndent - (parent.headIndent + bullet + space)) < 0.01)
      let tenWidth = "10. ".utf16.reduce(CGFloat(0)) { $0 + TableColumnLayout.advance(of: $1, in: font) }
      #expect(abs(ten.headIndent - tenWidth) < 0.01)
      // The child's literal indentation is hidden syntax (the paragraph indent replaces it).
      let childLine = ns.range(of: "  - child").location
      #expect(parsed.attributed.attribute(.markdownSyntax, at: childLine, effectiveRange: nil) != nil)
    }

    /// A setext underline is hidden; it must not keep a heading-sized line (plus the
    /// heading's spacing on both sides) under the text.
    @Test func setextUnderlineIsSmallAndCarriesTheSpacing() {
      let md = "Title\n=====\n\nBody"
      let parsed = MarkdownParser.parse(md)
      let underline = (md as NSString).range(of: "=====").location
      let font = parsed.attributed.attribute(.font, at: underline, effectiveRange: nil) as? NSFont
      #expect(font?.pointSize == MarkdownMetrics.standard.setextUnderlineFontSize)
      #expect(paragraph(parsed.attributed, at: 0)?.paragraphSpacing == 0)
      #expect(paragraph(parsed.attributed, at: underline)?.paragraphSpacingBefore == 0)
      #expect(parsed.attributed.attribute(.markdownLineCommand, at: underline, effectiveRange: nil) != nil)
    }

    /// `> > x` hides both markers and records depth 2; `> - x` renders a bullet.
    @Test func nestedQuotesAndListsInQuotes() {
      let md = "> one\n> > two\n> - item"
      let parsed = MarkdownParser.parse(md)
      let ns = md as NSString
      let two = ns.range(of: "> > two").location
      #expect(
        (parsed.attributed.attribute(.markdownBlockquote, at: two, effectiveRange: nil) as? NSNumber)?
          .intValue == 2)
      for offset in 0..<4 {  // "> > " — every marker character is a line command
        #expect(
          parsed.attributed.attribute(.markdownLineCommand, at: two + offset, effectiveRange: nil)
            != nil)
      }
      let dash = ns.range(of: "- item").location
      #expect(parsed.attributed.attribute(.markdownBullet, at: dash, effectiveRange: nil) != nil)
      #expect(parsed.attributed.attribute(.markdownListMarker, at: dash, effectiveRange: nil) != nil)
    }

    /// Bare URLs are links; trailing punctuation is not part of them; a URL already
    /// inside a link is left alone.
    @Test func bareURLsBecomeLinks() {
      let md = "See https://apple.com. and www.example.org/x) or [https://a.com](https://b.com)"
      let parsed = MarkdownParser.parse(md)
      let ns = md as NSString
      var linkRange = NSRange()
      let url = parsed.attributed.attribute(
        .link, at: ns.range(of: "https://apple.com").location, effectiveRange: &linkRange) as? URL
      #expect(url?.absoluteString == "https://apple.com")
      #expect(linkRange == ns.range(of: "https://apple.com"))
      let www = parsed.attributed.attribute(
        .link, at: ns.range(of: "www.example.org").location, effectiveRange: &linkRange) as? URL
      #expect(www?.absoluteString == "https://www.example.org/x")
      #expect(linkRange.length == ("www.example.org/x" as NSString).length)
      let inner = parsed.attributed.attribute(
        .link, at: ns.range(of: "https://a.com").location, effectiveRange: nil) as? URL
      #expect(inner?.absoluteString == "https://b.com")
    }

    /// A grid table wider than the container falls back to raw markdown (pipes
    /// visible), and returns to the grid when the editor is widened.
    @Test func tooWideTableFallsBackToRawAndRecovers() {
      let md = "| a | b |\n|---|---|\n| long cell content that is quite wide | 12345 |"
      let narrow = MarkdownParser.parse(md, maxTableWidth: 100)
      #expect(narrow.attributed.attribute(.markdownTableGrid, at: 0, effectiveRange: nil) == nil)
      #expect(narrow.attributed.attribute(.markdownSyntax, at: 0, effectiveRange: nil) == nil)
      #expect(narrow.attributed.attribute(.markdownTableOrdinal, at: 0, effectiveRange: nil) != nil)
      let wide = MarkdownParser.parse(md, maxTableWidth: 2000)
      #expect(wide.attributed.attribute(.markdownTableGrid, at: 0, effectiveRange: nil) != nil)

      let (window, tv) = hostedEditor(md, width: 220)
      defer { _ = window }
      #expect(tv.textStorage?.attribute(.markdownTableGrid, at: 0, effectiveRange: nil) == nil)
      tv.setFrameSize(NSSize(width: 1200, height: tv.frame.height))
      #expect(tv.textStorage?.attribute(.markdownTableGrid, at: 0, effectiveRange: nil) != nil)
    }

    /// Code colors follow the VIEW's appearance, not the app's.
    @Test func codePaletteFollowsTheViewAppearance() {
      let md = "```swift\nlet a = 10\n```"
      let tenIndex = (md as NSString).range(of: "10").location
      func numberColor(_ name: NSAppearance.Name) -> NSColor? {
        let (window, tv) = hostedEditor(md, appearance: name)
        defer { _ = window }
        return tv.textStorage?.attribute(.foregroundColor, at: tenIndex, effectiveRange: nil)
          as? NSColor
      }
      let light = numberColor(.aqua)
      let dark = numberColor(.darkAqua)
      #expect(light == NSColor.hex(CodeColorScheme.githubLight.number))
      #expect(dark == NSColor.hex(CodeColorScheme.githubDark.number))
    }

    /// The layout manager draws with the editor's own metrics.
    @Test func layoutManagerUsesTheEditorMetrics() {
      var custom = MarkdownMetrics()
      custom.quoteBarWidth = 9
      let tv = EditorTextView(metrics: custom)
      #expect((tv.layoutManager as? EditorLayoutManager)?.metrics.quoteBarWidth == 9)
      custom.headingSizes = [40, 30, 20, 16, 14, 12]
      let parsed = MarkdownParser.parse("# Big", style: MarkdownStyleSpec(metrics: custom))
      #expect((parsed.attributed.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize == 40)
    }

    /// The inline-code chip hugs the code font, not the whole (spacing-padded) line.
    @Test func inlineCodeChipHugsTheText() {
      final class Recorder: EditorLayoutManagerCore {
        var chips: [CGRect] = []
        override func drawInlineCodeChipHook(chip: CGRect, radius: CGFloat) { chips.append(chip) }
      }
      let storage = NSTextStorage(attributedString: MarkdownParser.parse("# Title `code`").attributed)
      let lm = Recorder()
      storage.addLayoutManager(lm)
      let container = NSTextContainer(size: NSSize(width: 600, height: 1000))
      lm.addTextContainer(container)
      lm.ensureLayout(for: container)
      let image = NSImage(size: NSSize(width: 600, height: 200))
      image.lockFocus()
      lm.drawBackground(forGlyphRange: lm.glyphRange(for: container), at: .zero)
      image.unlockFocus()
      guard let chip = lm.chips.first,
        let font = storage.attribute(.font, at: 9, effectiveRange: nil) as? NSFont
      else {
        Issue.record("no chip drawn")
        return
      }
      let expected = font.ascender - font.descender + MarkdownMetrics.standard.inlineCodeChipVInset * 2
      #expect(abs(chip.height - expected) < 0.01)
      let fragment = lm.lineFragmentRect(forGlyphAt: 9, effectiveRange: nil)
      let baseline = fragment.minY + lm.location(forGlyphAt: 9).y
      #expect(chip.minY < baseline - font.ascender + 0.01)
      #expect(chip.maxY > baseline - font.descender - 0.01)
    }
  }
#endif
