import Testing
import AppKit
import MdCode
@testable import Md

// MARK: - Parser + layout + parser-integration tests
//
// Ported from Sources/Md/SelfTest.swift (runAndExit / codeHighlightTests). The
// layout probes construct EditorLayoutManager + NSTextStorage + NSTextContainer
// and measure usedRect / lineFragmentRect headlessly (no window needed) — they
// are the regression suite for TextKit bugs (zero-width hidden commands, line
// breaking, heading line height, list markers, caret-span widths, checkbox
// slots, code-run merging).

@Suite struct ParserTests {

    /// The parser colors fenced code with `MarkdownStyle.codeScheme` =
    /// `CodeColorScheme.systemAware`, which resolves from the CURRENT DRAWING
    /// appearance. Headless `swift test` defaults to darkAqua, so the original
    /// (app-run, light-appearance) assertions compared against githubLight would
    /// fail. Run color-comparison bodies under an aqua drawing appearance so
    /// `systemAware` resolves to githubLight, matching the original intent.
    private func withLightAppearance(_ body: () -> Void) {
        guard let aqua = NSAppearance(named: .aqua) else { return body() }
        aqua.performAsCurrentDrawingAppearance(body)
    }

    // MARK: - Task 4: blocks

    @Test func emptyAndSampleDoc() {
        #expect(MarkdownParser.parse("", style: .standard).blocks.isEmpty)
        let sample = MarkdownParser.parse(SampleDocument.text, style: .standard)
        #expect(sample.attributed.length >= 0)
    }

    @Test func headings() {
        #expect(MarkdownParser.parse("## Hi").blocks == [.heading(level: 2, text: "Hi")])
        let h = MarkdownParser.parse("# Hi").attributed
        #expect(h.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil)
        #expect((h.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.pointSize == 28)
        #expect(MarkdownParser.parse("Title\n===").blocks == [.heading(level: 1, text: "Title")])
        #expect(MarkdownParser.parse("Title\n---").blocks == [.heading(level: 2, text: "Title")])
    }

    @Test func horizontalRules() {
        #expect(MarkdownParser.parse("---").blocks == [.rule])
        #expect(MarkdownParser.parse("***").syntaxRanges.first?.length == 3)
    }

