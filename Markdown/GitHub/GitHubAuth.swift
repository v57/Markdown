import Foundation
import Observation
import Security

/// Signing in to GitHub with the OAuth device flow: the app shows a short code, the user
/// enters it on github.com/login/device, and the app polls until GitHub hands over a
/// token. No password ever reaches the app, and no web view or callback URL is needed.
///
/// The OAuth App's client ID comes from the `GITHUB_CLIENT_ID` build setting (Info.plist
/// key `GitHubClientID`); the app must have Device Flow enabled on GitHub. The token is
/// kept in the Keychain.
@Observable final class GitHubAuth {
  enum State: Equatable {
    case signedOut
    /// Waiting for the user to enter `code` at `verificationURL`.
    case waiting(code: String, verificationURL: URL)
    case signedIn(login: String)
  }

  private(set) var state: State = .signedOut
  var error: String?
  private(set) var token: String?
  @ObservationIgnored private var polling: Task<Void, Never>?

  static var clientID: String? {
    let id = Bundle.main.object(forInfoDictionaryKey: "GitHubClientID") as? String
    guard let id, !id.isEmpty, !id.hasPrefix("$(") else { return nil }
    return id
  }

  var client: GitHubClient { GitHubClient(token: token) }

  init() {
    token = Keychain.read()
    if token != nil {
      state = .signedIn(login: UserDefaults.standard.string(forKey: "githubLogin") ?? "GitHub")
    }
  }

  /// Starts the device flow; `state` becomes `.waiting` with the code to show.
  func signIn() {
    guard let clientID = Self.clientID else {
      error =
        "GitHub sign-in isn’t set up in this build: it needs an OAuth App client ID (GITHUB_CLIENT_ID)."
      return
    }
    polling?.cancel()
    polling = Task {
      do {
        let device = try await Self.requestDeviceCode(clientID: clientID)
        state = .waiting(code: device.userCode, verificationURL: device.verificationURL)
        let token = try await Self.poll(clientID: clientID, device: device)
        let user = try await GitHubClient(token: token).user()
        Keychain.save(token)
        UserDefaults.standard.set(user.login, forKey: "githubLogin")
        self.token = token
        state = .signedIn(login: user.login)
      } catch is CancellationError {
        state = .signedOut
      } catch {
        state = .signedOut
        self.error = error.localizedDescription
      }
    }
  }

  func cancelSignIn() {
    polling?.cancel()
    polling = nil
    state = .signedOut
  }

  func signOut() {
    cancelSignIn()
    Keychain.delete()
    UserDefaults.standard.removeObject(forKey: "githubLogin")
    token = nil
  }

  // MARK: - Device flow

  private struct DeviceCode: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let interval: Int
    let expiresIn: Int
    var verificationURL: URL { URL(string: verificationURI) ?? URL(string: "https://github.com/login/device")! }
    enum CodingKeys: String, CodingKey {
      case interval
      case deviceCode = "device_code"
      case userCode = "user_code"
      case verificationURI = "verification_uri"
      case expiresIn = "expires_in"
    }
  }

  private struct FlowError: LocalizedError {
    let errorDescription: String?
  }

  nonisolated private static func post(_ url: String, _ fields: [String: String]) async throws
    -> [String: Any]
  {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: fields)
    let (data, _) = try await URLSession.shared.data(for: request)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  nonisolated private static func requestDeviceCode(clientID: String) async throws -> DeviceCode {
    let json = try await post(
      "https://github.com/login/device/code", ["client_id": clientID, "scope": "repo"])
    if let message = json["error_description"] as? String { throw FlowError(errorDescription: message) }
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(DeviceCode.self, from: data)
  }

  /// Polls at GitHub's interval (longer after `slow_down`) until the user approves,
  /// denies, or the code expires.
  nonisolated private static func poll(clientID: String, device: DeviceCode) async throws -> String {
    var interval = max(device.interval, 5)
    let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))
    while Date() < deadline {
      try await Task.sleep(for: .seconds(interval))
      let json = try await post(
        "https://github.com/login/oauth/access_token",
        [
          "client_id": clientID, "device_code": device.deviceCode,
          "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
      if let token = json["access_token"] as? String { return token }
      switch json["error"] as? String {
      case "authorization_pending": continue
      case "slow_down": interval += 5
      case "access_denied": throw FlowError(errorDescription: "GitHub sign-in was cancelled.")
      case "expired_token": throw FlowError(errorDescription: "The code expired. Try again.")
      default:
        throw FlowError(
          errorDescription: json["error_description"] as? String ?? "GitHub sign-in failed.")
      }
    }
    throw FlowError(errorDescription: "The code expired. Try again.")
  }
}

/// The GitHub token in the Keychain (one generic password item).
private enum Keychain {
  private static let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "dev.v57.md.github",
    kSecAttrAccount as String: "token",
  ]

  static func read() -> String? {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func save(_ token: String) {
    delete()
    var q = query
    q[kSecValueData as String] = Data(token.utf8)
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(q as CFDictionary, nil)
  }

  static func delete() {
    SecItemDelete(query as CFDictionary)
  }
}
