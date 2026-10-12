import Foundation
import Testing

@testable import MarkdownKit

#if canImport(AppKit)
  import AppKit
#endif

/// GitHub-style documents: URL resolution, the HTML subset READMEs use, anchors, and
/// image slots in the layout.
@Suite struct DocumentRenderingTests {
  // MARK: - Resolver

  @Test func resolverHandlesRelativeAbsoluteAndAnchors() {
    let doc = URL(fileURLWithPath: "/notes/Folder/Note.md")
    let r = MarkdownURLResolver.relative(to: doc)
    #expect(r.resolveImage("assets/a.png")?.path == "/notes/Folder/assets/a.png")
    #expect(r.resolveImage("./assets/a.png")?.path == "/notes/Folder/assets/a.png")
    #expect(r.resolveImage("../b.png")?.path == "/notes/b.png")
    #expect(r.resolveImage("my image.png")?.path == "/notes/Folder/my image.png")
    #expect(r.resolveImage("https://x.y/z.png")?.absoluteString == "https://x.y/z.png")
    #expect(r.resolveLink("#Get-Started")?.fragment == "Get-Started")
    #expect(MarkdownParser.isSameDocument(r.resolveLink("#a")!, doc))
    #expect(!MarkdownParser.isSameDocument(r.resolveLink("Other.md#a")!, doc))
    #expect(MarkdownURLResolver.absoluteOnly.resolveImage("a.png") == nil)
    #expect(MarkdownURLResolver.absoluteOnly.resolveLink("mailto:a@b.c") != nil)
  }

  @Test func rootRelativePathsUseTheRoot() {
    let root = URL(fileURLWithPath: "/repos/secretive", isDirectory: true)
    let doc = root.appendingPathComponent("docs/Guide.md")
    let r = MarkdownURLResolver.relative(to: doc, root: root)
    #expect(r.resolveImage("/.github/readme/app-dark.png")?.path == "/repos/secretive/.github/readme/app-dark.png")
    #expect(r.resolveImage("img.png")?.path == "/repos/secretive/docs/img.png")
    #expect(r.resolveLink("/FAQ.md#top")?.path == "/repos/secretive/FAQ.md")
    #expect(r.resolveImage("//cdn.example/x.png")?.path != "/repos/secretive/cdn.example/x.png")
    // Without a root, "/" stays the disk root.
    #expect(MarkdownURLResolver.relative(to: doc).resolveImage("/a.png")?.path == "/a.png")
  }

  #if canImport(AppKit)
    @Test func svgTspanPositionsAreHoisted() {
      let svg = """
        <svg><text fill="#fff">
          <tspan x="4" y="14">passing</tspan>
        </text><text x="1"><tspan>a</tspan><tspan>b</tspan></text></svg>
        """
      let fixed = String(decoding: MarkdownImageCache.appKitCompatibleSVG(Data(svg.utf8)), as: UTF8.self)
      #expect(fixed.contains(##"<text fill="#fff" x="4" y="14">passing</text>"##))
      // Two tspans: left alone.
      #expect(fixed.contains("<tspan>a</tspan><tspan>b</tspan>"))
    }
  #endif

  // MARK: - HTML tokenizer

  @Test func tagsAttributesAndComments() {
    let html = #"<p align="center"><img src='/a.png' width=40 alt="A &amp; B"><!-- <img src="x"> --></p><br/>"#
    let tags = MarkdownHTML.tags(in: html)
    #expect(tags.map(\.name) == ["p", "img", "", "p", "br"])
    #expect(tags[0].attributes["align"] == "center")
    #expect(tags[1].attributes["src"] == "/a.png")
    #expect(tags[1].attributes["width"] == "40")
    #expect(tags[1].attributes["alt"] == "A & B")
    #expect(tags[1].isSelfClosing && tags[4].isSelfClosing && tags[3].isClosing)
    #expect(tags[2].isComment)
    #expect(MarkdownHTML.dimension("50%").fraction == 0.5)
    #expect(MarkdownHTML.dimension("120px").points == 120)
  }

