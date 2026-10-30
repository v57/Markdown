import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

/// One row of a folder tree: a subdirectory or a markdown file.
struct FileNode: Identifiable, Hashable {
  let url: URL
  let isDirectory: Bool
  var id: URL { url }
  var name: String { url.lastPathComponent }
}

/// Access to the sidebar's folders and their contents.
///
/// Resolves each `SidebarFolder`'s bookmark to a URL once per run and keeps its
/// security-scoped access open while the folder is in the sidebar (README images and
/// linked files are read lazily, long after the folder was resolved). Directory
/// listings are cached until `reload()`; expansion state is per run.
@Observable final class FolderLibrary {
  /// Directories whose disclosure group is open.
  var expanded: Set<URL> = []
  /// Bumped by `reload()` so views re-read listings and documents.
  private(set) var generation = 0
  /// Why the last add failed, for an alert.
  var lastError: String?
  /// The app's own folders, beside the sidebar folders: the notes folder (and GitHub
  /// repositories). Always accessible — they live in the app's container or iCloud.
  var builtInRoots: [URL] = []
  /// The folders of the shared projects on this device (canonical paths, `SidebarProjects`): the only folders the
  /// sidebar keeps, in its Projects section. A folder added before then that isn't one stays stored, out of the way.
  var projectPaths: Set<String> = []

  @ObservationIgnored private var resolved: [PersistentIdentifier: URL] = [:]
  @ObservationIgnored private var accessing: Set<URL> = []
  @ObservationIgnored private var listings: [URL: [FileNode]] = [:]

  /// `mdenc` is an encrypted note (`NoteFiles`).
  nonisolated static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdenc"]

  // MARK: - Folders

