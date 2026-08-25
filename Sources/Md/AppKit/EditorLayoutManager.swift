#if canImport(AppKit)
  import AppKit

  /// TextKit 1 layout manager (AppKit stack). All glyph/geometry/merge logic lives
  /// in the platform-neutral `EditorLayoutManagerCore`; this subclass supplies the
  /// AppKit drawing (NSBezierPath, NSColor, NSImage, NSString) through the core's
  /// `open` hooks.
  public final class EditorLayoutManager: EditorLayoutManagerCore {
    // MARK: - Drawing hooks (AppKit)

    public override func drawCodeBlockBackground(union: CGRect, at origin: CGPoint) {
      let r = MarkdownMetrics.standard.codeBlockCornerRadius
      let path = NSBezierPath(roundedRect: union, xRadius: r, yRadius: r)
      codeBlockBackgroundColor().setFill()
      path.fill()
    }

    public override func drawInlineCodeChipHook(chip: CGRect, radius: CGFloat) {
      // Fill: primary @ 5% opacity (the SwiftUI `fill(.primary.opacity(0.05))`).
      inlineCodeFillColor().setFill()
      NSBezierPath(roundedRect: chip, xRadius: radius, yRadius: radius).fill()
      // Border: 0.5pt stroke at primary @ 5% — strokeBorder insets by half the
      // line width so the stroke sits inside the chip's edge.
      let stroke = MarkdownMetrics.standard.inlineCodeChipStrokeWidth
      let inset = chip.insetBy(dx: stroke / 2, dy: stroke / 2)
      let path = NSBezierPath(
        roundedRect: inset, xRadius: max(0, radius - stroke / 2),
        yRadius: max(0, radius - stroke / 2))
      path.lineWidth = stroke
      inlineCodeStrokeColor().setStroke()
      path.stroke()
    }

    public override func drawQuoteBarHook(bar: CGRect) {
      let r = MarkdownMetrics.standard.quoteBarCornerRadius
      let path = NSBezierPath(roundedRect: bar, xRadius: r, yRadius: r)
      quoteBarColor().setFill()
      path.fill()
    }

    public override func drawCheckboxHook(checked: Bool, in rect: CGRect) {
      CheckboxRenderer.image(checked: checked, size: rect.width).draw(in: rect)
    }

    public override func drawImageHook(_ image: PlatformImage, in rect: CGRect) {
      image.draw(in: rect)
    }

    public override func drawChromeLabel(
      _ text: String, in rect: CGRect, font: PlatformFont, color: PlatformColor
    ) { (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color]) }

    public override func image(for url: URL) -> PlatformImage? {
      InlineImageCache.shared.image(for: url)
    }

    public override func chromeFont() -> PlatformFont {
      NSFont.systemFont(ofSize: MarkdownMetrics.standard.chromeFontSize, weight: .semibold)
    }

    public override func chromeAttributes(font: PlatformFont) -> [NSAttributedString.Key: Any] {
      [.font: font, .foregroundColor: MarkdownStyle.standard.codeTextColor]
    }

    // MARK: - Colors (AppKit dynamic system colors)

    public override func codeTextColor() -> PlatformColor { MarkdownStyle.standard.codeTextColor }
    public override func codeBlockBackgroundColor() -> PlatformColor {
      MarkdownStyle.standard.codeBackground
    }
    public override func inlineCodeFillColor() -> PlatformColor {
      .labelColor.withAlphaComponent(0.05)
    }
    public override func inlineCodeStrokeColor() -> PlatformColor {
      .labelColor.withAlphaComponent(0.05)
    }
    public override func quoteBarColor() -> PlatformColor { MarkdownStyle.standard.quoteBarColor }
    public override func ruleColor() -> PlatformColor { MarkdownStyle.standard.ruleColor }
  }
#endif
