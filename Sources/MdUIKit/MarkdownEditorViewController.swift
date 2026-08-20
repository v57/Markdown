#if canImport(UIKit)
import UIKit
import MdCore

/// The main iOS deliverable: a `UIViewController` hosting the UIKit markdown
/// editor (`EditorTextView`). This is the UIKit alternative to the macOS
/// `MarkdownEditorView` (NSViewRepresentable) — a plain UIKit view controller,
/// not a SwiftUI merge. SwiftUI apps can host it via `MarkdownEditorView`
/// (UIViewControllerRepresentable) or present it directly.
@MainActor
open class MarkdownEditorViewController: UIViewController {
    /// The markdown editor text view (full-bleed in the controller's view).
    public let textView = EditorTextView()

    open override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
#endif
