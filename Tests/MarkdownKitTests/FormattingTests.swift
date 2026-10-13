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
}
