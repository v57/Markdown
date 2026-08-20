import AppKit
import MdCode

public extension NSAttributedString.Key {
    /// Marks markdown "command symbol" ranges (hidden on inactive lines, tertiary when active).
    static let markdownSyntax = NSAttributedString.Key("MarkdownSyntax")
    /// Marks task-list checkbox ranges ("[x]"/"[ ]"); the layout manager draws a checkbox
    /// image instead of the literal characters (keeps the source string verbatim).
    static let markdownCheckbox = NSAttributedString.Key("MarkdownCheckbox")
    /// Marks inline image ranges ("![alt](url)"); the layout manager draws a cached image
    /// in place of the range once loaded (keeps the source string verbatim).
    static let markdownImage = NSAttributedString.Key("MarkdownImage")
    /// Marks fenced-code content ranges; the layout manager draws the continuous
    /// full-width background block (per-line backgrounds would show seams).
    static let markdownCodeBlock = NSAttributedString.Key("MarkdownCodeBlock")
    /// Marks horizontal-rule ranges; the layout manager draws a full-width line
    /// instead of the literal dashes.
    static let markdownRule = NSAttributedString.Key("MarkdownRule")
    /// Marks list markers ("- ", "* ", "1. ") that are ALWAYS shown (never hidden or
    /// collapsed), even on inactive lines — Obsidian-style persistent bullets.
    static let markdownListMarker = NSAttributedString.Key("MarkdownListMarker")
    /// Marks BLOCK-level syntax (heading prefix, blockquote '>', code fences, table
    /// pipes, setext underline, rule): shown while the caret is anywhere on the line.
    static let markdownLineCommand = NSAttributedString.Key("MarkdownLineCommand")
    /// Marks the full span of an inline command ("**bold**", "`code`", "[link](url)").
    /// Value is an NSValue-wrapped NSRange. The command's delimiters are shown while
    /// the caret is inside (or just after) this span.
    static let markdownCommandSpan = NSAttributedString.Key("MarkdownCommandSpan")
    /// Marks blockquote lines (including their trailing newline); the layout manager
    /// draws a vertical bar at the quote block's left edge instead of relying on the
    /// '>' markers alone (those collapse to zero width on inactive lines).
    static let markdownBlockquote = NSAttributedString.Key("MarkdownBlockquote")
    /// Marks fenced-code content with its language display name (e.g. "Swift")
    /// when the fence language is recognized; the layout manager draws a language
    /// label for the block. Absent for unknown languages.
    static let markdownCodeLanguage = NSAttributedString.Key("MarkdownCodeLanguage")
    /// Marks inline-code content (the text between backticks, NOT the backticks);
    /// the layout manager draws a rounded chip behind it instead of the flat
    /// `.backgroundColor` rect (which can't round corners).
    static let markdownInlineCode = NSAttributedString.Key("MarkdownInlineCode")
}

public struct MarkdownStyle {
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
    public let bodyFont = NSFont.systemFont(ofSize: 15)
    public let codeFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    public let headingSizes: [CGFloat] = [28, 24, 20, 17, 15, 13]   // h1…h6
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
        p.lineSpacing = 2
        p.paragraphSpacing = 6
        return p
    }
    public func headingParagraph(level: Int) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = level <= 2 ? 12 : 8
        p.paragraphSpacing = level <= 2 ? 8 : 6
        return p
    }
    public func listParagraph(level: Int, markerWidth: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let indent = 24 * CGFloat(level)
        p.firstLineHeadIndent = indent
        p.headIndent = indent + markerWidth
        p.paragraphSpacing = 3
        return p
    }
    public func quoteParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 12
        p.headIndent = 12
        p.paragraphSpacing = 6
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

public extension NSColor {
    /// sRGB color from a 0xRRGGBB hex value (e.g. 0x24292E). The AppKit-side
    /// counterpart of `CodeColorScheme`'s platform-neutral `UInt32` storage.
    static func hex(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
