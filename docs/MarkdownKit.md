# MarkdownKit

## Purpose

MarkdownKit is a Markdown editor and viewer with live preview, in the style of Obsidian: syntax symbols are hidden on
lines you aren't editing and appear on the line you are. It is built on TextKit 1, with an AppKit front end on the Mac
and a UIKit one on iPhone and iPad, and one SwiftUI view, `MarkdownEditorView`, for both. The same view in read-only
mode is a document viewer: the Markdown app's Read mode, Shell's Markdown files and Agentus's Docs pane use it.

The editor keeps the source text exactly as typed. The parser only adds attributes on top of it, so what you save is
what the user wrote. MarkdownKit edits text, not files: loading, saving, folders and sync belong to the app. It is
not a general Markdown-to-HTML converter.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Markdown.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "MarkdownKit", package: "Markdown")]),
]
```

MarkdownKit depends on [swift-markdown](https://github.com/swiftlang/swift-markdown) (the `Markdown` module, which is
why the library is `MarkdownKit`) and on Code's `CodeHighlighting` (`https://github.com/v57/Code.git`). To build
against a Code checkout next to this one, open `Markdown-Local.xcworkspace`, or run SwiftPM with `V57_LOCAL=1`.

An editor for a note on disk, with a Bold button:

```swift
import MarkdownKit
import SwiftUI

struct NoteEditor: View {
  let fileURL: URL
  let initialText: String
  @State private var commands = MarkdownEditorCommands()

  var body: some View {
    VStack(spacing: 0) {
      Button("Bold") { commands.apply(.bold) }
      MarkdownEditorView(
        text: initialText,
        resolver: .relative(to: fileURL),
        onChange: { text in try? text.write(to: fileURL, atomically: true, encoding: .utf8) },
        commands: commands)
    }
  }
}
```

Pass `text` explicitly: without it the editor shows a built-in sample document (`SampleDocument.text`). A new `text`
value from the host replaces the editor's contents; the same value again never rolls back the user's edits.

A read-only viewer that asks before loading web images and before opening unusual links:

```swift
MarkdownEditorView(text: readme, resolver: .relative(to: readmeURL), isReadOnly: true)
  .remoteImages(loads: loadImages) { blocked in showsLoadImagesBar = blocked }
  .onConfirmLink { request in pendingLink = request }  // show request.title and request.message, then request.open()
```

`remoteImages(loads:onBlocked:)` and `onConfirmLink(_:)` return the editor view itself, so call them before any other
modifier.

## Main API

### The editor view

`MarkdownEditorView(metrics:text:resolver:isReadOnly:anchor:onChange:onOpenURL:startsEditing:commands:)`:
- `metrics`: a `MarkdownMetrics` (fonts, spacing, margins, drawn geometry). Every number the editor draws with comes
  from it; `.standard` is the default look.
- `text`: the document. `onChange` gets the full text after every edit.
- `resolver`: how relative image sources and link destinations resolve (below).
- `isReadOnly`: viewer mode. Syntax stays hidden everywhere and links can be followed.
- `anchor`: a heading's GitHub-style slug to scroll to; a new value scrolls again.
- `onOpenURL`: asked first when a link is followed; return `true` when your app handled it (another note, say).
- `startsEditing`: puts the caret in the editor when it appears.
- `commands`: a `MarkdownEditorCommands` to drive formatting from your toolbar or menu.

On the Mac it is an `NSViewRepresentable` around `EditorTextView` (an `NSTextView`). On iPhone and iPad it is a
`UIViewControllerRepresentable` around `MarkdownEditorViewController`, which hosts `EditorTextView` (a `UITextView`).
A UIKit app can use `MarkdownEditorViewController(metrics:)` directly. On both, `EditorTextView` has `setText(_:)`,
`scrollToAnchor(_:)`, `isReadOnly`, `resolver`, `onChange`, `onOpenURL`, `onConfirmLink`, `loadsRemoteImages` and
`onRemoteImagesBlocked`.

What the editor shows: headings (ATX and setext), lists with nesting and task lists (click a checkbox to toggle it),
quotes, fenced code with syntax colors, a language label and a copy button, tables as an aligned grid (click into one,
or its corner toggle, to edit the source), rules, links and bare URLs, inline images, and bold, italic, strikethrough
and inline code. Return continues a list or quote. A table wider than the editor shows as plain Markdown until there
is room. Light and dark follow the view's own appearance.

### Formatting

- `MarkdownEditorCommands`: `apply(_:)` a `MarkdownFormat` to the attached editor's selection as one undoable edit,
  `focus()`, and `isAvailable` (false while no editor is attached or it is read-only).
- `MarkdownFormat`: `.bold`, `.italic`, `.strikethrough`, `.inlineCode`, `.link`, `.heading(_:)`, `.bulletList`,
  `.numberedList`, `.checklist`, `.quote`, `.codeBlock`, `.table`, and the toggles `.toggleList`, `.toggleCheckbox`,
  `.toggleCheckedCheckbox`, `.toggleCode`. Inline styles wrap or unwrap the selection; line styles toggle a prefix on
  every selected line.
- `MarkdownQuickAction`: the toggles a keyboard bar offers, each with a `format`, `title`, `systemImage` and `shortcut`.
- `MarkdownFormatting.edit(applying:to:selection:)`: the same edit as a `MarkdownEdit` (range, replacement, new
  selection), without a text view. Use it to format text in your own editor or in tests.

### Parsing (Mac, iPhone and iPad)

