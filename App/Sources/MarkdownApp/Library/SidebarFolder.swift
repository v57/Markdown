import Foundation
import SwiftData

/// A directory the user added to the sidebar, or (`isFile`) a single file opened from
/// Finder or Files ("Open with…") outside every sidebar folder.
///
/// `path` is what the user sees and how duplicates are detected; `bookmark` is what
/// gets the folder back after a relaunch. The macOS sandbox only grants access to a
/// dropped or picked folder for the current run, and an iOS document-picker URL is
/// likewise only usable through its bookmark — so the bookmark, not the path, is the
/// durable reference. Defaults on every attribute keep the model CloudKit-compatible
/// should the store ever sync (bookmarks themselves are device-local).
@Model final class SidebarFolder {
  var path: String = ""
  var bookmark: Data?
  var addedAt: Date = Date()
  var isFile: Bool = false

  init(path: String, bookmark: Data?, isFile: Bool = false, addedAt: Date = .now) {
    self.path = path
    self.bookmark = bookmark
    self.isFile = isFile
    self.addedAt = addedAt
  }

  var name: String { (path as NSString).lastPathComponent }
}
