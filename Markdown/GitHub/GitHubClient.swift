import CryptoKit
import Foundation

/// The slice of the GitHub REST API the app uses: the signed-in user, their
/// repositories, and the Git Data API (refs, commits, trees, blobs) — enough to clone,
/// pull and push a repository's notes without git itself.
nonisolated struct GitHubClient: Sendable {
  /// nil: anonymous (public repositories, 60 requests an hour).
  var token: String?
  var session: URLSession = .shared

  static let api = URL(string: "https://api.github.com")!

  struct User: Decodable, Sendable { let login: String }

  struct Repository: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let fullName: String
    let name: String
    let owner: Owner
    let defaultBranch: String
    let isPrivate: Bool
    let description: String?
    struct Owner: Decodable, Hashable, Sendable { let login: String }
    enum CodingKeys: String, CodingKey {
      case id, name, owner, description
      case fullName = "full_name"
      case defaultBranch = "default_branch"
      case isPrivate = "private"
    }
  }

  struct TreeEntry: Decodable, Sendable {
    let path: String
    let mode: String
    let type: String
    let sha: String
    let size: Int?
  }

  struct Failure: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? {
      switch status {
      case 401: "GitHub didn’t accept the sign-in. Sign in again."
      case 403 where message.localizedCaseInsensitiveContains("rate limit"):
        "GitHub’s rate limit is reached. Sign in, or try again later."
      case 404: "GitHub couldn’t find it (or the account has no access): \(message)"
      default: "GitHub: \(message) (\(status))"
      }
    }
  }

  // MARK: - Account

  func user() async throws -> User {
    try await get("user")
  }

  /// The user's repositories, most recently updated first (up to 300).
  func repositories() async throws -> [Repository] {
    var all: [Repository] = []
    for page in 1...3 {
      let batch: [Repository] = try await get(
        "user/repos",
        query: [
          "per_page": "100", "page": "\(page)", "sort": "updated",
          "affiliation": "owner,collaborator,organization_member",
        ])
      all += batch
      if batch.count < 100 { break }
    }
    return all
  }

  func repository(owner: String, name: String) async throws -> Repository {
    try await get("repos/\(owner)/\(name)")
  }

  // MARK: - Git data

  /// The commit a branch points at.
  func head(owner: String, name: String, branch: String) async throws -> String {
    struct Ref: Decodable { let object: Object }
    struct Object: Decodable { let sha: String }
    let ref: Ref = try await get("repos/\(owner)/\(name)/git/ref/heads/\(branch)")
    return ref.object.sha
  }

  /// A commit's tree.
  func tree(owner: String, name: String, commit: String) async throws -> String {
    struct Commit: Decodable { let tree: Tree }
    struct Tree: Decodable { let sha: String }
    let c: Commit = try await get("repos/\(owner)/\(name)/git/commits/\(commit)")
    return c.tree.sha
  }

  /// Every file in a tree, recursively.
  func files(owner: String, name: String, tree: String) async throws -> [TreeEntry] {
    struct Tree: Decodable { let tree: [TreeEntry] }
    let t: Tree = try await get(
      "repos/\(owner)/\(name)/git/trees/\(tree)", query: ["recursive": "1"])
    return t.tree.filter { $0.type == "blob" }
  }

  func blob(owner: String, name: String, sha: String) async throws -> Data {
    try await data(
      request(
        "repos/\(owner)/\(name)/git/blobs/\(sha)", accept: "application/vnd.github.raw+json"))
  }

  func createBlob(owner: String, name: String, content: Data) async throws -> String {
    struct Created: Decodable { let sha: String }
    let created: Created = try await send(
      "POST", "repos/\(owner)/\(name)/git/blobs",
      body: ["content": content.base64EncodedString(), "encoding": "base64"])
    return created.sha
  }

  /// A change for `createTree`: a file's new blob, or (nil) its deletion.
  struct Change: Sendable {
    let path: String
    let sha: String?
  }

  func createTree(owner: String, name: String, base: String, changes: [Change]) async throws
    -> String
  {
    struct Created: Decodable { let sha: String }
    let entries: [[String: Any]] = changes.map {
      ["path": $0.path, "mode": "100644", "type": "blob", "sha": $0.sha ?? NSNull()]
    }
    let created: Created = try await send(
      "POST", "repos/\(owner)/\(name)/git/trees", body: ["base_tree": base, "tree": entries])
    return created.sha
  }

  func createCommit(owner: String, name: String, message: String, tree: String, parent: String)
    async throws -> String
  {
    struct Created: Decodable { let sha: String }
    let created: Created = try await send(
      "POST", "repos/\(owner)/\(name)/git/commits",
      body: ["message": message, "tree": tree, "parents": [parent]])
    return created.sha
  }

  /// Moves the branch to `commit` — only forward (never force).
  func updateBranch(owner: String, name: String, branch: String, to commit: String) async throws {
    struct Ref: Decodable { let ref: String }
    let _: Ref = try await send(
      "PATCH", "repos/\(owner)/\(name)/git/refs/heads/\(branch)",
      body: ["sha": commit, "force": false])
  }

  /// Git's object id for file contents: SHA-1 of "blob <size>\0<bytes>". Equal ids mean
  /// equal contents, so local edits are found without asking GitHub.
  static func blobSHA(_ data: Data) -> String {
    var hasher = Insecure.SHA1()
    hasher.update(data: Data("blob \(data.count)\0".utf8))
    hasher.update(data: data)
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Requests

  private func request(_ path: String, query: [String: String] = [:], accept: String? = nil)
    -> URLRequest
  {
    var components = URLComponents(
      url: Self.api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty {
      components.queryItems = query.sorted { $0.key < $1.key }.map {
        URLQueryItem(name: $0.key, value: $0.value)
      }
    }
    var request = URLRequest(url: components.url!)
    request.setValue(accept ?? "application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    return request
  }

  private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
    try JSONDecoder().decode(T.self, from: try await data(request(path, query: query)))
  }

  private func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any])
    async throws -> T
  {
    var request = request(path)
    request.httpMethod = method
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return try JSONDecoder().decode(T.self, from: try await data(request))
  }

  private func data(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      struct Message: Decodable { let message: String }
      let message =
        (try? JSONDecoder().decode(Message.self, from: data))?.message
        ?? HTTPURLResponse.localizedString(forStatusCode: status)
      throw Failure(status: status, message: message)
    }
    return data
  }
}
