import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar: the app's notes (iCloud Drive or local), folders added by dropping them
/// on it (Finder, Files) or with Add Folder (persisted in SwiftData), and files opened
/// on their own — each an expandable tree of subfolders and markdown files. Searching
/// replaces the trees with matching notes.
struct SidebarView: View {
  @Environment(FolderLibrary.self) private var library
  @Environment(Navigator.self) private var navigator
  @Environment(NotesLocation.self) private var notes
  @Environment(FileActions.self) private var actions
  @Environment(\.modelContext) private var context
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]
  @State private var isImporting = false
  @State private var isDropTargeted = false
  @State private var query = ""
  @State private var results: [SearchResult]?

  var body: some View {
    @Bindable var navigator = navigator
    List(selection: $navigator.selection) {
      if let results, !query.isEmpty {
        searchResults(results)
      } else {
        notesSection
        if !rootFolders.isEmpty {
          section("Folders", rootFolders)
        }
        if !openedFiles.isEmpty {
          section("Files", openedFiles)
        }
      }
    }
    .searchable(text: $query, placement: .sidebar, prompt: "Search Notes")
    .task(id: query) { await search() }
    .overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.accentColor, lineWidth: 2)
          .padding(4)
          .allowsHitTesting(false)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      add(urls.filter(\.isFileURL))
    } isTargeted: { isDropTargeted = $0 }
    #if os(macOS)
      .onDeleteCommand {
        if let selection = navigator.selection, isDeletable(selection) {
          actions.delete(selection)
        }
      }
    #endif
    .toolbar {
      ToolbarItemGroup {
        Button("New Note", systemImage: "square.and.pencil") { newNote() }
          .keyboardShortcut("n", modifiers: .command)
          .disabled(notes.url == nil)
        Menu("More", systemImage: "ellipsis.circle") {
          Button("New Folder", systemImage: "folder.badge.plus") { newFolder() }
            .keyboardShortcut("n", modifiers: [.command, .shift])
          Button("Add Folder to Sidebar…", systemImage: "plus.rectangle.on.folder") {
            isImporting = true
          }
          .keyboardShortcut("o", modifiers: [.command, .shift])
        }
      }
    }
    .fileImporter(
      isPresented: $isImporting, allowedContentTypes: [.folder], allowsMultipleSelection: true
    ) { result in
      if case .success(let urls) = result { add(urls) }
    }
    .alert(
      "Couldn’t Add Folder",
      isPresented: Binding(
        get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(library.lastError ?? "")
    }
    .modifier(FileActionPrompts())
    .navigationTitle("Markdown")
    #if DEBUG && targetEnvironment(simulator)
      .task { addLaunchArgumentFolders() }
    #endif
  }

  // MARK: - Sections

  /// The notes folder's contents, listed directly under the section (the folder itself
  /// is the section).
  @ViewBuilder private var notesSection: some View {
    Section {
      if let root = notes.url {
        let _ = library.generation
        let children = library.children(of: root)
        ForEach(children) { child in
          FileTreeRow(node: child)
        }
        if children.isEmpty {
          Button("New Note", systemImage: "square.and.pencil") { newNote() }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
      } else {
        ProgressView().frame(maxWidth: .infinity)
      }
    } header: {
      HStack(spacing: 4) {
        Text("Notes")
        if notes.isICloud {
          Image(systemName: "icloud")
            .help("Notes are in iCloud Drive and sync to your other devices.")
        }
      }
    }
  }

  private var rootFolders: [SidebarFolder] { folders.filter { !$0.isFile } }
  private var openedFiles: [SidebarFolder] { folders.filter(\.isFile) }

  private func section(_ title: String, _ items: [SidebarFolder]) -> some View {
    Section(title) {
      ForEach(items) { folder in
        FolderRootRow(folder: folder)
      }
      #if os(iOS)
        .onDelete { offsets in
          for index in offsets {
            remove(items[index], library: library, navigator: navigator, context: context)
          }
        }
      #endif
    }
  }

  // MARK: - Search

  @ViewBuilder private func searchResults(_ results: [SearchResult]) -> some View {
    Section(results.isEmpty ? "No Results" : "\(results.count) Results") {
      ForEach(results) { result in
        VStack(alignment: .leading, spacing: 2) {
          Text(result.name).lineLimit(1)
          if let snippet = result.snippet {
            Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
          Text(result.location).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .tag(result.url)
      }
    }
  }

  /// Searches every root a moment after typing pauses (the task restarts per keystroke).
  private func search() async {
    let query = query.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else {
      results = nil
      return
    }
    try? await Task.sleep(for: .milliseconds(250))
    guard !Task.isCancelled else { return }
    var roots: [(name: String, url: URL)] = []
    if let url = notes.url { roots.append(("Notes", url)) }
    for folder in folders {
      guard let url = library.url(for: folder) else { continue }
      roots.append((folder.name, folder.isFile ? url.deletingLastPathComponent() : url))
    }
    let found = await Task.detached(priority: .userInitiated) {
      NoteSearch.search(query, in: roots)
    }.value
    guard !Task.isCancelled else { return }
    // Single opened files: only themselves, not their (inaccessible) folders.
    let files = Set(openedFiles.compactMap { library.url(for: $0) })
    let fileFolders = Set(files.map { $0.deletingLastPathComponent() })
    results = found.filter { result in
      !fileFolders.contains(result.url.deletingLastPathComponent()) || files.contains(result.url)
        || library.root(of: result.url, roots: library.roots(folders)) != nil
    }
  }

  // MARK: - Actions

  /// Where a new note or folder goes: the selected folder, the selected file's folder
  /// (inside the sidebar's folders), otherwise the notes folder.
  private var targetDirectory: URL? {
    if let selection = navigator.selection,
      library.root(of: selection, roots: library.roots(folders)) != nil
    {
      return FolderLibrary.isDirectory(selection)
        ? selection : selection.deletingLastPathComponent()
    }
    return notes.url
  }

  private func newNote() {
    if let dir = targetDirectory { actions.newNote(in: dir) }
  }

  private func newFolder() {
    if let dir = targetDirectory { actions.newFolder(in: dir) }
  }

  /// Anything inside a root, but not a root itself (those are removed from the sidebar).
  private func isDeletable(_ url: URL) -> Bool {
    let roots = library.roots(folders)
    return library.root(of: url, roots: roots) != nil && !roots.contains(url)
  }

  #if DEBUG && targetEnvironment(simulator)
    /// Debug simulator builds: `--add-folder <path>` (repeatable) adds Mac folders at
    /// launch, for testing without the picker. Simulator-only: the macOS sandbox grants
    /// no access to a path passed on the command line, so the folder would be unreadable.
    private func addLaunchArgumentFolders() {
      let args = CommandLine.arguments
      let paths = args.indices.filter { args[$0] == "--add-folder" && $0 + 1 < args.count }
        .map { args[$0 + 1] }
      guard let first = paths.first else { return }
      add(paths.map { URL(fileURLWithPath: $0, isDirectory: true) })
      // Already in the sidebar from an earlier run: show it anyway.
      navigator.open(FolderLibrary.canonical(URL(fileURLWithPath: first, isDirectory: true)))
    }
  #endif

  /// Adds the folders and shows the first new one (its README).
  @discardableResult
  private func add(_ urls: [URL]) -> Bool {
    let added = library.add(urls, existing: folders, context: context)
    if let first = added.first { navigator.open(first) }
    return !added.isEmpty
  }
}

/// The rename prompt, the delete confirmation and file-operation errors.
private struct FileActionPrompts: ViewModifier {
  @Environment(FileActions.self) private var actions

  func body(content: Content) -> some View {
    @Bindable var actions = actions
    content
      .alert(
        "Rename", isPresented: Binding(get: { actions.renaming != nil }, set: { if !$0 { actions.renaming = nil } })
      ) {
        TextField("Name", text: $actions.newName)
        Button("Rename") { actions.commitRename() }
          .keyboardShortcut(.defaultAction)
        Button("Cancel", role: .cancel) { actions.renaming = nil }
      }
      .confirmationDialog(
        "Delete “\(actions.deleting?.lastPathComponent ?? "")”?",
        isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } }),
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) { actions.confirmDelete() }
      } message: {
        Text("This can’t be undone.")
      }
      .alert(
        "Couldn’t Complete the Action",
        isPresented: Binding(get: { actions.error != nil }, set: { if !$0 { actions.error = nil } })
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(actions.error ?? "")
      }
  }
}

