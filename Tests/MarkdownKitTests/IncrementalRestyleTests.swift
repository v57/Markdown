#if canImport(AppKit)
  import Testing
  import AppKit
  @testable import MarkdownKit

  // Re-styling writes only the runs that changed (positions that merely moved are written without invalidating
  // layout), and a long document is parsed in the background. Either way an edited editor must end up exactly like a
  // fresh one showing the same text: the same attributes and the same layout.
  @Suite @MainActor struct IncrementalRestyleTests {
    private func editor(_ text: String) -> (EditorTextView, NSWindow) {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let scroll = NSScrollView(frame: window.contentView!.bounds)
      window.contentView!.addSubview(scroll)
      let tv = EditorTextView(metrics: .standard, text: text)
      tv.frame = scroll.bounds
      scroll.documentView = tv
      tv.layoutManager!.ensureLayout(for: tv.textContainer!)
      return (tv, window)
    }

    private func type(_ text: String, at location: Int, in tv: EditorTextView) {
      tv.setSelectedRange(NSRange(location: location, length: 0))
      for character in text {
        tv.insertText(String(character), replacementRange: tv.selectedRange())
      }
    }

    private func delete(_ range: NSRange, in tv: EditorTextView) {
      tv.setSelectedRange(range)
      tv.deleteBackward(nil)
    }

    /// One run's attributes, comparable across editors: an image's spec is a class compared by identity.
    private func normalized(_ attributes: [NSAttributedString.Key: Any]) -> NSDictionary {
      var attributes = attributes
      if let spec = attributes[.markdownImageSpec] as? MarkdownImageSpec {
        attributes[.markdownImageSpec] = "\(spec.url) \(spec.range)"
      }
      return attributes as NSDictionary
    }

    /// Compares `edited` with a fresh editor showing its text, with the same selection: every character's
    /// attributes, the glyphs and every line fragment.
    private func expectMatchesFresh(_ edited: EditorTextView, sourceLocation: SourceLocation = #_sourceLocation) {
      let (fresh, window) = editor(edited.string)
      defer { window.close() }
      fresh.setSelectedRange(edited.selectedRange())
      let a = edited.textStorage!
      let b = fresh.textStorage!
      #expect(a.string == b.string, sourceLocation: sourceLocation)
      var index = 0
      var mismatches = 0
      while index < a.length, mismatches < 5 {
        var ra = NSRange()
        var rb = NSRange()
        let aa = normalized(a.attributes(at: index, effectiveRange: &ra))
        let bb = normalized(b.attributes(at: index, effectiveRange: &rb))
        if !aa.isEqual(bb) {
          mismatches += 1
          Issue.record("attributes differ at \(index): \(aa) vs \(bb)", sourceLocation: sourceLocation)
        }
        index = min(NSMaxRange(ra), NSMaxRange(rb))
      }
      let la = edited.layoutManager!
      let lb = fresh.layoutManager!
      la.ensureLayout(for: edited.textContainer!)
      lb.ensureLayout(for: fresh.textContainer!)
      #expect(la.numberOfGlyphs == lb.numberOfGlyphs, sourceLocation: sourceLocation)
      guard la.numberOfGlyphs == lb.numberOfGlyphs else { return }
      var glyph = 0
      while glyph < la.numberOfGlyphs {
        var range = NSRange()
        let fa = la.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
        let fb = lb.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let ua = la.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let ub = lb.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        if ua != ub {
          let chars = la.characterRange(forGlyphRange: range, actualGlyphRange: nil)
          Issue.record("used rect at glyph \(glyph) \((edited.string as NSString).substring(with: chars).debugDescription): \(ua) vs \(ub)", sourceLocation: sourceLocation)
          return
        }
        if fa != fb {
          Issue.record("line at glyph \(glyph): \(fa) vs \(fb)", sourceLocation: sourceLocation)
          return
        }
        for g in range.location..<NSMaxRange(range) where la.glyph(at: g) != lb.glyph(at: g) {
          Issue.record("glyph \(g) differs", sourceLocation: sourceLocation)
          return
        }
        glyph = NSMaxRange(range)
      }
      #expect(la.extraLineFragmentRect == lb.extraLineFragmentRect, sourceLocation: sourceLocation)
      #expect(la.extraLineFragmentUsedRect == lb.extraLineFragmentUsedRect, sourceLocation: sourceLocation)
      #expect(la.usedRect(for: edited.textContainer!).height == lb.usedRect(for: fresh.textContainer!).height, sourceLocation: sourceLocation)
    }

    static let document = """
      # Title

      Intro with **bold**, *italic*, `code` and a [link](https://example.com).

      - one **b**
      - two
      - [ ] task

      > quote **x**

      ```swift
      let a = 1
      ```

      | A | B |
      |---|---|
      | 1 | 2 |

      Tail paragraph with **more** *marks* and `spans` at the end.

      """

    @Test func editsMatchAFreshEditor() {
      let (tv, window) = editor(Self.document)
      defer { window.close() }
      let ns = { tv.string as NSString }
      type("abc ", at: ns().range(of: "Intro").location, in: tv)
      expectMatchesFresh(tv)
      type(" **new**", at: NSMaxRange(ns().range(of: "**bold**")), in: tv)
      expectMatchesFresh(tv)
      type("wide cell", at: ns().range(of: "| 1").location + 2, in: tv)
      expectMatchesFresh(tv)
      type("```\n", at: ns().range(of: "> quote").location, in: tv)
      expectMatchesFresh(tv)
      delete(NSRange(location: ns().range(of: "```\n> quote").location, length: 4), in: tv)
      expectMatchesFresh(tv)
      type("x", at: 0, in: tv)
      expectMatchesFresh(tv)
      tv.setSelectedRange(NSRange(location: ns().range(of: "more").location, length: 0))
      expectMatchesFresh(tv)
    }

    @Test func backgroundRestyleMatchesAFreshEditor() async throws {
      let (tv, window) = editor(String(repeating: Self.document, count: 3))
      defer { window.close() }
      tv.restyler.backgroundThreshold = 0
      tv.restyler.backgroundMinimumLength = 0
      let ns = { tv.string as NSString }
      type("one", at: ns().range(of: "Tail").location, in: tv)
      #expect(tv.isRestylePending, "the edit is parsed in the background")
      // Typed while the parse runs: the parse of the older text must not land.
      type(" **two**", at: ns().range(of: "Intro", options: .backwards).location, in: tv)
      for _ in 0..<2000 where tv.isRestylePending { try await Task.sleep(nanoseconds: 2_000_000) }
      #expect(!tv.isRestylePending)
      expectMatchesFresh(tv)
    }
  }
#endif
