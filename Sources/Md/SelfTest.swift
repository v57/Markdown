import AppKit
import MdCode

// MARK: - Self-test harness (CLI-verifiable TDD: `Markdown --selftest`)

@MainActor
public enum SelfTest {
    private static var passed = 0
    private static var failed = 0

    /// Reproduces the live edit sequence headlessly: sample doc → select-all+delete
    /// → type "Hello" → Return → "Hello". Mirrors the live path (storage replaces,
    /// attribute restyle, activeCharacterRange, and the textViewDidChangeSelection
    /// invalidations) and prints the line-fragment glyph ranges after every step so
    /// the step that corrupts line breaking (newline no longer ends line 1) is visible.
    public static func headlessSequenceProbe() {
        // Variant 2 (LIVE-MIRROR): the attribute restyle runs INSIDE the storage's
        // didProcessEditing callback (as reapplyMarkdown does in the text view),
        // instead of after replaceCharacters returns.
        final class RestyleDelegate: NSObject, NSTextStorageDelegate {
            var caret = 0
            var lm: EditorLayoutManager? = nil
            func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                             range editedRange: NSRange, changeInLength delta: Int) {
                guard editedMask.contains(.editedCharacters) else { return }
                let parsed = MarkdownParser.parse(textStorage.string, style: .standard)
                parsed.attributed.enumerateAttributes(in: NSRange(location: 0, length: parsed.attributed.length), options: []) { attrs, range, _ in
                    textStorage.setAttributes(attrs, range: range)   // NO begin/endEditing: fires per-run, still inside the callback
                }
                lm?.activeCharacterRange = NSRange(location: caret, length: 0)
            }
        }
        let storage2 = NSTextStorage()
        let lm2 = EditorLayoutManager()
        storage2.addLayoutManager(lm2)
        let container2 = NSTextContainer(size: NSSize(width: 600, height: 4000))
        lm2.addTextContainer(container2)
        let delegate = RestyleDelegate()
        delegate.lm = lm2
        storage2.delegate = delegate
        func step2(_ label: String) {
            lm2.ensureLayout(for: container2)
            var frags: [String] = []
            lm2.enumerateLineFragments(forGlyphRange: lm2.glyphRange(forCharacterRange: NSRange(location: 0, length: storage2.length), actualCharacterRange: nil)) { _, _, _, gr, _ in
                frags.append("[" + String(gr.location) + "," + String(NSMaxRange(gr)) + ")")
            }
            print("SEQPROBE2 " + label + " len=" + String(storage2.length) + " frags=" + frags.joined(separator: " "))
        }
        storage2.setAttributedString(NSAttributedString(string: SampleDocument.text))
        step2("sample")
        storage2.replaceCharacters(in: NSRange(location: 0, length: storage2.length), with: "")
        delegate.caret = 0
        lm2.activeCharacterRange = NSRange(location: 0, length: 0)
        step2("emptied")
        func type2(_ s: String) {
            storage2.replaceCharacters(in: NSRange(location: delegate.caret, length: 0), with: s)
            delegate.caret += (s as NSString).length
            let affected = lm2.affectedRange(for: NSRange(location: delegate.caret, length: 0))
            lm2.invalidateGlyphs(forCharacterRange: affected, changeInLength: 0, actualCharacterRange: nil)
            lm2.invalidateLayout(forCharacterRange: affected, actualCharacterRange: nil)
            step2("typed [" + s.replacingOccurrences(of: String(UnicodeScalar(10)), with: "\\n") + "]")
        }
        type2("Hello")
        type2(String(UnicodeScalar(10)))
        type2("Hello")
    }

    /// Live-view regression probe: typing "Hello" + Return + "Hello" must render
    /// BOTH lines completely. A report said the second line lost its first
    /// character ("Hello" / "ello"). Dumps storage attributes, glyph ids, the
    /// glyph-to-character mapping and fragment widths so the failure mode
    /// (parser attribute vs stale layout mapping vs draw skip) is identifiable
    /// from the log alone. Run via: Markdown --typingprobe
    public static func typingProbe() {
        headlessSequenceProbe()   // storage-level repro first (no window needed)
        guard let tv = EditorTextView.live else {
            print("TYPINGPROBE FAIL no live text view")
            NSApp.terminate(nil)
            return
        }
        func report(_ name: String, _ cond: Bool, _ extra: String = "") {
            print(String(format: "TYPINGPROBE %@ %@ %@", cond ? "PASS" : "FAIL", name, extra))
        }
        let nl = String(UnicodeScalar(10))
        let expected = "Hello" + nl + "Hello"
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        tv.deleteBackward(nil)
        tv.insertText("Hello")
        tv.insertNewline(nil)
        tv.insertText("Hello")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let storage = tv.textStorage, let lm = tv.layoutManager else {
                print("TYPINGPROBE FAIL no storage/layout")
                NSApp.terminate(nil)
                return
            }
            let ns = storage.string as NSString
            report("string verbatim", storage.string == expected,
                   String(format: "got [%@] len=%d", storage.string, ns.length))
            var syntax: [Int] = []
            for i in 0..<ns.length {
                if storage.attribute(.markdownSyntax, at: i, effectiveRange: nil) != nil { syntax.append(i) }
            }
            print(String(format: "TYPINGPROBE syntaxChars=%@", syntax))
            report("no syntax attrs in plain text", syntax.isEmpty, String(format: "%@", syntax))
            lm.ensureLayout(for: tv.textContainer!)
            let gAll = lm.glyphRange(forCharacterRange: NSRange(location: 0, length: ns.length), actualCharacterRange: nil)
            var parts: [String] = []
            var prevX: CGFloat? = nil
            var g = gAll.location
            while g < NSMaxRange(gAll) {
                let gl = lm.glyph(at: g, isValidIndex: nil)
                let ci = lm.characterIndexForGlyph(at: g)
                let loc = lm.location(forGlyphAt: g)
                let adv = prevX.map { Double(loc.x - $0) }
                parts.append(String(format: "g%d=ch%d gl%d x%.1f a%.1f", g, ci, gl, Double(loc.x), adv ?? -1))
                prevX = loc.x
                g += 1
            }
            print(String(format: "TYPINGPROBE glyphs %@", parts.joined(separator: " ")))
            var frags: [String] = []
            lm.enumerateLineFragments(forGlyphRange: gAll) { rect, used, _, glyphRange, _ in
                frags.append(String(format: "g[%d,%d) w%.1f y%.1f", glyphRange.location, NSMaxRange(glyphRange), used.width, rect.minY))
            }
            print(String(format: "TYPINGPROBE frags %@", frags.joined(separator: " ")))
            var props: [String] = []
            for g in gAll.location..<NSMaxRange(gAll) {
                props.append(String(format: "g%d=0x%X", g, lm.propertyForGlyph(at: g).rawValue))
            }
            print(String(format: "TYPINGPROBE props %@", props.joined(separator: " ")))
            var fragRanges: [NSRange] = []
            lm.enumerateLineFragments(forGlyphRange: gAll) { _, _, _, gr, _ in fragRanges.append(gr) }
            let breakOK = fragRanges.count == 2 && fragRanges[0] == NSRange(location: 0, length: 6) && fragRanges[1] == NSRange(location: 6, length: 5)
            report("second line keeps its first char", breakOK,
                   fragRanges.map { "[" + String($0.location) + "," + String(NSMaxRange($0)) + ")" }.joined(separator: " "))
            let gH1 = lm.glyphRange(forCharacterRange: NSRange(location: 0, length: 1), actualCharacterRange: nil)
            let gH2 = lm.glyphRange(forCharacterRange: NSRange(location: 6, length: 1), actualCharacterRange: nil)
            let gl1 = gH1.length > 0 ? lm.glyph(at: gH1.location, isValidIndex: nil) : 0
            let gl2 = gH2.length > 0 ? lm.glyph(at: gH2.location, isValidIndex: nil) : 0
            report("second-line H keeps its glyph", gl1 != 0 && gl1 == gl2,
                   String(format: "H gl=%d line2-H gl=%d", gl1, gl2))
            print("TYPINGPROBE done")
            NSApp.terminate(nil)
        }
    }

    public static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
            print("  PASS \(name)")
        } else {
            failed += 1
            print("  FAIL \(name) \(detail)")
        }
    }

    public static func runAndExit() -> Never {
        print("SELFTEST START")
        check("empty doc parses", MarkdownParser.parse("", style: .standard).blocks.isEmpty)
        let sample = MarkdownParser.parse(SampleDocument.text, style: .standard)
        check("sample doc parses without crash", sample.attributed.length >= 0)

        // --- Task 4: block pass ---
        check("atx heading level", MarkdownParser.parse("## Hi").blocks == [.heading(level: 2, text: "Hi")])
        let h = MarkdownParser.parse("# Hi").attributed
        check("heading syntax range marked", h.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil)
        check("heading font is big", (h.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.pointSize == 28)
        check("setext h1", MarkdownParser.parse("Title\n===").blocks == [.heading(level: 1, text: "Title")])
        check("setext h2", MarkdownParser.parse("Title\n---").blocks == [.heading(level: 2, text: "Title")])
        check("hr block", MarkdownParser.parse("---").blocks == [.rule])
        check("hr syntax", MarkdownParser.parse("***").syntaxRanges.first?.length == 3)
        check("blockquote", MarkdownParser.parse("> quote").blocks == [.blockquote("quote")])
        check("blockquote marker syntax", MarkdownParser.parse("> quote").syntaxRanges.count == 1)
        check("blockquote bar attr", MarkdownParser.parse("> quote").attributed.attribute(.markdownBlockquote, at: 0, effectiveRange: nil) != nil)
        let qa2 = MarkdownParser.parse("> a\n> b").attributed
        check("quote bar attr on both lines + newline",
              qa2.attribute(.markdownBlockquote, at: 0, effectiveRange: nil) != nil
              && qa2.attribute(.markdownBlockquote, at: 3, effectiveRange: nil) != nil   // the newline
              && qa2.attribute(.markdownBlockquote, at: 4, effectiveRange: nil) != nil)
        check("quote bar attr absent on plain", MarkdownParser.parse("plain").attributed.attribute(.markdownBlockquote, at: 0, effectiveRange: nil) == nil)
        check("quote bar color systemRed", MarkdownStyle.standard.quoteBarColor == .systemRed)
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
        print("QUOTEBAR x=0 span=\(qbMaxY - qbMinY) textX=\(qbTextX ?? -1)")
        check("quote text indent 12", qbTextX == 12, "x=\(qbTextX ?? -1)")
        check("quote bar spans both lines", qbMaxY - qbMinY > 30, "h=\(qbMaxY - qbMinY)")
        check("paragraph", MarkdownParser.parse("a\nb").blocks == [.paragraph("a\nb")])
        check("verbatim invariant",
              ["# Hi\n", "a\nb\n\n> q\n\n---\n", "Title\n===\n", "## A\nplain\n> quote\nx", ""]
                .allSatisfy { MarkdownParser.parse($0).attributed.string == $0 })

        // --- Task 5: inline pass ---
        let b = MarkdownParser.parse("**x**").attributed
        check("bold font", (b.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        check("bold delimiters syntax", b.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil
            && b.attribute(.markdownSyntax, at: 4, effectiveRange: nil) != nil)
        let ital = MarkdownParser.parse("*x*").attributed
        check("italic font", (ital.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        let both = MarkdownParser.parse("***x***").attributed
        check("bolditalic both",
              (both.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true
              && (both.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        let strike = MarkdownParser.parse("~~x~~").attributed
        check("strike attr", strike.attribute(.strikethroughStyle, at: 2, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        let code = MarkdownParser.parse("`x`").attributed
        check("code font", (code.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)?.fontName.contains("Mono") == true)
        // Inline code content is marked .markdownInlineCode (the layout manager draws
        // a rounded chip) — NOT .backgroundColor (a flat rect can't round corners).
        check("code chip marker", code.attribute(.markdownInlineCode, at: 1, effectiveRange: nil) != nil)
        check("code no bg attr", code.attribute(.backgroundColor, at: 1, effectiveRange: nil) == nil)
        check("code markers syntax", code.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil)
        // Inline code CONTENT must never be marked syntax — it stays visible when the
        // caret is outside the span (only the backtick delimiters collapse). Regression
        // for: cmark leaves have no children, so markGaps used to mark the whole span.
        check("code content not syntax", code.attribute(.markdownSyntax, at: 1, effectiveRange: nil) == nil)
        let code2 = MarkdownParser.parse("``a`b``").attributed
        check("code double-backtick span",
              (code2.attribute(.markdownCommandSpan, at: 3, effectiveRange: nil) as? NSValue)?.rangeValue == NSRange(location: 0, length: 7))
        check("code double-backtick delims", code2.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil
            && code2.attribute(.markdownSyntax, at: 5, effectiveRange: nil) != nil)
        check("code content backtick plain", code2.attribute(.markdownSyntax, at: 3, effectiveRange: nil) == nil)
        // Two adjacent inline-code spans must stay TWO separate chips (the draw loop
        // merges only contiguous sub-runs belonging to the SAME span; a gap between
        // spans starts a new run).
        let twoSpans = MarkdownParser.parse("`a` `b`").attributed
        var chipRuns: [NSRange] = []
        twoSpans.enumerateAttribute(.markdownInlineCode, in: NSRange(location: 0, length: twoSpans.length), options: []) { value, range, _ in
            if value != nil { chipRuns.append(range) }
        }
        check("two inline code chips separate", chipRuns.count == 2, "runs=\(chipRuns.count)")
        check("inline chip 1 range", chipRuns.first == NSRange(location: 1, length: 1), "r=\(String(describing: chipRuns.first))")
        check("inline chip 2 range", chipRuns.last == NSRange(location: 5, length: 1), "r=\(String(describing: chipRuns.last))")
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
        print("MIXEDCODE codeW=\(codeBounds.width) lineW=\(mixedLineWidth)")
        check("inline chip narrower than line", codeBounds.width < mixedLineWidth * 0.6, "codeW=\(codeBounds.width) lineW=\(mixedLineWidth)")
        check("inline chip starts at code", codeBounds.minX > 20, "minX=\(codeBounds.minX)")
        let esc = MarkdownParser.parse("\\*x\\*").attributed
        check("escape literal", esc.string == "\\*x\\*")
        check("escape asterisk plain", esc.attribute(.markdownSyntax, at: 1, effectiveRange: nil) == nil)
        check("escape backslash syntax", esc.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil)
        check("verbatim inline invariant",
              ["**b** and *i* and `c` and ~~s~~ and \\*x\\*", "a ** b ** c", "emoji 🎉 *ok*", "# **bold heading**"]
                .allSatisfy { MarkdownParser.parse($0).attributed.string == $0 })

        // --- Task 6: lists and task lists ---
        let ul = MarkdownParser.parse("- a\n- b")
        check("ul blocks", ul.blocks == [.unorderedList(items: [.init(text: "a", level: 0), .init(text: "b", level: 0)], level: 0)])
        check("ul marker syntax", ul.syntaxRanges.count == 2)
        let nested = MarkdownParser.parse("- a\n  - b")
        check("nested list levels",
              nested.blocks.first.map { if case .unorderedList(let items, _) = $0 { return items[1].level } else { return -1 } } == 1)
        let ol = MarkdownParser.parse("1. a\n2. b")
        check("ol blocks", ol.blocks == [.orderedList(items: [.init(text: "a", level: 0), .init(text: "b", level: 0)], level: 0)])
        let task = MarkdownParser.parse("- [x] done\n- [ ] todo")
        check("task blocks",
              task.blocks == [.taskList(items: [.init(text: "done", checked: true, level: 0), .init(text: "todo", checked: false, level: 0)])])
        check("task checkbox attr", task.attributed.attribute(.markdownCheckbox, at: 3, effectiveRange: nil) as? Bool == true)
        check("task checkbox unchecked attr", task.attributed.attribute(.markdownCheckbox, at: 14, effectiveRange: nil) as? Bool == false)
        check("verbatim list invariant",
              ["- a\n- b", "- [x] done\n- [ ] todo", "1. a\n  2. b", "* i1\n* i2\n  * i2a"]
                .allSatisfy { MarkdownParser.parse($0).attributed.string == $0 })

        // --- Task 7: links and images ---
        let l = MarkdownParser.parse("[x](https://a.b)").attributed
        check("link color", l.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor == .linkColor)
        check("link url attr", (l.attribute(.link, at: 1, effectiveRange: nil) as? URL)?.absoluteString == "https://a.b")
        check("link delimiters syntax", l.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil
            && l.attribute(.markdownSyntax, at: 6, effectiveRange: nil) != nil)
        let img = MarkdownParser.parse("![alt](https://a.b/c.png)").attributed
        check("image range attr", (img.attribute(.markdownImage, at: 2, effectiveRange: nil) as? URL)?.absoluteString == "https://a.b/c.png")
        check("image marker syntax", img.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil)
        check("verbatim link invariant",
              ["[x](https://a.b) t", "![alt](u) and [l](v)", "not a [link", "[a] (b)", "![broken](x"]
                .allSatisfy { MarkdownParser.parse($0).attributed.string == $0 })

        // --- Task 8: fenced code blocks ---
        let f = MarkdownParser.parse("```swift\nlet x = 1\n```")
        check("fence block", f.blocks == [.codeFence(language: "swift", code: "let x = 1\n")])
        check("fence markers syntax", f.syntaxRanges.count == 2)
        check("fence code attr", f.attributed.attribute(.markdownCodeBlock, at: 11, effectiveRange: nil) != nil)
        let fu = MarkdownParser.parse("~~~\ncode\n~~~")
        check("tilde fence", fu.blocks == [.codeFence(language: "", code: "code\n")])
        let unclosed = MarkdownParser.parse("```\nno close")
        check("unclosed fence runs to end", unclosed.blocks == [.codeFence(language: "", code: "no close\n")])
        check("verbatim fence invariant",
              ["```swift\nlet x = 1\n```", "```\nno close", "~~~\n**not bold**\n~~~", "a\n```\nb\n```"]
                .allSatisfy { MarkdownParser.parse($0).attributed.string == $0 })

        // --- Task 9: tables ---
        let t = MarkdownParser.parse("| a | b |\n|---|---|\n| 1 | 2 |")
        check("table block", t.blocks == [.table(header: ["a", "b"], rows: [["1", "2"]], alignments: [.left, .left])])
        check("table syntax pipes", t.syntaxRanges.count >= 4)
        let ta = MarkdownParser.parse("| a | b |\n|:---|---:|\n| 1 | 2 |")
        var aligns: [MarkdownParser.Alignment] = []
        if case .table(_, _, let a)? = ta.blocks.first { aligns = a }
        check("table alignments", aligns == [.left, .right])
        check("table header bold", (t.attributed.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        check("table cell monospace", (t.attributed.attribute(.font, at: 13, effectiveRange: nil) as? NSFont)?.fontName.contains("Mono") == true)
        check("verbatim table invariant",
              ["| a | b |\n|---|---|\n| 1 | 2 |", "a | b\n---|---\n1 | 2", "|x|y|\n|:-|-:|\n|1|2|", "no | pipe here"]
                .allSatisfy { MarkdownParser.parse($0).attributed.string == $0 })

        // --- Task 11: feature attributes ---
        check("rule attr", MarkdownParser.parse("---").attributed.attribute(.markdownRule, at: 0, effectiveRange: nil) != nil)

        // --- Task 12: sample document ---
        let sd = MarkdownParser.parse(SampleDocument.text)
        check("sample verbatim", sd.attributed.string == SampleDocument.text)
        check("sample has headings", sd.blocks.filter { if case .heading = $0 { return true } else { return false } }.count == 4)
        check("sample has tasks", sd.blocks.contains { if case .taskList = $0 { return true } else { return false } })
        check("sample has code fence", sd.blocks.contains { if case .codeFence = $0 { return true } else { return false } })
        check("sample has table", sd.blocks.contains { if case .table = $0 { return true } else { return false } })
        check("sample syntax ranges", sd.syntaxRanges.count > 10)

        // --- Task 13: zero-width hidden commands (layout-level) ---
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
        print("ZEROWIDTH real: hidden=\(wHidden) shown=\(wShown)")
        check("zerowidth: inactive line narrower", wHidden < wShown - 5, "hidden=\(wHidden) shown=\(wShown)")

        // --- Task 13b: heading line-height probe (active vs inactive) ---
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
        let nlFragDesc = nlFrags.map { "[" + String($0.location) + "," + String(NSMaxRange($0)) + ")" }.joined(separator: " ")
        print("NEWLINE FRAGS " + nlFragDesc)
        check("newline breaks line 1 headlessly",
              nlFrags.count == 2 && nlFrags[0] == NSRange(location: 0, length: 6) && nlFrags[1] == NSRange(location: 6, length: 5),
              nlFragDesc)
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
            print("FONTCHECK \(font.fontName): \(found.isEmpty ? "none" : found.joined(separator: " "))")
            if found.contains(where: { $0.hasSuffix("adv=0.0") }) { sfHasZeroWidth = true }
        }
        check("system font has zero-width glyph", sfHasZeroWidth)
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
        let hActiveWhole = headingHeight(activeRange: NSRange(location: 0, length: 11), invalidateRange: wholeDoc)
        let hActiveLineOnly = headingHeight(activeRange: NSRange(location: 0, length: 11), invalidateRange: headingLine)
        print("HEADING HEIGHT inactive=\(hInactive) active-whole=\(hActiveWhole) active-line-only=\(hActiveLineOnly)")
        check("heading height stable", abs(hInactive - hActiveLineOnly) < 0.5, "inactive=\(hInactive) active=\(hActiveLineOnly)")

        // --- Task 14: list markers always visible ---
        let lmDoc = MarkdownParser.parse("- a\n1. b\n- [x] c")
        check("ul marker attr", lmDoc.attributed.attribute(.markdownListMarker, at: 0, effectiveRange: nil) != nil)
        check("ol marker attr", lmDoc.attributed.attribute(.markdownListMarker, at: 4, effectiveRange: nil) != nil)
        check("task marker attr", lmDoc.attributed.attribute(.markdownListMarker, at: 9, effectiveRange: nil) != nil)
        let lmDoc2 = MarkdownParser.parse("- a").attributed
        let lmStorage2 = NSTextStorage(attributedString: lmDoc2)
        let lmLM2 = EditorLayoutManager()
        lmStorage2.addLayoutManager(lmLM2)
        let lmC2 = NSTextContainer(size: NSSize(width: 600, height: 2000))
        lmLM2.addTextContainer(lmC2)
        lmLM2.activeCharacterRange = NSRange(location: 999, length: 0) // no active line — marker must stay
        lmLM2.ensureLayout(for: lmC2)
        let wMarker = lmLM2.usedRect(for: lmC2).width
        print("LISTMARKER kept-width=\(wMarker)")
        check("list marker keeps width when inactive", wMarker > 14, "w=\(wMarker)")

        // --- Task 15: caret-range command visibility ---
        // Inline commands get a full span (opening through closing delimiter); the
        // delimiters show while the caret is inside the span. Block commands (#, >,
        // fences, table pipes) are line-commands: shown while the caret is on the line.
        let bs = MarkdownParser.parse("**bold** and **more**").attributed
        check("bold span covers whole command",
              (bs.attribute(.markdownCommandSpan, at: 0, effectiveRange: nil) as? NSValue)?.rangeValue == NSRange(location: 0, length: 8))
        check("bold span covers content",
              (bs.attribute(.markdownCommandSpan, at: 3, effectiveRange: nil) as? NSValue)?.rangeValue == NSRange(location: 0, length: 8))
        check("second bold has own span",
              (bs.attribute(.markdownCommandSpan, at: 14, effectiveRange: nil) as? NSValue)?.rangeValue == NSRange(location: 13, length: 8))
        check("inline delimiter is not line-command", bs.attribute(.markdownLineCommand, at: 0, effectiveRange: nil) == nil)
        let hd2 = MarkdownParser.parse("# Hi").attributed
        check("heading marker is line-command", hd2.attribute(.markdownLineCommand, at: 0, effectiveRange: nil) != nil)
        check("heading has no command span", hd2.attribute(.markdownCommandSpan, at: 0, effectiveRange: nil) == nil)
        let codeSpan = MarkdownParser.parse("a `code` b").attributed
        check("code span attr",
              (codeSpan.attribute(.markdownCommandSpan, at: 4, effectiveRange: nil) as? NSValue)?.rangeValue == NSRange(location: 2, length: 6))
        let linkSpan = MarkdownParser.parse("[t](https://a.b)").attributed
        check("link span attr",
              (linkSpan.attribute(.markdownCommandSpan, at: 1, effectiveRange: nil) as? NSValue)?.rangeValue == NSRange(location: 0, length: 16))

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
        print("SPANWIDTH inside=\(wInside) outside=\(wOutside)")
        check("inline delimiters show when caret inside span", wInside > wOutside + 5, "in=\(wInside) out=\(wOutside)")

        // --- Task 16: uniform checkbox slot ---
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
        print("CHECKBOXSLOT checked=\(cbCheckedW) unchecked=\(cbUncheckedW)")
        check("checkbox rows same width checked/unchecked", abs(cbCheckedW - cbUncheckedW) < 0.5, "c=\(cbCheckedW) u=\(cbUncheckedW)")

        // --- Task 17: smart list continuation (Return keeps/prepends the marker) ---
        check("continuation bullet", MarkdownParser.listContinuation(for: "- item") == MarkdownParser.ListContinuation(marker: "- ", empty: false))
        check("continuation alt bullet", MarkdownParser.listContinuation(for: "* item") == MarkdownParser.ListContinuation(marker: "* ", empty: false))
        check("continuation plus bullet", MarkdownParser.listContinuation(for: "+ item") == MarkdownParser.ListContinuation(marker: "+ ", empty: false))
        check("continuation indented", MarkdownParser.listContinuation(for: "  - item") == MarkdownParser.ListContinuation(marker: "  - ", empty: false))
        check("continuation ordered", MarkdownParser.listContinuation(for: "1. item") == MarkdownParser.ListContinuation(marker: "2. ", empty: false))
        check("continuation ordered paren", MarkdownParser.listContinuation(for: "10) item") == MarkdownParser.ListContinuation(marker: "11) ", empty: false))
        check("continuation task unchecked", MarkdownParser.listContinuation(for: "- [ ] todo") == MarkdownParser.ListContinuation(marker: "- [ ] ", empty: false))
        check("continuation task checked", MarkdownParser.listContinuation(for: "- [x] done") == MarkdownParser.ListContinuation(marker: "- [x] ", empty: false))
        check("continuation task indented", MarkdownParser.listContinuation(for: "  - [x] done") == MarkdownParser.ListContinuation(marker: "  - [x] ", empty: false))
        check("continuation empty bullet", MarkdownParser.listContinuation(for: "- ") == MarkdownParser.ListContinuation(marker: "- ", empty: true))
        check("continuation empty task", MarkdownParser.listContinuation(for: "- [ ] ") == MarkdownParser.ListContinuation(marker: "- [ ] ", empty: true))
        check("continuation whitespace-only content", MarkdownParser.listContinuation(for: "1.   ") == MarkdownParser.ListContinuation(marker: "2.   ", empty: true))
        check("continuation plain line", MarkdownParser.listContinuation(for: "plain text") == nil)
        check("continuation heading", MarkdownParser.listContinuation(for: "# head") == nil)
        check("continuation no-space dash", MarkdownParser.listContinuation(for: "-not a list") == nil)

        // Quote continuation: Return on a quote line prepends "> " to the new line;
        // a marker-only "> " line exits the quote (marker dropped).
        check("quote continuation", MarkdownParser.quoteContinuation(for: "> quoted") == MarkdownParser.ListContinuation(marker: "> ", empty: false))
        check("quote continuation no space", MarkdownParser.quoteContinuation(for: ">quoted") == MarkdownParser.ListContinuation(marker: "> ", empty: false))
        check("quote continuation nested", MarkdownParser.quoteContinuation(for: ">> deep") == MarkdownParser.ListContinuation(marker: ">> ", empty: false))
        check("quote continuation indented", MarkdownParser.quoteContinuation(for: "  > quoted") == MarkdownParser.ListContinuation(marker: "  > ", empty: false))
        check("quote continuation empty", MarkdownParser.quoteContinuation(for: "> ") == MarkdownParser.ListContinuation(marker: "> ", empty: true))
        check("quote continuation whitespace-only", MarkdownParser.quoteContinuation(for: ">   ") == MarkdownParser.ListContinuation(marker: ">   ", empty: true))
        check("quote continuation plain", MarkdownParser.quoteContinuation(for: "plain text") == nil)
        check("quote continuation heading", MarkdownParser.quoteContinuation(for: "# head") == nil)

        // --- Task 18: swift-markdown parser (regressions + new capabilities) ---
        // The old hand-rolled parser LOOPED FOREVER on a bare "- [ ]" (no trailing
        // space): the task-list guard matched but the full pattern did not, so the
        // group index never advanced. That input is exactly what backspacing a
        // checkbox produces. swift-markdown (cmark) cannot loop; assert clean parses.
        let bare = MarkdownParser.parse("- [ ]", style: .standard)
        check("bare checkbox parses (old infinite-loop repro)", bare.attributed.string == "- [ ]")
        // cmark's GFM task marker requires trailing whitespace, so "- [ ]" is a plain
        // list item holding the literal "[ ]" — it parses cleanly (the old parser
        // looped forever here) and renders as text, never crashing the editor.
        check("bare checkbox parses as a regular list item",
              bare.blocks == [.unorderedList(items: [.init(text: "[ ]", level: 0)], level: 0)])
        check("bare checkbox with space is a task item",
              MarkdownParser.parse("- [ ] ").blocks == [.taskList(items: [.init(text: "", checked: false, level: 0)])])
        let bareSpaced = MarkdownParser.parse("- [ ] \n- [x] done")
        check("checkbox backspace sequence parses", bareSpaced.attributed.string == "- [ ] \n- [x] done")
        // Reference-style links and autolinks (new capabilities, cmark-resolved)
        let ref = MarkdownParser.parse("[x][id]\n\n[id]: https://a.b")
        check("reference link resolves", (ref.attributed.attribute(.link, at: 1, effectiveRange: nil) as? URL)?.absoluteString == "https://a.b")
        let auto = MarkdownParser.parse("<https://a.b>")
        check("autolink resolves", (auto.attributed.attribute(.link, at: 2, effectiveRange: nil) as? URL)?.absoluteString == "https://a.b")
        check("autolink delimiters syntax", auto.attributed.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil
            && auto.attributed.attribute(.markdownSyntax, at: 12, effectiveRange: nil) != nil)
        // Inline HTML becomes a hidden command symbol
        let html = MarkdownParser.parse("a <b>c</b> d")
        check("inline html syntax", html.attributed.attribute(.markdownSyntax, at: 2, effectiveRange: nil) != nil)
        // Verbatim battery: emoji/multibyte around inline commands, tabs, trailing
        // newline, mixed constructs — byte-column → UTF-16 conversion must be exact.
        check("verbatim swift-markdown battery",
              ["emoji 🎉 *ok*", "a🎉b **bold**", "line1\nline2\n", "- [ ] \n- [x] done\n\n# t\n",
               "*i* and **b** and `c` and [l](u) and ![a](i)", "\ttab-indented\n",
               "# h1\nplain\n\n> quote\n\n- item\n- [x] task\n\n1. one\n  1. nested\n"]
                .allSatisfy { MarkdownParser.parse($0).attributed.string == $0 })

        codeHighlightTests()

        print("SELFTEST \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

            // MARK: - Task 19 tests (code syntax highlighting)

            /// Kind of the innermost token covering `offset` in `code` (overlapping tokens
                /// exist: a URL inside a comment is a link token inside the comment token).
                private static func kindAt(_ code: String, _ language: String, _ offset: Int) -> SyntaxKind? {
                    CodeHighlighter.tokens(in: code, language: language).last { NSLocationInRange(offset, $0.range) }?.kind
                }

            static func codeHighlightTests() {
                // --- Task 19: code syntax highlighting (Xcode-style categories, GitHub palette) ---

                // Language resolution from fence info strings.
                check("alias py -> python", CodeHighlighter.spec(forLanguage: "py")?.name == "Python")
                check("alias c++ -> cpp", CodeHighlighter.spec(forLanguage: "c++")?.name == "C++")
                check("alias objective-c", CodeHighlighter.spec(forLanguage: "objective-c")?.name == "Objective-C")
                check("alias mixed case", CodeHighlighter.spec(forLanguage: "TypeScript")?.name == "TypeScript")
                check("alias info attributes", CodeHighlighter.spec(forLanguage: "swift linenums")?.name == "Swift")
                check("language- prefix stripped", CodeHighlighter.spec(forLanguage: "language-python")?.name == "Python")
                check("unknown language nil", CodeHighlighter.spec(forLanguage: "klingon") == nil)
                check("20 languages catalogued", CodeHighlighter.all.count == 20)
                let names = Set(CodeHighlighter.all.map { $0.name })
                check("octoverse top-20 present",
                      ["JavaScript", "TypeScript", "Python", "Java", "C#", "C++", "PHP", "Shell", "C", "Ruby",
                       "Rust", "Go", "Kotlin", "Dart", "Swift", "Objective-C", "Scala", "PowerShell", "Lua", "Haskell"]
                        .allSatisfy { names.contains($0) })
                check("generic language placeholder", CodeHighlighter.spec(forLanguage: "plaintext") == nil)

                // Swift lexing: keywords, declarations, types, strings, comments, links.
                let sw = "func greet(name: String) -> String {\n    let msg = \"Hello, \\(name)!\"   // hi https://example.com\n    return msg\n}\n"
                let swNs = sw as NSString
                check("swift func keyword", kindAt(sw, "swift", swNs.range(of: "func").location) == .keyword)
                check("swift bare func keyword (typing)", kindAt("func", "swift", 0) == .keyword)
                check("swift member declaration", kindAt(sw, "swift", swNs.range(of: "greet").location) == .memberDeclaration)
                check("swift type reference", kindAt(sw, "swift", swNs.range(of: "String").location) == .otherType)
                check("swift string", kindAt(sw, "swift", swNs.range(of: "Hello").location) == .string)
                check("swift line comment", kindAt(sw, "swift", swNs.range(of: "hi").location) == .comment)
                check("swift url in comment is a link", kindAt(sw, "swift", swNs.range(of: "https://").location) == .link)
                check("swift let/return keywords", kindAt(sw, "swift", swNs.range(of: "let").location) == .keyword
                    && kindAt(sw, "swift", swNs.range(of: "return").location) == .keyword)
                let nums = "let n = 42, f = 3.14, h = 0xFF, b = 0b1010"
                check("swift int number", kindAt(nums, "swift", (nums as NSString).range(of: "42").location) == .number)
                check("swift float number", kindAt(nums, "swift", (nums as NSString).range(of: "3.14").location) == .number)
                check("swift hex number", kindAt(nums, "swift", (nums as NSString).range(of: "0xFF").location) == .number)
                check("swift binary number", kindAt(nums, "swift", (nums as NSString).range(of: "0b1010").location) == .number)

                // Doc comments: /// markers are comments, prose is prose.
                let doc = "/// Docs for foo\nfunc foo() {}"
                check("swift doc marker is comment", kindAt(doc, "swift", (doc as NSString).range(of: "///").location) == .comment)
                check("swift doc prose kind", kindAt(doc, "swift", (doc as NSString).range(of: "Docs").location) == .prose)
                check("swift block doc prose", kindAt("/** Block docs */\nlet x = 1", "swift", 4) == .prose)
                check("swift empty block comment", kindAt("/**/", "swift", 0) == .comment)

                // Cross-line constructs.
                let multi = "\"\"\"\nline one\ntwo\n\"\"\"\nlet end = true"
                check("swift multiline string state", kindAt(multi, "swift", (multi as NSString).range(of: "line one").location) == .string
                    && kindAt(multi, "swift", (multi as NSString).range(of: "two").location) == .string)
                check("swift multiline close resumes", kindAt(multi, "swift", (multi as NSString).range(of: "let end").location) == .keyword)
                let nested = "let a = 1 /* outer /* inner */ still */ let b = 2"
                check("swift nested block comment", kindAt(nested, "swift", (nested as NSString).range(of: "still").location) == .comment
                    && kindAt(nested, "swift", (nested as NSString).range(of: "let b").location) == .keyword)
                let unterminated = "let s = \"unterminated\nlet t = 1"
                check("swift unterminated string stops at line end",
                      kindAt(unterminated, "swift", (unterminated as NSString).range(of: "let t").location) == .keyword)
                let raw = "let r = #\"raw \\\"quoted\\\" text\"#\nlet next = 5"
                check("swift raw string", kindAt(raw, "swift", (raw as NSString).range(of: "quoted").location) == .string
                    && kindAt(raw, "swift", (raw as NSString).range(of: "let next").location) == .keyword)

                // UTF-16 safety: emoji inside strings and comments.
                let emoji = "let s = \"🎉\" // 😀 comment\nlet n = 7"
                check("swift emoji string", kindAt(emoji, "swift", (emoji as NSString).range(of: "🎉").location) == .string)
                check("swift emoji comment", kindAt(emoji, "swift", (emoji as NSString).range(of: "😀").location) == .comment)

                // Other languages: comments, strings, preprocessors, attributes, vars.
                let cCode = "#include <stdio.h>\n#define MAX 10\nint main(void) { return 0; }"
                let cNs = cCode as NSString
                check("c include preprocessor", kindAt(cCode, "c", cNs.range(of: "#include").location) == .preprocessor)
                check("c define preprocessor", kindAt(cCode, "c", cNs.range(of: "#define").location) == .preprocessor)
                check("c header string", kindAt(cCode, "c", cNs.range(of: "stdio").location) == .string)
                check("c header dot inside header string", kindAt(cCode, "c", cNs.range(of: "stdio.h").location + 5) == .string)
                let py = "# comment\ndef f(x):\n    return x * 2\n"
                check("python comment", kindAt(py, "python", (py as NSString).range(of: "comment").location) == .comment)
                check("python def keyword", kindAt(py, "python", (py as NSString).range(of: "def").location) == .keyword)
                check("python name member decl", kindAt(py, "python", (py as NSString).range(of: "f(x)").location) == .memberDeclaration)
                check("python number", kindAt(py, "python", (py as NSString).range(of: "2").location) == .number)
                let rust = "#[derive(Debug)]\nstruct Point { x: i32 }\nfn main() {}"
                check("rust attribute preprocessor", kindAt(rust, "rust", (rust as NSString).range(of: "#[derive").location) == .preprocessor)
                check("rust struct type decl", kindAt(rust, "rust", (rust as NSString).range(of: "Point").location) == .typeDeclaration)
                check("rust fn member decl", kindAt(rust, "rust", (rust as NSString).range(of: "main").location) == .memberDeclaration)
                check("rust lifetime plain", kindAt("fn f<'a>(x: &'a str) -> &'a str { x }", "rust", 8) == nil)
                let sh = "for f in *.md; do echo $f; done"
                check("shell keyword", kindAt(sh, "bash", (sh as NSString).range(of: "for").location) == .keyword)
                check("shell variable member", kindAt(sh, "bash", (sh as NSString).range(of: "$f").location) == .otherMember)
                let lua = "local function greet(name)\n    print(name)\nend"
                check("lua function member decl", kindAt(lua, "lua", (lua as NSString).range(of: "greet").location) == .memberDeclaration)
                check("lua local keyword", kindAt(lua, "lua", (lua as NSString).range(of: "local").location) == .keyword)

                // GitHub schemes: struct colors per Xcode category, dark vs light distinct.
                check("github light plain text", CodeColorScheme.githubLight.plainText == .hex("24292e"))
                check("github dark comment", CodeColorScheme.githubDark.comment == .hex("959da5"))
                check("dark scheme distinct from light",
                      CodeColorScheme.githubDark.keyword != CodeColorScheme.githubLight.keyword
                      && CodeColorScheme.githubDark.plainText != CodeColorScheme.githubLight.plainText)
                check("scheme resolves per kind",
                      CodeColorScheme.githubDark.color(for: .keyword) == CodeColorScheme.githubDark.keyword
                      && CodeColorScheme.githubLight.color(for: .comment) == CodeColorScheme.githubLight.comment)

                // --- Parser integration: fenced code spans get token colors ---
                let mdCode = "before\n\n```swift\nfunc f() { let x = 42 }   // hi https://a.b\n```\n\nafter"
                let parsed = MarkdownParser.parse(mdCode)
                check("highlighted fence verbatim", parsed.attributed.string == mdCode)
                let mdNs = mdCode as NSString
                func colorAt(_ word: String) -> NSColor? {
                    let loc = mdNs.range(of: word).location
                    guard loc != NSNotFound else { return nil }
                    return parsed.attributed.attribute(.foregroundColor, at: loc, effectiveRange: nil) as? NSColor
                }
                check("code keyword color = github light keyword", colorAt("func") == CodeColorScheme.githubLight.keyword)
                check("code number color = github light constant", colorAt("42") == CodeColorScheme.githubLight.number)
                check("code comment color = github light comment", colorAt("hi") == CodeColorScheme.githubLight.comment)
                check("code url color = github light link", colorAt("https://a.b") == CodeColorScheme.githubLight.link)
                check("code url underlined", parsed.attributed.attribute(.underlineStyle,
                                                                         at: mdNs.range(of: "https://a.b").location,
                                                                         effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
                check("code url underline color", parsed.attributed.attribute(.underlineColor,
                                                                              at: mdNs.range(of: "https://a.b").location,
                                                                              effectiveRange: nil) as? NSColor == CodeColorScheme.githubLight.link)
                check("highlighted code keeps block background",
                              parsed.attributed.attribute(.markdownCodeBlock, at: mdNs.range(of: "func").location, effectiveRange: nil) != nil)
                        // The whole fence content is ONE .markdownCodeBlock run — the interior newline
                        // between code lines carries the marker, so the layout manager draws a single
                        // rounded block instead of per-line tiles. Fence marker lines are background-free.
                        let multiFence = "```swift\nlet a = 1\nlet b = 2\n```"
                        let mf = MarkdownParser.parse(multiFence)
                        let mfNs = multiFence as NSString
                        let interiorNL = mfNs.range(of: "\nlet b").location
                        check("code background continuous across lines",
                              mf.attributed.attribute(.markdownCodeBlock, at: interiorNL, effectiveRange: nil) != nil
                              && mf.attributed.attribute(.markdownCodeBlock, at: interiorNL + 1, effectiveRange: nil) != nil)
                        check("fence marker lines have no background",
                              mf.attributed.attribute(.markdownCodeBlock, at: 0, effectiveRange: nil) == nil
                              && mf.attributed.attribute(.markdownCodeBlock, at: mfNs.length - 2, effectiveRange: nil) == nil)
                        check("single-line fence one block", MarkdownParser.parse("```x\na\n```").attributed.attribute(.markdownCodeBlock, at: 5, effectiveRange: nil) != nil)
        // Language label attribute for the block chrome.
        let langDoc = MarkdownParser.parse("```swift\nlet a = 1\n```")
        let ldNs = langDoc.attributed.string as NSString
        let langName = langDoc.attributed.attribute(.markdownCodeLanguage, at: ldNs.range(of: "let a").location, effectiveRange: nil) as? String
        check("code block language label attr", langName == "Swift")
        let unknownLangDoc = MarkdownParser.parse("```xyz\nabc\n```")
        let ulNs = unknownLangDoc.attributed.string as NSString
        let ulName = unknownLangDoc.attributed.attribute(.markdownCodeLanguage, at: ulNs.range(of: "abc").location, effectiveRange: nil) as? String
        check("unknown code block has no language label", ulName == nil)
        check("language label verbatim", langDoc.attributed.string == "```swift\nlet a = 1\n```" && unknownLangDoc.attributed.string == "```xyz\nabc\n```")
        // Draw-time merge: token-color sub-runs within one fence must collapse into a
        // single block (not a rounded rect per token), while a real gap starts a new block.
        check("merge adjacent code runs into one block",
              EditorLayoutManager.mergedCodeRuns([NSRange(location: 0, length: 3),
                                                  NSRange(location: 3, length: 2),
                                                  NSRange(location: 5, length: 1)]) ==
                [NSRange(location: 0, length: 6)])
        check("merge keeps separate blocks across a gap",
              EditorLayoutManager.mergedCodeRuns([NSRange(location: 0, length: 2),
                                                  NSRange(location: 3, length: 2)]) ==
                [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
                check("plain code outside fence unchanged", colorAt("before") == MarkdownStyle.standard.textColor)

                let unknown = "```xyz\nfunc f()\n```"
                let un = MarkdownParser.parse(unknown)
                check("unknown language keeps code text color",
                      un.attributed.attribute(.foregroundColor, at: (unknown as NSString).range(of: "func").location,
                                              effectiveRange: nil) as? NSColor == MarkdownStyle.standard.codeTextColor)
                check("unknown language verbatim", un.attributed.string == unknown)

                let two = "```python\nx = 1\n```\n\n```js\nconst y = 2\n```"
                let tp = MarkdownParser.parse(two)
                check("two fences verbatim", tp.attributed.string == two)
                let tNs = two as NSString
                let pyNum = tp.attributed.attribute(.foregroundColor, at: tNs.range(of: "x = 1").location + 4,
                                                    effectiveRange: nil) as? NSColor
                let jsKw = tp.attributed.attribute(.foregroundColor, at: tNs.range(of: "const").location,
                                                   effectiveRange: nil) as? NSColor
                check("python number in first fence", pyNum == CodeColorScheme.githubLight.number)
                check("js keyword in second fence", jsKw == CodeColorScheme.githubLight.keyword)
            }

    /// Measures scroll content geometry in the LIVE text view: the document view
    /// frame must track the layout manager's usedRect (+ vertical textContainerInset)
    /// so the scroller covers exactly the document. Drives the caret to the end and
    /// re-measures, since selection-driven reflows (zero-width commands) change layout.
    public static func scrollGeometryProbe() {
        guard let tv = EditorTextView.live, let scroll = tv.enclosingScrollView else {
            print("SCROLLPROBE FAIL no live text view / scroll view")
            return
        }
        func report(_ name: String, _ cond: Bool, _ extra: String = "") {
            print("SCROLLPROBE \(cond ? "PASS" : "FAIL") \(name) \(extra)")
        }
        func measure(_ label: String) {
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)
            let used = tv.layoutManager!.usedRect(for: tv.textContainer!)
            let inset = tv.textContainerInset
            let expected = used.height + inset.height * 2
            let frameH = tv.frame.height
            let delta = frameH - expected
            print("SCROLLPROBE \(label): frameH=\(frameH) usedH=\(used.height) expected=\(expected) delta=\(delta) contentSize=\(scroll.contentSize)")
            report("frame tracks usedRect", abs(delta) < 1.0, "delta=\(delta)")
        }
        print("SCROLLPROBE lmDelegateIsTV=\((tv.layoutManager?.delegate as AnyObject?) === tv) minSize=\(tv.minSize) maxSize=\(tv.maxSize) autoresizing=\(tv.autoresizingMask.rawValue)")
        measure("launch-caret-0")
        tv.sizeToFit()
        measure("after-sizeToFit")
        let len = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: len, length: 0))
        tv.insertText("X")
        measure("after-insert-at-end")
        tv.deleteBackward(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            measure("caret-at-end")
            print("SCROLLPROBE done")
        }
    }

    /// Drives the live editor through insertText / deleteBackward / insertNewline to
    /// diagnose "backspace does nothing" / "second Enter does nothing" reports.
    public static func editPathProbe() {
        guard let tv = EditorTextView.live else {
            print("EDITPROBE FAIL no live text view")
            return
        }
        func report(_ name: String, _ cond: Bool, _ extra: String = "") {
            print("EDITPROBE \(cond ? "PASS" : "FAIL") \(name) \(extra)")
        }
        let ns = tv.string as NSString
        let startLen = ns.length
        print("EDITPROBE launch selection=\(tv.selectedRange) len=\(startLen)")

        // Heading line-height probe in the real text view (regression: selecting a heading
        // was reported to grow its line height and push everything below down).
        let headingRange = ns.range(of: "### Task list")
        if headingRange.location != NSNotFound {
            func headingFrags() -> String {
                tv.layoutManager?.ensureLayout(for: tv.textContainer!)
                let g = tv.layoutManager!.glyphRange(forCharacterRange: headingRange, actualCharacterRange: nil)
                var frags: [String] = []
                tv.layoutManager!.enumerateLineFragments(forGlyphRange: g) { rect, used, _, _, _ in
                    frags.append("h=\(rect.height)/y=\(rect.minY)")
                }
                return frags.joined(separator: " ")
            }
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            let dInactive = headingFrags()
            tv.setSelectedRange(NSRange(location: headingRange.location + headingRange.length, length: 0))
            let dActive = headingFrags()
            let stable = dInactive == dActive
            print("EDITPROBE \(stable ? "PASS" : "FAIL") heading line stable: inactive=[\(dInactive)] active=[\(dActive)]")
        }
        tv.setSelectedRange(NSRange(location: startLen, length: 0))
        tv.insertText("Z")
        let afterInsert = (tv.string as NSString).length
        report("insertText", tv.string.hasSuffix("Z"), "len \(startLen) -> \(afterInsert)")
        tv.deleteBackward(nil)
        let afterDelete = (tv.string as NSString).length
        report("deleteBackward", !tv.string.hasSuffix("Z") && afterDelete == startLen, "len \(afterInsert) -> \(afterDelete)")
        let nl0 = tv.string.filter { $0 == "\n" }.count
        tv.insertNewline(nil)
        let nl1 = tv.string.filter { $0 == "\n" }.count
        report("first newline", nl1 == nl0 + 1, "nl \(nl0) -> \(nl1)")
        tv.insertNewline(nil)
        let nl2 = tv.string.filter { $0 == "\n" }.count
        report("second newline", nl2 == nl0 + 2, "nl \(nl1) -> \(nl2)")
        // Smart list continuation: Return on a list item prepends the marker; Return
        // on the fresh marker-only item removes it again (exits the list).
        let cl0 = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: cl0, length: 0))
        tv.insertText("- [ ] task")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertNewline(nil)
        report("list continuation marker", tv.string.hasSuffix("- [ ] task\n- [ ] "), "suffix=[\(String(tv.string.suffix(24)))]")
        report("list continuation caret", tv.selectedRange.location == (tv.string as NSString).length, "caret=\(tv.selectedRange.location) len=\((tv.string as NSString).length)")
        tv.insertNewline(nil)
        report("list continuation exit", tv.string.hasSuffix("- [ ] task\n"), "suffix=[\(String(tv.string.suffix(16)))]")
        report("list continuation exit caret", tv.selectedRange.location == (tv.string as NSString).length, "caret=\(tv.selectedRange.location) len=\((tv.string as NSString).length)")
        // Smart quote continuation: Return on a quote line prepends "> "; Return on
        // the fresh marker-only "> " line removes it again (exits the quote).
        let cq0 = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: cq0, length: 0))
        tv.insertText("> quoted")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertNewline(nil)
        report("quote continuation marker", tv.string.hasSuffix("> quoted\n> "), "suffix=[\(String(tv.string.suffix(18)))]")
        report("quote continuation caret", tv.selectedRange.location == (tv.string as NSString).length, "caret=\(tv.selectedRange.location) len=\((tv.string as NSString).length)")
        tv.insertNewline(nil)
        report("quote continuation exit", tv.string.hasSuffix("> quoted\n"), "suffix=[\(String(tv.string.suffix(12)))]")
        report("quote continuation exit caret", tv.selectedRange.location == (tv.string as NSString).length, "caret=\(tv.selectedRange.location) len=\((tv.string as NSString).length)")
        // Middle-of-text edits (common backspace case)
        let mid = (tv.string as NSString).length / 2
        tv.setSelectedRange(NSRange(location: mid, length: 0))
        tv.insertText("Q")
        let c = (tv.string as NSString).character(at: mid)
        report("middle insert", c == 0x51, "char at \(mid) = \(c)")
        let lenMid1 = (tv.string as NSString).length
        tv.deleteBackward(nil)
        let lenMid2 = (tv.string as NSString).length
        report("middle delete", lenMid2 == lenMid1 - 1, "len \(lenMid1) -> \(lenMid2)")
        // Select all → delete (regression: crashed in setTypingAttributes/font panel)
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        tv.deleteBackward(nil)
        let lenAfterSelectAll = (tv.string as NSString).length
        report("select-all delete", lenAfterSelectAll == 0, "len -> \(lenAfterSelectAll)")
        print("EDITPROBE final selection=\(tv.selectedRange) len=\((tv.string as NSString).length)")
    }
}

// MARK: - Smoke mode (launch, log, self-quit)

@MainActor
public enum SmokeTest {
    public static func schedule() {
        // Drive the live editor through the real edit path after the window is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            SelfTest.scrollGeometryProbe()   // runs first: editPathProbe empties the doc
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            SelfTest.editPathProbe()         // after the scroll probe's async measurements
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            EmptyDocScrollProbe.run()        // frame must shrink to ~insets, not clamp
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            print("SMOKE OK")
            NSApp.terminate(nil)
        }
    }
}

/// After the edit probe empties the document, the text view frame must shrink to
/// just the vertical insets (no minSize clamp to the first viewport height).
@MainActor
public enum EmptyDocScrollProbe {
    public static func run() {
        guard let tv = EditorTextView.live else {
            print("EMPTYDOC FAIL no live text view")
            return
        }
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let used = tv.layoutManager!.usedRect(for: tv.textContainer!)
        let expected = used.height + tv.textContainerInset.height * 2
        let frameH = tv.frame.height
        let delta = frameH - expected
        print("EMPTYDOC frameH=\(frameH) expected=\(expected) delta=\(delta) minSize=\(tv.minSize)")
        print("EMPTYDOC \(abs(delta) < 1.0 ? "PASS" : "FAIL") frame shrinks with content")
    }
}
