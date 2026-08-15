import SwiftUI

struct MarkdownApp: App {
    var body: some Scene {
        WindowGroup("Markdown") {
            Text("Markdown")   // placeholder — replaced by EditorView in Task 2
                .frame(minWidth: 480, minHeight: 360)
        }
        .defaultSize(width: 900, height: 700)
        .commands { TextEditingCommands() }   // standard Edit menu so ⌘C/V/X/Z work
    }
}
