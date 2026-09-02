#if canImport(AppKit)
  import Testing
  import AppKit
  @testable import Md

  // Regression: selecting / navigating DOWN past the last line of a document whose
  // last line is non-empty must behave like other editors — append a trailing
  // "\n" (creating an empty final line) and move/extend the selection onto it.
  // TextKit 1 lays out NO line fragment for a trailing empty line, so without this
  // the caret and extend-selection dead-end on the last text line.
  @Suite @MainActor struct EditorEndOfDocumentTests {
    @Test func downAtEndOfNonEmptyLastLineCreatesEmptyLine() {
      let tv = EditorTextView(metrics: .standard)
      tv.setText("foo\nbar")
      tv.setSelectedRange(NSRange(location: 7, length: 0))
      tv.moveDown(nil)
      #expect(tv.string == "foo\nbar\n")
      #expect(tv.selectedRange == NSRange(location: 8, length: 0))
    }

    @Test func downAtEndOfSingleNonEmptyLineCreatesEmptyLine() {
      let tv = EditorTextView(metrics: .standard)
      tv.setText("foo")
      tv.setSelectedRange(NSRange(location: 3, length: 0))
      tv.moveDown(nil)
      #expect(tv.string == "foo\n")
      #expect(tv.selectedRange == NSRange(location: 4, length: 0))
    }

    @Test func extendSelectionPastNonEmptyLastLine() {
      let tv = EditorTextView(metrics: .standard)
      tv.setText("foo\nbar")
      tv.setSelectedRange(NSRange(location: 0, length: 1))
      for _ in 0..<5 { tv.moveDownAndModifySelection(nil) }
      #expect(tv.string == "foo\nbar\n")
      #expect(tv.selectedRange == NSRange(location: 0, length: 8))
    }

    @Test func downOnNewlineTerminatedEmptyLineDoesNotDoubleAppend() {
      let tv = EditorTextView(metrics: .standard)
      tv.setText("foo\n")
      tv.setSelectedRange(NSRange(location: 4, length: 0))
      tv.moveDown(nil)
      #expect(tv.string == "foo\n")  // empty final line already exists; no extra "\n"
      #expect(tv.selectedRange == NSRange(location: 4, length: 0))
    }

    @Test func verbatimInvariantAfterCreatedNewline() {
      let tv = EditorTextView(metrics: .standard)
      tv.setText("hello")
      tv.setSelectedRange(NSRange(location: 5, length: 0))
      tv.moveDown(nil)
      let s = tv.string
      #expect(MarkdownParser.parse(s, style: MarkdownStyleSpec.standard).attributed.string == s)
    }
  }
#endif