/// A sidebar folder: its tree, or a placeholder when it can no longer be reached.
private struct FolderRootRow: View {
  let folder: SidebarFolder
  @Environment(FolderLibrary.self) private var library
  @Environment(Navigator.self) private var navigator
  @Environment(FileActions.self) private var actions
  @Environment(\.modelContext) private var context

  var body: some View {
    Group {
      if let url = library.url(for: folder) {
        FileTreeRow(node: FileNode(url: url, isDirectory: !folder.isFile), isRoot: true)
      } else {
        Label {
          Text(folder.name).foregroundStyle(.secondary)
        } icon: {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
        }
        .help("\(folder.path) can’t be found. It may have been moved or deleted.")
      }
    }
    .contextMenu {
      if !folder.isFile, let url = library.url(for: folder) {
        Button("New Note") { actions.newNote(in: url) }
        Button("New Folder") { actions.newFolder(in: url) }
        Divider()
      }
      #if os(macOS)
        if let url = library.url(for: folder) {
          Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
      #endif
      Button("Reload") { library.reload() }
      Divider()
      Button("Remove from Sidebar", role: .destructive) {
        remove(folder, library: library, navigator: navigator, context: context)
      }
    }
  }
}

/// A folder (expandable, lazily listed) or a markdown file. Selecting a folder shows
/// its README. Items can be dragged onto folders (moved; files from other apps are
/// copied in) and have the organizing actions in their context menu.
struct FileTreeRow: View {
  let node: FileNode
  var isRoot = false
  @Environment(FolderLibrary.self) private var library
  @Environment(FileActions.self) private var actions
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]
  @State private var isDropTargeted = false

