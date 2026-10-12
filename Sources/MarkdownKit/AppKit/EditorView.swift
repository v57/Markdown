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

    public init(
      metrics: MarkdownMetrics = .standard,
      text: String? = nil,
      resolver: MarkdownURLResolver = .absoluteOnly,
      isReadOnly: Bool = false,
      anchor: String? = nil,
      onChange: @escaping @MainActor (String) -> Void = { _ in },
      onOpenURL: (@MainActor (URL) -> Bool)? = nil,
      startsEditing: Bool = false
    ) {
      self.metrics = metrics
      self.text = text
      self.resolver = resolver
      self.isReadOnly = isReadOnly
      self.anchor = anchor
      self.onChange = onChange
      self.onOpenURL = onOpenURL
      self.startsEditing = startsEditing
    }

    /// Applies the non-text configuration (cheap when unchanged).
    @MainActor private func configure(_ textView: EditorTextView, coordinator: Coordinator) {
      textView.onChange = onChange
      textView.onOpenURL = onOpenURL
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
    public func makeNSView(context: Context) -> NSScrollView {
      let textView = EditorTextView(metrics: metrics)
      configure(textView, coordinator: context.coordinator)
      if let text { textView.setText(text) }
      context.coordinator.textView = textView
      context.coordinator.appliedText = text
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true
      scroll.hasHorizontalScroller = false
      scroll.autohidesScrollers = true
      scroll.borderType = .noBorder
      scroll.documentView = textView
      scrollToAnchorIfNeeded(textView, coordinator: context.coordinator)
      if startsEditing {
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
      }
      return scroll
    }
    /// Pushes a new `text` from the host into the editor and refreshes `onChange`. The
    /// text is applied only when the HOST changed it (compared with the value last
    /// applied), never just because it differs from the editor's contents — a host that
    /// passes its initial text and only listens to `onChange` would otherwise have every
    /// unrelated SwiftUI update roll the user's edits back.
    public func updateNSView(_ nsView: NSScrollView, context: Context) {
      guard let textView = context.coordinator.textView else { return }
      configure(textView, coordinator: context.coordinator)
      defer { scrollToAnchorIfNeeded(textView, coordinator: context.coordinator) }
      guard text != context.coordinator.appliedText else { return }
      context.coordinator.appliedText = text
      if let text, text != textView.string { textView.setText(text) }
    }
    @MainActor public final class Coordinator: NSObject {
      weak var textView: EditorTextView?
      /// The `text` value last pushed into the editor.
      var appliedText: String?
      var appliedAnchor: String?
      var resolvedDocument: URL?
      var hasResolver = false
    }
  }

#endif
