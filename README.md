# Markdown

A markdown editor library for Apple platforms, built on TextKit 1 live
preview (Obsidian-style: syntax symbols are hidden on inactive lines and
appear while you edit them).

Single library, one module: `MarkdownKit`. Platform-specific code lives in
`Sources/MarkdownKit/AppKit/` (macOS) and `Sources/MarkdownKit/UIKit/` (iOS), selected with
`#if canImport(AppKit)` / `#if canImport(UIKit)` — there is no separate
UIKit/AppKit framework, no separate core framework. Everything compiles into
the one `MarkdownKit` module on the host platform.

Requirements: macOS 14+ and iOS 17+, for both the `MarkdownKit` library and the app.
Fenced code is highlighted and colored by `CodeHighlighting` from the Code repo, which
must sit next to this one (`../Code`).

Layout

  Sources/MarkdownKit/        platform-neutral core
    MarkdownParser.swift        the markdown parser (swift-markdown AST)
    MarkdownRenderer.swift      renders neutral attributes -> native types
    MarkdownStyleSpec.swift     MarkdownColor/Font/Paragraph + MarkdownStyling
    MarkdownFormatting.swift    Format commands (bold, lists, tables…) as text edits
    EditorLayoutManagerCore.swift  shared TextKit layout logic + draw hooks
    MarkdownKeys.swift          NSAttributedString.Key extensions
    TableColumnLayout.swift     table grid geometry (column targets, kerns)
    ...                         images, metrics, HTML export, SampleDocument
  Sources/MarkdownKit/AppKit/ macOS editor stack (imports AppKit)
    EditorTextView.swift         NSTextView subclass (live re-styling)
    EditorLayoutManager.swift    NSLayoutManager drawing (NSBezierPath/NSImage)
    EditorView.swift             NSViewRepresentable (SwiftUI host)
    MarkdownStyle.swift          AppKit MarkdownStyling implementation
    CheckboxAttachment.swift     NSImage checkbox renderer
    InlineImageCache.swift       NSImage cache
    SelfTest.swift               CLI harness (--selftest/--smoke/--typingprobe)
  Sources/MarkdownKit/UIKit/  iOS editor stack (imports UIKit)
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
    - MarkdownKit.MarkdownEditorView (AppKit)  = NSViewRepresentable (macOS)
    - MarkdownKit.MarkdownEditorView (UIKit)   = UIViewControllerRepresentable (iOS)
  Both are in the same MarkdownKit module, so only one can exist per platform — which
  is exactly what #if canImport gives us: on macOS you get the NSView one, on
  iOS the UIViewController one.

