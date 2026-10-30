import ComponentKit
import DevScreenshots
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// The library window, in two columns as in the other v57 apps: the sidebar (where notes live,
/// then the notes of the place chosen there) and the open note, or the welcome while none is.
/// Quick Open (⌘K) floats above them. Files and folders opened from Finder or Files
/// ("Open with…", a drop on the Dock icon) open here too.
struct ContentView: View {
  @State private var library: FolderLibrary
  @State private var navigator: Navigator
  @State private var actions: FileActions
  @State private var notes: NotesLocation
  private let vault: Vault
  @State private var github: GitHubAuth
  @State private var repositories: RepositoryStore
  /// The window's account's pinned and recent notes.
  @State private var preferences: NotePreferences
  @State private var window = WindowState()
  /// On iPhone: the column shown, which follows the sidebar's picks.
  @State private var compactColumn = NavigationSplitViewColumn.sidebar
  /// The split's columns, for the kit's sidebar toggles on iPad.
  @State private var columns = NavigationSplitViewVisibility.automatic
  @Environment(\.kitIdiom) private var idiom
  @Environment(\.modelContext) private var context
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]

  /// The window's vault account (`MarkdownWindow`): its notes, GitHub sign-in and connected repositories.
  init(vault: Vault) {
    self.vault = vault
    _notes = State(initialValue: NotesLocation(vault: vault))
    _github = State(initialValue: GitHubAuth(vault: vault))
    _repositories = State(initialValue: RepositoryStore(vault: vault))
    _preferences = State(
      initialValue: NotePreferences(
        defaults: ScreenshotDemo.isOn ? ScreenshotDemo.defaults : .standard, account: vault.accountID))
    let library = FolderLibrary()
    let navigator = Navigator()
    _library = State(initialValue: library)
    _navigator = State(initialValue: navigator)
    _actions = State(initialValue: FileActions(library: library, navigator: navigator))
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
      // On iPhone the note is pushed over the sidebar.
      SidebarView(columnVisibility: idiom == .phone ? nil : $columns) { compactColumn = .detail }
        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
    } detail: {
      NavigationStack {
        DocumentView()
          .modifier(ShowSidebarButton(columns: $columns, isOn: idiom != .phone))
      }
    }
    // Screenshots: every sidebar row built when the scene is ready, not a few a frame as they near the screen.
    .kitLazyLoading(!ScreenshotDemo.isOn)
    .kitPaletteOverlay(isPresented: $window.isQuickOpenShown) { QuickOpenView(perform: perform) }
    #if os(macOS)
      // Each pane names itself with its own rich title.
      .kitHidesSystemTitle()
    #endif
    .modifier(FileActionPrompts())
    .environment(library)
    .environment(navigator)
    .environment(notes)
    .environment(actions)
    .environment(github)
    .environment(repositories)
    .environment(preferences)
    .environment(window)
    .focusedSceneValue(\.windowState, window)
    // The shared projects' folders, which may join the sidebar.
    .onChange(of: SidebarProjects.paths(vault), initial: true) { _, paths in library.projectPaths = paths }
    .task {
      // Screenshots (.dev/screenshots.json): this window opens the later scenes of the launch.
      ScreenshotDemo.openScene = { arguments in
        openScreenshotDemo(arguments)
        await screenshotSceneLoaded()
        showScreenshotPalette()
      }
      window.perform = perform
      repositories.willChangeFiles = { [actions] in actions.willChangeFiles() }
      repositories.didChangeFiles = { [library] in library.reload() }
      actions.didMove = { [preferences] in preferences.replace($0, with: $1) }
      actions.notesFolder = { [notes] in notes.url }
      updateRoots()
      await notes.resolve()
      updateRoots()
      if navigator.item == nil, navigator.selection == nil { navigator.item = .allNotes }
      repositories.refreshChanges()
      if ScreenshotDemo.isOn {
        openScreenshotDemo()
        await screenshotSceneLoaded()
        showScreenshotPalette()
      }
      Screenshots.ready()
    }
    // Notes changed by sync or another app: re-list, and reload the open note.
    .onChange(of: notes.externalChanges) { library.reload() }
    .onChange(of: repositories.repositories) { updateRoots() }
    // Edits saved, files moved: recount the repositories' local changes.
    .onChange(of: library.generation) { repositories.refreshChanges() }
    .onChange(of: navigator.selection) { _, selection in
      follow(selection)
      if selection != nil { compactColumn = .detail }
    }

    .onOpenURL { open($0) }
    // Opened files go to this window instead of a new one each.
    .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
  }

  // MARK: - Navigation

  /// The list follows the shown note: a note from elsewhere (a link, Quick Open, a file
  /// opened from Finder) lists its folder, unless the list already shows it.
  private func follow(_ selection: URL?) {
    guard let selection else { return }
    if FolderLibrary.isDirectory(selection) {
      if navigator.item != .folder(selection) { navigator.item = .folder(selection) }
      return
    }
    preferences.opened(selection)
    let folder = selection.deletingLastPathComponent()
    switch navigator.item {
    case .allNotes:
      if let root = notes.url, selection.path.hasPrefix(root.path + "/") { return }
    case .folder(let listed):
      if listed == folder { return }
    case .openedFiles:
      if isOpenedFile(selection) { return }
    case nil:
      break
    }
    navigator.item = isOpenedFile(selection) ? .openedFiles : .folder(folder)
  }

  private func isOpenedFile(_ url: URL) -> Bool {
    folders.contains { $0.isFile && $0.path == url.path }
  }

  // MARK: - Commands

  /// Quick Open's and the welcome's commands.
  private func perform(_ command: QuickOpenCommand) {
    switch command {
    case .newNote(let name):
      guard let dir = newItemDirectory else { return }
      if navigator.item != .folder(dir), navigator.item != .allNotes { navigator.item = .folder(dir) }
      actions.newNote(in: dir, named: name)
    case .newFolder:
      if let dir = newItemDirectory { actions.newFolder(in: dir) }
    case .welcome:
      // The welcome is the note pane's content while no note is open (on iPhone, pushed over the sidebar).
      navigator.selection = nil
      navigator.item = .allNotes
      if idiom == .phone { compactColumn = .detail }
    }
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

  /// `--screenshot-demo`: the docs project open in the sidebar, and the scene's note and panels; with `arguments`, a later
  /// screenshot scene in this launch, after undoing what the scene before opened.
  private func openScreenshotDemo(_ arguments: [String]? = nil) {
    if let arguments {
      // The same scene in the other appearance: the kit switches that.
      guard arguments != ScreenshotDemo.arguments else { return }
      ScreenshotDemo.arguments = arguments
      window.isQuickOpenShown = false
      navigator.reset()
      preferences.forgetRecents()
      library.expanded.removeAll()
    }
    library.projectPaths = SidebarProjects.paths(vault)
    library.add([ScreenshotDemo.docs], existing: folders, context: context)
    navigator.item = .allNotes
    if let path = ScreenshotDemo.value("--open") {
      navigator.open(FolderLibrary.canonical(ScreenshotDemo.root.appendingPathComponent(path)))
      // Now rather than on the next update, which skips a scene showing the note the one before showed.
      follow(navigator.selection)
    }
  }

  /// `--quick-open`: Quick Open over the scene's note, once the note shows; `--open-sheet`: one of the overlays (on the Mac an editor made as the palette
  /// comes in stays blank under it).
  private func showScreenshotPalette() {
    if ScreenshotDemo.flag("--quick-open") { window.isQuickOpenShown = true }
    guard ScreenshotDemo.isOn, let sheet = ScreenshotDemo.value("--open-sheet") else { return }
    switch sheet {
    case "github": window.isConnectingGitHub = true
    case "rename": if let note = navigator.selection { actions.beginRename(note) }
    case "delete": actions.deleting = navigator.selection
    default: break
    }
  }

  /// Until the sidebar's count, the note list and the document show the scene (at most 10 s), so its picture never
  /// depends on a long delay.
  private func screenshotSceneLoaded() async {
    for _ in 0..<200 {
      let shown = WindowState.Shown(selection: navigator.selection, item: navigator.item)
      if window.hasCountedNotes, window.loadedList == .some(navigator.item), window.loadedDocument == shown { return }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  /// The app's own folders: notes and GitHub repositories.
  private func updateRoots() {
    library.builtInRoots = (notes.url.map { [$0] } ?? []) + repositories.directories
  }

  private func open(_ url: URL) {
    guard url.isFileURL else { return }
    if let shown = library.add([url], existing: folders, context: context).first {
      navigator.open(shown)
    }
  }
}

/// The kit's Show Sidebar button while the sidebar is out (on the Mac and iPad, where it stands in for the split
/// view's own toggle).
private struct ShowSidebarButton: ViewModifier {
  @Binding var columns: NavigationSplitViewVisibility
  let isOn: Bool

  func body(content: Content) -> some View {
    if isOn {
      content.kitSidebarToggle(columnVisibility: $columns)
    } else {
      content
    }
  }
}
