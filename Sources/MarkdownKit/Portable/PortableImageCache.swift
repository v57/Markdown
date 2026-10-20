#if !canImport(AppKit) && !canImport(UIKit)
  import Foundation

  /// Without TextKit the document's images load through SwiftUI (`AsyncImage`), which keeps no cache to clear.
  public final class MarkdownImageCache: @unchecked Sendable {
    public static let shared = MarkdownImageCache()
    public func forgetFileImages() {}
    public func forget(_ url: URL) {}
  }
#endif
