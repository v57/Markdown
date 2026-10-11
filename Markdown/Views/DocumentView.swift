import Md
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The detail pane: the selected markdown file, or the selected folder's README, edited
/// in place (or previewed read-only). Edits save themselves (see `DocumentSaver`).
/// Relative images resolve against the file; links to markdown files and folders open
/// here (with back/forward), anything else opens externally.
struct DocumentView: View {
  @Environment(FolderLibrary.self) private var library
  @Environment(Navigator.self) private var navigator
  @Environment(\.scenePhase) private var scenePhase
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]
  @Environment(\.modelContext) private var context
  @State private var content: Content = .empty
  @State private var saver = DocumentSaver()
  @State private var showsSaveError = false
  @State private var isPickingFolder = false
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

  /// Re-loads when the selection changes or the library reloads.
  private struct LoadKey: Equatable {
    var selection: URL?
    var generation: Int
  }

  var body: some View {
    contentView
      .navigationTitle(title)
      #if os(macOS)
        .navigationSubtitle(subtitle)
      #endif
      .toolbar { toolbar }
      .task(id: LoadKey(selection: navigator.selection, generation: library.generation)) {
        await load()
      }
      .onChange(of: scenePhase) { _, phase in
        switch phase {
        // Pick up edits made in other apps while we were in the background.
        case .active: refresh()
        default: saver.flush()
        }
      }
      .onDisappear { saver.flush() }
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
        "No Selection", systemImage: "sidebar.left",
        description: Text("Select a folder to read its README, or a markdown file."))
    case .loading:
      ProgressView()
    case .document(let file, let text):
      MarkdownEditorView(
        text: text, resolver: .relative(to: file, root: library.root(of: file, roots: roots)),
        isReadOnly: !isEditing, anchor: navigator.anchor,
        onChange: { saver.edited($0) },
        onOpenURL: { open($0) }
      )
      .id(file)
    case .noReadme(let folder):
      ContentUnavailableView(
        "No README", systemImage: "doc.questionmark",
        description: Text(
          "“\(folder.lastPathComponent)” has no README.md. Pick a markdown file in the sidebar."))
    case .failed(let file, let message):
      ContentUnavailableView(
        "Couldn’t Open “\(file.lastPathComponent)”", systemImage: "exclamationmark.triangle",
        description: Text(message))
    }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button("Back", systemImage: "chevron.left") { navigator.goBack() }
        .disabled(navigator.back.isEmpty)
        .keyboardShortcut("[", modifiers: .command)
      Button("Forward", systemImage: "chevron.right") { navigator.goForward() }
        .disabled(navigator.forward.isEmpty)
        .keyboardShortcut("]", modifiers: .command)
    }
    ToolbarItemGroup {
      if case .failed = saver.state {
        Button("Not Saved", systemImage: "exclamationmark.triangle") { showsSaveError = true }
          .foregroundStyle(.yellow)
          .help("The last edit couldn’t be saved. Click for details.")
      }
      if case .document = content {
        Toggle(isOn: $isEditing) {
          Label(isEditing ? "Editing" : "Preview", systemImage: isEditing ? "pencil" : "eye")
        }
        .help(isEditing ? "Switch to read-only preview" : "Edit this document")
        Button("Save", systemImage: "square.and.arrow.down") { saver.flush() }
          .keyboardShortcut("s", modifiers: .command)
          .disabled(saver.state != .unsaved)
          .help("Edits save automatically; ⌘S saves right away.")
      }
      if case .document(let file, _) = content, isStandalone(file) {
        Button("Add Enclosing Folder…", systemImage: "folder.badge.plus") {
          addEnclosingFolder(of: file)
        }
        .help(
          "Add “\(file.deletingLastPathComponent().lastPathComponent)” to the sidebar, so this file’s images and links work."
        )
      }
      Button("Reload", systemImage: "arrow.clockwise") { refresh() }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(navigator.selection == nil)
      #if os(macOS)
        if case .document(let file, _) = content {
          Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([file])
          }
        }
      #endif
    }
  }

  private var title: String {
    navigator.selection?.lastPathComponent ?? "Markdown"
  }

  /// The file actually shown when it differs from the selection (a folder's README).
  private var subtitle: String {
    guard case .document(let file, _) = content, file != navigator.selection else { return "" }
    return file.lastPathComponent
  }

  // MARK: - Loading

  private func load() async {
    saver.flush()  // the previous document's pending edits
    guard let selection = navigator.selection else {
      content = .empty
      return
    }
    let file: URL
    if FolderLibrary.isDirectory(selection) {
      guard let readme = library.readme(in: selection) else {
        content = .noReadme(folder: selection)
        return
      }
      file = readme
    } else {
      file = selection
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
  /// detects.
  nonisolated private static func read(_ url: URL) throws -> String {
    if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
    var encoding = String.Encoding.utf8
    return try String(contentsOf: url, usedEncoding: &encoding)
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

  private var roots: [URL] { folders.filter { !$0.isFile }.compactMap { library.url(for: $0) } }

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
