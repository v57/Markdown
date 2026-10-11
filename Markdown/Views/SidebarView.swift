import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The folder sidebar. Folders are added by dropping them on it (Finder, Files) or with
/// the Add Folder button, persisted in SwiftData, and shown as expandable trees of
/// subfolders and markdown files.
struct SidebarView: View {
  @Environment(FolderLibrary.self) private var library
  @Environment(Navigator.self) private var navigator
  @Environment(\.modelContext) private var context
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]
  @State private var isImporting = false
  @State private var isDropTargeted = false

  var body: some View {
    @Bindable var navigator = navigator
    List(selection: $navigator.selection) {
      Section("Folders") {
        ForEach(folders) { folder in
          FolderRootRow(folder: folder)
        }
        #if os(iOS)
          .onDelete { offsets in
            for index in offsets {
              remove(folders[index], library: library, navigator: navigator, context: context)
            }
          }
        #endif
      }
    }
    .overlay {
      if folders.isEmpty {
        ContentUnavailableView {
          Label("No Folders", systemImage: "folder.badge.plus")
        } description: {
          Text("Drop folders here, or add one to browse its markdown files.")
        } actions: {
          Button("Add Folder…") { isImporting = true }
        }
      }
    }
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
    .toolbar {
      ToolbarItem {
        Button("Add Folder…", systemImage: "folder.badge.plus") { isImporting = true }
          .keyboardShortcut("o", modifiers: [.command, .shift])
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
    .navigationTitle("Markdown")
    #if DEBUG && targetEnvironment(simulator)
      .task { addLaunchArgumentFolders() }
    #endif
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

/// A sidebar folder: its tree, or a placeholder when it can no longer be reached.
private struct FolderRootRow: View {
  let folder: SidebarFolder
  @Environment(FolderLibrary.self) private var library
  @Environment(Navigator.self) private var navigator
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
/// its README.
struct FileTreeRow: View {
  let node: FileNode
  var isRoot = false
  @Environment(FolderLibrary.self) private var library

  var body: some View {
    if node.isDirectory {
      DisclosureGroup(isExpanded: expandedBinding) {
        // Read only once expanded; `generation` re-lists after a reload.
        let _ = library.generation
        ForEach(library.children(of: node.url)) { child in
          FileTreeRow(node: child)
        }
      } label: {
        Label(node.name, systemImage: isRoot ? "folder.fill" : "folder")
      }
      .tag(node.url)
    } else {
      Label(node.name, systemImage: "doc.text")
        .tag(node.url)
    }
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
