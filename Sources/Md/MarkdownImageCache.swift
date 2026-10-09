import Foundation
import ImageIO

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// Loaded document images, keyed by resolved URL, shared by every editor.
///
/// - Fetches through a `URLSession` with an on-disk `URLCache`, so a README's images are
///   instant (and available offline) the second time; `file:` URLs read from disk.
/// - Decodes off the main thread with ImageIO, downsampling large rasters to what a
///   screen can show (the natural size is still the source's pixel size: GitHub lays
///   images out at 1 CSS pixel = 1 point).
/// - Animated GIF/APNG/WebP keep their `CGImageSource` and decode frames on demand.
/// - SVG: AppKit's `NSImage` draws it natively; UIKit cannot decode SVG, so iOS
///   rasterizes it through `SVGRasterizer` (WebKit).
///
/// Thread safety: every mutable member is guarded by `lock`; completions run on main.
public final class MarkdownImageCache: @unchecked Sendable {
  public static let shared = MarkdownImageCache()

  /// A decoded image.
  public final class Entry: @unchecked Sendable {
    /// Layout size in points (the source's pixel size; an SVG's declared size).
    public let naturalSize: CGSize
    /// The still image (an animation's first frame).
    public let image: PlatformImage
    let animation: Animation?
    public var isAnimated: Bool { animation != nil }

    init(naturalSize: CGSize, image: PlatformImage, animation: Animation? = nil) {
      self.naturalSize = naturalSize
      self.image = image
      self.animation = animation
    }

    /// The image to draw at `time` (seconds on any monotonic clock).
    public func image(at time: TimeInterval) -> PlatformImage {
      animation?.frame(at: time) ?? image
    }
  }

  private enum State {
    case loading([@MainActor (URL) -> Void])
    case loaded(Entry)
    case failed
  }

  private let lock = NSLock()
  private var states: [URL: State] = [:]
  private let session: URLSession
  private let decodeQueue = DispatchQueue(
    label: "md.image-decode", qos: .userInitiated, attributes: .concurrent)
  /// Longest side, in pixels, a still image is decoded at.
  public var maxDecodedPixelSize: Int = 2400

  public init(diskCapacity: Int = 256 * 1024 * 1024) {
    let config = URLSessionConfiguration.default
    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent("MarkdownImages", isDirectory: true)
    config.urlCache = URLCache(
      memoryCapacity: 16 * 1024 * 1024, diskCapacity: diskCapacity, directory: cacheDir)
    config.requestCachePolicy = .returnCacheDataElseLoad
    config.timeoutIntervalForRequest = 30
    config.httpMaximumConnectionsPerHost = 6
    session = URLSession(configuration: config)
  }

  /// The decoded image for `url`, if loaded.
  public func entry(for url: URL) -> Entry? {
    lock.lock()
    defer { lock.unlock() }
    if case .loaded(let e) = states[url] { return e }
    return nil
  }

  /// The natural size of the loaded image for `url`, if loaded.
  public func naturalSize(for url: URL) -> CGSize? { entry(for: url)?.naturalSize }

