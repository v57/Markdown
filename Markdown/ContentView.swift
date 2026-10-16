import ComponentKit
import DevScreenshots
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The library window, in three columns as in Notes: where notes live (sidebar), the
/// notes there (list), the open note (detail). Quick Open (⌘K) floats above them and the
/// welcome sheet opens with the window. Files and folders opened from Finder or Files
/// ("Open with…", a drop on the Dock icon) open here too.
struct ContentView: View {
  @State private var library: FolderLibrary
  @State private var navigator: Navigator
  @State private var actions: FileActions
  @State private var notes = NotesLocation()
  @State private var github = GitHubAuth()
  @State private var repositories = RepositoryStore()
  @State private var preferences = NotePreferences(defaults: ScreenshotDemo.isOn ? ScreenshotDemo.defaults : .standard)
  @State private var window = WindowState()
  /// On iPhone: the column shown, which follows the sidebar's and the list's picks.
  @State private var compactColumn = NavigationSplitViewColumn.sidebar
  @AppStorage("showsWelcome") private var showsWelcome = true
  @Environment(\.modelContext) private var context
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]
  /// The welcome sheet opens with the first window of a launch, not with each new one.
  private static var hasWelcomed = false

  init() {
    let library = FolderLibrary()
    let navigator = Navigator()
    _library = State(initialValue: library)
    _navigator = State(initialValue: navigator)
    _actions = State(initialValue: FileActions(library: library, navigator: navigator))
  }

  var body: some View {
    NavigationSplitView(preferredCompactColumn: $compactColumn) {
      SidebarView(compactColumn: $compactColumn)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    } content: {
      NoteListView()
        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
    } detail: {
      NavigationStack {
        DocumentView()
      }
    }
    .overlay { quickOpen }
    .animation(.kit, value: window.isQuickOpenShown)
    #if os(macOS)
      .modifier(HidesWindowTitle())
    #endif
    .sheet(isPresented: $window.isWelcomeShown) {
      WelcomeView(perform: perform) { urls in
        let shown = library.add(urls, existing: folders, context: context)
        if let first = shown.first { navigator.open(first) }
        return !shown.isEmpty
      }
    }
    .fileImporter(
      isPresented: $window.isAddingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: true
    ) { result in
      if case .success(let urls) = result { add(urls) }
    }
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
    .task {
      // Screenshots (.dev/screenshots.json): this window opens the later scenes of the launch.
      ScreenshotDemo.openScene = { arguments in
        openScreenshotDemo(arguments)
        await screenshotSceneLoaded()
      }
      window.perform = perform
      repositories.willChangeFiles = { [actions] in actions.willChangeFiles() }
      repositories.didChangeFiles = { [library] in library.reload() }
      actions.didMove = { [preferences] in preferences.replace($0, with: $1) }
      actions.notesFolder = { [notes] in notes.url }
      if ScreenshotDemo.isOn ? ScreenshotDemo.flag("--welcome") : showsWelcome, !Self.hasWelcomed {
        Self.hasWelcomed = true
        window.isWelcomeShown = true
      }
      updateRoots()
      await notes.resolve()
      updateRoots()
      if navigator.item == nil, navigator.selection == nil { navigator.item = .allNotes }
      repositories.refreshChanges()
      if ScreenshotDemo.isOn {
        openScreenshotDemo()
        await screenshotSceneLoaded()
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

  @ViewBuilder private var quickOpen: some View {
    if window.isQuickOpenShown {
      ZStack(alignment: .top) {
        Color.black.opacity(0.12)
          .ignoresSafeArea()
          .onTapGesture { window.isQuickOpenShown = false }
          .accessibilityHidden(true)
        QuickOpenView(perform: perform)
          .frame(maxWidth: 560)
          .padding(.horizontal, 16)
          .padding(.top, 72)
      }
      .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }
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

  /// Quick Open's and the welcome sheet's commands.
  private func perform(_ command: QuickOpenCommand) {
    switch command {
    case .newNote(let name):
      guard let dir = newItemDirectory else { return }
      if navigator.item != .folder(dir), navigator.item != .allNotes { navigator.item = .folder(dir) }
      actions.newNote(in: dir, named: name)
    case .newFolder:
      if let dir = newItemDirectory { actions.newFolder(in: dir) }
    case .addFolder:
      window.isAddingFolder = true
    case .welcome:
      window.isWelcomeShown = true
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

  /// `--screenshot-demo`: the docs folder in the sidebar, and the scene's note and panels; with `arguments`, a later
  /// screenshot scene in this launch, after undoing what the scene before opened.
  private func openScreenshotDemo(_ arguments: [String]? = nil) {
    if let arguments {
      // The same scene in the other appearance: the kit switches that.
      guard arguments != ScreenshotDemo.arguments else { return }
      ScreenshotDemo.arguments = arguments
      window.isQuickOpenShown = false
      window.isWelcomeShown = ScreenshotDemo.flag("--welcome")
      navigator.reset()
      preferences.forgetRecents()
      library.expanded.removeAll()
    }
    library.add([ScreenshotDemo.docs], existing: folders, context: context)
    navigator.item = .allNotes
    if let path = ScreenshotDemo.value("--open") {
      navigator.open(FolderLibrary.canonical(ScreenshotDemo.root.appendingPathComponent(path)))
      // Now rather than on the next update, which skips a scene showing the note the one before showed.
      follow(navigator.selection)
    }
    if ScreenshotDemo.flag("--quick-open") { window.isQuickOpenShown = true }
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

  private func add(_ urls: [URL]) {
    if let first = library.add(urls, existing: folders, context: context).first {
      navigator.open(first)
    }
  }

  private func open(_ url: URL) {
    guard url.isFileURL else { return }
    window.isWelcomeShown = false
    if let shown = library.add([url], existing: folders, context: context).first {
      navigator.open(shown)
    }
  }
}

#if os(macOS)
  /// Each pane names itself in its own rich title, so the window's title stays out of the toolbar.
  private struct HidesWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
      if #available(macOS 15, *) {
        content.toolbar(removing: .title)
      } else {
        content
      }
    }
  }
#endif
