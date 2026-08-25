import Foundation
import SwiftUI

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

// MARK: - Single source of truth: every markdown metric
//
// ALL numeric values that shape how markdown renders live in this one struct:
// fonts, paragraph spacings/indents, text-view margins, and drawing geometry.
// The render path (parser paragraph styles, platform font/paragraph builders,
// the layout-manager drawing hooks, checkbox/chrome drawing) reads from
// `MarkdownMetrics.standard` instead of hardcoding literals, so tweaking a
// value here re-renders the editor live (Xcode preview picks it up on the
// fly). Values mirror the original literals exactly — the default look is
// unchanged.

public struct MarkdownMetrics: Sendable {
  // MARK: Fonts (pt)

  public var bodyFontSize: CGFloat = 13
  public var codeFontSize: CGFloat = 14
  /// Inline-code font size in BODY context: container size − 1 (13→12). The
  /// parser derives inline-code size per-container (headings scale up too).
  public var inlineCodeFontSize: CGFloat = 12
  /// h1…h6 point sizes.
  public var headingSizes: [CGFloat] = [26, 20, 16, 14, 13, 12]
  /// Code-block chrome (language label + Copy button) font.
  public var chromeFontSize: CGFloat = 11
  public var chromeFontWeight: MarkdownFontWeight = .semibold

  // MARK: Paragraphs (pt)

  public var bodyLineSpacing: CGFloat = 5
  public var bodyParagraphSpacing: CGFloat = 6
  /// Heading spacing: h1–h2 vs h3–h6.
  public var headingParagraphSpacingBefore: CGFloat = 18
  public var headingParagraphSpacingBeforeMinor: CGFloat = 8
  public var headingParagraphSpacing: CGFloat = 15
  public var headingParagraphSpacingMinor: CGFloat = 15
  /// List: indent grows by this per nesting level.
  public var listIndentPerLevel: CGFloat = 24
  public var listParagraphSpacing: CGFloat = 3
  /// Marker column widths (the space reserved for the marker glyph).
  public var listMarkerWidthBullet: CGFloat = 18
  public var listMarkerWidthOrdered: CGFloat = 30
  public var listMarkerWidthTask: CGFloat = 24
  /// Blockquote: text indent and paragraph spacing.
  public var quoteIndent: CGFloat = 12
  public var quoteParagraphSpacing: CGFloat = 6

  // MARK: Text view / container (pt)

  /// Obsidian-like margins around the text.
  public var textContainerInsetWidth: CGFloat = 48
  public var textContainerInsetHeight: CGFloat = 28

  // MARK: Drawing geometry (pt)

  public var codeBlockCornerRadius: CGFloat = 6
  /// Inline-code chip: horizontal padding around the code glyphs.
  public var inlineCodeChipHPad: CGFloat = 3
  /// Inline-code chip: vertical inset from the line fragment.
  public var inlineCodeChipVInset: CGFloat = 2
  /// Inline-code chip: max corner radius (scaled by line height).
  public var inlineCodeChipMaxRadius: CGFloat = 5
  /// Inline-code chip: stroke border width (design spec: 0.5pt).
  public var inlineCodeChipStrokeWidth: CGFloat = 0.5
  /// Blockquote vertical bar.
  public var quoteBarWidth: CGFloat = 3
  public var quoteBarCornerRadius: CGFloat = 1.5
  /// Horizontal rule stroke.
  public var ruleStrokeWidth: CGFloat = 1
  /// Code chrome (language label + Copy) offset from the fence line top.
  public var codeChromeTopOffset: CGFloat = 2
  /// Code chrome horizontal inset from the block edges.
  public var codeChromeInset: CGFloat = 10
  /// Copy button hit-test padding around the drawn text.
  public var copyHitPaddingX: CGFloat = 6
  public var copyHitPaddingY: CGFloat = 4
  /// Checkbox drawn size: `max(checkboxMinSize, lineHeight * 0.62) * checkboxScaleFactor`.
  public var checkboxScaleFactor: CGFloat = 1.2
  public var checkboxMinSize: CGFloat = 14
  /// Reference checkbox image size (pt) for API callers that build the image
  /// outside the layout manager's draw hook (e.g. the UIKit renderer default).
  public var checkboxImageSize: CGFloat = 13
  /// Inline image drawn height relative to the line fragment.
  public var imageHeightScale: CGFloat = 1.05
  /// Checkbox glyph box geometry.
  public var checkboxCornerRadius: CGFloat = 3
  public var checkboxStrokeWidth: CGFloat = 1.2
  public var checkboxCheckStrokeWidth: CGFloat = 1.6

