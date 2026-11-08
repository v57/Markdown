import ComponentKit
import MarkdownKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VaultKit
import VaultUI

/// The detail pane: the selected note, or a folder's README (a link to the folder, or the
/// listed folder while no note is selected), edited in place or read (`Edit` / `Read`).
/// Edits save themselves (see `DocumentSaver`); the title's meta line says so and counts words.
/// Relative images resolve against the file; links to markdown files and folders open
/// here (with back/forward), anything else opens externally.
struct DocumentView: View {
  @Environment(FolderLibrary.self) private var library
  @Environment(Navigator.self) private var navigator
  @Environment(FileActions.self) private var actions
  @Environment(RepositoryStore.self) private var repositories
  @Environment(NotesLocation.self) private var notes
  @Environment(NotePreferences.self) private var preferences
  @Environment(\.scenePhase) private var scenePhase
  @Environment(WindowState.self) private var window
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]
  @Environment(\.modelContext) private var context
  @Environment(\.kitIdiom) private var idiom
  /// Off while one of the kit's overlays covers the window: the Format menu then leaves the note alone (⌘. and the
  /// other shortcuts would edit it behind the overlay).
  @Environment(\.isEnabled) private var isEnabled
  @State private var content: Content = .empty
  @State private var saver = DocumentSaver()
  #if os(macOS)
    /// Saves what's pending when the app quits.
    @State private var quitObserver: (any NSObjectProtocol)?
  #endif
  /// What was selected when the saver's file opened.
  @State private var selectedOnOpen: URL?
  @State private var showsSaveError = false
  @State private var isPickingFolder = false
  @State private var commands = MarkdownEditorCommands()
  @State private var words = WordCounter()
  /// The documents whose web images the reader let load, while the window is open (security audit M1).
  @State private var imagesAllowed: Set<URL> = []
  /// Whether the open document has web images that weren't loaded.
  @State private var hasBlockedImages = false
  /// A link waiting for the reader's go-ahead (security audit H4).
  @State private var linkRequest: MarkdownLinkRequest?
  @State private var showsMoreMenu = false
  #if os(iOS)
    @State private var isKeyboardShown = false
    @State private var showsTextStyles = false
  #endif
  /// Edit (default) or preview: preview never reveals syntax, and on iOS lets a tap
  /// follow a link instead of placing the caret.
  @KitStorage("editsDocuments", store: ScreenshotDemo.settings) private var isEditing = true

  private enum Content: Equatable {
    case empty
    case loading
    case document(file: URL, text: String)
    case noReadme(folder: URL)
    case failed(file: URL, message: String)
  }

  /// Re-loads when the selection changes (or, with none, the listed folder), or the
  /// library reloads.
  private struct LoadKey: Equatable {
    var selection: URL?
    var item: LibraryItem?
    var generation: Int
  }

  var body: some View {
    contentView
      .kitPane(.content)
      .kitConfirmation(
        linkTitle, isPresented: Binding(get: { linkRequest != nil }, set: { if !$0 { linkRequest = nil } }),
        message: linkMessage, systemImage: "link", confirm: "Open", role: nil
      ) { [linkRequest] in linkRequest?.open() }
      // Back and forward lead the title at the bar's spacing; the Edit/Read switch and the note's actions trail it.
      .kitToolbar(title) {
        navigationButtons
      } title: {
        titleView
      } tools: {
        if case .document(let file, _) = content {
          if idiom != .phone {
            KitSegmented(selection: $isEditing, options: [("Edit", true), ("Read", false)])
              .kitHelp("Edit or Read", shortcut: "⇧⌘E", meta: "Edit shows Markdown on the line you’re on")
          }
          ToolGroup(iconOnly: true) {
            SaveFailedButton(saver: saver, showsSaveError: $showsSaveError)
            if idiom == .phone {
              Button(isEditing ? "Read" : "Edit", systemImage: isEditing ? "eye" : "pencil") { isEditing.toggle() }
                .kitHelp(isEditing ? "Read" : "Edit", shortcut: "⇧⌘E")
            }
            ShareLink(item: file)
              .kitHelp("Share")
            moreMenu(file)
          }
        }
      }
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // The editor is UIKit, which SwiftUI's keyboard toolbar doesn't reach: the
        // formatting bar floats above the keyboard instead.
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if isShowingDocument, isEditing, isKeyboardShown { formattingBar }
        }
        .task {
          for await _ in NotificationCenter.default.notifications(named: UIResponder.keyboardWillShowNotification) {
            withAnimation(.kit) { isKeyboardShown = true }
          }
        }
        .task {
          for await _ in NotificationCenter.default.notifications(named: UIResponder.keyboardWillHideNotification) {
            withAnimation(.kit) { isKeyboardShown = false }
          }
        }
      #elseif os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if isShowingDocument, isEditing { quickActionsBar }
        }
      #endif
      .focusedSceneValue(\.editorCommands, isShowingDocument && isEditing && isEnabled ? commands : nil)
      .focusedSceneValue(\.documentActions, documentActions)
      .task(id: LoadKey(selection: navigator.selection, item: navigator.item, generation: library.generation)) {
        let shown = WindowState.Shown(selection: navigator.selection, item: navigator.item)
        await load()
        if !Task.isCancelled { window.loadedDocument = shown }
      }
      .onChange(of: scenePhase) { _, phase in
        switch phase {
        // Pick up edits made in other apps while we were in the background.
        case .active: refresh()
        default: saver.flush()
        }
      }
      .onAppear {
        saver.filePresenter = { [notes] in notes.filePresenter }
        actions.willChangeFiles = { [saver] in saver.flush() }
        actions.willCreateNote = { discardEmptyNote() }
        actions.didCreateNote = { if isEditing { commands.focus() } }
      }
      .onDisappear { saver.flush() }
      #if os(macOS)
        // A plain observer, not `for await` in a `.task`: the app exits as soon as its observers return, before a task
        // waiting on the notification would resume, which would lose what was typed in the last moment.
        .onAppear {
          guard quitObserver == nil else { return }
          quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
          ) { [saver] _ in
            MainActor.assumeIsolated { saver.flush() }
          }
        }
        .onDisappear {
          if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
          quitObserver = nil
        }
      #endif
      .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
        if case .success(let folder) = result, case .document(let file, _) = content {
          addFolder(folder, showing: file)
        }
      }
      .modifier(SaveFollower(saver: saver, showsSaveError: $showsSaveError, allowEditing: allowEditingAction))
  }

  @ViewBuilder private var contentView: some View {
    switch content {
    case .empty:
      // Nothing open: the welcome is the main screen.
      WelcomeView()
    case .loading:
      // A quick open (switching notes) shows nothing; a slow one says what it opens.
      EmptyState(
        systemImage: "doc.text", title: "Opening “\(navigator.selection?.lastPathComponent ?? "Note")”", status: .working
      )
      .kitAppearDelay()
    case .document(let file, let text):
      VStack(spacing: 0) {
        if hasBlockedImages, !imagesAllowed.contains(file) {
          Banner(
            "This note's images from the web aren't loaded.",
            message: "Loading them tells their servers that the note was opened.", systemImage: "photo", hue: .blue
          ) {
            Button("Load Images") { imagesAllowed.insert(file) }
          }
          .padding(8)
        }
        MarkdownEditorView(
          text: text, resolver: .relative(to: file, root: library.root(of: file, roots: roots)),
          isReadOnly: !isEditing, anchor: navigator.anchor,
          onChange: { [saver, words] text in
            saver.edited(text)
            words.count(text)
          },
          onOpenURL: { open($0) },
          startsEditing: navigator.startsEditing && isEditing,
          commands: commands
        )
        .remoteImages(loads: imagesAllowed.contains(file)) { hasBlockedImages = $0 }
        .onConfirmLink { linkRequest = $0 }
        .id(file)
        .onAppear { words.count(text, now: true) }
      }
    case .noReadme(let folder):
      EmptyState(
        systemImage: "doc.questionmark", title: "No README",
        message: "“\(folder.lastPathComponent)” has no README.md. Choose a note in the sidebar.")
    case .failed(let file, let message):
      EmptyState(
        systemImage: "exclamationmark.triangle", title: "Couldn’t Open “\(file.lastPathComponent)”",
        message: "\(message)")
    }
  }

  /// The question for a link waiting for the go-ahead.
  private var linkTitle: LocalizedStringKey {
    guard let linkRequest, linkRequest.url.isFileURL else { return "Open this link?" }
    return "Open “\(linkRequest.target)”?"
  }

  /// Where the link leads (a file's path, else the whole URL) and the app that would open it. On iPhone and iPad a
  /// file's path is the app's container, which says nothing (M-008): there it's the path in its folder ("ZZ Test/img.png").
  private var linkMessage: LocalizedStringKey {
    guard let url = linkRequest?.url else { return "" }
    let place = url.isFileURL ? (idiom == .mac ? url.path : placeInLibrary(url)) : url.absoluteString
    guard let opener = linkRequest?.opener else { return "\(place) opens in another app." }
    return "\(place) opens in \(opener)."
  }

  /// A file's path from the folder in the sidebar that holds it, that folder's name first; its name alone outside them.
  private func placeInLibrary(_ url: URL) -> String {
    let file = FolderLibrary.canonical(url)
    guard let root = library.root(of: file, roots: roots) else { return file.lastPathComponent }
    let base = FolderLibrary.canonical(root).path
    let relative = file.path.hasPrefix(base + "/") ? String(file.path.dropFirst(base.count + 1)) : file.lastPathComponent
    // The notes folder is the app's Documents: its own name is noise.
    if let notesRoot = notes.url, FolderLibrary.canonical(notesRoot) == FolderLibrary.canonical(root) { return relative }
    return root.lastPathComponent + "/" + relative
  }

  /// Back and forward, except on iPhone: its bar is short, so they're in the note's More menu.
  @ViewBuilder private var navigationButtons: some View {
    if idiom != .phone {
      ToolGroup(iconOnly: true) {
        Button("Back", systemImage: "chevron.left") { navigator.goBack() }
          .disabled(navigator.back.isEmpty)
          .keyboardShortcut("[", modifiers: .command)
          .kitHelp("Back", shortcut: "⌘[")
        Button("Forward", systemImage: "chevron.right") { navigator.goForward() }
          .disabled(navigator.forward.isEmpty)
          .keyboardShortcut("]", modifiers: .command)
          .kitHelp("Forward", shortcut: "⌘]")
      }
    }
  }

  /// The note's rich title; its meta line is where it lives, then whether edits are saved and its length.
  private var titleView: some View {
    DocumentTitle(
      title: title, place: subtitle.components(separatedBy: " · "), isShowingDocument: isShowingDocument, saver: saver,
      words: words)
  }

  private func moreMenu(_ file: URL) -> some View {
    Button("More", systemImage: "ellipsis.circle") { showsMoreMenu = true }
      .kitHelp("More")
      .kitMenu(isPresented: $showsMoreMenu) {
        if isNote(file) {
          Button(preferences.isPinned(file) ? "Unpin Note" : "Pin Note", systemImage: preferences.isPinned(file) ? "pin.slash" : "pin") {
            preferences.togglePin(file)
          }
          Button("Rename…", systemImage: "pencil") { actions.beginRename(file) }
          if actions.canToggleEncryption(file) {
            let encrypted = NoteFiles.isEncrypted(file)
            Button(encrypted ? "Decrypt Note" : "Encrypt Note", systemImage: encrypted ? "lock.open" : "lock") {
              actions.setEncrypted(file, !encrypted)
            }
          }
        }
        #if os(macOS) || os(Windows)
          KitOpenWithRow.file(file)
        #endif
        if isStandalone(file), let project = project(holding: file) {
          Button("Open Project “\(project.lastPathComponent)”…", systemImage: "folder.badge.plus") {
            openProject(project, showing: file)
          }
          .kitMenuPreview("Opens the project this note is in.")
        }
        Divider()
        Button("Save Now", systemImage: "square.and.arrow.down") { saver.flush() }
          .disabled(saver.state != .unsaved)
          .kitMenuHint(idiom == .mac ? "⌘S" : nil)
        Button("Reload", systemImage: "arrow.clockwise") { refresh() }
          .kitMenuHint(idiom == .mac ? "⌘R" : nil)
        if idiom == .phone {
          if !navigator.back.isEmpty || !navigator.forward.isEmpty {
            Divider()
            Button("Back", systemImage: "chevron.left") { navigator.goBack() }
              .disabled(navigator.back.isEmpty)
            Button("Forward", systemImage: "chevron.right") { navigator.goForward() }
              .disabled(navigator.forward.isEmpty)
          }
        }
      }
  }

  /// The toggles for the selected text and lines, with their shortcuts.
  private var quickActions: some View {
    ForEach(MarkdownQuickAction.allCases) { action in
      Button(action.title, systemImage: action.systemImage) { commands.apply(action.format) }
        .kitHelp(action.title, shortcut: idiom == .mac ? action.shortcut : nil)
    }
  }

  #if os(macOS)
    /// Under the editor while editing.
    private var quickActionsBar: some View {
      HStack(spacing: 0) { quickActions }
        .labelStyle(.iconOnly)
        .buttonStyle(.kitToolIcon)
        .padding(.horizontal, KitMetrics.gutter)
        .frame(height: 40)
        .kitSurface(.floating, cornerRadius: KitMetrics.radiusCapsule)
        .padding(.bottom, KitMetrics.gutter)
    }
  #endif

  #if os(iOS)
    /// Above the keyboard: the other text styles and blocks, the toggles for the selected lines, and a button that puts
    /// the keyboard away.
    private var formattingBar: some View {
      HStack(spacing: 0) {
        formattingButtons
      }
      .buttonStyle(.kitToolIcon)
      .padding(.horizontal, KitMetrics.cardPadding)
      .frame(height: 52)
      .kitSurface(.floating, cornerRadius: KitMetrics.radiusCapsule)
      .padding(.horizontal, KitMetrics.gutter)
      .padding(.bottom, KitMetrics.gutter)
      .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder private var formattingButtons: some View {
      Button("Text Style", systemImage: "textformat") { showsTextStyles = true }
        .kitMenu(isPresented: $showsTextStyles) {
          Button("Title", systemImage: "textformat.size.larger") { commands.apply(.heading(1)) }
          Button("Heading", systemImage: "textformat.size") { commands.apply(.heading(2)) }
          Button("Subheading", systemImage: "textformat.size.smaller") { commands.apply(.heading(3)) }
          Divider()
          Button("Bold", systemImage: "bold") { commands.apply(.bold) }
          Button("Italic", systemImage: "italic") { commands.apply(.italic) }
          Button("Strikethrough", systemImage: "strikethrough") { commands.apply(.strikethrough) }
          Divider()
          Button("Table", systemImage: "tablecells") { commands.apply(.table) }
          Button("Code Block", systemImage: "curlybraces") { commands.apply(.codeBlock) }
          Button("Link", systemImage: "link") { commands.apply(.link) }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
      Group {
        quickActions
        Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down") {
          UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
      }
      .frame(maxWidth: .infinity, minHeight: 44)
    }
  #endif

  private var isShowingDocument: Bool {
    if case .document = content { return true }
    return false
  }

  /// Save, Reload and the Edit/Read switch for the menu bar.
  private var documentActions: DocumentActions? {
    guard case .document = content else { return nil }
    return DocumentActions(
      save: { saver.flush() }, reload: { refresh() }, toggleMode: { isEditing.toggle() },
      isEditing: isEditing)
  }

  /// A note the user can rename and pin: inside one of the app's folders.
  private func isNote(_ file: URL) -> Bool {
    library.root(of: file, roots: roots) != nil
  }

  /// The note's name, or the folder's for its README.
  private var title: String {
    guard case .document(let file, _) = content else { return "" }
    if file != navigator.selection, FolderLibrary.isDirectory(file.deletingLastPathComponent()),
      file.deletingPathExtension().lastPathComponent.lowercased() == "readme"
    {
      return readmeFolder(of: file)?.lastPathComponent ?? file.lastPathComponent
    }
    return file.deletingPathExtension().lastPathComponent
  }

  /// Where the note is: "Projects · Notes", "README.md · v57/website".
  private var subtitle: String {
    guard case .document(let file, _) = content else { return "" }
    let folder = file.deletingLastPathComponent()
    let root = library.root(of: file, roots: roots)
    let place: String
    if let notesRoot = notes.url, root == notesRoot {
      place = String(localized: "Notes")
    } else if let root, let repository = repositories.repositories.first(where: { repositories.directory(for: $0) == root }) {
      place = repository.fullName
    } else {
      place = root?.lastPathComponent ?? folder.lastPathComponent
    }
    if file != navigator.selection, title != file.deletingPathExtension().lastPathComponent {
      return "\(file.lastPathComponent) · \(place)"
    }
    let folderName = folder == root ? nil : folder.lastPathComponent
    return [folderName, place].compactMap { $0 }.joined(separator: " · ")
  }

  /// The folder a README belongs to (it may sit in .github/ or docs/).
  private func readmeFolder(of file: URL) -> URL? {
    let folder = file.deletingLastPathComponent()
    return [".github", "docs"].contains(folder.lastPathComponent) ? folder.deletingLastPathComponent() : folder
  }

  // MARK: - Loading

  private func load() async {
    saver.flush()  // the previous document's pending edits
    discardEmptyNote(keeping: navigator.selection)
    let file: URL
    if let selection = navigator.selection {
      if FolderLibrary.isDirectory(selection) {
        guard let readme = library.readme(in: selection) else {
          content = .noReadme(folder: selection)
          return
        }
        file = readme
      } else {
        file = selection
      }
    } else if case .folder(let folder) = navigator.item, let readme = library.readme(in: folder) {
      // Nothing chosen in the list yet: the folder's README, as on GitHub.
      file = readme
    } else {
      content = .empty
      return
    }
    if case .document(let shown, _) = content, shown != file { content = .loading }
    if case .empty = content { content = .loading }
    do {
      let text = try await Task.detached(priority: .userInitiated) {
        try Self.read(file)
      }.value
      guard !Task.isCancelled else { return }
      // Our own save read back (a reload after editing): keep the editor as it is —
      // replacing its text would reset the caret and scroll position.
      if case .document(let shown, _) = content, shown == file, saver.isCurrent(text, for: file) {
        return
      }
      saver.open(file, text: text)
      selectedOnOpen = navigator.selection
      content = .document(file: file, text: text)
    } catch {
      guard !Task.isCancelled else { return }
      content = .failed(file: file, message: error.localizedDescription)
    }
  }

  /// The note just left goes when it has no text, unless it's pinned (Shell does the same with its notes). A new note
  /// stays while it's the selected one: this runs when the selection moves on, or for the next new note. A README shown
  /// for its folder was never selected, so it stays.
  private func discardEmptyNote(keeping selection: URL? = nil) {
    saver.flush()
    guard let file = saver.file, file == selectedOnOpen, file != selection, saver.isEmpty, !preferences.isPinned(file)
    else { return }
    actions.discardEmptyNote(file)
  }

  /// UTF-8 first (what markdown nearly always is), else whatever encoding Foundation
  /// detects; an encrypted note is decrypted (`NoteFiles`). The read is coordinated: a note
  /// iCloud has not downloaded yet is fetched first, a sync in progress finishes before the
  /// text is read, and versions two devices saved apart are merged first.
  nonisolated private static func read(_ url: URL) throws -> String {
    NoteFiles.resolveConflicts(at: url)
    var coordinationError: NSError?
    var result: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
      url in
      result = Result { try NoteFiles.text(at: url) }
    }
    if let coordinationError { throw coordinationError }
    let text = try result.get()
    NoteFiles.remember(text, for: url)
    return text
  }

  private func refresh() {
    saver.flush()  // a reload must not drop (or be raced by) pending edits
    MarkdownImageCache.shared.forgetFileImages()
    library.reload()
  }

  // MARK: - Access

  /// Re-grants read-write access to the shown file's folder, where the sandbox refused a save (the Mac).
  private var allowEditingAction: (() -> Void)? {
    #if os(macOS)
      { allowEditing() }
    #else
      nil
    #endif
  }

  #if os(macOS)
    /// Re-grants read-write access to the shown file's sidebar folder: an open panel on
    /// that folder; confirming it replaces the folder's bookmark, then the pending edits
    /// are saved.
    private func allowEditing() {
      guard case .document(let file, _) = content,
        let folder = folders.first(where: { f in
          !f.isFile && library.url(for: f).map { library.root(of: file, roots: [$0]) != nil } ?? false
        }), let root = library.url(for: folder)
      else { return }
      Task {
        guard
          let granted = await KitDesktop.chooseFolders(
            prompt: String(localized: "Allow Editing"), message: String(localized: "Choose “\(root.lastPathComponent)” to let Markdown save changes in it."),
            directory: root.deletingLastPathComponent(), name: root.lastPathComponent
          ).first,
          FolderLibrary.canonical(granted) == root
        else { return }
        library.regrant(folder, with: granted, context: context)
        saver.flush()
      }
    }
  #endif

  // MARK: - Opened files

  /// A file opened on its own (Finder, Files): the app may read and write only the file,
  /// so relative images and links in it do not resolve.
  private func isStandalone(_ file: URL) -> Bool {
    library.root(of: file, roots: roots) == nil
  }

  /// The shared project whose folder holds the file, which the sidebar can open (`FolderLibrary.projectPaths`).
  private func project(holding file: URL) -> URL? {
    let path = FolderLibrary.canonical(file).path
    return library.projectPaths.filter { path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  /// Asks for access to the project's folder and opens it in the sidebar, with the file in it.
  private func openProject(_ project: URL, showing file: URL) {
    #if os(macOS)
      // Without the sandbox the folder opens as it is; in it, a grant or the panel (on the folder with every project).
      let projects = library.projectPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
      Task {
        guard
          let granted = await VaultFolderAccess.request(
            project, name: project.lastPathComponent, among: projects,
            message: "Choose “\(FolderGrants.folder(around: project, among: projects).lastPathComponent)” to open the project in the sidebar, with this note’s images and linked files.",
            grants: library.grants)
        else { return }
        addFolder(granted, showing: file)
      }
    #else
      isPickingFolder = true
    #endif
  }

  /// Opens the project's `folder` in the sidebar; when it holds `file`, the file's own sidebar entry
  /// goes (the folder now shows it) and the file is shown again with resolving links.
  private func addFolder(_ folder: URL, showing file: URL) {
    let added = library.add([folder], existing: folders, context: context)
    let newRoots = roots + added.filter(FolderLibrary.isDirectory)
    guard library.root(of: file, roots: newRoots) != nil else { return }
    if let entry = folders.first(where: { $0.isFile && $0.path == file.path }) {
      library.remove(entry, context: context)
    }
    library.reveal(file, roots: newRoots)
    navigator.open(file)
    library.reload()
  }

  // MARK: - Links

  private var roots: [URL] { library.roots(folders) }

  /// Markdown files and folders open here; everything else is left to the editor's
  /// default (the system opens it).
  private func open(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    let target = FolderLibrary.canonical(url)
    guard FolderLibrary.isDirectory(target) || FolderLibrary.isMarkdown(target) else {
      return false
    }
    library.reveal(target, roots: roots)
    navigator.open(target, anchor: url.fragment)
    return true
  }
}

/// The note's rich title: its name, where it lives, whether edits are saved and how many words it has. A view of its
/// own, so a save or a new count updates only the title: read in `DocumentView`'s body, both built the whole pane again
/// (the toolbar, the editor's representable and the menu bar's commands) as the user typed.
private struct DocumentTitle: View {
  let title: String
  let place: [String]
  let isShowingDocument: Bool
  let saver: DocumentSaver
  let words: WordCounter
  @Environment(NotesLocation.self) private var notes
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    KitTitle(title, meta: meta, systemImage: "doc.text", hue: .accent, status: status)
      .opacity(title.isEmpty ? 0 : 1)
  }

  private var meta: [String] {
    guard isShowingDocument else { return place }
    let state =
      switch saver.state {
      case .saved: isInICloud ? "Synced" : "Saved"
      case .unsaved: "Edited"
      case .failed: "Not saved"
      }
    let count = words.value
    let length = count == 0 ? "" : count == 1 ? "1 word" : "\(count.formatted()) words"
    // An iPhone's bar leaves the title about 110 points: the place, then the state, left nothing of the count (M-003).
    // There it's the state while an edit waits or failed, else the count (the screen under the note's folder says
    // where it is). On iPad the state and count come first, the place after them while it fits.
    switch idiom {
    case .phone: return [saver.state == .saved && !length.isEmpty ? length : state]
    case .pad: return [state, length].filter { !$0.isEmpty } + place
    default: return place + [state, length]
    }
  }

  private var status: WorkStatus {
    if case .failed(let message, _) = saver.state { return .failed(message) }
    return .idle
  }

  private var isInICloud: Bool {
    guard notes.isICloud, let root = notes.url, let file = saver.file else { return false }
    return file.path.hasPrefix(root.path + "/")
  }
}

/// Not Saved, in the note's tools while the last edit couldn't be saved; it shows why. A view of its own, so the saver's
/// state updates only it.
private struct SaveFailedButton: View {
  let saver: DocumentSaver
  @Binding var showsSaveError: Bool

  var body: some View {
    if case .failed = saver.state {
      Button("Not Saved", systemImage: "exclamationmark.triangle", role: .destructive) { showsSaveError = true }
        .kitHelp("Not Saved", meta: "The last edit couldn’t be saved", hue: .red)
    }
  }
}

/// What follows the saver: a save lists the note's new date and first line, one in a GitHub repository recounts its local
/// changes, and why a save failed shows while asked (with Allow Editing… where the sandbox refused it). A modifier of its
/// own, so a save updates only it.
private struct SaveFollower: ViewModifier {
  let saver: DocumentSaver
  @Binding var showsSaveError: Bool
  let allowEditing: (() -> Void)?
  @Environment(RepositoryStore.self) private var repositories
  @Environment(FolderLibrary.self) private var library

  func body(content: Content) -> some View {
    content
      .onChange(of: saver.state) { _, state in
        guard state == .saved else { return }
        library.noteSaved()
        if let file = saver.file, repositories.repository(containing: file) != nil {
          repositories.refreshChanges()
        }
      }
      .kitNotice("Couldn’t Save", message: saveError, buttons: allowEditingButtons)
  }

  /// Why the last edit couldn't be saved, while its notice shows.
  private var saveError: Binding<String?> {
    Binding(
      get: {
        guard showsSaveError, case .failed(let message, _) = saver.state else { return nil }
        return message
      },
      set: { if $0 == nil { showsSaveError = false } })
  }

  /// Allow Editing… when the sandbox refused the save.
  private var allowEditingButtons: [KitConfirmationButton] {
    guard let allowEditing, case .failed(_, permissionDenied: true) = saver.state else { return [] }
    return [KitConfirmationButton("Allow Editing…") { allowEditing() }]
  }
}

/// The open note's word count, after typing pauses (a long note is a lot of text to scan per keystroke). Observable on
/// its own, so a new count updates only the title.
@Observable private final class WordCounter {
  private(set) var value = 0
  @ObservationIgnored private var task: Task<Void, Never>?

  func count(_ text: String, now: Bool = false) {
    task?.cancel()
    task = Task {
      if !now { try? await Task.sleep(for: .milliseconds(400)) }
      guard !Task.isCancelled else { return }
      let count = await Task.detached(priority: .utility) { Self.words(in: text) }.value
      guard !Task.isCancelled, count != value else { return }
      value = count
    }
  }

  nonisolated private static func words(in text: String) -> Int {
    var count = 0
    var inWord = false
    for scalar in text.unicodeScalars {
      let isWordCharacter = CharacterSet.alphanumerics.contains(scalar)
      if isWordCharacter, !inWord { count += 1 }
      inWord = isWordCharacter || (inWord && (scalar == "'" || scalar == "’" || scalar == "-"))
    }
    return count
  }
}