  @Test func entitiesDecode() {
    let found = MarkdownHTML.entities(in: "a&nbsp;b &copy; &#169; &#xA9; &bogus; &")
    #expect(found.map(\.codeUnit) == [0xA0, 0xA9, 0xA9, 0xA9])
    #expect(MarkdownHTML.decodeEntities("A &amp; B") == "A & B")
  }

  @Test func pictureSourceFollowsAppearance() {
    let tags = MarkdownHTML.tags(
      in: #"<source media="(prefers-color-scheme: dark)" srcset="d.png"><source media="(prefers-color-scheme: light)" srcset="l.png 1x, l2.png 2x">"#)
    #expect(MarkdownHTML.pictureSource(tags, isDark: true) == "d.png")
    #expect(MarkdownHTML.pictureSource(tags, isDark: false) == "l.png")
  }

  @Test func displaySizeFollowsHTMLRules() {
    let url = URL(string: "https://x/y.png")!
    let natural = CGSize(width: 1200, height: 600)
    let plain = MarkdownImageSpec(url: url, range: NSRange())
    #expect(plain.displaySize(natural: natural, maxWidth: 600) == CGSize(width: 600, height: 300))
    #expect(plain.displaySize(natural: natural, maxWidth: 2000) == natural)
    let w = MarkdownImageSpec(url: url, range: NSRange(), width: 400)
    #expect(w.displaySize(natural: natural, maxWidth: 900) == CGSize(width: 400, height: 200))
    let h = MarkdownImageSpec(url: url, range: NSRange(), height: 52)
    #expect(h.displaySize(natural: natural, maxWidth: 900) == CGSize(width: 104, height: 52))
    let pct = MarkdownImageSpec(url: url, range: NSRange(), widthFraction: 0.5)
    #expect(pct.displaySize(natural: natural, maxWidth: 800) == CGSize(width: 400, height: 200))
  }

  // MARK: - Parser

  private let readme = URL(string: "https://github.com/o/r/blob/main/README.md")!
  private var githubLike: MarkdownURLResolver {
    MarkdownURLResolver(
      documentURL: readme,
      resolveImage: { MarkdownURLResolver.resolveRelative($0, against: URL(string: "https://raw.example/o/r/main/README.md")) },
      resolveLink: { [readme] in MarkdownURLResolver.resolveRelative($0, against: readme) })
  }

  @Test func htmlImagesResolveAndCarrySize() {
    let md = "<p align=\"center\">\n  <img src=\"./assets/logo.png\" width=\"70\" valign=\"middle\">\n</p>\n\nText"
    let parsed = MarkdownParser.parse(md, resolver: githubLike)
    let a = parsed.attributed
    #expect(a.string == md)
    let imgAt = (md as NSString).range(of: "<img").location
    #expect((a.attribute(.markdownImage, at: imgAt, effectiveRange: nil) as? URL)?.absoluteString
      == "https://raw.example/o/r/main/assets/logo.png")
    let spec = a.attribute(.markdownImageSpec, at: imgAt + 3, effectiveRange: nil) as? MarkdownImageSpec
    #expect(spec?.width == 70)
    #expect(spec?.verticalAlignment == .middle)
    #expect(spec?.range == (md as NSString).range(of: #"<img src="./assets/logo.png" width="70" valign="middle">"#))
    // The <p> and </p> lines carry nothing visible: collapsible; the image line is not.
    #expect(a.attribute(.markdownCollapsibleLine, at: 0, effectiveRange: nil) != nil)
    #expect(a.attribute(.markdownCollapsibleLine, at: imgAt, effectiveRange: nil) == nil)
    let closeAt = (md as NSString).range(of: "</p>").location
    #expect(a.attribute(.markdownCollapsibleLine, at: closeAt, effectiveRange: nil) != nil)
    // align="center" centers the block's lines; the indentation is hidden.
    let para = a.attribute(.paragraphStyle, at: imgAt, effectiveRange: nil) as? NSParagraphStyle
    #expect(para?.alignment == .center)
    #expect(a.attribute(.markdownSyntax, at: imgAt - 1, effectiveRange: nil) != nil)
    let textPara = a.attribute(.paragraphStyle, at: (md as NSString).range(of: "Text").location, effectiveRange: nil) as? NSParagraphStyle
    #expect(textPara?.alignment != .center)
  }

