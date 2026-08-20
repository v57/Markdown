import Foundation
import Testing
@testable import MdCore

@Suite("MarkdownStyleSpec")
struct MarkdownStyleSpecTests {
    @Test func standardStyleColorsMatchMacOSDefaults() {
        let style = MarkdownStyleSpec.standard
        #expect(style.textColor == .label)
        #expect(style.syntaxColor == .tertiaryLabel)
        #expect(style.codeBackground == .quaternarySystemFill)
        #expect(style.codeTextColor == .secondaryLabel)
        #expect(style.linkColor == .link)
        #expect(style.quoteTextColor == .secondaryLabel)
        #expect(style.quoteBarColor == .systemRed)
        #expect(style.ruleColor == .separator)
        #expect(style.checkedTextColor == .secondaryLabel)
    }

    @Test func bodyAndCodeFontsMatchMacOSDefaults() {
        let style = MarkdownStyleSpec.standard
        let body = style.bodyFont()
        #expect(body.kind == .body)
        #expect(body.size == 15)
        #expect(body.weight == .regular)
        #expect(body.traits.isEmpty)
        let code = style.codeFont()
        #expect(code.kind == .code)
        #expect(code.size == 14)
        #expect(code.weight == .regular)
        #expect(code.traits.isEmpty)
    }

    @Test func headingFontsMatchMacOSDefaults() {
        let style = MarkdownStyleSpec.standard
        let h1 = style.headingFont(level: 1)
        #expect(h1.size == 28)
        #expect(h1.weight == .bold)
        let h2 = style.headingFont(level: 2)
        #expect(h2.size == 24)
        #expect(h2.weight == .bold)
        let h3 = style.headingFont(level: 3)
        #expect(h3.size == 20)
        #expect(h3.weight == .bold)
        let h4 = style.headingFont(level: 4)
        #expect(h4.size == 17)
        #expect(h4.weight == .semibold)
        let h6 = style.headingFont(level: 6)
        #expect(h6.size == 13)
        #expect(h6.weight == .semibold)
        // Out-of-range levels clamp like the macOS implementation.
        #expect(style.headingFont(level: 0).size == 28)
        #expect(style.headingFont(level: 99).size == 13)
    }

    @Test func paragraphsMatchMacOSDefaults() {
        let style = MarkdownStyleSpec.standard
        let body = style.bodyParagraph()
        #expect(body.lineSpacing == 2)
        #expect(body.paragraphSpacing == 6)

        let h1 = style.headingParagraph(level: 1)
        #expect(h1.paragraphSpacingBefore == 12)
        #expect(h1.paragraphSpacing == 8)
        let h3 = style.headingParagraph(level: 3)
        #expect(h3.paragraphSpacingBefore == 8)
        #expect(h3.paragraphSpacing == 6)

        let list = style.listParagraph(level: 1, markerWidth: 18)
        #expect(list.firstLineHeadIndent == 24)
        #expect(list.headIndent == 42)
        #expect(list.paragraphSpacing == 3)
        let list0 = style.listParagraph(level: 0, markerWidth: 18)
        #expect(list0.firstLineHeadIndent == 0)
        #expect(list0.headIndent == 18)

        let quote = style.quoteParagraph()
        #expect(quote.firstLineHeadIndent == 12)
        #expect(quote.headIndent == 12)
        #expect(quote.paragraphSpacing == 6)

        #expect(style.codeParagraph() == MarkdownParagraph())
        #expect(style.tableParagraph() == MarkdownParagraph())
    }

    @Test func emphasisFontAddsTraitsToBase() {
        let style = MarkdownStyleSpec.standard
        let base = MarkdownFont(kind: .body, size: 15)
        let bold = style.emphasisFont(base: base, bold: true, italic: false)
        #expect(bold.traits == [.bold])
        #expect(bold.size == 15)
        #expect(bold.kind == .body)
        let italic = style.emphasisFont(base: base, bold: false, italic: true)
        #expect(italic.traits == [.italic])
        let both = style.emphasisFont(base: bold, bold: false, italic: true)
        #expect(both.traits == [.bold, .italic])
        let none = style.emphasisFont(base: base, bold: false, italic: false)
        #expect(none.traits.isEmpty)
    }

    @Test func markdownFontAddingTraitsUnions() {
        let base = MarkdownFont(kind: .code, size: 14)
        let bolded = base.addingTraits([.bold])
        #expect(bolded.traits == [.bold])
        #expect(bolded.size == 14)
        #expect(bolded.kind == .code)
        // Idempotent for the same trait.
        #expect(bolded.addingTraits([.bold]).traits == [.bold])
        // Unions additional traits.
        #expect(bolded.addingTraits([.italic]).traits == [.bold, .italic])
        // withTraits replaces rather than unions.
        let replaced = bolded.withTraits([.italic])
        #expect(replaced.traits == [.italic])
    }

    @Test func markdownColorEquatable() {
        #expect(MarkdownColor.rgb(0x24292E) == MarkdownColor.rgb(0x24292E))
        #expect(MarkdownColor.rgb(0x24292E) != MarkdownColor.rgb(0x24292F))
        #expect(MarkdownColor.label == MarkdownColor.label)
        #expect(MarkdownColor.label != MarkdownColor.secondaryLabel)
        #expect(MarkdownColor.rgb(0x24292E) != MarkdownColor.label)
    }
}
