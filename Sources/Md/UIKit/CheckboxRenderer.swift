#if canImport(UIKit)
  import UIKit

  /// Draws the task-list checkbox. The layout manager renders this image in place
  /// of the "[x]"/"[ ]" characters (which stay in the source string, marked
  /// .markdownCheckbox). Matches `Sources/Md/CheckboxAttachment.swift` (AppKit):
  /// the SAME SF Symbols, weights, and palette colors, so both platforms draw
  /// identical checkboxes.
  ///
  /// iOS SDK note: unlike AppKit, `UIImage.SymbolConfiguration.applying(_:)`
  /// returns a NON-optional configuration (no `!` needed after it), and the
  /// `paletteColors:` init must be spelled with the full type name — the `.init`
  /// shorthand fails overload resolution inside a chained `applying` call.
  public enum CheckboxRenderer {
    public static func image(
      checked: Bool, size: CGFloat = MarkdownMetrics.standard.checkboxImageSize
    ) -> UIImage {
      if checked {
        UIImage(systemName: "checkmark.circle.fill")!.applyingSymbolConfiguration(
          UIImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(
            UIImage.SymbolConfiguration(paletteColors: [.white, .systemBlue])))!
      } else {
        UIImage(systemName: "circle")!.applyingSymbolConfiguration(
          UIImage.SymbolConfiguration(pointSize: size, weight: .regular).applying(
            UIImage.SymbolConfiguration(paletteColors: [.systemBlue])))!
      }
    }
  }
#endif
