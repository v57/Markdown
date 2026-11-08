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
    /// Formatting commands from the host (toolbar buttons, a Format menu) go to this editor.
    public var commands: MarkdownEditorCommands?
    var loadsRemoteImages = false
    var onRemoteImagesBlocked: (@MainActor (Bool) -> Void)?
    var confirmLink: (@MainActor (MarkdownLinkRequest) -> Void)?

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

    /// Whether images from the web load (security audit M1): off unless the host turns it on, for instance from its
    /// "Load images" bar. `onBlocked` hears whether the document holds web images that didn't load.
    public func remoteImages(loads: Bool, onBlocked: (@MainActor (Bool) -> Void)? = nil) -> Self {
      var copy = self
      copy.loadsRemoteImages = loads
      copy.onRemoteImagesBlocked = onBlocked
      return copy
    }

    /// Asks the host before a link that needs the reader's go-ahead opens (`MarkdownLinkPolicy`); the host calls the
    /// request's `open()` on yes. Without it the editor asks with a system alert.
    public func onConfirmLink(_ action: @escaping @MainActor (MarkdownLinkRequest) -> Void) -> Self {
      var copy = self
      copy.confirmLink = action
      return copy
    }

    /// Applies the non-text configuration (cheap when unchanged).
    @MainActor private func configure(_ textView: EditorTextView, coordinator: Coordinator) {
      textView.onChange = onChange
      textView.onOpenURL = onOpenURL
      textView.onConfirmLink = confirmLink
      textView.onRemoteImagesBlocked = onRemoteImagesBlocked
      if textView.loadsRemoteImages != loadsRemoteImages { textView.loadsRemoteImages = loadsRemoteImages }
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
    public func makeNSView(context: Context) -> NSScrollView {
      // Made with its text, resolver and mode: styled once, not as the sample and then again for each of them.
      let textView = EditorTextView(
        metrics: metrics, text: text ?? SampleDocument.text, resolver: resolver, isReadOnly: isReadOnly)
      context.coordinator.hasResolver = true
      context.coordinator.resolvedDocument = resolver.documentURL
      configure(textView, coordinator: context.coordinator)
      textView.setSelectedRange(NSRange(location: 0, length: 0))
      context.coordinator.textView = textView
      context.coordinator.appliedText = text
      let scroll = EditorScrollView()
      scroll.documentCursor = .iBeam
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

  /// The text view is only as tall as its text (the scroller covers exactly the document), so a click below the last
  /// line lands here. It goes to the text view, which takes the focus and puts the caret at the end (or starts a drag
  /// selection from there).
  final class EditorScrollView: NSScrollView {
    override func mouseDown(with event: NSEvent) {
      guard let textView = documentView as? EditorTextView else {
        super.mouseDown(with: event)
        return
      }
      window?.makeFirstResponder(textView)
      textView.mouseDown(with: event)
    }
  }

#endif
