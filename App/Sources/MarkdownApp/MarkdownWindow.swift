import ComponentKit
import SwiftData
import SwiftUI
import VaultKit
import VaultUI

/// A library window: one vault account (Personal, or one the user works for), kept with the window. The account's
/// notes, sidebar folders, GitHub sign-in and connected repositories are the window's (`AccountStorage`); the
/// sidebar's picker switches it, and the window starts over on the other account.
struct MarkdownWindow: View {
  @SceneStorage("vault.account") private var accountID = VaultAccount.personal.id
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #else
    /// Manage Accounts… over the window, where there is no Settings window.
    @State private var isManaging = false
  #endif

  var body: some View {
    if ScreenshotDemo.isOn {
      // The demo's window is Personal's, without the picker: the user's accounts stay out of screenshots.
      content(.shared)
      #if os(macOS)
        .task { if ScreenshotDemo.flag("--settings") { openSettings() } }
      #endif
    } else {
      VaultAccountScope(selection: $accountID, manage: manage) { vault in
        content(vault)
      }
      #if !os(macOS)
        .kitSheet(isPresented: $isManaging) {
          KitSheet(title: "Accounts", systemImage: "person.2", hue: .indigo, onClose: { isManaging = false }) {
            VaultAccountsSettings()
          }
        }
      #endif
    }
  }

  private func content(_ vault: Vault) -> some View {
    ContentView(vault: vault)
      .modelContainer(AccountStorage.sidebarStore(for: vault))
  }

  /// Opens Settings ▸ Accounts (on the Mac), or the accounts over the window.
  private var manage: @MainActor @Sendable () -> Void {
    #if os(macOS)
      { [openSettings] in
        UserDefaults.standard.set(MarkdownSettings.accountsPane, forKey: MarkdownSettings.paneKey)
        openSettings()
      }
    #else
      { [$isManaging] in $isManaging.wrappedValue = true }
    #endif
  }
}

#if os(macOS)
  /// The Settings window: the panes the v57 apps share.
  struct MarkdownSettings: View {
    static let paneKey = "SettingsPane"
    static let accountsPane = "Accounts"
    @AppStorage(paneKey) private var pane = accountsPane

    var body: some View {
      KitSettings(selection: $pane, window: .hiddenTitleBar) {
        SettingsPane(Self.accountsPane, systemImage: "person.2", hue: .indigo, section: "v57") {
          VaultAccountsSettings()
        }
      }
      .frame(width: 680, height: 460)
    }
  }
#endif
