import AppKit

/// Cache of loaded inline images, keyed by URL. The editor layout manager draws these
/// in place of ![alt](url) ranges; until an image loads, the alt text is shown.
final class InlineImageCache {
    static let shared = InlineImageCache()
    private var images: [URL: NSImage] = [:]
    private let queue = DispatchQueue(label: "inline-image-load")

    func image(for url: URL) -> NSImage? { images[url] }

    /// Loads the image if not cached; `completion` runs on the main thread.
    func load(url: URL, completion: @escaping () -> Void) {
        if images[url] != nil { return }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let img = NSImage(data: data) else { return }
            self.queue.sync { self.images[url] = img }
            DispatchQueue.main.async(execute: completion)
        }
        task.resume()
    }
}