  /// Adds dropped, picked or opened items to the sidebar: a shared project's folder (access to it), text files as
  /// single files — unless a sidebar folder already holds them. Returns what to
  /// show for each item (new or already there); anything else is reported in `lastError`.
  @discardableResult
  func add(_ urls: [URL], existing: [SidebarFolder], context: ModelContext) -> [URL] {
    var known = Set(existing.map(\.path))
    let roots = roots(existing)
    var shown: [URL] = []
    for url in urls {
      let started = url.startAccessingSecurityScopedResource()
      let standardized = Self.canonical(url)
      let isDirectory = Self.isDirectory(standardized)
      guard isDirectory || Self.isText(standardized) else {
        if started { url.stopAccessingSecurityScopedResource() }
        lastError = "“\(url.lastPathComponent)” is not a folder or a text file."
        continue
      }
      // Anything inside a sidebar folder is shown there, with its folder's access.
      if root(of: standardized, roots: roots) != nil {
        if started { url.stopAccessingSecurityScopedResource() }
        reveal(standardized, roots: roots)
        shown.append(standardized)
        continue
      }
      // A folder joins the sidebar only as a shared project's (the Projects section).
      guard !isDirectory || projectPaths.contains(standardized.path) else {
        if started { url.stopAccessingSecurityScopedResource() }
        lastError =
          "“\(url.lastPathComponent)” isn’t one of your projects. Markdown shows the notes folder, connected GitHub repositories and the projects the v57 apps share: add the folder as a project in Code or Git."
        continue
      }
      guard known.insert(standardized.path).inserted else {
        if started { url.stopAccessingSecurityScopedResource() }
        shown.append(standardized)
        continue
      }
      let bookmark = try? standardized.bookmarkData(
        options: Self.bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
      let folder = SidebarFolder(path: standardized.path, bookmark: bookmark, isFile: !isDirectory)
      context.insert(folder)
      // Keep the access the drop/picker granted; the bookmark takes over next launch.
      if started { accessing.insert(url) }
      resolved[folder.persistentModelID] = standardized
      shown.append(standardized)
    }
    try? context.save()
    return shown
  }

  /// Removes a folder from the sidebar (the folder on disk is untouched).
  func remove(_ folder: SidebarFolder, context: ModelContext) {
    if let url = resolved.removeValue(forKey: folder.persistentModelID),
      let held = accessing.first(where: { Self.canonical($0) == url })
    {
      held.stopAccessingSecurityScopedResource()
      accessing.remove(held)
    }
    context.delete(folder)
    try? context.save()
  }

  /// Replaces a folder's access with what the user just granted (`granted`, from an
  /// open panel): a fresh bookmark — read-write — and that access for this run.
  func regrant(_ folder: SidebarFolder, with granted: URL, context: ModelContext) {
    if let old = resolved.removeValue(forKey: folder.persistentModelID) {
      for held in accessing where Self.canonical(held) == old {
        held.stopAccessingSecurityScopedResource()
        accessing.remove(held)
      }
    }
    if granted.startAccessingSecurityScopedResource() { accessing.insert(granted) }
    let url = Self.canonical(granted)
    folder.bookmark = try? url.bookmarkData(
      options: Self.bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    folder.path = url.path
    resolved[folder.persistentModelID] = url
    try? context.save()
  }

  /// The folder's URL with access granted, or nil when it can no longer be reached
  /// (moved, deleted, bookmark unresolvable).
  func url(for folder: SidebarFolder) -> URL? {
    // A removed folder's row can render once more while it animates out. Resolving it
    // then would reopen its access, and refreshing a stale bookmark would write to the
    // deleted model — which brought removed folders back on the next save.
    guard !folder.isDeleted, folder.modelContext != nil else { return nil }
    if let url = resolved[folder.persistentModelID] { return url }
    var url = URL(fileURLWithPath: folder.path, isDirectory: true)
    if let bookmark = folder.bookmark {
      var stale = false
      if let fromBookmark = try? URL(
        resolvingBookmarkData: bookmark, options: Self.bookmarkResolutionOptions, relativeTo: nil,
        bookmarkDataIsStale: &stale)
      {
        if fromBookmark.startAccessingSecurityScopedResource() { accessing.insert(fromBookmark) }
        url = Self.canonical(fromBookmark)
        if stale, let fresh = try? url.bookmarkData(
          options: Self.bookmarkCreationOptions, includingResourceValuesForKeys: nil,
          relativeTo: nil)
        {
          // Moved or renamed: refresh the bookmark and the displayed path (only what
          // changed — every write marks the model dirty).
          if folder.bookmark != fresh { folder.bookmark = fresh }
          if folder.path != url.path { folder.path = url.path }
        }
      }
    }
    let exists =
      folder.isFile ? FileManager.default.fileExists(atPath: url.path) : Self.isDirectory(url)
    guard exists else { return nil }
    resolved[folder.persistentModelID] = url
    return url
  }

  #if os(macOS)
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
  #else
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
  #endif

  // MARK: - Contents

  /// A directory's subdirectories and markdown files — folders first, then files, each
  /// in Finder order. Hidden items and packages (.app, .xcodeproj) are left out.
  func children(of directory: URL) -> [FileNode] {
    if let cached = listings[directory] { return cached }
    let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
    let items =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: keys, options: [])) ?? []
    var folders: [FileNode] = []
    var files: [FileNode] = []
    for item in items {
      // A note iCloud has not downloaded yet: ".Name.md.icloud" stands for "Name.md".
      // Listed by its real name; reading it (coordinated) downloads it.
      if let placeholder = Self.iCloudPlaceholderTarget(item) {
        if Self.isMarkdown(placeholder) { files.append(FileNode(url: Self.canonical(placeholder), isDirectory: false)) }
        continue
      }
      guard !item.lastPathComponent.hasPrefix(".") else { continue }
      let values = try? item.resourceValues(forKeys: Set(keys))
      guard values?.isHidden != true else { continue }
      if values?.isDirectory == true {
        if values?.isPackage != true { folders.append(FileNode(url: Self.canonical(item), isDirectory: true)) }
      } else if Self.markdownExtensions.contains(item.pathExtension.lowercased()) {
        files.append(FileNode(url: Self.canonical(item), isDirectory: false))
      }
    }
    let order: (FileNode, FileNode) -> Bool = {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    let result = folders.sorted(by: order) + files.sorted(by: order)
    listings[directory] = result
    return result
  }

  /// The README GitHub would show for `directory`: in the folder itself, then in
  /// `.github/` and `docs/`. Matched case-insensitively (README.md, readme.markdown…).
  func readme(in directory: URL) -> URL? {
    for sub in ["", ".github", "docs"] {
      let dir = sub.isEmpty ? directory : directory.appendingPathComponent(sub, isDirectory: true)
      guard
        let items = try? FileManager.default.contentsOfDirectory(
          at: dir, includingPropertiesForKeys: nil)
      else { continue }
      let candidates = items.filter {
        $0.deletingPathExtension().lastPathComponent.lowercased() == "readme"
          && Self.markdownExtensions.contains($0.pathExtension.lowercased())
      }
      // Prefer the canonical README.md when several spellings exist.
      if let best = candidates.min(by: { lhs, rhs in
        (lhs.pathExtension.lowercased() == "md" ? 0 : 1, lhs.lastPathComponent)
          < (rhs.pathExtension.lowercased() == "md" ? 0 : 1, rhs.lastPathComponent)
      }) {
        return Self.canonical(best)
      }
    }
    return nil
  }

  /// Every folder whose files the app shows and edits: the built-in ones and the
  /// sidebar folders (not single opened files).
  func roots(_ folders: [SidebarFolder]) -> [URL] {
    builtInRoots + folders.filter { !$0.isFile && projectPaths.contains($0.path) }.compactMap { url(for: $0) }
  }

  /// The sidebar folder `url` lives in (the innermost, when folders nest) — what a
  /// root-relative path (`/docs/a.png`) in its documents means.
  func root(of url: URL, roots: [URL]) -> URL? {
    let path = Self.canonical(url).path
    return roots.filter { path.hasPrefix($0.path + "/") || path == $0.path }
      .max { $0.path.count < $1.path.count }
  }

  /// Opens every ancestor of `url` below its sidebar root, so a link target is visible.
  func reveal(_ url: URL, roots: [URL]) {
    guard let root = root(of: url, roots: roots) else { return }
    var dir = Self.canonical(url).deletingLastPathComponent()
    while dir.path.count >= root.path.count, dir.path.hasPrefix(root.path) {
      expanded.insert(Self.canonical(dir))
      dir = dir.deletingLastPathComponent()
    }
  }

  /// Forgets cached listings and asks views to re-read what they show.
  func reload() {
    listings.removeAll()
    generation += 1
  }

  /// One spelling per file: `contentsOfDirectory` answers `/private/tmp/…` for a
  /// folder added as `/tmp/…`, while links resolve to `/tmp/…` — equal files, unequal
  /// URLs, so a selected link target matched no sidebar row. Every URL entering the
  /// tree, the selection or the history goes through here (standardized path, trailing
  /// slash for directories, no base URL).
  nonisolated static func canonical(_ url: URL) -> URL {
    URL(fileURLWithPath: url.standardizedFileURL.path)
  }

  /// The file an iCloud placeholder (".Name.md.icloud") stands for.
  nonisolated static func iCloudPlaceholderTarget(_ url: URL) -> URL? {
    let name = url.lastPathComponent
    guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".x.icloud".count - 1
    else { return nil }
    let real = String(name.dropFirst().dropLast(".icloud".count))
    return url.deletingLastPathComponent().appendingPathComponent(real)
  }

  nonisolated static func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
  }

