#if canImport(AppKit)
  import AppKit

  /// Draws the task-list checkbox. The layout manager renders this image in place of the
  /// "[x]"/"[ ]" characters (which stay in the source string, marked .markdownCheckbox).
  public enum CheckboxRenderer {
    public static func image(checked: Bool, size: CGFloat) -> NSImage {
      if checked {
        NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "check")!
          .withSymbolConfiguration(
            .init(pointSize: size, weight: .semibold).applying(
              .init(paletteColors: [.white, .systemBlue])))!
      } else {
        NSImage(systemSymbolName: "circle", accessibilityDescription: "uncheck")!
          .withSymbolConfiguration(
            .init(pointSize: size, weight: .regular).applying(.init(paletteColors: [.systemBlue])))!
      }
    }
  }
#endif
