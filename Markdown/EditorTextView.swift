import AppKit

final class EditorTextView: NSTextView, NSTextStorageDelegate, NSTextViewDelegate {
    private let markdownStorage: NSTextStorage
    private let markdownLayout: EditorLayoutManager
    private let markdownContainer: NSTextContainer

    init() {
        markdownStorage = NSTextStorage()
        markdownLayout = EditorLayoutManager()
        markdownStorage.addLayoutManager(markdownLayout)
        markdownContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        markdownContainer.widthTracksTextView = true
        markdownLayout.addTextContainer(markdownContainer)
        super.init(frame: .zero, textContainer: markdownContainer)
        configure()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        isRichText = false                       // pastes/drops land as plain text
        allowsUndo = true
        isHorizontallyResizable = false
        isVerticallyResizable = true
        textContainerInset = NSSize(width: 48, height: 28)   // Obsidian-like margins
        font = MarkdownStyle.standard.bodyFont
        textColor = .labelColor
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        usesFindBar = true                       // ⌘F find bar for free
        insertionPointColor = .labelColor
        delegate = self
        markdownStorage.delegate = self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            print("EDITOR READY textKit1=\(textLayoutManager == nil)")
            window?.makeFirstResponder(self)
        }
    }
}
