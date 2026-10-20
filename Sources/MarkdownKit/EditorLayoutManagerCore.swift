// TextKit (AppKit, UIKit): the editors' layout and rendering. Elsewhere the portable editor draws with SwiftUI.
#if canImport(AppKit) || canImport(UIKit)
import Foundation

#if canImport(AppKit)
  import AppKit
  import CoreText
  public typealias PlatformImage = NSImage
  public typealias PlatformFont = NSFont
  public typealias PlatformColor = NSColor
  public typealias PlatformBezierPath = NSBezierPath
#elseif canImport(UIKit)
  import UIKit
  import CoreText
  public typealias PlatformImage = UIImage
  public typealias PlatformFont = UIFont
  public typealias PlatformColor = UIColor
  public typealias PlatformBezierPath = UIBezierPath
#endif

/// TextKit 1 layout manager core — platform-neutral glyph/geometry/merge logic.
///
/// Not actor-isolated: NSLayoutManager's drawing/layout overrides are nonisolated
/// SDK methods called on the main thread, and the class only touches main-thread
/// state (textStorage, activeCharacterRange). The AppKit stack compiles this as
/// plain (nonisolated) code with identical runtime behavior.
///
/// The core owns run classification and geometry; actual drawing (bezier paths,
/// colors, images, text) is delegated to `open` hooks overridden by the
/// platform-specific subclasses in `MarkdownKit` (AppKit) and `MdUIKit` (UIKit).
open class EditorLayoutManagerCore: NSLayoutManager {
  /// The caret/selection character range. Visibility is derived from it:
  /// line-level commands (heading '#', blockquote '>', fences, table pipes) show
  /// while the caret is on their line; inline delimiters (**bold**, `code`, links)
  /// show while the caret is inside the command's span. Outside those, syntax
  /// glyphs are replaced with a zero-width glyph at layout time (Obsidian-style
  /// live preview: hidden commands collapse to zero width, so text shifts when
  /// the caret lands on/inside a command).
  public var activeCharacterRange: NSRange = NSRange(location: 0, length: 0)

  /// The metrics this layout manager draws with. The editor sets it to its own
  /// metrics, so a customized `MarkdownMetrics` reaches the drawn geometry too.
  public var metrics: MarkdownMetrics = .standard

  /// False for a read-only viewer: the caret never reveals syntax (no line or span is
  /// ever "active"), so the document always renders as its preview.
  public var revealsSyntax = true

  /// One code block's reusable "chrome": the copy-button frame plus the block's
  /// document range (to read the code for copying) and language name (for the
  /// label). Frames are in the layout manager's drawing coordinates (== the text
  /// view's coordinate space after `origin`), so the editor hit-tests them with a
  /// converted click point.
  public struct CodeBlockChrome {
    public let copyFrame: CGRect
    public let blockRange: NSRange
    public let language: String?
    public var copied: Bool
  }
  /// Copy buttons for every code block in the document, in drawing coordinates for
  /// `origin` (the text view's `textContainerOrigin`). Computed from the current layout,
  /// not cached by the last draw pass: a partial redraw elsewhere (typing in another
  /// paragraph) must not leave a visible button dead.
  public func copyButtons(origin: CGPoint) -> [CodeBlockChrome] {
    var out: [CodeBlockChrome] = []
    for r in EditorLayoutManagerCore.mergedRuns(documentBackgroundRuns().codeRuns) {
      let fillRange = codeBlockFillRange(for: r) ?? r
      guard let union = codeBlockUnion(forCharacterRange: fillRange, at: origin),
        let chrome = codeChromeLayout(forCharacterRange: r, union: union, at: origin)
      else { continue }
      out.append(
        CodeBlockChrome(
          copyFrame: chrome.hitFrame, blockRange: r, language: chrome.language,
          copied: copiedBlockRange == r))
    }
    return out
  }
  /// Flash state: which block most recently showed "Copied".
  public private(set) var copiedBlockRange: NSRange?

  /// A grid-mode table's corner button: grid ⇄ source. Frames are in the layout manager's
  /// drawing coordinates (== the text view's space after `origin`), so the editor
  /// hit-tests them with a converted click point — the same contract as `copyButtons`.
  public struct TableToggle {
    public let frame: CGRect
    /// Which table (0-based, document order) this button belongs to.
    public let tableOrdinal: Int
  }
  /// Grid/source toggles for every grid-mode table in the document, in drawing
  /// coordinates for `origin` — computed on demand, like `copyButtons(origin:)`.
  public func tableToggles(origin: CGPoint) -> [TableToggle] {
    EditorLayoutManagerCore.mergedRuns(documentBackgroundRuns().tableRuns).compactMap {
      tableGridGeometry(forCharacterRange: $0, at: origin)?.toggle
    }
  }

