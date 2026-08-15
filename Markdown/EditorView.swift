import SwiftUI
import AppKit

struct EditorView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let textView = EditorTextView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = textView
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
    @MainActor final class Coordinator: NSObject {}
}
