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

    public init(metrics: MarkdownMetrics = .standard) { self.metrics = metrics }

    public func makeUIViewController(context: Context) -> MarkdownEditorViewController {
      MarkdownEditorViewController(metrics: metrics)
    }

    public func updateUIViewController(
      _ uiViewController: MarkdownEditorViewController, context: Context
    ) {}
  }
#endif
