import Foundation

/// A platform-neutral color: either a fixed sRGB hex value (0xRRGGBB) or a
/// semantic system role that the platform layer resolves to `NSColor`/`UIColor`.
public enum MarkdownColor: Equatable, Sendable {
  /// Fixed sRGB color, 0xRRGGBB.
  case rgb(UInt32)
  /// Semantic system colors (resolved per-platform; adapt to dark/light mode).
  case label, secondaryLabel, tertiaryLabel
  case link, separator, systemRed, systemBlue
  case controlAccent, systemBackground
  case quaternarySystemFill
}

/// A platform-neutral font weight.
public enum MarkdownFontWeight: Equatable, Sendable { case regular, semibold, bold }

/// A platform-neutral font trait, applied on top of a base font
/// (e.g. for emphasis: bold and/or italic).
public enum MarkdownFontTrait: Equatable, Sendable, Hashable { case bold, italic }

/// A platform-neutral font description.
public struct MarkdownFont: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case body, code
    case heading(level: Int)
    case chrome
  }

  public var kind: Kind
  public var size: CGFloat
  public var weight: MarkdownFontWeight
  public var traits: Set<MarkdownFontTrait>

  public init(
    kind: Kind, size: CGFloat, weight: MarkdownFontWeight = .regular,
    traits: Set<MarkdownFontTrait> = []
  ) {
    self.kind = kind
    self.size = size
    self.weight = weight
    self.traits = traits
  }
}

extension MarkdownFont {
  /// Returns a copy with `traits` replaced by the given set.
  public func withTraits(_ traits: Set<MarkdownFontTrait>) -> MarkdownFont {
    var copy = self
    copy.traits = traits
    return copy
  }

  /// Returns a copy with `traits` unioned into the existing traits —
  /// matches the macOS `emphasisFont` behavior, which ADDS traits to the base.
  public func addingTraits(_ traits: Set<MarkdownFontTrait>) -> MarkdownFont {
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
    lineSpacing: CGFloat = 0, paragraphSpacing: CGFloat = 0, paragraphSpacingBefore: CGFloat = 0,
    firstLineHeadIndent: CGFloat = 0, headIndent: CGFloat = 0
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
  /// List marker (`-`, `1.`) color — systemBlue by default.
  var listMarkerColor: MarkdownColor { get }
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
  /// Marker column width for a list item (task / ordered / bullet).
  func listMarkerWidth(task: Bool, ordered: Bool) -> CGFloat
}

extension MarkdownStyling {
  /// Default marker widths — from `MarkdownMetrics.standard` (the single
  /// source of truth) unless a style overrides them.
  public func listMarkerWidth(task: Bool, ordered: Bool) -> CGFloat {
    MarkdownMetrics.standard.listMarkerWidth(task: task, ordered: ordered)
  }
}

/// The default platform-neutral style spec — values come from
/// `MarkdownMetrics.standard` (the single source of truth), so the macOS stack
/// renders identically and any metric tweak flows through everywhere.
public struct MarkdownStyleSpec: MarkdownStyling {
  /// The metrics this style reads from. Defaults to the standard values;
  /// inject a custom `MarkdownMetrics` to re-theme the whole render path.
  public var metrics: MarkdownMetrics

  public init(metrics: MarkdownMetrics = .standard) { self.metrics = metrics }

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
  public var listMarkerColor: MarkdownColor { .systemBlue }

  // MARK: Fonts

  public func bodyFont() -> MarkdownFont { metrics.bodyFont() }

  public func codeFont() -> MarkdownFont { metrics.codeFont() }

  public func headingFont(level: Int) -> MarkdownFont { metrics.headingFont(level: level) }

  public func emphasisFont(base: MarkdownFont, bold: Bool, italic: Bool) -> MarkdownFont {
    var traits = base.traits
    if bold { traits.insert(.bold) }
    if italic { traits.insert(.italic) }
    return base.addingTraits(traits)
  }

  // MARK: Paragraphs

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
  public static var standard: MarkdownStyleSpec { MarkdownStyleSpec() }
}
