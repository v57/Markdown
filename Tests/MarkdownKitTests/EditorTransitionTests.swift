#if canImport(AppKit)
  import Testing
  import AppKit
  @testable import MarkdownKit

  // A checkbox click toggles the source, reports the edit, and animates through
  // overlays that leave the text view as they found it.
  @Suite @MainActor struct EditorTransitionTests {
    private func editor(_ text: String) -> (EditorTextView, NSWindow) {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let tv = EditorTextView(metrics: .standard)
      tv.frame = window.contentView!.bounds
      window.contentView!.addSubview(tv)
      tv.setText(text)
      tv.layoutManager!.ensureLayout(for: tv.textContainer!)
      return (tv, window)
    }

    private func click(_ tv: EditorTextView, at point: CGPoint) {
      let event = NSEvent.mouseEvent(
        with: .leftMouseDown, location: tv.convert(point, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: tv.window!.windowNumber, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 1)!
      tv.mouseDown(with: event)
    }

    @Test func checkboxClickTogglesAndCleansUp() async throws {
      let (tv, window) = editor("- [ ] one\n- [x] two\n")
      defer { window.close() }
      var changes: [String] = []
      tv.onChange = { changes.append($0) }
      let lm = try #require(tv.layoutManager as? EditorLayoutManager)
      let rect = try #require(lm.checkboxRect(at: 2, origin: tv.textContainerOrigin))
      click(tv, at: CGPoint(x: rect.midX, y: rect.midY))

      #expect(tv.string == "- [x] one\n- [x] two\n")
      #expect(changes == ["- [x] one\n- [x] two\n"])
      #expect(!tv.subviews.isEmpty)  // the crossfade (and, without Reduce Motion, the pop)
      if !EditorTextView.reducesMotion {
        #expect(lm.checkboxesHiddenForAnimation == [2])
      }

      // Both overlays finish within a second and put the checkbox back in the text.
      let deadline = Date().addingTimeInterval(2)
      while (!tv.subviews.isEmpty || !lm.checkboxesHiddenForAnimation.isEmpty), Date() < deadline {
        try await Task.sleep(for: .milliseconds(50))  // the main queue runs the cleanup
      }
      #expect(tv.subviews.isEmpty)
      #expect(lm.checkboxesHiddenForAnimation.isEmpty)
    }

    @Test func checkboxRectFollowsTheCheckbox() throws {
      let (tv, window) = editor("text\n\n- [ ] task\n")
      defer { window.close() }
      let lm = try #require(tv.layoutManager as? EditorLayoutManager)
      #expect(lm.checkboxRect(at: 0, origin: .zero) == nil)  // not a checkbox
      let rect = try #require(lm.checkboxRect(at: 8, origin: .zero))
      #expect(rect.width > 0 && rect.minY > 0)
    }
  }
#endif
