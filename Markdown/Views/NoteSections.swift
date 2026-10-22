import ComponentKit
import SwiftData
import SwiftUI

/// The notes of the place chosen in the sidebar (`Navigator.item`), loaded for the sidebar's note sections, and the
/// notes that match the sidebar's search line.
@Observable final class NoteListModel {
  /// The listed notes, newest first; nil until the first load.
  var summaries: [NoteSummary]?
  /// The item `summaries` belong to.
  var loadedItem: LibraryItem?
  /// The notes that match the search line; nil while it is empty.
  var results: [SearchResult]?
}

/// The sidebar's notes, below the places: the chosen place's notes newest first and grouped by date (Pinned, Today,
/// Yesterday, …) as in Notes, a card per group, each note with its time and first line. While the search line holds
/// text, the notes that match instead. `SidebarView` loads them into `NoteListModel`.
struct NoteSections: View {
  let model: NoteListModel
  @Environment(FolderLibrary.self) private var library
  @Environment(Navigator.self) private var navigator
  @Environment(NotesLocation.self) private var notes
  @Environment(FileActions.self) private var actions
  @Environment(NotePreferences.self) private var preferences
  @Environment(RepositoryStore.self) private var repositories
  @Environment(\.modelContext) private var context
  @Environment(WindowState.self) private var window
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]
  @AppStorage("noteListSortsByTitle") private var sortsByTitle = false
  @State private var showsSortMenu = false

  var body: some View {
    if isSearching, let results = model.results {
      searchSection(results)
    } else if let item = navigator.item, let summaries = model.summaries, model.loadedItem == item {
      let groups = groups(summaries)
      if groups.isEmpty {
        emptySection(item)
      } else {
        ForEach(groups) { group in
          KitSection(
            group.title.isEmpty ? placeTitle : group.title, meta: meta(group), systemImage: image(group),
            hue: hue(group)
          ) {
            rows(group)
          } accessory: {
            if group.id == groups.first?.id { sortButton }
          }
          // A long group keeps its title in view while its notes scroll by.
          .kitSticky()
        }
      }
    }
  }

  // MARK: - Groups

  private func groups(_ summaries: [NoteSummary]) -> [NoteGroup] {
    var notes = summaries
    if sortsByTitle {
      notes.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    return NoteGroup.grouped(notes, pinned: preferences.pinned, byDate: !sortsByTitle)
  }

  private func rows(_ group: NoteGroup) -> some View {
    ForEach(group.notes) { note in
      NoteRow(note: note, isPinned: preferences.isPinned(note.url))
        .draggable(note.url)
        .kitContextMenu { menu(for: note.url) }
    }
  }

  /// A date group's meta line: how many, and when the newest was edited.
  private func meta(_ group: NoteGroup) -> [String] {
    let count = group.notes.count == 1 ? "1 note" : "\(group.notes.count) notes"
    let edited = group.notes.map(\.modified).max().map { "edited \($0.noteListText)" } ?? ""
    return [count, edited]
  }

  private func image(_ group: NoteGroup) -> String {
    group.title == "Pinned" ? "pin" : sortsByTitle ? "textformat" : "clock"
  }

  private func hue(_ group: NoteGroup) -> Hue { group.title == "Pinned" ? .orange : .accent }

  /// Date Edited or Title, on the first group's card.
  private var sortButton: some View {
    Button("Sort", systemImage: "line.3.horizontal.decrease") { showsSortMenu = true }
      .labelStyle(.iconOnly)
      .kitMenu(isPresented: $showsSortMenu) {
        KitMenuOptions(selection: $sortsByTitle, options: [("Date Edited", false), ("Title", true)])
      }
      .kitHelp("Sort", meta: sortsByTitle ? "By title" : "By date edited")
  }

  /// A place without notes: its name, and a row that starts one where the app can write.
  private func emptySection(_ item: LibraryItem) -> some View {
    KitSection(placeTitle, meta: "No notes", systemImage: "note.text", hue: .gray) {
      if item != .openedFiles, newNoteDirectory != nil {
        SidebarRow("New Note", subtitle: "Notes you write here appear in this list.", systemImage: "square.and.pencil")
          .action { newNote() }
      } else {
        SidebarRow(
          "No Notes", subtitle: item == .openedFiles ? "Files you open from Finder appear here." : nil,
          systemImage: "note.text", hue: .gray)
      }
    }
  }

  /// The listed place's name, for a group without one (notes sorted by title).
  private var placeTitle: String {
    switch navigator.item {
    case .allNotes, nil: "All Notes"
    case .folder(let url):
      url == notes.url
        ? "Notes"
        : repositories.repositories.first { repositories.directory(for: $0) == url }?.fullName
          ?? url.lastPathComponent
    case .openedFiles: "Opened Files"
    }
  }

  // MARK: - Menus

  @ViewBuilder private func menu(for url: URL) -> some View {
    Button(preferences.isPinned(url) ? "Unpin Note" : "Pin Note", systemImage: preferences.isPinned(url) ? "pin.slash" : "pin") {
      withAnimation { preferences.togglePin(url) }
    }
    Divider()
    if isDeletable(url) {
      Button("Rename…", systemImage: "pencil") { actions.beginRename(url) }
      if actions.canToggleEncryption(url) {
        let encrypted = NoteFiles.isEncrypted(url)
        Button(encrypted ? "Decrypt Note" : "Encrypt Note", systemImage: encrypted ? "lock.open" : "lock") {
          actions.setEncrypted(url, !encrypted)
        }
      }
    }
    #if os(macOS) || os(Windows)
      Button("Show in \(KitDesktop.fileManagerName)", systemImage: "folder") { KitDesktop.reveal([url]) }
    #endif
    KitMenuShare(items: [url])
    Divider()
    if let folder = folders.first(where: { $0.isFile && $0.path == url.path }) {
      Button("Remove from List", systemImage: "minus.circle") {
        remove(folder, library: library, navigator: navigator, context: context)
      }
    } else if isDeletable(url) {
      #if os(macOS) || os(Windows)
        Button("Move to Trash", systemImage: "trash", role: .destructive) { actions.delete(url) }
      #else
        Button("Delete…", systemImage: "trash", role: .destructive) { actions.delete(url) }
      #endif
    }
  }

  // MARK: - New notes

  /// The listed folder when the app can write there, otherwise the notes folder.
  private var newNoteDirectory: URL? {
    if case .folder(let dir) = navigator.item, FolderLibrary.isDirectory(dir),
      library.root(of: dir, roots: library.roots(folders)) != nil
    {
      return dir
    }
    return notes.url
  }

  private func newNote() {
    guard let dir = newNoteDirectory else { return }
    if navigator.item == nil || navigator.item == .openedFiles { navigator.item = .folder(dir) }
    actions.newNote(in: dir)
  }

  /// Anything inside a root, but not a root itself.
  private func isDeletable(_ url: URL) -> Bool {
    let roots = library.roots(folders)
    return library.root(of: url, roots: roots) != nil && !roots.contains(url)
  }

  // MARK: - Search

  private var isSearching: Bool {
    !window.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private func searchSection(_ results: [SearchResult]) -> some View {
    KitSection(
      "Search", meta: results.isEmpty ? "No results" : results.count == 1 ? "1 result" : "\(results.count) results",
      systemImage: "magnifyingglass", status: results.isEmpty ? .failed : .idle
    ) {
      ForEach(results) { result in
        SidebarRow(value: result.url, result.name) { EmptyView() }
          .subtitle {
            VStack(alignment: .leading, spacing: 1) {
              if let snippet = result.snippet { Text(snippet).foregroundStyle(.kitSecondary) }
              Text(result.location).foregroundStyle(.kitTertiary)
            }
          }
          .kitContextMenu { menu(for: result.url) }
      }
    }
  }
}

// MARK: - Loading

extension NoteListModel {
  /// Lists the notes of `item`: a folder's own, the files opened on their own, or every note in the notes folder.
  func load(_ item: LibraryItem?, library: FolderLibrary, notes: NotesLocation, folders: [SidebarFolder]) async {
    guard let item else {
      summaries = []
      loadedItem = nil
      return
    }
    let urls: [URL]
    switch item {
    case .folder(let dir):
      urls = library.children(of: dir).filter { !$0.isDirectory }.map(\.url)
    case .openedFiles:
      urls = folders.filter(\.isFile).compactMap { library.url(for: $0) }
    case .allNotes:
      guard let root = notes.url else { return }
      urls = await Task.detached(priority: .userInitiated) { NoteSummaries.allNotes(in: root) }.value
    }
    let loaded = await Task.detached(priority: .userInitiated) { NoteSummaries.load(urls) }.value
    guard !Task.isCancelled else { return }
    summaries = loaded
    loadedItem = item
  }

  /// Searches every note a moment after typing pauses (the task restarts per keystroke).
  func search(_ query: String, scope: SearchScope) async {
    let query = query.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else {
      results = nil
      return
    }
    try? await Task.sleep(for: .milliseconds(250))
    guard !Task.isCancelled else { return }
    let found = await scope.search(query)
    guard !Task.isCancelled else { return }
    results = found
  }
}

/// A note in the sidebar: its name (a pin when pinned), then its date and the start of its text.
private struct NoteRow: View {
  let note: NoteSummary
  let isPinned: Bool

  var body: some View {
    SidebarRow(value: note.url, note.title) { EmptyView() }
      .subtitle {
        Text(note.modified.noteListText).foregroundStyle(.kitLabel)
          + Text("  " + (note.snippet.isEmpty ? "No additional text" : note.snippet))
      }
      .titleAccessory {
        if isPinned {
          Image(systemName: "pin.fill")
            .font(.system(size: 9))
            .foregroundStyle(Hue.orange.fill)
            .accessibilityLabel("Pinned")
        }
      }
  }
}