- `MarkdownParser.parse(_:style:sourceModeTables:maxTableWidth:resolver:)` returns a `ParsedMarkdown`: `attributed`
  (a native `NSAttributedString` whose string is the source, unchanged), `syntaxRanges`, `blocks` (a simple
  `MarkdownParser.Block` list: headings, paragraphs, quotes, lists, task lists, code fences, tables, rules) and
  `tableWidths`.
- Styling is platform-neutral: the parser writes `MarkdownColor`, `MarkdownFont` and `MarkdownParagraph` values from a
  `MarkdownStyling` (`MarkdownStyleSpec` by default, built from `MarkdownMetrics`), and `MarkdownRenderer.render(_:)`
  turns them into `NSFont`/`UIFont`, `NSColor`/`UIColor` and `NSParagraphStyle`.
- The attributes the editor draws from are `NSAttributedString.Key` extensions in `MarkdownKeys.swift`
  (`.markdownSyntax`, `.markdownImage`, `.markdownImageSpec`, `.markdownCodeBlock`, `.markdownTableGrid`, …).
- `MarkdownParser.listContinuation(for:)` and `quoteContinuation(for:)`: what Return should insert after a list item
  or quote line.
- Helpers that work on every platform: `MarkdownParser.githubSlug(_:)` and `MarkdownParser.anchors(in:)` (in-page
  anchors, numbered for repeats as GitHub does), and `MarkdownHTML` (the slice of HTML READMEs use, tokenized from the
  source).

### HTML in documents

The parser understands the HTML that GitHub READMEs use and hides the markup: `<img>` as an image (with `width` and
`height`), `<a href>` as a link, `align="center"` as a centered line, `<picture>` as the source that matches the light
or dark appearance, headings, `<b>` and `<kbd>` as styled text, and entities as characters. It never rewrites the text.

### Code highlighting

Fenced code is colored by Code's `CodeHighlighting` (`CodeHighlighter`), which picks the language from the fence's
info string and names it in the block's corner. Colors follow `CodeColorScheme.systemAware`
(`MarkdownRenderer.currentCodeScheme()`), GitHub's light and dark palettes.

### Links

- `MarkdownURLResolver`: turns a document's raw destinations into absolute URLs. `.relative(to:root:)` resolves
  against the document's folder, and a root-relative path (`/docs/a.png`) against `root` (a repository's top folder).
  `.absoluteOnly` (the default) resolves only absolute URLs. An app can pass its own closures, for example to send a
  GitHub README's images to `raw.githubusercontent.com`.
- When a link is followed, a same-document `#anchor` scrolls. Otherwise `onOpenURL` is asked first, and what it
  doesn't handle goes through `MarkdownLinkPolicy.action(for:)`:
  - `http`, `https` and `mailto` open at once (`.open`). So do Markdown files and plain folders.
  - Programs, scripts, launchers, app bundles and packages, and any executable file are only shown in Finder
    (`.reveal`), never opened.
  - Any other file or scheme asks first (`.ask`): the editor hands `onConfirmLink` a `MarkdownLinkRequest` (`url`,
    `opener`, `title`, `message`, `open()`), or shows a system alert without one.

  `onOpenURL` runs before the policy, so a host that opens URLs itself takes over that check.

### Images

- `MarkdownImageCache.shared` loads, decodes and caches images by resolved URL for every editor. It fetches through
  an ephemeral session without cookies and with a disk cache, decodes off the main thread, downsamples large images
  (`maxDecodedPixelSize`), animates GIF, APNG and WebP, and draws SVG (rasterized through WebKit on iOS).
- Web images don't load by default, so opening a document contacts no server. Files and `data:` images always load.
  `remoteImages(loads:onBlocked:)` turns web images on, and `onBlocked` tells you whether the document has web images
  that didn't load, to show a "Load images" bar.
- `MarkdownImageSpec` describes one image's size, alignment and alt text, for hosts that draw their own.

## Platform notes

- **macOS** (14 and later): the AppKit editor (`Sources/MarkdownKit/AppKit/`).
- **iOS and iPadOS** (17 and later): the UIKit editor (`Sources/MarkdownKit/UIKit/`). Links can be tapped in
  read-only mode.
- **Linux and Windows:** built and tested on Linux, runs on Windows, on v57/SwiftUI. TextKit isn't there, so
  `MarkdownEditorView` is a portable SwiftUI view (`Sources/MarkdownKit/Portable/`) with the same initializer: it
  edits the source in a plain text editor (the formatting commands work) and, read-only, draws the document with
  SwiftUI from swift-markdown's tree (headings, inline styles, links, lists and task lists, quotes, highlighted code,
  tables, images). `MarkdownParser.parse`, `MarkdownRenderer` and `MarkdownImageCache` are Apple-only.
  `onConfirmLink` does nothing there: a link the policy would ask about doesn't open.
- **Android:** not yet.

## Testing

```bash
swift test
```

`MarkdownKitTests` cover the parser, the style spec, formatting, tables, document rendering and images, the link
policy and web images, editor transitions, and rendering regressions. The highlighter's own tests are in the Code
repository. The UIKit tests (`Tests/MarkdownKitTests/MdUIKitTests.swift`) run through Xcode on an iOS simulator. To
check that the tests build for iOS:

```bash
swift build --triple arm64-apple-ios17.0-simulator --build-tests
```

On Linux, the portable suites run with `swift test`; the attributed-rendering tests run only where the AppKit and
UIKit stacks are.

For your own tests, `MarkdownFormatting.edit(applying:to:selection:)` and `MarkdownParser.parse(_:)` need no view, and
`SampleDocument.text` exercises every feature.

See also: the user guide's [Writing and Reading](Writing-and-Reading.md) and
[Privacy and Security](Privacy-and-Security.md) (web images and links), and the [index](README.md).
