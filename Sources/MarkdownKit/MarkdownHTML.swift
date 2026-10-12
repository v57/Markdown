import Foundation

/// The small slice of HTML that GitHub READMEs actually use, tokenized from the source
/// text so the parser can hide the markup and render what it means: `<img>` as images,
/// `<a href>` as links, `align="center"` as centered lines, `<picture>` as the source
/// matching the appearance, `<hN>`/`<b>`/`<kbd>` as styled text, entities as characters.
/// Nothing here rewrites the text — every token is a range of the source.
public enum MarkdownHTML {
  public struct Tag: Equatable {
    /// The whole tag (`<img src="a.png" width="40">`) or comment, as a UTF-16 range.
    public var range: NSRange
    /// Lowercased element name; empty for a comment.
    public var name: String
    public var isClosing: Bool
    public var isSelfClosing: Bool
    /// Attribute names lowercased; values unquoted (a bare attribute maps to "").
    public var attributes: [String: String]
    public var isComment: Bool { name.isEmpty }
  }

  /// Elements whose content is NOT closed by a matching tag (HTML void elements).
  public static let voidElements: Set<String> = [
    "img", "br", "hr", "source", "input", "meta", "link", "wbr", "area", "col", "embed",
  ]

  /// Every tag and comment in `text`, in order, with ranges offset by `base`.
  /// Comments are matched first, so a tag inside a comment is not reported.
  public static func tags(in text: String, base: Int = 0) -> [Tag] {
    let ns = text as NSString
    guard ns.range(of: "<").location != NSNotFound,
      let re = MarkdownParser.regex(
        "<!--[\\s\\S]*?-->|<(/?)([A-Za-z][A-Za-z0-9-]*)((?:\\s+[^\\s\"'>/=]+(?:\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s\"'=<>`]+))?)*)\\s*(/?)>"
      )
    else { return [] }
    var out: [Tag] = []
    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      let range = NSRange(location: base + m.range.location, length: m.range.length)
      if m.range(at: 2).location == NSNotFound {
        out.append(
          Tag(range: range, name: "", isClosing: false, isSelfClosing: true, attributes: [:]))
        continue
      }
      let name = ns.substring(with: m.range(at: 2)).lowercased()
      let closing = m.range(at: 1).length > 0
      let attrText = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3))
      out.append(
        Tag(
          range: range, name: name, isClosing: closing,
          isSelfClosing: m.range(at: 4).length > 0 || voidElements.contains(name),
          attributes: attributes(in: attrText)))
    }
    return out
  }

  /// Parses `key="value" key2='v' bare key3=v` into a dictionary (lowercased keys).
  public static func attributes(in text: String) -> [String: String] {
    guard
      let re = MarkdownParser.regex(
        "([^\\s\"'>/=]+)(?:\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'=<>`]+)))?")
    else { return [:] }
    let ns = text as NSString
    var out: [String: String] = [:]
    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      let key = ns.substring(with: m.range(at: 1)).lowercased()
      var value = ""
      for g in 2...4 where m.range(at: g).location != NSNotFound {
        value = ns.substring(with: m.range(at: g))
        break
      }
      out[key] = decodeEntities(value)
    }
    return out
  }

  /// A dimension attribute: `"400"`/`"400px"` → (400, nil); `"50%"` → (nil, 0.5).
  public static func dimension(_ value: String?) -> (points: CGFloat?, fraction: CGFloat?) {
    guard var v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return (nil, nil) }
    if v.hasSuffix("%") {
      v.removeLast()
      return (nil, Double(v).map { CGFloat($0 / 100) })
    }
    if v.hasSuffix("px") { v.removeLast(2) }
    guard let d = Double(v), d > 0 else { return (nil, nil) }
    return (CGFloat(d), nil)
  }

  // MARK: - Entities

  /// Named entities READMEs use, by name → UTF-16 code unit (BMP only, so each one can
  /// stand in for the entity's first character as a single glyph).
  public static let namedEntities: [String: UInt16] = [
    "nbsp": 0x00A0, "amp": 0x26, "lt": 0x3C, "gt": 0x3E, "quot": 0x22, "apos": 0x27,
    "copy": 0x00A9, "reg": 0x00AE, "trade": 0x2122, "hellip": 0x2026, "mdash": 0x2014,
    "ndash": 0x2013, "middot": 0x00B7, "bull": 0x2022, "larr": 0x2190, "rarr": 0x2192,
    "uarr": 0x2191, "darr": 0x2193, "harr": 0x2194, "times": 0x00D7, "divide": 0x00F7,
    "deg": 0x00B0, "plusmn": 0x00B1, "laquo": 0x00AB, "raquo": 0x00BB, "ldquo": 0x201C,
    "rdquo": 0x201D, "lsquo": 0x2018, "rsquo": 0x2019, "ensp": 0x2002, "emsp": 0x2003,
    "thinsp": 0x2009, "sect": 0x00A7, "para": 0x00B6, "euro": 0x20AC, "pound": 0x00A3,
    "yen": 0x00A5, "cent": 0x00A2, "check": 0x2713, "star": 0x2606, "hearts": 0x2665,
    "zwj": 0x200D, "zwnj": 0x200C, "shy": 0x00AD, "iexcl": 0x00A1, "iquest": 0x00BF,
  ]

  public struct Entity: Equatable {
    public var range: NSRange
    public var codeUnit: UInt16
  }

  /// Every decodable entity (`&name;`, `&#123;`, `&#x1F;`) in `text`, offset by `base`.
  /// Numeric entities outside the BMP are skipped (no single code unit to draw).
  public static func entities(in text: String, base: Int = 0) -> [Entity] {
    let ns = text as NSString
    guard ns.range(of: "&").location != NSNotFound,
      let re = MarkdownParser.regex("&(?:#[xX]([0-9A-Fa-f]{1,6})|#([0-9]{1,7})|([A-Za-z][A-Za-z0-9]{1,31}));")
    else { return [] }
    var out: [Entity] = []
    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      var unit: UInt32?
      if m.range(at: 1).location != NSNotFound {
        unit = UInt32(ns.substring(with: m.range(at: 1)), radix: 16)
      } else if m.range(at: 2).location != NSNotFound {
        unit = UInt32(ns.substring(with: m.range(at: 2)))
      } else {
        unit = namedEntities[ns.substring(with: m.range(at: 3))].map(UInt32.init)
      }
      guard let u = unit, u > 0, u <= 0xFFFF, !(0xD800...0xDFFF).contains(u) else { continue }
      out.append(
        Entity(
          range: NSRange(location: base + m.range.location, length: m.range.length),
          codeUnit: UInt16(u)))
    }
    return out
  }

  /// `text` with its decodable entities replaced (attribute values, alt text).
  public static func decodeEntities(_ text: String) -> String {
    let found = entities(in: text)
    guard !found.isEmpty else { return text }
    let out = NSMutableString(string: text)
    for e in found.reversed() {
      out.replaceCharacters(in: e.range, with: String(utf16CodeUnits: [e.codeUnit], count: 1))
    }
    return out as String
  }

  // MARK: - <picture>

  /// The `srcset` a `<picture>` should show for the current appearance: the first
  /// `<source>` whose `media` names the matching `prefers-color-scheme` (or has no
  /// media query); nil keeps the `<img>`'s own `src`.
  public static func pictureSource(_ sources: [Tag], isDark: Bool) -> String? {
    for source in sources {
      guard let srcset = source.attributes["srcset"], !srcset.isEmpty else { continue }
      let media = (source.attributes["media"] ?? "").lowercased()
      let matches: Bool
      if media.contains("prefers-color-scheme") {
        matches = media.contains(isDark ? "dark" : "light")
      } else {
        matches = media.isEmpty
      }
      // srcset may list candidates ("a.png 1x, b.png 2x"): take the first URL.
      if matches { return srcset.split(separator: ",").first.map { firstToken(String($0)) } }
    }
    return nil
  }

  private static func firstToken(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? s
  }
}
