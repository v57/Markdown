import Foundation

/// Turns the raw destinations written in a document (`![](assets/a.png)`, `[x](../b.md)`,
/// `<img src="/logo.png">`) into absolute URLs. The parser stores the RESOLVED URL on
/// `.markdownImage` / `.link`, so the editor and its host never see a relative path.
///
/// A note on disk resolves against its own folder; a GitHub README resolves images to
/// raw.githubusercontent.com and links to github.com — that policy belongs to the host,
/// which passes its own closures.
public struct MarkdownURLResolver: Sendable {
  /// The document's own URL. A same-document link (`#install`) resolves to this URL with
  /// that fragment, which is how the editor recognizes in-page anchors.
  public var documentURL: URL?
  public var resolveImage: @Sendable (String) -> URL?
  public var resolveLink: @Sendable (String) -> URL?

  public init(
    documentURL: URL?, resolveImage: @escaping @Sendable (String) -> URL?,
    resolveLink: @escaping @Sendable (String) -> URL?
  ) {
    self.documentURL = documentURL
    self.resolveImage = resolveImage
    self.resolveLink = resolveLink
  }

  /// Absolute destinations as-is; relative ones against the directory of `documentURL`
  /// (nil: relative destinations do not resolve, except `#anchor` links).
  ///
  /// `root` is what a root-relative path (`/docs/a.png`) means — a repository's top
  /// folder, the way GitHub resolves it. Without one, `/` is the host's (or for a file,
  /// the disk's) root.
  public static func relative(to documentURL: URL?, root: URL? = nil) -> MarkdownURLResolver {
    MarkdownURLResolver(
      documentURL: documentURL,
      resolveImage: { resolveRelative($0, against: documentURL, root: root) },
      resolveLink: { resolveRelative($0, against: documentURL, root: root) })
  }

  /// Absolute destinations only — the parser's behavior without a document location.
  public static let absoluteOnly = relative(to: nil)

  /// `raw` resolved against `documentURL`: absolute URLs (with a scheme) pass through,
  /// `#fragment` targets the document itself, anything else is a path relative to the
  /// document's directory. Spaces and other characters a URL cannot hold are
  /// percent-encoded first (`![](my image.png)` is common in notes).
  public static func resolveRelative(_ raw: String, against documentURL: URL?, root: URL? = nil)
    -> URL?
  {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let absolute = absoluteURL(trimmed) { return absolute }
    // Root-relative ("/x", not protocol-relative "//host/x"): against `root`.
    if let root, trimmed.hasPrefix("/"), !trimmed.hasPrefix("//"),
      let encoded = encodedReference(String(trimmed.drop(while: { $0 == "/" })))
    {
      let base = root.hasDirectoryPath ? root : root.appendingPathComponent("", isDirectory: true)
      return URL(string: encoded, relativeTo: base)?.absoluteURL
    }
    guard let documentURL else { return nil }
    if trimmed.hasPrefix("#") {
      var components = URLComponents(url: documentURL, resolvingAgainstBaseURL: true)
      components?.fragment = String(trimmed.dropFirst())
      return components?.url
    }
    guard let encoded = encodedReference(trimmed) else { return nil }
    return URL(string: encoded, relativeTo: documentURL)?.absoluteURL
  }

  /// `raw` as a URL when it carries a scheme (`https:`, `mailto:`, `file:`).
  public static func absoluteURL(_ raw: String) -> URL? {
    // RFC 3986 scheme: a letter, then letters/digits/`+`/`-`/`.`. Two characters at
    // least, so a Windows drive letter ("C:") is not a scheme.
    guard let colon = raw.firstIndex(of: ":"), let first = raw.first, first.isLetter,
      raw[..<colon].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }),
      raw.distance(from: raw.startIndex, to: colon) > 1
    else { return nil }
    return URL(string: raw) ?? encodedReference(raw).flatMap { URL(string: $0) }
  }

  /// A relative reference safe for `URL(string:)`: characters a URL cannot hold are
  /// percent-encoded, existing escapes are kept.
  static func encodedReference(_ raw: String) -> String? {
    if URL(string: raw) != nil { return raw }
    var allowed = CharacterSet.urlPathAllowed
    allowed.insert(charactersIn: "%?#&=")
    return raw.addingPercentEncoding(withAllowedCharacters: allowed)
  }
}

/// Everything the layout manager needs to size and place one image: the value of
/// `.markdownImageSpec` over the image's source span. A class (identity equality), so
/// two adjacent images never merge into one attribute run.
public final class MarkdownImageSpec: NSObject, @unchecked Sendable {
  public enum VerticalAlignment: Sendable { case baseline, middle }

  /// The resolved image URL.
  public let url: URL
  /// The image's whole source span (`![alt](src)` or the `<img …>` tag).
  public let range: NSRange
  /// Requested width/height in points (HTML `width=` / `height=`); nil: natural.
  public let width: CGFloat?
  public let height: CGFloat?
  /// Requested width as a fraction of the available width (`width="50%"`).
  public let widthFraction: CGFloat?
  public let alt: String
  public let verticalAlignment: VerticalAlignment

  public init(
    url: URL, range: NSRange, width: CGFloat? = nil, height: CGFloat? = nil,
    widthFraction: CGFloat? = nil, alt: String = "", verticalAlignment: VerticalAlignment = .baseline
  ) {
    self.url = url
    self.range = range
    self.width = width
    self.height = height
    self.widthFraction = widthFraction
    self.alt = alt
    self.verticalAlignment = verticalAlignment
  }

  /// The drawn size for an image whose natural size is `natural`, HTML-style: both
  /// requested dimensions win; one requested dimension keeps the natural aspect ratio;
  /// nothing requested is the natural size. Never wider than `maxWidth` (scaled down
  /// proportionally, like GitHub's `max-width: 100%`).
  public func displaySize(natural: CGSize, maxWidth: CGFloat) -> CGSize {
    let aspect = natural.width > 0 && natural.height > 0 ? natural.height / natural.width : 1
    var w: CGFloat
    var h: CGFloat
    let requestedWidth = widthFraction.map { $0 * maxWidth } ?? width
    switch (requestedWidth, height) {
    case let (w0?, h0?):
      w = w0
      h = h0
    case let (w0?, nil):
      w = w0
      h = w0 * aspect
    case let (nil, h0?):
      h = h0
      w = aspect > 0 ? h0 / aspect : h0
    case (nil, nil):
      w = natural.width
      h = natural.height
    }
    if maxWidth > 0, w > maxWidth {
      h *= maxWidth / w
      w = maxWidth
    }
    return CGSize(width: max(1, w.rounded()), height: max(1, h.rounded()))
  }
}
