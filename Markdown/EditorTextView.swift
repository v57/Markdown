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
        markdownStorage.setAttributedString(NSAttributedString(string: SampleDocument.text)) // launch sample
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

    // MARK: - Derived styling (re-parse on every character edit)

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        // Attribute-only edits (our own styling pass) must not re-trigger styling — no recursion.
        guard editedMask.contains(.editedCharacters) else { return }
        reapplyMarkdown()
    }

    private func reapplyMarkdown() {
        let parsed = MarkdownParser.parse(string, style: .standard)
        // Apply attributes only (characters are identical — verbatim invariant), so the
        // storage reports .editedAttributes and the guard above stops the loop.
        markdownStorage.beginEditing()
        parsed.attributed.enumerateAttributes(in: NSRange(location: 0, length: parsed.attributed.length), options: []) { attrs, range, _ in
            markdownStorage.setAttributes(attrs, range: range)
        }
        markdownStorage.endEditing()
        typingAttributes = MarkdownStyle.standard.typingAttributes
        if let lm = layoutManager as? EditorLayoutManager {
            lm.activeCharacterRange = currentActiveLineRange()
            lm.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: markdownStorage.length))
        }
        loadImages(from: parsed.attributed)
    }

    private func loadImages(from attributed: NSAttributedString) {
        attributed.enumerateAttribute(.markdownImage, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, _ in
            guard let url = value as? URL else { return }
            InlineImageCache.shared.load(url: url) { [weak self] in
                guard let self else { return }
                self.layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: self.markdownStorage.length))
                self.needsDisplay = true
            }
        }
    }

    // MARK: - Selection / active line (drives syntax show/hide)

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let lm = layoutManager as? EditorLayoutManager else { return }
        let newRange = currentActiveLineRange()
        let union = NSUnionRange(lm.activeCharacterRange, newRange)
        lm.activeCharacterRange = newRange
        lm.invalidateDisplay(forCharacterRange: union)
    }

    func textDidChange(_ notification: Notification) {
        typingAttributes = MarkdownStyle.standard.typingAttributes
    }

    private func currentActiveLineRange() -> NSRange {
        let sel = selectedRange()
        let ns = string as NSString
        let loc = max(0, min(sel.location, ns.length))
        return ns.lineRange(for: NSRange(location: loc, length: 0))
    }

    // MARK: - Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { NSWorkspace.shared.open(url) }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            print("EDITOR READY textKit1=\(textLayoutManager == nil)")
            window?.makeFirstResponder(self)
        }
    }
}
