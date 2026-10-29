import MarkdownApp
import SwiftUI

/// The app's entry point, the same on every platform: the app itself is the MarkdownApp library (App/Sources/MarkdownApp).
/// The module is MarkdownEditor, not Markdown: swift-markdown's module and product are named Markdown.
@main enum MarkdownMain {
  static func main() { MarkdownApp.main() }
}
