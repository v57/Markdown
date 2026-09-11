import Foundation

extension NSAttributedString.Key {
  /// Marks markdown "command symbol" ranges (hidden on inactive lines, tertiary when active).
  public static let markdownSyntax = NSAttributedString.Key("MarkdownSyntax")
  /// Marks task-list checkbox ranges ("[x]"/"[ ]"); the layout manager draws a checkbox
  /// image instead of the literal characters (keeps the source string verbatim).
  public static let markdownCheckbox = NSAttributedString.Key("MarkdownCheckbox")
  /// Marks inline image ranges ("![alt](url)"); the layout manager draws a cached image
  /// in place of the range once loaded (keeps the source string verbatim).
  public static let markdownImage = NSAttributedString.Key("MarkdownImage")
  /// Marks fenced-code CONTENT ranges; the layout manager draws the continuous
  /// full-width background block (per-line backgrounds would show seams). This
  /// span covers the code-content lines only (NOT the ``` fence lines) — it drives
  /// chrome anchoring, the language label, and what Copy copies.
  public static let markdownCodeBlock = NSAttributedString.Key("MarkdownCodeBlock")
  /// Marks the FULL fenced-code block (content PLUS the ``` open/close fence lines)
  /// for the continuous background FILL only. Value is an NSValue-wrapped NSRange
  /// of the whole block. `.markdownCodeBlock` stays content-only so chrome/Copy are
  /// unaffected; this key lets the background cover the fence lines too.
  public static let markdownCodeBlockFill = NSAttributedString.Key("MarkdownCodeBlockFill")
  /// Marks horizontal-rule ranges; the layout manager draws a full-width line
  /// instead of the literal dashes.
  public static let markdownRule = NSAttributedString.Key("MarkdownRule")
  /// Marks list markers ("- ", "* ", "1. ") that are ALWAYS shown (never hidden or
  /// collapsed), even on inactive lines — Obsidian-style persistent bullets.
  public static let markdownListMarker = NSAttributedString.Key("MarkdownListMarker")
  /// Marks the actual bullet character of a plain UNORDERED list marker ("-", "*",
  /// "+"). The layout manager substitutes its glyph with "•" (U+2022) so a hyphen
  /// renders as a bullet while the source keeps the literal "-". Ordered markers
  /// ("1.") and task list "-" do NOT carry this.
  public static let markdownBullet = NSAttributedString.Key("MarkdownBullet")
  /// Marks BLOCK-level syntax (heading prefix, blockquote '>', code fences, table
  /// pipes, setext underline, rule): shown while the caret is anywhere on the line.
  public static let markdownLineCommand = NSAttributedString.Key("MarkdownLineCommand")
  /// Marks the full span of an inline command ("**bold**", "`code`", "[link](url)").
  /// Value is an NSValue-wrapped NSRange. The command's delimiters are shown while
  /// the caret is inside (or just after) this span.
  public static let markdownCommandSpan = NSAttributedString.Key("MarkdownCommandSpan")
  /// Marks blockquote lines (including their trailing newline); the layout manager
  /// draws a vertical bar at the quote block's left edge instead of relying on the
  /// '>' markers alone (those collapse to zero width on inactive lines).
  public static let markdownBlockquote = NSAttributedString.Key("MarkdownBlockquote")
  /// Marks fenced-code content with its language display name (e.g. "Swift")
  /// when the fence language is recognized; the layout manager draws a language
  /// label for the block. Absent for unknown languages.
  public static let markdownCodeLanguage = NSAttributedString.Key("MarkdownCodeLanguage")
  /// Marks inline-code content (the text between backticks, NOT the backticks);
  /// the layout manager draws a rounded chip behind it instead of the flat
  /// `.backgroundColor` rect (which can't round corners).
  public static let markdownInlineCode = NSAttributedString.Key("MarkdownInlineCode")
  /// Marks a table rendered in GRID mode, over the whole block range (header through
  /// the last body line, newlines included). Value is an `[NSNumber]` of ascending
  /// container-relative x positions — one per vertical grid line — so the layout
  /// manager draws the grid without re-measuring anything.
  public static let markdownTableGrid = NSAttributedString.Key("MarkdownTableGrid")
  /// A table's ordinal among the document's tables (0-based, document order) over the
  /// whole grid block. The editor reads it at the click/caret index to know WHICH
  /// table's grid/source mode to flip.
  public static let markdownTableOrdinal = NSAttributedString.Key("MarkdownTableOrdinal")
  /// Marks a table's header-separator row (the `|---|` line) in grid mode. Its literal
  /// characters are hidden syntax; the layout manager draws a rule across the table
  /// instead. Value is an `NSNumber`: the table's width in points.
  public static let markdownTableRule = NSAttributedString.Key("MarkdownTableRule")
}
