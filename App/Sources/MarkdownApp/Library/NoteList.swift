import Foundation

/// What the note list shows: every note in the notes folder, one folder's notes, or the
/// files opened on their own from Finder or Files.
nonisolated enum LibraryItem: Hashable, Sendable {
  case allNotes
  case folder(URL)
  case openedFiles
}

/// A row of the note list, named as Shell names its notes: the first line is the name, the second the subtitle.
struct NoteSummary: Identifiable, Hashable {
  let url: URL
  let modified: Date
  /// The first line, without a heading, bullet or quote marker; the file's name when that line is empty.
  let title: String
  /// The second line, the same way; nil when there is none.
  let subtitle: String?
  var id: URL { url }
}

enum NoteSummaries {
  /// Reads each file's date and opening lines (off the main thread: iCloud and network
  /// volumes can be slow). Newest first.
  nonisolated static func load(_ urls: [URL]) -> [NoteSummary] {
    urls.compactMap { url in
      if Task.isCancelled { return nil }
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
      let text = opening(of: url)
      return NoteSummary(
        url: url, modified: values?.contentModificationDate ?? .distantPast,
        title: title(for: text) ?? url.deletingPathExtension().lastPathComponent, subtitle: subtitle(for: text))
    }
    .sorted { $0.modified > $1.modified }
  }

  /// Every markdown file under `root` (hidden folders and dependency folders skipped).
  nonisolated static func allNotes(in root: URL) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    var urls: [URL] = []
    for case let url as URL in enumerator {
      if Task.isCancelled { break }
      if FolderLibrary.isMarkdown(url) { urls.append(FolderLibrary.canonical(url)) }
    }
    return urls
  }

  /// The file's first few kilobytes ("" when it can't be read).
  nonisolated static func opening(of url: URL) -> String {
    if NoteFiles.isEncrypted(url) {
      // The whole note is one sealed box: it decrypts whole (notes are small).
      guard let full = try? NoteFiles.text(at: url) else { return "" }
      return String(full.prefix(4096))
    }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 4096) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  // Shell's NotesStore derives a note's title and subtitle the same way: the first and second physical lines, each
  // without one leading ATX heading ('#{1,6} '), bullet ('- ', '* ', '+ ') or quote ('> ') marker, the title cut at
  // 60 characters.

  /// The first line, or nil when it is empty.
  nonisolated static func title(for text: String) -> String? {
    let derived = stripMarkdownPrefix(physicalLines(in: text).first ?? "").trimmingCharacters(in: .whitespaces)
    return derived.isEmpty ? nil : String(derived.prefix(60))
  }

  /// The second line, or nil when there is none or it is empty.
  nonisolated static func subtitle(for text: String) -> String? {
    let lines = physicalLines(in: text)
    guard lines.count > 1 else { return nil }
    let derived = stripMarkdownPrefix(lines[1]).trimmingCharacters(in: .whitespaces)
    return derived.isEmpty ? nil : derived
  }

  private nonisolated static func stripMarkdownPrefix(_ line: String) -> String {
    guard !line.isEmpty else { return line }
    if line.first == "#" {
      let hashCount = line.prefix { $0 == "#" }.count
      let spaceIndex = line.index(line.startIndex, offsetBy: hashCount)
      if (1...6).contains(hashCount), spaceIndex < line.endIndex, line[spaceIndex] == " " {
        return String(line[line.index(after: spaceIndex)...])
      }
      return line
    }
    if line.count >= 2 {
      let marker = line[line.startIndex]
      let next = line[line.index(after: line.startIndex)]
      if next == " ", "-*+>".contains(marker) { return String(line.dropFirst(2)) }
    }
    return line
  }

  private nonisolated static func physicalLines(in text: String) -> [String] {
    text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  /// "- [ ] **Ship** the [docs](x)" → "Ship the docs".
  nonisolated static func plain(_ line: String) -> String {
    var text = line
    for pattern in [#"^(>\s*)+"#, #"^([-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)"#] {
      text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    text = text.replacingOccurrences(of: #"[*_`~]|<[^>]+>"#, with: "", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespaces)
  }
}

extension Date {
  /// The note list's date: the time today, "Yesterday", the weekday this week, else
  /// the short date.
  var noteListText: String {
    let calendar = Calendar.current
    if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
    if calendar.isDateInYesterday(self) { return String(localized: "Yesterday") }
    if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
      return formatted(.dateTime.weekday(.wide))
    }
    return formatted(date: .numeric, time: .omitted)
  }
}
