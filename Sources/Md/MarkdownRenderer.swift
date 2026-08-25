import Foundation

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// Renders the parser's platform-neutral attribute values into a native
/// `NSAttributedString` (NSFont/NSColor/NSParagraphStyle on macOS,
/// UIFont/UIColor/NSParagraphStyle on iOS).
///
/// The parser builds its attribute dictionaries with `MarkdownColor`,
/// `MarkdownFont`, and `MarkdownParagraph` values (never AppKit/UIKit types).
/// `MarkdownRenderer.render(_:style:)` walks those attributes and materializes
/// the platform-native font/color/paragraph objects, so the parser stays 100%
/// platform-neutral while `parse()` still returns a fully-native
/// `NSAttributedString` that callers (editor text views, tests) consume as-is.
public enum MarkdownRenderer {
  // MARK: - Platform-native resolution

  /// Resolves a platform-neutral color to the native color type.
  public static func resolve(_ color: MarkdownColor) -> Any {
    #if canImport(AppKit)
      return resolveAppKit(color)
    #elseif canImport(UIKit)
      return resolveUIKit(color)
    #else
      return color
    #endif
  }

  /// Resolves a platform-neutral font to the native font type.
  public static func resolve(_ font: MarkdownFont) -> Any {
    #if canImport(AppKit)
      return resolveAppKit(font)
    #elseif canImport(UIKit)
      return resolveUIKit(font)
    #else
      return font
    #endif
  }

  /// Builds a native paragraph style from the platform-neutral metrics.
  public static func resolve(_ paragraph: MarkdownParagraph) -> NSParagraphStyle {
    let p = NSMutableParagraphStyle()
    p.lineSpacing = paragraph.lineSpacing
    p.paragraphSpacing = paragraph.paragraphSpacing
    p.paragraphSpacingBefore = paragraph.paragraphSpacingBefore
    p.firstLineHeadIndent = paragraph.firstLineHeadIndent
    p.headIndent = paragraph.headIndent
    return p
  }

  // MARK: - AppKit resolution

  #if canImport(AppKit)
    private static func resolveAppKit(_ color: MarkdownColor) -> NSColor {
      switch color {
      case .rgb(let hex): return NSColor.hex(hex)
      case .label: return .labelColor
      case .secondaryLabel: return .secondaryLabelColor
      case .tertiaryLabel: return .tertiaryLabelColor
      case .link: return .linkColor
      case .separator: return .separatorColor
      case .systemRed: return .systemRed
      case .systemBlue: return .systemBlue
      case .controlAccent: return .controlAccentColor
      case .systemBackground: return .windowBackgroundColor
      case .quaternarySystemFill: return .quaternarySystemFill
      }
    }

    private static func resolveAppKit(_ font: MarkdownFont) -> NSFont {
      let m = MarkdownMetrics.standard
      switch font.kind {
      case .body: return base(font, default: .systemFont(ofSize: m.bodyFontSize))
      case .code:
        return base(font, default: .monospacedSystemFont(ofSize: m.codeFontSize, weight: .regular))
      case .heading(let level):
        let size = m.headingSizes[max(0, min(5, level - 1))]
        let weight: NSFont.Weight = level <= 3 ? .bold : .semibold
        let f = NSFont.systemFont(ofSize: size, weight: weight)
        return withTraits(font, on: f)
      case .chrome:
        let w: NSFont.Weight = m.chromeFontWeight == .bold ? .bold : .semibold
        return base(font, default: .systemFont(ofSize: m.chromeFontSize, weight: w))
      }
    }

    private static func base(_ font: MarkdownFont, default d: NSFont) -> NSFont {
      let weight: NSFont.Weight = {
        switch font.weight {
        case .regular: return .regular
        case .semibold: return .semibold
        case .bold: return .bold
        }
      }()
      // Use the kind-appropriate base (monospaced for code) with the font's size.
      let f: NSFont
      switch font.kind {
      case .code: f = NSFont.monospacedSystemFont(ofSize: font.size, weight: weight)
      default: f = d.withSize(font.size)
      }
      return withTraits(font, on: f)
    }

