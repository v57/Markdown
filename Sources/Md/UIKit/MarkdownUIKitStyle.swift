#if canImport(UIKit)
import UIKit

/// UIKit implementation of the platform-neutral `MarkdownStyling` contract.
/// Mirrors the AppKit `MarkdownStyle` numeric values EXACTLY: colors resolve to
/// dynamic `UIColor` system roles (automatic dark/light support), fonts to
/// `UIFont`, paragraphs to `NSParagraphStyle` — all via `MarkdownRenderer`.
public struct MarkdownUIKitStyle: MarkdownStyling {
    public init() {}

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

    // MARK: - Fonts

    /// h1…h6 point sizes, mirroring `MarkdownStyle.headingSizes`.
    public let headingSizes: [CGFloat] = [28, 24, 20, 17, 15, 13]

    public func bodyFont() -> MarkdownFont {
        MarkdownFont(kind: .body, size: 15, weight: .regular)
    }

    public func codeFont() -> MarkdownFont {
        MarkdownFont(kind: .code, size: 14, weight: .regular)
    }

    public func headingFont(level: Int) -> MarkdownFont {
        let size = headingSizes[max(0, min(5, level - 1))]
        let weight: MarkdownFontWeight = level <= 3 ? .bold : .semibold
        return MarkdownFont(kind: .heading(level: level), size: size, weight: weight)
    }

    /// Bold/italic emphasis on top of a base font — traits are ADDED to the
    /// base's traits (matches the macOS `emphasisFont` behavior).
    public func emphasisFont(base: MarkdownFont, bold: Bool, italic: Bool) -> MarkdownFont {
        var traits = base.traits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return base.addingTraits(traits)
    }

    // MARK: - Paragraphs

    public func bodyParagraph() -> MarkdownParagraph {
        MarkdownParagraph(lineSpacing: 2, paragraphSpacing: 6)
    }

    public func headingParagraph(level: Int) -> MarkdownParagraph {
        MarkdownParagraph(
            paragraphSpacing: level <= 2 ? 8 : 6,
            paragraphSpacingBefore: level <= 2 ? 12 : 8
        )
    }

    public func listParagraph(level: Int, markerWidth: CGFloat) -> MarkdownParagraph {
        let indent = 24 * CGFloat(level)
        return MarkdownParagraph(
            paragraphSpacing: 3,
            firstLineHeadIndent: indent,
            headIndent: indent + markerWidth
        )
    }

    public func quoteParagraph() -> MarkdownParagraph {
        MarkdownParagraph(paragraphSpacing: 6, firstLineHeadIndent: 12, headIndent: 12)
    }

    public func codeParagraph() -> MarkdownParagraph {
        MarkdownParagraph()
    }

    public func tableParagraph() -> MarkdownParagraph {
        MarkdownParagraph()
    }

    /// The default style. Computed (not a stored global) so the value type stays
    /// trivially Sendable under Swift 6.
    public static var standard: MarkdownUIKitStyle { MarkdownUIKitStyle() }

    // MARK: - Convenience native accessors (used by the editor stack)

    public var bodyUIFont: UIFont { MarkdownRenderer.resolve(bodyFont()) as! UIFont }
    public var codeUIFont: UIFont { MarkdownRenderer.resolve(codeFont()) as! UIFont }
    public func headingUIFont(level: Int) -> UIFont { MarkdownRenderer.resolve(headingFont(level: level)) as! UIFont }
    public func color(_ c: MarkdownColor) -> UIColor { MarkdownRenderer.resolve(c) as! UIColor }
    public var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyUIFont, .foregroundColor: color(textColor), .paragraphStyle: MarkdownRenderer.resolve(bodyParagraph())]
    }
}
#endif
