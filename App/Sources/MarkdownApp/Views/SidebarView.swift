import ComponentKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VaultKit
import VaultUI

/// The sidebar: where notes live. All Notes and the notes folder with its folders, connected GitHub repositories,
/// the projects the v57 apps share (on the Mac and Windows; a project's folder joins once the user grants it), and
/// files opened on their own. Choosing a place lists its notes right under its row (`PlaceNotes`), and the note picked
/// there shows beside it. The kit's sidebar: a card per kind of place, the search results while searching, and the bar
/// at the bottom (search, new note and folder, the sidebar toggle).
struct SidebarView: View {
  /// The split's columns, for the bar's sidebar toggle (nil on iPhone, where the note is pushed).
  var columnVisibility: Binding<NavigationSplitViewVisibility>?
  /// On iPhone: shows the note column, also for the note already shown before going back.
  var showsNote: () -> Void = {}
  @State private var list = NoteListModel()
  /// The window's account (Personal outside a `VaultAccountScope`, as in the screenshot demo).
  @Environment(\.vault) private var windowVault
  @Environment(FolderLibrary.self) private var library
  @Environment(Navigator.self) private var navigator
  @Environment(NotesLocation.self) private var notes
  @Environment(FileActions.self) private var actions
  @Environment(RepositoryStore.self) private var repositories
  @Environment(WindowState.self) private var window
  @Environment(\.modelContext) private var context
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]
  @State private var isDropTargeted = false
  @State private var allNotesCount: Int?
  @State private var showsNotesMenu = false
  @AppStorage(NoteSort.key) private var sortsByTitle = false
  /// The shared projects section, collapsed until opened (it can be long).
  @AppStorage("showsSharedProjects") private var showsProjects = false
  #if os(macOS) || os(Windows)
    /// The project groups closed in the shared projects section (vault group ids).
    @AppStorage("CollapsedProjectGroups") private var collapsedGroups = KitIDSet()
    /// The shared projects and groups removed from the list (vault ids): Markdown's own, the other apps keep them.
    /// Adding a project's folder again brings it back.
    @AppStorage("RemovedProjects") private var removedProjects = KitIDSet()
    @State private var confirmsRemoveAll = false
  #endif
  #if os(Windows)
    /// Choose Notes Folder… shows the system's folder picker.
    @State private var isChoosingNotesFolder = false
  #endif

  var body: some View {
    @Bindable var window = window
    KitSidebar(
      selection: noteSelection, searchText: $window.searchQuery, searchPrompt: "Search Notes",
      columnVisibility: columnVisibility
    ) {
      // The window's account, while there is more than Personal.
      VaultAccountPicker(meta: allNotesCount.map { $0 == 1 ? "1 note" : "\($0) notes" })
      // A place with many folders keeps its title in view while they scroll by.
      notesSection.kitSticky()
      if !repositories.repositories.isEmpty { gitHubSection.kitSticky() }
      #if os(macOS) || os(Windows)
        projectsSection.kitSticky()
      #endif
      if !openedFiles.isEmpty { filesSection }
      NoteSearchSection()
    } bottomBar: {
      Button("New Note", systemImage: "square.and.pencil") { newNote() }
        .disabled(notes.url == nil)
        .kitHelp("New Note", shortcut: "⌘N")
      Button("New Folder", systemImage: "folder.badge.plus") { newFolder() }
        .disabled(notes.url == nil)
        .kitHelp("New Folder", shortcut: "⇧⌘N")
    }
    .status { Label(storageStatus, systemImage: notes.isICloud ? "icloud" : deviceSymbol).labelStyle(.titleOnly) }
    .environment(list)
    // Files dropped anywhere on the sidebar join it (and a shared project's folder, its access).
    .kitDropTarget(isDropTargeted, cornerRadius: KitMetrics.radiusCard)
    .dropDestination(for: URL.self) { urls, _ in
      add(urls.filter(\.isFileURL))
    } isTargeted: { isDropTargeted = $0 }
    #if os(macOS) || os(Windows)
      .onDeleteCommand {
        if let url = noteSelection.wrappedValue, isDeletable(url) { actions.delete(url) }
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
    .task(id: ListKey(item: navigator.item, generation: library.generation)) {
      let item = navigator.item
      await list.load(item, library: library, notes: notes, folders: folders)
      if !Task.isCancelled { window.loadedList = .some(item) }
    }
    .task(id: window.searchQuery) {
      await list.search(
        window.searchQuery,
        scope: SearchScope(library: library, notes: notes, repositories: repositories, folders: folders))
    }
    .kitSheet(isPresented: $window.isConnectingGitHub) { GitHubConnectView() }
    .kitNotice(
      repositories.message?.title ?? "",
      message: Binding(get: { repositories.message?.text }, set: { if $0 == nil { repositories.message = nil } }),
      systemImage: "arrow.triangle.branch", hue: .purple)
    .kitNotice("Couldn’t Add Folder", message: Bindable(library).lastError)
    .navigationTitle("Markdown")
    // The bottom bar has the toggle; the note's Show Sidebar button brings it back.
    .toolbar(removing: .sidebarToggle)
  }

  // MARK: - Sections

  /// All Notes, the notes folder itself (notes not in a folder) and its folders.
  private var notesSection: some View {
    KitSection(
      storageName, meta: notesMeta, systemImage: notes.isICloud ? "icloud" : "doc.text", hue: .blue
    ) {
      if let root = notes.url {
        let _ = library.generation
        SidebarRow("All Notes", systemImage: "note.text") {
          Text("\(allNotesCount ?? 0)")
        }
        .place(.allNotes)
        PlaceNotes(item: .allNotes).kitRowIndent(1)
        FileTreeRow(node: FileNode(url: root, isDirectory: true), isRoot: true, title: "Notes", showsChildren: false)
        ForEach(library.children(of: root).filter(\.isDirectory)) { child in
          FileTreeRow(node: child)
        }
      } else {
        EmptyState(systemImage: "doc.text", title: "Loading Notes", status: .working)
      }
    } accessory: {
      notesMenu
    }
    .help(
      notes.isICloud
        ? "Notes are files in \(notes.url?.lastPathComponent ?? "Notes") and sync through iCloud, encrypted."
        : "Notes are plain files on this \(KitDevice.nameInSentence).")
  }

  private var notesMeta: [String] {
    let count = allNotesCount.map { $0 == 1 ? "1 note" : "\($0) notes" }
    return [count ?? "", notes.isICloud ? "iCloud" : "plain files"]
  }

  /// New notes and folders, how notes are sorted, and (on the Mac) where the notes are as files.
  private var notesMenu: some View {
    Button("Add", systemImage: "plus") { showsNotesMenu = true }
      .labelStyle(.iconOnly)
      .kitHelp("Add", meta: "A note, a folder or a GitHub repository")
      .kitMenu(isPresented: $showsNotesMenu) {
        Button("New Note", systemImage: "square.and.pencil") { newNote() }
        Button("New Folder", systemImage: "folder.badge.plus") { newFolder() }
        Button("Connect GitHub Repository…", systemImage: "arrow.triangle.branch") { window.isConnectingGitHub = true }
        KitMenuSection("Sort Notes By") {
          KitMenuOptions(selection: $sortsByTitle, options: [("Date Edited", false), ("Title", true)])
        }
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
      Button("Connect GitHub Repository…", systemImage: "plus") { window.isConnectingGitHub = true }
        .labelStyle(.iconOnly)
        .kitHelp("Connect GitHub Repository…")
    }
  }

  private var filesSection: some View {
    KitSection("Files", meta: "opened on their own", systemImage: "doc.on.doc", hue: .gray) {
      SidebarRow("Opened Files", systemImage: "doc.on.doc") {
        Text("\(openedFiles.count)")
      }
      .place(.openedFiles)
      PlaceNotes(item: .openedFiles).kitRowIndent(1)
    }
  }

  private var storageName: String { "On My \(KitDevice.name)" }

  /// Where the notes are, at the start of the bottom bar.
  private var storageStatus: String { notes.isICloud ? "iCloud" : "On This \(deviceName)" }

  private var deviceSymbol: String { KitDevice.systemImage }

  private var deviceName: String { KitDevice.name }

  private var openedFiles: [SidebarFolder] { folders.filter(\.isFile) }

  // MARK: - Selection

  /// The sidebar's selection is the shown note (not a folder shown by its README); the places are rows that list
  /// their notes (`place(_:)`).
  private var noteSelection: Binding<URL?> {
    Binding(
      get: {
        guard let selection = navigator.selection, !FolderLibrary.isDirectory(selection) else { return nil }
        return selection
      },
      set: { url in
        guard let url else { return }
        navigator.selection = url
        showsNote()
      })
  }

  // MARK: - All Notes

  private struct CountKey: Equatable {
    var root: URL?
    var generation: Int
  }

  private struct ListKey: Equatable {
    var item: LibraryItem?
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

  /// Adds dropped files (and a shared project's folder) and shows the first.
  @discardableResult
  private func add(_ urls: [URL]) -> Bool {
    let added = library.add(urls, existing: folders, context: context)
    #if os(macOS) || os(Windows)
      restoreProjects(at: added)
    #endif
    if let first = added.first { navigator.open(first) }
    return !added.isEmpty
  }

  #if os(macOS) || os(Windows)
    /// Picks the folder the notes are kept in as files (the sandbox needs the user's pick).
    private func chooseNotesFolder() {
      #if os(Windows)
        isChoosingNotesFolder = true
      #else
        Task {
          guard
            let folder = await KitDesktop.chooseFolders(
              prompt: "Use for Notes",
              message: "Your notes are written to this folder as Markdown files and stay in sync with it.",
              canCreateDirectories: true
            ).first
          else { return }
          notes.choose(folder)
        }
      #endif
    }

    /// The projects the v57 apps share (added in Code, Git and the others, through the vault), in the vault's groups,
    /// live as they change. A project the app may open lists its folders and notes as the notes folder does; the
    /// sandbox only opens a folder the user picks, so a tap on another shows an open panel on it. A group opens and
    /// closes; which are closed is Markdown's own.
    @ViewBuilder private var projectsSection: some View {
      let tree = listedProjects(SidebarProjects.tree(windowVault ?? .shared))
      let count = tree.projects().count
      if count > 0 {
        let hasGroups = !tree.groups.isEmpty
        KitSection(
          "Projects", meta: count == 1 ? "1 shared project" : "\(count) shared projects",
          systemImage: "square.stack", hue: .indigo, isExpanded: $showsProjects
        ) {
          if hasGroups {
            // Groups open and close (a click on the row or its chevron); projects keep the chevron's slot.
            KitOutline(tree.roots, children: { $0.group == nil ? nil : $0.children }, collapsed: $collapsedGroups.ids) {
              projectNodeRow($0)
            }
          } else {
            ForEach(tree.roots) { projectNodeRow($0) }
          }
        }
        .headerMenu {
          Button("Remove All Projects from List", systemImage: "minus.circle") { confirmsRemoveAll = true }
        }
        .animation(.kit, value: Self.ids(tree.roots))
        .kitConfirmation(
          count == 1 ? "Remove 1 project from the list?" : "Remove all \(count) projects from the list?", isPresented: $confirmsRemoveAll,
          message: "Their folders stay on disk, and the other v57 apps keep them. Adding a folder again brings it back.",
          systemImage: "minus.circle", confirm: "Remove All"
        ) {
          withAnimation(.kit) { removeProjects(tree.projects().map(\.id), closing: tree.projects()) }
        }
      }
    }

    /// The shared projects without the ones removed from the list, alone or with a group they are in.
    private func listedProjects(_ tree: VaultProjectTree) -> VaultProjectTree {
      let removed = removedProjects.ids
      guard !removed.isEmpty else { return tree }
      return tree.filter { project in
        !removed.contains(project.id) && !tree.ancestors(of: project.id).contains { removed.contains($0.id) }
      }
    }

    /// Removes projects and groups (vault ids) from the list, and closes the open ones among `projects`.
    private func removeProjects(_ ids: [String], closing projects: [VaultProject]) {
      for folder in projects.compactMap(sidebarFolder(of:)) {
        remove(folder, library: library, navigator: navigator, context: context)
      }
      removedProjects.ids.formUnion(ids)
    }

    /// Brings back the removed projects whose folders were just added, with the groups they are in.
    private func restoreProjects(at urls: [URL]) {
      guard !removedProjects.ids.isEmpty else { return }
      let tree = SidebarProjects.tree(windowVault ?? .shared)
      let paths = Set(urls.map { FolderLibrary.canonical($0).path })
      for project in tree.projects() {
        guard let url = SidebarProjects.url(of: project), paths.contains(FolderLibrary.canonical(url).path) else {
          continue
        }
        removedProjects.ids.subtract([project.id] + tree.ancestors(of: project.id).map(\.id))
      }
    }

    /// The sidebar folder that gives the app the project's folder, once the user picked it.
    private func sidebarFolder(of project: VaultProject) -> SidebarFolder? {
      guard let url = SidebarProjects.url(of: project) else { return nil }
      let path = FolderLibrary.canonical(url).path
      return folders.first { !$0.isFile && $0.path == path }
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

    /// A group (it opens and closes in the outline) or a project: open in the sidebar with its folder's tree, or a
    /// row that asks for its folder.
    @ViewBuilder private func projectNodeRow(_ node: VaultProjectTree.Node) -> some View {
      switch node {
      case .group(let group, _):
        let count = node.projects.count
        SidebarRow(
          group.name, subtitle: group.note?.isEmpty == false ? group.note : nil,
          systemImage: collapsedGroups.contains(group.id) ? "folder" : "folder.fill", hue: StableHue.pick(group.name)
        )
        .kitHelp(group.name, meta: count == 1 ? "1 project" : "\(count) projects", systemImage: "folder")
        .kitContextMenu {
          Button("Remove Group from List", systemImage: "minus.circle") {
            withAnimation(.kit) { removeProjects([group.id], closing: node.projects) }
          }
        }
      case .project(let project):
        if let folder = sidebarFolder(of: project) {
          FolderRootRow(folder: folder, title: project.name, icon: project.icon)
        } else {
          // Not open yet: a tap asks for the folder.
          projectRow(project)
            .action { addProject(project) }
            .kitHelp(project.name, meta: "Open “\(project.name)” in Markdown")
        }
      }
    }

    /// Every group and project id in the tree, for the list's animation.
    private static func ids(_ nodes: [VaultProjectTree.Node]) -> [String] {
      nodes.flatMap { [$0.id] + ids($0.children) }
    }

    private func addProject(_ project: VaultProject) {
      guard let url = SidebarProjects.url(of: project) else { return }
      #if os(Windows)
        // No sandbox: the project's folder is the one to add.
        _ = add([url])
      #else
        Task {
          guard
            let chosen = await KitDesktop.chooseFolders(
              prompt: "Open", message: "Open “\(project.name)” in Markdown. Markdown opens only folders you choose.",
              directory: url
            ).first
          else { return }
          _ = add([chosen])
        }
      #endif
    }
  #endif
}

/// The rename prompt, the delete confirmation and file-operation errors, as the kit's sheets (over the window on the
/// Mac and iPad).
struct FileActionPrompts: ViewModifier {
  @Environment(FileActions.self) private var actions

  func body(content: Content) -> some View {
    @Bindable var actions = actions
    content
      // A rename from the document's menu (or of a new folder); the sidebar rows' own menus rename in the row.
      .kitPrompt(
        "Rename",
        isPresented: Binding(
          get: { actions.renaming != nil && !actions.renamesInPlace }, set: { if !$0 { actions.renaming = nil } }),
        text: $actions.newName, message: actions.renaming.map { "“\($0.lastPathComponent)”" },
        field: KitPromptField("Name", systemImage: "doc.text"), confirm: "Rename"
      ) { _ in
        actions.commitRename()
      }
      .kitConfirmation(
        "Delete “\(actions.deleting?.lastPathComponent ?? "")”?",
        isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } }),
        message: "This can’t be undone.", systemImage: "trash", confirm: "Delete"
      ) {
        actions.confirmDelete()
      }
      .kitNotice("Couldn’t Complete the Action", message: $actions.error)
  }
}

