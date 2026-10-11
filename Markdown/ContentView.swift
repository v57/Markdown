import SwiftData
import SwiftUI

/// The library window: dropped folders in the sidebar, the selected folder's README
/// (or the selected markdown file) in the detail pane. Files and folders opened from
/// Finder or Files ("Open with…", a drop on the Dock icon) open here too.
struct ContentView: View {
  @State private var library = FolderLibrary()
  @State private var navigator = Navigator()
  @Environment(\.modelContext) private var context
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]

  var body: some View {
    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
    } detail: {
      NavigationStack {
        DocumentView()
      }
    }
    .environment(library)
    .environment(navigator)
    .onOpenURL { open($0) }
    // Opened files go to this window instead of a new one each.
    .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
  }

  private func open(_ url: URL) {
    guard url.isFileURL else { return }
    if let shown = library.add([url], existing: folders, context: context).first {
      navigator.open(shown)
    }
  }
}
