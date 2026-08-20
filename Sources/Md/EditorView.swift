import SwiftUI
import AppKit

public struct MarkdownEditorView: NSViewRepresentable {
    public init() {}
    public func makeCoordinator() -> Coordinator { Coordinator() }
    public func makeNSView(context: Context) -> NSScrollView {
        let textView = EditorTextView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = textView
        return scroll
    }
    public func updateNSView(_ nsView: NSScrollView, context: Context) {}
    @MainActor public final class Coordinator: NSObject {}
}
