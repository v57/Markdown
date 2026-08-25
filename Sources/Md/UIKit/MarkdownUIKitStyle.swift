#if canImport(UIKit)
  import UIKit

  /// UIKit implementation of the platform-neutral `MarkdownStyling` contract.
  /// Mirrors the AppKit `MarkdownStyle` numeric values EXACTLY: colors resolve to
  /// dynamic `UIColor` system roles (automatic dark/light support), fonts to
  /// `UIFont`, paragraphs to `NSParagraphStyle` — all via `MarkdownRenderer`.
  public struct MarkdownUIKitStyle: MarkdownStyling {
    /// Metrics this style reads from — the single source of truth.
    public var metrics: MarkdownMetrics

    public init(metrics: MarkdownMetrics = .standard) { self.metrics = metrics }

    // MARK: - Colors (same semantic roles as MarkdownStyle on macOS)

    public var textColor: MarkdownColor { .label }
    public var syntaxColor: MarkdownColor { .tertiaryLabel }
    public var codeBackground: MarkdownColor { .quaternarySystemFill }
    public var codeTextColor: MarkdownColor { .secondaryLabel }
    public var linkColor: MarkdownColor { .link }
    public var quoteTextColor: MarkdownColor { .secondaryLabel }
    public var quoteBarColor: MarkdownColor { .systemRed }
    public var ruleColor: MarkdownColor { .separator }
    public var checkedTextColor: MarkdownColor { .secondaryLabel }
    public var listMarkerColor: MarkdownColor { .systemBlue }

    // MARK: - Fonts

    public func bodyFont() -> MarkdownFont { metrics.bodyFont() }

    public func codeFont() -> MarkdownFont { metrics.codeFont() }

    public func headingFont(level: Int) -> MarkdownFont { metrics.headingFont(level: level) }

    /// Bold/italic emphasis on top of a base font — traits are ADDED to the
    /// base's traits (matches the macOS `emphasisFont` behavior).
    public func emphasisFont(base: MarkdownFont, bold: Bool, italic: Bool) -> MarkdownFont {
      var traits = base.traits
      if bold { traits.insert(.bold) }
      if italic { traits.insert(.italic) }
      return base.addingTraits(traits)
    }

    // MARK: - Paragraphs

    public func bodyParagraph() -> MarkdownParagraph { metrics.bodyParagraph() }

    public func headingParagraph(level: Int) -> MarkdownParagraph {
      metrics.headingParagraph(level: level)
    }

    public func listParagraph(level: Int, markerWidth: CGFloat) -> MarkdownParagraph {
      metrics.listParagraph(level: level, markerWidth: markerWidth)
    }

    public func quoteParagraph() -> MarkdownParagraph { metrics.quoteParagraph() }

    public func codeParagraph() -> MarkdownParagraph { metrics.codeParagraph() }

    public func tableParagraph() -> MarkdownParagraph { metrics.tableParagraph() }

    /// The default style. Computed (not a stored global) so the value type stays
    /// trivially Sendable under Swift 6.
    public static var standard: MarkdownUIKitStyle { MarkdownUIKitStyle() }

    // MARK: - Convenience native accessors (used by the editor stack)

    public var bodyUIFont: UIFont { MarkdownRenderer.resolve(bodyFont()) as! UIFont }
    public var codeUIFont: UIFont { MarkdownRenderer.resolve(codeFont()) as! UIFont }
    public func headingUIFont(level: Int) -> UIFont {
      MarkdownRenderer.resolve(headingFont(level: level)) as! UIFont
    }
    public func color(_ c: MarkdownColor) -> UIColor { MarkdownRenderer.resolve(c) as! UIColor }
    public var typingAttributes: [NSAttributedString.Key: Any] {
      [
        .font: bodyUIFont, .foregroundColor: color(textColor),
        .paragraphStyle: MarkdownRenderer.resolve(bodyParagraph()),
      ]
    }
  }
#endif
