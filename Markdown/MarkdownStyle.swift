import AppKit

extension NSAttributedString.Key {
    /// Marks markdown "command symbol" ranges (hidden on inactive lines, tertiary when active).
    static let markdownSyntax = NSAttributedString.Key("MarkdownSyntax")
    /// Marks task-list checkbox ranges ("[x]"/"[ ]"); the layout manager draws a checkbox
    /// image instead of the literal characters (keeps the source string verbatim).
    static let markdownCheckbox = NSAttributedString.Key("MarkdownCheckbox")
    /// Marks inline image ranges ("![alt](url)"); the layout manager draws a cached image
    /// in place of the range once loaded (keeps the source string verbatim).
    static let markdownImage = NSAttributedString.Key("MarkdownImage")
}

struct MarkdownStyle {
    // Colors — all dynamic system colors → automatic dark/light support
    let textColor: NSColor = .labelColor
    let syntaxColor: NSColor = .tertiaryLabelColor   // ★ "commands in tertiary color"
    let codeBackground: NSColor = .quaternarySystemFill
    let codeTextColor: NSColor = .secondaryLabelColor
    let linkColor: NSColor = .linkColor
    let quoteTextColor: NSColor = .secondaryLabelColor
    let quoteBarColor: NSColor = .tertiaryLabelColor
    let ruleColor: NSColor = .separatorColor
    let checkedTextColor: NSColor = .secondaryLabelColor

    // Fonts
    let bodyFont = NSFont.systemFont(ofSize: 15)
    let codeFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    let headingSizes: [CGFloat] = [28, 24, 20, 17, 15, 13]   // h1…h6
    func headingFont(level: Int) -> NSFont {
        let size = headingSizes[max(0, min(5, level - 1))]
        let weight: NSFont.Weight = level <= 3 ? .bold : .semibold
        return .systemFont(ofSize: size, weight: weight)
    }
    func emphasisFont(base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let desc = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: base.pointSize) ?? base
    }

    // Paragraph styles
    func bodyParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        p.paragraphSpacing = 6
        return p
    }
    func headingParagraph(level: Int) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = level <= 2 ? 12 : 8
        p.paragraphSpacing = level <= 2 ? 8 : 6
        return p
    }
    func listParagraph(level: Int, markerWidth: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let indent = 24 * CGFloat(level)
        p.firstLineHeadIndent = indent
        p.headIndent = indent + markerWidth
        p.paragraphSpacing = 3
        return p
    }
    func quoteParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 24
        p.headIndent = 24
        p.paragraphSpacing = 6
        return p
    }

    // Attribute bundles
    var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: textColor, .paragraphStyle: bodyParagraph()]
    }
    func syntaxAttributes() -> [NSAttributedString.Key: Any] {
        [.foregroundColor: syntaxColor, .markdownSyntax: true]
    }
    func codeAttributes() -> [NSAttributedString.Key: Any] {
        [.font: codeFont, .foregroundColor: codeTextColor, .backgroundColor: codeBackground]
    }

    static let standard = MarkdownStyle()
}
