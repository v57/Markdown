#if canImport(AppKit)
  import AppKit

  extension EditorTextView {
    /// Applies a formatting command to the selection as one undoable edit, like typing:
    /// the text is re-styled and `onChange` reports it.
    public func apply(_ format: MarkdownFormat) {
      guard !isReadOnly, let storage = textStorage else { return }
      let edit = MarkdownFormatting.edit(applying: format, to: string, selection: selectedRange())
      guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
      storage.replaceCharacters(in: edit.range, with: edit.replacement)
      didChangeText()
      setSelectedRange(edit.selection)
      scrollRangeToVisible(edit.selection)
      window?.makeFirstResponder(self)
    }
  }
#endif