extension View {
  /// Renames `url` in this sidebar row while a rename of it began from the row's menu (`beginRename(_:inPlace:)`).
  func renamesInPlace(_ url: URL, actions: FileActions) -> some View {
    kitRename(
      isRenaming: Binding(
        get: { actions.renamesInPlace && actions.renaming == url },
        set: { if !$0, actions.renaming == url { actions.renaming = nil } }),
      text: Binding(get: { actions.newName }, set: { actions.newName = $0 })
    ) {
      actions.commitRename()
    }
  }
}

/// A shared project the app may open: its folder's tree, or a placeholder when the folder can no longer be reached.
private struct FolderRootRow: View {
  let folder: SidebarFolder
  let title: String
  /// The project's app icon (Code and Dev find them), shown instead of the folder tile.
  let icon: Data?
  @Environment(FolderLibrary.self) private var library
  @Environment(Navigator.self) private var navigator
  @Environment(FileActions.self) private var actions
  @Environment(\.modelContext) private var context

  var body: some View {
    Group {
      if let url = library.url(for: folder) {
        FileTreeRow(node: FileNode(url: url, isDirectory: true), isRoot: true, title: title, icon: icon)
      } else {
        SidebarRow(title, subtitle: "Can’t be found", systemImage: "exclamationmark.triangle", hue: .yellow)
          .kitHelp(
            title, meta: "\(folder.path) can’t be found. It may have been moved or deleted.",
            systemImage: "exclamationmark.triangle", hue: .yellow)
      }
    }
    // On the folder and the folders inside it, whose own menus win.
    .kitContextMenu { menu }
  }

