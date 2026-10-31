import ComponentKit
import SwiftData
import SwiftUI

/// The notes of the place chosen in the sidebar (`Navigator.item`), loaded for the rows under it (`PlaceNotes`), and
/// the notes that match the sidebar's search line.
@Observable final class NoteListModel {
  /// The listed notes, newest first; nil until the first load.
  var summaries: [NoteSummary]?
  /// The item `summaries` belong to.
  var loadedItem: LibraryItem?
  /// The notes that match the search line; nil while it is empty.
  var results: [SearchResult]?
}

/// The notes of the place chosen in the sidebar, right under its row as the tree's next level: pinned first, then
/// newest first (or by title), each with its time and first line. A place without notes offers a new one where the app
/// can write. `SidebarView` loads them into the `NoteListModel` in the environment; rows put this after a place's row,
/// one indent level deeper (`kitRowIndent`).
struct PlaceNotes: View {
  let item: LibraryItem
  @Environment(NoteListModel.self) private var model
  @Environment(FileActions.self) private var actions
  @Environment(Navigator.self) private var navigator
  @Environment(NotePreferences.self) private var preferences
  @AppStorage(NoteSort.key) private var sortsByTitle = false

  var body: some View {
    if navigator.item == item, model.loadedItem == item, let summaries = model.summaries {
      if summaries.isEmpty {
        EmptyPlaceRow(item: item)
      } else {
        ForEach(NoteSort.sorted(summaries, pinned: preferences.pinned, byTitle: sortsByTitle)) { note in
          NoteRow(note: note, isPinned: preferences.isPinned(note.url))
            .renamesInPlace(note.url, actions: actions)
            .draggable(note.url)
            .kitContextMenu { NoteMenu(url: note.url, renamesInPlace: true) }
        }
      }
    }
  }
}

/// How the sidebar orders a place's notes: pinned first, then by date edited (newest first) or by title.
enum NoteSort {
  static let key = "noteListSortsByTitle"

  static func sorted(_ notes: [NoteSummary], pinned: Set<URL>, byTitle: Bool) -> [NoteSummary] {
    var notes = notes
    if byTitle { notes.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    return notes.filter { pinned.contains($0.url) } + notes.filter { !pinned.contains($0.url) }
  }
}

/// A place without notes: a row that starts one where the app can write.
private struct EmptyPlaceRow: View {
  let item: LibraryItem
  @Environment(FolderLibrary.self) private var library
  @Environment(Navigator.self) private var navigator
  @Environment(NotesLocation.self) private var notes
  @Environment(FileActions.self) private var actions
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]

  var body: some View {
    if item != .openedFiles, let dir = newNoteDirectory {
      SidebarRow("New Note", subtitle: "No notes here yet.", systemImage: "square.and.pencil")
        .action { actions.newNote(in: dir) }
    } else {
      SidebarRow(
        "No Notes", subtitle: item == .openedFiles ? "Files you open from \(KitDesktop.fileManagerName) appear here." : nil,
        systemImage: "note.text", hue: .gray)
    }
  }

  /// The listed folder when the app can write there, otherwise the notes folder.
  private var newNoteDirectory: URL? {
    if case .folder(let dir) = item, FolderLibrary.isDirectory(dir),
      library.root(of: dir, roots: library.roots(folders)) != nil
    {
      return dir
    }
    return notes.url
  }
}

/// A note's context menu: pin, rename, encrypt, show, share, and remove or delete.
struct NoteMenu: View {
  let url: URL
  /// Rename… renames in the note's sidebar row (a place's notes) instead of the Rename prompt (search results).
  var renamesInPlace = false
  @Environment(FolderLibrary.self) private var library
  @Environment(Navigator.self) private var navigator
  @Environment(FileActions.self) private var actions
  @Environment(NotePreferences.self) private var preferences
  @Environment(\.modelContext) private var context
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]

  var body: some View {
    Button(preferences.isPinned(url) ? "Unpin Note" : "Pin Note", systemImage: preferences.isPinned(url) ? "pin.slash" : "pin") {
      withAnimation { preferences.togglePin(url) }
    }
    Divider()
    if isDeletable {
      Button("Rename…", systemImage: "pencil") { actions.beginRename(url, inPlace: renamesInPlace) }
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
    } else if isDeletable {
      #if os(macOS) || os(Windows)
        Button("Move to Trash", systemImage: "trash", role: .destructive) { actions.delete(url) }
      #else
        Button("Delete…", systemImage: "trash", role: .destructive) { actions.delete(url) }
      #endif
    }
  }

  /// Anything inside a root, but not a root itself.
  private var isDeletable: Bool {
    let roots = library.roots(folders)
    return library.root(of: url, roots: roots) != nil && !roots.contains(url)
  }
}

/// The notes that match the sidebar's search line, below the places while it holds text.
struct NoteSearchSection: View {
  @Environment(NoteListModel.self) private var model
  @Environment(WindowState.self) private var window

  var body: some View {
    if !window.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty, let results = model.results {
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
            .kitContextMenu { NoteMenu(url: result.url) }
        }
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
            .imageScale(.small)
            .foregroundStyle(Hue.orange.fill)
            .kitFont(.caption)
            .accessibilityLabel("Pinned")
        }
      }
  }
}
