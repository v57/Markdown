#if canImport(UIKit)
import Testing
import UIKit

@testable import MdUIKit
@testable import MdCore
@testable import MdCode

// MARK: - iOS (UIKit) editor stack tests
//
// Headless TextKit probes running on the iOS simulator: the UIKit
// EditorLayoutManager (UIBezierPath drawing) + NSTextStorage must behave
// identically to the AppKit stack for the layout-level invariants (zero-width
// hidden commands, line fragments, checkbox slot width, quote bar geometry,
// code-run merging). The parser/renderer assertions verify the UIKit style
// resolves to native UIFont/UIColor.

@Suite struct MdUIKitTests {

    // MARK: - Style rendering (MarkdownUIKitStyle → native UIKit types)

    @Test func uikitStyleResolvesNativeTypes() {
        let style = MarkdownUIKitStyle.standard
        #expect(style.color(.label) == .label)
        #expect(style.color(.systemRed) == .systemRed)
        #expect(style.bodyUIFont.pointSize == 15)
        #expect(style.codeUIFont.fontName.contains("Mono"))
        #expect(style.headingUIFont(level: 1).pointSize == 28)
        #expect(style.headingUIFont(level: 4).pointSize == 17)
        #expect(style.headingUIFont(level: 1).fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(style.headingUIFont(level: 4).fontDescriptor.symbolicTraits.contains(.traitSemibold))
    }

    @Test func uikitParserOutputIsNative() {
        let p = MarkdownParser.parse("# Hi\n\n**bold** and `code`")
        let a = p.attributed
        // Heading font is UIFont at 28pt
        #expect((a.attribute(.font, at: 3, effectiveRange: nil) as? UIFont)?.pointSize == 28)
        // Body foreground is UIColor
        #expect(a.attribute(.foregroundColor, at: 5, effectiveRange: nil) is UIColor)
        // Inline code font is monospaced UIFont
        let codeLoc = (a.string as NSString).range(of: "code").location
        #expect((a.attribute(.font, at: codeLoc, effectiveRange: nil) as? UIFont)?.fontName.contains("Mono") == true)
        // Paragraph style is NSParagraphStyle
        #expect(a.attribute(.paragraphStyle, at: 0, effectiveRange: nil) is NSParagraphStyle)
        // Verbatim invariant
        #expect(a.string == "# Hi\n\n**bold** and `code`")
    }

    @Test func uikitFencedCodeTokenColors() {
        let mdCode = "```swift\nfunc f() { let x = 42 }   // hi https://a.b\n```"
        let p = MarkdownParser.parse(mdCode)
        #expect(p.attributed.string == mdCode)
        let ns = mdCode as NSString
        func colorAt(_ word: String) -> UIColor? {
            let loc = ns.range(of: word).location
            guard loc != NSNotFound else { return nil }
            return p.attributed.attribute(.foregroundColor, at: loc, effectiveRange: nil) as? UIColor
        }
        // Token colors resolve from the hex scheme to UIColor
        #expect(colorAt("func") == UIColor.hex(CodeColorScheme.githubLight.keyword))
        #expect(colorAt("42") == UIColor.hex(CodeColorScheme.githubLight.number))
        #expect(colorAt("hi") == UIColor.hex(CodeColorScheme.githubLight.comment))
    }

    // MARK: - Layout probes (headless TextKit on the simulator)

