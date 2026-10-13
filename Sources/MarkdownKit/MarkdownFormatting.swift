import Foundation

/// A formatting command for the editor's selection — what a Format menu or a keyboard
/// toolbar offers. Inline styles wrap the selection in markers (or unwrap it when it is
/// already wrapped); line styles toggle a prefix on every selected line; blocks insert
/// a fenced code block or a table.
public enum MarkdownFormat: Hashable, Sendable {
  case bold, italic, strikethrough, inlineCode, link
  /// `#` … `######`; the same level again removes the heading.
  case heading(Int)
  case bulletList, numberedList, checklist, quote
  case codeBlock, table
}

/// One text change: replace `range` with `replacement`, then select `selection`
/// (ranges in UTF-16 units, like `NSString` and the text views).
public struct MarkdownEdit: Equatable, Sendable {
  public var range: NSRange
  public var replacement: String
  public var selection: NSRange

  public init(range: NSRange, replacement: String, selection: NSRange) {
    self.range = range
    self.replacement = replacement
    self.selection = selection
  }
}

/// Computes the edit a `MarkdownFormat` makes, without touching a text view (both
/// editors apply the result through their own undo-aware paths).
public enum MarkdownFormatting {
  public static func edit(applying format: MarkdownFormat, to text: String, selection: NSRange)
    -> MarkdownEdit
  {
    let ns = text as NSString
    let selection = NSRange(
      location: min(selection.location, ns.length),
      length: min(selection.length, ns.length - min(selection.location, ns.length)))
    switch format {
    case .bold: return wrap(ns, selection, marker: "**")
    // Underscores, so toggling italic inside **bold** never takes one of its asterisks.
    case .italic: return wrap(ns, selection, marker: "_")
    case .strikethrough: return wrap(ns, selection, marker: "~~")
    case .inlineCode: return wrap(ns, selection, marker: "`")
    case .link: return link(ns, selection)
    case .heading(let level):
      return prefixLines(ns, selection, kind: .heading(max(1, min(6, level))))
    case .bulletList: return prefixLines(ns, selection, kind: .bullet)
    case .numberedList: return prefixLines(ns, selection, kind: .numbered)
    case .checklist: return prefixLines(ns, selection, kind: .checklist)
    case .quote: return prefixLines(ns, selection, kind: .quote)
    case .codeBlock: return codeBlock(ns, selection)
    case .table: return table(ns, selection)
    }
  }

  // MARK: - Inline

  private static func wrap(_ ns: NSString, _ selection: NSRange, marker: String) -> MarkdownEdit {
    let m = (marker as NSString).length
    let sel = trimmingWhitespace(ns, selection)
    // Markers right around the selection (or around the caret): unwrap.
    if sel.location >= m, NSMaxRange(sel) + m <= ns.length,
      ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
      ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker
    {
      let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
      return MarkdownEdit(
        range: outer, replacement: ns.substring(with: sel),
        selection: NSRange(location: outer.location, length: sel.length))
    }
    // The selection includes its markers: unwrap.
    let selected = ns.substring(with: sel)
    if sel.length >= 2 * m, selected.hasPrefix(marker), selected.hasSuffix(marker) {
      let inner = (selected as NSString).substring(
        with: NSRange(location: m, length: sel.length - 2 * m))
      return MarkdownEdit(
        range: sel, replacement: inner,
        selection: NSRange(location: sel.location, length: sel.length - 2 * m))
    }
    return MarkdownEdit(
      range: sel, replacement: marker + selected + marker,
      selection: NSRange(location: sel.location + m, length: sel.length))
  }

  /// `[selection](https://)` with the URL selected for typing over; a selected URL
  /// becomes the link's target instead, with the caret in the empty title.
  private static func link(_ ns: NSString, _ selection: NSRange) -> MarkdownEdit {
    let sel = trimmingWhitespace(ns, selection)
    let selected = ns.substring(with: sel)
    if selected.hasPrefix("http://") || selected.hasPrefix("https://") {
      return MarkdownEdit(
        range: sel, replacement: "[](\(selected))",
        selection: NSRange(location: sel.location + 1, length: 0))
    }
    let title = "[" + selected + "]("
    let placeholder = "https://"
    let titleLength = (title as NSString).length
    return MarkdownEdit(
      range: sel, replacement: title + placeholder + ")",
      selection: selected.isEmpty
        ? NSRange(location: sel.location + 1, length: 0)
        : NSRange(location: sel.location + titleLength, length: (placeholder as NSString).length))
  }

  /// A double-clicked word often brings its trailing space; `**word **` is not bold.
  private static func trimmingWhitespace(_ ns: NSString, _ range: NSRange) -> NSRange {
    var start = range.location
    var end = NSMaxRange(range)
    let spaces = CharacterSet.whitespacesAndNewlines
    while start < end, let scalar = UnicodeScalar(ns.character(at: start)), spaces.contains(scalar) {
      start += 1
    }
    while end > start, let scalar = UnicodeScalar(ns.character(at: end - 1)), spaces.contains(scalar) {
      end -= 1
    }
    return NSRange(location: start, length: end - start)
  }

  // MARK: - Lines

  private enum LineKind: Equatable {
    case heading(Int), bullet, numbered, checklist, quote
  }

