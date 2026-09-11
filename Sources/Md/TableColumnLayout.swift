import CoreText
import Foundation

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// Column geometry for a GFM table rendered as a live-preview grid.
///
/// WHY THIS EXISTS — the editor's central invariant is that the styled attributed
/// string is CHARACTER-IDENTICAL to the source (the live view re-applies it to the
/// text storage on every keystroke), so a table's columns can never be padded by
/// inserting spaces. Measured facts on this SDK that shaped the design:
///
///   * `.kern` on a character shifts everything AFTER it: `"abc | def"` moves its
///     pipe 32.14 → 52.14 with a `+20` kern on the `'c'` (or on the space); `-4` moves
///     it to 28.14. A kern ON the pipe moves only what follows it (the pipe's own x is
///     unchanged) — which is how the hidden-pipe trick below works.
///   * A kern of `-advance` cancels a character's width without touching the string.
///   * Glyph substitution CANNOT produce a zero-advance character here: SF Mono
///     (`.AppleSystemUIFontMonospaced-Regular`) has NO U+200B/200C/200D/2060/FEFF
///     glyph, so the layout manager's zero-glyph fallback resolves to the SPACE glyph
///     and the advance survives (measured 8.036 = a full advance). Grid mode therefore
///     hides the pipes with a `-advance` kern, not with a glyph substitution.
///   * Tab stops are not usable either: a literal tab snaps to `NSTextTab` stops, but
///     substituting the pipe's glyph with the tab glyph does NOT (measured identical x
///     with and without the substitution).
public enum TableColumnLayout {

  /// Target positions (container-relative; 0 = the table's left edge) of each column's
  /// content and of each vertical grid line, plus the table's total width.
  public struct Model: Equatable, Sendable {
    /// x where each column's content begins (one per column).
    public var contentTargets: [CGFloat]
    /// x of each vertical grid line: the leading edge, one per column boundary, and the
    /// trailing edge — so `count == columnCount + 1`.
    public var separatorTargets: [CGFloat]
    /// Total table width in points (the trailing grid line's x).
    public var tableWidth: CGFloat
  }

  /// Builds the grid: `padding` on both sides of every column, columns as wide as their
  /// widest cell. Pipe characters are NOT accounted for — in grid mode they are made
  /// zero-width (see `nullingKern`), so they contribute no advance.
  public static func model(columnContentWidths: [CGFloat], padding: CGFloat) -> Model {
    var contentTargets: [CGFloat] = []
    var separatorTargets: [CGFloat] = [0]
    var x: CGFloat = 0
    for width in columnContentWidths {
      x += padding
      contentTargets.append(x)
      x += width + padding
      separatorTargets.append(x)
    }
    return Model(contentTargets: contentTargets, separatorTargets: separatorTargets, tableWidth: x)
  }

  /// `.kern` deltas that move every anchor onto its target x. Anchors MUST be supplied
  /// in ascending character order; `naturalEndX` is the un-kerned x of the anchor
  /// character's END (the measured width of the row prefix through that character), and
  /// each delta accounts for the deltas already applied to its left.
  public static func deltas(
    anchors: [(anchorCharIndex: Int, targetX: CGFloat, naturalEndX: CGFloat)]
  ) -> [(anchorCharIndex: Int, delta: CGFloat)] {
    var out: [(anchorCharIndex: Int, delta: CGFloat)] = []
    var applied: CGFloat = 0
    for a in anchors {
      let delta = a.targetX - (a.naturalEndX + applied)
      out.append((anchorCharIndex: a.anchorCharIndex, delta: delta))
      applied += delta
    }
    return out
  }

  /// The kern that makes one character occupy no width (`-advance`), used to hide a
  /// table's pipe characters without deleting them.
  public static func nullingKern(of character: UniChar, in font: PlatformFont) -> CGFloat {
    -advance(of: character, in: font)
  }

  /// Advance of a single character in `font` (0 when the font has no glyph for it).
  public static func advance(of character: UniChar, in font: PlatformFont) -> CGFloat {
    var chars: [UniChar] = [character]
    var glyphs = [CGGlyph](repeating: 0, count: 1)
    guard CTFontGetGlyphsForCharacters(font as CTFont, &chars, &glyphs, 1), glyphs[0] != 0
    else { return 0 }
    var advances = [CGSize](repeating: .zero, count: 1)
    CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, glyphs, &advances, 1)
    return advances[0].width
  }

  /// Width of `range` in `attributed`, skipping HIDDEN syntax characters.
  ///
  /// Deliberately NOT `CTLineGetTypographicBounds`: that returns the union bounds of the
  /// INK, which excludes trailing whitespace — so measuring a row prefix that ends in a
  /// cell's padding space (the common case) under-reports by one space's width and every
  /// column drifts by one character (verified: the naive measurement landed column 1 at
  /// 32.14 instead of 40.11). This sums the real per-character advances instead.
  ///
  /// Hidden syntax (`.markdownSyntax`) is skipped because the layout manager substitutes a
  /// zero-advance glyph for it; in grid mode the pipe characters are marked as syntax AND
  /// carry a `nullingKern`, so skipping them equals their laid-out width of 0. `.kern` is
  /// likewise ignored, so measurements are taken from a kern-free source (the parser
  /// measures a snapshot taken before it writes any alignment kerns).
  public static func measuredWidth(of range: NSRange, in attributed: NSAttributedString)
    -> CGFloat
  {
    guard range.length > 0, NSMaxRange(range) <= attributed.length else { return 0 }
    let text = attributed.string as NSString
    var total: CGFloat = 0
    var i = range.location
    while i < NSMaxRange(range) {
      var effective = NSRange(location: i, length: 0)
      let attrs = attributed.attributes(at: i, effectiveRange: &effective)
      let end = min(NSMaxRange(effective), NSMaxRange(range))
      if attrs[.markdownSyntax] == nil, end > i, let font = attrs[.font] as? PlatformFont {
        let count = end - i
        var chars = [UniChar](repeating: 0, count: count)
        text.getCharacters(&chars, range: NSRange(location: i, length: count))
        var glyphs = [CGGlyph](repeating: 0, count: count)
        guard CTFontGetGlyphsForCharacters(font as CTFont, &chars, &glyphs, count) else {
          i = end
          continue
        }
        var advances = [CGSize](repeating: .zero, count: count)
        CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, glyphs, &advances, count)
        for a in advances { total += a.width }
      }
      i = end > i ? end : i + 1
    }
    return total
  }
}
