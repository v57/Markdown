import Foundation
import Markdown

/// Corrects cmark's columns for inline nodes on a paragraph's later lines.
///
/// cmark reports an inline node's column as the paragraph's first-line column plus the node's offset in that line's
/// content, as if every line of the paragraph started where its first line did. A line whose content starts elsewhere
/// comes out shifted: a lazy continuation line (`- item` then `**after** list`, `> quote` then `more`) by the
/// container prefix it leaves out, an indented paragraph's flush line by the indent. The editor hid the wrong
/// characters there ("**ter**ist" for `**after** list`, M-010).
///
/// `deltas` gives, per 1-based line, the byte columns to add to an inline position on that line. Lines that need
/// nothing (first lines, continuation lines that start where the first did) are left out. Block nodes' own ranges are
/// right and take no correction.
struct MarkdownInlineColumns {
  private(set) var deltas: [Int: Int] = [:]

  init(document: Markup, lines: [String]) {
    let bytes = lines.map { Array($0.utf8) }
    var indents: [Int: Int] = [:]  // a list item's continuation indent, by where it starts
    let walker = Walker(lines: bytes)
    func visit(_ node: Markup) {
      if node is Paragraph || node is Heading, let range = node.range, range.upperBound.line > range.lowerBound.line {
        add(node, range: range)
      }
      for child in node.children where !(child is InlineMarkup) { visit(child) }
    }
    func add(_ node: Markup, range: SourceRange) {
      let blockOffset = range.lowerBound.column - 1
      let chain = containers(of: node)
      for line in (range.lowerBound.line + 1)...range.upperBound.line where line <= bytes.count {
        guard let start = walker.contentStart(line: line, chain: chain, indents: &indents) else { continue }
        if start != blockOffset { deltas[line] = start - blockOffset }
      }
    }
    visit(document)
  }

  /// `column` (1-based bytes, as cmark reports it) of an inline position on `line`, corrected.
  func column(_ column: Int, line: Int) -> Int {
    max(1, column + (deltas[line] ?? 0))
  }

  /// The block quotes and list items around `node`, outermost first: the containers whose prefixes a line matches.
  private func containers(of node: Markup) -> [Markup] {
    var chain: [Markup] = []
    var parent = node.parent
    while let p = parent {
      if p is BlockQuote || p is ListItem { chain.append(p) }
      parent = p.parent
    }
    return chain.reversed()
  }

  /// Matches containers' prefixes on a line, as cmark's block parser does (`S_process_line`).
  private struct Walker {
    let lines: [[UInt8]]

    /// Where cmark started the paragraph's content on `line`: after the prefixes of the containers that matched, and
    /// past the indentation when all of them did (a lazy line keeps its spaces). Nil for a tab in the prefix.
    func contentStart(line: Int, chain: [Markup], indents: inout [Int: Int]) -> Int? {
      let text = lines[line - 1]
      var offset = 0
      for container in chain {
        guard let matched = match(container, in: text, at: offset, indents: &indents) else { return nil }
        guard let next = matched else {
          return offset  // lazy: the rest of the line, its spaces included
        }
        offset = next
      }
      return firstNonSpace(text, from: offset)
    }

    /// The offset after `container`'s continuation prefix on a line, `.some(nil)` when the line doesn't continue it
    /// (lazy), nil when it can't be told (a tab).
    private func match(_ container: Markup, in text: [UInt8], at offset: Int, indents: inout [Int: Int])
      -> Int??
    {
      let first = firstNonSpace(text, from: offset)
      if text[offset..<first].contains(0x09) { return nil }
      let indent = first - offset
      if container is BlockQuote {
        guard indent <= 3, first < text.count, text[first] == UInt8(ascii: ">") else { return .some(nil) }
        var next = first + 1
        if next < text.count, text[next] == 0x20 { next += 1 } else if next < text.count, text[next] == 0x09 { return nil }
        return next
      }
      guard let item = container as? ListItem, let required = contentIndent(of: item, indents: &indents) else {
        return nil
      }
      return indent >= required ? offset + required : .some(nil)
    }

    /// A list item's marker offset plus padding (cmark's `marker_offset + padding`): how far a line must be indented,
    /// from its container's prefix, to continue the item.
    private func contentIndent(of item: ListItem, indents: inout [Int: Int]) -> Int? {
      guard let range = item.range, range.lowerBound.line >= 1, range.lowerBound.line <= lines.count else { return nil }
      let key = range.lowerBound.line << 20 | range.lowerBound.column
      if let known = indents[key] { return known }
      let text = lines[range.lowerBound.line - 1]
      let marker = range.lowerBound.column - 1  // cmark starts an item at its marker
      guard marker < text.count else { return nil }
      // The prefix before the marker belongs to the containers outside the item; its start is where they ended,
      // which is the marker less up to 3 spaces of the item's own indentation.
      var start = marker
      while start > 0, marker - start < 3, text[start - 1] == 0x20 { start -= 1 }
      var end = marker
      if text[end] == UInt8(ascii: "-") || text[end] == UInt8(ascii: "*") || text[end] == UInt8(ascii: "+") {
        end += 1
      } else {
        while end < text.count, (0x30...0x39).contains(text[end]) { end += 1 }
        end += 1  // `.` or `)`
      }
      let width = end - marker
      var spaces = 0
      while end + spaces < text.count, text[end + spaces] == 0x20 { spaces += 1 }
      if end + spaces < text.count, text[end + spaces] == 0x09 { return nil }
      let rest = end + spaces >= text.count
      let padding = width + ((spaces >= 5 || spaces == 0 || rest) ? 1 : spaces)
      let indent = (marker - start) + padding
      indents[key] = indent
      return indent
    }

    private func firstNonSpace(_ text: [UInt8], from offset: Int) -> Int {
      var i = offset
      while i < text.count, text[i] == 0x20 || text[i] == 0x09 { i += 1 }
      return i
    }
  }
}