  /// A line's existing block marker (after its indentation), and what kind it is.
  private static let markerPattern = try! NSRegularExpression(
    pattern: #"^([ \t]*)(#{1,6}[ \t]+|[-*+][ \t]+\[[ xX]\][ \t]+|[-*+][ \t]+|\d+[.)][ \t]+|>[ \t]?)"#)

  private static func marker(of line: String) -> (indent: Int, length: Int, kind: LineKind)? {
    let ns = line as NSString
    guard let match = markerPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
    else { return nil }
    let indent = match.range(at: 1).length
    let marker = ns.substring(with: match.range(at: 2))
    let kind: LineKind
    if marker.hasPrefix("#") {
      kind = .heading(marker.prefix { $0 == "#" }.count)
    } else if marker.hasPrefix(">") {
      kind = .quote
    } else if marker.contains("[") {
      kind = .checklist
    } else if marker.first?.isNumber == true {
      kind = .numbered
    } else {
      kind = .bullet
    }
    return (indent, match.range(at: 2).length, kind)
  }

  private static func prefixLines(_ ns: NSString, _ selection: NSRange, kind: LineKind) -> MarkdownEdit {
    let block = ns.lineRange(for: selection)
    var lines = ns.substring(with: block).components(separatedBy: "\n")
    let endsWithNewline = lines.count > 1 && lines.last == ""
    if endsWithNewline { lines.removeLast() }
    let single = lines.count == 1
    let targets = lines.indices.filter { single || !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
    // Every selected line already has this style: take it off.
    let removes = !targets.isEmpty && targets.allSatisfy { marker(of: lines[$0])?.kind == kind }
    var number = 0
    var firstDelta = 0
    var firstOldMarkerEnd = 0
    var firstNewMarkerEnd = 0
    for (n, i) in targets.enumerated() {
      let line = lines[i] as NSString
      let existing = marker(of: lines[i])
      let indent = existing?.indent ?? (lines[i].prefix { $0 == " " || $0 == "\t" }.utf16.count)
      let oldEnd = indent + (existing?.length ?? 0)
      let prefix: String
      if removes {
        prefix = ""
      } else {
        number += 1
        switch kind {
        case .heading(let level): prefix = String(repeating: "#", count: level) + " "
        case .bullet: prefix = "- "
        case .numbered: prefix = "\(number). "
        case .checklist: prefix = "- [ ] "
        case .quote: prefix = "> "
        }
      }
      lines[i] = line.substring(to: indent) + prefix + line.substring(from: oldEnd)
      if n == 0 {
        firstDelta = (prefix as NSString).length - (oldEnd - indent)
        firstOldMarkerEnd = oldEnd
        firstNewMarkerEnd = indent + (prefix as NSString).length
      }
    }
    let replacement = lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
    let newSelection: NSRange
    if single, selection.length == 0 {
      // The caret keeps its place in the text; inside the old marker it moves after the new one.
      let column = selection.location - block.location
      let location = column <= firstOldMarkerEnd ? firstNewMarkerEnd : column + firstDelta
      newSelection = NSRange(location: block.location + location, length: 0)
    } else {
      let length = (replacement as NSString).length - (endsWithNewline ? 1 : 0)
      newSelection = NSRange(location: block.location, length: length)
    }
    return MarkdownEdit(range: block, replacement: replacement, selection: newSelection)
  }

  // MARK: - Blocks

  private static func codeBlock(_ ns: NSString, _ selection: NSRange) -> MarkdownEdit {
    if selection.length > 0 {
      let block = ns.lineRange(for: selection)
      var body = ns.substring(with: block)
      let endsWithNewline = body.hasSuffix("\n")
      if endsWithNewline { body.removeLast() }
      let replacement = "```\n" + body + "\n```" + (endsWithNewline ? "\n" : "")
      return MarkdownEdit(
        range: block, replacement: replacement,
        selection: NSRange(location: block.location + 4, length: 0))
    }
    let (at, lead) = blockInsertionPoint(ns, selection)
    let replacement = lead + "```\n\n```"
    return MarkdownEdit(
      range: NSRange(location: at, length: 0), replacement: replacement,
      selection: NSRange(location: at + (lead as NSString).length + 4, length: 0))
  }

  private static func table(_ ns: NSString, _ selection: NSRange) -> MarkdownEdit {
    let (at, lead) = blockInsertionPoint(ns, NSRange(location: NSMaxRange(selection), length: 0))
    let table = "| Column | Column |\n| --- | --- |\n|  |  |"
    return MarkdownEdit(
      range: NSRange(location: at, length: 0), replacement: lead + table,
      selection: NSRange(location: at + (lead as NSString).length + 2, length: 6))
  }

  /// A block goes on the caret's line when that line is empty, otherwise after it,
  /// separated by a blank line (a fence or table glued to a paragraph doesn't parse).
  private static func blockInsertionPoint(_ ns: NSString, _ selection: NSRange) -> (Int, String) {
    let line = ns.lineRange(for: NSRange(location: selection.location, length: 0))
    var content = ns.substring(with: line)
    if content.hasSuffix("\n") { content.removeLast() }
    if content.trimmingCharacters(in: .whitespaces).isEmpty {
      return (line.location, "")
    }
    let end = line.location + (content as NSString).length
    return (end, "\n\n")
  }
}

/// Lets a host apply `MarkdownFormat`s to an editor it embeds through
/// `MarkdownEditorView` (pass it as `commands:`): toolbar buttons and menu items call
/// `apply(_:)`; it does nothing while no editor is attached or the editor is read-only.
@MainActor public final class MarkdownEditorCommands {
  weak var textView: EditorTextView?

  public init() {}

  /// Whether `apply(_:)` will do anything now.
  public var isAvailable: Bool { textView.map { !$0.isReadOnly } ?? false }

  public func apply(_ format: MarkdownFormat) {
    textView?.apply(format)
  }
}
