import AppKit

// MARK: - Self-test harness (CLI-verifiable TDD: `Markdown --selftest`)

enum SelfTest {
    private static var passed = 0
    private static var failed = 0

    static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
            print("  PASS \(name)")
        } else {
            failed += 1
            print("  FAIL \(name) \(detail)")
        }
    }

    static func runAndExit() -> Never {
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
        check("code bg", code.attribute(.backgroundColor, at: 1, effectiveRange: nil) != nil)
        check("code markers syntax", code.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil)
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
        check("fence block", f.blocks == [.codeFence(language: "swift", code: "let x = 1")])
        check("fence markers syntax", f.syntaxRanges.count == 2)
        check("fence code attr", f.attributed.attribute(.markdownCodeBlock, at: 11, effectiveRange: nil) != nil)
        let fu = MarkdownParser.parse("~~~\ncode\n~~~")
        check("tilde fence", fu.blocks == [.codeFence(language: "", code: "code")])
        let unclosed = MarkdownParser.parse("```\nno close")
        check("unclosed fence runs to end", unclosed.blocks == [.codeFence(language: "", code: "no close")])
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
        check("sample has headings", sd.blocks.filter { if case .heading = $0 { return true } else { return false } }.count == 3)
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

        print("SELFTEST \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    /// Drives the live editor through insertText / deleteBackward / insertNewline to
    /// diagnose "backspace does nothing" / "second Enter does nothing" reports.
    static func editPathProbe() {
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

enum SmokeTest {
    static func schedule() {
        // Drive the live editor through the real edit path after the window is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            SelfTest.editPathProbe()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print("SMOKE OK")
            NSApp.terminate(nil)
        }
    }
}
