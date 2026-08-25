#if canImport(AppKit)
  import AppKit

  /// Cache of loaded inline images, keyed by URL. The editor layout manager draws these
  /// in place of ![alt](url) ranges; until an image loads, the alt text is shown.
  /// Nonisolated: reads happen on the main thread (layout/draw), writes on a private
  /// queue via `queue.sync` — matching the app target's original (non-annotated) build.
  public final class InlineImageCache {
    /// Main-thread singleton (layout/draw reads happen on the main thread). Marked
    /// nonisolated(unsafe) so the non-Sendable class instance can be a global.
    public static nonisolated(unsafe) let shared = InlineImageCache()
    private var images: [URL: NSImage] = [:]
    private let queue = DispatchQueue(label: "inline-image-load")

    public func image(for url: URL) -> NSImage? { images[url] }

    /// Loads the image if not cached; `completion` runs on the main thread.
    public func load(url: URL, completion: @escaping () -> Void) {
      if images[url] != nil { return }
      let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
        guard let self, let data, let img = NSImage(data: data) else { return }
        self.queue.sync { self.images[url] = img }
        DispatchQueue.main.async(execute: completion)
      }
      task.resume()
    }
  }
#endif
