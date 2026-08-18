import AppKit

final class EditorLayoutManager: NSLayoutManager {
    /// The caret/selection character range. Visibility is derived from it:
    /// line-level commands (heading '#', blockquote '>', fences, table pipes) show
    /// while the caret is on their line; inline delimiters (**bold**, `code`, links)
    /// show while the caret is inside the command's span. Outside those, syntax
    /// glyphs are replaced with a zero-width glyph at layout time (Obsidian-style
    /// live preview: hidden commands collapse to zero width, so text shifts when
    /// the caret lands on/inside a command).
    var activeCharacterRange: NSRange = NSRange(location: 0, length: 0)

    /// One code block's reusable "chrome": the copy-button frame plus the block's
    /// document range (to read the code for copying) and language name (for the
    /// label). Frames are in the layout manager's drawing coordinates (== the text
    /// view's coordinate space after `origin`), so the editor hit-tests them with a
    /// converted click point.
    struct CodeBlockChrome {
        let copyFrame: NSRect
        let blockRange: NSRange
        let language: String?
        var copied: Bool
    }
    /// Copy buttons for the currently visible code blocks, rebuilt each draw pass.
    private(set) var copyButtons: [CodeBlockChrome] = []
    /// Flash state: which block most recently showed "Copied".
    private(set) var copiedBlockRange: NSRange?

    /// Marks this block's button as "Copied" (flash). The editor schedules the
    /// matching `clearCopied` after a delay and redraws.
    func markCopied(_ blockRange: NSRange) {
        copiedBlockRange = blockRange
    }
    func clearCopied(_ blockRange: NSRange) {
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
    func affectedRange(for selection: NSRange) -> NSRange {
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

    private static var zeroGlyphCache: [String: CGGlyph] = [:]

    /// A real glyph with zero advancement for the given font. NSNullGlyph + .null property
    /// is NOT used: a run of null-property glyphs at the start of a line gets split into
    /// its own line fragment by the layout manager, corrupting line heights (a selected
    /// heading visibly grew and pushed the document down). A real zero-width glyph keeps
    /// the run intact. Fonts without a zero-width glyph (SF Mono) fall back to space.
    private static func zeroGlyph(for font: NSFont) -> CGGlyph {
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
    private static var checkboxSlotGlyphCache: [String: CGGlyph] = [:]

    private static func checkboxSlotGlyph(for font: NSFont) -> CGGlyph {
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
    override func setGlyphs(_ glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                            characterIndexes charIndexes: UnsafePointer<Int>, font: NSFont, forGlyphRange glyphRange: NSRange) {
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

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var codeRuns: [NSRange] = []
        var quoteRuns: [NSRange] = []
        var plainRuns: [NSRange] = []
        var i = charRange.location
        let end = NSMaxRange(charRange)
        while i < end {
            var effective = NSRange(location: i, length: 0)
            let attrs = storage.attributes(at: i, effectiveRange: &effective)
            if effective.length == 0 { effective = NSRange(location: i, length: 1) }
            let clamped = NSIntersectionRange(effective, charRange)
            if clamped.length > 0 {
                if attrs[.markdownCodeBlock] != nil {
                    codeRuns.append(clamped)
                } else if attrs[.markdownBlockquote] != nil {
                    // Adjacent quote sub-runs (line content vs attributed newline) merge
                    // into one run so the bar is continuous across consecutive quote lines.
                    if let last = quoteRuns.last, NSMaxRange(last) == clamped.location {
                        quoteRuns[quoteRuns.count - 1] = NSUnionRange(last, clamped)
                    } else {
                        quoteRuns.append(clamped)
                    }
                } else {
                    plainRuns.append(clamped)
                }
            }
            i = NSMaxRange(clamped)
            if i <= clamped.location { i += 1 }   // safety against zero-progress
        }
        // Merge adjacent per-token sub-runs into ONE block per fence. Token colors
        // (keyword/string/number) split `.markdownCodeBlock`'s span into many adjacent
        // effective ranges; drawing a rounded rect per run would tile the block with
        // per-token chips. Runs that tile contiguously belong to the same block; a
        // gap (a non-code line between fences) starts a new block.
        let codeBlocks = EditorLayoutManager.mergedCodeRuns(codeRuns)
        copyButtons.removeAll(keepingCapacity: true)
        for r in codeBlocks {
            guard let union = drawCodeBackground(forCharacterRange: r, at: origin) else { continue }
            // super draws selection highlights and any background attributes over the code
            super.drawBackground(forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil), at: origin)
            drawCodeChrome(forCharacterRange: r, union: union, at: origin)
        }
        for r in quoteRuns {
            // super first so the bar stays visible on top of the selection highlight
            super.drawBackground(forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil), at: origin)
            drawQuoteBar(forCharacterRange: r, at: origin)
        }
        for r in plainRuns {
            super.drawBackground(forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil), at: origin)
        }
    }

    private func drawCodeBackground(forCharacterRange r: NSRange, at origin: NSPoint) -> NSRect? {
        var rects: [NSRect] = []
        enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil)) { rect, _, _, _, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        guard let first = rects.first, let last = rects.last else { return nil }
        // One block per fence: the union spans the FIRST line's top through the
        // LAST line's bottom at full line height (no per-line inset) and full
        // content width. A single rounded rect rounds only the block's own corners.
        let union = NSRect(x: first.minX, y: first.minY, width: first.width, height: last.maxY - first.minY)
        let path = NSBezierPath(roundedRect: union, xRadius: 6, yRadius: 6)
        MarkdownStyle.standard.codeBackground.setFill()
        path.fill()
        return union
    }