Embedding

  macOS (AppKit/SwiftUI host):
      import MarkdownKit
      MarkdownEditorView()                       // NSViewRepresentable

  iOS (UIKit host):
      import MarkdownKit
      let vc = MarkdownEditorViewController()    // the main deliverable

  iOS (SwiftUI host):
      import MarkdownKit
      MarkdownEditorView()                       // UIViewControllerRepresentable

  Headless parsing/styling on either platform:
      import MarkdownKit
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

  Three columns, as in Notes: the sidebar lists where notes live (All Notes, the
  notes folder (synced through the vault) and its folders, GitHub
  repositories, folders dropped on the sidebar or added with Add Folder (⇧⌘O),
  files opened on their own); the note list shows the selected folder's notes,
  newest first, grouped by date (Pinned, Today, Yesterday, …) with each note's
  time and first line; the detail pane edits the note. With no note chosen, a
  folder's README is shown. Sidebar folders are saved with SwiftData
  (SidebarFolder: path plus a security-scoped bookmark, so the sandbox grants
  access again after a relaunch). Pins and recent notes are kept in the app's
  defaults (NotePreferences).

  Files are edited in place: DocumentSaver writes edits back (coordinated,
  atomic) after a short pause, and right away on ⌘S, switching documents,
  reload, backgrounding and quit; the status bar (macOS) says whether edits are
  saved and counts words. Edit / Read (⇧⌘E) switches between the live editor
  and a read-only view (links tappable on iOS). Formatting comes from
  MarkdownKit's MarkdownEditorCommands: the Format menu on macOS, a bar above
  the keyboard on iOS. Quick Open (⌘K) finds notes by name and by content and
  runs commands; the welcome sheet opens with the first window (unless turned
  off) and from Window › Welcome to Markdown. Folders added while the app was
  read-only keep read-only bookmarks; a failed save offers "Allow Editing…"
  (macOS), which re-grants the folder read-write. Relative images resolve
  against the file and "/" against the sidebar folder; links to markdown files
  and folders open in the app with back/forward (⌘[ ⌘]), Reload is ⌘R.

    Markdown/Library/   SidebarFolder (SwiftData), FolderLibrary, Navigator,
                        DocumentSaver, NoteList, NotePreferences, SearchScope
    Markdown/Views/     SidebarView, NoteListView, DocumentView, QuickOpenView,
                        WelcomeView, Commands (menu bar, window state)
    Markdown.entitlements  bookmarks.app-scope (macOS; the rest comes from
                           build settings)

  Notes: the sidebar's first section is the app's own notes folder —
  NotesLocation uses the app's Documents (On My iPhone › Markdown in Files on
  iOS) or a folder chosen with Choose Notes Folder… (macOS, a security-scoped
  bookmark). The notes sync through the vault (../Vault: CloudKit, encrypted,
  shared with Shell); NotesMirror keeps the folder and the vault's notes the
  same both ways, so they stay plain files any editor can open. New notes are
  encrypted `.mdenc` files unless Encrypt New Notes is off. Notes earlier
  versions kept in the app's iCloud Drive folder are copied in once. A file
  presenter on the folder reloads the sidebar and the open note when the mirror
  (or another app) changes them. FileActions creates notes (⌘N) and
  folders (⇧⌘N), renames, moves (drag onto a folder; files dragged in from
  other apps are copied) and trashes (Delete in the sidebar on macOS; a
  confirmed delete on iOS) in any folder the app can write. A new note opens
  with the caret in it (MarkdownEditorView's startsEditing). Search (the sidebar's search field,
  NoteSearch) matches every word against note names and text across all
  folders, names first.

  GitHub (Markdown/GitHub/, on GitHubKit from ../Git): "Connect GitHub
  Repository…" signs in with the OAuth device flow (GitHubAuth over
  GitHubAccount; the OAuth App's client ID is the GITHUB_CLIENT_ID build
  setting, the token goes to the Keychain) and lists
  your repositories; any public repository can be added without signing in
  (read-only). RepositorySync clones only notes — markdown files and images —
  through the REST Git Data API into Application Support/GitHub/<owner>/<repo>,
  recording each file's blob id. Pull is a per-file three-way merge (a file
  changed on both sides keeps the local text and saves GitHub's as
  "Name (GitHub).md"); Commit and Push pulls, creates blobs, a tree on the base
  tree and a commit, then moves the branch forward without forcing. The
  sidebar shows each repository's local change count.

  Open with…: Info.plist declares Markdown (net.daringfireball.markdown,
  imported) and plain text, so Finder and Files offer the app. An opened file
  inside a sidebar folder is shown there; any other file gets its own entry
  under Files (a bookmark, like folders), with "Add Enclosing Folder…" to grant
  the folder so its images and links resolve. Saving such a file writes in
  place when the sandbox refuses the atomic write's temporary file.

  Debug simulator builds accept --add-folder <path> (repeatable) to add and
  show a Mac folder at launch without the picker. (Not on macOS: the sandbox
  grants no access to a path given on the command line.)

Distribution

  Scripts/release.sh mac        Developer ID: archive, export, notarize and
                                staple; build/release/Markdown.dmg and .zip for
                                a GitHub release (stable link:
                                releases/latest/download/Markdown.dmg)
  Scripts/release.sh appstore   macOS and iOS archives uploaded to App Store
                                Connect

  The direct build adds DIRECT_DISTRIBUTION, which turns on UpdateChecker: a
  daily check of the latest GitHub release and "Check for Updates…" (App Store
  builds leave it out). Notarization uses a notarytool keychain profile
  ("notary" by default; see the script). PrivacyInfo.xcprivacy declares no
  tracking or collection and the UserDefaults reason.

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
          (107 tests: parser, style spec, layout probes, code colors,
          tables, rendering regressions, HTML/images/anchors; the highlighter's
          own tests live in ../Code)
          xcodebuild -project Markdown.xcodeproj -scheme Markdown build
  iOS:    swift build --triple arm64-apple-ios17.0-simulator --build-tests
          xcodebuild -project Markdown.xcodeproj -scheme Markdown
            -destination 'generic/platform=iOS Simulator' build
          (app runs on the iOS simulator; UIKit tests in
          Tests/MarkdownKitTests/MdUIKitTests.swift run via Xcode)
