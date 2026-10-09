#if canImport(AppKit)
  import SwiftUI
  import AppKit

  public struct MarkdownEditorView: NSViewRepresentable {
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
    public func makeNSView(context: Context) -> NSScrollView {
      let textView = EditorTextView(metrics: metrics)
      if let text { textView.setText(text) }
      textView.onChange = onChange
      context.coordinator.textView = textView
      context.coordinator.appliedText = text
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true
      scroll.hasHorizontalScroller = false
      scroll.autohidesScrollers = true
      scroll.borderType = .noBorder
      scroll.documentView = textView
      return scroll
    }
    /// Pushes a new `text` from the host into the editor and refreshes `onChange`. The
    /// text is applied only when the HOST changed it (compared with the value last
    /// applied), never just because it differs from the editor's contents — a host that
    /// passes its initial text and only listens to `onChange` would otherwise have every
    /// unrelated SwiftUI update roll the user's edits back.
    public func updateNSView(_ nsView: NSScrollView, context: Context) {
      guard let textView = context.coordinator.textView else { return }
      textView.onChange = onChange
      guard text != context.coordinator.appliedText else { return }
      context.coordinator.appliedText = text
      if let text, text != textView.string { textView.setText(text) }
    }
    @MainActor public final class Coordinator: NSObject {
      weak var textView: EditorTextView?
      /// The `text` value last pushed into the editor.
      var appliedText: String?
    }
  }

#endif