  public init() {}

  /// The default metrics — matches the original hardcoded values exactly.
  public static var standard: MarkdownMetrics { MarkdownMetrics() }

  // MARK: Derived helpers (used by the render path)

  /// Paragraph spacing before a heading of the given level.
  public func headingSpacingBefore(level: Int) -> CGFloat {
    switch level {
    case 1: 18
    case 2: 16
    case 3: 14
    case 4: 11
    case 5: 11
    default: 11
    }
  }

  /// Paragraph spacing after a heading of the given level.
  public func headingSpacingAfter(level: Int) -> CGFloat {
    switch level {
    case 1: 15
    case 2: 13
    case 3: 13
    case 4: 11
    case 5: 9
    default: 8
    }
  }

  /// Width of the marker column for a list item of the given kind.
  public func listMarkerWidth(task: Bool, ordered: Bool) -> CGFloat {
    task ? listMarkerWidthTask : (ordered ? listMarkerWidthOrdered : listMarkerWidthBullet)
  }

  /// Body paragraph style.
  public func bodyParagraph() -> MarkdownParagraph {
    MarkdownParagraph(lineSpacing: bodyLineSpacing, paragraphSpacing: bodyParagraphSpacing)
  }

  /// Heading paragraph style for the given level.
  public func headingParagraph(level: Int) -> MarkdownParagraph {
    MarkdownParagraph(
      paragraphSpacing: headingSpacingAfter(level: level),
      paragraphSpacingBefore: headingSpacingBefore(level: level))
  }

  /// List item paragraph style at a nesting level with a marker column width.
  public func listParagraph(level: Int, markerWidth: CGFloat) -> MarkdownParagraph {
    let indent = listIndentPerLevel * CGFloat(level)
    return MarkdownParagraph(
      paragraphSpacing: listParagraphSpacing, firstLineHeadIndent: indent,
      headIndent: indent + markerWidth)
  }

  /// Blockquote paragraph style.
  public func quoteParagraph() -> MarkdownParagraph {
    MarkdownParagraph(
      paragraphSpacing: quoteParagraphSpacing, firstLineHeadIndent: quoteIndent,
      headIndent: quoteIndent)
  }

  /// Code block paragraph style (no indents/spacings).
  public func codeParagraph() -> MarkdownParagraph { MarkdownParagraph() }

  /// Table paragraph style (no indents/spacings).
  public func tableParagraph() -> MarkdownParagraph { MarkdownParagraph() }

  /// Heading font for the given level.
  public func headingFont(level: Int) -> MarkdownFont {
    let size = headingSizes[max(0, min(5, level - 1))]
    let weight: MarkdownFontWeight = level <= 3 ? .bold : .semibold
    return MarkdownFont(kind: .heading(level: level), size: size, weight: weight)
  }

  /// Body font.
  public func bodyFont() -> MarkdownFont {
    MarkdownFont(kind: .body, size: bodyFontSize, weight: .regular)
  }

  /// Code font.
  public func codeFont() -> MarkdownFont {
    MarkdownFont(kind: .code, size: codeFontSize, weight: .regular)
  }

  /// Inline-code font for BODY context (12pt monospaced). The parser derives
  /// the actual per-container size (container − 1); this is the body baseline.
  public func inlineCodeFont() -> MarkdownFont {
    MarkdownFont(kind: .code, size: inlineCodeFontSize, weight: .regular)
  }

  /// Chrome (code-block label + Copy button) font.
  public func chromeFont() -> MarkdownFont {
    MarkdownFont(kind: .chrome, size: chromeFontSize, weight: chromeFontWeight)
  }
}

#if DEBUG
  #Preview("MarkdownEditorView") { MarkdownEditorView().frame(minWidth: 480, minHeight: 800) }
#endif