  /// Background runs over the whole document (used by the on-demand hit tests).
  private func documentBackgroundRuns() -> BackgroundRuns {
    guard let storage = textStorage, storage.length > 0 else { return BackgroundRuns() }
    let glyphs = glyphRange(
      forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
    return classifyBackgroundRuns(forGlyphRange: glyphs)
  }

  /// Marks this block's button as "Copied" (flash). The editor schedules the
  /// matching `clearCopied` after a delay and redraws.
  public func markCopied(_ blockRange: NSRange) { copiedBlockRange = blockRange }
  public func clearCopied(_ blockRange: NSRange) {
    if copiedBlockRange == blockRange { copiedBlockRange = nil }
  }

  private func isHiddenCharacter(_ charIndex: Int, in storage: NSTextStorage) -> Bool {
    guard charIndex >= 0, charIndex < storage.length else { return false }
    var eff = NSRange(location: 0, length: 0)
    let attrs = storage.attributes(at: charIndex, effectiveRange: &eff)
    // A drawn image replaces its whole source (alt text included); its first character
    // carries the image's width as a kern (see `updateImageSlots`).
    if let spec = attrs[.markdownImageSpec] as? MarkdownImageSpec, renderedImageSize(spec) != nil {
      return true
    }
    guard attrs[.markdownSyntax] != nil else { return false }
    if attrs[.markdownCheckbox] != nil { return false }  // keep the checkbox slot
    if attrs[.markdownListMarker] != nil { return false }  // list markers are always shown
    return !isSyntaxVisible(NSRange(location: charIndex, length: 1), attrs: attrs)
  }

  /// True when the char is the middle of a "[x]"/"[ ]" checkbox range (the 'x' or
  /// the space between the brackets). Its glyph is substituted with a fixed-width
  /// glyph in setGlyphs so checked and unchecked rows have IDENTICAL slot widths
  /// (the literal 'x' is wider than a space in most fonts, which made checked rows
  /// wider than unchecked ones). The literal glyphs are never drawn — the checkbox
  /// image replaces them — so only the slot width matters.
  private func isCheckboxMiddle(_ charIndex: Int, in storage: NSTextStorage) -> Bool {
    guard charIndex >= 0, charIndex < storage.length else { return false }
    var eff = NSRange(location: 0, length: 0)
    guard storage.attribute(.markdownCheckbox, at: charIndex, effectiveRange: &eff) != nil else {
      return false
    }
    return charIndex == eff.location + 1
  }

  /// Whether a syntax character range (within one attribute run) is currently visible.
  private func isSyntaxVisible(_ charRange: NSRange, attrs: [NSAttributedString.Key: Any]) -> Bool {
    if attrs[.markdownLineCommand] != nil {
      // Line-level command: visible while the caret is on its line.
      return lineContainsCaret(charRange.location)
    }
    if let spanValue = attrs[.markdownCommandSpan] as? NSValue {
      // Inline command: visible while the caret is inside (or just after) its span.
      return spanIsActive(spanValue.rangeValue)
    }
    return false  // syntax with no line/span context — always hidden
  }

  private func lineContainsCaret(_ charIndex: Int) -> Bool {
    guard revealsSyntax, let storage = textStorage else { return false }
    let ns = storage.string as NSString
    let caret = min(max(activeCharacterRange.location, 0), ns.length)
    return NSLocationInRange(charIndex, ns.lineRange(for: NSRange(location: caret, length: 0)))
  }

  private func spanIsActive(_ span: NSRange) -> Bool {
    guard revealsSyntax else { return false }
    let sel = activeCharacterRange
    if NSIntersectionRange(span, sel).length > 0 { return true }
    guard sel.length == 0 else { return false }
    let loc = sel.location
    if NSLocationInRange(loc, span) { return true }
    return loc == NSMaxRange(span)  // caret just after the closing delimiter
  }

  /// Character ranges whose visibility can change when the caret is at `selection`
  /// (the lines it touches plus any command spans adjacent to it).
  public func affectedRange(for selection: NSRange) -> NSRange {
    guard let storage = textStorage else { return NSRange(location: 0, length: 0) }
    let ns = storage.string as NSString
    let loc = min(max(selection.location, 0), ns.length)
    let clamped = NSRange(location: loc, length: min(selection.length, ns.length - loc))
    var union = ns.lineRange(for: clamped)
    for idx in [
      clamped.location, clamped.location - 1, clamped.location + 1, NSMaxRange(clamped) - 1,
    ] { if let span = commandSpan(at: idx) { union = NSUnionRange(union, span) } }
    return union
  }

  private func commandSpan(at index: Int) -> NSRange? {
    guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
    guard
      let v = storage.attribute(.markdownCommandSpan, at: index, effectiveRange: nil) as? NSValue
    else { return nil }
    return v.rangeValue
  }

  // MARK: - Zero-width glyph substitution for hidden command symbols

  // TextKit 1 layout runs on the main thread; these caches are only touched from
  // setGlyphs/drawGlyphs (main-thread callbacks), so they are safe to treat as
  // nonisolated shared state under Swift 6. Under Swift Testing, however, the
  // headless probes run layout on CONCURRENT test threads, so a bare Dictionary is
  // a data race (a corrupted cache crashed the suite with "unrecognized selector").
  // Guard ALL glyph caches with one lock. setGlyphs/drawGlyphs callers hold it only
  // briefly, and the cache is a small constant-size dictionary, so contention is nil.
  private static nonisolated(unsafe) let glyphCacheLock = NSLock()
  private static nonisolated(unsafe) var zeroGlyphCache: [String: CGGlyph] = [:]

  /// A real glyph with zero advancement for the given font. NSNullGlyph + .null property
  /// is NOT used: a run of null-property glyphs at the start of a line gets split into
  /// its own line fragment by the layout manager, corrupting line heights (a selected
  /// heading visibly grew and pushed the document down). A real zero-width glyph keeps
  /// the run intact. Fonts without a zero-width glyph (SF Mono) fall back to space.
  private static func zeroGlyph(for font: PlatformFont) -> CGGlyph {
    let key = font.fontName
    glyphCacheLock.lock()
    if let cached = zeroGlyphCache[key] {
      glyphCacheLock.unlock()
      return cached
    }
    glyphCacheLock.unlock()
    var glyph = CGGlyph(0)
    for char: UniChar in [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF] {
      var ch: [UniChar] = [char]
      var gl = [CGGlyph](repeating: 0, count: 1)
      CTFontGetGlyphsForCharacters(font as CTFont, &ch, &gl, 1)
      if gl[0] != 0 {
        var adv = [CGSize](repeating: .zero, count: 1)
        CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, gl, &adv, 1)
        if adv[0].width == 0 {
          glyph = gl[0]
          break
        }
      }
    }
    if glyph == 0 {
      var sp: [UniChar] = [0x20]
      var spg = [CGGlyph](repeating: 0, count: 1)
      CTFontGetGlyphsForCharacters(font as CTFont, &sp, &spg, 1)
      glyph = spg[0]
    }
    glyphCacheLock.lock()
    zeroGlyphCache[key] = glyph
    glyphCacheLock.unlock()
    return glyph
  }

  /// Fixed-width glyph substituted for a checkbox range's middle char: EN SPACE
  /// (U+2002, 0.5 em) when the font has it, else EN QUAD (U+2000), else plain space.
  /// Gives "[x]" and "[ ]" the same slot width and enough room for the drawn
  /// checkbox image (which replaces the literal glyphs, so only width matters).
  private static nonisolated(unsafe) var checkboxSlotGlyphCache: [String: CGGlyph] = [:]

  private static func checkboxSlotGlyph(for font: PlatformFont) -> CGGlyph {
    let key = font.fontName
    glyphCacheLock.lock()
    if let cached = checkboxSlotGlyphCache[key] {
      glyphCacheLock.unlock()
      return cached
    }
    glyphCacheLock.unlock()
    var glyph = CGGlyph(0)
    for char: UniChar in [0x2002, 0x2000] {  // EN SPACE, EN QUAD — both 0.5 em
      var ch: [UniChar] = [char]
      var gl = [CGGlyph](repeating: 0, count: 1)
      CTFontGetGlyphsForCharacters(font as CTFont, &ch, &gl, 1)
      if gl[0] != 0 {
        glyph = gl[0]
        break
      }
    }
    if glyph == 0 {
      var sp: [UniChar] = [0x20]
      var spg = [CGGlyph](repeating: 0, count: 1)
      CTFontGetGlyphsForCharacters(font as CTFont, &sp, &spg, 1)
      glyph = spg[0]
    }
    glyphCacheLock.lock()
    checkboxSlotGlyphCache[key] = glyph
    glyphCacheLock.unlock()
    return glyph
  }

  /// Substitutes the plain unordered marker character ("-", "*", "+") with the
  /// BULLET glyph "•" (U+2022) so a hyphen renders as a bullet while the source
  /// keeps the literal "-" (the verbatim invariant survives: glyph substitution
  /// never touches the attributed string). Ordered markers ("1.") and task-list
  /// "-" do NOT carry .markdownBullet and are left alone. Falls back to the plain
  /// marker glyph if the font has no bullet.
  private static nonisolated(unsafe) var bulletGlyphCache: [String: CGGlyph] = [:]