    @Test func zeroWidthHiddenCommands() {
        let zwDoc = MarkdownParser.parse("# Hi\nplain").attributed.mutableCopy() as! NSMutableAttributedString
        let zwStorage = NSTextStorage(attributedString: zwDoc)
        let zwLM = EditorLayoutManager()
        zwStorage.addLayoutManager(zwLM)
        let zwContainer = NSTextContainer(size: CGSize(width: 600, height: 2000))
        zwLM.addTextContainer(zwContainer)
        // Caret on line 2 ("plain") → line 1's "# " is hidden (zero width)
        zwLM.activeCharacterRange = NSRange(location: 5, length: 5)
        zwLM.ensureLayout(for: zwContainer)
        let wHidden = zwLM.usedRect(for: zwContainer).width
        // Caret on line 1 → nothing hidden
        zwLM.activeCharacterRange = NSRange(location: 0, length: 4)
        zwLM.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: 10), changeInLength: 0, actualCharacterRange: nil)
        zwLM.invalidateLayout(forCharacterRange: NSRange(location: 0, length: 10), actualCharacterRange: nil)
        zwLM.ensureLayout(for: zwContainer)
        let wShown = zwLM.usedRect(for: zwContainer).width
        #expect(wHidden < wShown - 5)
    }

    @Test func newlineFragments() {
        // "Hello\nHello" must break into [0,6) and [6,11) — the newline ends line 1.
        let nlDoc = MarkdownParser.parse("Hello\nHello").attributed
        let nlStorage = NSTextStorage(attributedString: nlDoc)
        let nlLM = EditorLayoutManager()
        nlStorage.addLayoutManager(nlLM)
        let nlContainer = NSTextContainer(size: CGSize(width: 600, height: 2000))
        nlLM.addTextContainer(nlContainer)
        nlLM.ensureLayout(for: nlContainer)
        var frags: [NSRange] = []
        nlLM.enumerateLineFragments(forGlyphRange: nlLM.glyphRange(forCharacterRange: NSRange(location: 0, length: nlStorage.length), actualCharacterRange: nil)) { _, _, _, glyphRange, _ in
            frags.append(glyphRange)
        }
        #expect(frags.count == 2 && frags[0] == NSRange(location: 0, length: 6) && frags[1] == NSRange(location: 6, length: 5))
    }

    @Test func checkboxSlotUniformWidth() {
        let cbDoc = MarkdownParser.parse("- [x] done\n- [ ] done").attributed.mutableCopy() as! NSMutableAttributedString
        let cbStorage = NSTextStorage(attributedString: cbDoc)
        let cbLM = EditorLayoutManager()
        cbStorage.addLayoutManager(cbLM)
        let cbContainer = NSTextContainer(size: CGSize(width: 600, height: 2000))
        cbLM.addTextContainer(cbContainer)
        cbLM.ensureLayout(for: cbContainer)
        let cbNs = cbDoc.string as NSString
        func cbRowWidth(_ startIdx: Int) -> CGFloat {
            let lineRange = cbNs.lineRange(for: NSRange(location: startIdx, length: 0))
            let g = cbLM.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var w: CGFloat = 0
            cbLM.enumerateLineFragments(forGlyphRange: g) { _, used, _, _, _ in w = max(w, used.width) }
            return w
        }
        let cbCheckedW = cbRowWidth(0)
        let cbUncheckedW = cbRowWidth(10)
        #expect(abs(cbCheckedW - cbUncheckedW) < 0.5)
    }

    @Test func mergedCodeRuns() {
        #expect(EditorLayoutManager.mergedCodeRuns([NSRange(location: 0, length: 3),
                                                   NSRange(location: 3, length: 2),
                                                   NSRange(location: 5, length: 1)]) ==
            [NSRange(location: 0, length: 6)])
        #expect(EditorLayoutManager.mergedCodeRuns([NSRange(location: 0, length: 2),
                                                   NSRange(location: 3, length: 2)]) ==
            [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
    }

    @Test func quoteBarGeometry() {
        let qbDoc = MarkdownParser.parse("> a\n> b").attributed.mutableCopy() as! NSMutableAttributedString
        let qbStorage = NSTextStorage(attributedString: qbDoc)
        let qbLM = EditorLayoutManager()
        qbStorage.addLayoutManager(qbLM)
        let qbContainer = NSTextContainer(size: CGSize(width: 400, height: 2000))
        qbLM.addTextContainer(qbContainer)
        qbLM.ensureLayout(for: qbContainer)
        let qbGlyphRange = qbLM.glyphRange(forCharacterRange: NSRange(location: 0, length: qbStorage.length), actualCharacterRange: nil)
        var qbTextX: CGFloat? = nil
        var qbMinY = CGFloat.greatestFiniteMagnitude
        var qbMaxY = -CGFloat.greatestFiniteMagnitude
        qbLM.enumerateLineFragments(forGlyphRange: qbGlyphRange) { rect, used, _, _, _ in
            if qbTextX == nil { qbTextX = used.minX }
            qbMinY = min(qbMinY, rect.minY)
            qbMaxY = max(qbMaxY, rect.maxY)
        }
        #expect(qbTextX == 12)
        #expect(qbMaxY - qbMinY > 30)
    }

    @Test func checkboxRendererProducesImage() {
        let checked = CheckboxRenderer.image(checked: true, size: 13)
        let unchecked = CheckboxRenderer.image(checked: false, size: 13)
        #expect(checked.size == CGSize(width: 13, height: 13))
        #expect(unchecked.size == CGSize(width: 13, height: 13))
    }
}
#endif
