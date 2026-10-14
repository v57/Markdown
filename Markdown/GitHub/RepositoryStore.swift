import Foundation
import GitHubKit
import Observation

/// The connected GitHub repositories: their local copies (in the app's Application
/// Support, so always accessible) and sync state, and the pull/push/disconnect actions
/// the sidebar offers. See `RepositorySync` for how syncing works.
@Observable final class RepositoryStore {
  private(set) var repositories: [RepositoryState] = []
  /// Repositories with an operation running, and what it is ("Pulling…").
  private(set) var activity: [String: String] = [:]
  /// Local changes per repository (full name → count), refreshed by `refreshChanges()`.
  private(set) var changeCounts: [String: Int] = [:]
  /// The outcome of the last operation, for an alert.
  var message: (title: String, text: String)?
  /// Runs before a pull rewrites files: the open note's pending edits must be on disk,
  /// or they would be taken for unchanged text and overwritten.
  @ObservationIgnored var willChangeFiles: () -> Void = {}
  /// Runs after files changed (re-list the sidebar, reload the open note).
  @ObservationIgnored var didChangeFiles: () -> Void = {}

  @ObservationIgnored private let folder: URL

  init() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    folder = support.appendingPathComponent("GitHub", isDirectory: true)
    repositories = ScreenshotDemo.isOn ? [] : Self.loadStates(in: folder)
  }

  /// The local copy of a repository.
  func directory(for repository: RepositoryState) -> URL {
    FolderLibrary.canonical(
      folder.appendingPathComponent(repository.owner, isDirectory: true)
        .appendingPathComponent(repository.name, isDirectory: true))
  }

  var directories: [URL] { repositories.map(directory(for:)) }

  func repository(containing url: URL) -> RepositoryState? {
    let path = FolderLibrary.canonical(url).path
    return repositories.first {
      let root = directory(for: $0).path
      return path == root || path.hasPrefix(root + "/")
    }
  }

  // MARK: - Actions

  /// Clones `owner/name` and adds it to the sidebar. Returns its local folder.
  @discardableResult
  func connect(owner: String, name: String, client: GitHubAPI) async -> URL? {
    let fullName = "\(owner)/\(name)"
    guard !repositories.contains(where: { $0.fullName.lowercased() == fullName.lowercased() }) else {
      message = ("Already Connected", "\(fullName) is already in the sidebar.")
      return nil
    }
    activity[fullName] = "Downloading…"
    defer { activity[fullName] = nil }
    do {
      let info = try await client.repository(owner: owner, name: name)
      var state = RepositoryState(
        owner: info.owner, name: info.name, branch: info.defaultBranch ?? "main", headCommit: "",
        headTree: "", files: [:])
      let dir = directory(for: state)
      state = try await RepositorySync.clone(
        client: client, owner: state.owner, name: state.name, branch: state.branch, into: dir)
      repositories.append(state)
      try save(state)
      didChangeFiles()
      return dir
    } catch {
      message = ("Couldn’t Connect \(fullName)", error.localizedDescription)
      return nil
    }
  }

  func pull(_ repository: RepositoryState, client: GitHubAPI) async {
    willChangeFiles()
    activity[repository.fullName] = "Pulling…"
    defer { activity[repository.fullName] = nil }
    do {
      let result = try await pulled(repository, client: client)
      if !result.conflicts.isEmpty {
        message = conflictMessage(result.conflicts)
      } else {
        message = (
          repository.fullName,
          result.updated == 0 ? "Already up to date." : "Updated \(result.updated) file\(result.updated == 1 ? "" : "s")."
        )
      }
    } catch {
      message = ("Couldn’t Pull \(repository.fullName)", error.localizedDescription)
    }
    refreshChanges()
  }

  /// Pulls first (GitHub may have moved on), then commits the local changes and pushes.
  /// Conflicts stop it: they need merging by hand.
  func commitAndPush(_ repository: RepositoryState, message commitMessage: String, client: GitHubAPI)
    async
  {
    guard !repository.isAnonymous, client.token != nil else {
      message = ("Sign In to Push", "Sign in to GitHub to push changes to \(repository.fullName).")
      return
    }
    willChangeFiles()
    activity[repository.fullName] = "Pushing…"
    defer { activity[repository.fullName] = nil }
    do {
      let result = try await pulled(repository, client: client)
      guard result.conflicts.isEmpty else {
        message = conflictMessage(result.conflicts)
        refreshChanges()
        return
      }
      let dir = directory(for: result.state)
      let count = RepositorySync.changes(result.state, in: dir).count
      let pushed = try await RepositorySync.push(
        client: client, state: result.state, directory: dir, message: commitMessage)
      replace(pushed)
      try save(pushed)
      message = (
        repository.fullName,
        count == 0 ? "Nothing to commit." : "Pushed \(count) change\(count == 1 ? "" : "s") to \(pushed.branch)."
      )
    } catch {
      message = ("Couldn’t Push \(repository.fullName)", error.localizedDescription)
    }
    refreshChanges()
  }

  /// Removes the repository and its local copy (unpushed changes are lost; the sidebar
  /// asks first).
  func disconnect(_ repository: RepositoryState) {
    willChangeFiles()
    let dir = directory(for: repository)
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.removeItem(at: stateURL(for: repository))
    repositories.removeAll { $0.fullName == repository.fullName }
    changeCounts[repository.fullName] = nil
    didChangeFiles()
  }

  /// Recounts local changes (off the main thread).
  func refreshChanges() {
    let jobs = repositories.map { ($0, directory(for: $0)) }
    Task {
      let counts = await Task.detached(priority: .utility) {
        Dictionary(
          uniqueKeysWithValues: jobs.map { ($0.0.fullName, RepositorySync.changes($0.0, in: $0.1).count) })
      }.value
      changeCounts = counts
    }
  }

  func changes(_ repository: RepositoryState) -> [RepositorySync.Change] {
    RepositorySync.changes(repository, in: directory(for: repository))
  }

  // MARK: - State

  private func pulled(_ repository: RepositoryState, client: GitHubAPI) async throws
    -> RepositorySync.PullResult
  {
    let result = try await RepositorySync.pull(
      client: client, state: repository, directory: directory(for: repository))
    replace(result.state)
    try save(result.state)
    if result.updated > 0 || !result.conflicts.isEmpty { didChangeFiles() }
    return result
  }

  private func conflictMessage(_ conflicts: [String]) -> (title: String, text: String) {
    (
      "Changed Here and on GitHub",
      "Your version is kept and GitHub’s is saved beside it. Merge them, delete the “(GitHub)” copy, then push:\n"
        + conflicts.joined(separator: "\n")
    )
  }

  private func replace(_ state: RepositoryState) {
    if let index = repositories.firstIndex(where: { $0.fullName == state.fullName }) {
      repositories[index] = state
    }
  }

  private func stateURL(for repository: RepositoryState) -> URL {
    folder.appendingPathComponent(repository.owner, isDirectory: true)
      .appendingPathComponent("\(repository.name).json")
  }

  private func save(_ state: RepositoryState) throws {
    let url = stateURL(for: state)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(state).write(to: url, options: .atomic)
  }

  private static func loadStates(in folder: URL) -> [RepositoryState] {
    let fm = FileManager.default
    guard let owners = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    else { return [] }
    return owners.flatMap { owner -> [RepositoryState] in
      let files = (try? fm.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil)) ?? []
      return files.filter { $0.pathExtension == "json" }.compactMap {
        try? JSONDecoder().decode(RepositoryState.self, from: Data(contentsOf: $0))
      }
    }.sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
  }
}