  /// Whether `url` was requested before (loaded, loading or failed).
  public func hasRequested(_ url: URL) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return states[url] != nil
  }

  /// Whether loading `url` failed (it is not retried until `forget`).
  public func didFail(_ url: URL) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if case .failed = states[url] { return true }
    return false
  }

  /// Registers an already-decoded image for `url` (tests; a host that has the image in
  /// hand, e.g. one just pasted). Replaces anything known about `url`.
  public func store(_ image: PlatformImage, naturalSize: CGSize, for url: URL) {
    lock.lock()
    states[url] = .loaded(Entry(naturalSize: naturalSize, image: image))
    lock.unlock()
  }

  /// Drops everything known about `url` (a reload fetches it again).
  public func forget(_ url: URL) {
    lock.lock()
    states[url] = nil
    lock.unlock()
  }

  /// Loads `url` unless it is loaded or failed; `completion` runs on the main thread
  /// once it is loaded (not on failure). Concurrent requests share one fetch.
  public func load(_ url: URL, completion: @escaping @MainActor (URL) -> Void) {
    lock.lock()
    switch states[url] {
    case .loaded:
      lock.unlock()
      return
    case .failed:
      lock.unlock()
      return
    case .loading(var waiters):
      waiters.append(completion)
      states[url] = .loading(waiters)
      lock.unlock()
      return
    case nil:
      states[url] = .loading([completion])
      lock.unlock()
    }
    let task = session.dataTask(with: url) { [weak self] data, response, _ in
      guard let self else { return }
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        self.finish(url, entry: nil)
        return
      }
      guard let data, !data.isEmpty else {
        self.finish(url, entry: nil)
        return
      }
      let mime = (response?.mimeType ?? "").lowercased()
      self.decodeQueue.async {
        if Self.isSVG(data: data, url: url, mime: mime) {
          Self.decodeSVG(data) { [self] entry in self.finish(url, entry: entry) }
        } else {
          self.finish(url, entry: self.decodeRaster(data))
        }
      }
    }
    task.resume()
  }

  private func finish(_ url: URL, entry: Entry?) {
    lock.lock()
    var waiters: [@MainActor (URL) -> Void] = []
    if case .loading(let w) = states[url] { waiters = w }
    states[url] = entry.map { .loaded($0) } ?? .failed
    lock.unlock()
    guard entry != nil else { return }
    DispatchQueue.main.async {
      MainActor.assumeIsolated { for w in waiters { w(url) } }
    }
  }

  // MARK: - Decoding

  static func isSVG(data: Data, url: URL, mime: String) -> Bool {
    if mime.contains("svg") || url.pathExtension.lowercased() == "svg" { return true }
    let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
    return head.contains("<svg")
  }

  private func decodeRaster(_ data: Data) -> Entry? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0,
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let pw = props[kCGImagePropertyPixelWidth] as? Int,
      let ph = props[kCGImagePropertyPixelHeight] as? Int, pw > 0, ph > 0
    else { return nil }
    // EXIF orientations 5–8 swap the displayed axes.
    let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
    let natural =
      orientation >= 5 ? CGSize(width: ph, height: pw) : CGSize(width: pw, height: ph)
    let count = CGImageSourceGetCount(source)
    let maxPixel = min(max(pw, ph), maxDecodedPixelSize)
    guard let first = Self.frame(source, index: 0, maxPixel: maxPixel) else { return nil }
    let still = Self.platformImage(first, size: natural)
    if count > 1, let animation = Animation(source: source, count: count, natural: natural) {
      return Entry(naturalSize: natural, image: still, animation: animation)
    }
    return Entry(naturalSize: natural, image: still)
  }

  static func frame(_ source: CGImageSource, index: Int, maxPixel: Int) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
  }

  static func platformImage(_ cg: CGImage, size: CGSize) -> PlatformImage {
    #if canImport(AppKit)
      return NSImage(cgImage: cg, size: size)
    #else
      return UIImage(cgImage: cg)
    #endif
  }

  private static func decodeSVG(_ data: Data, completion: @escaping @Sendable (Entry?) -> Void) {
    #if canImport(AppKit)
      guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
        completion(nil)
        return
      }
      completion(Entry(naturalSize: image.size, image: image))
    #else
      let size = SVGRasterizer.declaredSize(of: data)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          SVGRasterizer.shared.rasterize(data, size: size) { image in
            completion(image.map { Entry(naturalSize: size, image: $0) })
          }
        }
      }
    #endif
  }

  // MARK: - Animation

  /// An animated image's frames, decoded on demand from its source. Frames are kept
  /// while they fit `frameBudget` bytes; past that only the most recent one is.
  final class Animation: @unchecked Sendable {
    private let source: CGImageSource
    private let delays: [Double]
    private let total: Double
    private let natural: CGSize
    private let maxPixel: Int
    private let lock = NSLock()
    private var frames: [Int: PlatformImage] = [:]
    private let keepsAllFrames: Bool

    init?(source: CGImageSource, count: Int, natural: CGSize, frameBudget: Int = 48 * 1024 * 1024) {
      self.source = source
      self.natural = natural
      // Frames are decoded at up to 2x a typical README width.
      maxPixel = Int(min(max(natural.width, natural.height), 1600))
      var delays: [Double] = []
      for i in 0..<count { delays.append(Self.delay(source, index: i)) }
      self.delays = delays
      total = delays.reduce(0, +)
      guard total > 0 else { return nil }
      let scale = Double(maxPixel) / Double(max(natural.width, natural.height, 1))
      let frameBytes = Double(natural.width * natural.height) * scale * scale * 4
      keepsAllFrames = frameBytes * Double(count) <= Double(frameBudget)
    }

    /// Browsers' rule: a delay under 20ms plays at 100ms.
    private static func delay(_ source: CGImageSource, index: Int) -> Double {
      guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
      else { return 0.1 }
      let dicts: [(CFString, CFString, CFString)] = [
        (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
        (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
      ]
      for (dict, unclamped, clamped) in dicts {
        guard let d = props[dict] as? [CFString: Any] else { continue }
        let value = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0.1
        return value < 0.02 ? 0.1 : value
      }
      return 0.1
    }

    func frame(at time: TimeInterval) -> PlatformImage? {
      var t = time.truncatingRemainder(dividingBy: total)
      var index = 0
      while index < delays.count - 1, t >= delays[index] {
        t -= delays[index]
        index += 1
      }
      lock.lock()
      if let cached = frames[index] {
        lock.unlock()
        return cached
      }
      lock.unlock()
      guard let cg = MarkdownImageCache.frame(source, index: index, maxPixel: maxPixel) else {
        return nil
      }
      let image = MarkdownImageCache.platformImage(cg, size: natural)
      lock.lock()
      if !keepsAllFrames { frames.removeAll() }
      frames[index] = image
      lock.unlock()
      return image
    }
  }
}

/// The former name of the image cache.
public typealias InlineImageCache = MarkdownImageCache
