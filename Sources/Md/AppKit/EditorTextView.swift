#if canImport(AppKit)
  import AppKit

  @MainActor
  public final class EditorTextView: NSTextView, NSTextViewDelegate, NSLayoutManagerDelegate {
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
    /// renders as its preview. Text stays selectable and links clickable.
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
        needsDisplay = true
      }
    }
    /// Asked first when a link is clicked; return true when the host handled it (e.g.
    /// opened another note). Same-document `#anchor` links scroll without asking;
    /// anything unhandled opens in the default browser/app.
    public var onOpenURL: (@MainActor (URL) -> Bool)?

    public init(metrics: MarkdownMetrics = .standard) {
      self.metrics = metrics
      markdownStorage = NSTextStorage()
      markdownLayout = EditorLayoutManager()
      markdownLayout.metrics = metrics
      markdownStorage.addLayoutManager(markdownLayout)
      markdownContainer = NSTextContainer(
        size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
      markdownContainer.widthTracksTextView = true
      markdownLayout.addTextContainer(markdownContainer)
      super.init(frame: .zero, textContainer: markdownContainer)
      configure()
      markdownStorage.setAttributedString(NSAttributedString(string: SampleDocument.text))  // launch sample
      // textDidChange only fires for user edits, not for this initial load — style
      // the sample document once here (identical to the per-edit reapply path).
      reapplyMarkdown()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
      isRichText = false  // pastes/drops land as plain text
      allowsUndo = true
      isHorizontallyResizable = false
      isVerticallyResizable = true
      // Scroll-content sizing: without explicit min/max the text view inherits the
      // initial clip size as its maxSize and can never grow past the first viewport
      // (the scroll content then clips the document bottom). Autoresizing [.width]
      // keeps the text width tracking the window so text re-wraps on resize.
      unclampSize()
      autoresizingMask = [.width]
      textContainerInset = NSSize(
        width: metrics.textContainerInsetWidth, height: metrics.textContainerInsetHeight)  // Obsidian-like margins
      font = MarkdownStyle(metrics: metrics).bodyFont
      textColor = .labelColor
      isAutomaticQuoteSubstitutionEnabled = false
      isAutomaticDashSubstitutionEnabled = false
      isAutomaticTextReplacementEnabled = false
      isAutomaticSpellingCorrectionEnabled = false
      isContinuousSpellCheckingEnabled = false
      isGrammarCheckingEnabled = false
      usesFindBar = true  // ⌘F find bar for free
      insertionPointColor = .labelColor
      delegate = self
      // Restore the automatic frame-grows-with-content path: NSTextView resizes
      // itself when the layout manager completes a layout pass (didCompleteLayoutFor),
      // which requires the text view to be the layout manager's delegate.
      markdownLayout.delegate = self
      // Links should NOT be underlined. We still set `.link` (URL) on link ranges so
      // they're clickable, but NSTextView applies its own DEFAULT link styling
      // (underline + color) to `.link`-carrying ranges via `linkTextAttributes`.
      // Override that dictionary to keep the link color (from our own styling) but
      // drop the underline — otherwise links stay underlined no matter what the
      // parser emits.
      linkTextAttributes = [
        .foregroundColor: MarkdownStyle(metrics: metrics).linkColor,
      ]
    }

    /// Replaces the document with `newText` and re-applies styling. Programmatic,
    /// so it does NOT fire `textDidChange` — `onChange` is not called (a host that
    /// wants to observe edits still gets them via the normal edit path). Used by
    /// hosts that inflate the editor with existing content (e.g. a note editor).
    public func setText(_ newText: String) {
      self.string = newText
      sourceModeTables.removeAll()
      reapplyMarkdown()
      setSelectedRange(NSRange(location: 0, length: 0))
    }

    // MARK: - Derived styling (re-parse on every character edit)

    /// Re-styling runs in `textDidChange`, which fires AFTER the edit settles in the
    /// SAME event: the selection is valid, and the first draw after the event already
    /// shows the styled (and zero-width-collapsed) text — no unstyled frame, no
    /// next-frame reflow (the visible "jump" an async deferral caused).
    ///
    /// It must NOT run inside `textStorage(_:didProcessEditing:)`: an attribute edit
    /// performed inside the storage's edit callback reaches the layout manager BEFORE
    /// the outer character edit's invalidation, and that interleaved state corrupts
    /// line breaking — a plain "Hello\nHello" laid out as "Hello" / "ello" (the
    /// newline stopped ending line 1; the second line's first glyph got absorbed
    /// into line 1's fragment). TextKit 1 tolerates no nested attribute edits during
    /// an edit event, however "storage-only" they are (reproduced headlessly: a
    /// storage delegate doing setAttributes inside didProcessEditing yields
    /// fragments [0,7)[7,11) instead of [0,6)[6,11)).
    ///
    /// reapplyMarkdown touches ONLY the STORAGE (setAttributes → .editedAttributes,
    /// which does not fire textDidChange — no recursion) plus the layout manager's
    /// caret range. setTypingAttributes also lives here: inside didProcessEditing it
    /// crashed (→ updateFontPanel → ensureAttributesAreFixedInRange with the stale
    /// selection, e.g. Select-All → Delete); here the selection is valid.
    public func textDidChange(_ notification: Notification) {
      reapplyMarkdown()
      typingAttributes = MarkdownStyle(metrics: metrics).typingAttributes
      onChange?(string)
    }

    private func reapplyMarkdown() {
      // Parse under THIS view's appearance: the code palette is resolved from the current
      // drawing appearance, which outside a draw pass is the app's — wrong whenever the
      // window or view overrides it (e.g. a light window in dark mode).
      var parsed: ParsedMarkdown!
      effectiveAppearance.performAsCurrentDrawingAppearance {
        parsed = MarkdownParser.parse(
          string, style: MarkdownStyleSpec(metrics: metrics), sourceModeTables: sourceModeTables,
          maxTableWidth: availableTableWidth, resolver: resolver)
      }
      tableWidths = parsed.tableWidths
      overflowingTables = MarkdownParser.overflowingTables(
        tableWidths, availableWidth: availableTableWidth)
      // Apply attributes only (characters are identical — verbatim invariant), so the
      // storage reports .editedAttributes and the guard above stops the loop.
      // NOTE: no explicit invalidateDisplay here — the attribute edits fire their own
      // (safe) layout invalidation. A manual [0, length) invalidation during the edit
      // callback crashes the layout manager (stale selection / end-of-string boundary).
      markdownStorage.beginEditing()
      parsed.attributed.enumerateAttributes(
        in: NSRange(location: 0, length: parsed.attributed.length), options: []
      ) { attrs, range, _ in markdownStorage.setAttributes(attrs, range: range) }
      markdownStorage.endEditing()
      // typingAttributes reset lives in textDidChange (same event, safe point):
      // setting it here would crash on the stale selection (Select-All → Delete).
      markdownLayout.activeCharacterRange = selectedRange()
      markdownLayout.updateImageSlots(in: NSRange(location: 0, length: markdownStorage.length))
      loadVisibleImages()
    }

    /// Width a table grid may occupy: the container minus its line-fragment padding. nil
    /// until the view has been sized (a zero-width container would fit no table).
    private var availableTableWidth: CGFloat? {
      guard let container = textContainer else { return nil }
      let width = container.size.width - container.lineFragmentPadding * 2
      return width > 0 ? width : nil
    }

    /// After a width change: re-parse when the set of tables too wide for a grid changed,
    /// so a table falls back to raw markdown instead of wrapping (and returns to the grid
    /// once it fits again).
    private func reflowTablesIfNeeded() {
      guard !tableWidths.isEmpty, !isReflowingTables else { return }
      let now = MarkdownParser.overflowingTables(tableWidths, availableWidth: availableTableWidth)
      guard now != overflowingTables else { return }
      isReflowingTables = true
      defer { isReflowingTables = false }
      reapplyMarkdown()
    }
    private var isReflowingTables = false

    // MARK: - Images (lazy loading, slots, animation)

    /// Loads the images in and around the visible part of the document (a screen above,
    /// two below) — a long README requests only what the reader is near. Called after
    /// re-styling and on every scroll.
    private func loadVisibleImages() {
      guard markdownStorage.length > 0 else { return }
      let visible =
        visibleRect.isEmpty ? NSRect(x: 0, y: 0, width: frame.width, height: 1200) : visibleRect
      let area = NSRect(
        x: visible.minX, y: visible.minY - visible.height, width: visible.width,
        height: visible.height * 4)
      let origin = textContainerOrigin
      let glyphs = markdownLayout.glyphRange(
        forBoundingRect: area.offsetBy(dx: -origin.x, dy: -origin.y), in: markdownContainer)
      let chars = markdownLayout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      guard chars.length > 0 else { return }
      let cache = MarkdownImageCache.shared
      markdownStorage.enumerateAttribute(.markdownImage, in: chars, options: []) { value, _, _ in
        guard let url = value as? URL, !cache.hasRequested(url) else { return }
        cache.load(url) { [weak self] url in self?.imageDidLoad(url) }
      }
      // Images loaded earlier (another document, before a re-parse) need their slots;
      // a no-op for images whose kern is already right.
      markdownLayout.updateImageSlots(in: chars)
    }

    private var loadedImageURLs: Set<URL> = []
    /// Coalesces image arrivals into one relayout per run-loop turn (a README's icons
    /// arrive in bursts).
    private func imageDidLoad(_ url: URL) {
      loadedImageURLs.insert(url)
      guard loadedImageURLs.count == 1 else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        let urls = self.loadedImageURLs
        self.loadedImageURLs.removeAll()
        for url in urls {
          for span in self.markdownLayout.imageSpans(for: url) { self.refreshImageSpan(span) }
        }
      }
    }

    /// Re-lays out one image's source span: its slot (kern), glyphs (the source collapses
    /// once the image draws) and line height.
    private func refreshImageSpan(_ span: NSRange) {
      markdownLayout.updateImageSlots(in: span)
      markdownLayout.invalidateGlyphs(
        forCharacterRange: span, changeInLength: 0, actualCharacterRange: nil)
      markdownLayout.invalidateLayout(forCharacterRange: span, actualCharacterRange: nil)
      markdownLayout.invalidateDisplay(forCharacterRange: span)
    }

    private var animationTimerScheduled = false
    /// Animated images record their rects while drawing; redraw those on the animation
    /// clock. One scrolled out of view is not drawn, so it stops asking.
    public override func draw(_ dirtyRect: NSRect) {
      markdownLayout.animatedImageRects.removeAll()
      super.draw(dirtyRect)
      let rects = markdownLayout.animatedImageRects
      guard !rects.isEmpty, !animationTimerScheduled else { return }
      animationTimerScheduled = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
        guard let self else { return }
        self.animationTimerScheduled = false
        for r in rects where r.intersects(self.visibleRect) { self.setNeedsDisplay(r) }
      }
    }

    // MARK: - Anchors

    /// Scrolls so the heading (or HTML `id`/`name` anchor) with GitHub slug `anchor` is at
    /// the top. Returns false when the document has no such anchor.
    @discardableResult
    public func scrollToAnchor(_ anchor: String) -> Bool {
      let key = (anchor.removingPercentEncoding ?? anchor).lowercased()
      guard let location = MarkdownParser.anchors(in: string)[key], markdownStorage.length > 0
      else { return false }
      let char = min(location, markdownStorage.length - 1)
      let glyph = markdownLayout.glyphIndexForCharacter(at: char)
      markdownLayout.ensureLayout(forGlyphRange: NSRange(location: 0, length: glyph + 1))
      let rect = markdownLayout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      scroll(NSPoint(x: 0, y: max(0, rect.minY + textContainerOrigin.y - 8)))
      return true
    }

    // MARK: - Selection / active line (drives syntax show/hide)

    /// Flips one table between the grid and its raw markdown source. VIEW state only:
    /// the characters never change and `onChange` is not called — a host sees the same
    /// document either way.
    private func setTableMode(source: Bool, ordinal: Int) {
      let changed = source ? sourceModeTables.insert(ordinal).inserted : (sourceModeTables.remove(ordinal) != nil)
      guard changed else { return }
      reapplyMarkdown()
      needsDisplay = true
    }

    /// The table (0-based, document order) whose block covers `index`, if any. Both modes
    /// carry `.markdownTableOrdinal` over the table's whole range, so this is a pure
    /// attribute lookup.
    private func tableOrdinal(at index: Int) -> Int? {
      guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
      return (storage.attribute(.markdownTableOrdinal, at: index, effectiveRange: nil) as? NSNumber)?
        .intValue
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
      guard let lm = layoutManager as? EditorLayoutManager else { return }
      let newSelection = selectedRange()
      guard newSelection != lm.activeCharacterRange else { return }
      // A viewer never reveals syntax: nothing to re-lay out.
      guard !isReadOnly else {
        lm.activeCharacterRange = newSelection
        return
      }
      // Leaving a source-mode table returns it to the grid: the grid is the reading state,
      // and source mode has no toggle of its own. Done BEFORE the visibility pass because
      // a re-parse replaces the attributes wholesale.
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

    /// NSTextView re-derives minSize/maxSize from the frame it receives (e.g. when the
    /// scroll view tiles it as documentView), which would clamp the frame to the first
    /// viewport size and break both scroll growth and shrinking for short documents.
    /// Re-assert before super so the text view stays free to track the layout height.
    public override func setFrameSize(_ newSize: NSSize) {
      // Setting minSize/maxSize resizes the view to fit them — which lands back
      // here. Unclamp only from the outermost call, or opening a document
      // recurses until the stack overflows.
      if !isUnclampingSize { unclampSize() }
      let widthChanged = abs(newSize.width - frame.width) > 0.5
      super.setFrameSize(newSize)
      if widthChanged {
        reflowTablesIfNeeded()
        // Every image's maximum width changed. Deferred: attribute edits are not safe in
        // the middle of a frame change.
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.markdownLayout.updateImageSlots(
            in: NSRange(location: 0, length: self.markdownStorage.length))
          self.loadVisibleImages()
        }
      }
    }

    /// Set while `unclampSize()` writes minSize/maxSize (see `setFrameSize`).
    private var isUnclampingSize = false

    /// Lifts the min/max clamp NSTextView derives from its frame, writing only the
    /// bounds that changed: every write makes NSTextView resize itself.
    private func unclampSize() {
      let unclampedMin = NSSize(width: 0, height: 0)
      let unclampedMax = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      guard minSize != unclampedMin || maxSize != unclampedMax else { return }
      isUnclampingSize = true
      defer { isUnclampingSize = false }
      if minSize != unclampedMin { minSize = unclampedMin }
      if maxSize != unclampedMax { maxSize = unclampedMax }
    }

    // MARK: - Scroll content sizing (document view tracks the layout)

    /// Grows/shrinks the text view frame to fit the laid-out content so the scroll
    /// view's content size always equals the document. Fired by the layout manager
    /// after every completed layout pass — including the selection-driven reflows
    /// (zero-width commands) and typing — so the scroller stays correct.
    public func layoutManager(
      _ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?,
      atEnd layoutFinishedFlag: Bool
    ) {
      guard let container = textContainer else { return }
      let used = layoutManager.usedRect(for: container)
      let targetHeight = used.height + textContainerInset.height * 2
      if abs(targetHeight - frame.height) > 0.5 {
        setFrameSize(NSSize(width: frame.width, height: targetHeight))
      }
    }

    // MARK: - Links

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool
    {
      guard let url = (link as? URL) ?? (link as? String).flatMap({ URL(string: $0) }) else {
        return true
      }
      if let fragment = url.fragment, MarkdownParser.isSameDocument(url, resolver.documentURL),
        scrollToAnchor(fragment)
      {
        return true
      }
      if onOpenURL?(url) == true { return true }
      NSWorkspace.shared.open(url)
      return true
    }

    /// Grows image lines and collapses markup-only lines (see `adjustLineFragment`).
    public func layoutManager(
      _ layoutManager: NSLayoutManager,
      shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
      lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
      baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer,
      forGlyphRange glyphRange: NSRange
    ) -> Bool {
      markdownLayout.adjustLineFragment(
        &lineFragmentRect.pointee, usedRect: &lineFragmentUsedRect.pointee,
        baselineOffset: &baselineOffset.pointee, glyphRange: glyphRange)
    }

    // MARK: - Interactive content (copy button, table toggle, checkbox)

    public override func mouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      // Code-block copy button: copy the block's code to the clipboard.
      if let lm = layoutManager as? EditorLayoutManager,
        let chrome = lm.copyButtons(origin: textContainerOrigin).first(where: {
          $0.copyFrame.contains(point)
        })
      {
        let code = (string as NSString).substring(with: chrome.blockRange)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        lm.markCopied(chrome.blockRange)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          [weak self, block = chrome.blockRange] in
          guard let self, let lm = self.layoutManager as? EditorLayoutManager else { return }
          lm.clearCopied(block)
          self.needsDisplay = true
        }
        return
      }
      // A viewer has no source modes and no checkboxes to toggle.
      if isReadOnly {
        super.mouseDown(with: event)
        return
      }
      // Table corner toggle: flip the table between the grid and its source text. The
      // click is consumed (like the copy button) so the caret does not jump.
      if let lm = layoutManager as? EditorLayoutManager,
        let toggle = lm.tableToggles(origin: textContainerOrigin).first(where: {
          $0.frame.contains(point)
        })
      {
        setTableMode(
          source: !sourceModeTables.contains(toggle.tableOrdinal),
          ordinal: toggle.tableOrdinal)
        return
      }
      let index = characterIndexForInsertion(at: point)
      let ns = string as NSString
      // Clicking INTO a grid-mode table switches it to source: a grid cell has hidden
      // pipes and alignment kerns, so typing there would be blind. The click still falls
      // through so it also places the caret.
      if let ordinal = tableOrdinal(at: index), !sourceModeTables.contains(ordinal) {
        setTableMode(source: true, ordinal: ordinal)
      }
      guard index < ns.length, let storage = textStorage,
        storage.attribute(.markdownCheckbox, at: index, effectiveRange: nil) != nil
      else {
        super.mouseDown(with: event)
        return
      }
      var eff = NSRange(location: 0, length: 0)
      _ = storage.attribute(.markdownCheckbox, at: index, effectiveRange: &eff)
      guard eff.length >= 3 else {
        super.mouseDown(with: event)
        return
      }
      let inner = NSRange(location: eff.location + 1, length: eff.length - 2)
      let current = ns.substring(with: inner)
      let replacement = (current == "x" || current == "X") ? " " : "x"
      if shouldChangeText(in: inner, replacementString: replacement) {
        textStorage?.replaceCharacters(in: inner, with: replacement)
        didChangeText()
      }
    }

    // MARK: - Smart list continuation on Return (Obsidian-style)

    /// Return inside a list item splits the line and continues the list: the new line
    /// is prepended with the item's marker (ordered-list numbers incremented, task
    /// checkboxes keep their state, indentation preserved). Return on a marker-only
    /// item removes the marker instead — that's the standard "exit the list" gesture.
    public override func insertNewline(_ sender: Any?) {
      let sel = selectedRange()
      let ns = string as NSString
      if sel.length == 0, ns.length > 0, sel.location <= ns.length {
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: lineRange)
        let content = line.hasSuffix("\n") ? String(line.dropLast()) : line
        if let cont = MarkdownParser.listContinuation(for: content) {
          continueBlock(cont, lineRange: lineRange, line: line, caret: sel.location)
          return
        }
        if let cont = MarkdownParser.quoteContinuation(for: content) {
          continueBlock(cont, lineRange: lineRange, line: line, caret: sel.location)
          return
        }
      }
      super.insertNewline(sender)
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
        if shouldChangeText(in: markerRange, replacementString: "") {
          textStorage?.replaceCharacters(in: markerRange, with: "")
          didChangeText()
          setSelectedRange(NSRange(location: markerRange.location, length: 0))
        }
      } else {
        // Split at the caret and carry the marker onto the new line.
        let insertion = "\n" + cont.marker
        let insertRange = NSRange(location: caret, length: 0)
        if shouldChangeText(in: insertRange, replacementString: insertion) {
          textStorage?.replaceCharacters(in: insertRange, with: insertion)
          didChangeText()
          let newCaret = caret + (insertion as NSString).length
          setSelectedRange(NSRange(location: newCaret, length: 0))
        }
      }
    }

    // MARK: - Trailing empty line (Select/Down past the last line)

    /// True when the document has text and does NOT end in a newline — i.e. its
    /// LAST line is non-empty. TextKit 1 lays out no line fragment for a trailing
    /// empty line, so the caret/selection cannot move past a non-empty last line.
    /// Other editors behave as if there is always one more (empty) line after the
    /// last line of text. When the user navigates / extends a selection past such a
    /// line, we append a trailing "\n" so the empty line becomes real & selectable.
    private var hasNonEmptyLastLine: Bool {
      let ns = string as NSString
      return ns.length > 0 && !string.hasSuffix("\n")
    }

    /// Appends a "\n" at the end (creating an empty final line). Keeps the caret at
    /// the new end, or extends the current selection's focus to it when
    /// `extendingSelection`. Uses the standard edit path so reapply + undo fire.
    private func appendTrailingNewline(extendingSelection: Bool) {
      let ns = string as NSString
      let end = ns.length
      let prior = selectedRange()
      guard shouldChangeText(in: NSRange(location: end, length: 0), replacementString: "\n")
      else { return }
      textStorage?.replaceCharacters(in: NSRange(location: end, length: 0), with: "\n")
      didChangeText()
      if extendingSelection {
        // The anchor is the selection's start; extend the focus to the new (empty)
        // final line. newLen == oldLen + 1, so this range is always valid.
        let anchor = prior.location
        let newLen = (string as NSString).length
        setSelectedRange(NSRange(location: anchor, length: newLen - anchor))
      } else {
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
      }
    }

    /// Shift+Down / Down at the very end of a non-empty last line: `super` does
    /// nothing (there is no line fragment to move to). Creating the empty line and
    /// moving onto it matches standard editor behavior.
    public override func moveDown(_ sender: Any?) {
      let ns = string as NSString
      if selectedRange().length == 0, ns.length > 0, selectedRange().location == ns.length,
        hasNonEmptyLastLine {
        appendTrailingNewline(extendingSelection: false)
        return
      }
      super.moveDown(sender)
    }

    /// Shift+Down extend-selection past a non-empty last line: produce the empty
    /// line so the selection can keep growing (like other editors).
    public override func moveDownAndModifySelection(_ sender: Any?) {
      let ns = string as NSString
      if ns.length > 0, NSMaxRange(selectedRange()) >= ns.length, hasNonEmptyLastLine {
        appendTrailingNewline(extendingSelection: true)
        return
      }
      super.moveDownAndModifySelection(sender)
    }

    public override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil {
        // Re-assert after the scroll view sized us: NSTextView can clamp min/max
        // back to the frame it received as documentView, which would block
        // shrinking below the first viewport / narrow windows.
        unclampSize()
        EditorTextView.live = self
        // Lazy image loading follows the scroll position.
        if let clip = enclosingScrollView?.contentView {
          clip.postsBoundsChangedNotifications = true
          NotificationCenter.default.removeObserver(
            self, name: NSView.boundsDidChangeNotification, object: nil)
          NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: clip)
        }
        loadVisibleImages()
        // Take focus only when nothing else in the window has it — never steal it from
        // a host's own fields.
        if let window, window.firstResponder == nil || window.firstResponder === window {
          window.makeFirstResponder(self)
        }
      }
    }

    @objc private func clipBoundsDidChange(_ note: Notification) { loadVisibleImages() }

    /// The code palette is GitHub Light/Dark (static colors, unlike the dynamic
    /// system colors used elsewhere) — re-apply when the appearance switches so
    /// fenced code restyles immediately instead of waiting for the next edit.
    public override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      reapplyMarkdown()
    }
  }
#endif
