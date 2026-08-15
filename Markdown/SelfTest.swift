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

        print("SELFTEST \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

// MARK: - Smoke mode (launch, log, self-quit)

enum SmokeTest {
    static func schedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print("SMOKE OK")
            NSApp.terminate(nil)
        }
    }
}
