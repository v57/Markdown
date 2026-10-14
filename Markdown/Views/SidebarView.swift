import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// The sidebar: where notes live. All Notes and the notes folder (iCloud Drive or local)
/// with its folders, connected GitHub repositories, folders added by dropping them here
/// (Finder, Files) or with Add Folder (persisted in SwiftData), and files opened on their
/// own. Selecting one lists its notes in the note list.
struct SidebarView: View {
  @Environment(FolderLibrary.self) private var library
  @Environment(Navigator.self) private var navigator
  @Environment(NotesLocation.self) private var notes
  @Environment(FileActions.self) private var actions
  @Environment(RepositoryStore.self) private var repositories
  @Environment(WindowState.self) private var window
  @Environment(\.modelContext) private var context
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]
  @State private var isConnectingGitHub = false
  @State private var isDropTargeted = false
  @State private var allNotesCount: Int?
  /// The shared projects section, collapsed until opened (it can be long).
  @AppStorage("showsSharedProjects") private var showsProjects = false

  var body: some View {
    List(selection: itemBinding) {
      notesSection
      if !repositories.repositories.isEmpty {
        Section("GitHub") {
          ForEach(repositories.repositories, id: \.fullName) { repository in
            RepositoryRow(repository: repository)
          }
        }
      }
      if !rootFolders.isEmpty {
        Section("Folders") {
          ForEach(rootFolders) { folder in
            FolderRootRow(folder: folder)
          }
          #if os(iOS)
            .onDelete { offsets in
              for index in offsets {
                remove(rootFolders[index], library: library, navigator: navigator, context: context)
              }
            }
          #endif
        }
      }
      #if os(macOS)
        projectsSection
      #endif
      if !openedFiles.isEmpty {
        Section("Files") {
          Label("Opened Files", systemImage: "doc.on.doc")
            .badge(openedFiles.count)
            .tag(LibraryItem.openedFiles)
        }
      }
      #if os(macOS)
        // On macOS a List hands drops only to its rows (one on the List itself never
        // arrives), so the space under the rows is a row too, taking dropped folders.
        Section {
          Color.clear
            .frame(height: 200)
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
              add(urls.filter(\.isFileURL))
            } isTargeted: { isDropTargeted = $0 }
            .listRowBackground(Color.clear)
            .accessibilityHidden(true)
        }
      #endif
    }
    #if os(macOS)
      .safeAreaInset(edge: .top, spacing: 0) { searchField }
      .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    #endif
    // Outside the insets, so the search field and the bar below take drops too.
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
        if case .folder(let url) = navigator.item, isDeletable(url) { actions.delete(url) }
      }
    #else
      .toolbar {
        ToolbarItem(placement: .primaryAction) { addMenu }
      }
    #endif
    .task(id: CountKey(root: notes.url, generation: library.generation)) { await countAllNotes() }
    .sheet(isPresented: $isConnectingGitHub) { GitHubConnectView() }
    .alert(
      repositories.message?.title ?? "",
      isPresented: Binding(
        get: { repositories.message != nil }, set: { if !$0 { repositories.message = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(repositories.message?.text ?? "")
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
    .navigationTitle("Markdown")
    #if DEBUG && targetEnvironment(simulator)
      .task { addLaunchArgumentFolders() }
    #endif
  }

  // MARK: - Sections

  /// All Notes, the notes folder itself (notes not in a folder) and its folders.
  @ViewBuilder private var notesSection: some View {
    Section {
      if let root = notes.url {
        let _ = library.generation
        Label("All Notes", systemImage: "note.text")
          .badge(allNotesCount ?? 0)
          .tag(LibraryItem.allNotes)
        FileTreeRow(node: FileNode(url: root, isDirectory: true), isRoot: true, title: "Notes", showsChildren: false)
        ForEach(library.children(of: root).filter(\.isDirectory)) { child in
          FileTreeRow(node: child)
        }
      } else {
        ProgressView().frame(maxWidth: .infinity)
      }
    } header: {
      HStack(spacing: 4) {
        Text(notes.isICloud ? "iCloud" : storageName)
        if notes.isICloud {
          Image(systemName: "icloud")
            .help("Notes sync through iCloud to your other devices and to Shell, encrypted.")
        }
      }
    }
  }

  private var storageName: String {
    #if os(macOS)
      "On My Mac"
    #else
      UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"
    #endif
  }

  private var rootFolders: [SidebarFolder] { folders.filter { !$0.isFile } }
  private var openedFiles: [SidebarFolder] { folders.filter(\.isFile) }

  #if os(macOS)
    /// Opens Quick Open: looks like a search field, as in the sidebar of Mail or Notes.
    private var searchField: some View {
      Button {
        window.isQuickOpenShown = true
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
          Text("Search")
          Spacer()
          Text("⌘K")
            .font(.caption)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Find notes, text inside notes and commands (⌘K)")
      .padding(.horizontal, 10)
      .padding(.bottom, 6)
    }

    private var bottomBar: some View {
      HStack {
        addMenu
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
        Spacer()
        if let folder = notes.url {
          // Where the notes are as files, and choosing another folder for them.
          Menu {
            Button("Show Notes Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            Button("Choose Notes Folder…") { chooseNotesFolder() }
          } label: {
            Label(notes.isICloud ? "iCloud" : "On This Mac", systemImage: notes.isICloud ? "checkmark.icloud" : "internaldrive")
              .labelStyle(.titleAndIcon)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .help(
            notes.isICloud
              ? "Notes are files in \(folder.lastPathComponent) and sync through iCloud, encrypted."
              : "Notes are files in \(folder.lastPathComponent) on this Mac. Sign in to iCloud to sync them.")
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .overlay(alignment: .top) { Divider() }
    }
  #endif

  private var addMenu: some View {
    Menu {
      Button("New Folder", systemImage: "folder.badge.plus") { newFolder() }
        .keyboardShortcut("n", modifiers: [.command, .shift])
      Button("Add Folder to Sidebar…", systemImage: "plus.rectangle.on.folder") {
        window.isAddingFolder = true
      }
      .keyboardShortcut("o", modifiers: [.command, .shift])
      Button("Connect GitHub Repository…", systemImage: "arrow.triangle.branch") {
        isConnectingGitHub = true
      }
    } label: {
      #if os(macOS)
        Label("New Folder", systemImage: "plus")
      #else
        Label("Add", systemImage: "folder.badge.plus")
      #endif
    } primaryAction: {
      newFolder()
    }
    .disabled(notes.url == nil)
  }

  // MARK: - Selection

  /// Choosing a sidebar item lists its notes; the shown note stays when it's in the list.
  private var itemBinding: Binding<LibraryItem?> {
    Binding(
      get: { navigator.item },
      set: { item in
        navigator.item = item
        guard let selection = navigator.selection, let item else { return }
        if !contains(item, selection) { navigator.selection = nil }
      })
  }

  private func contains(_ item: LibraryItem, _ url: URL) -> Bool {
    switch item {
    case .allNotes:
      guard let root = notes.url else { return false }
      return url.path.hasPrefix(root.path + "/")
    case .folder(let folder):
      return url.deletingLastPathComponent() == folder
    case .openedFiles:
      return openedFiles.contains { $0.path == url.path }
    }
  }

  // MARK: - All Notes

  private struct CountKey: Equatable {
    var root: URL?
    var generation: Int
  }

  private func countAllNotes() async {
    guard let root = notes.url else { return }
    let count = await Task.detached(priority: .utility) {
      NoteSummaries.allNotes(in: root).count
    }.value
    guard !Task.isCancelled else { return }
    allNotesCount = count
  }

  // MARK: - Actions

  /// Where a new folder goes: the listed folder, otherwise the notes folder.
  private func newFolder() {
    if case .folder(let dir) = navigator.item, FolderLibrary.isDirectory(dir),
      library.root(of: dir, roots: library.roots(folders)) != nil
    {
      actions.newFolder(in: dir)
    } else if let root = notes.url {
      actions.newFolder(in: root)
    }
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

  /// Adds the folders and shows the first new one.
  @discardableResult
  private func add(_ urls: [URL]) -> Bool {
    let added = library.add(urls, existing: folders, context: context)
    if let first = added.first { navigator.open(first) }
    return !added.isEmpty
  }

  #if os(macOS)
    /// Picks the folder the notes are kept in as files (the sandbox needs the user's pick).
    private func chooseNotesFolder() {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.canCreateDirectories = true
      panel.prompt = "Use for Notes"
      panel.message = "Your notes are written to this folder as Markdown files and stay in sync with it."
      guard panel.runModal() == .OK, let folder = panel.url else { return }
      notes.choose(folder)
    }

    /// The projects the v57 apps share (added in Git and the others, through the vault) that aren't
    /// sidebar folders yet, live as they change. The sandbox only opens a folder the user picks, so adding
    /// one shows an open panel on it.
    @ViewBuilder private var projectsSection: some View {
      let added = Set(rootFolders.map { FolderLibrary.canonical(URL(fileURLWithPath: $0.path)).path })
      let projects = Vault.shared.localProjects.filter { project in
        guard let url = project.localURL else { return false }
        return !added.contains(FolderLibrary.canonical(url).path)
      }
      if !projects.isEmpty {
        Section("Projects", isExpanded: $showsProjects) {
          ForEach(projects) { project in
            Button {
              addProject(project)
            } label: {
              Label(project.name, systemImage: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .help("Add “\(project.name)” to the sidebar")
          }
        }
      }
    }

    private func addProject(_ project: VaultProject) {
      guard let url = project.localURL else { return }
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.directoryURL = url
      panel.prompt = "Add"
      panel.message = "Add “\(project.name)” to the sidebar. Markdown opens only folders you choose."
      guard panel.runModal() == .OK, let chosen = panel.url else { return }
      _ = add([chosen])
    }
  #endif
}

/// The rename prompt, the delete confirmation and file-operation errors.
struct FileActionPrompts: ViewModifier {
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
        FileTreeRow(node: FileNode(url: url, isDirectory: true), isRoot: true)
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
      if let url = library.url(for: folder) {
        Button("New Note") { actions.newNote(in: url) }
        Button("New Folder") { actions.newFolder(in: url) }
        Divider()
        #if os(macOS)
          Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        #endif
      }
      Button("Reload") { library.reload() }
      Divider()
      Button("Remove from Sidebar", role: .destructive) {
        remove(folder, library: library, navigator: navigator, context: context)
      }
    }
  }
}

/// A folder in the sidebar: expandable when it has subfolders, with the number of notes
/// in it. Notes dragged onto it move there (files from other apps are copied in).
struct FileTreeRow: View {
  let node: FileNode
  var isRoot = false
  /// Roots only: a count shown beside the name instead of the number of notes (a
  /// repository's local changes), and an operation in progress ("Pulling…").
  var badge: Int?
  var activity: String?
  /// Roots only: shown instead of the folder name ("owner/repository").
  var title: String?
  /// False for the notes folder, whose folders the sidebar lists beside it.
  var showsChildren = true
  var systemImage = "folder"
  @Environment(FolderLibrary.self) private var library
  @Environment(FileActions.self) private var actions
  @Environment(Navigator.self) private var navigator
  @Environment(\.modelContext) private var context
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]
  @State private var isDropTargeted = false

  var body: some View {
    // `generation` re-lists after a reload.
    let _ = library.generation
    let children = library.children(of: node.url)
    let subfolders = showsChildren ? children.filter(\.isDirectory) : []
    if subfolders.isEmpty {
      row(noteCount: children.count - children.filter(\.isDirectory).count)
    } else {
      DisclosureGroup(isExpanded: expandedBinding) {
        ForEach(subfolders) { child in
          FileTreeRow(node: child)
        }
      } label: {
        row(noteCount: children.count - children.filter(\.isDirectory).count)
      }
    }
  }

  private func row(noteCount: Int) -> some View {
    label(Label(title ?? node.name, systemImage: systemImage))
      .badge(badge ?? noteCount)
      .dropDestination(for: URL.self) { urls, _ in drop(urls) } isTargeted: { isDropTargeted = $0 }
      .listRowBackground(
        isDropTargeted ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.2)) : nil)
      .tag(LibraryItem.folder(node.url))
  }

  /// Notes and folders from the app's own folders move here, files from other apps are
  /// copied in. A folder from Finder joins the sidebar instead: the rows cover most of
  /// the sidebar, and dropping a folder on the sidebar means adding it.
  private func drop(_ urls: [URL]) -> Bool {
    let roots = library.roots(folders)
    let urls = urls.filter(\.isFileURL)
    let newFolders = urls.filter {
      ($0.hasDirectoryPath || FolderLibrary.isDirectory($0)) && library.root(of: $0, roots: roots) == nil
    }
    let rest = urls.filter { !newFolders.contains($0) }
    var dropped = false
    if !newFolders.isEmpty {
      let added = library.add(newFolders, existing: folders, context: context)
      if let first = added.first { navigator.open(first) }
      dropped = !added.isEmpty
    }
    if !rest.isEmpty, actions.drop(rest, into: node.url, roots: roots) { dropped = true }
    return dropped
  }

  /// Roots keep their sidebar menu (FolderRootRow); everything inside gets the folder one.
  @ViewBuilder private func label(_ label: some View) -> some View {
    if isRoot {
      HStack {
        label
        if let activity {
          Spacer()
          ProgressView().controlSize(.small).help(activity)
        }
      }
    } else {
      label
        .draggable(node.url)
        .contextMenu { menu }
    }
  }

  @ViewBuilder private var menu: some View {
    Button("New Note") { actions.newNote(in: node.url) }
    Button("New Folder") { actions.newFolder(in: node.url) }
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
@MainActor func remove(
  _ folder: SidebarFolder, library: FolderLibrary, navigator: Navigator, context: ModelContext
) {
  if let url = library.url(for: folder) { navigator.forget(under: url) }
  library.remove(folder, context: context)
}
