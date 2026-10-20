import ComponentKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// The sidebar: where notes live. All Notes and the notes folder (iCloud Drive or local)
/// with its folders, connected GitHub repositories, folders added by dropping them here
/// (Finder, Files) or with Add Folder (persisted in SwiftData), and files opened on their
/// own. Selecting one lists its notes in the note list. The kit's sidebar: a card per place,
/// and the bar at the bottom (search, new note and folder, the sidebar toggle).
struct SidebarView: View {
  /// On iPhone: picking a place pushes the note list.
  @Binding var compactColumn: NavigationSplitViewColumn
  /// On iPad: the split's columns, for the bar's sidebar toggle.
  var columnVisibility: Binding<NavigationSplitViewVisibility>?
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
  @State private var showsNotesMenu = false
  /// The shared projects section, collapsed until opened (it can be long).
  @AppStorage("showsSharedProjects") private var showsProjects = false
  #if os(macOS) || os(Windows)
    /// The project groups closed in the shared projects section (vault group ids).
    @AppStorage("CollapsedProjectGroups") private var collapsedGroups = CollapsedGroups()
  #endif
  #if os(Windows)
    /// Choose Notes Folder… shows the system's folder picker.
    @State private var isChoosingNotesFolder = false
  #endif

  var body: some View {
    @Bindable var window = window
    KitSidebar(
      selection: itemBinding, searchText: $window.searchQuery, searchPrompt: "Search Notes",
      columnVisibility: columnVisibility
    ) {
      notesSection
      if !repositories.repositories.isEmpty { gitHubSection }
      if !rootFolders.isEmpty { foldersSection }
      #if os(macOS) || os(Windows)
        // The vault's projects are the user's: never in the screenshot demo.
        if !ScreenshotDemo.isOn { projectsSection }
      #endif
      if !openedFiles.isEmpty { filesSection }
    } bottomBar: {
      Button("New Note", systemImage: "square.and.pencil") { newNote() }
        .disabled(notes.url == nil)
        .kitHelp("New Note", shortcut: "⌘N")
      Button("New Folder", systemImage: "folder.badge.plus") { newFolder() }
        .disabled(notes.url == nil)
        .kitHelp("New Folder", shortcut: "⇧⌘N")
    }
    .status { Label(storageStatus, systemImage: notes.isICloud ? "icloud" : deviceSymbol).labelStyle(.titleOnly) }
    // Folders dropped anywhere on the sidebar join it.
    .kitDropTarget(isDropTargeted, cornerRadius: KitMetrics.radiusCard)
    .dropDestination(for: URL.self) { urls, _ in
      add(urls.filter(\.isFileURL))
    } isTargeted: { isDropTargeted = $0 }
    #if os(macOS) || os(Windows)
      .onDeleteCommand {
        if case .folder(let url) = navigator.item, isDeletable(url) { actions.delete(url) }
      }
    #endif
    #if os(Windows)
      .fileImporter(isPresented: $isChoosingNotesFolder, allowedContentTypes: [.folder]) { result in
        if case .success(let folder) = result { notes.choose(folder) }
      }
    #endif
    .task(id: CountKey(root: notes.url, generation: library.generation)) {
      await countAllNotes()
      if !Task.isCancelled { window.hasCountedNotes = true }
    }
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
    // The bottom bar has the toggle; View › Show Sidebar on the Mac, and the note list's Show Sidebar
    // button on iPad, bring it back.
    .toolbar(removing: .sidebarToggle)
    #if DEBUG && targetEnvironment(simulator)
      .task { addLaunchArgumentFolders() }
    #endif
  }

  // MARK: - Sections

  /// All Notes, the notes folder itself (notes not in a folder) and its folders.
  private var notesSection: some View {
    KitSection(
      storageName, meta: notesMeta, systemImage: notes.isICloud ? "icloud" : "doc.text", hue: .blue
    ) {
      if let root = notes.url {
        let _ = library.generation
        SidebarRow(value: LibraryItem.allNotes, "All Notes", systemImage: "note.text") {
          Text("\(allNotesCount ?? 0)")
        }
        FileTreeRow(node: FileNode(url: root, isDirectory: true), isRoot: true, title: "Notes", showsChildren: false)
        ForEach(library.children(of: root).filter(\.isDirectory)) { child in
          FileTreeRow(node: child)
        }
      } else {
        LiveIcon(systemImage: "doc.text", status: .working, size: 18)
          .frame(maxWidth: .infinity, minHeight: 32)
      }
    } accessory: {
      notesMenu
    }
    .help(
      notes.isICloud
        ? "Notes are files in \(notes.url?.lastPathComponent ?? "Notes") and sync through iCloud, encrypted."
        : "Notes are plain files on this \(deviceName).")
  }

