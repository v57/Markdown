import Foundation
import Testing

@testable import MarkdownKit

/// `MarkdownFormatting`: the edits behind the Format menu and the keyboard toolbar.
@Suite struct FormattingTests {
  /// Applies `format` to `text` whose selection is marked with `[` `]` (or a caret `|`),
  /// and returns the result marked the same way.
  private func apply(_ format: MarkdownFormat, _ marked: String) -> String {
    var text = marked
    var selection: NSRange
    if let caret = text.range(of: "|") {
      selection = NSRange(location: text.utf16.distance(from: text.startIndex, to: caret.lowerBound), length: 0)
      text.removeSubrange(caret)
    } else {
      let open = text.range(of: "[")!
      let start = text.utf16.distance(from: text.startIndex, to: open.lowerBound)
      text.removeSubrange(open)
      let close = text.range(of: "]", range: text.index(text.startIndex, offsetBy: start)..<text.endIndex)!
      let end = text.utf16.distance(from: text.startIndex, to: close.lowerBound)
      text.removeSubrange(close)
      selection = NSRange(location: start, length: end - start)
    }
    let edit = MarkdownFormatting.edit(applying: format, to: text, selection: selection)
    let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) as NSString
    if edit.selection.length == 0 {
      return result.replacingCharacters(in: edit.selection, with: "|")
    }
    let selected = result.substring(with: edit.selection)
    return result.replacingCharacters(in: edit.selection, with: "[" + selected + "]")
  }

  @Test func wrapsAndUnwrapsInlineStyles() {
    #expect(apply(.bold, "a [word] b") == "a **[word]** b")
    #expect(apply(.bold, "a **[word]** b") == "a [word] b")
    #expect(apply(.bold, "a [**word**] b") == "a [word] b")
    #expect(apply(.bold, "a [word ]b") == "a **[word]** b")
    #expect(apply(.italic, "**[bold]**") == "**_[bold]_**")
    #expect(apply(.inlineCode, "x|y") == "x`|`y")
    #expect(apply(.bold, "x**|**y") == "x|y")
    #expect(apply(.strikethrough, "[gone]") == "~~[gone]~~")
  }

  @Test func insertsLinks() {
    #expect(apply(.link, "see [docs]") == "see [docs]([https://])")
    #expect(apply(.link, "see [https://v57.dev]") == "see [|](https://v57.dev)")
    #expect(apply(.link, "see |") == "see [|](https://)")
  }

  @Test func togglesLinePrefixes() {
    #expect(apply(.heading(2), "Ti|tle") == "## Ti|tle")
    #expect(apply(.heading(2), "## Ti|tle") == "Ti|tle")
    #expect(apply(.heading(1), "### Ti|tle") == "# Ti|tle")
    #expect(apply(.checklist, "- it|em") == "- [ ] it|em")
    #expect(apply(.checklist, "- [x] it|em") == "it|em")
    #expect(apply(.bulletList, "[one\ntwo]\nthree") == "[- one\n- two]\nthree")
    #expect(apply(.numberedList, "[one\n\ntwo]") == "[1. one\n\n2. two]")
    #expect(apply(.quote, "  in|dented") == "  > in|dented")
  }

  @Test func insertsBlocks() {
    #expect(apply(.codeBlock, "|") == "```\n|\n```")
    #expect(apply(.codeBlock, "text|") == "text\n\n```\n|\n```")
    #expect(apply(.codeBlock, "[let x = 1]\n") == "```\n|let x = 1\n```\n")
    #expect(apply(.table, "Intro|") == "Intro\n\n| [Column] | Column |\n| --- | --- |\n|  |  |")
  }

  /// The text after `format` on all of it selected: for checkboxes, whose brackets `apply` would read as a selection.
  private func whole(_ format: MarkdownFormat, _ text: String) -> String {
    let edit = MarkdownFormatting.edit(
      applying: format, to: text, selection: NSRange(location: 0, length: (text as NSString).length))
    return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
  }

  @Test func toggleList() {
    #expect(apply(.toggleList, "it|em") == "- it|em")
    #expect(apply(.toggleList, "- it|em") == "it|em")
    #expect(apply(.toggleList, "- [x] it|em") == "it|em")
    #expect(apply(.toggleList, "1. it|em") == "- it|em")
    #expect(apply(.toggleList, "[one\n\ntwo\n]") == "[- one\n\n- two]\n")
    #expect(whole(.toggleList, "- one\n- [ ] two") == "one\ntwo")
    #expect(whole(.toggleList, "one\n- [ ] two") == "- one\n- [ ] two")
    #expect(apply(.toggleList, "> qu|ote") == "> - qu|ote")
    #expect(apply(.toggleList, "wo[rd] more") == "- wo[rd] more")
  }

  @Test func toggleNumberedList() {
    #expect(apply(.numberedList, "it|em") == "1. it|em")
    #expect(apply(.numberedList, "1. it|em") == "it|em")
    #expect(apply(.numberedList, "[- one\ntwo]") == "[1. one\n2. two]")
    #expect(apply(.numberedList, "[1. one\n3. two]") == "[one\ntwo]")
  }

  @Test func toggleCheckbox() {
    #expect(apply(.toggleCheckbox, "it|em") == "- [ ] it|em")
    #expect(apply(.toggleCheckbox, "- it|em") == "- [ ] it|em")
    #expect(apply(.toggleCheckbox, "- [ ] it|em") == "- [x] it|em")
    #expect(apply(.toggleCheckbox, "- [x] it|em") == "- [ ] it|em")
    #expect(apply(.toggleCheckbox, "* [ ] it|em") == "* [x] it|em")
    #expect(whole(.toggleCheckbox, "- [x] one\ntwo") == "- [x] one\n- [ ] two")
    #expect(whole(.toggleCheckbox, "- [x] one\n- [ ] two") == "- [x] one\n- [x] two")
    #expect(whole(.toggleCheckbox, "- [x] one\n- [x] two") == "- [ ] one\n- [ ] two")
    #expect(apply(.toggleCheckedCheckbox, "it|em") == "- [x] it|em")
    #expect(apply(.toggleCheckedCheckbox, "- [ ] it|em") == "- [x] it|em")
    #expect(apply(.toggleCheckedCheckbox, "- [x] it|em") == "- [ ] it|em")
    #expect(whole(.toggleCheckedCheckbox, "one\n- [ ] two") == "- [x] one\n- [x] two")
  }

  @Test func toggleCode() {
    #expect(apply(.toggleCode, "a [word] here") == "a `[word]` here")
    #expect(apply(.toggleCode, "a `[word]` here") == "a [word] here")
    #expect(apply(.toggleCode, "a `wo|rd` here") == "a wo|rd here")
    #expect(apply(.toggleCode, "ca|ret") == "ca`|`ret")
    #expect(apply(.toggleCode, "[one\ntwo]\n") == "```\n[one\ntwo]\n```\n")
    #expect(apply(.toggleCode, "o[ne\ntw]o") == "```\n[one\ntwo]\n```")
    #expect(apply(.toggleCode, "```\n[one\ntwo]\n```\n") == "[one\ntwo]\n")
    #expect(apply(.toggleCode, "```\n[one\ntwo]\n```") == "[one\ntwo]")
    #expect(apply(.toggleCode, "[```\none\n```\n]") == "[one]\n")
    #expect(apply(.toggleCode, "```\non|e\n```\nnext") == "on|e\nnext")
  }

  @Test func toggleNote() {
    #expect(apply(.quote, "it|em") == "> it|em")
    #expect(apply(.quote, "> it|em") == "it|em")
    #expect(apply(.quote, "- it|em") == "> - it|em")
    #expect(apply(.quote, "> - it|em") == "- it|em")
    #expect(apply(.quote, "[one\n\ntwo]") == "[> one\n> \n> two]")
    #expect(apply(.quote, "[> one\n> \n> two]") == "[one\n\ntwo]")
    #expect(apply(.quote, "> > it|em") == "> it|em")
    #expect(apply(.quote, "wo[rd]") == "> wo[rd]")
  }
}