  private static func bulletGlyph(for font: PlatformFont) -> CGGlyph {
    let key = font.fontName
    glyphCacheLock.lock()
    if let cached = bulletGlyphCache[key] {
      glyphCacheLock.unlock()
      return cached
    }
    glyphCacheLock.unlock()
    var glyph = CGGlyph(0)
    var ch: [UniChar] = [0x2022]  // •
    var gl = [CGGlyph](repeating: 0, count: 1)
    CTFontGetGlyphsForCharacters(font as CTFont, &ch, &gl, 1)
    if gl[0] != 0 {
      glyph = gl[0]
    } else {
      var m: [UniChar] = [0x2D]  // hyphen fallback
      var mg = [CGGlyph](repeating: 0, count: 1)
      CTFontGetGlyphsForCharacters(font as CTFont, &m, &mg, 1)
      glyph = mg[0]
    }
    glyphCacheLock.lock()
    bulletGlyphCache[key] = glyph
    glyphCacheLock.unlock()
    return glyph
  }

  private static nonisolated(unsafe) var substituteGlyphCache: [String: CGGlyph] = [:]

  /// The font's glyph for one UTF-16 code unit (an entity's decoded character), or nil
  /// when the font has none.
  private static func glyph(for unit: UInt16, in font: PlatformFont) -> CGGlyph? {
    let key = "\(font.fontName)/\(unit)"
    glyphCacheLock.lock()
    if let cached = substituteGlyphCache[key] {
      glyphCacheLock.unlock()
      return cached == 0 ? nil : cached
    }
    glyphCacheLock.unlock()
    var ch: [UniChar] = [unit]
    var gl = [CGGlyph](repeating: 0, count: 1)
    CTFontGetGlyphsForCharacters(font as CTFont, &ch, &gl, 1)
    glyphCacheLock.lock()
    substituteGlyphCache[key] = gl[0]
    glyphCacheLock.unlock()
    return gl[0] == 0 ? nil : gl[0]
  }