  private var notesMeta: [String] {
    let count = allNotesCount.map { $0 == 1 ? "1 note" : "\($0) notes" }
    return [count ?? "", notes.isICloud ? "iCloud" : "plain files"]
  }

  /// New notes and folders, and (on the Mac) where the notes are as files.
  private var notesMenu: some View {
    Button("Add", systemImage: "plus") { showsNotesMenu = true }
      .labelStyle(.iconOnly)
      .kitMenu(isPresented: $showsNotesMenu) {
        Button("New Note", systemImage: "square.and.pencil") { newNote() }
        Button("New Folder", systemImage: "folder.badge.plus") { newFolder() }
        Divider()
        Button("Add Folder to Sidebar…", systemImage: "plus.rectangle.on.folder") { window.isAddingFolder = true }
        Button("Connect GitHub Repository…", systemImage: "arrow.triangle.branch") { isConnectingGitHub = true }
        #if os(macOS) || os(Windows)
          if let folder = notes.url {
            Divider()
            Button("Show Notes Folder in \(KitDesktop.fileManagerName)", systemImage: "folder") {
              KitDesktop.reveal([folder])
            }
            Button("Choose Notes Folder…", systemImage: "folder.badge.gearshape") { chooseNotesFolder() }
          }
        #endif
      }
      .disabled(notes.url == nil)
  }

  private var gitHubSection: some View {
    let changes = repositories.changeCounts.values.reduce(0, +)
    let count = repositories.repositories.count
    return KitSection(
      "GitHub",
      meta: [count == 1 ? "1 repository" : "\(count) repositories", changes == 0 ? "" : "\(changes) to push"],
      systemImage: "arrow.triangle.branch", hue: .purple,
      status: repositories.activity.isEmpty ? .idle : .working
    ) {
      ForEach(repositories.repositories, id: \.fullName) { repository in
        RepositoryRow(repository: repository)
      }
    } accessory: {
      Button("Connect GitHub Repository…", systemImage: "plus") { isConnectingGitHub = true }
        .labelStyle(.iconOnly)
    }
  }

  private var foldersSection: some View {
    let names = rootFolders.map(\.name)
    return KitSection(
      "Folders", meta: names.count == 1 ? names : ["\(names.count) folders"], systemImage: "folder", hue: .teal
    ) {
      ForEach(rootFolders) { folder in
        FolderRootRow(folder: folder)
      }
    } accessory: {
      Button("Add Folder to Sidebar…", systemImage: "plus") { window.isAddingFolder = true }
        .labelStyle(.iconOnly)
    }
  }

  private var filesSection: some View {
    KitSection("Files", meta: "opened on their own", systemImage: "doc.on.doc", hue: .gray) {
      SidebarRow(value: LibraryItem.openedFiles, "Opened Files", systemImage: "doc.on.doc") {
        Text("\(openedFiles.count)")
      }
    }
  }

  private var storageName: String { "On My \(KitDevice.name)" }

  /// Where the notes are, at the start of the bottom bar.
  private var storageStatus: String { notes.isICloud ? "iCloud" : "On This \(deviceName)" }

  private var deviceSymbol: String { KitDevice.systemImage }

  private var deviceName: String { KitDevice.name }

  private var rootFolders: [SidebarFolder] { folders.filter { !$0.isFile } }
  private var openedFiles: [SidebarFolder] { folders.filter(\.isFile) }

  // MARK: - Selection

