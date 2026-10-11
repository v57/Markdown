import SwiftUI

/// The Connect GitHub sheet: sign in (device flow), then pick one of your repositories —
/// or add any public repository by name, signed in or not (read-only without sign-in).
struct GitHubConnectView: View {
  @Environment(GitHubAuth.self) private var auth
  @Environment(RepositoryStore.self) private var store
  @Environment(Navigator.self) private var navigator
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @State private var repositories: [GitHubClient.Repository] = []
  @State private var isLoading = false
  @State private var filter = ""
  @State private var publicName = ""

  var body: some View {
    NavigationStack {
      Form {
        account
        if case .signedIn = auth.state {
          yourRepositories
        }
        Section {
          HStack {
            TextField("owner/repository", text: $publicName)
              .autocorrectionDisabled()
              #if os(iOS)
                .textInputAutocapitalization(.never)
              #endif
              .onSubmit(addPublic)
            Button("Add", action: addPublic)
              .disabled(parsed(publicName) == nil)
          }
        } header: {
          Text("Any Public Repository")
        } footer: {
          Text("Only Markdown files and their images are downloaded.")
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Connect GitHub")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task(id: auth.token) { await loadRepositories() }
      .alert(
        "GitHub",
        isPresented: Binding(get: { auth.error != nil }, set: { if !$0 { auth.error = nil } })
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(auth.error ?? "")
      }
    }
    #if os(macOS)
      .frame(minWidth: 460, minHeight: 520)
    #endif
  }

  @ViewBuilder private var account: some View {
    Section("Account") {
      switch auth.state {
      case .signedOut:
        Button("Sign In with GitHub…") { auth.signIn() }
        Text("Signing in lets you edit your repositories, including private ones, and push changes.")
          .font(.callout).foregroundStyle(.secondary)
      case .waiting(let code, let url):
        VStack(alignment: .leading, spacing: 10) {
          Text("Enter this code on GitHub:")
          Text(code)
            .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
            .textSelection(.enabled)
          Button("Copy Code and Open GitHub") {
            copy(code)
            openURL(url)
          }
          .buttonStyle(.borderedProminent)
          HStack {
            ProgressView().controlSize(.small)
            Text("Waiting for you to approve…").foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { auth.cancelSignIn() }
          }
        }
        .padding(.vertical, 4)
      case .signedIn(let login):
        HStack {
          Label("@\(login)", systemImage: "person.crop.circle")
          Spacer()
          Button("Sign Out") { auth.signOut() }
        }
      }
    }
  }

  @ViewBuilder private var yourRepositories: some View {
    Section("Your Repositories") {
      TextField("Filter", text: $filter)
      if isLoading {
        ProgressView().frame(maxWidth: .infinity)
      }
      ForEach(filtered) { repository in
        let connected = store.repositories.contains { $0.fullName == repository.fullName }
        let busy = store.activity[repository.fullName]
        Button {
          connect(owner: repository.owner.login, name: repository.name)
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 4) {
                Text(repository.fullName)
                if repository.isPrivate {
                  Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                }
              }
              if let description = repository.description, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
            }
            Spacer()
            if let busy {
              ProgressView().controlSize(.small)
              Text(busy).font(.caption).foregroundStyle(.secondary)
            } else if connected {
              Image(systemName: "checkmark").foregroundStyle(.secondary)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(connected || busy != nil)
      }
    }
  }

  private var filtered: [GitHubClient.Repository] {
    let query = filter.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return repositories }
    return repositories.filter { $0.fullName.localizedCaseInsensitiveContains(query) }
  }

  private func loadRepositories() async {
    guard case .signedIn = auth.state else {
      repositories = []
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      repositories = try await auth.client.repositories()
    } catch {
      auth.error = error.localizedDescription
    }
  }

  /// "owner/name", a github.com URL, or "github.com/owner/name".
  private func parsed(_ text: String) -> (owner: String, name: String)? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["https://", "http://", "www.", "github.com/"] where trimmed.hasPrefix(prefix) {
      trimmed.removeFirst(prefix.count)
    }
    if trimmed.hasPrefix("github.com/") { trimmed.removeFirst("github.com/".count) }
    if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
    let parts = trimmed.split(separator: "/").map(String.init)
    guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return (parts[0], parts[1])
  }

  private func addPublic() {
    guard let (owner, name) = parsed(publicName) else { return }
    connect(owner: owner, name: name)
  }

  private func connect(owner: String, name: String) {
    Task {
      if let dir = await store.connect(owner: owner, name: name, client: auth.client) {
        navigator.open(dir)
        dismiss()
      }
    }
  }

  private func copy(_ text: String) {
    #if os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #else
      UIPasteboard.general.string = text
    #endif
  }
}

/// A connected repository in the sidebar: its file tree, the number of local changes,
/// and Pull / Commit and Push / Disconnect.
struct RepositoryRow: View {
  let repository: RepositoryState
  @Environment(RepositoryStore.self) private var store
  @Environment(GitHubAuth.self) private var auth
  @Environment(Navigator.self) private var navigator
  @Environment(\.openURL) private var openURL
  @State private var isCommitting = false
  @State private var commitMessage = ""
  @State private var isDisconnecting = false

  var body: some View {
    let dir = store.directory(for: repository)
    FileTreeRow(
      node: FileNode(url: dir, isDirectory: true), isRoot: true,
      badge: store.changeCounts[repository.fullName] ?? 0,
      activity: store.activity[repository.fullName]
    )
    .contextMenu {
      Button("Pull") { Task { await store.pull(repository, client: auth.client) } }
      Button("Commit and Push…") { beginCommit() }
        .disabled(repository.isAnonymous && auth.token == nil)
      Divider()
      Button("Open on GitHub") {
        openURL(URL(string: "https://github.com/\(repository.fullName)/tree/\(repository.branch)")!)
      }
      Divider()
      Button("Disconnect…", role: .destructive) { isDisconnecting = true }
    }
    .alert("Commit and Push", isPresented: $isCommitting) {
      TextField("Message", text: $commitMessage)
      Button("Push") {
        let message = commitMessage
        Task { await store.commitAndPush(repository, message: message, client: auth.client) }
      }
      .keyboardShortcut(.defaultAction)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(changeSummary)
    }
    .confirmationDialog(
      "Disconnect \(repository.fullName)?", isPresented: $isDisconnecting, titleVisibility: .visible
    ) {
      Button("Disconnect", role: .destructive) {
        navigator.forget(under: dir)
        store.disconnect(repository)
      }
    } message: {
      let count = store.changeCounts[repository.fullName] ?? 0
      Text(
        count == 0
          ? "The local copy is removed. The repository on GitHub is not affected."
          : "\(count) change\(count == 1 ? " hasn’t" : "s haven’t") been pushed and will be lost.")
    }
  }

  private var changeSummary: String {
    let changes = store.changes(repository)
    guard !changes.isEmpty else { return "No local changes. Pull anyway to get GitHub’s latest." }
    let lines = changes.prefix(8).map { change -> String in
      let mark = switch change.kind {
      case .added: "+"
      case .modified: "•"
      case .deleted: "−"
      }
      return "\(mark) \(change.path)"
    }
    return (lines + (changes.count > 8 ? ["and \(changes.count - 8) more"] : [])).joined(separator: "\n")
  }

  private func beginCommit() {
    let changes = store.changes(repository)
    commitMessage =
      changes.count == 1
      ? "Update \((changes[0].path as NSString).lastPathComponent)" : "Update notes"
    isCommitting = true
  }
}
