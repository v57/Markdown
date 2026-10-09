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

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIViewController(context: Context) -> MarkdownEditorViewController {
      let controller = MarkdownEditorViewController(metrics: metrics)
      if let text { controller.textView.setText(text) }
      controller.textView.onChange = onChange
      context.coordinator.appliedText = text
      return controller
    }

    /// Pushes a new `text` from the host into the editor and refreshes `onChange`. The
    /// text is applied only when the HOST changed it (compared with the value last
    /// applied), never just because it differs from the editor's contents — a host that
    /// passes its initial text and only listens to `onChange` would otherwise have every
    /// unrelated SwiftUI update roll the user's edits back.
    public func updateUIViewController(
      _ uiViewController: MarkdownEditorViewController, context: Context
    ) {
      let textView = uiViewController.textView
      textView.onChange = onChange
      guard text != context.coordinator.appliedText else { return }
      context.coordinator.appliedText = text
      if let text, text != textView.text { textView.setText(text) }
    }

    @MainActor public final class Coordinator {
      /// The `text` value last pushed into the editor.
      var appliedText: String?
    }
  }
#endif
