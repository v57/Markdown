#if canImport(UIKit)
import SwiftUI
import UIKit

/// SwiftUI host adapter for the UIKit markdown editor. This is a thin
/// `UIViewControllerRepresentable` wrapper around `MarkdownEditorViewController`
/// (the actual editor is UIKit, not SwiftUI) — the iOS analogue of the macOS
/// `MarkdownEditorView` (NSViewRepresentable) in the `Md` module.
public struct MarkdownEditorView: UIViewControllerRepresentable {
    public init() {}

    public func makeUIViewController(context: Context) -> MarkdownEditorViewController {
        MarkdownEditorViewController()
    }

    public func updateUIViewController(_ uiViewController: MarkdownEditorViewController, context: Context) {}
}
#endif
