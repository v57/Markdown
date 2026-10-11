# Markdown

A markdown editor library for Apple platforms, built on TextKit 1 live
preview (Obsidian-style: syntax symbols are hidden on inactive lines and
appear while you edit them).

Single library, one module: `Md`. Platform-specific code lives in
`Sources/Md/AppKit/` (macOS) and `Sources/Md/UIKit/` (iOS), selected with
`#if canImport(AppKit)` / `#if canImport(UIKit)` — there is no separate
UIKit/AppKit framework, no separate core framework. Everything compiles into
the one `Md` module on the host platform.

Requirements: the `Md` library supports macOS 12+ and iOS 15+ (the oldest the
current toolchain targets). The app needs macOS 14+ and iOS 17+ (Observation and
SwiftData).

Layout

  Sources/Md/                 platform-neutral core
    MarkdownParser.swift        the markdown parser (swift-markdown AST)
    MarkdownRenderer.swift      renders neutral attributes -> native types
    MarkdownStyleSpec.swift     MarkdownColor/Font/Paragraph + MarkdownStyling
    EditorLayoutManagerCore.swift  shared TextKit layout logic + draw hooks
    MarkdownKeys.swift          NSAttributedString.Key extensions
    TableColumnLayout.swift     table grid geometry (column targets, kerns)
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

App (Markdown.xcodeproj)

  The app is a SwiftUI app that builds and runs on BOTH macOS and iOS.
  Entry is @main on MarkdownApp (Markdown/MarkdownApp.swift); the macOS CLI
  harness (--selftest / --smoke / --typingprobe) runs in MarkdownApp.init
  under #if os(macOS) and is absent on iOS (the probes get the sample editor
  instead of the library window). The single MarkdownEditorView symbol
  resolves to the AppKit NSViewRepresentable on macOS and the UIKit
  UIViewControllerRepresentable on iOS.

  Folder sidebar: drop folders on the sidebar (Finder, Files) or use Add
  Folder (⇧⌘O). They are saved with SwiftData (SidebarFolder: path plus a
  security-scoped bookmark, so the sandbox grants access again after a
  relaunch) and shown as expandable trees of subfolders and markdown files.
  Selecting a folder shows its README (also .github/ and docs/); selecting a
  file shows it. Files are edited in place: DocumentSaver writes edits back
  (coordinated, atomic) after a short pause, and right away on ⌘S, switching
  documents, reload, backgrounding and quit. The toolbar toggles Editing /
  Preview (read-only, links tappable on iOS). Folders added while the app was
  read-only keep read-only bookmarks; a failed save offers "Allow Editing…"
  (macOS), which re-grants the folder read-write. Relative images resolve
  against the file and "/" against the sidebar folder; links to markdown files
  and folders open in the app with back/forward (⌘[ ⌘]), Reload is ⌘R.

    Markdown/Library/   SidebarFolder (SwiftData), FolderLibrary, Navigator,
                        DocumentSaver
    Markdown/Views/     SidebarView, DocumentView
    Markdown.entitlements  bookmarks.app-scope (macOS; the rest comes from
                           build settings)

  Debug simulator builds accept --add-folder <path> (repeatable) to add and
  show a Mac folder at launch without the picker. (Not on macOS: the sandbox
  grants no access to a path given on the command line.)

Features (both stacks)

  - Live re-styling on every edit; the source text is kept verbatim.
  - Headings (ATX and setext), lists (incl. task lists and nesting, with
    wrapped lines hanging under the item text), blockquotes (nested, with lists
    inside), fenced code (highlighted with the GitHub palette), tables,
    horizontal rules, links and bare URLs, inline images,
    bold/italic/strikethrough/inline code.
  - Tables render as an aligned grid (pipes hidden, separators drawn); click
    into a table or its corner toggle to edit the source. A table wider than
    the editor falls back to raw markdown until the editor is wide enough.
  - Syntax symbols hidden on inactive lines, shown on the active line
    (Obsidian-style live preview).
  - Checkbox click-to-toggle, code-block copy button, smart list/quote
    continuation on Return.
  - Dynamic dark/light support (system colors + GitHub Light/Dark code
    palette, resolved from the editor view's own appearance).
  - Every metric (fonts, spacing, drawn geometry) comes from the
    `MarkdownMetrics` passed to the editor.

Verification

  macOS:  swift build && swift test
          (108 tests: parser, style spec, layout probes, highlighter, schemes,
          tables, rendering regressions, HTML/images/anchors)
          xcodebuild -project Markdown.xcodeproj -scheme Markdown build
  iOS:    swift build --triple arm64-apple-ios15.0-simulator --build-tests
          xcodebuild -project Markdown.xcodeproj -scheme Markdown
            -destination 'generic/platform=iOS Simulator' build
          (app runs on the iOS simulator; UIKit tests in
          Tests/MdTests/MdUIKitTests.swift run via Xcode)
