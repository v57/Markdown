import MarkdownKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The detail pane: the selected note, or a folder's README (a link to the folder, or the
/// listed folder while no note is selected), edited in place or read (`Edit` / `Read`).
/// Edits save themselves (see `DocumentSaver`); the status bar says so and counts words.
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
  @State private var content: Content = .empty
  @State private var saver = DocumentSaver()
  @State private var showsSaveError = false
  @State private var isPickingFolder = false
  @State private var commands = MarkdownEditorCommands()
  @State private var wordCount = 0
  @State private var wordCountTask: Task<Void, Never>?
  #if os(iOS)
    @State private var isKeyboardShown = false
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
      .navigationTitle(title)
      #if os(macOS)
        .navigationSubtitle(subtitle)
      #endif
      .toolbar { toolbar }
      #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if case .document = content { statusBar }
        }
      #else
        .navigationBarTitleDisplayMode(.inline)
        // The editor is UIKit, which SwiftUI's keyboard toolbar doesn't reach: the
        // formatting bar floats above the keyboard instead.
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if isShowingDocument, isEditing, isKeyboardShown { formattingBar }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
          withAnimation(.smooth(duration: 0.25)) { isKeyboardShown = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
          withAnimation(.smooth(duration: 0.25)) { isKeyboardShown = false }
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
      .alert("Couldn’t Save", isPresented: $showsSaveError) {
        #if os(macOS)
          if case .failed(_, permissionDenied: true) = saver.state {
            Button("Allow Editing…") { allowEditing() }
          }
        #endif
        Button("OK", role: .cancel) {}
      } message: {
        if case .failed(let message, _) = saver.state { Text(message) }
      }
  }

  @ViewBuilder private var contentView: some View {
    switch content {
    case .empty:
      ContentUnavailableView(
        "No Note Selected", systemImage: "note.text",
        description: Text("Choose a note in the list, or start a new one with ⌘N."))
    case .loading:
      ProgressView()
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
      ContentUnavailableView(
        "No README", systemImage: "doc.questionmark",
        description: Text(
          "“\(folder.lastPathComponent)” has no README.md. Choose a note in the list."))
    case .failed(let file, let message):
      ContentUnavailableView(
        "Couldn’t Open “\(file.lastPathComponent)”", systemImage: "exclamationmark.triangle",
        description: Text(message))
    }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    #if os(macOS)
      // Back/forward and the note's title lead the editor's part of the toolbar, its
      // actions trail it (a split view's `.navigation` items would sit over the list).
      ToolbarItemGroup {
        Button("Back", systemImage: "chevron.left") { navigator.goBack() }
          .disabled(navigator.back.isEmpty)
          .keyboardShortcut("[", modifiers: .command)
          .help("Back (⌘[)")
        Button("Forward", systemImage: "chevron.right") { navigator.goForward() }
          .disabled(navigator.forward.isEmpty)
          .keyboardShortcut("]", modifiers: .command)
          .help("Forward (⌘])")
      }
      if #available(macOS 26, *) {
        ToolbarItem {
          titleView
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
      }
    #endif
    ToolbarItemGroup {
      if case .failed = saver.state {
        Button("Not Saved", systemImage: "exclamationmark.triangle") { showsSaveError = true }
          .foregroundStyle(.yellow)
          .help("The last edit couldn’t be saved. Click for details.")
      }
      if case .document(let file, _) = content {
        #if os(macOS)
          Picker("Mode", selection: $isEditing) {
            Label("Edit", systemImage: "pencil").tag(true)
            Label("Read", systemImage: "eye").tag(false)
          }
          .pickerStyle(.segmented)
          .labelStyle(.titleAndIcon)
          .fixedSize()
          .help("Edit shows Markdown on the line you’re on; Read hides it (⇧⌘E)")
        #else
          Button(isEditing ? "Read" : "Edit", systemImage: isEditing ? "eye" : "pencil") {
            isEditing.toggle()
          }
        #endif
        ShareLink(item: file)
        moreMenu(file)
      }
    }
  }

  #if os(macOS)
    private var titleView: some View {
      VStack(alignment: .leading, spacing: 0) {
        Text(title).font(.headline).lineLimit(1)
        if !subtitle.isEmpty {
          Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .padding(.horizontal, 4)
      .accessibilityElement(children: .combine)
    }
  #endif

  private func moreMenu(_ file: URL) -> some View {
    Menu("More", systemImage: "ellipsis.circle") {
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
      #if os(macOS)
        Button("Show in Finder", systemImage: "folder") {
          NSWorkspace.shared.activateFileViewerSelecting([file])
        }
      #endif
      if isStandalone(file) {
        Button("Add Enclosing Folder…", systemImage: "folder.badge.plus") {
          addEnclosingFolder(of: file)
        }
      }
      Divider()
      Button("Save Now", systemImage: "square.and.arrow.down") { saver.flush() }
        .disabled(saver.state != .unsaved)
      Button("Reload", systemImage: "arrow.clockwise") { refresh() }
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
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .font(.title3)
      .tint(.primary)
      .padding(.horizontal, 6)
      .frame(height: 52)
      .background(.regularMaterial, in: Capsule())
      .overlay { Capsule().strokeBorder(.separator.opacity(0.5)) }
      .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
      .padding(.horizontal, 12)
      .padding(.bottom, 8)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder private var formattingButtons: some View {
      Menu {
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
      } label: {
        Label("Text Style", systemImage: "textformat")
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

  #if os(macOS)
    /// Under the editor: whether edits are saved (and where), and the note's length.
    private var statusBar: some View {
      HStack(spacing: 12) {
        saveStatus
        Spacer()
        Text(wordCountText)
          .monospacedDigit()
          .contentTransition(.numericText())
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 16)
      .frame(height: 28)
      .background(.bar)
      .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var saveStatus: some View {
      switch saver.state {
      case .saved:
        Label(isInICloud ? "Saved, syncs through iCloud" : "Saved", systemImage: isInICloud ? "checkmark.icloud" : "checkmark.circle")
      case .unsaved:
        Label("Edited", systemImage: "pencil.circle")
      case .failed:
        Button {
          showsSaveError = true
        } label: {
          Label("Not Saved", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .help("The last edit couldn’t be saved. Click for details.")
      }
    }

    private var isInICloud: Bool {
      guard notes.isICloud, let root = notes.url, let file = saver.file else { return false }
      return file.path.hasPrefix(root.path + "/")
    }
  #endif

  private var wordCountText: String {
    let words = wordCount == 1 ? "1 word" : "\(wordCount.formatted()) words"
    let minutes = max(1, Int((Double(wordCount) / 230).rounded()))
    return wordCount == 0 ? "No words" : "\(words) · \(minutes) min read"
  }

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
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.directoryURL = root.deletingLastPathComponent()
      panel.nameFieldStringValue = root.lastPathComponent
      panel.prompt = "Allow Editing"
      panel.message = "Choose “\(root.lastPathComponent)” to let Markdown save changes in it."
      guard panel.runModal() == .OK, let granted = panel.url,
        FolderLibrary.canonical(granted) == root
      else { return }
      library.regrant(folder, with: granted, context: context)
      saver.flush()
    }
  #endif

  // MARK: - Opened files

  /// A file opened on its own (Finder, Files): the app may read and write only the file,
  /// so relative images and links in it do not resolve.
  private func isStandalone(_ file: URL) -> Bool {
    library.root(of: file, roots: roots) == nil
  }

  /// Asks for access to the file's folder and adds it to the sidebar.
  private func addEnclosingFolder(of file: URL) {
    #if os(macOS)
      let folder = file.deletingLastPathComponent()
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.directoryURL = folder
      panel.prompt = "Add Folder"
      panel.message =
        "Choose “\(folder.lastPathComponent)” to show it in the sidebar, with its images and linked files."
      guard panel.runModal() == .OK, let granted = panel.url else { return }
      addFolder(granted, showing: file)
    #else
      isPickingFolder = true
    #endif
  }

  /// Adds `folder` to the sidebar; when it holds `file`, the file's own sidebar entry
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
