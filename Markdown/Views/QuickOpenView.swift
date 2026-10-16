import ComponentKit
import SwiftData
import SwiftUI

/// Something Quick Open can do besides opening a note.
enum QuickOpenCommand: Hashable {
  /// A new note, named after what was typed (or "Untitled").
  case newNote(String?)
  case newFolder
  case addFolder
  case welcome
}

/// Quick Open (⌘K): one field that finds notes by name, finds text inside notes, and
/// runs commands. Arrow keys move, Return opens, Escape closes. With nothing typed it
/// lists recent notes. The kit's palette: a group card per kind of result.
struct QuickOpenView: View {
  var perform: (QuickOpenCommand) -> Void
  @Environment(FolderLibrary.self) private var library
  @Environment(Navigator.self) private var navigator
  @Environment(NotesLocation.self) private var notes
  @Environment(NotePreferences.self) private var preferences
  @Environment(RepositoryStore.self) private var repositories
  @Environment(WindowState.self) private var window
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]
  @State private var query = ""
  @State private var results: [SearchResult] = []
  @State private var isSearching = false

  private struct Entry: Identifiable {
    enum Action { case open(URL), command(QuickOpenCommand) }
    let id: String
    let section: String
    let title: String
    let subtitle: String?
    let systemImage: String
    var hue: Hue = .blue
    var shortcut: String?
    let action: Action
  }

  var body: some View {
    let entries = entries
    KitPalette(
      query: $query, prompt: "Search notes and commands", status: status, hints: hints, maxHeight: 420,
      dismiss: close
    ) {
      ForEach(sections(entries), id: \.title) { section in
        PaletteGroup(section.title, meta: section.meta, systemImage: section.systemImage, hue: section.hue) {
          ForEach(section.entries) { entry in
            PaletteItem(
              entry.title, id: entry.id, systemImage: entry.systemImage, hue: entry.hue, detail: entry.subtitle,
              shortcut: entry.shortcut
            ) {
              activate(entry)
            }
          }
        }
      }
    }
    .task(id: query) { await search() }
  }

  private var hints: [PaletteHint] {
    #if os(macOS)
      PaletteHint.standard
    #else
      []
    #endif
  }

  /// The arc while searching, red when no note matched.
  private var status: WorkStatus {
    if trimmedQuery.isEmpty { return .idle }
    if isSearching { return .working }
    return results.isEmpty ? .failed : .idle
  }

  private struct Section {
    var title: String
    var meta: [String]
    var systemImage: String
    var hue: Hue
    var entries: [Entry]
  }

  /// The entries in their groups, in order.
  private func sections(_ entries: [Entry]) -> [Section] {
    var sections: [Section] = []
    for entry in entries {
      if sections.last?.title == entry.section {
        sections[sections.count - 1].entries.append(entry)
      } else {
        let (image, hue): (String, Hue) =
          switch entry.section {
          case "Recent": ("clock", .blue)
          case "Notes": ("doc.text", .blue)
          case "Inside Notes": ("text.magnifyingglass", .blue)
          default: ("command", .gray)
          }
        sections.append(Section(title: entry.section, meta: [], systemImage: image, hue: hue, entries: [entry]))
      }
    }
    for index in sections.indices {
      let count = sections[index].entries.count
      let noun = sections[index].title == "Commands" ? "command" : "note"
      sections[index].meta = [count == 1 ? "1 \(noun)" : "\(count) \(noun)s"]
    }
    return sections
  }

  // MARK: - Entries

  private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  private var entries: [Entry] {
    let query = trimmedQuery
    var entries: [Entry] = []
    if query.isEmpty {
      for url in preferences.existingRecents.prefix(6) {
        entries.append(noteEntry(url, section: "Recent", subtitle: location(of: url)))
      }
    } else {
      for result in results.filter(\.nameMatches).prefix(6) {
        entries.append(noteEntry(result.url, section: "Notes", subtitle: result.location))
      }
      for result in results.filter({ !$0.nameMatches }).prefix(6) {
        let snippet = result.snippet.map { NoteSummaries.plain($0) } ?? result.location
        entries.append(noteEntry(result.url, section: "Inside Notes", subtitle: snippet, systemImage: "text.alignleft"))
      }
    }
    entries += commands(matching: query)
    return entries
  }

  private func noteEntry(
    _ url: URL, section: String, subtitle: String, systemImage: String = "doc.text"
  ) -> Entry {
    Entry(
      id: section + url.path, section: section,
      title: url.deletingPathExtension().lastPathComponent, subtitle: subtitle,
      systemImage: systemImage, action: .open(url))
  }

  private func commands(matching query: String) -> [Entry] {
    var all: [Entry] = [
      Entry(
        id: "new-note", section: "Commands",
        title: query.isEmpty ? "New Note" : "New Note “\(query)”", subtitle: nil,
        systemImage: "square.and.pencil", hue: .gray, shortcut: "⌘N", action: .command(.newNote(query.isEmpty ? nil : query))),
      Entry(
        id: "new-folder", section: "Commands", title: "New Folder", subtitle: nil,
        systemImage: "folder.badge.plus", hue: .gray, shortcut: "⇧⌘N", action: .command(.newFolder)),
      Entry(
        id: "add-folder", section: "Commands", title: "Add Folder to Sidebar…", subtitle: nil,
        systemImage: "plus.rectangle.on.folder", hue: .gray, shortcut: "⇧⌘O", action: .command(.addFolder)),
      Entry(
        id: "welcome", section: "Commands", title: "Welcome to Markdown", subtitle: nil,
        systemImage: "hand.wave", hue: .gray, shortcut: "⇧⌘1", action: .command(.welcome)),
    ]
    #if os(iOS)
      for index in all.indices { all[index].shortcut = nil }
    #endif
    guard !query.isEmpty else { return all }
    // "New Note “…”" always; the rest when every typed word is in their title.
    let terms = query.split(separator: " ").map(String.init)
    return all.filter { entry in
      entry.id == "new-note"
        || terms.allSatisfy { entry.title.localizedCaseInsensitiveContains($0) }
    }
  }

  /// "Projects · iCloud" for a recent note.
  private func location(of url: URL) -> String {
    let folder = url.deletingLastPathComponent()
    if let root = notes.url, folder == root { return notes.isICloud ? "iCloud" : "Notes" }
    if let root = notes.url, folder.path.hasPrefix(root.path + "/") {
      return folder.lastPathComponent + (notes.isICloud ? " · iCloud" : "")
    }
    return folder.lastPathComponent
  }

  // MARK: - Actions

  private func search() async {
    let query = trimmedQuery
    guard !query.isEmpty else {
      results = []
      isSearching = false
      return
    }
    isSearching = true
    try? await Task.sleep(for: .milliseconds(150))
    guard !Task.isCancelled else { return }
    let scope = SearchScope(library: library, notes: notes, repositories: repositories, folders: folders)
    let found = await scope.search(query)
    guard !Task.isCancelled else { return }
    results = found
    isSearching = false
  }

  private func activate(_ entry: Entry) {
    close()
    switch entry.action {
    case .open(let url):
      library.reveal(url, roots: library.roots(folders))
      navigator.open(url)
    case .command(let command):
      perform(command)
    }
  }

  private func close() {
    window.isQuickOpenShown = false
  }
}