  nonisolated static func isMarkdown(_ url: URL) -> Bool {
    markdownExtensions.contains(url.pathExtension.lowercased())
  }

  /// Markdown, anything the system types as text, and extensionless files (README,
  /// LICENSE) — what the app opens and edits.
  nonisolated static func isText(_ url: URL) -> Bool {
    if isMarkdown(url) || url.pathExtension.isEmpty { return true }
    return UTType(filenameExtension: url.pathExtension)?.conforms(to: .text) ?? false
  }
}

/// What the detail pane shows, with back/forward history. Selecting a folder shows its
/// README; following a link pushes the previous selection.
@Observable final class Navigator {
  /// The place whose notes the sidebar lists.
  var item: LibraryItem?
  /// The shown note, or a folder whose README is shown (a link to a folder).
  var selection: URL? {
    didSet {
      guard selection != oldValue else { return }
      if !isTraversing, let oldValue {
        back.append(oldValue)
        forward.removeAll()
      }
      if !keepsAnchor { anchor = nil }
      startsEditing = false
    }
  }
  /// The in-page anchor to scroll to in the shown document.
  var anchor: String?
  /// The shown document was just created: the editor takes the keyboard focus.
  var startsEditing = false
  private(set) var back: [URL] = []
  private(set) var forward: [URL] = []
  @ObservationIgnored private var isTraversing = false
  @ObservationIgnored private var keepsAnchor = false