  @ViewBuilder private var menu: some View {
    if let url = library.url(for: folder) {
      Button("New Note", systemImage: "square.and.pencil") { actions.newNote(in: url) }
      Button("New Folder", systemImage: "folder.badge.plus") { actions.newFolder(in: url) }
      Divider()
      #if os(macOS) || os(Windows)
        Button("Show in \(KitDesktop.fileManagerName)", systemImage: "folder") { KitDesktop.reveal([url]) }
      #endif
      VaultOtherPlacesMenu(root: url)
    }
    Button("Reload", systemImage: "arrow.clockwise") { library.reload() }
    Divider()
    // The project stays listed; opening it again asks for the folder.
    Button("Close Project", systemImage: "minus.circle") {
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
  /// How deep in the sidebar's tree the folder is (its root is 0): a project group's outline sets it, and each folder
  /// puts its notes and subfolders one level deeper.
  @Environment(\.kitRowIndentLevel) private var depth

  var body: some View {
    // `generation` re-lists after a reload.
    let _ = library.generation
    let children = library.children(of: node.url)
    let subfolders = showsChildren ? children.filter(\.isDirectory) : []
    row(noteCount: children.count - children.filter(\.isDirectory).count, isExpandable: !subfolders.isEmpty)
    PlaceNotes(item: .folder(node.url)).kitRowIndent(depth + 1)
    if isExpanded.wrappedValue {
      ForEach(subfolders) { child in
        FileTreeRow(node: child).kitRowIndent(depth + 1)
      }
    }
  }

  private func row(noteCount: Int, isExpandable: Bool) -> some View {
    label(
      SidebarRow(title ?? node.name, isExpanded: isExpandable ? isExpanded : nil) {
        if let image = icon.flatMap(Image.init(data:)) {
          Avatar(name: title ?? node.name, image: image, kind: .thing, size: 18)
        } else {
          RowTile(systemImage: systemImage)
        }
      } trailing: {
        if let activity {
          LiveIcon(systemImage: "arrow.down", status: .working, size: 16)
            .kitHelp(activity, systemImage: "arrow.down", status: .working)
        } else {
          Text("\(badge ?? noteCount)")
        }
      }
      .place(.folder(node.url))
      .renamesInPlace(node.url, actions: actions)
    )
    .kitDropTarget(isDropTargeted)
    .dropDestination(for: URL.self) { urls, _ in drop(urls) } isTargeted: { isDropTargeted = $0 }
  }

  /// Notes and folders from the app's own folders move here, files from other apps are
  /// copied in. A shared project's folder from Finder opens in the sidebar instead (its access): the rows cover most
  /// of the sidebar, and dropping such a folder on the sidebar means opening it.
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

  /// Roots keep their own menu (FolderRootRow, RepositoryRow); everything inside gets the folder one.
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
    Button("Rename…", systemImage: "pencil") { actions.beginRename(node.url, inPlace: true) }
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

extension SidebarRow {
  /// A place: the current row while its notes are listed below it, and a click (a tap) lists them.
  func place(_ item: LibraryItem) -> some View { PlaceRow(row: self, item: item) }
}

private struct PlaceRow<Icon: View, Trailing: View>: View {
  let row: SidebarRow<Icon, Trailing>
  let item: LibraryItem
  @Environment(Navigator.self) private var navigator
  @Environment(NotesLocation.self) private var notes
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]

  var body: some View {
    row
      .isCurrent(navigator.item == item)
      .action {
        navigator.choose(item, notesFolder: notes.url, openedFiles: Set(folders.filter(\.isFile).map(\.path)))
      }
  }
}

/// Removes a folder or an opened file from the sidebar (never from disk) and forgets what was shown from it.
@MainActor func remove(
  _ folder: SidebarFolder, library: FolderLibrary, navigator: Navigator, context: ModelContext
) {
  if let url = library.url(for: folder) { navigator.forget(under: url) }
  library.remove(folder, context: context)
}
