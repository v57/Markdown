#if canImport(UIKit)
  import SwiftUI
  import UIKit

  /// SwiftUI host adapter for the UIKit markdown editor. This is a thin
  /// `UIViewControllerRepresentable` wrapper around `MarkdownEditorViewController`
  /// (the actual editor is UIKit, not SwiftUI) — the iOS analogue of the macOS
  /// `MarkdownEditorView` (NSViewRepresentable) in the `Md` module.
  public struct MarkdownEditorView: UIViewControllerRepresentable {
    /// Metrics used for this editor instance. Defaults to `MarkdownMetrics.standard`;
    /// pass a customized `MarkdownMetrics` to re-theme spacing/fonts/geometry.
    public var metrics: MarkdownMetrics
    /// Inflates the editor with this text on creation. `nil` (default) keeps the
    /// built-in sample document — a host that owns the content passes it explicitly.
    public var text: String?
    /// Called with the full document text after every user edit.
    public var onChange: @MainActor (String) -> Void

    public init(
      metrics: MarkdownMetrics = .standard,
      text: String? = nil,
      onChange: @escaping @MainActor (String) -> Void = { _ in }
    ) {
      self.metrics = metrics
      self.text = text
      self.onChange = onChange
    }

    public func makeUIViewController(context: Context) -> MarkdownEditorViewController {
      let controller = MarkdownEditorViewController(metrics: metrics)
      if let text { controller.textView.setText(text) }
      controller.textView.onChange = onChange
      return controller
    }

    public func updateUIViewController(
      _ uiViewController: MarkdownEditorViewController, context: Context
    ) {}
  }
#endif
