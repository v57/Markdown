#if canImport(UIKit)
import UIKit

/// TextKit 1 layout manager (UIKit stack). All glyph/geometry/merge logic lives
/// in the platform-neutral `EditorLayoutManagerCore`; this subclass supplies the
/// UIKit drawing (UIBezierPath, UIColor, UIImage, NSString) through the core's
/// `open` hooks. Mirrors `Sources/Md/EditorLayoutManager.swift` (AppKit).
public final class EditorLayoutManager: EditorLayoutManagerCore {
    // MARK: - Drawing hooks (UIKit)

    public override func drawCodeBlockBackground(union: CGRect, at origin: CGPoint) {
        let path = UIBezierPath(roundedRect: union, cornerRadius: MarkdownMetrics.standard.codeBlockCornerRadius)
        codeBlockBackgroundColor().setFill()
        path.fill()
    }

    public override func drawInlineCodeChipHook(chip: CGRect, radius: CGFloat) {
        // Fill: primary @ 5% opacity (the SwiftUI `fill(.primary.opacity(0.05))`).
        inlineCodeFillColor().setFill()
        UIBezierPath(roundedRect: chip, cornerRadius: radius).fill()
        // Border: 0.5pt stroke at primary @ 5% — strokeBorder insets by half the
        // line width so the stroke sits inside the chip's edge.
        let stroke = MarkdownMetrics.standard.inlineCodeChipStrokeWidth
        let inset = chip.insetBy(dx: stroke / 2, dy: stroke / 2)
        let path = UIBezierPath(roundedRect: inset, cornerRadius: max(0, radius - stroke / 2))
        path.lineWidth = stroke
        inlineCodeStrokeColor().setStroke()
        path.stroke()
    }

    public override func drawQuoteBarHook(bar: CGRect) {
        let path = UIBezierPath(roundedRect: bar, cornerRadius: MarkdownMetrics.standard.quoteBarCornerRadius)
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
        UIFont.systemFont(ofSize: MarkdownMetrics.standard.chromeFontSize, weight: .semibold)
    }

    public override func chromeAttributes(font: PlatformFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: MarkdownUIKitStyle.standard.color(.secondaryLabel)]
    }

    // MARK: - Colors (UIKit dynamic system colors)

    public override func codeTextColor() -> PlatformColor { MarkdownUIKitStyle.standard.color(.secondaryLabel) }
    public override func codeBlockBackgroundColor() -> PlatformColor { MarkdownUIKitStyle.standard.color(.quaternarySystemFill) }
    public override func inlineCodeFillColor() -> PlatformColor { .label.withAlphaComponent(0.05) }
    public override func inlineCodeStrokeColor() -> PlatformColor { .label.withAlphaComponent(0.05) }
    public override func quoteBarColor() -> PlatformColor { MarkdownUIKitStyle.standard.color(.systemRed) }
    public override func ruleColor() -> PlatformColor { MarkdownUIKitStyle.standard.color(.separator) }
}
#endif
