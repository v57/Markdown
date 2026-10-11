#if os(macOS) && DIRECT_DISTRIBUTION
  import AppKit
  import SwiftUI

  /// Updates for the direct download (GitHub Releases; App Store builds leave this out):
  /// once a day, and from "Check for Updates…", compares the latest release's tag with
  /// the app's version and offers the download. A few lines instead of an updater
  /// framework — the app's size is part of the point.
  @Observable final class UpdateChecker {
    struct Release: Equatable {
      let version: String
      let page: URL
    }

    /// A newer release to offer, or (`isCurrent`) the answer to a manual check.
    var available: Release?
    var isCurrent = false

    private static let latest = URL(
      string: "https://api.github.com/repos/v57/Markdown/releases/latest")!
    private static let lastCheckKey = "lastUpdateCheck"

    /// On launch: at most once a day, quietly.
    func checkIfDue() {
      let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
      guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
      Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
      struct Latest: Decodable {
        let tagName: String
        let htmlURL: URL
        enum CodingKeys: String, CodingKey {
          case tagName = "tag_name"
          case htmlURL = "html_url"
        }
      }
      var request = URLRequest(url: Self.latest)
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      guard let (data, _) = try? await URLSession.shared.data(for: request),
        let latest = try? JSONDecoder().decode(Latest.self, from: data)
      else { return }
      UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
      let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
      let version = latest.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
      if Self.isNewer(version, than: current) {
        available = Release(version: version, page: latest.htmlURL)
      } else if userInitiated {
        isCurrent = true
      }
    }

    /// "1.10" > "1.9"; missing components count as 0 ("1.1" == "1.1.0").
    static func isNewer(_ a: String, than b: String) -> Bool {
      let x = a.split(separator: ".").map { Int($0) ?? 0 }
      let y = b.split(separator: ".").map { Int($0) ?? 0 }
      for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0
        let r = i < y.count ? y[i] : 0
        if l != r { return l > r }
      }
      return false
    }
  }

  /// The update alerts, attached to the main window.
  struct UpdateAlerts: ViewModifier {
    @Bindable var checker: UpdateChecker
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
      content
        .task { checker.checkIfDue() }
        .alert(
          "Markdown \(checker.available?.version ?? "") Is Available",
          isPresented: Binding(get: { checker.available != nil }, set: { if !$0 { checker.available = nil } })
        ) {
          Button("Download") {
            if let page = checker.available?.page { openURL(page) }
          }
          Button("Later", role: .cancel) {}
        } message: {
          Text("Download it from GitHub and replace this copy in Applications.")
        }
        .alert("Markdown Is Up to Date", isPresented: $checker.isCurrent) {
          Button("OK", role: .cancel) {}
        }
    }
  }
#endif
