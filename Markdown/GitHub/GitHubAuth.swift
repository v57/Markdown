import Foundation
import GitHubKit
import Observation

/// Signing in to GitHub with the OAuth device flow (GitHubKit, `../Git`): the app shows a
/// short code, the user enters it on github.com/login/device, and the app polls until GitHub
/// hands over a token. No password ever reaches the app, and no web view or callback URL is
/// needed.
///
/// The OAuth App's client ID comes from the `GITHUB_CLIENT_ID` build setting (Info.plist
/// key `GitHubClientID`); the app must have Device Flow enabled on GitHub. The token is
/// kept in the Keychain.
@Observable final class GitHubAuth {
  enum State: Equatable {
    case signedOut
    /// Asking GitHub for a code.
    case requesting
    /// Waiting for the user to enter `code` at `verificationURL`.
    case waiting(code: String, verificationURL: URL)
    case signedIn(login: String)
  }

  let account: GitHubAccount
  private var localError: String?

  static var clientID: String? {
    let id = Bundle.main.object(forInfoDictionaryKey: "GitHubClientID") as? String
    guard let id, !id.isEmpty, !id.hasPrefix("$(") else { return nil }
    return id
  }

  init() {
    let store = KeychainTokenStore(service: "dev.v57.md.github")
    Self.migrateLegacyToken(in: store)
    // Without a client ID the saved token still works; only a new sign-in needs one.
    account = GitHubAccount(clientID: Self.clientID ?? "", store: store)
    // No request at launch: GitHub is contacted only when the user asks.
    account.restore(refreshing: false)
  }

  var state: State {
    switch account.signInStep {
    case .requestingCode: return .requesting
    case .waiting(let code): return .waiting(code: code.userCode, verificationURL: code.verificationURL)
    default: break
    }
    guard let credential = account.credential else { return .signedOut }
    return .signedIn(login: account.user?.login ?? credential.login)
  }

  /// A failed sign-in, a revoked token, or an error the views report.
  var error: String? {
    get {
      if let localError { return localError }
      if case .failed(let failure) = account.signInStep { return Self.describe(failure) }
      return account.notice
    }
    set {
      localError = newValue
      if newValue == nil {
        account.endSignIn()
        account.notice = nil
      }
    }
  }

  var token: String? { account.credential?.token }

  /// The API as the signed-in user, or anonymous (public repositories only).
  var api: GitHubAPI { account.api ?? GitHubAPI(token: nil) }

  /// Starts the device flow; `state` becomes `.waiting` with the code to show.
  func signIn() {
    guard Self.clientID != nil else {
      error =
        "GitHub sign-in isn’t set up in this build: it needs an OAuth App client ID (GITHUB_CLIENT_ID)."
      return
    }
    account.signIn(
      requesting: GitHubPermissions(repositories: .all, organizations: false, workflows: false))
  }

  func cancelSignIn() { account.cancelSignIn() }

  func signOut() { account.signOut() }

  private static func describe(_ error: GitHubError) -> String {
    switch error {
    case .signInDeclined: "GitHub sign-in was cancelled."
    case .codeExpired: "The code expired. Try again."
    default: error.localizedDescription
    }
  }

  /// Builds before GitHubKit kept the token under the account "token", with the login in
  /// UserDefaults. Moves it to GitHubKit's layout so the user stays signed in.
  private static func migrateLegacyToken(in store: KeychainTokenStore) {
    guard let saved = try? store.load(), saved.login == "token" else { return }
    let defaults = UserDefaults.standard
    let login = defaults.string(forKey: "githubLogin") ?? "GitHub"
    try? store.save(GitHubCredential(login: login, token: saved.token, scopes: ["repo"]))
    defaults.removeObject(forKey: "githubLogin")
  }
}
