import Foundation
import GitHubKit
import SwiftData
import VaultKit

/// Where a window's vault account keeps what this device holds of it (../Ideas/Accounts.md: each window shows one
/// account). Personal keeps the places it had before accounts: the notes in Documents (or the chosen folder), the
/// mirror's state, the connected repositories and the sidebar store in Application Support. Another account keeps
/// them in `Application Support/Accounts/<id>/`, outside Personal's notes folder so Personal's mirror never syncs
/// them into Personal's vault.
enum AccountStorage {
  /// Application Support for Personal; the account's folder in it otherwise.
  static func directory(for vault: Vault) -> URL {
    let support = URL.applicationSupportDirectory
    guard !vault.isPersonal else { return support }
    return support.appendingPathComponent("Accounts", isDirectory: true)
      .appendingPathComponent(vault.accountID, isDirectory: true)
  }

  /// The account's notes folder when the user hasn't chosen one: Documents for Personal (on iOS: On My iPhone ›
  /// Markdown in Files).
  static func defaultNotesFolder(for vault: Vault) -> URL {
    vault.isPersonal ? URL.documentsDirectory : directory(for: vault).appendingPathComponent("Notes", isDirectory: true)
  }

  /// The UserDefaults key of a setting this device keeps per account (the chosen notes folder's bookmark):
  /// Personal keeps the key it had.
  static func key(_ key: String, for vault: Vault) -> String {
    vault.isPersonal ? key : "\(key).\(vault.accountID)"
  }

  /// The account's GitHub sign-in: Personal's is the one the v57 apps share (`KeychainTokenStore.shared`), another
  /// account's sits beside it under its own service (`KeychainTokenStore.forAccount`, as in Git and Dev), so signing
  /// in there leaves Personal's alone.
  static func gitHubTokens(for vault: Vault) -> KeychainTokenStore {
    KeychainTokenStore.forAccount(vault.accountID)
  }

  // MARK: Sidebar store

  /// The sidebar's folders (security-scoped bookmarks, which only resolve on this device, so the store stays local),
  /// one store per account. The default configuration would mirror it to CloudKit because the app has an iCloud
  /// container, and CloudKit traps at launch without the CloudKit service.
  static func sidebarStore(for vault: Vault) -> ModelContainer {
    if let container = sidebarStores[vault.accountID] { return container }
    let configuration: ModelConfiguration
    if vault.isPersonal || ScreenshotDemo.isOn {
      configuration = ModelConfiguration(isStoredInMemoryOnly: ScreenshotDemo.isOn, cloudKitDatabase: .none)
    } else {
      let folder = directory(for: vault)
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      configuration = ModelConfiguration(url: folder.appendingPathComponent("Sidebar.store"), cloudKitDatabase: .none)
    }
    do {
      let container = try ModelContainer(for: SidebarFolder.self, configurations: configuration)
      sidebarStores[vault.accountID] = container
      return container
    } catch {
      fatalError("Could not open the sidebar store: \(error)")
    }
  }

  private static var sidebarStores: [String: ModelContainer] = [:]
}
