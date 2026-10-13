#if canImport(UIKit)
  import UIKit

  extension EditorTextView {
    /// Applies a formatting command to the selection as one undoable edit, like typing:
    /// the text is re-styled and `onChange` reports it.
    public func apply(_ format: MarkdownFormat) {
      guard !isReadOnly else { return }
      let edit = MarkdownFormatting.edit(applying: format, to: text, selection: selectedRange)
      selectedRange = edit.range
      if edit.replacement.isEmpty {
        if edit.range.length > 0 { deleteBackward() }
      } else {
        insertText(edit.replacement)
      }
      selectedRange = edit.selection
      scrollRangeToVisible(edit.selection)
    }
  }
#endif
