#if canImport(UIKit)
  import UIKit

  /// TextKit 1 editor text view (UIKit stack). Mirrors the AppKit `EditorTextView`
  /// (NSTextView) behavior for the iOS editor: live markdown re-styling on every
  /// edit, Obsidian-style syntax show/hide via the shared layout-manager core,
  /// checkbox tap-to-toggle, code-block copy buttons, smart list/quote
  /// continuation on Return, and link handling.
  @MainActor
  public final class EditorTextView: UITextView, UITextViewDelegate, NSLayoutManagerDelegate, UIGestureRecognizerDelegate {
    /// Weak handle for the smoke/probe harness to drive the live editor.
    public static weak var live: EditorTextView?
    /// The metrics this editor instance renders with.
    public let metrics: MarkdownMetrics
    /// Called with the full text after every user edit (NOT for programmatic
    /// `setText`). Lets a host (e.g. a note editor) observe the document text.
    /// `@MainActor` because edits fire on the main thread and hosts will call
    /// back into MainActor code (e.g. a note store).
    public var onChange: (@MainActor (String) -> Void)?
    private let markdownStorage: NSTextStorage
    private let markdownLayout: EditorLayoutManager
    private let markdownContainer: NSTextContainer
    /// Tables pinned to SOURCE mode (0-based document order). Everything else renders as a
    /// grid. VIEW state, not document state: it never reaches `onChange`, and flipping it
    /// re-parses (the alignment kerns depend on whether the pipes are visible).
    private var sourceModeTables: Set<Int> = []
    /// Natural grid widths of the tables from the last parse, and which of them did not
    /// fit — a resize re-parses only when that set changes.
    private var tableWidths: [Int: CGFloat] = [:]
    private var overflowingTables: Set<Int> = []
    /// Resolves the document's relative image sources and links (a note's folder, a
    /// GitHub repository). Setting it re-styles the document.
    public var resolver: MarkdownURLResolver = .absoluteOnly {
      didSet { reapplyMarkdown() }
    }
    /// A read-only viewer: not editable, and syntax is never revealed (no caret-driven
    /// show/hide, no table source mode, no checkbox toggling) — the document always
    /// renders as its preview. Text stays selectable and links tappable.
    public var isReadOnly = false {
      didSet {
        guard isReadOnly != oldValue else { return }
        isEditable = !isReadOnly
        markdownLayout.revealsSyntax = !isReadOnly
        sourceModeTables.removeAll()
        reapplyMarkdown()
        let full = NSRange(location: 0, length: markdownStorage.length)
        markdownLayout.invalidateGlyphs(
          forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        markdownLayout.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        setNeedsDisplay()
      }
    }
    /// Asked first when a link is tapped; return true when the host handled it (e.g.
    /// opened another note). Same-document `#anchor` links scroll without asking;
    /// anything unhandled opens externally.
    public var onOpenURL: (@MainActor (URL) -> Bool)?

    public init(metrics: MarkdownMetrics = .standard) {
      self.metrics = metrics
      markdownStorage = NSTextStorage()
      markdownLayout = EditorLayoutManager()
      markdownLayout.metrics = metrics
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
      markdownLayout.onAnimatedImageDrawn = { [weak self] in self?.scheduleAnimationFrame() }
      // Link interaction (tappable links in the rendered text).
      isSelectable = true
      // Links should NOT be underlined. UITextView applies its own DEFAULT link
      // styling (underline + color) to `.link`-carrying ranges via
      // `linkTextAttributes`. Override it to keep the link color (from our own
      // styling) but drop the underline.
      linkTextAttributes = [
        .foregroundColor: MarkdownUIKitStyle(metrics: metrics).color(.link),
      ]
      // Tap-to-toggle checkboxes and copy buttons. This custom tap recognizer
      // MUST allow SIMULTANEOUS recognition with the text view's own private
      // tap gesture that makes it first responder: by default a developer
      // UITapGestureRecognizer forces the built-in tap-to-edit recognizer to
      // fail, so tapping a note never summons the keyboard (documented UIKit
      // behaviour). Allow simultaneous + keep touches in view so a tap on
      // non-interactive content still falls through to editing.
      let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
      tap.delegate = self
      tap.cancelsTouchesInView = false
      addGestureRecognizer(tap)
    }

    /// Replaces the document with `newText` and re-applies styling. Programmatic,
    /// so it does NOT fire `textViewDidChange` — `onChange` is not called (a host
    /// that wants to observe edits still gets them via the normal edit path). Used
    /// by hosts that inflate the editor with existing content (e.g. a note editor).
    public func setText(_ newText: String) {
      text = newText
      sourceModeTables.removeAll()
      reapplyMarkdown()
      selectedRange = NSRange(location: 0, length: 0)
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
    public func textViewDidChange(_ textView: UITextView) {
      reapplyMarkdown()
      typingAttributes = MarkdownUIKitStyle(metrics: metrics).typingAttributes
      onChange?(text)
    }

    private func reapplyMarkdown() {
      // Parse under THIS view's traits: the code palette is resolved from
      // `UITraitCollection.current`, which outside a draw pass need not be this view's
      // (e.g. a host forcing light mode inside a dark app).
      var parsed: ParsedMarkdown!
      traitCollection.performAsCurrent {
        parsed = MarkdownParser.parse(
          text, style: MarkdownStyleSpec(metrics: metrics), sourceModeTables: sourceModeTables,
          maxTableWidth: availableTableWidth, resolver: resolver)
      }
      tableWidths = parsed.tableWidths
      overflowingTables = MarkdownParser.overflowingTables(
        tableWidths, availableWidth: availableTableWidth)
      // Apply attributes only (characters are identical — verbatim invariant), so
      // the storage reports .editedAttributes and textViewDidChange doesn't recurse.
      markdownStorage.beginEditing()
      parsed.attributed.enumerateAttributes(
        in: NSRange(location: 0, length: parsed.attributed.length), options: []
      ) { attrs, range, _ in markdownStorage.setAttributes(attrs, range: range) }
      markdownStorage.endEditing()
      markdownLayout.activeCharacterRange = selectedRange
      markdownLayout.updateImageSlots(in: NSRange(location: 0, length: markdownStorage.length))
      loadVisibleImages()
    }

    /// Width a table grid may occupy: the container minus its line-fragment padding. nil
    /// until the view has been sized (a zero-width container would fit no table).
    private var availableTableWidth: CGFloat? {
      let width = textContainer.size.width - textContainer.lineFragmentPadding * 2
      return width > 0 ? width : nil
    }

    /// After a width change (rotation, split view): re-parse when the set of tables too
    /// wide for a grid changed, so a table falls back to raw markdown instead of wrapping.
    private func reflowTablesIfNeeded() {
      guard !tableWidths.isEmpty, !isReflowingTables else { return }
      let now = MarkdownParser.overflowingTables(tableWidths, availableWidth: availableTableWidth)
      guard now != overflowingTables else { return }
      isReflowingTables = true
      defer { isReflowingTables = false }
      reapplyMarkdown()
    }
    private var isReflowingTables = false
    private var lastLayoutWidth: CGFloat = 0

    public override func layoutSubviews() {
      super.layoutSubviews()
      if abs(bounds.width - lastLayoutWidth) > 0.5 {
        lastLayoutWidth = bounds.width
        reflowTablesIfNeeded()
        // Every image's maximum width changed. Deferred out of the layout pass.
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.markdownLayout.updateImageSlots(
            in: NSRange(location: 0, length: self.markdownStorage.length))
          self.loadVisibleImages()
        }
      }
    }

    // MARK: - Images (lazy loading, slots, animation)

    /// Loads the images in and around the visible part of the document (a screen above,
    /// two below) — a long README requests only what the reader is near. Called after
    /// re-styling and on every scroll.
    private func loadVisibleImages() {
      guard markdownStorage.length > 0 else { return }
      let visible = CGRect(
        origin: contentOffset, size: bounds.size.height > 0 ? bounds.size : CGSize(width: 400, height: 900))
      let area = CGRect(
        x: visible.minX - textContainerInset.left,
        y: visible.minY - visible.height - textContainerInset.top, width: visible.width,
        height: visible.height * 4)
      let glyphs = markdownLayout.glyphRange(forBoundingRect: area, in: markdownContainer)
      let chars = markdownLayout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      guard chars.length > 0 else { return }
      let cache = MarkdownImageCache.shared
      markdownStorage.enumerateAttribute(.markdownImage, in: chars, options: []) { value, _, _ in
        guard let url = value as? URL, !cache.hasRequested(url) else { return }
        cache.load(url) { [weak self] url in self?.imageDidLoad(url) }
      }
      markdownLayout.updateImageSlots(in: chars)
    }

    private var loadedImageURLs: Set<URL> = []
    /// Coalesces image arrivals into one relayout per run-loop turn.
    private func imageDidLoad(_ url: URL) {
      loadedImageURLs.insert(url)
      guard loadedImageURLs.count == 1 else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        let urls = self.loadedImageURLs
        self.loadedImageURLs.removeAll()
        for url in urls {
          for span in self.markdownLayout.imageSpans(for: url) {
            self.markdownLayout.updateImageSlots(in: span)
            self.markdownLayout.invalidateGlyphs(
              forCharacterRange: span, changeInLength: 0, actualCharacterRange: nil)
            self.markdownLayout.invalidateLayout(forCharacterRange: span, actualCharacterRange: nil)
            self.markdownLayout.invalidateDisplay(forCharacterRange: span)
          }
        }
      }
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) { loadVisibleImages() }

    private var animationTimerScheduled = false
    /// Called by the layout manager whenever it draws an animated image: redraw the
    /// animated images on the animation clock. One scrolled out of view is not drawn, so
    /// it stops asking.
    private func scheduleAnimationFrame() {
      guard !animationTimerScheduled else { return }
      animationTimerScheduled = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
        guard let self else { return }
        self.animationTimerScheduled = false
        let drawn = self.markdownLayout.animatedImageRects
        self.markdownLayout.animatedImageRects.removeAll()
        let visible = CGRect(origin: self.contentOffset, size: self.bounds.size)
        let origin = CGPoint(x: self.textContainerInset.left, y: self.textContainerInset.top)
        for r in drawn where r.intersects(visible) {
          let glyphs = self.markdownLayout.glyphRange(
            forBoundingRect: r.offsetBy(dx: -origin.x, dy: -origin.y), in: self.markdownContainer)
          self.markdownLayout.invalidateDisplay(forGlyphRange: glyphs)
        }
      }
    }

    // MARK: - Anchors

    /// Scrolls so the heading (or HTML `id`/`name` anchor) with GitHub slug `anchor` is at
    /// the top. Returns false when the document has no such anchor.
    @discardableResult
    public func scrollToAnchor(_ anchor: String) -> Bool {
      let key = (anchor.removingPercentEncoding ?? anchor).lowercased()
      guard let location = MarkdownParser.anchors(in: text)[key], markdownStorage.length > 0
      else { return false }
      let char = min(location, markdownStorage.length - 1)
      let glyph = markdownLayout.glyphIndexForCharacter(at: char)
      markdownLayout.ensureLayout(forGlyphRange: NSRange(location: 0, length: glyph + 1))
      let rect = markdownLayout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let maxY = max(0, contentSize.height - bounds.height + adjustedContentInset.bottom)
      let y = min(maxY, max(-adjustedContentInset.top, rect.minY + textContainerInset.top - 8))
      setContentOffset(CGPoint(x: 0, y: y), animated: true)
      return true
    }

    // MARK: - Selection / active line (drives syntax show/hide)

    public func textViewDidChangeSelection(_ textView: UITextView) {
      guard let lm = layoutManager as? EditorLayoutManager else { return }
      let newSelection = selectedRange
      guard newSelection != lm.activeCharacterRange else { return }
      // A viewer never reveals syntax: nothing to re-lay out.
      guard !isReadOnly else {
        lm.activeCharacterRange = newSelection
        return
      }
      // Leaving a source-mode table returns it to the grid (the reading state); source mode
      // has no toggle of its own. Done BEFORE the visibility pass because a re-parse
      // replaces the attributes wholesale.
      if !sourceModeTables.isEmpty {
        let ordinal = tableOrdinal(at: newSelection.location)
        if ordinal == nil || !sourceModeTables.contains(ordinal!) {
          sourceModeTables.removeAll()
          reapplyMarkdown()
          return
        }
      }
      // Visibility changes for BOTH the old and new caret positions: an inline
      // command's delimiters show/hide as the caret enters/leaves its span, and
      // line-level commands as the caret moves between lines.
      let affected = NSUnionRange(
        lm.affectedRange(for: lm.activeCharacterRange), lm.affectedRange(for: newSelection))
      lm.activeCharacterRange = newSelection
      // An image whose source the caret entered (or left) loses (or regains) its slot.
      lm.updateImageSlots(in: affected)
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
      open(url)
      return false
    }

    /// Link routing: same-document anchors scroll, then the host, then the system.
    private func open(_ url: URL) {
      if let fragment = url.fragment, MarkdownParser.isSameDocument(url, resolver.documentURL),
        scrollToAnchor(fragment)
      {
        return
      }
      if onOpenURL?(url) == true { return }
      UIApplication.shared.open(url)
    }

    /// iOS 17+: a tapped link runs our routing instead of UIKit's default action.
    @available(iOS 17, *)
    public func textView(
      _ textView: UITextView, primaryActionFor textItem: UITextItem,
      defaultAction: UIAction
    ) -> UIAction? {
      guard case .link(let url) = textItem.content else { return defaultAction }
      return UIAction { [weak self] _ in self?.open(url) }
    }

    /// Grows image lines and collapses markup-only lines (see `adjustLineFragment`).
    public func layoutManager(
      _ layoutManager: NSLayoutManager,
      shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
      lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
      baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer,
      forGlyphRange glyphRange: NSRange
    ) -> Bool {
      markdownLayout.adjustLineFragment(
        &lineFragmentRect.pointee, usedRect: &lineFragmentUsedRect.pointee,
        baselineOffset: &baselineOffset.pointee, glyphRange: glyphRange)
    }

    // MARK: - Checkbox tap-to-toggle + code copy button

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
      guard recognizer.state == .ended else { return }
      let point = recognizer.location(in: self)
      // Code-block copy button: copy the block's code to the clipboard.
      let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
      if let lm = layoutManager as? EditorLayoutManager,
        let chrome = lm.copyButtons(origin: origin).first(where: { $0.copyFrame.contains(point) })
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
      // A viewer has no source modes and no checkboxes to toggle.
      if isReadOnly { return }
      // Table corner toggle: flip the table between the grid and its source text.
      if let lm = layoutManager as? EditorLayoutManager,
        let toggle = lm.tableToggles(origin: origin).first(where: { $0.frame.contains(point) })
      {
        setTableMode(
          source: !sourceModeTables.contains(toggle.tableOrdinal),
          ordinal: toggle.tableOrdinal)
        return
      }
      // Tapping INTO a grid-mode table switches it to source: a grid cell has hidden pipes
      // and alignment kerns, so typing there would be blind.
      let storage = textStorage
      let index = characterIndexForTap(at: point)
      if let ordinal = tableOrdinal(at: index), !sourceModeTables.contains(ordinal) {
        setTableMode(source: true, ordinal: ordinal)
      }
      // Checkbox toggle: hit-test the .markdownCheckbox attribute range.
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

    /// Flips one table between the grid and its raw markdown source. VIEW state only: the
    /// characters never change and `onChange` is not called — a host sees the same
    /// document either way.
    private func setTableMode(source: Bool, ordinal: Int) {
      let changed =
        source ? sourceModeTables.insert(ordinal).inserted : (sourceModeTables.remove(ordinal) != nil)
      guard changed else { return }
      reapplyMarkdown()
      setNeedsDisplay()
    }

    /// The table (0-based, document order) whose block covers `index`, if any. Both modes
    /// carry `.markdownTableOrdinal` over the table's whole range, so this is a pure
    /// attribute lookup.
    private func tableOrdinal(at index: Int) -> Int? {
      let storage = textStorage
      guard index >= 0, index < storage.length else { return nil }
      return (storage.attribute(.markdownTableOrdinal, at: index, effectiveRange: nil) as? NSNumber)?
        .intValue
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

    // MARK: - UIGestureRecognizerDelegate

    /// Let the checkbox/copy tap recognizer run TOGETHER with the text view's
    /// internal tap-to-edit recognizer, so tapping the editor both toggles
    /// interactive content AND raises the keyboard. Without this the custom
    /// recognizer forces the built-in one to fail and the keyboard never shows
    /// on tap (see configure()). Other recognizers (scroll pan, link tap) may
    /// also run simultaneously — that is the standard editing behaviour.
    public func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
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
