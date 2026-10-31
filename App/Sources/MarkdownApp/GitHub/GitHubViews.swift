import ComponentKit
import GitHubKit
import GitHubUI
import SwiftUI

/// The Connect GitHub sheet (the kit's, over the window on the Mac and iPad): sign in (device flow), then pick one of your repositories —
/// or add any public repository by name, signed in or not (read-only without sign-in).
struct GitHubConnectView: View {
  @Environment(GitHubAuth.self) private var auth
  @Environment(RepositoryStore.self) private var store
  @Environment(Navigator.self) private var navigator
  @Environment(\.kitDismiss) private var dismiss
  @State private var repositories: [GitHubRepository] = []
  @State private var isLoading = false
  @State private var filter = ""
  @State private var publicName = ""
  /// Other vault accounts' sign-ins, while this one has none.
  @State private var offers: [GitHubSignInOffer] = []
  @State private var isSigningIn = false

  var body: some View {
    KitSheet(
      title: "Connect GitHub", meta: "Notes from a repository's Markdown files, edited here and pushed back.",
      systemImage: "arrow.triangle.branch", hue: .purple, width: 480
    ) {
      account
      if case .signedIn = auth.state {
        yourRepositories
      }
      FormCard("Any Public Repository", footer: "Only Markdown files and their images are downloaded.") {
        FormRow(
          "Repository", help: "owner/repository or a github.com address", systemImage: "globe", hue: .gray,
          field: TextField("owner/repository", text: $publicName)
            .autocorrectionDisabled()
            #if os(iOS)
              .textInputAutocapitalization(.never)
            #endif
            .onSubmit(addPublic))
        GroupRow("Add", help: nil, action: addPublic)
          .disabled(parsed(publicName) == nil)
      }
    } footer: {
      Button("Done") { dismiss() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
    }
    .task(id: auth.token) {
      offers = auth.offers
      await loadRepositories()
    }
    .notice("GitHub", message: Bindable(auth).error)
  }

  @ViewBuilder private var account: some View {
    FormCard("Account") {
      switch auth.state {
      case .signedOut:
        GroupRow(
          "Sign In with GitHub…",
          help: "Signing in lets you edit your repositories, including private ones, and push changes.",
          action: { isSigningIn = auth.canSignIn() })
        ForEach(offers) { offer in
          GroupRow(
            "Use @\(offer.credential.login)", help: "Signed in on \(offer.accountName).", action: { auth.use(offer) })
        }
      case .signedIn(let login):
        GroupRow {
          Label("@\(login)", systemImage: "person.crop.circle")
        } trailing: {
          Button("Sign Out") { auth.signOut() }.buttonStyle(.kit)
        }
      }
    }
    // The device flow, as Git signs in (GitHubUI).
    .kitSheet(isPresented: $isSigningIn) {
      GitHubSignInSheet(
        account: auth.account, appName: "Markdown", permissions: GitHubAuth.permissions, choices: [],
        offers: { auth.offers }, use: { auth.use($0) }, systemImage: "doc.text")
    }
  }

  @ViewBuilder private var yourRepositories: some View {
    FormCard("Your Repositories") {
      KitSearchField(text: $filter, prompt: "Filter your repositories", count: "\(filtered.count) of \(repositories.count)")
        .padding(10)
      if isLoading {
        LiveIcon(systemImage: "arrow.triangle.branch", status: .working, size: 18)
          .frame(maxWidth: .infinity)
          .padding(10)
      }
      ForEach(filtered) { repository in
        let connected = store.repositories.contains { $0.fullName == repository.fullName }
        let busy = store.activity[repository.fullName]
        GroupRow(action: { connect(owner: repository.owner, name: repository.name) }) {
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
              Text(repository.fullName)
              if repository.isPrivate {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.kitSecondary)
              }
            }
            if let description = repository.description, !description.isEmpty {
              Text(description).font(.caption).foregroundStyle(.kitSecondary).lineLimit(1)
            }
          }
        } trailing: {
          if let busy {
            LiveIcon(systemImage: "arrow.down", status: .working, size: 16)
            Text(busy).font(.caption).foregroundStyle(.kitSecondary)
          } else if connected {
            Image(systemName: "checkmark").foregroundStyle(.kitSecondary)
          }
        }
        .disabled(connected || busy != nil)
      }
    }
  }

  private var filtered: [GitHubRepository] {
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
      repositories = try await auth.api.repositories()
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
      if let dir = await store.connect(owner: owner, name: name, client: auth.api) {
        navigator.open(dir)
        dismiss()
      }
    }
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
      activity: store.activity[repository.fullName],
      title: repository.fullName,
      systemImage: "arrow.triangle.branch"
    )
    .kitContextMenu { menu }
    .kitSheet(isPresented: $isCommitting) {
      KitSheet(title: "Commit and Push", meta: changeSummary, systemImage: "arrow.up", hue: .purple) {
        FormCard {
          FormRow("Message", systemImage: "text.bubble", field: TextField("Message", text: $commitMessage))
        }
      } footer: {
        Button("Cancel") { isCommitting = false }
          .keyboardShortcut(.cancelAction)
        Button("Push") {
          let message = commitMessage
          isCommitting = false
          Task { await store.commitAndPush(repository, message: message, client: auth.api) }
        }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
      }
    }
    .kitConfirmation(
      "Disconnect \(repository.fullName)?", isPresented: $isDisconnecting, message: disconnectMessage,
      systemImage: "minus.circle", confirm: "Disconnect"
    ) {
      navigator.forget(under: dir)
      store.disconnect(repository)
    }
  }

  private var disconnectMessage: String {
    let count = store.changeCounts[repository.fullName] ?? 0
    return count == 0
      ? "The local copy is removed. The repository on GitHub is not affected."
      : "\(count) change\(count == 1 ? " hasn’t" : "s haven’t") been pushed and will be lost."
  }

  @ViewBuilder private var menu: some View {
    Button("Pull", systemImage: "arrow.down") { Task { await store.pull(repository, client: auth.api) } }
    Button("Commit and Push…", systemImage: "arrow.up") { beginCommit() }
      .disabled(repository.isAnonymous && auth.token == nil)
    Divider()
    Button("Open on GitHub", systemImage: "safari") {
      openURL(URL(string: "https://github.com/\(repository.fullName)/tree/\(repository.branch)")!)
    }
    Divider()
    Button("Disconnect…", systemImage: "minus.circle", role: .destructive) { isDisconnecting = true }
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
