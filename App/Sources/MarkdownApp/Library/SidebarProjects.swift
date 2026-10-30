import Foundation
import VaultKit

/// The shared projects the sidebar lists (its Projects section): the vault's with a folder on this device on the Mac
/// and Windows, the demo's in the screenshot demo (never the user's), none on iPhone and iPad, where a project's
/// folder is on another device.
enum SidebarProjects {
  @MainActor static func tree(_ vault: Vault) -> VaultProjectTree {
    #if os(macOS) || os(Windows)
      ScreenshotDemo.isOn ? ScreenshotDemo.projectTree : vault.localProjectTree
    #else
      VaultProjectTree(projects: [], groups: [])
    #endif
  }

  /// Where the project's folder is on this device.
  static func url(of project: VaultProject) -> URL? {
    ScreenshotDemo.isOn ? ScreenshotDemo.projectFolders[project.id] : project.localURL
  }

  /// The canonical paths of the projects' folders, which may join the sidebar (`FolderLibrary.projectPaths`).
  @MainActor static func paths(_ vault: Vault) -> Set<String> {
    Set(tree(vault).projects().compactMap { url(of: $0).map { FolderLibrary.canonical($0).path } })
  }
}
