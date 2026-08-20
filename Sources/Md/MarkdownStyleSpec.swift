import Foundation

/// A platform-neutral color: either a fixed sRGB hex value (0xRRGGBB) or a
/// semantic system role that the platform layer resolves to `NSColor`/`UIColor`.
public enum MarkdownColor: Equatable, Sendable {
    /// Fixed sRGB color, 0xRRGGBB.
    case rgb(UInt32)
    /// Semantic system colors (resolved per-platform; adapt to dark/light mode).
    case label, secondaryLabel, tertiaryLabel
    case link, separator, systemRed
    case controlAccent, systemBackground
    case quaternarySystemFill
}

/// A platform-neutral font weight.
public enum MarkdownFontWeight: Equatable, Sendable {
    case regular, semibold, bold
}

/// A platform-neutral font trait, applied on top of a base font
/// (e.g. for emphasis: bold and/or italic).
public enum MarkdownFontTrait: Equatable, Sendable, Hashable {
    case bold, italic
}

/// A platform-neutral font description.
public struct MarkdownFont: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case body, code, heading(level: Int), chrome
    }

    public var kind: Kind
    public var size: CGFloat
    public var weight: MarkdownFontWeight
    public var traits: Set<MarkdownFontTrait>

    public init(
        kind: Kind,
        size: CGFloat,
        weight: MarkdownFontWeight = .regular,
        traits: Set<MarkdownFontTrait> = []
    ) {
        self.kind = kind
        self.size = size
        self.weight = weight
        self.traits = traits
    }
}

public extension MarkdownFont {
    /// Returns a copy with `traits` replaced by the given set.
    func withTraits(_ traits: Set<MarkdownFontTrait>) -> MarkdownFont {
        var copy = self
        copy.traits = traits
        return copy
    }

    /// Returns a copy with `traits` unioned into the existing traits —
    /// matches the macOS `emphasisFont` behavior, which ADDS traits to the base.
    func addingTraits(_ traits: Set<MarkdownFontTrait>) -> MarkdownFont {
        var copy = self
        copy.traits.formUnion(traits)
        return copy
    }
}

/// A platform-neutral paragraph style (indents/spacings).
public struct MarkdownParagraph: Equatable, Sendable {
    public var lineSpacing: CGFloat
    public var paragraphSpacing: CGFloat
    public var paragraphSpacingBefore: CGFloat
    public var firstLineHeadIndent: CGFloat
    public var headIndent: CGFloat

    public init(
        lineSpacing: CGFloat = 0,
        paragraphSpacing: CGFloat = 0,
        paragraphSpacingBefore: CGFloat = 0,
        firstLineHeadIndent: CGFloat = 0,
        headIndent: CGFloat = 0
    ) {
        self.lineSpacing = lineSpacing
        self.paragraphSpacing = paragraphSpacing
        self.paragraphSpacingBefore = paragraphSpacingBefore
        self.firstLineHeadIndent = firstLineHeadIndent
        self.headIndent = headIndent
    }
}

/// The style contract each platform implements. Fonts/colors/paragraphs are
/// described platform-neutrally; each platform's `MarkdownStyle` renders them
/// into its native types (NSFont/NSColor/NSParagraphStyle, UIFont/UIColor/...).
///
/// NOTE: the code-syntax palette (`CodeColorScheme`) is intentionally NOT part
/// of this protocol — MdCore must not depend on MdCode. Each platform style
/// exposes its own `codeScheme` property; the parser receives it separately.
public protocol MarkdownStyling {
    var textColor: MarkdownColor { get }
    var syntaxColor: MarkdownColor { get }
    var codeBackground: MarkdownColor { get }
    var codeTextColor: MarkdownColor { get }
    var linkColor: MarkdownColor { get }
    var quoteTextColor: MarkdownColor { get }
    var quoteBarColor: MarkdownColor { get }
    var ruleColor: MarkdownColor { get }
    var checkedTextColor: MarkdownColor { get }
    func bodyFont() -> MarkdownFont
    func codeFont() -> MarkdownFont
    func headingFont(level: Int) -> MarkdownFont
    func emphasisFont(base: MarkdownFont, bold: Bool, italic: Bool) -> MarkdownFont
    func bodyParagraph() -> MarkdownParagraph
    func headingParagraph(level: Int) -> MarkdownParagraph
    func listParagraph(level: Int, markerWidth: CGFloat) -> MarkdownParagraph
    func quoteParagraph() -> MarkdownParagraph
    func codeParagraph() -> MarkdownParagraph
    func tableParagraph() -> MarkdownParagraph
}

/// The default platform-neutral style spec — values mirror the macOS
/// `MarkdownStyle` exactly (so the macOS stack renders identically).
public struct MarkdownStyleSpec: MarkdownStyling {
    public init() {}

    // MARK: Colors — mirror Sources/Md/MarkdownStyle.swift

    public var textColor: MarkdownColor { .label }
    public var syntaxColor: MarkdownColor { .tertiaryLabel }
    public var codeBackground: MarkdownColor { .quaternarySystemFill }
    public var codeTextColor: MarkdownColor { .secondaryLabel }
    public var linkColor: MarkdownColor { .link }
    public var quoteTextColor: MarkdownColor { .secondaryLabel }
    public var quoteBarColor: MarkdownColor { .systemRed }
    public var ruleColor: MarkdownColor { .separator }
    public var checkedTextColor: MarkdownColor { .secondaryLabel }

    // MARK: Fonts

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

    public func emphasisFont(base: MarkdownFont, bold: Bool, italic: Bool) -> MarkdownFont {
        var traits = base.traits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return base.addingTraits(traits)
    }

    // MARK: Paragraphs

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
    public static var standard: MarkdownStyleSpec { MarkdownStyleSpec() }
}
