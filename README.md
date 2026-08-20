# Markdown

A markdown editor library for Apple platforms, built on TextKit 1 live
preview (Obsidian-style: syntax symbols are hidden on inactive lines and
appear while you edit them).

Single library, one module: `Md`. Platform-specific code lives in
`Sources/Md/AppKit/` (macOS) and `Sources/Md/UIKit/` (iOS), selected with
`#if canImport(AppKit)` / `#if canImport(UIKit)` — there is no separate
UIKit/AppKit framework, no separate core framework. Everything compiles into
the one `Md` module on the host platform.

Layout

  Sources/Md/                 platform-neutral core
    MarkdownParser.swift        the markdown parser (swift-markdown AST)
    MarkdownRenderer.swift      renders neutral attributes -> native types
    MarkdownStyleSpec.swift     MarkdownColor/Font/Paragraph + MarkdownStyling
    EditorLayoutManagerCore.swift  shared TextKit layout logic + draw hooks
    MarkdownKeys.swift          NSAttributedString.Key extensions
    CodeColorScheme.swift       hex-based code palette (platform-neutral)
    CodeHighlighter.swift       code syntax highlighting engine
    ...                         scanner/catalog/spec/kind, SampleDocument
  Sources/Md/AppKit/          macOS editor stack (imports AppKit)
    EditorTextView.swift         NSTextView subclass (live re-styling)
    EditorLayoutManager.swift    NSLayoutManager drawing (NSBezierPath/NSImage)
    EditorView.swift             NSViewRepresentable (SwiftUI host)
    MarkdownStyle.swift          AppKit MarkdownStyling implementation
    CheckboxAttachment.swift     NSImage checkbox renderer
    InlineImageCache.swift       NSImage cache
    SelfTest.swift               CLI harness (--selftest/--smoke/--typingprobe)
  Sources/Md/UIKit/           iOS editor stack (imports UIKit)
    EditorTextViewUIKit.swift    UITextView subclass (live re-styling)
    EditorLayoutManagerUIKit.swift NSLayoutManager drawing (UIBezierPath/UIImage)
    MarkdownEditorViewController.swift  the main iOS deliverable
    MarkdownEditorView.swift     UIViewControllerRepresentable (SwiftUI host)
    MarkdownUIKitStyle.swift     UIKit MarkdownStyling implementation
    CheckboxRenderer.swift       UIImage checkbox renderer
    InlineImageCacheUIKit.swift  UIImage cache

(The UIKit files carry a `UIKit` suffix in their filename to avoid SwiftPM's
unique-filename rule; the AppKit files keep their original names.)

Architecture

  One parser, one layout-engine core, two drawing front-ends. The parser
  produces a fully-native NSAttributedString on each platform: it stores
  platform-neutral attribute values (MarkdownColor/MarkdownFont/
  MarkdownParagraph) and MarkdownRenderer resolves them to NSColor/NSFont/
  NSParagraphStyle on macOS and UIColor/UIFont/NSParagraphStyle on iOS.

  The TextKit 1 layout manager is the same NSLayoutManager class on both
  platforms. EditorLayoutManagerCore owns the glyph substitution (zero-width
  hidden commands, checkbox slot widths), run classification, and geometry;
  each platform subclass (AppKit/EditorLayoutManager.swift on macOS,
  UIKit/EditorLayoutManagerUIKit.swift on iOS) supplies only the drawing
  hooks (bezier paths, colors, images, chrome labels).

  The two editor views are different types that happen to share a name:
    - Md.MarkdownEditorView (AppKit)  = NSViewRepresentable (macOS)
    - Md.MarkdownEditorView (UIKit)   = UIViewControllerRepresentable (iOS)
  Both are in the same Md module, so only one can exist per platform — which
  is exactly what #if canImport gives us: on macOS you get the NSView one, on
  iOS the UIViewController one.

Embedding

  macOS (AppKit/SwiftUI host):
      import Md
      MarkdownEditorView()                       // NSViewRepresentable

  iOS (UIKit host):
      import Md
      let vc = MarkdownEditorViewController()    // the main deliverable

  iOS (SwiftUI host):
      import Md
      MarkdownEditorView()                       // UIViewControllerRepresentable

  Headless parsing/styling on either platform:
      import Md
      let parsed = MarkdownParser.parse("# Hi\n\n**bold** and `code`")
      parsed.attributed                          // native NSAttributedString
      parsed.blocks                              // [MarkdownParser.Block]

Features (both stacks)

  - Live re-styling on every edit; the source text is kept verbatim.
  - Headings, lists (incl. task lists), blockquotes, fenced code (highlighted
    with the GitHub palette), tables, horizontal rules, links, inline images,
    bold/italic/strikethrough/inline code.
  - Syntax symbols hidden on inactive lines, shown on the active line
    (Obsidian-style live preview).
  - Checkbox click-to-toggle, code-block copy button, smart list/quote
    continuation on Return.
  - Dynamic dark/light support (system colors + GitHub Light/Dark code
    palette).

Verification

  macOS:  swift build && swift test
          (48 tests: parser, style spec, layout probes, highlighter, schemes)
  iOS:    swift build --triple arm64-apple-ios17.0-simulator --build-tests
          (the UIKit tests in Tests/MdTests/MdUIKitTests.swift run via Xcode
          on an iOS simulator)
