#if canImport(AppKit)
import AppKit

public struct MarkdownStyle {
    /// Metrics this style reads from — the single source of truth.
    public var metrics: MarkdownMetrics

    public init(metrics: MarkdownMetrics = .standard) {
        self.metrics = metrics
    }

    // Colors — all dynamic system colors → automatic dark/light support
    public let textColor: NSColor = .labelColor
    public let syntaxColor: NSColor = .tertiaryLabelColor   // ★ "commands in tertiary color"
    public let codeBackground: NSColor = .quaternarySystemFill   // macOS 14+; package targets macOS 12
    public let codeTextColor: NSColor = .secondaryLabelColor
    public let linkColor: NSColor = .linkColor
    public let quoteTextColor: NSColor = .secondaryLabelColor
    public let quoteBarColor: NSColor = .systemRed
    public let ruleColor: NSColor = .separatorColor
    public let checkedTextColor: NSColor = .secondaryLabelColor

    /// Code syntax color scheme (Xcode-style categories; GitHub Light/Dark
    /// defaults). Resolved afresh on every parse: an appearance switch restyles
    /// fenced code with the matching palette on the next edit/restyle pass.
    public var codeScheme: CodeColorScheme { .systemAware }
    // Fonts
    public var bodyFont: NSFont { .systemFont(ofSize: metrics.bodyFontSize) }
    public var codeFont: NSFont { .monospacedSystemFont(ofSize: metrics.codeFontSize, weight: .regular) }
    public var headingSizes: [CGFloat] { metrics.headingSizes }
    public func headingFont(level: Int) -> NSFont {
        let size = headingSizes[max(0, min(5, level - 1))]
        let weight: NSFont.Weight = level <= 3 ? .bold : .semibold
        return .systemFont(ofSize: size, weight: weight)
    }
    public func emphasisFont(base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let desc = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: base.pointSize) ?? base
    }

    // Paragraph styles
    public func bodyParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = metrics.bodyLineSpacing
        p.paragraphSpacing = metrics.bodyParagraphSpacing
        return p
    }
    public func headingParagraph(level: Int) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = metrics.headingSpacingBefore(level: level)
        p.paragraphSpacing = metrics.headingSpacingAfter(level: level)
        return p
    }
    public func listParagraph(level: Int, markerWidth: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let indent = metrics.listIndentPerLevel * CGFloat(level)
        p.firstLineHeadIndent = indent
        p.headIndent = indent + markerWidth
        p.paragraphSpacing = metrics.listParagraphSpacing
        return p
    }
    public func quoteParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = metrics.quoteIndent
        p.headIndent = metrics.quoteIndent
        p.paragraphSpacing = metrics.quoteParagraphSpacing
        return p
    }

    // Attribute bundles
    public var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: textColor, .paragraphStyle: bodyParagraph()]
    }
    public func syntaxAttributes() -> [NSAttributedString.Key: Any] {
        [.foregroundColor: syntaxColor, .markdownSyntax: true]
    }
    public func codeAttributes() -> [NSAttributedString.Key: Any] {
        [.font: codeFont, .foregroundColor: codeTextColor, .backgroundColor: codeBackground]
    }
    public func inlineCodeAttributes() -> [NSAttributedString.Key: Any] {
        // No .backgroundColor — the layout manager draws a rounded chip behind the
        // range (marked .markdownInlineCode) so corners can be rounded.
        [.font: codeFont, .foregroundColor: codeTextColor, .markdownInlineCode: true]
    }

    /// The default style. Computed (not a stored global) so the non-Sendable
    /// NSColor/NSFont value type stays concurrency-safe under Swift 6.
    public static var standard: MarkdownStyle { MarkdownStyle() }
}
#endif