  @Test func markdownImagesResolveRelativeAndRootPaths() {
    let md = "![a](docs/x.gif) ![b](/.github/y.png)"
    let a = MarkdownParser.parse(md, resolver: githubLike).attributed
    #expect((a.attribute(.markdownImage, at: 1, effectiveRange: nil) as? URL)?.absoluteString
      == "https://raw.example/o/r/main/docs/x.gif")
    let second = (md as NSString).range(of: "![b]").location
    #expect((a.attribute(.markdownImage, at: second, effectiveRange: nil) as? URL)?.absoluteString
      == "https://raw.example/.github/y.png")  // a plain base resolves "/" to the host root
    // Separate spec objects even for adjacent images.
    let s1 = a.attribute(.markdownImageSpec, at: 0, effectiveRange: nil) as AnyObject?
    let s2 = a.attribute(.markdownImageSpec, at: second, effectiveRange: nil) as AnyObject?
    #expect(s1 !== s2)
  }

  @Test func pictureUsesTheAppearanceSource() {
    let md = """
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="/d.png">
        <source media="(prefers-color-scheme: light)" srcset="/l.png">
        <img src="/d.png" alt="Shot" width="600">
      </picture>
      """
    let a = MarkdownParser.parse(md, resolver: githubLike).attributed
    let imgAt = (md as NSString).range(of: "<img").location
    let url = a.attribute(.markdownImage, at: imgAt, effectiveRange: nil) as? URL
    // Tests run with the default (light) appearance.
    #expect(url?.lastPathComponent == (MarkdownRenderer.currentAppearanceIsDark() ? "d.png" : "l.png"))
    for marker in ["<picture>", "<source media=\"(prefers-color-scheme: dark)\"", "</picture>"] {
      let at = (md as NSString).range(of: marker).location
      #expect(a.attribute(.markdownCollapsibleLine, at: at, effectiveRange: nil) != nil, "\(marker)")
    }
  }

  @Test func htmlLinksStylesAndEntities() {
    let md = "<p>Press <kbd>⌘K</kbd>, see <a href=\"#install\">install</a> &copy; <b>bold</b></p>"
    let a = MarkdownParser.parse(md, resolver: githubLike).attributed
    #expect(a.string == md)
    let link = (md as NSString).range(of: ">install<").location + 1
    #expect((a.attribute(.link, at: link, effectiveRange: nil) as? URL)?.fragment == "install")
    let kbd = (md as NSString).range(of: "⌘K").location
    #expect(a.attribute(.markdownInlineCode, at: kbd, effectiveRange: nil) != nil)
    let copy = (md as NSString).range(of: "&copy;").location
    #expect((a.attribute(.markdownGlyphSubstitute, at: copy, effectiveRange: nil) as? NSNumber)?.intValue == 0xA9)
    #expect(a.attribute(.markdownSyntax, at: copy + 1, effectiveRange: nil) != nil)
    let bold = (md as NSString).range(of: ">bold<").location + 1
    #expect((a.attribute(.font, at: bold, effectiveRange: nil) as? PlatformFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
  }

  @Test func inlineEntitiesInMarkdownText() {
    let md = "Tom &amp; Jerry \\* star"
    let a = MarkdownParser.parse(md).attributed
    let amp = (md as NSString).range(of: "&amp;").location
    #expect((a.attribute(.markdownGlyphSubstitute, at: amp, effectiveRange: nil) as? NSNumber)?.intValue == 0x26)
    // The escape after the entity is still found.
    let backslash = (md as NSString).range(of: "\\").location
    #expect(a.attribute(.markdownSyntax, at: backslash, effectiveRange: nil) != nil)
    #expect(a.attribute(.markdownSyntax, at: backslash + 1, effectiveRange: nil) == nil)
  }

  @Test func referenceDefinitionsAreHidden() {
    let md = "![OSS][OSS Icon] means open source\n\n[OSS Icon]: https://x.y/oss.svg \"Open Source\""
    let a = MarkdownParser.parse(md).attributed
    #expect((a.attribute(.markdownImage, at: 0, effectiveRange: nil) as? URL)?.absoluteString == "https://x.y/oss.svg")
    let def = (md as NSString).range(of: "[OSS Icon]:").location
    #expect(a.attribute(.markdownSyntax, at: def, effectiveRange: nil) != nil)
    #expect(a.attribute(.markdownCollapsibleLine, at: def, effectiveRange: nil) != nil)
  }

  @Test func htmlHeadingAndRule() {
    let md = "<h1>\n  <img src=\"logo.png\" width=\"70\">\n  &nbsp;container\n</h1>\n<hr>\n\nBody"
    let a = MarkdownParser.parse(md, resolver: githubLike).attributed
    let word = (md as NSString).range(of: "container").location
    let font = a.attribute(.font, at: word, effectiveRange: nil) as? PlatformFont
    #expect(font?.pointSize == MarkdownMetrics.standard.headingSizes[0])
    let hr = (md as NSString).range(of: "<hr>").location
    #expect(a.attribute(.markdownRule, at: hr, effectiveRange: nil) != nil)
  }

  @Test func verbatimInvariantOnHTMLHeavyInput() {
    let samples = [
      "<div align=\"center\" markdown=\"1\">\n  <sup>Thanks</sup>\n  <br>\n\n  <a href=\"https://a.b/\">\n    <img alt=\"x\" width=\"400\" src=\"https://a.b/c.png\">\n  </a>\n</div>\n<hr>",
      "<!--idoc:ignore:start-->\n## Contents\n<!--\nmulti\nline\n-->\n",
      "<p>unclosed <b>bold\n\n<img src=x>",
      "&nbsp;&amp;&#x1F600;&#169;",
    ]
    for md in samples { #expect(MarkdownParser.parse(md).attributed.string == md) }
  }

  // MARK: - Anchors

  @Test func anchorsUseGitHubSlugs() {
    let md = "# Get started\n## Get started\n### C++ & Swift: notes!\n<a name=\"custom\"></a>\nText"
    let anchors = MarkdownParser.anchors(in: md)
    #expect(anchors["get-started"] == 0)
    #expect(anchors["get-started-1"] == (md as NSString).range(of: "## Get").location)
    #expect(anchors["c--swift-notes"] != nil)
    #expect(anchors["custom"] != nil)
    #expect(MarkdownParser.githubSlug("Upgrade or downgrade") == "upgrade-or-downgrade")
  }
}

