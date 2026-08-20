import AppKit
import MdCore

/// TextKit 1 layout manager (AppKit stack). All glyph/geometry/merge logic lives
/// in the platform-neutral `EditorLayoutManagerCore`; this subclass supplies the
/// AppKit drawing (NSBezierPath, NSColor, NSImage, NSString) through the core's
/// `open` hooks.
public final class EditorLayoutManager: EditorLayoutManagerCore {
    // MARK: - Drawing hooks (AppKit)

    public override func drawCodeBlockBackground(union: CGRect, at origin: CGPoint) {
        let path = NSBezierPath(roundedRect: union, xRadius: 6, yRadius: 6)
        codeBlockBackgroundColor().setFill()
        path.fill()
    }

    public override func drawInlineCodeChipHook(chip: CGRect, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: chip, xRadius: radius, yRadius: radius)
        codeBlockBackgroundColor().setFill()
        path.fill()
    }

    public override func drawQuoteBarHook(bar: CGRect) {
        let path = NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5)
        quoteBarColor().setFill()
        path.fill()
    }

    public override func drawCheckboxHook(checked: Bool, in rect: CGRect) {
        CheckboxRenderer.image(checked: checked, size: rect.width).draw(in: rect)
    }

    public override func drawImageHook(_ image: PlatformImage, in rect: CGRect) {
        image.draw(in: rect)
    }

    public override func drawChromeLabel(_ text: String, in rect: CGRect, font: PlatformFont, color: PlatformColor) {
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color])
    }

    public override func image(for url: URL) -> PlatformImage? {
        InlineImageCache.shared.image(for: url)
    }

    public override func chromeFont() -> PlatformFont {
        NSFont.systemFont(ofSize: 11, weight: .semibold)
    }

    public override func chromeAttributes(font: PlatformFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: MarkdownStyle.standard.codeTextColor]
    }

    // MARK: - Colors (AppKit dynamic system colors)

    public override func codeTextColor() -> PlatformColor { MarkdownStyle.standard.codeTextColor }
    public override func codeBlockBackgroundColor() -> PlatformColor { MarkdownStyle.standard.codeBackground }
    public override func quoteBarColor() -> PlatformColor { MarkdownStyle.standard.quoteBarColor }
    public override func ruleColor() -> PlatformColor { MarkdownStyle.standard.ruleColor }
}