    /// Draws the copy button (top-right) and language label (top-left) on the
    /// opening ``` fence line — one line ABOVE the first code-content line — and
    /// records the copy button's frame + block range for the editor's click-to-copy
    /// hit test. Only drawn when the block's actual top line is on screen (a scrolled
    /// tall fence doesn't float the chrome mid-block).
    private func drawCodeChrome(forCharacterRange r: NSRange, union: NSRect, at origin: NSPoint) {
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
        let langFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let langAttrs: [NSAttributedString.Key: Any] = [
            .font: langFont, .foregroundColor: MarkdownStyle.standard.codeTextColor,
        ]

        // Language label at the top-LEFT of the block — on the ``` fence line.
        if let language, !language.isEmpty {
            let langSize = (language as NSString).size(withAttributes: langAttrs)
            let langRect = NSRect(x: union.minX + inset, y: topBand,
                                  width: langSize.width, height: langSize.height)
            (language as NSString).draw(in: langRect, withAttributes: langAttrs)
        }

        // Copy at the top-right, the same plain-text style as the language label.
        // The hit-test frame is padded for an easy click target while the drawn
        // glyph stays flush text.
        let copyLabel = (copiedBlockRange == r) ? "Copied" : "Copy"
        let copyTextSize = (copyLabel as NSString).size(withAttributes: langAttrs)
        let copyRect = NSRect(x: union.maxX - inset - copyTextSize.width, y: topBand,
                              width: copyTextSize.width, height: copyTextSize.height)
        (copyLabel as NSString).draw(in: copyRect, withAttributes: langAttrs)

        let hitFrame = copyRect.insetBy(dx: -6, dy: -4)
        copyButtons.append(CodeBlockChrome(copyFrame: hitFrame, blockRange: r,
                                           language: language, copied: copiedBlockRange == r))
    }

    /// Collapses input character ranges into blocks by merging runs that tile
    /// contiguously (NSMaxRange == next.location). Used to turn the many per-token
    /// `.markdownCodeBlock` sub-runs of one fence into a single block. Runs are
    /// assumed sorted and tiling within each contiguous region.
    static func mergedCodeRuns(_ runs: [NSRange]) -> [NSRange] {
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

    /// Vertical bar at the left edge of a blockquote (Obsidian-style). Spans every
    /// line fragment of the quote run, so consecutive quote lines merge into one
    /// continuous bar (adjacent sub-runs are coalesced by drawBackground). The bar x
    /// is the quote content's left edge — the used-rect minX (the 24pt paragraph
    /// indent); the '>' marker glyphs sit 5pt (lineFragmentPadding) to its right.
    private func drawQuoteBar(forCharacterRange r: NSRange, at origin: NSPoint) {
        let g = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        guard g.length > 0 else { return }
        var barX: CGFloat? = nil
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        enumerateLineFragments(forGlyphRange: g) { rect, used, _, _, _ in
            if barX == nil { barX = origin.x + used.minX }
            minY = min(minY, rect.minY)
            maxY = max(maxY, rect.maxY)
        }
        guard let barX else { return }
        let bar = NSRect(x: barX, y: origin.y + minY, width: 3, height: maxY - minY)
        let path = NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5)
        MarkdownStyle.standard.quoteBarColor.setFill()
        path.fill()
    }

    // MARK: - Glyphs (hide command symbols on inactive lines)

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
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
                          InlineImageCache.shared.image(for: url) != nil {
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

    private func drawCheckbox(in charRange: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else { return }
        let checked = (storage.attribute(.markdownCheckbox, at: charRange.location, effectiveRange: nil) as? Bool) ?? false
        let glyphRange = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let fragRect = lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let loc = location(forGlyphAt: glyphRange.location)
        let size = max(11, fragRect.height * 0.62) * 1.2   // 20% larger checkbox
        let rect = NSRect(x: origin.x + fragRect.minX + loc.x,
                          y: origin.y + fragRect.minY + (fragRect.height - size) / 2,
                          width: size, height: size)
        CheckboxRenderer.image(checked: checked, size: size).draw(in: rect)
    }

    private func drawRule(in charRange: NSRange, at origin: NSPoint) {
        let glyphRange = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let fragRect = lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let y = origin.y + fragRect.minY + fragRect.height / 2 - 0.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: origin.x + fragRect.minX, y: y))
        path.line(to: NSPoint(x: origin.x + fragRect.maxX, y: y))
        path.lineWidth = 1
        MarkdownStyle.standard.ruleColor.setStroke()
        path.stroke()
    }

    private func drawImage(in charRange: NSRange, at origin: NSPoint) {
        guard let storage = textStorage,
              let url = storage.attribute(.markdownImage, at: charRange.location, effectiveRange: nil) as? URL,
              let image = InlineImageCache.shared.image(for: url) else { return }
        let glyphRange = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let fragRect = lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let loc = location(forGlyphAt: glyphRange.location)
        let height = fragRect.height * 1.05
        let aspect = image.size.width / max(1, image.size.height)
        let rect = NSRect(x: origin.x + fragRect.minX + loc.x,
                          y: origin.y + fragRect.minY + (fragRect.height - height) / 2,
                          width: height * aspect, height: height)
        image.draw(in: rect)
    }
}
