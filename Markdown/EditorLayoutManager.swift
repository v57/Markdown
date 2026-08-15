import AppKit

final class EditorLayoutManager: NSLayoutManager {
    /// Union of lines containing the current selection/caret. Syntax glyphs outside
    /// this range are replaced with NSNullGlyph + .null property at layout time, which
    /// takes up NO space (Obsidian-style live preview: hidden commands collapse to zero
    /// width, so text shifts when the caret lands on the line).
    var activeCharacterRange: NSRange = NSRange(location: 0, length: 0)

    private func isHiddenCharacter(_ charIndex: Int, in storage: NSTextStorage) -> Bool {
        guard charIndex >= 0, charIndex < storage.length else { return false }
        var eff = NSRange(location: 0, length: 0)
        let attrs = storage.attributes(at: charIndex, effectiveRange: &eff)
        guard attrs[.markdownSyntax] != nil else { return false }
        if attrs[.markdownCheckbox] != nil { return false }   // keep the checkbox slot
        if attrs[.markdownImage] != nil { return false }      // keep the image slot
        if attrs[.markdownListMarker] != nil { return false } // list markers are always shown
        return NSIntersectionRange(NSRange(location: charIndex, length: 1), activeCharacterRange).length == 0
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
    override func setGlyphs(_ glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                            characterIndexes charIndexes: UnsafePointer<Int>, font: NSFont, forGlyphRange glyphRange: NSRange) {
        guard glyphRange.length > 0, let storage = textStorage else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
            return
        }
        var zeroed = [Bool](repeating: false, count: glyphRange.length)
        var anyZeroed = false
        for i in 0..<glyphRange.length {
            if isHiddenCharacter(charIndexes[i], in: storage) {
                zeroed[i] = true
                anyZeroed = true
            }
        }
        guard anyZeroed else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
            return
        }
        var newGlyphs = [CGGlyph](repeating: 0, count: glyphRange.length)
        var newProps = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
        for i in 0..<glyphRange.length {
            if zeroed[i] {
                newGlyphs[i] = Self.zeroGlyph(for: font)
                newProps[i] = [] // real glyph, normal property — keeps the line fragment intact
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
        var plainRuns: [NSRange] = []
        var i = charRange.location
        let end = NSMaxRange(charRange)
        while i < end {
            var effective = NSRange(location: i, length: 0)
            let isCode = storage.attribute(.markdownCodeBlock, at: i, effectiveRange: &effective) != nil
            if effective.length == 0 { effective = NSRange(location: i, length: 1) }
            let clamped = NSIntersectionRange(effective, charRange)
            if clamped.length > 0 {
                if isCode { codeRuns.append(clamped) } else { plainRuns.append(clamped) }
            }
            i = NSMaxRange(clamped)
            if i <= clamped.location { i += 1 }   // safety against zero-progress
        }
        for r in codeRuns {
            drawCodeBackground(forCharacterRange: r, at: origin)
            // super still draws selection highlights and any background attributes over the code
            super.drawBackground(forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil), at: origin)
        }
        for r in plainRuns {
            super.drawBackground(forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil), at: origin)
        }
    }

    private func drawCodeBackground(forCharacterRange r: NSRange, at origin: NSPoint) {
        var rects: [NSRect] = []
        enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil)) { rect, _, _, _, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        guard let first = rects.first, let last = rects.last else { return }
        let union = NSRect(x: first.minX, y: first.minY, width: first.width, height: last.maxY - first.minY)
        let path = NSBezierPath(roundedRect: union.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6)
        MarkdownStyle.standard.codeBackground.setFill()
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
                    let active = NSIntersectionRange(clamped, activeCharacterRange).length > 0
                    if !isSyntax || active || alwaysShow {
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
        let size = max(11, fragRect.height * 0.62)
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
