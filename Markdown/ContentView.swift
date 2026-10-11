import SwiftData
import SwiftUI

/// The library window: dropped folders in the sidebar, the selected folder's README
/// (or the selected markdown file) in the detail pane.
struct ContentView: View {
  @State private var library = FolderLibrary()
  @State private var navigator = Navigator()

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
  }
}
