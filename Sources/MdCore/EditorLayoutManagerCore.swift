import Foundation
#if canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformBezierPath = NSBezierPath
#elseif canImport(UIKit)
import UIKit
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
/// platform-specific subclasses in `Md` (AppKit) and `MdUIKit` (UIKit).
open class EditorLayoutManagerCore: NSLayoutManager {
    /// The caret/selection character range. Visibility is derived from it:
    /// line-level commands (heading '#', blockquote '>', fences, table pipes) show
    /// while the caret is on their line; inline delimiters (**bold**, `code`, links)
    /// show while the caret is inside the command's span. Outside those, syntax
    /// glyphs are replaced with a zero-width glyph at layout time (Obsidian-style
    /// live preview: hidden commands collapse to zero width, so text shifts when
    /// the caret lands on/inside a command).
    public var activeCharacterRange: NSRange = NSRange(location: 0, length: 0)

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
    /// Copy buttons for the currently visible code blocks, rebuilt each draw pass.
    public private(set) var copyButtons: [CodeBlockChrome] = []
    /// Flash state: which block most recently showed "Copied".
    public private(set) var copiedBlockRange: NSRange?

    /// Marks this block's button as "Copied" (flash). The editor schedules the
    /// matching `clearCopied` after a delay and redraws.
    public func markCopied(_ blockRange: NSRange) {
        copiedBlockRange = blockRange
    }
    public func clearCopied(_ blockRange: NSRange) {
        if copiedBlockRange == blockRange { copiedBlockRange = nil }
    }

    private func isHiddenCharacter(_ charIndex: Int, in storage: NSTextStorage) -> Bool {
        guard charIndex >= 0, charIndex < storage.length else { return false }
        var eff = NSRange(location: 0, length: 0)
        let attrs = storage.attributes(at: charIndex, effectiveRange: &eff)
        guard attrs[.markdownSyntax] != nil else { return false }
        if attrs[.markdownCheckbox] != nil { return false }   // keep the checkbox slot
        if attrs[.markdownImage] != nil { return false }      // keep the image slot
        if attrs[.markdownListMarker] != nil { return false } // list markers are always shown
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
        guard storage.attribute(.markdownCheckbox, at: charIndex, effectiveRange: &eff) != nil else { return false }
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
        return false // syntax with no line/span context — always hidden
    }

    private func lineContainsCaret(_ charIndex: Int) -> Bool {
        guard let storage = textStorage else { return false }
        let ns = storage.string as NSString
        let caret = min(max(activeCharacterRange.location, 0), ns.length)
        return NSLocationInRange(charIndex, ns.lineRange(for: NSRange(location: caret, length: 0)))
    }

    private func spanIsActive(_ span: NSRange) -> Bool {
        let sel = activeCharacterRange
        if NSIntersectionRange(span, sel).length > 0 { return true }
        guard sel.length == 0 else { return false }
        let loc = sel.location
        if NSLocationInRange(loc, span) { return true }
        return loc == NSMaxRange(span) // caret just after the closing delimiter
    }

    /// Character ranges whose visibility can change when the caret is at `selection`
    /// (the lines it touches plus any command spans adjacent to it).
    public func affectedRange(for selection: NSRange) -> NSRange {
        guard let storage = textStorage else { return NSRange(location: 0, length: 0) }
        let ns = storage.string as NSString
        let loc = min(max(selection.location, 0), ns.length)
        let clamped = NSRange(location: loc, length: min(selection.length, ns.length - loc))
        var union = ns.lineRange(for: clamped)
        for idx in [clamped.location, clamped.location - 1, clamped.location + 1, NSMaxRange(clamped) - 1] {
            if let span = commandSpan(at: idx) { union = NSUnionRange(union, span) }
        }
        return union
    }

