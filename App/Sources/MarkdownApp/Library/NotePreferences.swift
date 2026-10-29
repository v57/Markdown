import Foundation
import Observation
import VaultKit

/// Pinned notes and recently opened notes, kept in the app's defaults on this device
/// (by path: the notes themselves stay plain files with nothing added to them), per vault account: a window lists
/// only its account's (Personal keeps the keys it had).
@Observable final class NotePreferences {
  private(set) var pinned: Set<URL>
  /// Most recent first.
  private(set) var recents: [URL]

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let pinnedKey: String
  @ObservationIgnored private let recentsKey: String
  private static let recentsLimit = 12

  /// `account` is the window's vault account id (`Vault.accountID`).
  init(defaults: UserDefaults = .standard, account: String = VaultAccount.personal.id) {
    self.defaults = defaults
    let suffix = account == VaultAccount.personal.id ? "" : ".\(account)"
    pinnedKey = "pinnedNotes" + suffix
    recentsKey = "recentNotes" + suffix
    pinned = Set((defaults.stringArray(forKey: pinnedKey) ?? []).map { URL(fileURLWithPath: $0) })
    recents = (defaults.stringArray(forKey: recentsKey) ?? []).map { URL(fileURLWithPath: $0) }
  }

  func isPinned(_ url: URL) -> Bool { pinned.contains(url) }

  func togglePin(_ url: URL) {
    if pinned.remove(url) == nil { pinned.insert(url) }
    save()
  }

  /// Records a note the user opened, for the welcome screen and Quick Open.
  func opened(_ url: URL) {
    guard recents.first != url else { return }
    recents.removeAll { $0 == url }
    recents.insert(url, at: 0)
    if recents.count > Self.recentsLimit { recents.removeLast(recents.count - Self.recentsLimit) }
    save()
  }

  /// Forgets the recent notes (a screenshot scene opened in place starts as a launch would).
  func forgetRecents() {
    recents.removeAll()
    save()
  }

  /// Recent notes that still exist.
  var existingRecents: [URL] {
    recents.filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// Follows a rename or move: pins and recents at or inside `old` move into `new`.
  func replace(_ old: URL, with new: URL) {
    let root = old.path
    func moved(_ url: URL) -> URL {
      guard url.path == root || url.path.hasPrefix(root + "/") else { return url }
      return URL(fileURLWithPath: new.path + url.path.dropFirst(root.count))
    }
    pinned = Set(pinned.map(moved))
    recents = recents.map(moved)
    save()
  }

  private func save() {
    defaults.set(pinned.map(\.path).sorted(), forKey: pinnedKey)
    defaults.set(recents.map(\.path), forKey: recentsKey)
  }
}