#if canImport(AppKit)
  /// Image slots in a hosted editor: a loaded image takes its size in the text flow.
  @Suite @MainActor struct ImageLayoutTests {
    private func hosted(_ text: String, width: CGFloat = 600, readOnly: Bool = false)
      -> (NSWindow, EditorTextView)
    {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.titled],
        backing: .buffered, defer: false)
      let tv = EditorTextView(metrics: .standard)
      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
      scroll.documentView = tv
      window.contentView = scroll
      tv.frame = NSRect(x: 0, y: 0, width: width, height: 800)
      tv.isReadOnly = readOnly
      tv.setText(text)
      tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
      tv.layoutManager?.ensureLayout(for: tv.textContainer!)
      return (window, tv)
    }

    private func storeImage(_ name: String, size: CGSize) -> URL {
      let url = URL(string: "test-image://\(name)/\(UUID().uuidString).png")!
      let image = NSImage(size: size)
      MarkdownImageCache.shared.store(image, naturalSize: size, for: url)
      return url
    }

    @Test func loadedImageTakesItsSizeInTheFlow() {
      let url = storeImage("a", size: CGSize(width: 120, height: 60))
      let md = "ab ![alt](\(url.absoluteString)) cd\nnext"
      let (window, tv) = hosted(md)
      defer { _ = window }
      let lm = tv.layoutManager!
      let ns = md as NSString
      let cd = lm.glyphIndexForCharacter(at: ns.range(of: "cd").location)
      let ab = lm.glyphIndexForCharacter(at: 0)
      let gap = lm.location(forGlyphAt: cd).x - lm.location(forGlyphAt: ab).x
      // "ab " + 120pt image + " " — the source text itself takes no width.
      #expect(gap > 120 && gap < 150, "gap \(gap)")
      let frag = lm.lineFragmentRect(forGlyphAt: cd, effectiveRange: nil)
      #expect(frag.height >= 60)
      let next = lm.lineFragmentRect(
        forGlyphAt: lm.glyphIndexForCharacter(at: ns.range(of: "next").location), effectiveRange: nil)
      #expect(next.height < 40)
    }

    @Test func caretInsideTheImageShowsItsSource() {
      let url = storeImage("b", size: CGSize(width: 200, height: 100))
      let md = "x ![alt](\(url.absoluteString)) y"
      let (window, tv) = hosted(md)
      defer { _ = window }
      let first = (md as NSString).range(of: "![").location
      #expect(tv.textStorage?.attribute(.kern, at: first, effectiveRange: nil) != nil)
      tv.setSelectedRange(NSRange(location: first + 3, length: 0))
      #expect(tv.textStorage?.attribute(.kern, at: first, effectiveRange: nil) == nil)
      tv.setSelectedRange(NSRange(location: 0, length: 0))
      #expect(tv.textStorage?.attribute(.kern, at: first, effectiveRange: nil) != nil)
    }

    @Test func wideImagesShrinkToTheContainer() {
      let url = storeImage("c", size: CGSize(width: 3000, height: 1500))
      let (window, tv) = hosted("![wide](\(url.absoluteString))", width: 600)
      defer { _ = window }
      let lm = tv.layoutManager as! EditorLayoutManager
      let spec = tv.textStorage?.attribute(.markdownImageSpec, at: 0, effectiveRange: nil) as! MarkdownImageSpec
      let size = lm.renderedImageSize(spec)!
      let available = tv.textContainer!.size.width - 2 * tv.textContainer!.lineFragmentPadding
      #expect(abs(size.width - available) <= 1)
      #expect(abs(size.height - size.width / 2) <= 1)
    }

    @Test func markupOnlyLinesCollapseInTheViewer() {
      let url = storeImage("d", size: CGSize(width: 50, height: 50))
      let md = "<p align=\"center\">\n<img src=\"\(url.absoluteString)\">\n</p>\n\nText"
      let (window, tv) = hosted(md, readOnly: true)
      defer { _ = window }
      let lm = tv.layoutManager!
      let open = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
      #expect(open.height == 0)
      let img = lm.lineFragmentRect(
        forGlyphAt: lm.glyphIndexForCharacter(at: (md as NSString).range(of: "<img").location),
        effectiveRange: nil)
      #expect(img.height >= 50)
      // Centered: the image's slot starts right of the container's left edge.
      let x = lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: (md as NSString).range(of: "<img").location)).x
      #expect(x > 100)
    }

    @Test func readOnlyNeverRevealsSyntax() {
      let (window, tv) = hosted("# Title\n\n**bold**", readOnly: true)
      defer { _ = window }
      tv.setSelectedRange(NSRange(location: 1, length: 0))
      let lm = tv.layoutManager!
      // "# " stays collapsed: "T" sits at the line start.
      let t = lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: 2)).x
      let hash = lm.location(forGlyphAt: 0).x
      #expect(abs(t - hash) < 1)
      #expect(!tv.isEditable)
    }

    @Test func anchorsScroll() {
      let body = (0..<200).map { "line \($0)" }.joined(separator: "\n\n")
      let (window, tv) = hosted("# Top\n\n\(body)\n\n## Far Away\n\nend", readOnly: true)
      defer { _ = window }
      #expect(tv.scrollToAnchor("far-away"))
      #expect(tv.visibleRect.minY > 1000)
      #expect(!tv.scrollToAnchor("missing"))
    }
  }
#endif
