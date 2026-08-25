import Foundation
import Testing

@testable import Md

@Suite("MarkdownStyleSpec") struct MarkdownStyleSpecTests {
  @Test func standardStyleColorsMatchMacOSDefaults() {
    let style = MarkdownStyleSpec.standard
    #expect(style.textColor == .label)
    #expect(style.syntaxColor == .tertiaryLabel)
    #expect(style.codeBackground == .quaternarySystemFill)
    #expect(style.codeTextColor == .secondaryLabel)
    #expect(style.linkColor == .link)
    #expect(style.quoteTextColor == .secondaryLabel)
    #expect(style.quoteBarColor == .systemRed)
    #expect(style.listMarkerColor == .systemBlue)
    #expect(style.ruleColor == .separator)
    #expect(style.checkedTextColor == .secondaryLabel)
  }

  @Test func bodyAndCodeFontsMatchMacOSDefaults() {
    let style = MarkdownStyleSpec.standard
    let body = style.bodyFont()
    #expect(body.kind == .body)
    #expect(body.size == 13)
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
    #expect(h1.size == 26)
    #expect(h1.weight == .bold)
    let h2 = style.headingFont(level: 2)
    #expect(h2.size == 20)
    #expect(h2.weight == .bold)
    let h3 = style.headingFont(level: 3)
    #expect(h3.size == 16)
    #expect(h3.weight == .bold)
    let h4 = style.headingFont(level: 4)
    #expect(h4.size == 14)
    #expect(h4.weight == .semibold)
    let h6 = style.headingFont(level: 6)
    #expect(h6.size == 12)
    #expect(h6.weight == .semibold)
    // Out-of-range levels clamp like the macOS implementation.
    #expect(style.headingFont(level: 0).size == 26)
    #expect(style.headingFont(level: 99).size == 12)
  }

  @Test func paragraphsMatchMacOSDefaults() {
    let style = MarkdownStyleSpec.standard
    let body = style.bodyParagraph()
    #expect(body.lineSpacing == 5)
    #expect(body.paragraphSpacing == 6)

    let h1 = style.headingParagraph(level: 1)
    #expect(h1.paragraphSpacingBefore == 18)
    #expect(h1.paragraphSpacing == 15)
    let h3 = style.headingParagraph(level: 3)
    #expect(h3.paragraphSpacingBefore == 14)
    #expect(h3.paragraphSpacing == 13)

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

  // MARK: - MarkdownMetrics (single source of truth)

  @Test func standardMetricsMatchOriginalDefaults() {
    let m = MarkdownMetrics.standard
    // Fonts
    #expect(m.bodyFontSize == 13)
    #expect(m.codeFontSize == 14)
    #expect(m.headingSizes == [26, 20, 16, 14, 13, 12])
    #expect(m.chromeFontSize == 11)
    #expect(m.chromeFontWeight == .semibold)
    #expect(m.checkboxImageSize == 13)
    // Paragraphs
    #expect(m.bodyLineSpacing == 5)
    #expect(m.bodyParagraphSpacing == 6)
    #expect(m.headingParagraphSpacingBefore == 18)
    #expect(m.headingParagraphSpacingBeforeMinor == 8)
    #expect(m.headingParagraphSpacing == 15)
    #expect(m.headingParagraphSpacingMinor == 15)
    #expect(m.listIndentPerLevel == 24)
    #expect(m.listParagraphSpacing == 3)
    #expect(m.listMarkerWidthBullet == 18)
    #expect(m.listMarkerWidthOrdered == 30)
    #expect(m.listMarkerWidthTask == 24)
    #expect(m.quoteIndent == 12)
    #expect(m.quoteParagraphSpacing == 6)
    // Layout / drawing
    #expect(m.textContainerInsetWidth == 48)
    #expect(m.textContainerInsetHeight == 28)
    #expect(m.codeBlockCornerRadius == 6)
    #expect(m.inlineCodeChipHPad == 3)
    #expect(m.inlineCodeChipVInset == 2)
    #expect(m.inlineCodeChipMaxRadius == 5)
    #expect(m.inlineCodeChipStrokeWidth == 0.5)
    #expect(m.inlineCodeFontSize == 12)
    #expect(m.quoteBarWidth == 3)
    #expect(m.quoteBarCornerRadius == 1.5)
    #expect(m.ruleStrokeWidth == 1)
    #expect(m.codeChromeTopOffset == 2)
    #expect(m.codeChromeInset == 10)
    #expect(m.copyHitPaddingX == 6)
    #expect(m.copyHitPaddingY == 4)
    #expect(m.checkboxScaleFactor == 1.2)
    #expect(m.checkboxMinSize == 14)
    #expect(m.imageHeightScale == 1.05)
    #expect(m.checkboxCornerRadius == 3)
    #expect(m.checkboxStrokeWidth == 1.2)
    #expect(m.checkboxCheckStrokeWidth == 1.6)
  }

  @Test func metricsDriveStyleSpec() {
    var custom = MarkdownMetrics.standard
    custom.bodyFontSize = 20
    custom.bodyLineSpacing = 4
    custom.bodyParagraphSpacing = 10
    custom.headingSizes = [40, 32, 26, 20, 16, 14]
    custom.listIndentPerLevel = 30
    custom.quoteIndent = 18
    let style = MarkdownStyleSpec(metrics: custom)
    #expect(style.bodyFont().size == 20)
    #expect(style.bodyParagraph().lineSpacing == 4)
    #expect(style.bodyParagraph().paragraphSpacing == 10)
    #expect(style.headingFont(level: 1).size == 40)
    #expect(style.headingFont(level: 6).size == 14)
    #expect(MarkdownMetrics.standard.inlineCodeFont().size == 12)
    #expect(MarkdownMetrics.standard.inlineCodeFont().kind == .code)
    #expect(style.listParagraph(level: 1, markerWidth: 10).firstLineHeadIndent == 30)
    #expect(style.quoteParagraph().firstLineHeadIndent == 18)
    #expect(style.listMarkerWidth(task: false, ordered: false) == 18)
  }

  @Test func metricsMarkerWidths() {
    let m = MarkdownMetrics.standard
    #expect(m.listMarkerWidth(task: true, ordered: false) == 24)
    #expect(m.listMarkerWidth(task: false, ordered: true) == 30)
    #expect(m.listMarkerWidth(task: false, ordered: false) == 18)
  }
}