    @Test func blockquotes() {
        #expect(MarkdownParser.parse("> quote").blocks == [.blockquote("quote")])
        #expect(MarkdownParser.parse("> quote").syntaxRanges.count == 1)
        #expect(MarkdownParser.parse("> quote").attributed.attribute(.markdownBlockquote, at: 0, effectiveRange: nil) != nil)
        let qa2 = MarkdownParser.parse("> a\n> b").attributed
        #expect(qa2.attribute(.markdownBlockquote, at: 0, effectiveRange: nil) != nil
            && qa2.attribute(.markdownBlockquote, at: 3, effectiveRange: nil) != nil   // the newline
            && qa2.attribute(.markdownBlockquote, at: 4, effectiveRange: nil) != nil)
        #expect(MarkdownParser.parse("plain").attributed.attribute(.markdownBlockquote, at: 0, effectiveRange: nil) == nil)
        #expect(MarkdownStyle.standard.quoteBarColor == .systemRed)
    }

    @Test func paragraph() {
        #expect(MarkdownParser.parse("a\nb").blocks == [.paragraph("a\nb")])
    }

    @Test func verbatimInvariantBattery() {
        // The parser never synthesizes characters: output string == input.
        #expect(["# Hi\n", "a\nb\n\n> q\n\n---\n", "Title\n===\n", "## A\nplain\n> quote\nx", ""]
            .allSatisfy { MarkdownParser.parse($0).attributed.string == $0 })
    }

    // MARK: - Task 5: inline styling

    @Test func inlineBoldItalicStrike() {
        let b = MarkdownParser.parse("**x**").attributed
        #expect((b.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(b.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil
            && b.attribute(.markdownSyntax, at: 4, effectiveRange: nil) != nil)
        let ital = MarkdownParser.parse("*x*").attributed
        #expect((ital.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        let both = MarkdownParser.parse("***x***").attributed
        #expect((both.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true
            && (both.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        let strike = MarkdownParser.parse("~~x~~").attributed
        #expect(strike.attribute(.strikethroughStyle, at: 2, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test func inlineCodeChips() {
        let code = MarkdownParser.parse("`x`").attributed
        #expect((code.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)?.fontName.contains("Mono") == true)
        // Inline code content is marked .markdownInlineCode (the layout manager draws
        // a rounded chip) — NOT .backgroundColor (a flat rect can't round corners).
        #expect(code.attribute(.markdownInlineCode, at: 1, effectiveRange: nil) != nil)
        #expect(code.attribute(.backgroundColor, at: 1, effectiveRange: nil) == nil)
        #expect(code.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil)
        // Inline code CONTENT must never be marked syntax — it stays visible when the
        // caret is outside the span (only the backtick delimiters collapse). Regression
        // for: cmark leaves have no children, so markGaps used to mark the whole span.
        #expect(code.attribute(.markdownSyntax, at: 1, effectiveRange: nil) == nil)
    }

    @Test func doubleBacktickSpans() {
        let code2 = MarkdownParser.parse("``a`b``").attributed
        #expect((code2.attribute(.markdownCommandSpan, at: 3, effectiveRange: nil) as? NSValue)?.rangeValue == NSRange(location: 0, length: 7))
        #expect(code2.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil
            && code2.attribute(.markdownSyntax, at: 5, effectiveRange: nil) != nil)
        #expect(code2.attribute(.markdownSyntax, at: 3, effectiveRange: nil) == nil)
    }

    @Test func twoInlineCodeChipsSeparate() {
        // Two adjacent inline-code spans must stay TWO separate chips (the draw loop
        // merges only contiguous sub-runs belonging to the SAME span; a gap between
        // spans starts a new run).
        let twoSpans = MarkdownParser.parse("`a` `b`").attributed
        var chipRuns: [NSRange] = []
        twoSpans.enumerateAttribute(.markdownInlineCode, in: NSRange(location: 0, length: twoSpans.length), options: []) { value, range, _ in
            if value != nil { chipRuns.append(range) }
        }
        #expect(chipRuns.count == 2)
        #expect(chipRuns.first == NSRange(location: 1, length: 1))
        #expect(chipRuns.last == NSRange(location: 5, length: 1))
    }

    @Test func inlineEscapes() {
        let esc = MarkdownParser.parse("\\*x\\*").attributed
        #expect(esc.string == "\\*x\\*")
        #expect(esc.attribute(.markdownSyntax, at: 1, effectiveRange: nil) == nil)
        #expect(esc.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil)
        #expect(["**b** and *i* and `c` and ~~s~~ and \\*x\\*", "a ** b ** c", "emoji 🎉 *ok*", "# **bold heading**"]
            .allSatisfy { MarkdownParser.parse($0).attributed.string == $0 })
    }

    // MARK: - Task 6: lists and task lists

    @Test func lists() {
        let ul = MarkdownParser.parse("- a\n- b")
        #expect(ul.blocks == [.unorderedList(items: [.init(text: "a", level: 0), .init(text: "b", level: 0)], level: 0)])
        #expect(ul.syntaxRanges.count == 2)
        let nested = MarkdownParser.parse("- a\n  - b")
        #expect(nested.blocks.first.map { if case .unorderedList(let items, _) = $0 { return items[1].level } else { return -1 } } == 1)
        let ol = MarkdownParser.parse("1. a\n2. b")
        #expect(ol.blocks == [.orderedList(items: [.init(text: "a", level: 0), .init(text: "b", level: 0)], level: 0)])
        let task = MarkdownParser.parse("- [x] done\n- [ ] todo")
        #expect(task.blocks == [.taskList(items: [.init(text: "done", checked: true, level: 0), .init(text: "todo", checked: false, level: 0)])])
        #expect(task.attributed.attribute(.markdownCheckbox, at: 3, effectiveRange: nil) as? Bool == true)
        #expect(task.attributed.attribute(.markdownCheckbox, at: 14, effectiveRange: nil) as? Bool == false)
        #expect(["- a\n- b", "- [x] done\n- [ ] todo", "1. a\n  2. b", "* i1\n* i2\n  * i2a"]
            .allSatisfy { MarkdownParser.parse($0).attributed.string == $0 })
    }

    // MARK: - Task 7: links and images

    @Test func linksAndImages() {
        let l = MarkdownParser.parse("[x](https://a.b)").attributed
        #expect(l.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor == .linkColor)
        #expect((l.attribute(.link, at: 1, effectiveRange: nil) as? URL)?.absoluteString == "https://a.b")
        #expect(l.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil
            && l.attribute(.markdownSyntax, at: 6, effectiveRange: nil) != nil)
        let img = MarkdownParser.parse("![alt](https://a.b/c.png)").attributed
        #expect((img.attribute(.markdownImage, at: 2, effectiveRange: nil) as? URL)?.absoluteString == "https://a.b/c.png")
        #expect(img.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil)
        #expect(["[x](https://a.b) t", "![alt](u) and [l](v)", "not a [link", "[a] (b)", "![broken](x"]
            .allSatisfy { MarkdownParser.parse($0).attributed.string == $0 })
    }

    // MARK: - Task 8: fenced code blocks

    @Test func fencedCodeBlocks() {
        let f = MarkdownParser.parse("```swift\nlet x = 1\n```")
        #expect(f.blocks == [.codeFence(language: "swift", code: "let x = 1\n")])
        #expect(f.syntaxRanges.count == 2)
        #expect(f.attributed.attribute(.markdownCodeBlock, at: 11, effectiveRange: nil) != nil)
        let fu = MarkdownParser.parse("~~~\ncode\n~~~")
        #expect(fu.blocks == [.codeFence(language: "", code: "code\n")])
        let unclosed = MarkdownParser.parse("```\nno close")
        #expect(unclosed.blocks == [.codeFence(language: "", code: "no close\n")])
        #expect(["```swift\nlet x = 1\n```", "```\nno close", "~~~\n**not bold**\n~~~", "a\n```\nb\n```"]
            .allSatisfy { MarkdownParser.parse($0).attributed.string == $0 })
    }

    // MARK: - Task 9: tables

    @Test func tables() {
        let t = MarkdownParser.parse("| a | b |\n|---|---|\n| 1 | 2 |")
        #expect(t.blocks == [.table(header: ["a", "b"], rows: [["1", "2"]], alignments: [.left, .left])])
        #expect(t.syntaxRanges.count >= 4)
        let ta = MarkdownParser.parse("| a | b |\n|:---|---:|\n| 1 | 2 |")
        var aligns: [MarkdownParser.Alignment] = []
        if case .table(_, _, let a)? = ta.blocks.first { aligns = a }
        #expect(aligns == [.left, .right])
        #expect((t.attributed.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect((t.attributed.attribute(.font, at: 13, effectiveRange: nil) as? NSFont)?.fontName.contains("Mono") == true)
        #expect(["| a | b |\n|---|---|\n| 1 | 2 |", "a | b\n---|---\n1 | 2", "|x|y|\n|:-|-:|\n|1|2|", "no | pipe here"]
            .allSatisfy { MarkdownParser.parse($0).attributed.string == $0 })
    }

    // MARK: - Task 11/12: feature attrs and sample document

    @Test func featureAttributes() {
        #expect(MarkdownParser.parse("---").attributed.attribute(.markdownRule, at: 0, effectiveRange: nil) != nil)
    }

    @Test func sampleDocument() {
        let sd = MarkdownParser.parse(SampleDocument.text)
        #expect(sd.attributed.string == SampleDocument.text)
        #expect(sd.blocks.filter { if case .heading = $0 { return true } else { return false } }.count == 4)
        #expect(sd.blocks.contains { if case .taskList = $0 { return true } else { return false } })
        #expect(sd.blocks.contains { if case .codeFence = $0 { return true } else { return false } })
        #expect(sd.blocks.contains { if case .table = $0 { return true } else { return false } })
        #expect(sd.syntaxRanges.count > 10)
    }

    // MARK: - Task 13: zero-width hidden commands (layout-level)

    @Test func zeroWidthHiddenCommands() {
        // Real path: syntax attributes + activeCharacterRange drive the substitution.
        let zwDoc = MarkdownParser.parse("# Hi\nplain").attributed.mutableCopy() as! NSMutableAttributedString
        let zwStorage = NSTextStorage(attributedString: zwDoc)
        let zwLM = EditorLayoutManager()
        zwStorage.addLayoutManager(zwLM)
        let zwContainer = NSTextContainer(size: NSSize(width: 600, height: 2000))
        zwLM.addTextContainer(zwContainer)
        // Caret on line 2 ("plain") → line 1's "# " is hidden (zero width)
        zwLM.activeCharacterRange = NSRange(location: 5, length: 5)
        zwLM.ensureLayout(for: zwContainer)
        let wHidden = zwLM.usedRect(for: zwContainer).width
        // Caret on line 1 → nothing hidden
        zwLM.activeCharacterRange = NSRange(location: 0, length: 4)
        zwLM.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: 10), changeInLength: 0, actualCharacterRange: nil)
        zwLM.invalidateLayout(forCharacterRange: NSRange(location: 0, length: 10), actualCharacterRange: nil)
        zwLM.ensureLayout(for: zwContainer)
        let wShown = zwLM.usedRect(for: zwContainer).width
        #expect(wHidden < wShown - 5)
    }

    @Test func newlineFragmentsAndZeroWidthGlyph() {
        // Regression: "Hello" + Return + "Hello" rendered as "Hello" / "ello" in the
        // LIVE view (fragment 1 absorbed the second line's 'H'). Headless check: the
        // plain two-line doc must break into [0,6) and [6,11) — the newline ends line 1.
        let nlDoc = MarkdownParser.parse("Hello" + String(UnicodeScalar(10)) + "Hello", style: .standard).attributed
        let nlStorage = NSTextStorage(attributedString: nlDoc)
        let nlLM = EditorLayoutManager()
        nlStorage.addLayoutManager(nlLM)
        let nlContainer = NSTextContainer(size: NSSize(width: 600, height: 2000))
        nlLM.addTextContainer(nlContainer)
        nlLM.ensureLayout(for: nlContainer)
        var nlFrags: [NSRange] = []
        nlLM.enumerateLineFragments(forGlyphRange: nlLM.glyphRange(forCharacterRange: NSRange(location: 0, length: nlStorage.length), actualCharacterRange: nil)) { _, _, _, glyphRange, _ in
            nlFrags.append(glyphRange)
        }
        #expect(nlFrags.count == 2 && nlFrags[0] == NSRange(location: 0, length: 6) && nlFrags[1] == NSRange(location: 6, length: 5))
        // Font zero-advance glyph availability (for the ZWSP substitution fix)
        var sfHasZeroWidth = false
        for font in [NSFont.systemFont(ofSize: 15),
                     NSFont.systemFont(ofSize: 20, weight: .semibold),
                     NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)] {
            var found: [String] = []
            for char in [0x200B, 0x2060, 0xFEFF] {
                var ch: [UniChar] = [UniChar(char)]
                var gl = [CGGlyph](repeating: 0, count: 1)
                CTFontGetGlyphsForCharacters(font as CTFont, &ch, &gl, 1)
                var adv = [CGSize](repeating: .zero, count: 1)
                CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, gl, &adv, 1)
                if gl[0] != 0 { found.append("U+\(String(format: "%04X", char)) g=\(gl[0]) adv=\(adv[0].width)") }
            }
            if found.contains(where: { $0.hasSuffix("adv=0.0") }) { sfHasZeroWidth = true }
        }
        #expect(sfHasZeroWidth)
    }

    @Test func headingHeightStable() {
        let hdDoc = MarkdownParser.parse("### Task list\nplain").attributed.mutableCopy() as! NSMutableAttributedString
        let hdStorage = NSTextStorage(attributedString: hdDoc)
        let hdLM = EditorLayoutManager()
        hdStorage.addLayoutManager(hdLM)
        let hdContainer = NSTextContainer(size: NSSize(width: 600, height: 2000))
        hdLM.addTextContainer(hdContainer)
        func headingHeight(activeRange: NSRange, invalidateRange: NSRange) -> CGFloat {
            hdLM.activeCharacterRange = activeRange
            hdLM.invalidateGlyphs(forCharacterRange: invalidateRange, changeInLength: 0, actualCharacterRange: nil)
            hdLM.invalidateLayout(forCharacterRange: invalidateRange, actualCharacterRange: nil)
            hdLM.ensureLayout(for: hdContainer)
            let glyphRange = hdLM.glyphRange(forCharacterRange: NSRange(location: 0, length: 11), actualCharacterRange: nil)
            return hdLM.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil).height
        }
        let wholeDoc = NSRange(location: 0, length: hdStorage.length)
        let headingLine = NSRange(location: 0, length: 11)
        let hInactive = headingHeight(activeRange: NSRange(location: 12, length: 5), invalidateRange: wholeDoc) // caret on "plain"
        _ = headingHeight(activeRange: NSRange(location: 0, length: 11), invalidateRange: wholeDoc)
        let hActiveLineOnly = headingHeight(activeRange: NSRange(location: 0, length: 11), invalidateRange: headingLine)
        #expect(abs(hInactive - hActiveLineOnly) < 0.5)
    }

    // MARK: - Task 14: list markers always visible

    @Test func listMarkers() {
        let lmDoc = MarkdownParser.parse("- a\n1. b\n- [x] c")
        #expect(lmDoc.attributed.attribute(.markdownListMarker, at: 0, effectiveRange: nil) != nil)
        #expect(lmDoc.attributed.attribute(.markdownListMarker, at: 4, effectiveRange: nil) != nil)
        #expect(lmDoc.attributed.attribute(.markdownListMarker, at: 9, effectiveRange: nil) != nil)
        let lmDoc2 = MarkdownParser.parse("- a").attributed
        let lmStorage2 = NSTextStorage(attributedString: lmDoc2)
        let lmLM2 = EditorLayoutManager()
        lmStorage2.addLayoutManager(lmLM2)
        let lmC2 = NSTextContainer(size: NSSize(width: 600, height: 2000))
        lmLM2.addTextContainer(lmC2)
        lmLM2.activeCharacterRange = NSRange(location: 999, length: 0) // no active line — marker must stay
        lmLM2.ensureLayout(for: lmC2)
        let wMarker = lmLM2.usedRect(for: lmC2).width
        #expect(wMarker > 14)
    }

    // MARK: - Task 15: caret-range command visibility

    @Test func commandSpanAttributes() {
        // Inline commands get a full span (opening through closing delimiter); the
        // delimiters show while the caret is inside the span. Block commands (#, >,
        // fences, table pipes) are line-commands: shown while the caret is on the line.
        let bs = MarkdownParser.parse("**bold** and **more**").attributed
        #expect((bs.attribute(.markdownCommandSpan, at: 0, effectiveRange: nil) as? NSValue)?.rangeValue == NSRange(location: 0, length: 8))
        #expect((bs.attribute(.markdownCommandSpan, at: 3, effectiveRange: nil) as? NSValue)?.rangeValue == NSRange(location: 0, length: 8))
        #expect((bs.attribute(.markdownCommandSpan, at: 14, effectiveRange: nil) as? NSValue)?.rangeValue == NSRange(location: 13, length: 8))
        #expect(bs.attribute(.markdownLineCommand, at: 0, effectiveRange: nil) == nil)
        let hd2 = MarkdownParser.parse("# Hi").attributed
        #expect(hd2.attribute(.markdownLineCommand, at: 0, effectiveRange: nil) != nil)
        #expect(hd2.attribute(.markdownCommandSpan, at: 0, effectiveRange: nil) == nil)
        let codeSpan = MarkdownParser.parse("a `code` b").attributed
        #expect((codeSpan.attribute(.markdownCommandSpan, at: 4, effectiveRange: nil) as? NSValue)?.rangeValue == NSRange(location: 2, length: 6))
        let linkSpan = MarkdownParser.parse("[t](https://a.b)").attributed
        #expect((linkSpan.attribute(.markdownCommandSpan, at: 1, effectiveRange: nil) as? NSValue)?.rangeValue == NSRange(location: 0, length: 16))
    }

    @Test func inlineDelimitersShowWhenCaretInsideSpan() {
        // Layout-level: caret INSIDE a bold span → delimiters keep their width;
        // caret outside → they collapse to zero width.
        let csDoc = MarkdownParser.parse("**bold** x").attributed.mutableCopy() as! NSMutableAttributedString
        let csStorage = NSTextStorage(attributedString: csDoc)
        let csLM = EditorLayoutManager()
        csStorage.addLayoutManager(csLM)
        let csContainer = NSTextContainer(size: NSSize(width: 600, height: 2000))
        csLM.addTextContainer(csContainer)
        func spanWidth(caret: Int) -> CGFloat {
            csLM.activeCharacterRange = NSRange(location: caret, length: 0)
            csLM.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: csStorage.length), changeInLength: 0, actualCharacterRange: nil)
            csLM.invalidateLayout(forCharacterRange: NSRange(location: 0, length: csStorage.length), actualCharacterRange: nil)
            csLM.ensureLayout(for: csContainer)
            return csLM.usedRect(for: csContainer).width
        }
        let wInside = spanWidth(caret: 4)   // inside "bold"
        let wOutside = spanWidth(caret: 9)  // on the space, outside the span
        #expect(wInside > wOutside + 5)
    }

    // MARK: - Task 16: uniform checkbox slot

    @Test func checkboxSlotUniformWidth() {
        // "[x]" and "[ ]" must occupy the same width (the literal 'x' is wider than
        // a space, which made checked rows wider than unchecked ones). The middle
        // glyph is substituted with EN SPACE so both states match.
        let cbDoc = MarkdownParser.parse("- [x] done\n- [ ] done").attributed.mutableCopy() as! NSMutableAttributedString
        let cbStorage = NSTextStorage(attributedString: cbDoc)
        let cbLM = EditorLayoutManager()
        cbStorage.addLayoutManager(cbLM)
        let cbContainer = NSTextContainer(size: NSSize(width: 600, height: 2000))
        cbLM.addTextContainer(cbContainer)
        cbLM.ensureLayout(for: cbContainer)
        let cbNs = cbDoc.string as NSString
        func cbRowWidth(_ startIdx: Int) -> CGFloat {
            let lineRange = cbNs.lineRange(for: NSRange(location: startIdx, length: 0))
            let g = cbLM.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var w: CGFloat = 0
            cbLM.enumerateLineFragments(forGlyphRange: g) { _, used, _, _, _ in w = max(w, used.width) }
            return w
        }
        let cbCheckedW = cbRowWidth(0)
        let cbUncheckedW = cbRowWidth(10)
        #expect(abs(cbCheckedW - cbUncheckedW) < 0.5)
    }

    // MARK: - Task 17: smart list continuation (Return keeps/prepends the marker)

    @Test func listContinuations() {
        #expect(MarkdownParser.listContinuation(for: "- item") == MarkdownParser.ListContinuation(marker: "- ", empty: false))
        #expect(MarkdownParser.listContinuation(for: "* item") == MarkdownParser.ListContinuation(marker: "* ", empty: false))
        #expect(MarkdownParser.listContinuation(for: "+ item") == MarkdownParser.ListContinuation(marker: "+ ", empty: false))
        #expect(MarkdownParser.listContinuation(for: "  - item") == MarkdownParser.ListContinuation(marker: "  - ", empty: false))
        #expect(MarkdownParser.listContinuation(for: "1. item") == MarkdownParser.ListContinuation(marker: "2. ", empty: false))
        #expect(MarkdownParser.listContinuation(for: "10) item") == MarkdownParser.ListContinuation(marker: "11) ", empty: false))
        #expect(MarkdownParser.listContinuation(for: "- [ ] todo") == MarkdownParser.ListContinuation(marker: "- [ ] ", empty: false))
        #expect(MarkdownParser.listContinuation(for: "- [x] done") == MarkdownParser.ListContinuation(marker: "- [x] ", empty: false))
        #expect(MarkdownParser.listContinuation(for: "  - [x] done") == MarkdownParser.ListContinuation(marker: "  - [x] ", empty: false))
        #expect(MarkdownParser.listContinuation(for: "- ") == MarkdownParser.ListContinuation(marker: "- ", empty: true))
        #expect(MarkdownParser.listContinuation(for: "- [ ] ") == MarkdownParser.ListContinuation(marker: "- [ ] ", empty: true))
        #expect(MarkdownParser.listContinuation(for: "1.   ") == MarkdownParser.ListContinuation(marker: "2.   ", empty: true))
        #expect(MarkdownParser.listContinuation(for: "plain text") == nil)
        #expect(MarkdownParser.listContinuation(for: "# head") == nil)
        #expect(MarkdownParser.listContinuation(for: "-not a list") == nil)
    }

    @Test func quoteContinuations() {
        // Quote continuation: Return on a quote line prepends "> " to the new line;
        // a marker-only "> " line exits the quote (marker dropped).
        #expect(MarkdownParser.quoteContinuation(for: "> quoted") == MarkdownParser.ListContinuation(marker: "> ", empty: false))
        #expect(MarkdownParser.quoteContinuation(for: ">quoted") == MarkdownParser.ListContinuation(marker: "> ", empty: false))
        #expect(MarkdownParser.quoteContinuation(for: ">> deep") == MarkdownParser.ListContinuation(marker: ">> ", empty: false))
        #expect(MarkdownParser.quoteContinuation(for: "  > quoted") == MarkdownParser.ListContinuation(marker: "  > ", empty: false))
        #expect(MarkdownParser.quoteContinuation(for: "> ") == MarkdownParser.ListContinuation(marker: "> ", empty: true))
        #expect(MarkdownParser.quoteContinuation(for: ">   ") == MarkdownParser.ListContinuation(marker: ">   ", empty: true))
        #expect(MarkdownParser.quoteContinuation(for: "plain text") == nil)
        #expect(MarkdownParser.quoteContinuation(for: "# head") == nil)
    }

    // MARK: - Task 18: swift-markdown parser (regressions + new capabilities)

    @Test func swiftMarkdownRegressions() {
        // The old hand-rolled parser LOOPED FOREVER on a bare "- [ ]" (no trailing
        // space): the task-list guard matched but the full pattern did not, so the
        // group index never advanced. That input is exactly what backspacing a
        // checkbox produces. swift-markdown (cmark) cannot loop; assert clean parses.
        let bare = MarkdownParser.parse("- [ ]", style: .standard)
        #expect(bare.attributed.string == "- [ ]")
        // cmark's GFM task marker requires trailing whitespace, so "- [ ]" is a plain
        // list item holding the literal "[ ]" — it parses cleanly (the old parser
        // looped forever here) and renders as text, never crashing the editor.
        #expect(bare.blocks == [.unorderedList(items: [.init(text: "[ ]", level: 0)], level: 0)])
        #expect(MarkdownParser.parse("- [ ] ").blocks == [.taskList(items: [.init(text: "", checked: false, level: 0)])])
        let bareSpaced = MarkdownParser.parse("- [ ] \n- [x] done")
        #expect(bareSpaced.attributed.string == "- [ ] \n- [x] done")
        // Reference-style links and autolinks (new capabilities, cmark-resolved)
        let ref = MarkdownParser.parse("[x][id]\n\n[id]: https://a.b")
        #expect((ref.attributed.attribute(.link, at: 1, effectiveRange: nil) as? URL)?.absoluteString == "https://a.b")
        let auto = MarkdownParser.parse("<https://a.b>")
        #expect((auto.attributed.attribute(.link, at: 2, effectiveRange: nil) as? URL)?.absoluteString == "https://a.b")
        #expect(auto.attributed.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil
            && auto.attributed.attribute(.markdownSyntax, at: 12, effectiveRange: nil) != nil)
        // Inline HTML becomes a hidden command symbol
        let html = MarkdownParser.parse("a <b>c</b> d")
        #expect(html.attributed.attribute(.markdownSyntax, at: 2, effectiveRange: nil) != nil)
        // Verbatim battery: emoji/multibyte around inline commands, tabs, trailing
        // newline, mixed constructs — byte-column → UTF-16 conversion must be exact.
        #expect(["emoji 🎉 *ok*", "a🎉b **bold**", "line1\nline2\n", "- [ ] \n- [x] done\n\n# t\n",
                 "*i* and **b** and `c` and [l](u) and ![a](i)", "\ttab-indented\n",
                 "# h1\nplain\n\n> quote\n\n- item\n- [x] task\n\n1. one\n  1. nested\n"]
            .allSatisfy { MarkdownParser.parse($0).attributed.string == $0 })
    }

    // MARK: - Headless layout probes (TextKit regression suite)

    @Test func quoteBarGeometryHeadless() {
        // Bar geometry: the bar is drawn at x = origin.x (container left edge), while
        // the quote text keeps its 12pt paragraph indent. Headless: verify the text
        // indent is unchanged (used.minX == 12) — the bar's x is origin by construction.
        let qbDoc = MarkdownParser.parse("> a\n> b").attributed.mutableCopy() as! NSMutableAttributedString
        let qbStorage = NSTextStorage(attributedString: qbDoc)
        let qbLM = EditorLayoutManager()
        qbStorage.addLayoutManager(qbLM)
        let qbContainer = NSTextContainer(size: NSSize(width: 400, height: 2000))
        qbLM.addTextContainer(qbContainer)
        qbLM.ensureLayout(for: qbContainer)
        let qbGlyphRange = qbLM.glyphRange(forCharacterRange: NSRange(location: 0, length: qbStorage.length), actualCharacterRange: nil)
        var qbTextX: CGFloat? = nil
        var qbMinY = CGFloat.greatestFiniteMagnitude
        var qbMaxY = -CGFloat.greatestFiniteMagnitude
        qbLM.enumerateLineFragments(forGlyphRange: qbGlyphRange) { rect, used, _, _, _ in
            if qbTextX == nil { qbTextX = used.minX }          // quote text left edge
            qbMinY = min(qbMinY, rect.minY)
            qbMaxY = max(qbMaxY, rect.maxY)
        }
        #expect(qbTextX == 12)
        #expect(qbMaxY - qbMinY > 30)
    }

    @Test func mixedLineCodeChipNarrower() {
        // The chip must hug ONLY the code glyphs on a mixed line ("text `code` more"),
        // NOT the whole line fragment. Reproduces the "highlights full line" bug: the
        // line fragment's `used` rect spans the whole line; boundingRect gives just
        // the code glyphs. Assert the code's glyph bounds are narrower than the line.
        let mixedDoc = MarkdownParser.parse("text `code` more").attributed.mutableCopy() as! NSMutableAttributedString
        let mixedStorage = NSTextStorage(attributedString: mixedDoc)
        let mixedLM = EditorLayoutManager()
        mixedStorage.addLayoutManager(mixedLM)
        let mixedContainer = NSTextContainer(size: NSSize(width: 400, height: 2000))
        mixedLM.addTextContainer(mixedContainer)
        mixedLM.ensureLayout(for: mixedContainer)
        // Code content is "code" — chars 6..9 (text _code_ more).
        let codeRange = NSRange(location: 6, length: 4)
        let codeGlyphs = mixedLM.glyphRange(forCharacterRange: codeRange, actualCharacterRange: nil)
        let codeBounds = mixedLM.boundingRect(forGlyphRange: codeGlyphs, in: mixedContainer)
        var mixedLineWidth: CGFloat = 0
        mixedLM.enumerateLineFragments(forGlyphRange: mixedLM.glyphRange(forCharacterRange: NSRange(location: 0, length: mixedStorage.length), actualCharacterRange: nil)) { rect, _, _, _, _ in
            mixedLineWidth = max(mixedLineWidth, rect.width)
        }
        #expect(codeBounds.width < mixedLineWidth * 0.6)
        #expect(codeBounds.minX > 20)
    }

    // MARK: - Parser integration: fenced code spans get token colors

    @Test func highlightedFenceTokenColors() {
        withLightAppearance {
            let mdCode = "before\n\n```swift\nfunc f() { let x = 42 }   // hi https://a.b\n```\n\nafter"
            let parsed = MarkdownParser.parse(mdCode)
            #expect(parsed.attributed.string == mdCode)
            let mdNs = mdCode as NSString
            func colorAt(_ word: String) -> NSColor? {
                let loc = mdNs.range(of: word).location
                guard loc != NSNotFound else { return nil }
                return parsed.attributed.attribute(.foregroundColor, at: loc, effectiveRange: nil) as? NSColor
            }
            #expect(colorAt("func") == CodeColorScheme.githubLight.keyword)
            #expect(colorAt("42") == CodeColorScheme.githubLight.number)
            #expect(colorAt("hi") == CodeColorScheme.githubLight.comment)
            #expect(colorAt("https://a.b") == CodeColorScheme.githubLight.link)
            #expect(parsed.attributed.attribute(.underlineStyle,
                                                at: mdNs.range(of: "https://a.b").location,
                                                effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
            #expect(parsed.attributed.attribute(.underlineColor,
                                                at: mdNs.range(of: "https://a.b").location,
                                                effectiveRange: nil) as? NSColor == CodeColorScheme.githubLight.link)
            #expect(parsed.attributed.attribute(.markdownCodeBlock, at: mdNs.range(of: "func").location, effectiveRange: nil) != nil)
        }
    }

    @Test func multiLineFenceBackground() {
        // The whole fence content is ONE .markdownCodeBlock run — the interior newline
        // between code lines carries the marker, so the layout manager draws a single
        // rounded block instead of per-line tiles. Fence marker lines are background-free.
        let multiFence = "```swift\nlet a = 1\nlet b = 2\n```"
        let mf = MarkdownParser.parse(multiFence)
        let mfNs = multiFence as NSString
        let interiorNL = mfNs.range(of: "\nlet b").location
        #expect(mf.attributed.attribute(.markdownCodeBlock, at: interiorNL, effectiveRange: nil) != nil
            && mf.attributed.attribute(.markdownCodeBlock, at: interiorNL + 1, effectiveRange: nil) != nil)
        #expect(mf.attributed.attribute(.markdownCodeBlock, at: 0, effectiveRange: nil) == nil
            && mf.attributed.attribute(.markdownCodeBlock, at: mfNs.length - 2, effectiveRange: nil) == nil)
        #expect(MarkdownParser.parse("```x\na\n```").attributed.attribute(.markdownCodeBlock, at: 5, effectiveRange: nil) != nil)
    }

    @Test func codeLanguageLabel() {
        // Language label attribute for the block chrome.
        let langDoc = MarkdownParser.parse("```swift\nlet a = 1\n```")
        let ldNs = langDoc.attributed.string as NSString
        let langName = langDoc.attributed.attribute(.markdownCodeLanguage, at: ldNs.range(of: "let a").location, effectiveRange: nil) as? String
        #expect(langName == "Swift")
        let unknownLangDoc = MarkdownParser.parse("```xyz\nabc\n```")
        let ulNs = unknownLangDoc.attributed.string as NSString
        let ulName = unknownLangDoc.attributed.attribute(.markdownCodeLanguage, at: ulNs.range(of: "abc").location, effectiveRange: nil) as? String
        #expect(ulName == nil)
        #expect(langDoc.attributed.string == "```swift\nlet a = 1\n```" && unknownLangDoc.attributed.string == "```xyz\nabc\n```")
    }

    @Test func mergedCodeRuns() {
        // Draw-time merge: token-color sub-runs within one fence must collapse into a
        // single block (not a rounded rect per token), while a real gap starts a new block.
        #expect(EditorLayoutManager.mergedCodeRuns([NSRange(location: 0, length: 3),
                                                   NSRange(location: 3, length: 2),
                                                   NSRange(location: 5, length: 1)]) ==
            [NSRange(location: 0, length: 6)])
        #expect(EditorLayoutManager.mergedCodeRuns([NSRange(location: 0, length: 2),
                                                   NSRange(location: 3, length: 2)]) ==
            [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
    }

    @Test func unknownLanguageAndTwoFences() {
        withLightAppearance {
            let mdCode = "before\n\n```swift\nfunc f() { let x = 42 }   // hi https://a.b\n```\n\nafter"
            let parsed = MarkdownParser.parse(mdCode)
            let mdNs = mdCode as NSString
            func colorAt(_ word: String) -> NSColor? {
                let loc = mdNs.range(of: word).location
                guard loc != NSNotFound else { return nil }
                return parsed.attributed.attribute(.foregroundColor, at: loc, effectiveRange: nil) as? NSColor
            }
            #expect(colorAt("before") == MarkdownStyle.standard.textColor)

            let unknown = "```xyz\nfunc f()\n```"
            let un = MarkdownParser.parse(unknown)
            #expect(un.attributed.attribute(.foregroundColor, at: (unknown as NSString).range(of: "func").location,
                                            effectiveRange: nil) as? NSColor == MarkdownStyle.standard.codeTextColor)
            #expect(un.attributed.string == unknown)

            let two = "```python\nx = 1\n```\n\n```js\nconst y = 2\n```"
            let tp = MarkdownParser.parse(two)
            #expect(tp.attributed.string == two)
            let tNs = two as NSString
            let pyNum = tp.attributed.attribute(.foregroundColor, at: tNs.range(of: "x = 1").location + 4,
                                                effectiveRange: nil) as? NSColor
            let jsKw = tp.attributed.attribute(.foregroundColor, at: tNs.range(of: "const").location,
                                               effectiveRange: nil) as? NSColor
            #expect(pyNum == CodeColorScheme.githubLight.number)
            #expect(jsKw == CodeColorScheme.githubLight.keyword)
        }
    }
}
