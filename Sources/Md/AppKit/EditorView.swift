#if canImport(AppKit)
  import SwiftUI
  import AppKit

  public struct MarkdownEditorView: NSViewRepresentable {
    /// Metrics used for this editor instance. Defaults to `MarkdownMetrics.standard`;
    /// pass a customized `MarkdownMetrics` to re-theme spacing/fonts/geometry.
    public var metrics: MarkdownMetrics

    public init(metrics: MarkdownMetrics = .standard) { self.metrics = metrics }

    public func makeCoordinator() -> Coordinator { Coordinator() }
    public func makeNSView(context: Context) -> NSScrollView {
      let textView = EditorTextView(metrics: metrics)
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true
      scroll.hasHorizontalScroller = false
      scroll.autohidesScrollers = true
      scroll.borderType = .noBorder
      scroll.documentView = textView
      return scroll
    }
    public func updateNSView(_ nsView: NSScrollView, context: Context) {}
    @MainActor public final class Coordinator: NSObject {}
  }

#endif
