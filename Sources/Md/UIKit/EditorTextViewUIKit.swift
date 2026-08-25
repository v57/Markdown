#if canImport(UIKit)
  import UIKit

  /// TextKit 1 editor text view (UIKit stack). Mirrors the AppKit `EditorTextView`
  /// (NSTextView) behavior for the iOS editor: live markdown re-styling on every
  /// edit, Obsidian-style syntax show/hide via the shared layout-manager core,
  /// checkbox tap-to-toggle, code-block copy buttons, smart list/quote
  /// continuation on Return, and link handling.
  @MainActor
  public final class EditorTextView: UITextView, UITextViewDelegate, NSLayoutManagerDelegate {
    /// Weak handle for the smoke/probe harness to drive the live editor.
    public static weak var live: EditorTextView?
    /// The metrics this editor instance renders with.
    public let metrics: MarkdownMetrics
    private let markdownStorage: NSTextStorage
    private let markdownLayout: EditorLayoutManager
    private let markdownContainer: NSTextContainer
    private var lastSyntaxRangeCount = 0

    public init(metrics: MarkdownMetrics = .standard) {
      self.metrics = metrics
      markdownStorage = NSTextStorage()
      markdownLayout = EditorLayoutManager()
      markdownStorage.addLayoutManager(markdownLayout)
      markdownContainer = NSTextContainer(
        size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
      markdownContainer.widthTracksTextView = true
      markdownLayout.addTextContainer(markdownContainer)
      super.init(frame: .zero, textContainer: markdownContainer)
      configure()
      markdownStorage.setAttributedString(NSAttributedString(string: SampleDocument.text))  // launch sample
      // textViewDidChange only fires for user edits, not for this initial load —
      // style the sample document once here (identical to the per-edit reapply path).
      reapplyMarkdown()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
      isEditable = true
      isScrollEnabled = true
      isSelectable = true
      // Obsidian-like margins. UITextView scrolls natively; no min/max frame
      // games needed (unlike NSTextView in an NSScrollView).
      textContainerInset = UIEdgeInsets(
        top: metrics.textContainerInsetHeight, left: metrics.textContainerInsetWidth,
        bottom: metrics.textContainerInsetHeight, right: metrics.textContainerInsetWidth)
      font = MarkdownUIKitStyle(metrics: metrics).bodyUIFont
      textColor = .label
      // Plain-text editing: disable the smart substitutions that would corrupt
      // the verbatim markdown source (quotes/dashes/replacement).
      autocorrectionType = .no
      smartQuotesType = .no
      smartDashesType = .no
      smartInsertDeleteType = .no
      spellCheckingType = .no
      allowsEditingTextAttributes = false
      alwaysBounceVertical = true
      keyboardDismissMode = .interactive
      delegate = self
      // The layout-manager delegate drives frame/content-size tracking.
      markdownLayout.delegate = self
      // Link interaction (tappable links in the rendered text).
      isSelectable = true
      // Tap-to-toggle checkboxes and copy buttons.
      let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
      addGestureRecognizer(tap)
    }

    // MARK: - Derived styling (re-parse on every character edit)

    /// Re-styling runs in `textViewDidChange`, which fires AFTER the edit settles
    /// in the SAME event: the selection is valid, and the first draw after the
    /// event already shows the styled (and zero-width-collapsed) text.
    ///
    /// It must NOT run inside `textStorage(_:didProcessEditing:)`: an attribute
    /// edit performed inside the storage's edit callback reaches the layout
    /// manager BEFORE the outer character edit's invalidation, and that
    /// interleaved state corrupts line breaking (same TextKit 1 constraint as
    /// the macOS editor).
    private var lastLoggedSyntaxCount = -1

    public func textViewDidChange(_ textView: UITextView) {
      reapplyMarkdown()
      typingAttributes = MarkdownUIKitStyle(metrics: metrics).typingAttributes
    }

    private func reapplyMarkdown() {
      let parsed = MarkdownParser.parse(text, style: MarkdownStyleSpec(metrics: metrics))
      lastSyntaxRangeCount = parsed.syntaxRanges.count
      // Apply attributes only (characters are identical — verbatim invariant), so
      // the storage reports .editedAttributes and textViewDidChange doesn't recurse.
      markdownStorage.beginEditing()
      parsed.attributed.enumerateAttributes(
        in: NSRange(location: 0, length: parsed.attributed.length), options: []
      ) { attrs, range, _ in markdownStorage.setAttributes(attrs, range: range) }
      markdownStorage.endEditing()
      if let lm = layoutManager as? EditorLayoutManager { lm.activeCharacterRange = selectedRange }
      if lastSyntaxRangeCount != lastLoggedSyntaxCount {
        print("STYLE APPLIED syntaxRanges=\(lastSyntaxRangeCount) chars=\(markdownStorage.length)")
        lastLoggedSyntaxCount = lastSyntaxRangeCount
      }
      loadImages(from: parsed.attributed)
    }

    private func loadImages(from attributed: NSAttributedString) {
      attributed.enumerateAttribute(
        .markdownImage, in: NSRange(location: 0, length: attributed.length), options: []
      ) { value, _, _ in
        guard let url = value as? URL else { return }
        InlineImageCache.shared.load(url: url) { [weak self] in
          guard let self else { return }
          // Images are drawn at line height from the cache on every draw — a
          // plain redraw suffices; layout does not change.
          self.setNeedsDisplay()
        }
      }
    }

    // MARK: - Selection / active line (drives syntax show/hide)

    public func textViewDidChangeSelection(_ textView: UITextView) {
      guard let lm = layoutManager as? EditorLayoutManager else { return }
      let newSelection = selectedRange
      guard newSelection != lm.activeCharacterRange else { return }
      // Visibility changes for BOTH the old and new caret positions: an inline
      // command's delimiters show/hide as the caret enters/leaves its span, and
      // line-level commands as the caret moves between lines.
      let affected = NSUnionRange(
        lm.affectedRange(for: lm.activeCharacterRange), lm.affectedRange(for: newSelection))
      lm.activeCharacterRange = newSelection
      // Re-layout the affected ranges so hidden commands collapse to zero width
      // (and appear again when the caret lands on/inside them).
      lm.invalidateGlyphs(forCharacterRange: affected, changeInLength: 0, actualCharacterRange: nil)
      lm.invalidateLayout(forCharacterRange: affected, actualCharacterRange: nil)
      lm.invalidateDisplay(forCharacterRange: affected)
    }

    // MARK: - Scroll content sizing (document view tracks the layout)

    /// Grows/shrinks the text view's content size to fit the laid-out text so the
    /// scroll view's content size always equals the document. Fired by the layout
    /// manager after every completed layout pass.
    public func layoutManager(
      _ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?,
      atEnd layoutFinishedFlag: Bool
    ) {
      guard let container = textContainer else { return }
      let used = layoutManager.usedRect(for: container)
      let targetHeight = used.height + textContainerInset.top + textContainerInset.bottom
      if abs(targetHeight - contentSize.height) > 0.5 {
        contentSize = CGSize(width: contentSize.width, height: targetHeight)
      }
    }

    // MARK: - Links

    public func textView(
      _ textView: UITextView, shouldInteractWith url: URL, in characterRange: NSRange,
      interaction: UITextItemInteraction
    ) -> Bool {
      UIApplication.shared.open(url)
      return false
    }

    // MARK: - Checkbox tap-to-toggle + code copy button

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
      guard recognizer.state == .ended else { return }
      let point = recognizer.location(in: self)
      // Code-block copy button: copy the block's code to the clipboard.
      if let lm = layoutManager as? EditorLayoutManager,
        let chrome = lm.copyButtons.first(where: { $0.copyFrame.contains(point) })
      {
        let code = (text as NSString).substring(with: chrome.blockRange)
        UIPasteboard.general.string = code
        lm.markCopied(chrome.blockRange)
        setNeedsDisplay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          [weak self, block = chrome.blockRange] in
          guard let self, let lm = self.layoutManager as? EditorLayoutManager else { return }
          lm.clearCopied(block)
          self.setNeedsDisplay()
        }
        return
      }
      // Checkbox toggle: hit-test the .markdownCheckbox attribute range.
      let storage = textStorage
      let index = characterIndexForTap(at: point)
      let ns = text as NSString
      guard index < ns.length,
        storage.attribute(.markdownCheckbox, at: index, effectiveRange: nil) != nil
      else { return }
      var eff = NSRange(location: 0, length: 0)
      _ = storage.attribute(.markdownCheckbox, at: index, effectiveRange: &eff)
      guard eff.length >= 3 else { return }
      let inner = NSRange(location: eff.location + 1, length: eff.length - 2)
      let current = ns.substring(with: inner)
      let replacement = (current == "x" || current == "X") ? " " : "x"
      storage.replaceCharacters(in: inner, with: replacement)
      // UITextView doesn't have didChangeText(); textViewDidChange fires from
      // the storage edit automatically, which re-applies styling.
    }

    /// Character index for a tap point, using the layout manager's glyph hit-test
    /// (TextKit 1: `characterIndex(for:in:fractionOfDistanceBetweenInsertionPoints:)`).
    private func characterIndexForTap(at point: CGPoint) -> Int {
      let pointInContainer = CGPoint(
        x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
      var fraction: CGFloat = 0
      return layoutManager.characterIndex(
        for: pointInContainer, in: textContainer,
        fractionOfDistanceBetweenInsertionPoints: &fraction)
    }

    // MARK: - Smart list continuation on Return (Obsidian-style)

    /// Return inside a list item splits the line and continues the list: the new
    /// line is prepended with the item's marker (ordered-list numbers incremented,
    /// task checkboxes keep their state, indentation preserved). Return on a
    /// marker-only item removes the marker instead — the "exit the list" gesture.
    public func textView(
      _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
      guard text == "\n" else { return true }
      let sel = range
      let ns = self.text as NSString
      if sel.length == 0, ns.length > 0, sel.location <= ns.length {
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: lineRange)
        let content = line.hasSuffix("\n") ? String(line.dropLast()) : line
        if let cont = MarkdownParser.listContinuation(for: content) {
          continueBlock(cont, lineRange: lineRange, line: line, caret: sel.location)
          return false
        }
        if let cont = MarkdownParser.quoteContinuation(for: content) {
          continueBlock(cont, lineRange: lineRange, line: line, caret: sel.location)
          return false
        }
      }
      return true
    }

    /// Shared continuation for list items and quotes: a marker-only line drops the
    /// marker (exits the block); otherwise the marker is carried onto the new line.
    private func continueBlock(
      _ cont: MarkdownParser.ListContinuation, lineRange: NSRange, line: String, caret: Int
    ) {
      if cont.empty {
        // Marker-only item: drop the marker, caret stays on the empty line.
        let markerLen = lineRange.length - (line.hasSuffix("\n") ? 1 : 0)
        let markerRange = NSRange(location: lineRange.location, length: markerLen)
        textStorage.replaceCharacters(in: markerRange, with: "")
        selectedRange = NSRange(location: markerRange.location, length: 0)
      } else {
        // Split at the caret and carry the marker onto the new line.
        let insertion = "\n" + cont.marker
        let insertRange = NSRange(location: caret, length: 0)
        textStorage.replaceCharacters(in: insertRange, with: insertion)
        let newCaret = caret + (insertion as NSString).length
        selectedRange = NSRange(location: newCaret, length: 0)
      }
    }

    // MARK: - Lifecycle / appearance

    public override func didMoveToWindow() {
      super.didMoveToWindow()
      if window != nil {
        EditorTextView.live = self
        print(
          "EDITOR READY textKit1=\(textLayoutManager == nil) syntaxRanges=\(lastSyntaxRangeCount) chars=\(markdownStorage.length)"
        )
      }
    }

    /// The code palette is GitHub Light/Dark (static colors) — re-apply when the
    /// trait collection switches so fenced code restyles immediately.
    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
      super.traitCollectionDidChange(previousTraitCollection)
      reapplyMarkdown()
    }
  }
#endif