  /// Advance of the glyph a hidden character draws as (zero for most fonts; a space for
  /// fonts without a zero-width glyph, e.g. SF Mono).
  static func hiddenGlyphAdvance(for font: PlatformFont) -> CGFloat {
    var glyph = zeroGlyph(for: font)
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, &glyph, &advance, 1)
    return advance.width
  }

  /// True when the char is the actual bullet character of a plain unordered list
  /// marker ("-", "*", "+"). Its glyph is substituted with "•" in setGlyphs.
  private func isBulletChar(_ charIndex: Int, in storage: NSTextStorage) -> Bool {
    guard charIndex >= 0, charIndex < storage.length else { return false }
    return storage.attribute(.markdownBullet, at: charIndex, effectiveRange: nil) != nil
  }
  public override func setGlyphs(
    _ glyphs: UnsafePointer<CGGlyph>,
    properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
    characterIndexes charIndexes: UnsafePointer<Int>, font: PlatformFont,
    forGlyphRange glyphRange: NSRange
  ) {
    guard glyphRange.length > 0, let storage = textStorage else {
      super.setGlyphs(
        glyphs, properties: props, characterIndexes: charIndexes, font: font,
        forGlyphRange: glyphRange)
      return
    }
    var zeroed = [Bool](repeating: false, count: glyphRange.length)
    var middleSlot = [Bool](repeating: false, count: glyphRange.length)
    var bullet = [Bool](repeating: false, count: glyphRange.length)
    var substitutes: [Int: CGGlyph] = [:]
    var slotGlyph: CGGlyph? = nil
    var bulletGlyph: CGGlyph? = nil
    var anyChange = false
    for i in 0..<glyphRange.length {
      let charIndex = charIndexes[i]
      if isHiddenCharacter(charIndex, in: storage) {
        // A hidden entity's first character draws the character it stands for.
        if let unit = storage.attribute(.markdownGlyphSubstitute, at: charIndex, effectiveRange: nil)
          as? NSNumber, let glyph = Self.glyph(for: unit.uint16Value, in: font)
        {
          substitutes[i] = glyph
        } else {
          zeroed[i] = true
        }
        anyChange = true
      } else if isCheckboxMiddle(charIndex, in: storage) {
        middleSlot[i] = true
        if slotGlyph == nil { slotGlyph = Self.checkboxSlotGlyph(for: font) }
        anyChange = true
      } else if isBulletChar(charIndex, in: storage) {
        bullet[i] = true
        if bulletGlyph == nil { bulletGlyph = Self.bulletGlyph(for: font) }
        anyChange = true
      }
    }
    guard anyChange else {
      super.setGlyphs(
        glyphs, properties: props, characterIndexes: charIndexes, font: font,
        forGlyphRange: glyphRange)
      return
    }
    var newGlyphs = [CGGlyph](repeating: 0, count: glyphRange.length)
    var newProps = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
    for i in 0..<glyphRange.length {
      if let substitute = substitutes[i] {
        newGlyphs[i] = substitute
        newProps[i] = []
      } else if zeroed[i] {
        newGlyphs[i] = Self.zeroGlyph(for: font)
        newProps[i] = []  // real glyph, normal property — keeps the line fragment intact
      } else if middleSlot[i], let slotGlyph {
        newGlyphs[i] = slotGlyph
        newProps[i] = props[i]
      } else if bullet[i], let bulletGlyph {
        newGlyphs[i] = bulletGlyph
        newProps[i] = props[i]
      } else {
        newGlyphs[i] = glyphs[i]
        newProps[i] = props[i]
      }
    }
    newGlyphs.withUnsafeBufferPointer { gp in
      newProps.withUnsafeBufferPointer { pp in
        super.setGlyphs(
          gp.baseAddress!, properties: pp.baseAddress!, characterIndexes: charIndexes, font: font,
          forGlyphRange: glyphRange)
      }
    }
  }

  // MARK: - Backgrounds (continuous code-block fills)

  /// Classifies the glyph range's attribute runs into code/quote/inline-code/plain.
  /// Returns (codeRuns, quoteRuns, inlineCodeRuns, plainRuns) — all clamped to the
  /// glyph range. Adjacent sub-runs of the same kind merge.
  public struct BackgroundRuns {
    public var codeRuns: [NSRange] = []
    public var quoteRuns: [NSRange] = []
    public var inlineCodeRuns: [NSRange] = []
    public var tableRuns: [NSRange] = []
    public var plainRuns: [NSRange] = []
  }

  public func classifyBackgroundRuns(forGlyphRange glyphsToShow: NSRange) -> BackgroundRuns {
    var runs = BackgroundRuns()
    guard let storage = textStorage else { return runs }
    let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    var i = charRange.location
    let end = NSMaxRange(charRange)
    while i < end {
      var effective = NSRange(location: i, length: 0)
      let attrs = storage.attributes(at: i, effectiveRange: &effective)
      if effective.length == 0 { effective = NSRange(location: i, length: 1) }
      let clamped = NSIntersectionRange(effective, charRange)
      if clamped.length > 0 {
        if attrs[.markdownCodeBlock] != nil {
          runs.codeRuns.append(clamped)
        } else if attrs[.markdownBlockquote] != nil {
          // Adjacent quote sub-runs (line content vs attributed newline) merge
          // into one run so the bar is continuous across consecutive quote lines.
          if let last = runs.quoteRuns.last, NSMaxRange(last) == clamped.location {
            runs.quoteRuns[runs.quoteRuns.count - 1] = NSUnionRange(last, clamped)
          } else {
            runs.quoteRuns.append(clamped)
          }
        } else if attrs[.markdownInlineCode] != nil {
          // Adjacent inline-code sub-runs (content vs attribute boundaries)
          // merge into one chip per code span.
          if let last = runs.inlineCodeRuns.last, NSMaxRange(last) == clamped.location {
            runs.inlineCodeRuns[runs.inlineCodeRuns.count - 1] = NSUnionRange(last, clamped)
          } else {
            runs.inlineCodeRuns.append(clamped)
          }
        } else if attrs[.markdownTableGrid] != nil {
          // A grid-mode table: its lines (and their newlines) form one run so the grid is
          // drawn over the whole table, not per line.
          if let last = runs.tableRuns.last, NSMaxRange(last) == clamped.location {
            runs.tableRuns[runs.tableRuns.count - 1] = NSUnionRange(last, clamped)
          } else {
            runs.tableRuns.append(clamped)
          }
        } else {
          runs.plainRuns.append(clamped)
        }
      }
      i = NSMaxRange(clamped)
      if i <= clamped.location { i += 1 }  // safety against zero-progress
    }
    return runs
  }

  public override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
    guard textStorage != nil else {
      super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
      return
    }
    let runs = classifyBackgroundRuns(forGlyphRange: glyphsToShow)
    // Merge adjacent per-token sub-runs into ONE block per fence. Token colors
    // (keyword/string/number) split `.markdownCodeBlock`'s span into many adjacent
    // effective ranges; drawing a rounded rect per run would tile the block with
    // per-token chips. Runs that tile contiguously belong to the same block; a
    // gap (a non-code line between fences) starts a new block.
    let codeBlocks = EditorLayoutManagerCore.mergedRuns(runs.codeRuns)
    for r in codeBlocks {
      // The background FILL covers the whole fenced block (content PLUS the ```
      // open/close fence lines) — that's the `.markdownCodeBlockFill` attribute
      // (NSValue(range:)) attached at the content start. The content-only run `r`
      // still drives chrome anchoring, the language label, and what Copy copies.
      let fillRange = codeBlockFillRange(for: r) ?? r
      guard let union = codeBlockUnion(forCharacterRange: fillRange, at: origin) else { continue }
      drawCodeBlockBackground(union: union, at: origin)
      // super draws selection highlights and any background attributes over the
      // whole block (fences included) so selection shows over every line.
      super.drawBackground(
        forGlyphRange: glyphRange(forCharacterRange: fillRange, actualCharacterRange: nil), at: origin)
      drawCodeChrome(forCharacterRange: r, union: union, at: origin)
    }
    for r in runs.quoteRuns {
      // super first so the bar stays visible on top of the selection highlight
      super.drawBackground(
        forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil), at: origin)
      drawQuoteBar(forCharacterRange: r, at: origin)
    }
    for r in runs.inlineCodeRuns {
      // super first so the selection highlight stays visible on top of the chip
      super.drawBackground(
        forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil), at: origin)
      drawInlineCodeChip(forCharacterRange: r, at: origin)
    }
    for r in EditorLayoutManagerCore.mergedRuns(runs.tableRuns) {
      // super first so the selection highlight stays visible on top of the grid
      super.drawBackground(
        forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil), at: origin)
      drawTableGrid(forCharacterRange: r, at: origin)
    }
    for r in runs.plainRuns {
      super.drawBackground(
        forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil), at: origin)
    }
  }

  /// The code block's background rect (union of every line's ink box) in drawing
  /// coordinates. Geometry only — shared by drawing and the copy-button hit test.
  private func codeBlockUnion(forCharacterRange r: NSRange, at origin: CGPoint) -> CGRect? {
    guard let storage = textStorage else { return nil }
    // The background must hug the code font's ACTUAL GLYPH INK per line
    // (CTLine path bounds), not the full line fragment (measured ~17pt for
    // 14pt SF Mono) nor a cap+descender estimate (which adds descender depth
    // below lines that have no descenders — the "bottom too big" complaint).
    let codeFont =
      (storage.attribute(.font, at: r.location, effectiveRange: nil) as? PlatformFont)
      ?? codeFontFallback()
    let asc = codeFont.ascender
    let desc = codeFont.descender  // negative
    let ascDesc = asc - desc  // typographic line height
    var rects: [CGRect] = []
    enumerateLineFragments(
      forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil)
    ) { rect, _, _, glyphRange, _ in
      // TextKit baseline within the fragment (fragment may be taller than the
      // font's line height due to spacing): baseline = top + asc/ascDesc * H.
      let baseline = rect.minY + (asc / ascDesc) * rect.height
      // Glyph ink of this line's text, relative to the baseline.
      var inkTop: CGFloat = asc  // fallback: typographic box
      var inkBottom: CGFloat = desc
      if let storage = self.textStorage {
        let charRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        if charRange.length > 0, charRange.location < storage.length {
          let sub = storage.attributedSubstring(from: charRange)
          let line = CTLineCreateWithAttributedString(sub)
          let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
          if !bounds.isNull, bounds.height > 0 {
            inkTop = bounds.maxY
            inkBottom = bounds.minY
          }
        }
      }
      let lineRect = CGRect(
        x: rect.minX, y: baseline - inkTop, width: rect.width, height: inkTop - inkBottom)
      rects.append(lineRect.offsetBy(dx: origin.x, dy: origin.y))
    }
    guard let first = rects.first, let last = rects.last else { return nil }
    // One block per fence: the union spans the FIRST line's ink top through the
    // LAST line's ink bottom at full content width. A single rounded rect rounds
    // only the block's own corners.
    return CGRect(
      x: first.minX, y: first.minY, width: first.width, height: last.maxY - first.minY)
  }

  private func drawTableGrid(forCharacterRange r: NSRange, at origin: CGPoint) {
    guard let geometry = tableGridGeometry(forCharacterRange: r, at: origin) else { return }
    drawTableGridHook(
      verticalLines: geometry.verticalLines, fromY: geometry.fromY, toY: geometry.toY)
    if let toggle = geometry.toggle { drawTableToggleHook(frame: toggle.frame, gridMode: true) }
  }

  /// A grid-mode table's vertical lines, vertical extent and corner toggle (if shown), in
  /// drawing coordinates. Geometry only — shared by drawing and the toggle hit test.
  private func tableGridGeometry(forCharacterRange r: NSRange, at origin: CGPoint)
    -> (verticalLines: [CGFloat], fromY: CGFloat, toY: CGFloat, toggle: TableToggle?)?
  {
    guard let storage = textStorage, r.location < storage.length else { return nil }
    guard
      let values = storage.attribute(.markdownTableGrid, at: r.location, effectiveRange: nil)
        as? [NSNumber], !values.isEmpty
    else { return nil }
    let glyphs = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
    guard glyphs.length > 0 else { return nil }
    var minY = CGFloat.greatestFiniteMagnitude
    var maxY = -CGFloat.greatestFiniteMagnitude
    var headerTop = CGFloat.greatestFiniteMagnitude
    var headerHeight: CGFloat = 0
    var isFirstFragment = true
    enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
      minY = min(minY, rect.minY)
      maxY = max(maxY, rect.maxY)
      if isFirstFragment {
        headerTop = rect.minY
        headerHeight = rect.height
        isFirstFragment = false
      }
    }
    guard minY <= maxY else { return nil }
    // The table's x values are relative to the container's left edge, while glyphs and
    // line fragments start one `lineFragmentPadding` further right — without this the
    // whole grid would be drawn one padding left of its text.
    let padding = textContainers.first?.lineFragmentPadding ?? 0
    let lines = values.map { origin.x + padding + CGFloat($0.doubleValue) }

    // Corner toggle (grid ⇄ source) at the top-right of the header row. Mirrors the
    // code-chrome rules: only when the block's true top is on screen (so a scrolled tall
    // table doesn't float its toggle mid-block), and hidden while the caret edits the
    // header line.
    let isBlockTop =
      r.location == 0
      || storage.attribute(.markdownTableGrid, at: r.location - 1, effectiveRange: nil) == nil
    var toggle: TableToggle? = nil
    if isBlockTop, !lineContainsCaret(r.location), let tableWidth = lines.last {
      let size = metrics.tableToggleSize
      let frame = CGRect(
        x: tableWidth - metrics.tableToggleInset - size,
        y: origin.y + headerTop + (headerHeight - size) / 2, width: size, height: size)
      let ordinal =
        (storage.attribute(.markdownTableOrdinal, at: r.location, effectiveRange: nil) as? NSNumber)?
        .intValue ?? 0
      toggle = TableToggle(frame: frame, tableOrdinal: ordinal)
    }
    return (lines, origin.y + minY, origin.y + maxY, toggle)
  }

  /// Rounded chip behind inline code (`` `code` ``), GitHub-style. One chip per line
  /// fragment the span covers (a wrapped span gets a chip on each line). Horizontally it
  /// spans the code glyphs (`boundingRect(forGlyphRange:in:)` — the fragment's `used`
  /// rect would span the WHOLE mixed line) plus padding; vertically it hugs the code
  /// font's ascender/descender box around the baseline plus padding. The line fragment
  /// is NOT used for height: it also carries the line and paragraph spacing, which
  /// pushed the chip far below the text (worst in headings).
  private func drawInlineCodeChip(forCharacterRange r: NSRange, at origin: CGPoint) {
    guard let storage = textStorage, r.location < storage.length,
      let container = textContainers.first
    else { return }
    let g = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
    guard g.length > 0 else { return }
    let font =
      (storage.attribute(.font, at: r.location, effectiveRange: nil) as? PlatformFont)
      ?? codeFontFallback()
    let hPad = metrics.inlineCodeChipHPad
    let vPad = metrics.inlineCodeChipVInset
    let height = font.ascender - font.descender + vPad * 2  // descender is negative
    let radius = max(0, min(metrics.inlineCodeChipMaxRadius, height / 2))
    enumerateLineFragments(forGlyphRange: g) { rect, _, _, lineGlyphs, _ in
      let sub = NSIntersectionRange(lineGlyphs, g)
      guard sub.length > 0 else { return }
      let bounds = self.boundingRect(forGlyphRange: sub, in: container)
      guard !bounds.isNull, bounds.width > 0 else { return }
      // `location(forGlyphAt:)` is relative to the fragment; its y is the baseline.
      let baseline = rect.minY + self.location(forGlyphAt: sub.location).y
      let chip = CGRect(
        x: origin.x + bounds.minX - hPad, y: origin.y + baseline - font.ascender - vPad,
        width: bounds.width + hPad * 2, height: height)
      self.drawInlineCodeChipHook(chip: chip, radius: radius)
    }
  }

  /// Draws the copy button (top-right) and language label (top-left) on the
  /// opening ``` fence line — one line ABOVE the first code-content line. Only drawn
  /// when the block's actual top line is on screen (a scrolled tall fence doesn't
  /// float the chrome mid-block).
  private func drawCodeChrome(forCharacterRange r: NSRange, union: CGRect, at origin: CGPoint) {
    guard let chrome = codeChromeLayout(forCharacterRange: r, union: union, at: origin) else {
      return
    }
    let font = chromeFont()
    if let language = chrome.language, let langRect = chrome.languageRect {
      drawChromeLabel(language, in: langRect, font: font, color: codeTextColor())
    }
    drawChromeLabel(chrome.copyLabel, in: chrome.copyRect, font: font, color: codeTextColor())
  }

  /// Where a code block's chrome goes, or nil when it is not shown (the block's top is
  /// not in `r`, or the caret is editing the fence line). Geometry only — shared by
  /// drawing and the copy-button hit test.
  private func codeChromeLayout(forCharacterRange r: NSRange, union: CGRect, at origin: CGPoint)
    -> (
      language: String?, languageRect: CGRect?, copyLabel: String, copyRect: CGRect,
      hitFrame: CGRect
    )?
  {
    guard let storage = textStorage else { return nil }
    // True top of this block: the char just before it is not code content.
    let isBlockTop =
      r.location == 0
      || storage.attribute(.markdownCodeBlock, at: r.location - 1, effectiveRange: nil) == nil
    guard isBlockTop else { return nil }
    // Hide the chrome while the caret is on the ``` fence line (editing the
    // fence marker itself) — language and Copy both disappear.
    if r.location > 0, lineContainsCaret(r.location - 1) { return nil }
    let language =
      storage.attribute(.markdownCodeLanguage, at: r.location, effectiveRange: nil) as? String
    // The ``` opening fence is the line immediately above the block's first
    // content line (code-fence lines aren't part of the .markdownCodeBlock
    // span). Anchor the chrome to THAT line fragment so it floats above the
    // block instead of overlapping the first code line. `union.minY` is a
    // fallback if the fence line has no glyphs (e.g. the block starts at EOF).
    var fenceTop = union.minY
    if r.location > 0 {
      let beforeGlyph = glyphRange(
        forCharacterRange: NSRange(location: r.location - 1, length: 1), actualCharacterRange: nil)
      if beforeGlyph.length > 0 {
        enumerateLineFragments(forGlyphRange: beforeGlyph) { rect, _, _, _, _ in
          if fenceTop == union.minY { fenceTop = origin.y + rect.minY }
        }
      }
    }
    let topBand = fenceTop + metrics.codeChromeTopOffset
    let inset = metrics.codeChromeInset
    // Shared style: the chrome is plain text, one weight for the language
    // name and the Copy affordance alike.
    let attrs = chromeAttributes(font: chromeFont())

    // Language label at the top-LEFT of the block — on the ``` fence line.
    var languageRect: CGRect? = nil
    if let language, !language.isEmpty {
      let size = (language as NSString).size(withAttributes: attrs)
      languageRect = CGRect(
        x: union.minX + inset, y: topBand, width: size.width, height: size.height)
    }

    // Copy at the top-right, the same plain-text style as the language label.
    // The hit-test frame is padded for an easy click target while the drawn
    // glyph stays flush text.
    let copyLabel = (copiedBlockRange == r) ? "Copied" : "Copy"
    let copySize = (copyLabel as NSString).size(withAttributes: attrs)
    let copyRect = CGRect(
      x: union.maxX - inset - copySize.width, y: topBand, width: copySize.width,
      height: copySize.height)
    let hitFrame = copyRect.insetBy(dx: -metrics.copyHitPaddingX, dy: -metrics.copyHitPaddingY)
    return (language, languageRect, copyLabel, copyRect, hitFrame)
  }

  /// Collapses input character ranges into blocks by merging runs that tile
  /// contiguously (NSMaxRange == next.location). Used to turn the many per-token
  /// `.markdownCodeBlock` sub-runs of one fence into a single block, and the per-line
  /// `.markdownTableGrid` sub-runs of one table into a single grid. Runs are assumed
  /// sorted and tiling within each contiguous region.
  public static func mergedRuns(_ runs: [NSRange]) -> [NSRange] {
    var out: [NSRange] = []
    for r in runs {
      if let last = out.last, NSMaxRange(last) == r.location {
        out[out.count - 1] = NSUnionRange(last, r)
      } else {
        out.append(r)
      }
    }
    return out
  }

  /// The full fenced-block range for a content `.markdownCodeBlock` run `r`, read
  /// from the `.markdownCodeBlockFill` attribute attached at the content start
  /// (NSValue-wrapped NSRange covering the content PLUS the ``` fence lines). This
  /// is what the background fill is drawn over. Returns nil when absent (e.g. an
  /// unclosed fence, or content built without the fill attribute), so callers fall
  /// back to the content run.
  private func codeBlockFillRange(for run: NSRange) -> NSRange? {
    guard let storage = textStorage, run.location < storage.length else { return nil }
    let v =
      storage.attribute(
        .markdownCodeBlockFill, at: run.location, effectiveRange: nil) as? NSValue
    return v?.rangeValue
  }

  /// Vertical bars at the container's left edge for a blockquote (Obsidian-style):
  /// one bar per nesting level, each `quoteIndent` further right. The
  /// `.markdownBlockquote` value is the line's depth (`> > x` = 2), so a bar for
  /// level k spans every consecutive line fragment deeper than k — consecutive quote
  /// lines merge into one continuous bar per level.
  private func drawQuoteBar(forCharacterRange r: NSRange, at origin: CGPoint) {
    guard let storage = textStorage else { return }
    let g = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
    guard g.length > 0 else { return }
    var fragments: [(minY: CGFloat, maxY: CGFloat, depth: Int)] = []
    enumerateLineFragments(forGlyphRange: g) { rect, _, _, lineGlyphs, _ in
      let chars = self.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
      let depth =
        chars.location < storage.length
        ? (storage.attribute(.markdownBlockquote, at: chars.location, effectiveRange: nil)
          as? NSNumber)?.intValue ?? 1 : 1
      fragments.append((rect.minY, rect.maxY, max(1, depth)))
    }
    let maxDepth = fragments.map(\.depth).max() ?? 1
    for level in 0..<maxDepth {
      var runStart: CGFloat? = nil
      var runEnd: CGFloat = 0
      func flush() {
        guard let start = runStart else { return }
        drawQuoteBarHook(
          bar: CGRect(
            x: origin.x + CGFloat(level) * metrics.quoteIndent, y: origin.y + start,
            width: metrics.quoteBarWidth, height: runEnd - start))
        runStart = nil
      }
      for f in fragments {
        if f.depth > level {
          if runStart == nil { runStart = f.minY }
          runEnd = f.maxY
        } else {
          flush()
        }
      }
      flush()
    }
  }

  // MARK: - Glyphs (hide command symbols on inactive lines)

  public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
    guard let storage = textStorage else {
      super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
      return
    }
    let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    var drawRanges: [NSRange] = []
    var checkboxRanges: [NSRange] = []
    var ruleRanges: [NSRange] = []
    var tableRuleRanges: [(range: NSRange, width: CGFloat)] = []
    var images: [MarkdownImageSpec] = []
    var i = charRange.location
    let end = NSMaxRange(charRange)
    while i < end {
      var effective = NSRange(location: i, length: 0)
      let attrs = storage.attributes(at: i, effectiveRange: &effective)
      if effective.length == 0 { effective = NSRange(location: i, length: 1) }
      let clamped = NSIntersectionRange(effective, charRange)
      if clamped.length > 0 {
        if attrs[.markdownCheckbox] != nil {
          checkboxRanges.append(clamped)  // never drawn as text
        } else if attrs[.markdownRule] != nil {
          ruleRanges.append(clamped)  // drawn as a line
        } else if let width = attrs[.markdownTableRule] as? NSNumber {
          // A table's hidden `|---|` row: its characters are not drawn; a rule is.
          tableRuleRanges.append((clamped, CGFloat(truncating: width)))
        } else if let spec = attrs[.markdownImageSpec] as? MarkdownImageSpec,
          renderedImageSize(spec) != nil
        {
          // Drawn as an image (once, from its first character's position).
          if images.last !== spec { images.append(spec) }
        } else if attrs[.markdownGlyphSubstitute] != nil {
          drawRanges.append(clamped)  // an entity's stand-in glyph (or the literal `&`)
        } else {
          let isSyntax = attrs[.markdownSyntax] != nil
          let alwaysShow = attrs[.markdownListMarker] != nil
          let visible = !isSyntax || alwaysShow || isSyntaxVisible(clamped, attrs: attrs)
          if visible {
            drawRanges.append(clamped)  // visible glyphs
          }
        }
      }
      i = NSMaxRange(clamped)
      if i <= clamped.location { i += 1 }
    }
    for r in drawRanges {
      let g = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
      if g.length > 0 { super.drawGlyphs(forGlyphRange: g, at: origin) }
    }
    for r in checkboxRanges { drawCheckbox(in: r, at: origin) }
    for r in ruleRanges { drawRule(in: r, at: origin) }
    for r in tableRuleRanges { drawTableRule(in: r.range, tableWidth: r.width, at: origin) }
    for spec in images { drawImage(spec, at: origin) }
  }

  // MARK: - Custom element drawing

  private func drawCheckbox(in charRange: NSRange, at origin: CGPoint) {
    guard let storage = textStorage else { return }
    var whole = NSRange(location: 0, length: 0)
    let checked =
      (storage.attribute(.markdownCheckbox, at: charRange.location, effectiveRange: &whole)
        as? Bool) ?? false
    // An overlay is animating this checkbox; drawing it too would show it twice.
    if checkboxesHiddenForAnimation.contains(whole.location) { return }
    drawCheckboxHook(checked: checked, in: checkboxRect(in: charRange, origin: origin))
  }

  /// Checkboxes (by the location of their `[ ]` range) left undrawn while an overlay
  /// animates them.
  public var checkboxesHiddenForAnimation: Set<Int> = []

  /// Where the checkbox for the `[ ]` range starting at `location` is drawn, in the
  /// coordinates `origin` (the text container's origin) puts it in.
  public func checkboxRect(at location: Int, origin: CGPoint) -> CGRect? {
    guard let storage = textStorage, location < storage.length else { return nil }
    var whole = NSRange(location: 0, length: 0)
    guard storage.attribute(.markdownCheckbox, at: location, effectiveRange: &whole) != nil
    else { return nil }
    ensureLayout(forCharacterRange: whole)
    return checkboxRect(in: whole, origin: origin)
  }

  private func checkboxRect(in charRange: NSRange, origin: CGPoint) -> CGRect {
    let glyphRange = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
    let fragRect = lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
    let loc = location(forGlyphAt: glyphRange.location)
    let m = metrics
    let size = max(m.checkboxMinSize, fragRect.height * 0.62) * m.checkboxScaleFactor  // 20% larger checkbox
    return CGRect(
      x: origin.x + fragRect.minX + loc.x, y: origin.y + fragRect.minY, width: size, height: size)
  }

  private func drawRule(in charRange: NSRange, at origin: CGPoint) {
    let glyphRange = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
    let fragRect = lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
    let y = origin.y + fragRect.minY + fragRect.height / 2 - 0.5
    drawLine(
      from: CGPoint(x: origin.x + fragRect.minX, y: y),
      to: CGPoint(x: origin.x + fragRect.maxX, y: y),
      width: metrics.ruleStrokeWidth, color: ruleColor())
  }

  /// The table's header rule, drawn on the hidden `|---|` separator row at the table's
  /// measured width (that row's characters are invisible in grid mode; the drawn rule is
  /// their visible stand-in).
  private func drawTableRule(in charRange: NSRange, tableWidth: CGFloat, at origin: CGPoint) {
    let glyphRange = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
    guard glyphRange.length > 0 else { return }
    let fragRect = lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
    let y = origin.y + fragRect.minY + fragRect.height / 2 - 0.5
    let padding = textContainers.first?.lineFragmentPadding ?? 0
    drawLine(
      from: CGPoint(x: origin.x + padding, y: y),
      to: CGPoint(x: origin.x + padding + tableWidth, y: y),
      width: metrics.tableRuleStrokeWidth, color: ruleColor())
  }

  /// One stroke, shared by the markdown rule and the table's header rule (AppKit and
  /// UIKit name the path builder's line method differently).
  private func drawLine(from: CGPoint, to: CGPoint, width: CGFloat, color: PlatformColor) {
    let path = PlatformBezierPath()
    path.move(to: from)
    #if canImport(AppKit)
      path.line(to: to)
    #else
      path.addLine(to: to)
    #endif
    path.lineWidth = width
    color.setStroke()
    path.stroke()
  }

  private func drawImage(_ spec: MarkdownImageSpec, at origin: CGPoint) {
    guard let rect = imageRect(spec, at: origin) else { return }
    if drawImageHook(url: spec.url, in: rect) {
      animatedImageRects.append(rect)
      onAnimatedImageDrawn?()
    }
  }

  // MARK: - Images (sized slots in the text flow)

  /// Where a drawn image sits, in drawing coordinates for `origin`; nil while it is not
  /// drawn (not loaded, or its source is being edited).
  public func imageRect(_ spec: MarkdownImageSpec, at origin: CGPoint) -> CGRect? {
    guard let storage = textStorage, spec.range.location < storage.length,
      let size = renderedImageSize(spec)
    else { return nil }
    let glyph = glyphIndexForCharacter(at: spec.range.location)
    guard glyph < numberOfGlyphs else { return nil }
    let frag = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    let loc = location(forGlyphAt: glyph)
    let baseline = frag.minY + loc.y
    let top: CGFloat
    switch spec.verticalAlignment {
    case .baseline: top = baseline - size.height
    case .middle: top = baseline - midline(at: spec.range.location) - size.height / 2
    }
    return CGRect(
      x: origin.x + frag.minX + loc.x, y: origin.y + top, width: size.width, height: size.height)
  }

  /// Images drawn as animations since the editor last took them (drawing coordinates).
  /// The editor redraws these rects on the animation's clock; an animation scrolled out of
  /// view is not drawn, so it stops asking for frames.
  public var animatedImageRects: [CGRect] = []
  /// Called after an animated image is drawn (the editor schedules its next frame).
  public var onAnimatedImageDrawn: (() -> Void)?

  /// The size an image is drawn at, or nil when it is not drawn: not loaded yet, or the
  /// caret is inside its source (editing shows the markdown instead).
  public func renderedImageSize(_ spec: MarkdownImageSpec) -> CGSize? {
    guard let natural = imageNaturalSize(for: spec.url), !imageSourceIsActive(spec.range) else {
      return nil
    }
    return spec.displaySize(natural: natural, maxWidth: availableImageWidth(at: spec.range.location))
  }

  /// Whether the caret is editing an image's source: strictly inside it, or a selection
  /// overlapping it. Unlike other inline spans, a caret merely touching the image's
  /// edge keeps it drawn — a note opening with its caret before a leading image, or
  /// typing right after one, must not flip it to markdown.
  private func imageSourceIsActive(_ span: NSRange) -> Bool {
    guard revealsSyntax else { return false }
    let sel = activeCharacterRange
    if sel.length > 0 { return NSIntersectionRange(span, sel).length > 0 }
    return sel.location > span.location && sel.location < NSMaxRange(span)
  }

  /// The width an image may take at `index`: the container minus its padding and the
  /// paragraph's indent (a list item's image stays inside the item).
  private func availableImageWidth(at index: Int) -> CGFloat {
    guard let container = textContainers.first else { return 0 }
    var width = container.size.width - container.lineFragmentPadding * 2
    if let storage = textStorage, index < storage.length,
      let para = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil)
        as? NSParagraphStyle
    {
      width -= max(para.firstLineHeadIndent, para.headIndent)
    }
    return max(1, width)
  }

  /// Distance from the baseline up to the middle of lowercase text (`valign="middle"`).
  private func midline(at index: Int) -> CGFloat {
    let font =
      (textStorage?.attribute(.font, at: index, effectiveRange: nil) as? PlatformFont)
      ?? PlatformFont.systemFont(ofSize: metrics.bodyFontSize)
    return font.xHeight / 2
  }

  /// Gives every image in `range` the horizontal slot it is drawn in: the first
  /// character of a drawn image gets a kern of the image's width (all its characters are
  /// zero-width glyphs then); an image that is not drawn loses the kern, so its source
  /// or alt text lays out normally. Call after re-styling, after an image loads, when the
  /// caret enters or leaves an image, and when the width changes. Storage attributes only.
  public func updateImageSlots(in range: NSRange) {
    guard let storage = textStorage, storage.length > 0 else { return }
    let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
    guard clamped.length > 0 else { return }
    var edits: [(location: Int, kern: CGFloat?)] = []
    var seen = Set<ObjectIdentifier>()
    storage.enumerateAttribute(.markdownImageSpec, in: clamped, options: []) { value, _, _ in
      guard let spec = value as? MarkdownImageSpec, seen.insert(ObjectIdentifier(spec)).inserted,
        spec.range.location < storage.length
      else { return }
      let first = spec.range.location
      var desired: CGFloat? = nil
      if let size = renderedImageSize(spec) {
        let font =
          (storage.attribute(.font, at: first, effectiveRange: nil) as? PlatformFont)
          ?? PlatformFont.systemFont(ofSize: metrics.bodyFontSize)
        desired = size.width - Self.hiddenGlyphAdvance(for: font)
      }
      let current = (storage.attribute(.kern, at: first, effectiveRange: nil) as? NSNumber).map {
        CGFloat($0.doubleValue)
      }
      if let desired, let current, abs(desired - current) < 0.01 { return }
      if desired == nil, current == nil { return }
      edits.append((first, desired))
    }
    guard !edits.isEmpty else { return }
    storage.beginEditing()
    for edit in edits {
      let r = NSRange(location: edit.location, length: 1)
      if let kern = edit.kern {
        storage.addAttribute(.kern, value: kern, range: r)
      } else {
        storage.removeAttribute(.kern, range: r)
      }
    }
    storage.endEditing()
  }

  /// The image spans in `range` whose image is `url` (to refresh after it loads).
  public func imageSpans(for url: URL, in range: NSRange? = nil) -> [NSRange] {
    guard let storage = textStorage, storage.length > 0 else { return [] }
    let full = NSRange(location: 0, length: storage.length)
    var out: [NSRange] = []
    storage.enumerateAttribute(.markdownImageSpec, in: range.map { NSIntersectionRange($0, full) } ?? full)
    { value, _, _ in
      if let spec = value as? MarkdownImageSpec, spec.url == url, out.last != spec.range {
        out.append(spec.range)
      }
    }
    return out
  }

  /// Grows a line fragment to fit the images drawn in it (baseline images need their
  /// height above the baseline; `valign="middle"` ones half above the text's midline,
  /// half below), and collapses a line holding nothing visible (`.markdownCollapsibleLine`)
  /// while it is not being edited. Called by the editor's layout-manager delegate
  /// (`shouldSetLineFragmentRect`); returns whether anything changed.
  public func adjustLineFragment(
    _ rect: inout CGRect, usedRect: inout CGRect, baselineOffset: inout CGFloat,
    glyphRange: NSRange
  ) -> Bool {
    guard let storage = textStorage, glyphRange.length > 0 else { return false }
    let chars = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    guard chars.location < storage.length else { return false }
    if storage.attribute(.markdownCollapsibleLine, at: chars.location, effectiveRange: nil) != nil,
      !lineContainsCaret(chars.location)
    {
      rect.size.height = metrics.collapsedLineHeight
      usedRect.size.height = metrics.collapsedLineHeight
      baselineOffset = metrics.collapsedLineHeight
      return true
    }
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    storage.enumerateAttribute(.markdownImageSpec, in: chars, options: []) { value, _, _ in
      guard let spec = value as? MarkdownImageSpec, NSLocationInRange(spec.range.location, chars),
        let size = renderedImageSize(spec)
      else { return }
      switch spec.verticalAlignment {
      case .baseline:
        ascent = max(ascent, size.height + metrics.imageTopInset)
      case .middle:
        let mid = midline(at: spec.range.location)
        ascent = max(ascent, size.height / 2 + mid + metrics.imageTopInset)
        descent = max(descent, size.height / 2 - mid)
      }
    }
    guard ascent > 0 else { return false }
    var changed = false
    if ascent > baselineOffset {
      let delta = ascent - baselineOffset
      rect.size.height += delta
      usedRect.size.height += delta
      baselineOffset += delta
      changed = true
    }
    let below = usedRect.maxY - (rect.minY + baselineOffset)
    if descent > below {
      let delta = descent - below
      rect.size.height += delta
      usedRect.size.height += delta
      changed = true
    }
    return changed
  }

  // MARK: - Platform hooks (overridden by MarkdownKit / MdUIKit subclasses)

  /// The code font used by fenced code blocks (14pt monospaced by default).
  /// The background drawing reads the font off the storage; this is the fallback
  /// when the attribute is missing (e.g. edge cases during editing).
  open func codeFontFallback() -> PlatformFont {
    let m = metrics
    return PlatformFont.monospacedSystemFont(ofSize: m.codeFontSize, weight: .regular)
  }

  /// Draw the code block's rounded background union.
  open func drawCodeBlockBackground(union: CGRect, at origin: CGPoint) {}
  /// Fill the inline-code chip.
  open func drawInlineCodeChipHook(chip: CGRect, radius: CGFloat) {}
  /// Inline-code chip fill color (design: `primary.opacity(0.05)`).
  open func inlineCodeFillColor() -> PlatformColor {
    PlatformColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.05)
  }
  /// Inline-code chip stroke border color (design: `primary.opacity(0.05)`).
  open func inlineCodeStrokeColor() -> PlatformColor {
    PlatformColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.05)
  }
  /// Draw a table's vertical grid lines (x values already include the container padding,
  /// and are in the layout manager's drawing coordinates).
  open func drawTableGridHook(verticalLines: [CGFloat], fromY: CGFloat, toY: CGFloat) {}
  /// Draw a table's corner grid/source toggle button.
  open func drawTableToggleHook(frame: CGRect, gridMode: Bool) {}
  /// Table grid + header-rule color.
  open func tableGridColor() -> PlatformColor {
    PlatformColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1)
  }
  /// Draw the quote bar.
  open func drawQuoteBarHook(bar: CGRect) {}
  /// Draw the checkbox image.
  open func drawCheckboxHook(checked: Bool, in rect: CGRect) {}
  /// Draw the loaded image for `url` in `rect`; returns true when it is animated (the
  /// editor then redraws `rect` on the animation's clock).
  @discardableResult
  open func drawImageHook(url: URL, in rect: CGRect) -> Bool { false }
  /// Draw a chrome label (language name / Copy) as text.
  open func drawChromeLabel(
    _ text: String, in rect: CGRect, font: PlatformFont, color: PlatformColor
  ) {}
  /// The natural size (CSS pixels = points) of the loaded image for a URL, if loaded.
  open func imageNaturalSize(for url: URL) -> CGSize? { nil }
  /// The chrome label font (11pt semibold).
  open func chromeFont() -> PlatformFont {
    let m = metrics
    return PlatformFont.systemFont(
      ofSize: m.chromeFontSize, weight: m.chromeFontWeight == .bold ? .bold : .semibold)
  }
  /// Attribute dictionary for chrome labels.
  open func chromeAttributes(font: PlatformFont) -> [NSAttributedString.Key: Any] {
    [.font: font, .foregroundColor: codeTextColor()]
  }
  /// Code text color for the chrome labels.
  open func codeTextColor() -> PlatformColor {
    PlatformColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1)
  }
  /// Code block background fill color.
  open func codeBlockBackgroundColor() -> PlatformColor {
    PlatformColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 0.5)
  }
  /// Quote bar color.
  open func quoteBarColor() -> PlatformColor { PlatformColor.systemRed }
  /// Horizontal rule color.
  open func ruleColor() -> PlatformColor {
    PlatformColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1)
  }
}
#endif