  /// Choosing a sidebar item lists its notes; the shown note stays when it's in the list.
  private var itemBinding: Binding<LibraryItem?> {
    Binding(
      get: { navigator.item },
      set: { item in
        navigator.item = item
        if item != nil { compactColumn = .content }
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

  /// A new note in the listed folder, otherwise in the notes folder.
  private func newNote() {
    guard let dir = newItemDirectory else { return }
    if navigator.item == nil || navigator.item == .openedFiles { navigator.item = .folder(dir) }
    actions.newNote(in: dir)
  }

  /// The listed folder when the app can write there, otherwise the notes folder.
  private var newItemDirectory: URL? {
    if case .folder(let dir) = navigator.item, FolderLibrary.isDirectory(dir),
      library.root(of: dir, roots: library.roots(folders)) != nil
    {
      return dir
    }
    return notes.url
  }

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

  #if os(macOS) || os(Windows)
    /// Picks the folder the notes are kept in as files (the sandbox needs the user's pick).
    private func chooseNotesFolder() {
      #if os(Windows)
        isChoosingNotesFolder = true
      #else
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for Notes"
        panel.message = "Your notes are written to this folder as Markdown files and stay in sync with it."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        notes.choose(folder)
      #endif
    }

    /// The projects the v57 apps share (added in Git and the others, through the vault) that aren't
    /// sidebar folders yet, in the vault's groups, live as they change. A group opens and closes; which are
    /// closed is Markdown's own. The sandbox only opens a folder the user picks, so adding a project shows an
    /// open panel on it.
    @ViewBuilder private var projectsSection: some View {
      let added = Set(rootFolders.map { FolderLibrary.canonical(URL(fileURLWithPath: $0.path)).path })
      let tree = Vault.shared.localProjectTree.filter { project in
        guard let url = project.localURL else { return false }
        return !added.contains(FolderLibrary.canonical(url).path)
      }
      let count = tree.projects().count
      if count > 0 {
        let rows = projectRows(tree)
        let hasGroups = !tree.groups.isEmpty
        KitSection(
          "Projects", meta: count == 1 ? "1 shared project" : "\(count) shared projects",
          systemImage: "square.stack", hue: .indigo, isExpanded: $showsProjects
        ) {
          ForEach(rows) { row in
            Group {
              switch row.node {
              case .group(let group, _):
                let isOpen = !collapsedGroups.ids.contains(group.id)
                SidebarRow(
                  group.name, subtitle: group.note?.isEmpty == false ? group.note : nil,
                  systemImage: isOpen ? "folder.fill" : "folder", hue: StableHue.pick(group.name)
                )
                .disclosure(isExpanded: groupIsExpanded(group.id))
                .action { withAnimation(.kit) { toggleGroup(group.id) } }
                .help(row.node.projects.count == 1 ? "1 project" : "\(row.node.projects.count) projects")
              case .project(let project):
                // Not a place to list: a tap asks for the folder and adds it.
                projectRow(project)
                  .disclosureSlot(hasGroups)
                  .action { addProject(project) }
                  .help("Add “\(project.name)” to the sidebar")
              }
            }
            .kitRowIndent(row.depth)
          }
        }
        .animation(.kit, value: rows.map(\.id))
      }
    }

    /// A shared project: its app icon from the vault (Code and Dev find them), else the add-folder tile.
    private func projectRow(_ project: VaultProject) -> SidebarRow<some View, EmptyView> {
      SidebarRow(project.name) {
        if let icon = project.icon.flatMap(Image.init(data:)) {
          Avatar(name: project.name, image: icon, kind: .thing, size: 18)
        } else {
          RowTile(systemImage: "folder.badge.plus")
        }
      }
    }

    /// The tree top to bottom, each item with how many groups it is in, without what closed groups hold.
    private func projectRows(_ tree: VaultProjectTree) -> [ProjectRow] {
      func rows(_ nodes: [VaultProjectTree.Node], depth: Int) -> [ProjectRow] {
        nodes.flatMap { node in
          let isOpen = node.group != nil && !collapsedGroups.ids.contains(node.id)
          return [ProjectRow(node: node, depth: depth)] + (isOpen ? rows(node.children, depth: depth + 1) : [])
        }
      }
      return rows(tree.roots, depth: 0)
    }

    private func groupIsExpanded(_ id: String) -> Binding<Bool> {
      Binding(
        get: { !collapsedGroups.ids.contains(id) },
        set: { if $0 == collapsedGroups.ids.contains(id) { toggleGroup(id) } })
    }

    private func toggleGroup(_ id: String) {
      if collapsedGroups.ids.contains(id) { collapsedGroups.ids.remove(id) } else { collapsedGroups.ids.insert(id) }
    }

    private func addProject(_ project: VaultProject) {
      guard let url = project.localURL else { return }
      #if os(Windows)
        // No sandbox: the project's folder is the one to add.
        _ = add([url])
      #else
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = url
        panel.prompt = "Add"
        panel.message = "Add “\(project.name)” to the sidebar. Markdown opens only folders you choose."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        _ = add([chosen])
      #endif
    }
  #endif
}

/// A row of the shared projects section: a group or a project, and how many groups it is in.
private struct ProjectRow: Identifiable {
  let node: VaultProjectTree.Node
  let depth: Int
  var id: String { node.id }
}

/// The ids of the closed groups, kept in one defaults string.
struct CollapsedGroups: RawRepresentable {
  var ids: Set<String>

  init() { ids = [] }

  init(rawValue: String) {
    ids = Set(rawValue.split(separator: "\n").map(String.init))
  }

  var rawValue: String { ids.sorted().joined(separator: "\n") }
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
        FileTreeRow(node: FileNode(url: url, isDirectory: true), isRoot: true, icon: projectIcon(url))
      } else {
        SidebarRow(folder.name, subtitle: "Can’t be found", systemImage: "exclamationmark.triangle", hue: .yellow)
          .help("\(folder.path) can’t be found. It may have been moved or deleted.")
      }
    }
    // On the folder and the folders inside it, whose own menus win.
    .kitContextMenu { menu }
  }

