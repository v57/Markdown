import Foundation
import Markdown

/// Markdown → styled attributed string, built on swift-markdown (CommonMark + GFM:
/// tables, task lists, strikethrough). Replaces the hand-rolled line dispatcher,
/// which could loop forever on inputs like a bare "- [ ]" (the old task-list guard
/// matched while the full pattern did not, so `i` never advanced).
///
/// Architecture: `Document(parsing:)` produces the AST; a styler walks it and emits
/// the SOURCE TEXT VERBATIM (never synthesized characters), so the invariant
/// `parsed.attributed.string == markdown` holds structurally. Each source line gets
/// a role from the AST (heading/quote/list/fence/table/rule/code/html/paragraph);
/// per-line marker ranges come from the same total regexes as before (every line
/// classifies — no loops); inline styling ranges come from the AST's source ranges
/// (cmark byte columns converted to UTF-16 offsets).
public enum MarkdownParser {}

// MARK: - Anchors

extension MarkdownParser {
  /// GitHub's heading anchor for `text`: lowercased; punctuation dropped except `-` and
  /// `_`; spaces become `-` ("Get started!" → "get-started").
  public static func githubSlug(_ text: String) -> String {
    var out = ""
    for scalar in text.lowercased().unicodeScalars {
      if scalar == " " {
        out.append("-")
      } else if scalar == "-" || scalar == "_" || CharacterSet.alphanumerics.contains(scalar) {
        out.unicodeScalars.append(scalar)
      }
    }
    return out
  }

  /// Every in-page anchor of `markdown` → the UTF-16 offset of its line: headings by
  /// GitHub slug (repeats get `-1`, `-2`, … like GitHub), plus HTML `id=`/`name=`
  /// attributes. Keys are lowercased.
  public static func anchors(in markdown: String) -> [String: Int] {
    let doc = Document(parsing: markdown, options: .disableSmartOpts)
    var lineStarts: [Int] = [0]
    let ns = markdown as NSString
    for i in 0..<ns.length where ns.character(at: i) == 0x0A { lineStarts.append(i + 1) }
    var out: [String: Int] = [:]
    var seen: [String: Int] = [:]
    func visit(_ node: Markup) {
      if let heading = node as? Heading, let range = heading.range {
        let base = githubSlug(heading.plainText)
        let count = seen[base, default: 0]
        seen[base] = count + 1
        let slug = count == 0 ? base : "\(base)-\(count)"
        let line = range.lowerBound.line - 1
        if out[slug] == nil, line < lineStarts.count { out[slug] = lineStarts[line] }
      }
      for child in node.children { visit(child) }
    }
    visit(doc)
    for tag in MarkdownHTML.tags(in: markdown) where !tag.isClosing {
      for key in ["id", "name"] {
        if let value = tag.attributes[key]?.lowercased(), !value.isEmpty, out[value] == nil {
          out[value] = tag.range.location
        }
      }
    }
    return out
  }

  /// True when `url` points into the document at `documentURL` (same URL, ignoring the
  /// fragment) — an in-page anchor link.
  public static func isSameDocument(_ url: URL, _ documentURL: URL?) -> Bool {
    guard let documentURL else { return false }
    func stripped(_ u: URL) -> String {
      var c = URLComponents(url: u, resolvingAgainstBaseURL: true)
      c?.fragment = nil
      return (c?.url ?? u).absoluteString
    }
    return stripped(url) == stripped(documentURL)
  }
}

extension MarkdownParser {
  // MARK: - Regex helper

  public static func match(_ s: String, pattern: String) -> [String]? {
    guard let re = regex(pattern) else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
      return nil
    }
    return (0..<m.numberOfRanges).map {
      m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0))
    }
  }

  /// Compiled patterns by (pattern, options). Compiling an NSRegularExpression costs far
  /// more than matching one line, and the line planner matches every line of the document
  /// on every keystroke — uncached compilation dominated large-document parses. Locked:
  /// tests parse on concurrent threads.
  private static nonisolated(unsafe) var regexCache: [String: NSRegularExpression] = [:]
  private static let regexCacheLock = NSLock()

  static func regex(
    _ pattern: String, options: NSRegularExpression.Options = []
  ) -> NSRegularExpression? {
    let key = "\(options.rawValue):\(pattern)"
    regexCacheLock.lock()
    defer { regexCacheLock.unlock() }
    if let cached = regexCache[key] { return cached }
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
    regexCache[key] = re
    return re
  }
}
