#if canImport(UIKit)
  import SwiftUI
  import UIKit

  /// SwiftUI host adapter for the UIKit markdown editor. This is a thin
  /// `UIViewControllerRepresentable` wrapper around `MarkdownEditorViewController`
  /// (the actual editor is UIKit, not SwiftUI) — the iOS analogue of the macOS
  /// `MarkdownEditorView` (NSViewRepresentable) in the `MarkdownKit` module.
  public struct MarkdownEditorView: UIViewControllerRepresentable {
    /// Metrics used for this editor instance. Defaults to `MarkdownMetrics.standard`;
    /// pass a customized `MarkdownMetrics` to re-theme spacing/fonts/geometry.
    public var metrics: MarkdownMetrics
    /// Inflates the editor with this text on creation. `nil` (default) keeps the
    /// built-in sample document — a host that owns the content passes it explicitly.
    public var text: String?
    /// Called with the full document text after every user edit.
    public var onChange: @MainActor (String) -> Void
    /// Resolves relative image sources and links (see `MarkdownURLResolver`). Re-applied
    /// when its `documentURL` changes.
    public var resolver: MarkdownURLResolver
    /// Read-only viewer mode (see `EditorTextView.isReadOnly`).
    public var isReadOnly: Bool
    /// An in-page anchor (GitHub heading slug) to scroll to once the text is laid out;
    /// a new value scrolls again.
    public var anchor: String?
    /// Asked first when a link is activated; return true when handled.
    public var onOpenURL: (@MainActor (URL) -> Bool)?
    /// Puts the caret in the editor when it appears (a note just created): typing goes
    /// straight into it.
    public var startsEditing: Bool
    /// Formatting commands from the host (toolbar buttons, a Format menu) go to this editor.
    public var commands: MarkdownEditorCommands?

    public init(
      metrics: MarkdownMetrics = .standard,
      text: String? = nil,
      resolver: MarkdownURLResolver = .absoluteOnly,
      isReadOnly: Bool = false,
      anchor: String? = nil,
      onChange: @escaping @MainActor (String) -> Void = { _ in },
      onOpenURL: (@MainActor (URL) -> Bool)? = nil,
      startsEditing: Bool = false,
      commands: MarkdownEditorCommands? = nil
    ) {
      self.metrics = metrics
      self.text = text
      self.resolver = resolver
      self.isReadOnly = isReadOnly
      self.anchor = anchor
      self.onChange = onChange
      self.onOpenURL = onOpenURL
      self.startsEditing = startsEditing
      self.commands = commands
    }

    /// Applies the non-text configuration (cheap when unchanged).
    @MainActor private func configure(_ textView: EditorTextView, coordinator: Coordinator) {
      textView.onChange = onChange
      textView.onOpenURL = onOpenURL
      commands?.textView = textView
      if textView.isReadOnly != isReadOnly { textView.isReadOnly = isReadOnly }
      if coordinator.resolvedDocument != resolver.documentURL || !coordinator.hasResolver {
        coordinator.hasResolver = true
        coordinator.resolvedDocument = resolver.documentURL
        textView.resolver = resolver
      }
    }

    @MainActor private func scrollToAnchorIfNeeded(_ textView: EditorTextView, coordinator: Coordinator) {
      guard let anchor, anchor != coordinator.appliedAnchor else { return }
      coordinator.appliedAnchor = anchor
      DispatchQueue.main.async { textView.scrollToAnchor(anchor) }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIViewController(context: Context) -> MarkdownEditorViewController {
      let controller = MarkdownEditorViewController(metrics: metrics)
      configure(controller.textView, coordinator: context.coordinator)
      if let text { controller.textView.setText(text) }
      context.coordinator.appliedText = text
      scrollToAnchorIfNeeded(controller.textView, coordinator: context.coordinator)
      if startsEditing {
        DispatchQueue.main.async { controller.textView.becomeFirstResponder() }
      }
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
      configure(textView, coordinator: context.coordinator)
      defer { scrollToAnchorIfNeeded(textView, coordinator: context.coordinator) }
      guard text != context.coordinator.appliedText else { return }
      context.coordinator.appliedText = text
      if let text, text != textView.text { textView.setText(text) }
    }

    @MainActor public final class Coordinator {
      /// The `text` value last pushed into the editor.
      var appliedText: String?
      var appliedAnchor: String?
      var resolvedDocument: URL?
      var hasResolver = false
    }
  }
#endif
