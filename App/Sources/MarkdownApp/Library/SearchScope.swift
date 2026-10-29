import Foundation

/// Everything a search covers: the notes folder, GitHub repositories, sidebar folders
/// and files opened on their own (only those files, not their folders).
struct SearchScope {
  let roots: [(name: String, url: URL)]
  let openedFiles: Set<URL>
  let folderRoots: [URL]

  init(
    library: FolderLibrary, notes: NotesLocation, repositories: RepositoryStore,
    folders: [SidebarFolder]
  ) {
    var roots: [(name: String, url: URL)] = []
    if let url = notes.url { roots.append(("Notes", url)) }
    for repository in repositories.repositories {
      roots.append((repository.fullName, repositories.directory(for: repository)))
    }
    for folder in folders {
      guard let url = library.url(for: folder) else { continue }
      roots.append((folder.name, folder.isFile ? url.deletingLastPathComponent() : url))
    }
    self.roots = roots
    openedFiles = Set(folders.filter(\.isFile).compactMap { library.url(for: $0) })
    folderRoots = library.roots(folders)
  }

  /// Notes matching `query`, name matches first (see `NoteSearch`).
  func search(_ query: String) async -> [SearchResult] {
    let roots = roots
    let found = await Task.detached(priority: .userInitiated) {
      NoteSearch.search(query, in: roots)
    }.value
    // A single opened file's folder was searched to reach the file: drop its neighbors.
    let fileFolders = Set(openedFiles.map { $0.deletingLastPathComponent() })
    return found.filter { result in
      !fileFolders.contains(result.url.deletingLastPathComponent())
        || openedFiles.contains(result.url)
        || folderRoots.contains { result.url.path.hasPrefix($0.path + "/") }
    }
  }
}
