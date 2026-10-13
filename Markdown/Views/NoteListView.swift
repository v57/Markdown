import SwiftData
import SwiftUI

/// The middle column: the notes of the sidebar's selection, newest first and grouped by
/// date (Pinned, Today, Yesterday, …) as in Notes, each with its time and first line.
/// On iOS it also searches every note.
struct NoteListView: View {
  @Environment(FolderLibrary.self) private var library
  @Environment(Navigator.self) private var navigator
  @Environment(NotesLocation.self) private var notes
  @Environment(FileActions.self) private var actions
  @Environment(NotePreferences.self) private var preferences
  @Environment(RepositoryStore.self) private var repositories
  @Environment(\.modelContext) private var context
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]
  @State private var summaries: [NoteSummary]?
  /// The item `summaries` belong to.
  @State private var loadedItem: LibraryItem?
  @AppStorage("noteListSortsByTitle") private var sortsByTitle = false
  #if os(iOS)
    @State private var query = ""
    @State private var results: [SearchResult]?
  #endif

  private struct LoadKey: Equatable {
    var item: LibraryItem?
    var generation: Int
  }

  var body: some View {
    list
      .overlay { emptyState }
      .navigationTitle(title)
      #if os(macOS)
        .navigationSubtitle(subtitle)
      #else
        .searchable(text: $query, prompt: "Search")
        .task(id: query) { await search() }
      #endif
      .toolbar { toolbar }
      .task(id: LoadKey(item: navigator.item, generation: library.generation)) { await load() }
    }

  @ViewBuilder private var list: some View {
    #if os(iOS)
      if isSearching, let results {
        List(selection: noteSelection) { searchResults(results) }
      } else {
        notesList
      }
    #else
      notesList
    #endif
  }

  private var notesList: some View {
    List(selection: noteSelection) {
      ForEach(groups) { group in
        Section {
          ForEach(group.notes) { note in
            NoteRow(note: note, isPinned: preferences.isPinned(note.url))
              .tag(note.url)
              .draggable(note.url)
              .contextMenu { menu(for: note.url) }
              #if os(iOS)
                .swipeActions(edge: .leading) {
                  Button(preferences.isPinned(note.url) ? "Unpin" : "Pin", systemImage: preferences.isPinned(note.url) ? "pin.slash" : "pin") {
                    withAnimation { preferences.togglePin(note.url) }
                  }
                  .tint(.orange)
                }
                .swipeActions(edge: .trailing) {
                  Button("Delete", systemImage: "trash", role: .destructive) { actions.delete(note.url) }
                }
              #endif
          }
        } header: {
          if !group.title.isEmpty { Text(group.title) }
        }
      }
    }
    // A fresh list per folder: on macOS, rows replaced while a selection moved into
    // them kept the height of a one-line row and lost their date and text.
    .id(loadedItem)
    #if os(iOS)
      .listStyle(.insetGrouped)
    #endif
    #if os(macOS)
      .onDeleteCommand {
        if let url = navigator.selection, isDeletable(url) { actions.delete(url) }
      }
    #endif
  }

  @ViewBuilder private var emptyState: some View {
    if let summaries, summaries.isEmpty, !isSearching, navigator.item != nil {
      ContentUnavailableView {
        Label("No Notes", systemImage: "note.text")
      } description: {
        Text(navigator.item == .openedFiles ? "Files you open from Finder appear here." : "Notes you write here appear in this list.")
      } actions: {
        if newNoteDirectory != nil {
          Button("New Note") { newNote() }
        }
      }
    } else if navigator.item == nil {
      ContentUnavailableView("No Folder Selected", systemImage: "sidebar.left", description: Text("Choose a folder in the sidebar."))
    }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItem {
      Menu("Sort", systemImage: "line.3.horizontal.decrease") {
        Picker("Sort By", selection: $sortsByTitle) {
          Text("Date Edited").tag(false)
          Text("Title").tag(true)
        }
        .pickerStyle(.inline)
      }
      .help("Sort notes by the date they were edited or by title")
    }
    #if os(iOS)
      ToolbarItem(placement: .bottomBar) { Spacer() }
      ToolbarItem(placement: .bottomBar) {
        Button("New Note", systemImage: "square.and.pencil") { newNote() }
          .disabled(newNoteDirectory == nil)
      }
    #else
      ToolbarItem {
        Button("New Note", systemImage: "square.and.pencil") { newNote() }
          .keyboardShortcut("n", modifiers: .command)
          .disabled(newNoteDirectory == nil)
          .help("New Note (⌘N)")
      }
    #endif
  }

  @ViewBuilder private func menu(for url: URL) -> some View {
    Button(preferences.isPinned(url) ? "Unpin Note" : "Pin Note", systemImage: preferences.isPinned(url) ? "pin.slash" : "pin") {
      withAnimation { preferences.togglePin(url) }
    }
    Divider()
    if isDeletable(url) {
      Button("Rename…", systemImage: "pencil") { actions.beginRename(url) }
    }
    #if os(macOS)
      Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    #endif
    ShareLink(item: url)
    Divider()
    if let folder = folders.first(where: { $0.isFile && $0.path == url.path }) {
      Button("Remove from List", systemImage: "minus.circle") {
        remove(folder, library: library, navigator: navigator, context: context)
      }
    } else if isDeletable(url) {
      #if os(macOS)
        Button("Move to Trash", systemImage: "trash", role: .destructive) { actions.delete(url) }
      #else
        Button("Delete…", systemImage: "trash", role: .destructive) { actions.delete(url) }
      #endif
    }
  }

  // MARK: - Contents

  private var groups: [NoteGroup] {
    var notes = summaries ?? []
    if sortsByTitle {
      notes.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    return NoteGroup.grouped(notes, pinned: preferences.pinned, byDate: !sortsByTitle)
  }

  /// The list highlights the shown note (not a folder shown by its README).
  private var noteSelection: Binding<URL?> {
    Binding(
      get: {
        guard let selection = navigator.selection, !FolderLibrary.isDirectory(selection) else { return nil }
        return selection
      },
      set: { url in
        if let url { navigator.selection = url }
      })
  }

  private func load() async {
    guard let item = navigator.item else {
      summaries = []
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

  private var title: String {
    switch navigator.item {
    case .allNotes: "All Notes"
    case .folder(let url): url == notes.url ? "Notes" : repositories.repositories.first { repositories.directory(for: $0) == url }?.fullName ?? url.lastPathComponent
    case .openedFiles: "Opened Files"
    case nil: "Notes"
    }
  }

  private var subtitle: String {
    guard let count = summaries?.count else { return "" }
    return count == 1 ? "1 note" : "\(count) notes"
  }

  // MARK: - New notes

  /// The listed folder when the app can write there, otherwise the notes folder.
  private var newNoteDirectory: URL? {
    if case .folder(let dir) = navigator.item, library.root(of: dir, roots: library.roots(folders)) != nil {
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

  // MARK: - Search (iOS)

  private var isSearching: Bool {
    #if os(iOS)
      !query.trimmingCharacters(in: .whitespaces).isEmpty
    #else
      false
    #endif
  }

  #if os(iOS)
    @ViewBuilder private func searchResults(_ results: [SearchResult]) -> some View {
      Section(results.isEmpty ? "No Results" : results.count == 1 ? "1 Result" : "\(results.count) Results") {
        ForEach(results) { result in
          VStack(alignment: .leading, spacing: 2) {
            Text(result.name).font(.headline).lineLimit(1)
            if let snippet = result.snippet {
              Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(result.location).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
          }
          .tag(result.url)
        }
      }
    }

    /// Searches every note a moment after typing pauses (the task restarts per keystroke).
    private func search() async {
      let query = query.trimmingCharacters(in: .whitespaces)
      guard !query.isEmpty else {
        results = nil
        return
      }
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      let scope = SearchScope(library: library, notes: notes, repositories: repositories, folders: folders)
      let found = await scope.search(query)
      guard !Task.isCancelled else { return }
      results = found
    }
  #endif
}

/// A note in the list: its name, then its date and the start of its text.
private struct NoteRow: View {
  let note: NoteSummary
  let isPinned: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        Text(note.title)
          .font(.headline)
          .lineLimit(1)
        if isPinned {
          Image(systemName: "pin.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
            .accessibilityLabel("Pinned")
        }
      }
      HStack(spacing: 6) {
        Text(note.modified.noteListText)
          .foregroundStyle(.primary)
        Text(note.snippet.isEmpty ? "No additional text" : note.snippet)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .font(.subheadline)
    }
    .padding(.vertical, 4)
  }
}