  /// Lists `item`'s notes in the sidebar; the shown note stays when it is one of them.
  func choose(_ item: LibraryItem, notesFolder: URL?, openedFiles: Set<String>) {
    self.item = item
    guard let selection else { return }
    let isListed =
      switch item {
      case .allNotes: notesFolder.map { selection.path.hasPrefix($0.path + "/") } ?? false
      case .folder(let folder): selection.deletingLastPathComponent() == folder
      case .openedFiles: openedFiles.contains(selection.path)
      }
    if !isListed { self.selection = nil }
  }

  /// Shows `url`, scrolled to `anchor` if given.
  func open(_ url: URL, anchor: String? = nil) {
    keepsAnchor = true
    defer { keepsAnchor = false }
    self.anchor = anchor
    selection = url
  }

  /// Follows a rename or move: the listed folder, the selection and history entries at
  /// or inside `old` point into `new` instead.
  func replace(_ old: URL, with new: URL) {
    let root = FolderLibrary.canonical(old).path
    func moved(_ url: URL) -> URL {
      let path = FolderLibrary.canonical(url).path
      guard path == root || path.hasPrefix(root + "/") else { return url }
      return URL(fileURLWithPath: new.path + path.dropFirst(root.count))
    }
    back = back.map(moved)
    forward = forward.map(moved)
    if case .folder(let listed) = item { item = .folder(moved(listed)) }
    if let selection {
      isTraversing = true
      keepsAnchor = true
      self.selection = moved(selection)
      keepsAnchor = false
      isTraversing = false
    }
  }

  /// Drops the listed folder, the selection and history entries inside `folder` (it was
  /// deleted, or left the sidebar and with it the app's access).
  func forget(under folder: URL) {
    let root = FolderLibrary.canonical(folder).path
    func isInside(_ url: URL) -> Bool {
      let path = FolderLibrary.canonical(url).path
      return path == root || path.hasPrefix(root + "/")
    }
    back.removeAll(where: isInside)
    forward.removeAll(where: isInside)
    if case .folder(let listed) = item, isInside(listed) { item = nil }
    if let selection, isInside(selection) {
      isTraversing = true
      self.selection = nil
      isTraversing = false
    }
  }

  /// Shows nothing and forgets the history, as at launch (a screenshot scene opened in place).
  func reset() {
    isTraversing = true
    selection = nil
    isTraversing = false
    back.removeAll()
    forward.removeAll()
    anchor = nil
  }

  func goBack() {
    guard let previous = back.popLast() else { return }
    if let selection { forward.append(selection) }
    traverse(to: previous)
  }

  func goForward() {
    guard let next = forward.popLast() else { return }
    if let selection { back.append(selection) }
    traverse(to: next)
  }

  private func traverse(to url: URL) {
    isTraversing = true
    defer { isTraversing = false }
    selection = url
  }
}
