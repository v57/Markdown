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
  /// A list of the selected lines, or no list and no checkboxes when they all are one.
  case toggleList
  /// New checkboxes unchecked; lines that all have one are checked, then unchecked.
  case toggleCheckbox
  /// New checkboxes checked, unchecked when they all are.
  case toggleCheckedCheckbox
  /// Backticks in a line, a fenced block over several lines; off again inside either.
  case toggleCode
}

/// The toggles a host's quick actions bar offers, with what its buttons and menu items show. Each works on every
/// selected line and is one undoable edit (`MarkdownEditorCommands.apply(_:)`).
public enum MarkdownQuickAction: String, CaseIterable, Identifiable, Sendable {
  case list, checkbox, checkedCheckbox, code, note, numberedList

  public var id: String { rawValue }

  public var format: MarkdownFormat {
    switch self {
    case .list: .toggleList
    case .checkbox: .toggleCheckbox
    case .checkedCheckbox: .toggleCheckedCheckbox
    case .code: .toggleCode
    case .note: .quote
    case .numberedList: .numberedList
    }
  }

  public var title: String {
    switch self {
    case .list: "Toggle List"
    case .checkbox: "Toggle Checkbox"
    case .checkedCheckbox: "Toggle Checked Checkbox"
    case .code: "Toggle Code"
    case .note: "Toggle Note"
    case .numberedList: "Toggle Numbered List"
    }
  }

  public var systemImage: String {
    switch self {
    case .list: "list.bullet"
    case .checkbox: "square"
    case .checkedCheckbox: "checkmark.square"
    case .code: "chevron.left.forwardslash.chevron.right"
    case .note: "text.quote"
    case .numberedList: "list.number"
    }
  }

  /// The shortcut as a menu shows it.
  public var shortcut: String {
    switch self {
    case .list: "⌘-"
    case .checkbox: "⌘="
    case .checkedCheckbox: "⇧⌘="
    case .code: "⌘`"
    case .note: "⌘."
    case .numberedList: "⌘1"
    }
  }
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
    case .numberedList: return toggleListLines(ns, selection, numbered: true)
    case .checklist: return prefixLines(ns, selection, kind: .checklist)
    case .quote: return toggleQuote(ns, selection)
    case .codeBlock: return codeBlock(ns, selection)
    case .table: return table(ns, selection)
    case .toggleList: return toggleListLines(ns, selection, numbered: false)
    case .toggleCheckbox: return toggleCheckbox(ns, selection, createsChecked: false)
    case .toggleCheckedCheckbox: return toggleCheckbox(ns, selection, createsChecked: true)
    case .toggleCode: return toggleCode(ns, selection)
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

  // MARK: - Toggles

  /// A line split around its list marker: what stays before it (indentation and quote markers), the marker, the text.
  private struct ListLine {
    enum Kind { case bullet, numbered, unchecked, checked }
    var lead: String
    var marker: String
    var kind: Kind?
    var text: String

    private static let pattern = try! NSRegularExpression(
      pattern: #"^([ \t]*(?:>[ \t]?[ \t]*)*)([-*+][ \t]+\[[ xX]\][ \t]+|[-*+][ \t]+|\d+[.)][ \t]+)?"#)

    init(_ line: String) {
      let ns = line as NSString
      let match = Self.pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))!
      lead = ns.substring(with: match.range(at: 1))
      let range = match.range(at: 2)
      marker = range.location == NSNotFound ? "" : ns.substring(with: range)
      text = ns.substring(from: NSMaxRange(match.range))
      if marker.contains("[ ]") {
        kind = .unchecked
      } else if marker.contains("[") {
        kind = .checked
      } else if marker.first?.isNumber == true {
        kind = .numbered
      } else if !marker.isEmpty {
        kind = .bullet
      }
    }