  /// The app icon of the vault's project in this folder, when it is one (Code and Dev find them).
  private func projectIcon(_ url: URL) -> Data? {
    let path = FolderLibrary.canonical(url).path
    return Vault.shared.localProjects.first { project in
      project.localURL.map { FolderLibrary.canonical($0).path } == path
    }?.icon
  }

  @ViewBuilder private var menu: some View {
    if let url = library.url(for: folder) {
      Button("New Note", systemImage: "square.and.pencil") { actions.newNote(in: url) }
      Button("New Folder", systemImage: "folder.badge.plus") { actions.newFolder(in: url) }
      Divider()
      #if os(macOS) || os(Windows)
        Button("Show in \(KitDesktop.fileManagerName)", systemImage: "folder") { KitDesktop.reveal([url]) }
      #endif
      OtherPlacesMenu(root: url)
    }
    Button("Reload", systemImage: "arrow.clockwise") { library.reload() }
    Divider()
    Button("Remove from Sidebar", systemImage: "minus.circle", role: .destructive) {
      remove(folder, library: library, navigator: navigator, context: context)
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
  /// Roots only: the PNG of the app icon of the vault's project in the folder, shown instead of the folder tile.
  var icon: Data?
  @Environment(FolderLibrary.self) private var library
  @Environment(FileActions.self) private var actions
  @Environment(Navigator.self) private var navigator
  @Environment(\.modelContext) private var context
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]
  @State private var isDropTargeted = false

  /// How deep in the sidebar's tree the folder is (its root is 0).
  var depth = 0

  var body: some View {
    // `generation` re-lists after a reload.
    let _ = library.generation
    let children = library.children(of: node.url)
    let subfolders = showsChildren ? children.filter(\.isDirectory) : []
    row(noteCount: children.count - children.filter(\.isDirectory).count, isExpandable: !subfolders.isEmpty)
    if isExpanded.wrappedValue {
      ForEach(subfolders) { child in
        FileTreeRow(node: child, depth: depth + 1)
      }
    }
  }

  private func row(noteCount: Int, isExpandable: Bool) -> some View {
    label(
      SidebarRow(
        value: LibraryItem.folder(node.url), title ?? node.name, isExpanded: isExpandable ? isExpanded : nil
      ) {
        if let image = icon.flatMap(Image.init(data:)) {
          Avatar(name: title ?? node.name, image: image, kind: .thing, size: 18)
        } else {
          RowTile(systemImage: systemImage)
        }
      } trailing: {
        if let activity {
          LiveIcon(systemImage: "arrow.down", status: .working, size: 16).help(activity)
        } else {
          Text("\(badge ?? noteCount)")
        }
      }
      .kitRowIndent(depth)
    )
    .kitDropTarget(isDropTargeted)
    .dropDestination(for: URL.self) { urls, _ in drop(urls) } isTargeted: { isDropTargeted = $0 }
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

  /// Roots keep their sidebar menu (FolderRootRow, RepositoryRow); everything inside gets the folder one.
  @ViewBuilder private func label(_ label: some View) -> some View {
    if isRoot {
      label
    } else {
      label
        .draggable(node.url)
        .kitContextMenu { menu }
    }
  }

  @ViewBuilder private var menu: some View {
    Button("New Note", systemImage: "square.and.pencil") { actions.newNote(in: node.url) }
    Button("New Folder", systemImage: "folder.badge.plus") { actions.newFolder(in: node.url) }
    Divider()
    Button("Rename…", systemImage: "pencil") { actions.beginRename(node.url) }
    #if os(macOS) || os(Windows)
      Button("Show in \(KitDesktop.fileManagerName)", systemImage: "folder") { KitDesktop.reveal([node.url]) }
    #endif
    Divider()
    #if os(macOS)
      Button("Move to Trash", systemImage: "trash", role: .destructive) { actions.delete(node.url) }
    #else
      Button("Delete…", systemImage: "trash", role: .destructive) { actions.delete(node.url) }
    #endif
  }

  /// Opens and closes the folder's subfolders (the row's disclosure chevron, ← →).
  private var isExpanded: Binding<Bool> {
    Binding(
      get: { library.expanded.contains(node.url) },
      set: { open in
        if open { library.expanded.insert(node.url) } else { library.expanded.remove(node.url) }
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
