import Foundation

/// What the note list shows: every note in the notes folder, one folder's notes, or the
/// files opened on their own from Finder or Files.
nonisolated enum LibraryItem: Hashable, Sendable {
  case allNotes
  case folder(URL)
  case openedFiles
}

/// A row of the note list: the note's name, when it was last edited, and the start of
/// its text.
struct NoteSummary: Identifiable, Hashable {
  let url: URL
  let modified: Date
  /// The first line of prose, with markdown symbols taken off ("" for an empty note).
  let snippet: String
  var id: URL { url }
  var title: String { url.deletingPathExtension().lastPathComponent }
}

enum NoteSummaries {
  /// Reads each file's date and opening lines (off the main thread: iCloud and network
  /// volumes can be slow). Newest first.
  nonisolated static func load(_ urls: [URL]) -> [NoteSummary] {
    urls.compactMap { url in
      if Task.isCancelled { return nil }
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
      return NoteSummary(
        url: url, modified: values?.contentModificationDate ?? .distantPast,
        snippet: snippet(of: url))
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

  /// The first non-heading line of the file's first few kilobytes, without its block
  /// marker and inline symbols. A note that is only a heading shows that heading.
  nonisolated static func snippet(of url: URL) -> String {
    let text: String
    if NoteFiles.isEncrypted(url) {
      // The whole note is one sealed box: it decrypts whole (notes are small).
      guard let full = try? NoteFiles.text(at: url) else { return "" }
      text = String(full.prefix(4096))
    } else {
      guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
      defer { try? handle.close() }
      guard let data = try? handle.read(upToCount: 4096) else { return "" }
      text = String(decoding: data, as: UTF8.self)
    }
    var heading: String?
    var inFence = false
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("```") || line.hasPrefix("~~~") {
        inFence.toggle()
        continue
      }
      if inFence || line.isEmpty || line.hasPrefix("<!--") || line.allSatisfy({ "-=*_|: ".contains($0) }) {
        continue
      }
      if line.hasPrefix("#") {
        if heading == nil { heading = plain(String(line.drop { $0 == "#" })) }
        continue
      }
      let text = plain(line)
      if !text.isEmpty { return text }
    }
    return heading ?? ""
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

/// The note list's sections: Pinned, then by date edited (Today, Yesterday, Previous 7
/// Days, Previous 30 Days, then by month and year) — as in Notes.
struct NoteGroup: Identifiable {
  let title: String
  let notes: [NoteSummary]
  var id: String { title }

  static func grouped(_ notes: [NoteSummary], pinned: Set<URL>, byDate: Bool, now: Date = .now)
    -> [NoteGroup]
  {
    var groups: [NoteGroup] = []
    let pins = notes.filter { pinned.contains($0.url) }
    if !pins.isEmpty { groups.append(NoteGroup(title: "Pinned", notes: pins)) }
    let rest = notes.filter { !pinned.contains($0.url) }
    guard byDate else {
      if !rest.isEmpty { groups.append(NoteGroup(title: pins.isEmpty ? "" : "Notes", notes: rest)) }
      return groups
    }
    let calendar = Calendar.current
    var order: [String] = []
    var buckets: [String: [NoteSummary]] = [:]
    for note in rest {
      let title = bucket(for: note.modified, now: now, calendar: calendar)
      if buckets[title] == nil { order.append(title) }
      buckets[title, default: []].append(note)
    }
    return groups + order.map { NoteGroup(title: $0, notes: buckets[$0] ?? []) }
  }

  private static func bucket(for date: Date, now: Date, calendar: Calendar) -> String {
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    if days < 7 { return "Previous 7 Days" }
    if days < 30 { return "Previous 30 Days" }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      return date.formatted(.dateTime.month(.wide))
    }
    return date.formatted(.dateTime.year())
  }
}

extension Date {
  /// The note list's date: the time today, "Yesterday", the weekday this week, else
  /// the short date.
  var noteListText: String {
    let calendar = Calendar.current
    if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
    if calendar.isDateInYesterday(self) { return "Yesterday" }
    if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
      return formatted(.dateTime.weekday(.wide))
    }
    return formatted(date: .numeric, time: .omitted)
  }
}