    var line: String { lead + marker + text }
    /// Where the line's text starts.
    var textStart: Int { (lead as NSString).length + (marker as NSString).length }
  }

  /// Rewrites the selected lines (`rewrite` gets those it should change: all but blank ones, unless `includesBlank` or
  /// the only line) as one edit. On one line the caret or selection stays on the same text; several stay selected.
  private static func rewriteLines(
    _ ns: NSString, _ selection: NSRange, includesBlank: Bool = false, _ rewrite: ([ListLine]) -> [ListLine]
  ) -> MarkdownEdit {
    let block = ns.lineRange(for: selection)
    var lines = ns.substring(with: block).components(separatedBy: "\n")
    let endsWithNewline = lines.count > 1 && lines.last == ""
    if endsWithNewline { lines.removeLast() }
    let single = lines.count == 1
    let targets = lines.indices.filter {
      single || includesBlank || !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
    }
    let rewritten = rewrite(targets.map { ListLine(lines[$0]) })
    for (index, line) in zip(targets, rewritten) { lines[index] = line.line }
    let replacement = lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
    guard single, let old = targets.first.map({ _ in ListLine(ns.substring(with: block).replacingOccurrences(of: "\n", with: "")) }),
      let new = rewritten.first
    else {
      let length = (replacement as NSString).length - (endsWithNewline ? 1 : 0)
      return MarkdownEdit(range: block, replacement: replacement, selection: NSRange(location: block.location, length: length))
    }
    func moved(_ location: Int) -> Int {
      let column = location - block.location
      let delta = new.textStart - old.textStart
      return block.location + (column <= old.textStart ? new.textStart : column + delta)
    }
    let start = moved(selection.location)
    let end = selection.length == 0 ? start : max(start, moved(NSMaxRange(selection)))
    return MarkdownEdit(range: block, replacement: replacement, selection: NSRange(location: start, length: end - start))
  }

  /// A bulleted or numbered list of the lines; off when they all are that list (checkboxes count as bullets, so they go
  /// too). Lines already in a bulleted list keep their marker and checkbox while the others join them.
  private static func toggleListLines(_ ns: NSString, _ selection: NSRange, numbered: Bool) -> MarkdownEdit {
    rewriteLines(ns, selection) { lines in
      let isOn: (ListLine) -> Bool = { line in
        numbered ? line.kind == .numbered : line.kind != nil && line.kind != .numbered
      }
      let removes = !lines.isEmpty && lines.allSatisfy(isOn)
      return lines.enumerated().map { index, line in
        var line = line
        if removes {
          line.marker = ""
        } else if numbered {
          line.marker = "\(index + 1). "
        } else if !isOn(line) {
          line.marker = "- "
        }
        return line
      }
    }
  }

  /// Lines without a checkbox get one. Once they all have one: any unchecked (or `createsChecked` with any unchecked)
  /// makes them all checked, all checked makes them unchecked.
  private static func toggleCheckbox(_ ns: NSString, _ selection: NSRange, createsChecked: Bool) -> MarkdownEdit {
    rewriteLines(ns, selection) { lines in
      let allBoxes = lines.allSatisfy { $0.kind == .checked || $0.kind == .unchecked }
      let allChecked = lines.allSatisfy { $0.kind == .checked }
      return lines.map { line in
        var line = line
        let isBox = line.kind == .checked || line.kind == .unchecked
        if createsChecked || allBoxes {
          let box = allChecked ? "[ ]" : "[x]"
          line.marker =
            isBox
            ? line.marker.replacingOccurrences(of: #"\[[ xX]\]"#, with: box, options: .regularExpression)
            : "- \(box) "
        } else if !isBox {
          line.marker = "- [ ] "
        }
        return line
      }
    }
  }

  /// `> ` before every selected line (a list stays a list inside the quote), blank lines too so the quote stays whole;
  /// off when every line has one.
  private static func toggleQuote(_ ns: NSString, _ selection: NSRange) -> MarkdownEdit {
    rewriteLines(ns, selection, includesBlank: true) { lines in
      let hasQuote: (ListLine) -> Bool = { $0.lead.contains(">") }
      let removes = !lines.isEmpty && lines.allSatisfy(hasQuote)
      return lines.map { line in
        var line = line
        let indent = String(line.lead.prefix { $0 == " " || $0 == "\t" })
        if removes {
          // One level: "> > x" keeps its inner quote.
          let rest = line.lead.dropFirst(indent.count).dropFirst()
          line.lead = indent + (rest.first == " " || rest.first == "\t" ? rest.dropFirst() : rest)
        } else if !hasQuote(line) {
          line.lead = indent + "> " + line.lead.dropFirst(indent.count)
        }
        return line
      }
    }
  }

  /// Backticks within a line, a fence around several; inside a fenced block or a code span it comes off instead.
  private static func toggleCode(_ ns: NSString, _ selection: NSRange) -> MarkdownEdit {
    if let fence = enclosingFence(ns, selection) { return removeFence(ns, fence, selection) }
    let block = ns.lineRange(for: selection)
    var body = ns.substring(with: block)
    let endsWithNewline = body.hasSuffix("\n")
    if endsWithNewline { body.removeLast() }
    guard body.contains("\n") else {
      return codeSpan(around: selection, in: ns, line: block) ?? wrap(ns, selection, marker: "`")
    }
    let fenced = "```\n" + body + "\n```" + (endsWithNewline ? "\n" : "")
    return MarkdownEdit(
      range: block, replacement: fenced,
      selection: NSRange(location: block.location + 4, length: (body as NSString).length))
  }

  /// The fence lines around the selection (it may include them).
  private static func enclosingFence(_ ns: NSString, _ selection: NSRange) -> (open: NSRange, close: NSRange)? {
    var open: NSRange?
    var marker = ""
    var location = 0
    while location < ns.length {
      let line = ns.lineRange(for: NSRange(location: location, length: 0))
      let content = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
      if content.hasPrefix("```") || content.hasPrefix("~~~") {
        if let start = open {
          if content.hasPrefix(marker) {
            if selection.location >= start.location, NSMaxRange(selection) <= NSMaxRange(line) { return (start, line) }
            open = nil
          }
        } else {
          open = line
          marker = String(content.prefix(3))
        }
      }
      location = NSMaxRange(line)
    }
    return nil
  }

  private static func removeFence(_ ns: NSString, _ fence: (open: NSRange, close: NSRange), _ selection: NSRange) -> MarkdownEdit {
    let whole = NSRange(location: fence.open.location, length: NSMaxRange(fence.close) - fence.open.location)
    var body = ns.substring(with: NSRange(location: NSMaxRange(fence.open), length: fence.close.location - NSMaxRange(fence.open)))
    let closeEndsLine = ns.substring(with: fence.close).hasSuffix("\n")
    if !closeEndsLine, body.hasSuffix("\n") { body.removeLast() }
    if selection.length == 0 {
      let column = max(0, selection.location - NSMaxRange(fence.open))
      let location = whole.location + min(column, (body as NSString).length)
      return MarkdownEdit(range: whole, replacement: body, selection: NSRange(location: location, length: 0))
    }
    let length = (body as NSString).length - (body.hasSuffix("\n") ? 1 : 0)
    return MarkdownEdit(range: whole, replacement: body, selection: NSRange(location: whole.location, length: max(0, length)))
  }

  /// Takes the backticks off the code span on the line that holds the selection.
  private static func codeSpan(around selection: NSRange, in ns: NSString, line: NSRange) -> MarkdownEdit? {
    var ticks: [Int] = []
    for index in line.location..<NSMaxRange(line) where ns.character(at: index) == 96 { ticks.append(index) }
    var pair = 0
    while pair + 1 < ticks.count {
      let (open, close) = (ticks[pair], ticks[pair + 1])
      if selection.location > open, NSMaxRange(selection) <= close {
        let inner = NSRange(location: open + 1, length: close - open - 1)
        return MarkdownEdit(
          range: NSRange(location: open, length: close - open + 1), replacement: ns.substring(with: inner),
          selection: NSRange(location: selection.location - 1, length: selection.length))
      }
      pair += 2
    }
    return nil
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

  /// Puts the caret in the editor (a new note that reuses the shown note's file, so its editor doesn't appear anew).
  public func focus() {
    textView?.takeFocus()
  }
}
