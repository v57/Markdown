#if canImport(AppKit)
  import AppKit
  import QuartzCore

  /// Transitions for the editor's state changes (checkbox toggles, table grid ⇄ source,
  /// the copy button's "Copied" flash). The text is drawn by the layout manager, which
  /// cannot animate, so each transition is an overlay: a snapshot of how a region looked
  /// fades out over the redrawn region, and a toggled checkbox pops in on its own layer
  /// while the layout manager leaves it undrawn.
  extension EditorTextView {
    /// Reduce Motion keeps the crossfades (they do not move anything) and drops the pop.
    static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Runs `change`, then crossfades `rect` (view coordinates) from how it looked before.
    func crossfade(_ rect: CGRect, duration: TimeInterval = 0.2, _ change: () -> Void) {
      let rect = rect.intersection(visibleRect).integral
      guard window != nil, !rect.isEmpty, let rep = bitmapImageRepForCachingDisplay(in: rect)
      else {
        change()
        return
      }
      cacheDisplay(in: rect, to: rep)
      change()
      let snapshot = NSImage(size: rect.size)
      snapshot.addRepresentation(rep)
      let overlay = TransitionOverlay(frame: rect)
      overlay.image = snapshot
      overlay.imageScaling = .scaleAxesIndependently
      addSubview(overlay)
      NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        overlay.animator().alphaValue = 0
      }
      // Timed, not a completion handler: those never fire for a window that is not on
      // screen, which would leave the snapshot covering the text.
      DispatchQueue.main.asyncAfter(deadline: .now() + duration) { overlay.removeFromSuperview() }
    }

    /// The rect a list item's lines occupy, across the full width (a toggled task's text
    /// changes color with its checkbox).
    func paragraphRect(containing range: NSRange) -> CGRect {
      guard let lm = layoutManager, let container = textContainer else { return .zero }
      let paragraph = (string as NSString).paragraphRange(for: range)
      let glyphs = lm.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
      let used = lm.boundingRect(forGlyphRange: glyphs, in: container)
      return CGRect(x: 0, y: used.minY + textContainerOrigin.y, width: bounds.width, height: used.height)
    }

    /// Pops the checkbox whose `[ ]` range starts at `location` into its new state: it
    /// springs up from smaller while the layout manager leaves that checkbox undrawn.
    func popCheckbox(at location: Int, checked: Bool) {
      guard !Self.reducesMotion, window != nil, let lm = layoutManager as? EditorLayoutManager,
        let rect = lm.checkboxRect(at: location, origin: textContainerOrigin),
        let image = Self.rasterize(size: rect.size, scale: window?.backingScaleFactor ?? 2, appearance: effectiveAppearance, {
          CheckboxRenderer.image(checked: checked, size: rect.width).draw(in: $0)
        })
      else { return }
      let range = NSRange(location: location, length: 3)
      lm.checkboxesHiddenForAnimation.insert(location)
      lm.invalidateDisplay(forCharacterRange: range)

      let overlay = TransitionOverlay(frame: rect)
      overlay.wantsLayer = true
      addSubview(overlay)
      // A layer of our own: a view's backing layer scales about its corner.
      let checkbox = CALayer()
      checkbox.frame = overlay.bounds
      checkbox.contents = image
      overlay.layer?.addSublayer(checkbox)

      let scale = CASpringAnimation(keyPath: "transform.scale")
      scale.fromValue = checked ? 0.55 : 0.8
      scale.toValue = 1
      scale.damping = checked ? 11 : 16
      scale.stiffness = 320
      scale.duration = scale.settlingDuration
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0
      fade.toValue = 1
      fade.duration = 0.12
      checkbox.add(scale, forKey: "pop")
      checkbox.add(fade, forKey: "fade")
      // Timed cleanup (see `crossfade`): the layout manager draws the checkbox again.
      DispatchQueue.main.asyncAfter(deadline: .now() + scale.duration) {
        [weak self, weak lm] in
        overlay.removeFromSuperview()
        lm?.checkboxesHiddenForAnimation.remove(location)
        if let lm, let storage = self?.textStorage, NSMaxRange(range) <= storage.length {
          lm.invalidateDisplay(forCharacterRange: range)
        }
      }
    }

    /// Draws into a bitmap the way the layout manager would (dynamic colors resolved for
    /// `appearance`).
    static func rasterize(
      size: CGSize, scale: CGFloat, appearance: NSAppearance, _ draw: (CGRect) -> Void
    ) -> CGImage? {
      let width = Int((size.width * scale).rounded(.up))
      let height = Int((size.height * scale).rounded(.up))
      guard width > 0, height > 0,
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0)
      else { return nil }
      rep.size = size
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      appearance.performAsCurrentDrawingAppearance { draw(CGRect(origin: .zero, size: size)) }
      NSGraphicsContext.restoreGraphicsState()
      return rep.cgImage
    }
  }

  /// A transition overlay: never takes clicks (the editor under it stays usable).
  private final class TransitionOverlay: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
#endif
