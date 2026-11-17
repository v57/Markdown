#if canImport(UIKit)
  import UIKit

  /// The main iOS deliverable: a `UIViewController` hosting the UIKit markdown
  /// editor (`EditorTextView`). This is the UIKit alternative to the macOS
  /// `MarkdownEditorView` (NSViewRepresentable) — a plain UIKit view controller,
  /// not a SwiftUI merge. SwiftUI apps can host it via `MarkdownEditorView`
  /// (UIViewControllerRepresentable) or present it directly.
  @MainActor open class MarkdownEditorViewController: UIViewController {
    /// The metrics this editor instance renders with.
    public let metrics: MarkdownMetrics
    /// The markdown editor text view (full-bleed in the controller's view).
    public let textView: EditorTextView

    public init(metrics: MarkdownMetrics = .standard) {
      self.metrics = metrics
      self.textView = EditorTextView(metrics: metrics)
      super.init(nibName: nil, bundle: nil)
    }

    /// Hosts `textView`, made by `MarkdownEditorView` with its text and settings.
    init(metrics: MarkdownMetrics, textView: EditorTextView) {
      self.metrics = metrics
      self.textView = textView
      super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) public required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    open override func viewDidLoad() {
      super.viewDidLoad()
      // Clear: the host's page shows through (the kit's window ground), not the system's black or white.
      view.backgroundColor = .clear
      textView.backgroundColor = .clear
      // The host's bars come in through `setBarInsets` (`MarkdownEditorView.underBars`), not the safe area.
      textView.contentInsetAdjustmentBehavior = .never
      textView.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(textView)
      NSLayoutConstraint.activate([
        textView.topAnchor.constraint(equalTo: view.topAnchor),
        textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
    }

    /// Insets the text by the host's bars, which it runs under: a text view that was at its top stays at its top
    /// under the new inset (the bars' heights arrive after the first layout, and a scroll view doesn't move when its
    /// inset grows), instead of starting under the bar.
    func setBarInsets(top: CGFloat, bottom: CGFloat) {
      let old = textView.contentInset
      guard old.top != top || old.bottom != bottom else { return }
      let wasAtTop = textView.contentOffset.y <= -old.top + 0.5
      textView.contentInset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
      textView.verticalScrollIndicatorInsets = textView.contentInset
      if wasAtTop { textView.contentOffset.y = -top }
    }
  }
#endif
