// TextKit (AppKit, UIKit): when the editors re-parse their text.
#if canImport(AppKit) || canImport(UIKit)
import Foundation

/// Decides when an editor's text is parsed again after an edit. A document that parses quickly is re-styled in the
/// same event as the edit (no unstyled frame). A long one is parsed on a background queue instead, so a keystroke
/// never waits for the whole document: the result is applied once it arrives, unless the text changed meanwhile (the
/// next parse, already queued, then brings the styles up to date).
@MainActor
final class MarkdownRestyler {
  /// Parses longer than this move to the background (the keystroke's frame budget, with room for layout).
  var backgroundThreshold: TimeInterval = 0.012
  /// Shorter documents are always re-styled in the edit's own event, however long one parse took (the first one, with
  /// cold caches, can be slow even for a short note).
  var backgroundMinimumLength = 8_000

  private static let queue = DispatchQueue(label: "dev.v57.MarkdownKit.parse", qos: .userInitiated)

  /// How long the last parse took (-1 before the first).
  private(set) var lastParseDuration: TimeInterval = -1
  /// Counts requests: a background result is applied only when no request came after it.
  private var generation = 0
  private var isParsing = false
  private var parseAgain = false

  /// Whether a background parse is queued or running.
  var isPending: Bool { isParsing }

  /// Whether the next edit of a document `length` UTF-16 units long is better parsed in the background.
  func prefersBackground(length: Int) -> Bool {
    length >= backgroundMinimumLength && lastParseDuration > backgroundThreshold
  }

  /// Parses now (an open, a setting changed, a quick document), dropping any background result still on its way.
  func parseNow(_ parse: () -> ParsedMarkdown) -> ParsedMarkdown {
    generation += 1
    parseAgain = false
    request = nil
    let start = DispatchTime.now().uptimeNanoseconds
    let parsed = parse()
    lastParseDuration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    return parsed
  }

  /// Parses in the background. `makeParse` runs now, on the main actor, and returns the work for the queue (it captures
  /// the text and settings of this moment); `apply` gets the result on the main actor, only while nothing newer was
  /// asked for. While a parse runs, further requests collapse into one more parse after it, of the latest text.
  func parseInBackground(
    _ makeParse: @escaping () -> @Sendable () -> ParsedMarkdown,
    apply: @escaping (ParsedMarkdown) -> Void
  ) {
    generation += 1
    request = (makeParse, apply)
    guard !isParsing else {
      parseAgain = true
      return
    }
    isParsing = true
    let requested = generation
    let work = makeParse()
    Self.queue.async { [weak self] in
      let start = DispatchTime.now().uptimeNanoseconds
      let result = ParsedBox(work())
      let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.finish(result, requested: requested, duration: duration) }
      }
    }
  }

  /// The latest background request: the next parse's work and where its result goes.
  private var request: (makeParse: () -> @Sendable () -> ParsedMarkdown, apply: (ParsedMarkdown) -> Void)?

  private func finish(_ result: ParsedBox, requested: Int, duration: TimeInterval) {
    isParsing = false
    lastParseDuration = duration
    guard let request else { return }
    if parseAgain {
      parseAgain = false
      parseInBackground(request.makeParse, apply: request.apply)
    } else if requested == generation {
      self.request = nil
      request.apply(result.parsed)
    }
  }
}

extension MarkdownRestyler {
  /// What belongs to syntax or to one span and must not spread to typed text.
  private static let spanKeys: [NSAttributedString.Key] = [
    .markdownSyntax, .markdownLineCommand, .markdownCommandSpan, .markdownCheckbox, .markdownBullet,
    .markdownListMarker, .markdownImage, .markdownImageSpec, .markdownGlyphSubstitute, .markdownRule,
    .markdownCollapsibleLine, .link, .kern, .attachment,
  ]

  /// The attributes text typed at `location` takes while its parse runs in the background: the preceding character's
  /// (a heading's font, a code block's colors) without what belongs to syntax or to one span, so the new text looks
  /// like the rest of its line until the styles arrive. `body` at the start of a line.
  static func typingAttributes(
    continuing storage: NSAttributedString, at location: Int, body: [NSAttributedString.Key: Any]
  ) -> [NSAttributedString.Key: Any] {
    let before = location - 1
    guard before >= 0, before < storage.length,
      CFStringGetCharacterAtIndex(CFAttributedStringGetString(storage as CFAttributedString), before) != 0x0A
    else { return body }
    var attributes = storage.attributes(at: before, effectiveRange: nil)
    if attributes[.markdownSyntax] != nil { attributes[.foregroundColor] = body[.foregroundColor] }
    for key in spanKeys { attributes[key] = nil }
    return attributes
  }
}

/// Carries a parse result from the parsing queue to the main actor (it is handed over, never shared).
private final class ParsedBox: @unchecked Sendable {
  let parsed: ParsedMarkdown
  init(_ parsed: ParsedMarkdown) { self.parsed = parsed }
}
#endif
