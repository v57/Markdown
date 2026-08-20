# Markdown

A markdown editor library for Apple platforms, built on TextKit 1 live
preview (Obsidian-style: syntax symbols are hidden on inactive lines and
appear while you edit them).

The package is split into four targets:

  Md        - the macOS editor stack (AppKit: NSTextView + NSLayoutManager).
              Used by the macOS app in Markdown.xcodeproj.
  MdUIKit   - the iOS editor stack (UIKit: UITextView + NSLayoutManager).
              This is the UIKit alternative to the AppKit stack - the two are
              separate, NOT merged in SwiftUI. iOS 17+.
  MdCore    - platform-neutral core shared by both stacks: the markdown parser
              (MarkdownParser), the style spec (MarkdownColor/MarkdownFont/
              MarkdownParagraph + the MarkdownStyling protocol), the shared
              TextKit layout-manager logic (EditorLayoutManagerCore), the
              native renderer (MarkdownRenderer), and SampleDocument.
  MdCode    - the code-syntax highlighting engine (scanner, language catalog,
              Xcode-style categories) with a platform-neutral hex color scheme
              (CodeColorScheme). No AppKit/UIKit.

Architecture

  Both editor stacks share ONE parser and ONE layout-engine core. The parser
  produces a fully-native NSAttributedString on each platform: it stores
  platform-neutral attribute values (MarkdownColor/MarkdownFont/
  MarkdownParagraph) and MarkdownRenderer resolves them to NSColor/NSFont/
  NSParagraphStyle on macOS and UIColor/UIFont/NSParagraphStyle on iOS.

  The TextKit 1 layout manager is the same NSLayoutManager class on both
  platforms. EditorLayoutManagerCore owns the glyph substitution (zero-width
  hidden commands, checkbox slot widths), run classification, and geometry;
  each platform subclass (Md/EditorLayoutManager on macOS, MdUIKit/
  EditorLayoutManager on iOS) supplies only the drawing hooks (bezier paths,
  colors, images, chrome labels).

  The two editor views are intentionally separate types that happen to share
  a name:
    - Md.MarkdownEditorView        = NSViewRepresentable (macOS)
    - MdUIKit.MarkdownEditorView   = UIViewControllerRepresentable (iOS)
  Do NOT import both Md and MdUIKit in the same file - the shared symbol
  names (EditorTextView, EditorLayoutManager, InlineImageCache,
  MarkdownEditorView) would collide.

Embedding

  macOS (AppKit/SwiftUI host):
      import Md
      MarkdownEditorView()                       // NSViewRepresentable

  iOS (UIKit host):
      import MdUIKit
      let vc = MarkdownEditorViewController()    // the main deliverable

  iOS (SwiftUI host):
      import MdUIKit
      MarkdownEditorView()                       // UIViewControllerRepresentable

  Headless parsing/styling on either platform:
      import MdCore
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
  iOS:    swift build --triple arm64-apple-ios17.0-simulator --target MdUIKit
          xcodebuild -scheme MdUIKit -destination 'generic/platform=iOS
          Simulator' build-for-testing
          (MdUIKitTests run via Xcode on an iOS simulator)
