import Foundation

/// A connected repository's sync state: the commit the local copy is based on, and the
/// blob id of every synced file at that commit. Comparing a file's current blob id with
/// the recorded one tells whether it was edited here; comparing the recorded one with
/// GitHub's tells whether it changed there.
nonisolated struct RepositoryState: Codable, Hashable, Sendable {
  var owner: String
  var name: String
  var branch: String
  var headCommit: String
  var headTree: String
  /// Path (relative, "/"-separated) → blob id at `headCommit`.
  var files: [String: String]
  /// Read-only: added without signing in (public repositories); push is unavailable.
  var isAnonymous = false

  var fullName: String { "\(owner)/\(name)" }
}

/// Clone, pull and push for a repository's notes through GitHub's Git Data API.
///
/// Only notes travel — markdown files and the images they show (up to 10 MB each); the
/// rest of the repository stays on GitHub. Pull is a three-way merge per file: a file
/// changed only on GitHub is updated, one changed only here is kept, and one changed on
/// both keeps the local text with GitHub's version saved beside it as
/// "Name (GitHub).md" to merge by hand. Push commits the local changes on top of the
/// latest commit and moves the branch forward (never forced).
nonisolated enum RepositorySync {
  static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic"]
  static let maxFileSize = 10_000_000

  struct Change: Hashable, Sendable {
    enum Kind: Sendable { case added, modified, deleted }
    let path: String
    let kind: Kind
  }

  struct PullResult: Sendable {
    var state: RepositoryState
    var updated: Int
    /// Paths changed on both sides; GitHub's version sits beside each.
    var conflicts: [String]
  }

  struct Rejected: LocalizedError {
    let errorDescription: String?
  }

  static func isSynced(_ path: String, size: Int?) -> Bool {
    guard (size ?? 0) <= maxFileSize else { return false }
    let ext = (path as NSString).pathExtension.lowercased()
    return FolderLibrary.markdownExtensions.contains(ext) || imageExtensions.contains(ext)
  }

  // MARK: - Clone

  static func clone(
    client: GitHubClient, owner: String, name: String, branch: String, into directory: URL
  ) async throws -> RepositoryState {
    let head = try await client.head(owner: owner, name: name, branch: branch)
    let tree = try await client.tree(owner: owner, name: name, commit: head)
    let remote = try await syncedFiles(client: client, owner: owner, name: name, tree: tree)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try await download(remote, client: client, owner: owner, name: name, into: directory)
    return RepositoryState(
      owner: owner, name: name, branch: branch, headCommit: head, headTree: tree, files: remote,
      isAnonymous: client.token == nil)
  }

  // MARK: - Local changes

  /// Synced files in the working copy, path → blob id.
  static func localFiles(in directory: URL) -> [String: String] {
    var result: [String: String] = [:]
    let base = directory.standardizedFileURL.path
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
    else { return result }
    for case let url as URL in enumerator {
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values?.isRegularFile == true else { continue }
      let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
      guard isSynced(path, size: values?.fileSize), let data = try? Data(contentsOf: url) else {
        continue
      }
      result[path] = GitHubClient.blobSHA(data)
    }
    return result
  }

  static func changes(_ state: RepositoryState, in directory: URL) -> [Change] {
    let local = localFiles(in: directory)
    var changes: [Change] = []
    for (path, sha) in local where state.files[path] != sha {
      changes.append(Change(path: path, kind: state.files[path] == nil ? .added : .modified))
    }
    for path in state.files.keys where local[path] == nil {
      changes.append(Change(path: path, kind: .deleted))
    }
    return changes.sorted { $0.path < $1.path }
  }

  // MARK: - Pull

  static func pull(client: GitHubClient, state: RepositoryState, directory: URL) async throws
    -> PullResult
  {
    let head = try await client.head(owner: state.owner, name: state.name, branch: state.branch)
    guard head != state.headCommit else { return PullResult(state: state, updated: 0, conflicts: []) }
    let tree = try await client.tree(owner: state.owner, name: state.name, commit: head)
    let remote = try await syncedFiles(
      client: client, owner: state.owner, name: state.name, tree: tree)
    let local = localFiles(in: directory)

    var downloads: [String: String] = [:]  // path → blob, written at path
    var conflictCopies: [String: String] = [:]  // conflict copy path → blob
    var deletions: [String] = []
    var conflicts: [String] = []
    var files = remote
    for path in Set(remote.keys).union(state.files.keys) {
      let base = state.files[path]
      let theirs = remote[path]
      let ours = local[path]
      guard theirs != base else { continue }  // unchanged on GitHub: keep whatever is here
      if ours == base || ours == theirs {
        // Changed only on GitHub (or identically on both sides).
        if let theirs, ours != theirs { downloads[path] = theirs } else if theirs == nil, ours != nil { deletions.append(path) }
      } else if let theirs {
        // Changed on both sides: keep ours, put theirs beside it.
        conflicts.append(path)
        conflictCopies[conflictPath(for: path)] = theirs
      } else {
        // Deleted on GitHub, edited here: keep the file; it becomes a local addition.
        files[path] = nil
      }
    }
    try await download(
      downloads, client: client, owner: state.owner, name: state.name, into: directory)
    try await download(
      conflictCopies, client: client, owner: state.owner, name: state.name, into: directory)
    for path in deletions {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(path))
    }
    var next = state
    next.headCommit = head
    next.headTree = tree
    next.files = files
    return PullResult(
      state: next, updated: downloads.count + deletions.count, conflicts: conflicts.sorted())
  }

  /// "docs/Guide.md" → "docs/Guide (GitHub).md".
  static func conflictPath(for path: String) -> String {
    let ns = path as NSString
    let ext = ns.pathExtension
    let stem = ns.deletingPathExtension
    return ext.isEmpty ? "\(stem) (GitHub)" : "\(stem) (GitHub).\(ext)"
  }

  // MARK: - Push

  /// Commits the local changes as one commit and moves the branch to it. GitHub must
  /// still be at `state.headCommit` (pull first); a rejected update changes nothing.
  static func push(
    client: GitHubClient, state: RepositoryState, directory: URL, message: String
  ) async throws -> RepositoryState {
    let changes = changes(state, in: directory)
    guard !changes.isEmpty else { return state }
    var treeChanges: [GitHubClient.Change] = []
    var files = state.files
    for change in changes {
      switch change.kind {
      case .deleted:
        treeChanges.append(.init(path: change.path, sha: nil))
        files[change.path] = nil
      case .added, .modified:
        let data = try Data(contentsOf: directory.appendingPathComponent(change.path))
        let sha = try await client.createBlob(owner: state.owner, name: state.name, content: data)
        treeChanges.append(.init(path: change.path, sha: sha))
        files[change.path] = sha
      }
    }
    let tree = try await client.createTree(
      owner: state.owner, name: state.name, base: state.headTree, changes: treeChanges)
    let commit = try await client.createCommit(
      owner: state.owner, name: state.name, message: message, tree: tree,
      parent: state.headCommit)
    do {
      try await client.updateBranch(
        owner: state.owner, name: state.name, branch: state.branch, to: commit)
    } catch let failure as GitHubClient.Failure where failure.status == 422 {
      throw Rejected(errorDescription: "GitHub has newer commits on \(state.branch). Pull, then push again.")
    }
    var next = state
    next.headCommit = commit
    next.headTree = tree
    next.files = files
    return next
  }

  // MARK: - Helpers

  private static func syncedFiles(
    client: GitHubClient, owner: String, name: String, tree: String
  ) async throws -> [String: String] {
    let entries = try await client.files(owner: owner, name: name, tree: tree)
    var files: [String: String] = [:]
    for entry in entries where entry.mode != "120000" && isSynced(entry.path, size: entry.size) {
      files[entry.path] = entry.sha
    }
    return files
  }

  /// Downloads blobs (path → blob id) into `directory`, a few at a time.
  private static func download(
    _ files: [String: String], client: GitHubClient, owner: String, name: String,
    into directory: URL
  ) async throws {
    let jobs = Array(files)
    var next = 0
    try await withThrowingTaskGroup(of: (String, Data).self) { group in
      func enqueue() {
        guard next < jobs.count else { return }
        let (path, sha) = jobs[next]
        next += 1
        group.addTask { (path, try await client.blob(owner: owner, name: name, sha: sha)) }
      }
      for _ in 0..<6 { enqueue() }
      while let (path, data) = try await group.next() {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        enqueue()
      }
    }
  }
}
