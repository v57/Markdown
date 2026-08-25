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
  /// Marks fenced-code content ranges; the layout manager draws the continuous
  /// full-width background block (per-line backgrounds would show seams).
  public static let markdownCodeBlock = NSAttributedString.Key("MarkdownCodeBlock")
  /// Marks horizontal-rule ranges; the layout manager draws a full-width line
  /// instead of the literal dashes.
  public static let markdownRule = NSAttributedString.Key("MarkdownRule")
  /// Marks list markers ("- ", "* ", "1. ") that are ALWAYS shown (never hidden or
  /// collapsed), even on inactive lines — Obsidian-style persistent bullets.
  public static let markdownListMarker = NSAttributedString.Key("MarkdownListMarker")
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
}
