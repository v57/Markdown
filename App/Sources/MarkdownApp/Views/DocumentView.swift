import ComponentKit
import MarkdownKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
  @State private var content: Content = .empty
  @State private var saver = DocumentSaver()
  @State private var showsSaveError = false
  @State private var isPickingFolder = false
  @State private var commands = MarkdownEditorCommands()
  @State private var wordCount = 0
  @State private var wordCountTask: Task<Void, Never>?
  @State private var showsMoreMenu = false
  #if os(iOS)
    @State private var isKeyboardShown = false
    @State private var showsTextStyles = false
  #endif
  /// Edit (default) or preview: preview never reveals syntax, and on iOS lets a tap
  /// follow a link instead of placing the caret.
  @AppStorage("editsDocuments") private var isEditing = true

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
      #if os(macOS) || os(Windows)
        // The window's title (Window menu, Mission Control); the toolbar shows the rich title instead.
        .navigationTitle(title)
      #endif
      .toolbar { toolbar }
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // The editor is UIKit, which SwiftUI's keyboard toolbar doesn't reach: the
        // formatting bar floats above the keyboard instead.
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if isShowingDocument, isEditing, isKeyboardShown { formattingBar }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
          withAnimation(.kit) { isKeyboardShown = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
          withAnimation(.kit) { isKeyboardShown = false }
        }
      #endif
      .focusedSceneValue(\.editorCommands, isShowingDocument && isEditing ? commands : nil)
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
      .onAppear { actions.willChangeFiles = { [saver] in saver.flush() } }
      .onDisappear { saver.flush() }
      // A save in a GitHub repository changes its count of local changes.
      .onChange(of: saver.state) { _, state in
        if state == .saved, let file = saver.file, repositories.repository(containing: file) != nil {
          repositories.refreshChanges()
        }
      }
      #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) {
          _ in saver.flush()
        }
      #endif
      .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
        if case .success(let folder) = result, case .document(let file, _) = content {
          addFolder(folder, showing: file)
        }
      }
      .kitNotice("Couldn’t Save", message: saveError, buttons: allowEditingButtons)
  }

  @ViewBuilder private var contentView: some View {
    switch content {
    case .empty:
      // Nothing open: the welcome is the main screen.
      WelcomeView()
    case .loading:
      EmptyState(
        systemImage: "doc.text", title: "Opening “\(navigator.selection?.lastPathComponent ?? "Note")”", status: .working)
    case .document(let file, let text):
      MarkdownEditorView(
        text: text, resolver: .relative(to: file, root: library.root(of: file, roots: roots)),
        isReadOnly: !isEditing, anchor: navigator.anchor,
        onChange: { text in
          saver.edited(text)
          countWords(text)
        },
        onOpenURL: { open($0) },
        startsEditing: navigator.startsEditing && isEditing,
        commands: commands
      )
      .id(file)
      .onAppear { countWords(text, now: true) }
    case .noReadme(let folder):
      EmptyState(
        systemImage: "doc.questionmark", title: "No README",
        message: "“\(folder.lastPathComponent)” has no README.md. Choose a note in the sidebar.")
    case .failed(let file, let message):
      EmptyState(
        systemImage: "exclamationmark.triangle", title: "Couldn’t Open “\(file.lastPathComponent)”",
        message: message)
    }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    #if os(macOS)
      // Back/forward and the note's rich title lead the editor's part of the toolbar, the
      // Edit/Read switch and its actions trail it (a split view's `.navigation` items would sit
      // over the list).
      ToolbarItem {
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
      .kitToolbarItem()
      ToolbarItem { titleView }
        .kitToolbarItem()
      if #available(macOS 26, *) {
        ToolbarSpacer(.flexible)
      }
    #else
      ToolbarItem(placement: .topBarLeading) {
        titleView.fixedSize()
      }
      .kitToolbarItem()
    #endif
    if case .document(let file, _) = content {
      if idiom != .phone {
        ToolbarItem(placement: .primaryAction) {
          KitSegmented(selection: $isEditing, options: [("Edit", true), ("Read", false)])
            .kitHelp("Edit or Read", shortcut: "⇧⌘E", meta: "Edit shows Markdown on the line you’re on")
        }
        .kitToolbarItem()
      }
      ToolbarItem(placement: .primaryAction) {
        ToolGroup(iconOnly: true) {
          if case .failed = saver.state {
            Button("Not Saved", systemImage: "exclamationmark.triangle", role: .destructive) { showsSaveError = true }
              .kitHelp("Not Saved", meta: "The last edit couldn’t be saved", hue: .red)
          }
          if idiom == .phone {
            Button(isEditing ? "Read" : "Edit", systemImage: isEditing ? "eye" : "pencil") { isEditing.toggle() }
              .kitHelp(isEditing ? "Read" : "Edit", shortcut: "⇧⌘E")
          }
          ShareLink(item: file)
            .kitHelp("Share")
          moreMenu(file)
        }
      }
      .kitToolbarItem()
    }
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

  /// Allow Editing… when the sandbox refused the save (the Mac).
  private var allowEditingButtons: [KitConfirmationButton] {
    #if os(macOS)
      if case .failed(_, permissionDenied: true) = saver.state {
        return [KitConfirmationButton("Allow Editing…") { allowEditing() }]
      }
    #endif
    return []
  }

  /// The note's rich title; its meta line is where it lives, then whether edits are saved and its length.
  private var titleView: some View {
    KitTitle(title, meta: titleMeta, systemImage: "doc.text", hue: .accent, status: titleStatus)
      .opacity(title.isEmpty ? 0 : 1)
  }

  private var titleMeta: [String] {
    let place = subtitle.components(separatedBy: " · ")
    guard isShowingDocument else { return place }
    let state =
      switch saver.state {
      case .saved: isInICloud ? "Synced" : "Saved"
      case .unsaved: "Edited"
      case .failed: "Not saved"
      }
    return place + [state, wordCount == 0 ? "" : wordCount == 1 ? "1 word" : "\(wordCount.formatted()) words"]
  }

  private var titleStatus: WorkStatus {
    if case .failed(let message, _) = saver.state { return .failed(message) }
    return .idle
  }

  private var isInICloud: Bool {
    guard notes.isICloud, let root = notes.url, let file = saver.file else { return false }
    return file.path.hasPrefix(root.path + "/")
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
          Button("Show in \(KitDesktop.fileManagerName)", systemImage: "folder") { KitDesktop.reveal([file]) }
        #endif
        if isStandalone(file), let project = project(holding: file) {
          Button("Open Project “\(project.lastPathComponent)”…", systemImage: "folder.badge.plus") {
            openProject(project, showing: file)
          }
        }
        Divider()
        Button("Save Now", systemImage: "square.and.arrow.down") { saver.flush() }
          .disabled(saver.state != .unsaved)
          .kitMenuHint(idiom == .mac ? "⌘S" : nil)
        Button("Reload", systemImage: "arrow.clockwise") { refresh() }
          .kitMenuHint(idiom == .mac ? "⌘R" : nil)
        #if os(iOS)
          if !navigator.back.isEmpty || !navigator.forward.isEmpty {
            Divider()
            Button("Back", systemImage: "chevron.left") { navigator.goBack() }
              .disabled(navigator.back.isEmpty)
            Button("Forward", systemImage: "chevron.right") { navigator.goForward() }
              .disabled(navigator.forward.isEmpty)
          }
        #endif
      }
  }

  #if os(iOS)
    /// Above the keyboard: text styles, checklist, list, table, code, link — and a
    /// button that puts the keyboard away.
    private var formattingBar: some View {
      HStack(spacing: 0) {
        formattingButtons
      }
      .buttonStyle(.kitToolIcon)
      .padding(.horizontal, KitMetrics.cardPadding)
      .frame(height: 52)
      .kitSurface(.floating)
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
          Button("Code", systemImage: "chevron.left.forwardslash.chevron.right") { commands.apply(.inlineCode) }
          Divider()
          Button("Quote", systemImage: "text.quote") { commands.apply(.quote) }
          Button("Numbered List", systemImage: "list.number") { commands.apply(.numberedList) }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
      Group {
        Button("Checklist", systemImage: "checklist") { commands.apply(.checklist) }
        Button("Bulleted List", systemImage: "list.bullet") { commands.apply(.bulletList) }
        Button("Table", systemImage: "tablecells") { commands.apply(.table) }
        Button("Code Block", systemImage: "curlybraces") { commands.apply(.codeBlock) }
        Button("Link", systemImage: "link") { commands.apply(.link) }
        Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down") {
          UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
      }
      .frame(maxWidth: .infinity, minHeight: 44)
    }
  #endif

  /// Counts after typing pauses (a long note is a lot of text to scan per keystroke).
  private func countWords(_ text: String, now: Bool = false) {
    wordCountTask?.cancel()
    wordCountTask = Task {
      if !now { try? await Task.sleep(for: .milliseconds(400)) }
      guard !Task.isCancelled else { return }
      let count = await Task.detached(priority: .utility) { Self.words(in: text) }.value
      guard !Task.isCancelled else { return }
      wordCount = count
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
      place = "Notes"
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
      content = .document(file: file, text: text)
    } catch {
      guard !Task.isCancelled else { return }
      content = .failed(file: file, message: error.localizedDescription)
    }
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
            prompt: "Allow Editing", message: "Choose “\(root.lastPathComponent)” to let Markdown save changes in it.",
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
      Task {
        guard
          let granted = await KitDesktop.chooseFolders(
            prompt: "Open",
            message:
              "Choose “\(project.lastPathComponent)” to open the project in the sidebar, with this note’s images and linked files.",
            directory: project
          ).first
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
