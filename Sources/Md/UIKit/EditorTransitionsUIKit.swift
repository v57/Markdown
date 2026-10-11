#if canImport(UIKit)
  import UIKit

  /// Transitions for the editor's state changes (checkbox toggles, table grid ⇄ source,
  /// the copy button's "Copied" flash) — the UIKit twin of `EditorTransitions.swift`. A
  /// snapshot of how a region looked fades out over the redrawn region, and a toggled
  /// checkbox springs in on its own view while the layout manager leaves it undrawn.
  extension EditorTextView {
    /// Reduce Motion keeps the crossfades (they do not move anything) and drops the pop.
    static var reducesMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// Runs `change`, then crossfades `rect` (content coordinates) from how it looked before.
    func crossfade(_ rect: CGRect, duration: TimeInterval = 0.2, _ change: () -> Void) {
      let visible = CGRect(origin: contentOffset, size: bounds.size)
      let rect = rect.intersection(visible).integral
      guard window != nil, !rect.isEmpty,
        let snapshot = resizableSnapshotView(
          from: rect, afterScreenUpdates: false, withCapInsets: .zero)
      else {
        change()
        return
      }
      change()
      snapshot.frame = rect
      snapshot.isUserInteractionEnabled = false
      addSubview(snapshot)
      UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut]) {
        snapshot.alpha = 0
      }
      // Timed, not a completion block: an interrupted animation must not leave the
      // snapshot covering the text.
      DispatchQueue.main.asyncAfter(deadline: .now() + duration) { snapshot.removeFromSuperview() }
    }

    /// The rect a list item's lines occupy, across the full width (a toggled task's text
    /// changes color with its checkbox).
    func paragraphRect(containing range: NSRange) -> CGRect {
      let paragraph = (text as NSString).paragraphRange(for: range)
      let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
      let used = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
      return CGRect(
        x: 0, y: used.minY + textContainerInset.top, width: bounds.width, height: used.height)
    }

    /// Pops the checkbox whose `[ ]` range starts at `location` into its new state: it
    /// springs up from smaller while the layout manager leaves that checkbox undrawn.
    func popCheckbox(at location: Int, checked: Bool) {
      let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
      guard !Self.reducesMotion, window != nil,
        let lm = layoutManager as? EditorLayoutManager,
        let rect = lm.checkboxRect(at: location, origin: origin)
      else { return }
      let range = NSRange(location: location, length: 3)
      lm.checkboxesHiddenForAnimation.insert(location)
      lm.invalidateDisplay(forCharacterRange: range)

      // Drawn the way the layout manager draws it: the image stretched to the rect.
      let checkbox = UIImageView(image: CheckboxRenderer.image(checked: checked, size: rect.width))
      checkbox.contentMode = .scaleToFill
      checkbox.frame = rect
      checkbox.isUserInteractionEnabled = false
      checkbox.alpha = 0
      checkbox.transform = CGAffineTransform(scaleX: checked ? 0.55 : 0.8, y: checked ? 0.55 : 0.8)
      addSubview(checkbox)
      UIView.animate(withDuration: 0.12) { checkbox.alpha = 1 }
      UIView.animate(
        withDuration: 0.45, delay: 0, usingSpringWithDamping: checked ? 0.5 : 0.75,
        initialSpringVelocity: 0, options: [.allowUserInteraction]
      ) {
        checkbox.transform = .identity
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak lm] in
        checkbox.removeFromSuperview()
        lm?.checkboxesHiddenForAnimation.remove(location)
        if let lm, let length = self?.textStorage.length, NSMaxRange(range) <= length {
          lm.invalidateDisplay(forCharacterRange: range)
        }
      }
    }
  }
#endif
