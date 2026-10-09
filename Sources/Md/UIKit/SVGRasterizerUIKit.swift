#if canImport(UIKit) && canImport(WebKit)
  import UIKit
  import WebKit

  /// Rasterizes SVG for iOS, where `UIImage(data:)` cannot decode it (AppKit's `NSImage`
  /// can). One offscreen `WKWebView` renders each SVG at its declared size and snapshots
  /// it at screen scale; requests are serialized through it. README SVGs are mostly
  /// shields.io badges and small icons, so this stays cheap.
  @MainActor final class SVGRasterizer: NSObject, WKNavigationDelegate {
    static let shared = SVGRasterizer()

    private struct Job {
      let data: Data
      let size: CGSize
      let completion: (UIImage?) -> Void
    }
    private var jobs: [Job] = []
    private var current: Job?
    private lazy var webView: WKWebView = {
      let config = WKWebViewConfiguration()
      config.suppressesIncrementalRendering = true
      let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: config)
      view.isOpaque = false
      view.backgroundColor = .clear
      view.scrollView.backgroundColor = .clear
      view.scrollView.contentInsetAdjustmentBehavior = .never
      view.isUserInteractionEnabled = false
      view.navigationDelegate = self
      return view
    }()

    func rasterize(_ data: Data, size: CGSize, completion: @escaping (UIImage?) -> Void) {
      jobs.append(Job(data: data, size: size, completion: completion))
      next()
    }

    private func next() {
      guard current == nil, !jobs.isEmpty else { return }
      let job = jobs.removeFirst()
      current = job
      // A snapshot of a web view outside any window comes back blank: park it, invisible,
      // in the key window while it renders.
      if webView.superview == nil, let window = Self.hostWindow() {
        webView.alpha = 0.011
        webView.frame.origin = CGPoint(x: -10_000, y: 0)
        window.insertSubview(webView, at: 0)
      }
      webView.frame.size = job.size
      let b64 = job.data.base64EncodedString()
      let html = """
        <!doctype html><html><head><meta name="viewport" content="width=\(Int(job.size.width)),initial-scale=1">\
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}\
        img{display:block;width:\(job.size.width)px;height:\(job.size.height)px}</style></head>\
        <body><img src="data:image/svg+xml;base64,\(b64)"></body></html>
        """
      webView.loadHTMLString(html, baseURL: nil)
    }

    private static func hostWindow() -> UIWindow? {
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows).first { $0.isKeyWindow }
        ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows).first
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      MainActor.assumeIsolated { snapshot() }
    }
    nonisolated func webView(
      _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
      MainActor.assumeIsolated { complete(nil) }
    }

    private func snapshot() {
      guard let job = current else { return }
      let config = WKSnapshotConfiguration()
      config.rect = CGRect(origin: .zero, size: job.size)
      config.afterScreenUpdates = true
      webView.takeSnapshot(with: config) { [weak self] image, _ in
        self?.complete(image)
      }
    }

    private func complete(_ image: UIImage?) {
      let job = current
      current = nil
      job?.completion(image)
      if jobs.isEmpty { webView.removeFromSuperview() }
      next()
    }

    /// An SVG's declared size: its root `width`/`height`, else the `viewBox` extent, else
    /// the HTML default for replaced content (300×150).
    nonisolated static func declaredSize(of data: Data) -> CGSize {
      let text = String(decoding: data.prefix(4096), as: UTF8.self)
      guard let open = text.range(of: "<svg", options: .caseInsensitive),
        let close = text[open.upperBound...].firstIndex(of: ">")
      else { return CGSize(width: 300, height: 150) }
      let attrs = MarkdownHTML.attributes(in: String(text[open.upperBound..<close]))
      let w = MarkdownHTML.dimension(attrs["width"]).points
      let h = MarkdownHTML.dimension(attrs["height"]).points
      let box = (attrs["viewbox"] ?? "").split(whereSeparator: { $0 == " " || $0 == "," })
        .compactMap { Double($0) }
      let bw = box.count == 4 ? CGFloat(box[2]) : nil
      let bh = box.count == 4 ? CGFloat(box[3]) : nil
      switch (w, h) {
      case let (w?, h?): return CGSize(width: w, height: h)
      case let (w?, nil):
        if let bw, let bh, bw > 0 { return CGSize(width: w, height: w * bh / bw) }
        return CGSize(width: w, height: w)
      case let (nil, h?):
        if let bw, let bh, bh > 0 { return CGSize(width: h * bw / bh, height: h) }
        return CGSize(width: h, height: h)
      case (nil, nil):
        if let bw, let bh, bw > 0, bh > 0 { return CGSize(width: bw, height: bh) }
        return CGSize(width: 300, height: 150)
      }
    }
  }
#endif