    private static func withTraits(_ font: MarkdownFont, on f: NSFont) -> NSFont {
      guard !font.traits.isEmpty else { return f }
      var symTraits: NSFontDescriptor.SymbolicTraits = []
      if font.traits.contains(.bold) { symTraits.insert(.bold) }
      if font.traits.contains(.italic) { symTraits.insert(.italic) }
      let desc = f.fontDescriptor.withSymbolicTraits(symTraits)
      return NSFont(descriptor: desc, size: f.pointSize) ?? f
    }
  #endif

  // MARK: - UIKit resolution

  #if canImport(UIKit)
    private static func resolveUIKit(_ color: MarkdownColor) -> UIColor {
      switch color {
      case .rgb(let hex): return UIColor.hex(hex)
      case .label: return .label
      case .secondaryLabel: return .secondaryLabel
      case .tertiaryLabel: return .tertiaryLabel
      case .link: return .link
      case .separator: return .separator
      case .systemRed: return .systemRed
      case .systemBlue: return .systemBlue
      case .controlAccent: return .tintColor
      case .systemBackground: return .systemBackground
      case .quaternarySystemFill: return .quaternarySystemFill
      }
    }

    private static func resolveUIKit(_ font: MarkdownFont) -> UIFont {
      let m = MarkdownMetrics.standard
      let weight: UIFont.Weight = {
        switch font.weight {
        case .regular: return .regular
        case .semibold: return .semibold
        case .bold: return .bold
        }
      }()
      let f: UIFont
      switch font.kind {
      case .code: f = .monospacedSystemFont(ofSize: font.size, weight: weight)
      case .heading(let level):
        let size = m.headingSizes[max(0, min(5, level - 1))]
        let w: UIFont.Weight = level <= 3 ? .bold : .semibold
        f = .systemFont(ofSize: size, weight: w)
      default: f = .systemFont(ofSize: font.size, weight: weight)
      }
      guard !font.traits.isEmpty else { return f }
      var symTraits: UIFontDescriptor.SymbolicTraits = []
      if font.traits.contains(.bold) { symTraits.insert(.traitBold) }
      if font.traits.contains(.italic) { symTraits.insert(.traitItalic) }
      if let desc = f.fontDescriptor.withSymbolicTraits(symTraits) {
        return UIFont(descriptor: desc, size: f.pointSize)
      }
      return f
    }
  #endif

  // MARK: - Render

  /// The code-syntax palette, resolved from the current platform appearance.
  /// Used by the parser's token-coloring pass (the `MarkdownStyling` protocol
  /// intentionally omits `codeScheme` so MdCore stays decoupled from MdCode's
  /// appearance resolution).
  public static func currentCodeScheme() -> CodeColorScheme { CodeColorScheme.systemAware }

  /// Converts a parser-built attributed string (platform-neutral attribute
  /// values) into a native attributed string by resolving every attribute
  /// value through the platform renderer.
  ///
  /// Values that are already native (NSValue-wrapped NSRange for command spans,
  /// Bool, URL, Int for strikethrough/underline, String) pass through unchanged.
  public static func render(_ source: NSAttributedString) -> NSAttributedString {
    let out = NSMutableAttributedString(attributedString: source)
    out.beginEditing()
    let full = NSRange(location: 0, length: out.length)
    out.enumerateAttributes(in: full, options: []) { attrs, range, _ in
      var resolved: [NSAttributedString.Key: Any] = [:]
      for (key, value) in attrs {
        switch value {
        case let c as MarkdownColor: resolved[key] = resolve(c)
        case let f as MarkdownFont: resolved[key] = resolve(f)
        case let p as MarkdownParagraph: resolved[key] = resolve(p)
        default: resolved[key] = value
        }
      }
      out.setAttributes(resolved, range: range)
    }
    out.endEditing()
    return out
  }
}

#if canImport(AppKit)
  extension NSColor {
    /// sRGB color from a 6-digit hex value (0xRRGGBB).
    static func hex(_ hex: UInt32) -> NSColor {
      NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
  }
#elseif canImport(UIKit)
  extension UIColor {
    /// sRGB color from a 6-digit hex value (0xRRGGBB).
    static func hex(_ hex: UInt32) -> UIColor {
      UIColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
  }
#endif