  var body: some View {
    if node.isDirectory {
      DisclosureGroup(isExpanded: expandedBinding) {
        // Read only once expanded; `generation` re-lists after a reload.
        let _ = library.generation
        ForEach(library.children(of: node.url)) { child in
          FileTreeRow(node: child)
        }
      } label: {
        label(Label(node.name, systemImage: isRoot ? "folder.fill" : "folder"))
          .dropDestination(for: URL.self) { urls, _ in
            actions.drop(urls, into: node.url, roots: library.roots(folders))
          } isTargeted: { isDropTargeted = $0 }
          .listRowBackground(
            isDropTargeted ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.2)) : nil)
      }
      .tag(node.url)
    } else {
      label(Label(node.name, systemImage: "doc.text"))
        .tag(node.url)
    }
  }

  /// Roots keep their sidebar menu (FolderRootRow); everything inside gets the file one.
  @ViewBuilder private func label(_ label: some View) -> some View {
    if isRoot {
      label
    } else {
      label
        .draggable(node.url)
        .contextMenu { menu }
    }
  }

  @ViewBuilder private var menu: some View {
    let folder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    Button("New Note") { actions.newNote(in: folder) }
    Button("New Folder") { actions.newFolder(in: folder) }
    Divider()
    Button("Rename…") { actions.beginRename(node.url) }
    #if os(macOS)
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
    #endif
    Divider()
    #if os(macOS)
      Button("Move to Trash", role: .destructive) { actions.delete(node.url) }
    #else
      Button("Delete…", role: .destructive) { actions.delete(node.url) }
    #endif
  }

  private var expandedBinding: Binding<Bool> {
    Binding(
      get: { library.expanded.contains(node.url) },
      set: { isOpen in
        if isOpen { library.expanded.insert(node.url) } else { library.expanded.remove(node.url) }
      })
  }
}

/// Removes a folder from the sidebar (never from disk) and forgets what was shown from it.
@MainActor private func remove(
  _ folder: SidebarFolder, library: FolderLibrary, navigator: Navigator, context: ModelContext
) {
  if let url = library.url(for: folder) { navigator.forget(under: url) }
  library.remove(folder, context: context)
}