    private func commandSpan(at index: Int) -> NSRange? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        guard let v = storage.attribute(.markdownCommandSpan, at: index, effectiveRange: nil) as? NSValue else { return nil }
        return v.rangeValue
    }

    // MARK: - Zero-width glyph substitution for hidden command symbols

    // TextKit 1 layout runs on the main thread; these caches are only touched from
    // setGlyphs/drawGlyphs (main-thread callbacks), so they are safe to treat as
    // nonisolated shared state under Swift 6.
    private static nonisolated(unsafe) var zeroGlyphCache: [String: CGGlyph] = [:]

    /// A real glyph with zero advancement for the given font. NSNullGlyph + .null property
    /// is NOT used: a run of null-property glyphs at the start of a line gets split into
    /// its own line fragment by the layout manager, corrupting line heights (a selected
    /// heading visibly grew and pushed the document down). A real zero-width glyph keeps
    /// the run intact. Fonts without a zero-width glyph (SF Mono) fall back to space.
    private static func zeroGlyph(for font: PlatformFont) -> CGGlyph {
        let key = font.fontName
        if let cached = zeroGlyphCache[key] { return cached }
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
        zeroGlyphCache[key] = glyph
        return glyph
    }

    /// Fixed-width glyph substituted for a checkbox range's middle char: EN SPACE
    /// (U+2002, 0.5 em) when the font has it, else EN QUAD (U+2000), else plain space.
    /// Gives "[x]" and "[ ]" the same slot width and enough room for the drawn
    /// checkbox image (which replaces the literal glyphs, so only width matters).
    private static nonisolated(unsafe) var checkboxSlotGlyphCache: [String: CGGlyph] = [:]

    private static func checkboxSlotGlyph(for font: PlatformFont) -> CGGlyph {
        let key = font.fontName
        if let cached = checkboxSlotGlyphCache[key] { return cached }
        var glyph = CGGlyph(0)
        for char: UniChar in [0x2002, 0x2000] { // EN SPACE, EN QUAD — both 0.5 em
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
        checkboxSlotGlyphCache[key] = glyph
        return glyph
    }
    public override func setGlyphs(_ glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                            characterIndexes charIndexes: UnsafePointer<Int>, font: PlatformFont, forGlyphRange glyphRange: NSRange) {
        guard glyphRange.length > 0, let storage = textStorage else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
            return
        }
        var zeroed = [Bool](repeating: false, count: glyphRange.length)
        var middleSlot = [Bool](repeating: false, count: glyphRange.length)
        var slotGlyph: CGGlyph? = nil
        var anyChange = false
        for i in 0..<glyphRange.length {
            let charIndex = charIndexes[i]
            if isHiddenCharacter(charIndex, in: storage) {
                zeroed[i] = true
                anyChange = true
            } else if isCheckboxMiddle(charIndex, in: storage) {
                middleSlot[i] = true
                if slotGlyph == nil { slotGlyph = Self.checkboxSlotGlyph(for: font) }
                anyChange = true
            }
        }
        guard anyChange else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
            return
        }
        var newGlyphs = [CGGlyph](repeating: 0, count: glyphRange.length)
        var newProps = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
        for i in 0..<glyphRange.length {
            if zeroed[i] {
                newGlyphs[i] = Self.zeroGlyph(for: font)
                newProps[i] = [] // real glyph, normal property — keeps the line fragment intact
            } else if middleSlot[i], let slotGlyph {
                newGlyphs[i] = slotGlyph
                newProps[i] = props[i]
            } else {
                newGlyphs[i] = glyphs[i]
                newProps[i] = props[i]
            }
        }
        newGlyphs.withUnsafeBufferPointer { gp in
            newProps.withUnsafeBufferPointer { pp in
                super.setGlyphs(gp.baseAddress!, properties: pp.baseAddress!, characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
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
                } else {
                    runs.plainRuns.append(clamped)
                }
            }
            i = NSMaxRange(clamped)
            if i <= clamped.location { i += 1 }   // safety against zero-progress
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
        let codeBlocks = EditorLayoutManagerCore.mergedCodeRuns(runs.codeRuns)
        copyButtons.removeAll(keepingCapacity: true)
        for r in codeBlocks {
            guard let union = drawCodeBackground(forCharacterRange: r, at: origin) else { continue }
            // super draws selection highlights and any background attributes over the code
            super.drawBackground(forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil), at: origin)
            drawCodeChrome(forCharacterRange: r, union: union, at: origin)
        }
        for r in runs.quoteRuns {
            // super first so the bar stays visible on top of the selection highlight
            super.drawBackground(forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil), at: origin)
            drawQuoteBar(forCharacterRange: r, at: origin)
        }
        for r in runs.inlineCodeRuns {
            // super first so the selection highlight stays visible on top of the chip
            super.drawBackground(forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil), at: origin)
            drawInlineCodeChip(forCharacterRange: r, at: origin)
        }
        for r in runs.plainRuns {
            super.drawBackground(forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil), at: origin)
        }
    }

    private func drawCodeBackground(forCharacterRange r: NSRange, at origin: CGPoint) -> CGRect? {
        var rects: [CGRect] = []
        enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil)) { rect, _, _, _, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        guard let first = rects.first, let last = rects.last else { return nil }
        // One block per fence: the union spans the FIRST line's top through the
        // LAST line's bottom at full line height (no per-line inset) and full
        // content width. A single rounded rect rounds only the block's own corners.
        let union = CGRect(x: first.minX, y: first.minY, width: first.width, height: last.maxY - first.minY)
        drawCodeBlockBackground(union: union, at: origin)
        return union
    }

    /// Rounded chip behind inline code (`` `code` ``), GitHub-style: the fill spans
    /// the code glyphs plus horizontal padding, vertically inset slightly so the
    /// chip doesn't touch the line's top/bottom edges. The horizontal extent comes
    /// from `boundingRect(forGlyphRange:in:)` — the line fragment's `used` rect
    /// would span the WHOLE mixed line (text `code` more), not just the code glyphs.
    /// The corner radius scales with the line height so tall fonts still look rounded.
    private func drawInlineCodeChip(forCharacterRange r: NSRange, at origin: CGPoint) {
        let g = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        guard g.length > 0, let container = textContainers.first else { return }
        let bounds = boundingRect(forGlyphRange: g, in: container)
        guard !bounds.isNull, bounds.width > 0 else { return }
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        enumerateLineFragments(forGlyphRange: g) { rect, _, _, _, _ in
            minY = min(minY, rect.minY)
            maxY = max(maxY, rect.maxY)
        }
        guard minY <= maxY else { return }
        let hPad: CGFloat = 5
        let vInset: CGFloat = 1.5
        let height = maxY - minY
        let radius = min(4, height / 2 - vInset)
        let chip = CGRect(x: origin.x + bounds.minX - hPad, y: origin.y + minY + vInset,
                          width: bounds.width + hPad * 2, height: height - vInset * 2)
        drawInlineCodeChipHook(chip: chip, radius: radius)
    }

    /// Draws the copy button (top-right) and language label (top-left) on the
    /// opening ``` fence line — one line ABOVE the first code-content line — and
    /// records the copy button's frame + block range for the editor's click-to-copy
    /// hit test. Only drawn when the block's actual top line is on screen (a scrolled
    /// tall fence doesn't float the chrome mid-block).
    private func drawCodeChrome(forCharacterRange r: NSRange, union: CGRect, at origin: CGPoint) {
        guard let storage = textStorage else { return }
        // True top of this block: the char just before it is not code content.
        let isBlockTop = r.location == 0
            || storage.attribute(.markdownCodeBlock, at: r.location - 1, effectiveRange: nil) == nil
        guard isBlockTop else { return }
        let language = storage.attribute(.markdownCodeLanguage, at: r.location, effectiveRange: nil) as? String
        // The ``` opening fence is the line immediately above the block's first
        // content line (code-fence lines aren't part of the .markdownCodeBlock
        // span). Anchor the chrome to THAT line fragment so it floats above the
        // block instead of overlapping the first code line. `union.minY` is a
        // fallback if the fence line has no glyphs (e.g. the block starts at EOF).
        var fenceTop = union.minY
        if r.location > 0 {
            let beforeGlyph = glyphRange(forCharacterRange: NSRange(location: r.location - 1, length: 1),
                                         actualCharacterRange: nil)
            if beforeGlyph.length > 0 {
                enumerateLineFragments(forGlyphRange: beforeGlyph) { rect, _, _, _, _ in
                    if fenceTop == union.minY { fenceTop = origin.y + rect.minY }
                }
            }
        }
        let topBand = fenceTop + 2
        let inset: CGFloat = 10

        // Hide the chrome while the caret is on the ``` fence line (editing the
        // fence marker itself) — language and Copy both disappear.
        if r.location > 0, lineContainsCaret(r.location - 1) { return }

        // Shared style: the chrome is plain text, one weight for the language
        // name and the Copy affordance alike.
        let langFont = chromeFont()
        let langAttrs = chromeAttributes(font: langFont)

        // Language label at the top-LEFT of the block — on the ``` fence line.
        if let language, !language.isEmpty {
            let langSize = (language as NSString).size(withAttributes: langAttrs)
            let langRect = CGRect(x: union.minX + inset, y: topBand,
                                  width: langSize.width, height: langSize.height)
            drawChromeLabel(language, in: langRect, font: langFont, color: codeTextColor())
        }

        // Copy at the top-right, the same plain-text style as the language label.
        // The hit-test frame is padded for an easy click target while the drawn
        // glyph stays flush text.
        let copyLabel = (copiedBlockRange == r) ? "Copied" : "Copy"
        let copyTextSize = (copyLabel as NSString).size(withAttributes: langAttrs)
        let copyRect = CGRect(x: union.maxX - inset - copyTextSize.width, y: topBand,
                              width: copyTextSize.width, height: copyTextSize.height)
        drawChromeLabel(copyLabel, in: copyRect, font: langFont, color: codeTextColor())

        let hitFrame = copyRect.insetBy(dx: -6, dy: -4)
        recordCopyButton(frame: hitFrame, blockRange: r, language: language, copied: copiedBlockRange == r)
    }

    /// Collapses input character ranges into blocks by merging runs that tile
    /// contiguously (NSMaxRange == next.location). Used to turn the many per-token
    /// `.markdownCodeBlock` sub-runs of one fence into a single block. Runs are
    /// assumed sorted and tiling within each contiguous region.
    public static func mergedCodeRuns(_ runs: [NSRange]) -> [NSRange] {
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

    /// Vertical bar at the container's left edge for a blockquote (Obsidian-style).
    /// Spans every line fragment of the quote run, so consecutive quote lines merge
    /// into one continuous bar (adjacent sub-runs are coalesced by drawBackground).
    /// The bar sits at x = origin.x (the container's left edge) while the quote text
    /// keeps its 12pt paragraph indent — the bar moved left, text spacing unchanged;
    /// the '>' marker glyphs sit at the indent + lineFragmentPadding to its right.
    private func drawQuoteBar(forCharacterRange r: NSRange, at origin: CGPoint) {
        let g = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        guard g.length > 0 else { return }
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        enumerateLineFragments(forGlyphRange: g) { rect, _, _, _, _ in
            minY = min(minY, rect.minY)
            maxY = max(maxY, rect.maxY)
        }
        let bar = CGRect(x: origin.x, y: origin.y + minY, width: 3, height: maxY - minY)
        drawQuoteBarHook(bar: bar)
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
        var imageRanges: [NSRange] = []
        var i = charRange.location
        let end = NSMaxRange(charRange)
        while i < end {
            var effective = NSRange(location: i, length: 0)
            let attrs = storage.attributes(at: i, effectiveRange: &effective)
            if effective.length == 0 { effective = NSRange(location: i, length: 1) }
            let clamped = NSIntersectionRange(effective, charRange)
            if clamped.length > 0 {
                if attrs[.markdownCheckbox] != nil {
                    checkboxRanges.append(clamped)                       // never drawn as text
                } else if attrs[.markdownRule] != nil {
                    ruleRanges.append(clamped)                           // drawn as a line
                } else if attrs[.markdownImage] != nil,
                          let url = attrs[.markdownImage] as? URL,
                          image(for: url) != nil {
                    imageRanges.append(clamped)                          // drawn as an image
                } else {
                    let isSyntax = attrs[.markdownSyntax] != nil
                    let alwaysShow = attrs[.markdownListMarker] != nil
                    let visible = !isSyntax || alwaysShow || isSyntaxVisible(clamped, attrs: attrs)
                    if visible {
                        drawRanges.append(clamped)                       // visible glyphs
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
        for r in imageRanges { drawImage(in: r, at: origin) }
    }

    // MARK: - Custom element drawing

    private func drawCheckbox(in charRange: NSRange, at origin: CGPoint) {
        guard let storage = textStorage else { return }
        let checked = (storage.attribute(.markdownCheckbox, at: charRange.location, effectiveRange: nil) as? Bool) ?? false
        let glyphRange = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let fragRect = lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let loc = location(forGlyphAt: glyphRange.location)
        let size = max(11, fragRect.height * 0.62) * 1.2   // 20% larger checkbox
        let rect = CGRect(x: origin.x + fragRect.minX + loc.x,
                          y: origin.y + fragRect.minY + (fragRect.height - size) / 2,
                          width: size, height: size)
        drawCheckboxHook(checked: checked, in: rect)
    }

    private func drawRule(in charRange: NSRange, at origin: CGPoint) {
        let glyphRange = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let fragRect = lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let y = origin.y + fragRect.minY + fragRect.height / 2 - 0.5
        let path = PlatformBezierPath()
        path.move(to: CGPoint(x: origin.x + fragRect.minX, y: y))
        path.line(to: CGPoint(x: origin.x + fragRect.maxX, y: y))
        path.lineWidth = 1
        ruleColor().setStroke()
        path.stroke()
    }

    private func drawImage(in charRange: NSRange, at origin: CGPoint) {
        guard let storage = textStorage,
              let url = storage.attribute(.markdownImage, at: charRange.location, effectiveRange: nil) as? URL,
              let image = image(for: url) else { return }
        let glyphRange = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let fragRect = lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let loc = location(forGlyphAt: glyphRange.location)
        let height = fragRect.height * 1.05
        let aspect = image.size.width / max(1, image.size.height)
        let rect = CGRect(x: origin.x + fragRect.minX + loc.x,
                          y: origin.y + fragRect.minY + (fragRect.height - height) / 2,
                          width: height * aspect, height: height)
        drawImageHook(image, in: rect)
    }

    // MARK: - Platform hooks (overridden by Md / MdUIKit subclasses)

    /// Fill the code block's rounded background union.
    open func drawCodeBlockBackground(union: CGRect, at origin: CGPoint) {}
    /// Fill the inline-code chip.
    open func drawInlineCodeChipHook(chip: CGRect, radius: CGFloat) {}
    /// Draw the quote bar.
    open func drawQuoteBarHook(bar: CGRect) {}
    /// Draw the checkbox image.
    open func drawCheckboxHook(checked: Bool, in rect: CGRect) {}
    /// Draw a loaded inline image.
    open func drawImageHook(_ image: PlatformImage, in rect: CGRect) {}
    /// Draw a chrome label (language name / Copy) as text.
    open func drawChromeLabel(_ text: String, in rect: CGRect, font: PlatformFont, color: PlatformColor) {}
    /// Record a copy-button frame for hit-testing.
    open func recordCopyButton(frame: CGRect, blockRange: NSRange, language: String?, copied: Bool) {
        copyButtons.append(CodeBlockChrome(copyFrame: frame, blockRange: blockRange, language: language, copied: copied))
    }
    /// The cached inline image for a URL, if loaded.
    open func image(for url: URL) -> PlatformImage? { nil }
    /// The chrome label font (11pt semibold).
    open func chromeFont() -> PlatformFont { PlatformFont.systemFont(ofSize: 11, weight: .semibold) }
    /// Attribute dictionary for chrome labels.
    open func chromeAttributes(font: PlatformFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: codeTextColor()]
    }
    /// Code text color for the chrome labels.
    open func codeTextColor() -> PlatformColor { PlatformColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1) }
    /// Code block background fill color.
    open func codeBlockBackgroundColor() -> PlatformColor { PlatformColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 0.5) }
    /// Quote bar color.
    open func quoteBarColor() -> PlatformColor { PlatformColor.systemRed }
    /// Horizontal rule color.
    open func ruleColor() -> PlatformColor { PlatformColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1) }
}
