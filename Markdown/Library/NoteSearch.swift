import Foundation

/// A markdown file matching a search: by name, by content, or both.
struct SearchResult: Identifiable, Hashable {
  let url: URL
  /// Where it lives, for the row's second line ("Notes › Projects").
  let location: String
  /// The first matching line, when the content matched.
  let snippet: String?
  let nameMatches: Bool
  var id: URL { url }
  var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Full-text search over the markdown files in the sidebar's folders.
///
/// Every word of the query must appear in the file's name or its text (case- and
/// diacritic-insensitive). Name matches come first. Runs off the main thread and stops
/// early when its task is cancelled (the query changed).
enum NoteSearch {
  /// Folders never worth searching (dependencies, build output).
  nonisolated private static let skippedFolders: Set<String> = [
    "node_modules", "build", "DerivedData", "Pods", ".build",
  ]
  nonisolated private static let maxFileSize = 2_000_000

  nonisolated static func search(
    _ query: String, in roots: [(name: String, url: URL)], limit: Int = 200
  ) -> [SearchResult] {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return [] }
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    var byName: [SearchResult] = []
    var byText: [SearchResult] = []
    var seen = Set<String>()
    for root in roots {
      let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
      guard
        let enumerator = FileManager.default.enumerator(
          at: root.url, includingPropertiesForKeys: keys,
          options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else { continue }
      for case let url as URL in enumerator {
        if Task.isCancelled || byName.count + byText.count >= limit { break }
        let values = try? url.resourceValues(forKeys: Set(keys))
        if values?.isDirectory == true {
          if skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
          continue
        }
        guard FolderLibrary.isMarkdown(url), seen.insert(url.standardizedFileURL.path).inserted
        else { continue }
        let name = url.deletingPathExtension().lastPathComponent
        let text: String? =
          (values?.fileSize ?? 0) <= maxFileSize ? try? NoteFiles.text(at: url) : nil
        // Every term somewhere: in the name or in the text.
        let all = terms.allSatisfy {
          name.range(of: $0, options: options) != nil
            || text?.range(of: $0, options: options) != nil
        }
        guard all else { continue }
        let nameMatches = terms.contains { name.range(of: $0, options: options) != nil }
        let result = SearchResult(
          url: FolderLibrary.canonical(url), location: location(of: url, in: root),
          snippet: text.flatMap { snippet(in: $0, terms: terms, options: options) },
          nameMatches: nameMatches)
        if nameMatches { byName.append(result) } else { byText.append(result) }
      }
    }
    return byName + byText
  }

  /// "Notes › Projects" for a file in Notes/Projects.
  nonisolated private static func location(of url: URL, in root: (name: String, url: URL))
    -> String
  {
    let folder = url.deletingLastPathComponent().standardizedFileURL.path
    let base = root.url.standardizedFileURL.path
    let inner = folder.count > base.count ? String(folder.dropFirst(base.count + 1)) : ""
    return ([root.name] + inner.split(separator: "/").map(String.init)).joined(separator: " › ")
  }

  /// The first line holding a term, trimmed to about 100 characters around it.
  nonisolated private static func snippet(
    in text: String, terms: [String], options: String.CompareOptions
  ) -> String? {
    for term in terms {
      guard let range = text.range(of: term, options: options) else { continue }
      let line = text.lineRange(for: range)
      let lineText = text[line].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !lineText.isEmpty else { continue }
      guard lineText.count > 100,
        let inLine = lineText.range(of: term, options: options)
      else { return lineText }
      let start =
        lineText.index(inLine.lowerBound, offsetBy: -40, limitedBy: lineText.startIndex)
        ?? lineText.startIndex
      let end =
        lineText.index(start, offsetBy: 100, limitedBy: lineText.endIndex) ?? lineText.endIndex
      return (start > lineText.startIndex ? "…" : "") + lineText[start..<end]
        + (end < lineText.endIndex ? "…" : "")
    }
    return nil
  }
}
