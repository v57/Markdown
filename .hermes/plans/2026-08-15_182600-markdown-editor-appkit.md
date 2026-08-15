# Markdown Editor (AppKit TextView, Obsidian-style live preview) — Implementation Plan

> **For Hermes:** implement this plan task-by-task; run the `--selftest` binary after each parser task before committing.

**Goal:** A macOS markdown editor/viewer in one pane: an AppKit `NSTextView` (TextKit 1 stack) that renders markdown live (headings, emphasis, lists, tasks, quotes, code, links, tables, rules) and hides the markdown "command symbols" unless the line containing the caret/selection is active — when active, the symbols are drawn in the tertiary color.

**Architecture:** SwiftUI shell (single window, standard Edit menu) hosting an `NSViewRepresentable` that wraps a programmatically built AppKit text stack: `NSTextStorage` → custom `NSLayoutManager` (the feature: it skips drawing syntax glyphs on inactive lines) → `NSTextContainer` → `NSTextView` subclass. A hand-rolled two-phase markdown parser (blocks, then inline) produces both the styled attributed string and explicit *syntax ranges* (ranges carrying a custom `.markdownSyntax` attribute, colored `tertiaryLabelColor`). Styling is derived state: re-applied from the raw text on every character edit, so undo only records characters. No persistence anywhere.

**Tech Stack:** Swift 5, AppKit + TextKit 1 (`NSLayoutManager` subclassing), SwiftUI for the shell, Xcode project (target `Markdown`, macOS 27 SDK), `xcodebuild` CLI for build/verify, a built-in `--selftest` assertion harness (CLI-verifiable TDD — the project has no XCTest target and the pbxproj is auto-synchronized, so we do not hand-edit it).

---

## Current context

- Repo: `/Users/v57/Projects/Markdown` — Xcode project, single target `Markdown` (product `Markdown.app`), Swift 5.0, `MACOSX_DEPLOYMENT_TARGET = 27.0`.
- Project uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 90): **any `.swift` file placed in `Markdown/` is automatically compiled into the target — no pbxproj edits needed.**
- `Markdown/ContentView.swift` currently holds a `@main struct MyApp` hello-world shell. It gets rewritten; `@main` moves to a new `main.swift` so `--selftest`/`--smoke` can run before `NSApplication` starts.
- 3 modified files in git (pbxproj/xcscheme/ContentView) — committed or reverted at start (Task 1).

## Key design decisions (read first)

1. **"Command symbols show when line is selected"** = Obsidian live-preview behavior: the markdown syntax characters (`#`, `**`, `>`, `-`, `` ` ``, `|`, …) are invisible when the caret/selection is NOT on their line, and visible — drawn in **tertiary color** (`NSColor.tertiaryLabelColor`) — when the line is active. Hidden symbols still occupy layout space (WYSIWYG spacing, matching Obsidian). Implemented in the custom `NSLayoutManager.drawsGlyphs(forGlyphRange:at:)` by splitting the draw call into subranges and skipping syntax glyphs outside the active line range.
2. **TextKit 1 on purpose.** The hide/show trick requires an `NSLayoutManager` subclass. Building the stack explicitly (`NSTextStorage` + custom `NSLayoutManager` + `NSTextContainer` + `init(frame:textContainer:)`) opts out of TextKit 2. Task 2 verifies `textView.textLayoutManager == nil` at runtime (assert + log) before anything else is built on it.
3. **Parser output contract.** `MarkdownParser.parse(_:style:) -> ParsedMarkdown { attributed, syntaxRanges, blocks }`. Syntax ranges = every range carrying `.markdownSyntax` (markers, delimiters, fence markers, table pipes, escaped backslashes, hidden URL parts of links). `blocks` is a plain enum list kept for assertions/debugging — the self-test asserts on it.
4. **Styling is derived.** `NSTextStorageDelegate.textStorage(_:didProcessEditing:…)` re-runs the parser when `editedMask` contains `.editedCharacters` (attribute-only edits are filtered, preventing recursion) and does `storage.setAttributedString(parsed.attributed)` — same characters, new attributes. Undo therefore undoes only characters; styles recompute. Typing attributes are reset to body style on every edit so the caret doesn't inherit bold/code.
5. **No test target.** TDD runs through a `--selftest` mode in the app binary (assertions + exit code). Rationale: adding an XCTest target means hand-editing pbxproj (risk for zero benefit here); the self-test is CLI-verifiable, which matches the project's verification style. If a real XCTest target is wanted later, add it in Xcode once and move `MarkdownCore` assertions there.
6. **Image links** (`![alt](url)`) render as inline `NSTextAttachment`s loaded asynchronously; on failure the alt text is shown. The launch sample omits images (no network dependency in the demo).

---

## Files

All under `Markdown/` (auto-included by the synchronized folder group):

| File | Role |
|---|---|
| `main.swift` | entry: `--selftest`/`--smoke` handling, then `MarkdownApp.main()` |
| `ContentView.swift` | rewritten: `MarkdownApp` (no `@main`), `WindowGroup`, Edit-menu commands |
| `EditorView.swift` | `NSViewRepresentable` wrapping the text stack in an `NSScrollView` |
| `EditorTextView.swift` | `NSTextView` subclass: config, delegates, selection→active-line, typing attrs, link clicks |
| `EditorLayoutManager.swift` | `NSLayoutManager` subclass — the hide/show feature |
| `MarkdownParser.swift` | two-phase parser → `ParsedMarkdown` |
| `MarkdownStyle.swift` | colors (tertiary syntax color), fonts, paragraph styles |
| `CheckboxAttachment.swift` | drawn checkbox `NSTextAttachment` for task lists |
| `SampleDocument.swift` | launch sample markdown |
| `SelfTest.swift` | assertion harness + `runAndExit()` |

No changes to `Markdown.xcodeproj` (synchronized groups pick up new files automatically).

Build/run commands used throughout:

```bash
# build
xcodebuild -project Markdown.xcodeproj -target Markdown -configuration Debug -derivedDataPath build build
BIN=build/Build/Products/Debug/Markdown.app/Contents/MacOS/Markdown
# self-test (exit 0 = all pass)
$BIN --selftest
# smoke launch (opens window, logs, quits after 3 s)
$BIN --smoke
```

---

## Task 1: Entry point, self-test harness skeleton, clean baseline

**Objective:** `--selftest` and `--smoke` become real CLI paths; the current hello-world builds and runs.

**Files:**
- Create: `Markdown/main.swift`, `Markdown/SelfTest.swift`
- Modify: `Markdown/ContentView.swift` (remove `@main`, rename `MyApp` → `MarkdownApp`)
- Git: commit or stash the 3 modified files first (`git status` should be clean or intentional).

**Step 1: `Markdown/main.swift`**

```swift
import AppKit

if CommandLine.arguments.contains("--selftest") {
    SelfTest.runAndExit()   // Never
}
if CommandLine.arguments.contains("--smoke") {
    SmokeTest.schedule()    // quits after 3 s, prints SMOKE OK
}
MarkdownApp.main()
```

**Step 2: `Markdown/SelfTest.swift`** — harness + first two trivial checks (empty doc, sample doc parses):

```swift
import AppKit

enum SelfTest {
    private static var passed = 0
    private static var failed = 0

    static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
            print("  PASS \(name)")
        } else {
            failed += 1
            print("  FAIL \(name) \(detail)")
        }
    }

    static func runAndExit() -> Never {
        print("SELFTEST START")
        // — parser checks are appended in later tasks here —
        check("empty doc parses", MarkdownParser.parse("", style: .standard).blocks.isEmpty)
        let sample = MarkdownParser.parse(SampleDocument.text, style: .standard)
        check("sample doc has blocks", !sample.blocks.isEmpty, "got \(sample.blocks.count)")
        print("SELFTEST \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
```

`SampleDocument` (Task 12 fills the real text; stub now with `static let text = "# Hello"`).

**Step 3: `ContentView.swift`** — rename struct, drop `@main`:

```swift
import SwiftUI

struct MarkdownApp: App {
    var body: some Scene {
        WindowGroup("Markdown") {
            EditorView()
                .frame(minWidth: 480, minHeight: 360)
        }
        .defaultSize(width: 900, height: 700)
        .commands { TextEditingCommands() }   // standard Edit menu so ⌘C/V/X/Z work
    }
}
```

(`EditorView` doesn't exist yet — Task 2; to keep this task buildable, temporarily keep `ContentView()`-style `Text("Markdown")` placeholder and swap in Task 2.)

**Step 4: Verify**

```bash
xcodebuild -project Markdown.xcodeproj -target Markdown -configuration Debug -derivedDataPath build build
build/Build/Products/Debug/Markdown.app/Contents/MacOS/Markdown --selftest
```

Expected: `SELFTEST START`, `PASS …` lines, `SELFTEST 2 passed, 0 failed`, exit code 0.

**Step 5: Commit** — `git add Markdown && git commit -m "Added markdown editor scaffold"`

---

## Task 2: TextKit 1 text stack + scroll view + window

**Objective:** the editor window shows a working plain `NSTextView` (typing, caret, undo, ⌘F find bar) built on the explicit TextKit 1 stack; TextKit 1 is confirmed at runtime.

**Files:**
- Create: `Markdown/EditorView.swift`, `Markdown/EditorTextView.swift`, `Markdown/EditorLayoutManager.swift` (empty shell for now)

**Step 1: `Markdown/EditorView.swift`** — representable + scroll view:

```swift
import SwiftUI
import AppKit

struct EditorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let textView = EditorTextView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = textView
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
    @MainActor final class Coordinator: NSObject {}
}
```

(Coordinator annotated `@MainActor` — required on current toolchains, see macos-swiftui-app-development skill.)

**Step 2: `Markdown/EditorLayoutManager.swift`** — placeholder shell:

```swift
import AppKit

final class EditorLayoutManager: NSLayoutManager {
    var activeCharacterRange: NSRange = NSRange(location: 0, length: 0)
}
```

**Step 3: `Markdown/EditorTextView.swift`** — full stack construction + configuration (the `configure()` body grows in Tasks 10–11):

```swift
import AppKit

final class EditorTextView: NSTextView, NSTextStorageDelegate, NSTextViewDelegate {
    private let markdownStorage: NSTextStorage
    private let markdownLayout: EditorLayoutManager
    private let markdownContainer: NSTextContainer

    init() {
        markdownStorage = NSTextStorage()
        markdownLayout = EditorLayoutManager()
        markdownStorage.addLayoutManager(markdownLayout)
        markdownContainer = NSTextContainer(size: NSSize(width: 0, height: .greatestFiniteMagnitude))
        markdownContainer.widthTracksTextView = true
        markdownLayout.addTextContainer(markdownContainer)
        super.init(frame: .zero, textContainer: markdownContainer)
        configure()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        isRichText = false                       // pastes/drops land as plain text
        allowsUndo = true
        isHorizontallyResizable = false
        widthTracksTextView = true
        isVerticallyResizable = true
        textContainerInset = NSSize(width: 48, height: 28)   // Obsidian-like margins
        font = MarkdownStyle.standard.bodyFont
        textColor = .labelColor
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        usesFindBar = true                       // ⌘F find bar for free
        insertionPointColor = .labelColor
        delegate = self
        markdownStorage.delegate = self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            print("EDITOR READY textKit1=\(textLayoutManager == nil)")
            window?.makeFirstResponder(self)
        }
    }
}
```

**Step 4: wire `EditorView` into `ContentView.swift`** (replace placeholder), then verify TextKit 1:

```bash
xcodebuild -project Markdown.xcodeproj -target Markdown -configuration Debug -derivedDataPath build build
build/Build/Products/Debug/Markdown.app/Contents/MacOS/Markdown --smoke
```

Expected: window appears; stdout shows `EDITOR READY textKit1=true`. `--smoke` mode (in `SmokeTest`, main.swift side): after `NSApplication` is up, `DispatchQueue.main.asyncAfter(.now()+3) { print("SMOKE OK"); NSApp.terminate(nil) }` — smoke exits 0 on its own. If `textKit1=false`, STOP and re-check the construction path (custom container init must win over TextKit 2).

**Step 5: Commit** — `git commit -m "Added AppKit editor text stack"`

---

## Task 3: MarkdownStyle + syntax attribute keys

**Objective:** single source of truth for colors/fonts/paragraph styles; syntax color = tertiary.

**Files:** Create: `Markdown/MarkdownStyle.swift`

```swift
import AppKit

extension NSAttributedString.Key {
    /// Marks markdown "command symbol" ranges (hidden on inactive lines, tertiary when active).
    static let markdownSyntax = NSAttributedString.Key("MarkdownSyntax")
}

struct MarkdownStyle {
    // Colors — all dynamic system colors → automatic dark/light support
    let textColor: NSColor = .labelColor
    let syntaxColor: NSColor = .tertiaryLabelColor   // ★ "commands in tertiary color"
    let codeBackground: NSColor = .quaternarySystemFillColor
    let codeTextColor: NSColor = .secondaryLabelColor
    let linkColor: NSColor = .linkColor
    let quoteTextColor: NSColor = .secondaryLabelColor
    let quoteBarColor: NSColor = .tertiaryLabelColor
    let ruleColor: NSColor = .separatorColor
    let checkedTextColor: NSColor = .secondaryLabelColor

    // Fonts
    let bodyFont = NSFont.systemFont(ofSize: 15)
    let codeFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    let headingSizes: [CGFloat] = [28, 24, 20, 17, 15, 13]   // h1…h6
    func headingFont(level: Int) -> NSFont {
        let size = headingSizes[max(0, min(5, level - 1))]
        let weight: NSFont.Weight = level <= 3 ? .bold : .semibold
        return .systemFont(ofSize: size, weight: weight)
    }
    func emphasisFont(base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let desc = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: base.pointSize) ?? base
    }

    // Paragraph styles
    func bodyParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        p.paragraphSpacing = 6
        return p
    }
    func headingParagraph(level: Int) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = level <= 2 ? 12 : 8
        p.paragraphSpacing = level <= 2 ? 8 : 6
        return p
    }
    func listParagraph(level: Int, markerWidth: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let indent = 24 * CGFloat(level)
        p.firstLineHeadIndent = indent
        p.headIndent = indent + markerWidth
        p.paragraphSpacing = 3
        return p
    }
    func quoteParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 24
        p.headIndent = 24
        p.paragraphSpacing = 6
        return p
    }

    // Attribute bundles
    var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: textColor, .paragraphStyle: bodyParagraph()]
    }
    func syntaxAttributes() -> [NSAttributedString.Key: Any] {
        [.foregroundColor: syntaxColor, .markdownSyntax: true]
    }
    func codeAttributes() -> [NSAttributedString.Key: Any] {
        [.font: codeFont, .foregroundColor: codeTextColor, .backgroundColor: codeBackground]
    }

    static let standard = MarkdownStyle()
}
```

**Verify:** build passes (`xcodebuild … build`). Commit: `git commit -m "Added markdown style tokens"`

---

## Task 4: Parser — block pass (headings, paragraphs, rules, blockquote)

**Objective:** `MarkdownParser.parse` returns styled text + syntax ranges + `blocks` for ATX headings, setext headings, paragraphs, horizontal rules, blockquotes.

**Files:** Create: `Markdown/MarkdownParser.swift` (grows through Tasks 4–9)

Parser skeleton + block pass (complete code; inline pass stub returns plain text):

```swift
import AppKit

struct ParsedMarkdown {
    let attributed: NSAttributedString
    let syntaxRanges: [NSRange]
    let blocks: [MarkdownParser.Block]
}

enum MarkdownParser {

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case blockquote(String)
        case rule
        case unorderedList(items: [ListItem], level: Int)
        case orderedList(items: [ListItem], level: Int)
        case taskList(items: [TaskItem])
        case codeFence(language: String, code: String)
        case table(header: [String], rows: [[String]], alignments: [Alignment])
    }
    struct ListItem: Equatable { let text: String; let level: Int }
    struct TaskItem: Equatable { let text: String; let checked: Bool; let level: Int }
    enum Alignment: Equatable { case left, center, right }

    static func parse(_ markdown: String, style: MarkdownStyle = .standard) -> ParsedMarkdown {
        let out = NSMutableAttributedString()
        var syntaxRanges: [NSRange] = []
        var blocks: [Block] = []

        let lines = (markdown as NSString).components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            // ATX heading: ^(#{1,6})\s+
            if let m = match(trimmed, pattern: "^(#{1,6})[ \\t]+(.*)$") {
                let level = m[1].count
                let text = m[2]
                let syntaxLen = raw.count - text.count   // '#' run + separating space
                append(out, &syntaxRanges, syntax: raw.prefix(syntaxLen), text: text, attrs: [
                    .font: style.headingFont(level: level),
                    .foregroundColor: style.textColor,
                    .paragraphStyle: style.headingParagraph(level: level),
                ], style: style)
                blocks.append(.heading(level: level, text: text))
                i += 1; continue
            }

            // Setext heading: next line is all = or all -
            if i + 1 < lines.count, !trimmed.isEmpty,
               let underline = match(lines[i + 1].trimmingCharacters(in: .whitespaces), pattern: "^(=+|-+)$") {
                let level = underline[1].hasPrefix("=") ? 1 : 2
                append(out, &syntaxRanges, syntax: "", text: trimmed, attrs: [
                    .font: style.headingFont(level: level),
                    .foregroundColor: style.textColor,
                    .paragraphStyle: style.headingParagraph(level: level),
                ], style: style)
                blocks.append(.heading(level: level, text: trimmed))
                i += 2; continue
            }

            // Horizontal rule: ^([-*_])\1{2,}$ (alone on line)
            if match(trimmed, pattern: "^([-*_])\\1{2,}$") != nil {
                appendRule(out, &syntaxRanges, raw: raw, style: style)
                blocks.append(.rule)
                i += 1; continue
            }

            // Blockquote: one or more '>' prefixes
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                var syntaxLenTotal = 0
                while i < lines.count {
                    let l = lines[i]
                    guard l.trimmingCharacters(in: .whitespaces).hasPrefix(">") else { break }
                    let markerLen = l.count - l.drop(while: { $0 == ">" || $0 == " " }).count  // > plus following space
                    syntaxLenTotal += markerLen
                    quoteLines.append(String(l.dropFirst(markerLen)))
                    i += 1
                }
                let text = quoteLines.joined(separator: "\n")
                append(out, &syntaxRanges, syntax: String(repeating: "> ", count: quoteLines.count),
                       text: text, attrs: [
                        .font: style.bodyFont, .foregroundColor: style.quoteTextColor,
                        .paragraphStyle: style.quoteParagraph(),
                       ], style: style)
                blocks.append(.blockquote(text))
                continue
            }

            // Paragraph: collect until blank line or a line starting a new block
            var paraLines = [trimmed]
            i += 1
            while i < lines.count {
                let l = lines[i].trimmingCharacters(in: .whitespaces)
                if l.isEmpty { i += 1; break }
                if startsNewBlock(l) { break }
                paraLines.append(l)
                i += 1
            }
            let text = paraLines.joined(separator: " ")
            append(out, &syntaxRanges, syntax: "", text: text, attrs: [
                .font: style.bodyFont, .foregroundColor: style.textColor,
                .paragraphStyle: style.bodyParagraph(),
            ], style: style)
            blocks.append(.paragraph(text))
        }

        return ParsedMarkdown(attributed: out, syntaxRanges: syntaxRanges, blocks: blocks)
    }

    // MARK: - helpers

    /// Appends `text` with `attrs`, then marks `syntax` (the command-symbol substring,
    /// emitted *before* text) as syntax-colored. Runs the inline pass over `text`.
    private static func append(_ out: NSMutableAttributedString, _ syntaxRanges: inout [NSRange],
                               syntax: String, text: String, attrs: [NSAttributedString.Key: Any], style: MarkdownStyle) {
        if !syntax.isEmpty {
            let s = NSAttributedString(string: syntax, attributes: style.syntaxAttributes())
            let r = NSRange(location: out.length, length: s.length)
            out.append(s)
            syntaxRanges.append(r)
        }
        let styled = inline(text, style: style, base: attrs)
        out.append(styled.attributed)
        syntaxRanges.append(contentsOf: styled.syntax.map { shifted($0, by: out.length - styled.attributed.length) })
    }

    private static func shifted(_ r: NSRange, by delta: Int) -> NSRange {
        NSRange(location: r.location + delta, length: r.length)
    }

    private static func startsNewBlock(_ line: String) -> Bool {
        line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("```") || line.hasPrefix("~~~")
            || match(line, pattern: "^([-*_])\\1{2,}$") != nil
            || match(line, pattern: "^(\\s*)[-*+]\\s+") != nil
            || match(line, pattern: "^(\\s*)\\d+[.)]\\s+") != nil
            || line.contains("|")
    }

    static func match(_ s: String, pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    private static func appendRule(_ out: NSMutableAttributedString, _ syntaxRanges: inout [NSRange],
                                   raw: String, style: MarkdownStyle) {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 10
        let a = NSMutableAttributedString(string: raw, attributes: [.paragraphStyle: p])
        // Draw the rule as a thin box fill via the layout manager (see Task 11 note),
        // or simplest: a full-width underscore in ruleColor. Use the box approach:
        a.addAttribute(.markdownSyntax, value: true, range: NSRange(location: 0, length: raw.count))
        a.addAttribute(.foregroundColor, value: style.ruleColor, range: NSRange(location: 0, length: raw.count))
        let r = NSRange(location: out.length, length: a.length)
        out.append(a)
        syntaxRanges.append(r)
    }

    /// Inline pass — Task 5. For now: plain text.
    static func inline(_ text: String, style: MarkdownStyle, base: [NSAttributedString.Key: Any])
        -> (attributed: NSAttributedString, syntax: [NSRange]) {
        (NSAttributedString(string: text, attributes: base), [])
    }
}
```

Notes: the blockquote marker accounting (`syntaxLenTotal` var is informational for now — the `String(repeating:)` marker is the emitted one); syntax emission uses the *raw* marker text so the characters match what the user typed.

**Step: Self-test checks** (append in `SelfTest.runAndExit()`):

```swift
// Task 4 checks
check("atx heading level", MarkdownParser.parse("## Hi").blocks == [.heading(level: 2, text: "Hi")])
let h = MarkdownParser.parse("# Hi").attributed
check("heading syntax range marked", h.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil)
check("heading font is big", (h.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.pointSize == 28)
check("setext h1", MarkdownParser.parse("Title\n===").blocks == [.heading(level: 1, text: "Title")])
check("setext h2", MarkdownParser.parse("Title\n---").blocks == [.heading(level: 2, text: "Title")])
check("hr block", MarkdownParser.parse("---").blocks == [.rule])
check("hr syntax", MarkdownParser.parse("***").syntaxRanges.first?.length == 3)
check("blockquote", MarkdownParser.parse("> quote").blocks == [.blockquote("quote")])
check("blockquote marker syntax", MarkdownParser.parse("> quote").syntaxRanges.count == 1)
check("paragraph", MarkdownParser.parse("a\nb").blocks == [.paragraph("a b")])
```

**Verify:** build → `--selftest` → all new checks PASS (write them first, watch the heading/paragraph ones fail, then implement, then pass — TDD). Commit: `git commit -m "Added markdown block parsing"`

---

## Task 5: Parser — inline pass (emphasis, strikethrough, code spans, escapes)

**Objective:** `inline(_:style:base:)` styles `**bold**`, `*italic*`, `***both***`, `__…__`, `_…_` (word-boundary guarded), `~~strike~~`, `` `code` `` (and n-backtick runs), `\escapes`. Delimiters become syntax ranges; content gets combined font traits.

**Step 1 (failing tests first)** — checks:

```swift
let b = MarkdownParser.parse("**x**").attributed
check("bold font", (b.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
check("bold delimiters syntax", b.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil
    && b.attribute(.markdownSyntax, at: 4, effectiveRange: nil) != nil)
let i = MarkdownParser.parse("*x*").attributed
check("italic font", (i.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
let s = MarkdownParser.parse("~~x~~").attributed
check("strike attr", s.attribute(.strikethroughStyle, at: 2, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
let c = MarkdownParser.parse("`x`").attributed
check("code font", (c.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)?.fontName.contains("Mono") == true)
check("code bg", c.attribute(.backgroundColor, at: 1, effectiveRange: nil) != nil)
check("code markers syntax", c.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil)
let e = MarkdownParser.parse(r"\*x\*").attributed
check("escape literal", (e.string as NSString).substring(with: NSRange(location: 0, length: 3)) == "*x*")
```

**Step 2: implementation** — replace the `inline` stub with a single left-to-right scanner (complete code):

```swift
static func inline(_ text: String, style: MarkdownStyle, base: [NSAttributedString.Key: Any])
    -> (attributed: NSAttributedString, syntax: [NSRange]) {
    let ns = text as NSString
    let out = NSMutableAttributedString()
    var syntax: [NSRange] = []

    func syntaxAttrs() -> [NSAttributedString.Key: Any] { style.syntaxAttributes() }
    func appendSyntax(_ s: String) {
        let r = NSRange(location: out.length, length: (s as NSString).length)
        out.append(NSAttributedString(string: s, attributes: syntaxAttrs()))
        syntax.append(r)
    }
    func appendPlain(_ s: String) {
        out.append(NSAttributedString(string: s, attributes: base))
    }

    var i = 0
    let len = ns.length
    while i < len {
        let c = ns.character(at: i)

        // Escape: \X → '\' (syntax) + literal X
        if c == 0x5C, i + 1 < len, isPunctuation(ns.character(at: i + 1)) {
            appendSyntax("\\")
            appendPlain(String(UnicodeScalar(ns.character(at: i + 1))!))
            i += 2; continue
        }

        // Code span: backtick run of length n, closed by same-length run
        if c == 0x60 {
            var run = 1
            while i + run < len && ns.character(at: i + run) == 0x60 { run += 1 }
            if let close = findRun(ns, char: 0x60, len: run, from: i + run) {
                var codeRange = NSRange(location: i + run, length: close - (i + run))
                // CommonMark: if code starts AND ends with a space, drop one on each side
                if codeRange.length >= 2,
                   ns.character(at: codeRange.location) == 0x20,
                   ns.character(at: NSMaxRange(codeRange) - 1) == 0x20 {
                    codeRange = NSRange(location: codeRange.location + 1, length: codeRange.length - 2)
                }
                appendSyntax(String(repeating: "`", count: run))
                out.append(NSAttributedString(string: ns.substring(with: codeRange), attributes: style.codeAttributes()))
                appendSyntax(String(repeating: "`", count: run))
                i = close + run; continue
            }
            appendPlain(String(repeating: "`", count: run))
            i += run; continue
        }

        // Link / image: [text](url) or ![alt](url) — Task 7 handles; skip `[` here
        if c == 0x5B { // [
            if let (textRange, urlRange, isImage) = tryLink(ns, at: i) {
                _ = isImage // Task 7
                // For now: plain fallthrough so tests stay green; Task 7 replaces this branch.
            }
        }

        // Emphasis delimiters: * _ (runs), and ~~ (strikethrough)
        if c == 0x7E { // ~
            if ns.character(at: i + 1) == 0x7E,
               let close = findRun(ns, char: 0x7E, len: 2, from: i + 2) {
                appendSyntax("~~")
                let inner = ns.substring(with: NSRange(location: i + 2, length: close - (i + 2)))
                let styled = NSMutableAttributedString(string: inner, attributes: base)
                styled.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                    range: NSRange(location: 0, length: styled.length))
                styled.addAttribute(.strikethroughColor, value: style.textColor,
                                    range: NSRange(location: 0, length: styled.length))
                out.append(styled)
                appendSyntax("~~")
                i = close + 2; continue
            }
            appendPlain("~"); i += 1; continue
        }

        if c == 0x2A || c == 0x5F { // * or _
            var run = 1
            while i + run < len && ns.character(at: i + run) == c { run += 1 }
            // Find a matching closer of the same char (>=1 run) and resolve
            if let close = findEmphasisClose(ns, char: c, from: i + run) {
                let bold = run >= 2 || closeRunLen(ns, close, char: c) >= 2
                let italic = run == 1 || closeRunLen(ns, close, char: c) == 1
                appendSyntax(ns.substring(with: NSRange(location: i, length: run)))
                let inner = ns.substring(with: NSRange(location: i + run, length: close - (i + run)))
                out.append(NSAttributedString(string: inner, attributes: [
                    .font: style.emphasisFont(base: base[.font] as? NSFont ?? style.bodyFont, bold: bold, italic: italic),
                    .foregroundColor: base[.foregroundColor] as? NSColor ?? style.textColor,
                ]))
                appendSyntax(ns.substring(with: NSRange(location: close, length: closeRunLen(ns, close, char: c))))
                i = close + closeRunLen(ns, close, char: c); continue
            }
            appendPlain(ns.substring(with: NSRange(location: i, length: run)))
            i += run; continue
        }

        appendPlain(String(UnicodeScalar(c)!))
        i += 1
    }
    return (out, syntax)
}

private static func isPunctuation(_ c: unichar) -> Bool {
    "\\`*_{}[]()#+-.!>~|".unicodeScalars.contains(UnicodeScalar(c)!)
}
private static func findRun(_ ns: NSString, char: unichar, len: Int, from start: Int) -> Int? {
    var j = start
    while j < ns.length {
        if ns.character(at: j) == char {
            var k = 0
            while j + k < ns.length && ns.character(at: j + k) == char { k += 1 }
            if k == len { return j }
            j += k
        } else { j += 1 }
    }
    return nil
}
private static func closeRunLen(_ ns: NSString, _ pos: Int, char: unichar) -> Int {
    var k = 0
    while pos + k < ns.length && ns.character(at: pos + k) == char { k += 1 }
    return k
}
private static func findEmphasisClose(_ ns: NSString, char: unichar, from start: Int) -> Int? {
    var j = start
    while j < ns.length {
        if ns.character(at: j) == char {
            // intraword rule for '_': must not sit between two alphanumerics
            if char == 0x5F, j > 0, j + 1 < ns.length,
               isAlnum(ns.character(at: j - 1)), isAlnum(ns.character(at: j + 1)) {
                j += 1; continue
            }
            return j
        }
        j += 1
    }
    return nil
}
private static func isAlnum(_ c: unichar) -> Bool {
    CharacterSet.alphanumerics.contains(UnicodeScalar(c)!)
}
```

Rules implemented (documented subset of CommonMark; deviations acceptable and listed):
- `*`/`_` runs of 1 → italic, 2+ → bold; a run of 3 on either side → bold+italic (via the `run>=2`/`run==1` per-side test).
- `_` does not open/close intraword; `*` does.
- No nested emphasis stacking (e.g. `**a *b* c**` renders the inner `*` as literal) — documented limitation; matches "pragmatic subset".
- Backtick runs must close with an equal-length run; code content may contain other markdown literally.

**Step 3:** build → selftest → all Task 5 checks pass. **Commit:** `git commit -m "Added inline markdown styling"`

---

## Task 6: Parser — lists (ul/ol/nested) and task lists with checkboxes

**Objective:** `- /*+` bullets, `1.`/`1)` ordered, nesting by leading whitespace, `- [ ]` / `- [x]` tasks with a drawn checkbox attachment; markers are syntax ranges; content hangs at `headIndent`.

**Step 1 (failing tests):**

```swift
let ul = MarkdownParser.parse("- a\n- b")
check("ul blocks", ul.blocks == [.unorderedList(items: [.init(text: "a", level: 0), .init(text: "b", level: 0)], level: 0)])
check("ul marker syntax", ul.syntaxRanges.count == 2)
let nested = MarkdownParser.parse("- a\n  - b")
check("nested list levels", nested.blocks.first.map { if case .unorderedList(let items, _) = $0 { return items[1].level } else { return -1 } } == 1)
let ol = MarkdownParser.parse("1. a\n2. b")
check("ol blocks", ol.blocks == [.orderedList(items: [.init(text: "a", level: 0), .init(text: "b", level: 0)], level: 0)])
let task = MarkdownParser.parse("- [x] done\n- [ ] todo")
check("task blocks", task.blocks == [.taskList(items: [.init(text: "done", checked: true, level: 0), .init(text: "todo", checked: false, level: 0)])])
check("task checkbox attachment", task.attributed.attribute(.attachment, at: 3, effectiveRange: nil) != nil)
```

**Step 2: `CheckboxAttachment.swift`** (complete):

```swift
import AppKit

final class CheckboxAttachment: NSTextAttachment {
    let checked: Bool

    init(checked: Bool, size: CGFloat = 13) {
        self.checked = checked
        super.init(data: nil, ofType: nil)
        let s = NSSize(width: size, height: size)
        let image = NSImage(size: s, flipped: false) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            if self.checked {
                NSColor.controlAccentColor.setFill()
                box.fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: rect.minX + 3, y: rect.midY))
                check.line(to: NSPoint(x: rect.midX - 0.5, y: rect.minY + 3))
                check.line(to: NSPoint(x: rect.maxX - 2.5, y: rect.maxY - 3))
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                box.lineWidth = 1.2
                box.stroke()
            }
            return true
        }
        self.image = image
        self.bounds = NSRect(x: 0, y: -2.5, size: s)   // optical alignment with body text
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
```

**Step 3: list parsing** — add to the block loop, before the paragraph fallback (after blockquote):

```swift
// Task lists: ^(\s*)[-*+]\s+\[([ xX])\]\s+
if let m = match(trimmed, pattern: "^([ \\t]*)[-*+][ \\t]+\\[([ xX])\\][ \\t]+(.*)$") {
    var items: [TaskItem] = []
    var markerPrefixes: [String] = []
    let level = m[1].count / 2
    while i < lines.count {
        guard let mm = match(lines[i], pattern: "^([ \\t]*)[-*+][ \\t]+\\[([ xX])\\][ \\t]+(.*)$") else { break }
        let lvl = mm[1].count / 2
        items.append(TaskItem(text: mm[3], checked: mm[2] != " ", level: lvl))
        markerPrefixes.append(lines[i].prefix(mm[1].count + 2) + " ")   // indent + '- ' (checkbox follows)
        i += 1
    }
    for (item, prefix) in zip(items, markerPrefixes) {
        let p = style.listParagraph(level: item.level, markerWidth: 18)
        append(out, &syntaxRanges, syntax: prefix, text: "", attrs: [.paragraphStyle: p], style: style)
        out.append(NSAttributedString(attachment: CheckboxAttachment(checked: item.checked)))
        if item.checked {
            let rest = NSAttributedString(string: " " + item.text, attributes: [
                .font: style.bodyFont, .foregroundColor: style.checkedTextColor, .paragraphStyle: p])
            out.append(rest)
        } else {
            append(out, &syntaxRanges, syntax: "", text: " " + item.text,
                   attrs: [.font: style.bodyFont, .foregroundColor: style.textColor, .paragraphStyle: p], style: style)
        }
        blocks.append(.taskList(items: items))
    }
    continue
}

// Unordered / ordered lists: ^(\s*)([-*+]|\d+[.)])\s+
if let m = match(trimmed, pattern: "^([ \\t]*)([-*+]|\\d+[.)])[ \\t]+(.*)$") {
    let isOrdered = m[2].first?.isNumber == true
    var items: [ListItem] = []
    var markers: [String] = []
    while i < lines.count {
        guard let mm = match(lines[i], pattern: "^([ \\t]*)([-*+]|\\d+[.)])[ \\t]+(.*)$") else { break }
        items.append(ListItem(text: mm[3], level: mm[1].count / 2))
        markers.append(mm[1] + mm[2] + " ")
        i += 1
    }
    for (item, marker) in zip(items, markers) {
        let width: CGFloat = isOrdered ? 28 : 18
        append(out, &syntaxRanges, syntax: marker, text: item.text, attrs: [
            .font: style.bodyFont, .foregroundColor: style.textColor,
            .paragraphStyle: style.listParagraph(level: item.level, markerWidth: width),
        ], style: style)
    }
    blocks.append(isOrdered
        ? .orderedList(items: items, level: items.first?.level ?? 0)
        : .unorderedList(items: items, level: items.first?.level ?? 0))
    continue
}
```

Checkbox alignment caveat: `bounds.y = -2.5` is a starting value — adjust after the user's first visual pass. Nested list indent = 24pt per level via `listParagraph`.

**Step 4:** build → selftest → pass. **Commit:** `git commit -m "Added markdown list rendering"`

---

## Task 7: Parser — links and images

**Objective:** `[text](url)` → text in link color + underline + `.link` attribute (clickable); `[`/`]`/`(url)` are syntax. `![alt](url)` → inline image attachment (async load, alt-text fallback).

**Step 1 (failing tests):**

```swift
let l = MarkdownParser.parse("[x](https://a.b)")
check("link color", l.attributed.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor == .linkColor)
check("link url attr", (l.attributed.attribute(.link, at: 1, effectiveRange: nil) as? URL)?.absoluteString == "https://a.b")
check("link delimiters syntax", l.attributed.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil
    && l.attributed.attribute(.markdownSyntax, at: 6, effectiveRange: nil) != nil)
```

**Step 2: `tryLink`** (used from the `[` branch in `inline`):

```swift
/// At a '[' position, returns (textRange, urlRange, isImage) for [t](u) / ![t](u), or nil.
private static func tryLink(_ ns: NSString, at i: Int) -> (NSRange, NSRange, Bool)? {
    let isImage = i > 0 && ns.character(at: i - 1) == 0x21 // '!'
    let textStart = i + (isImage ? 1 : 0)
    var j = textStart
    while j < ns.length && ns.character(at: j) != 0x5D {   // ]
        if ns.character(at: j) == 0x0A { return nil }
        j += 1
    }
    guard j < ns.length, j + 1 < ns.length, ns.character(at: j + 1) == 0x28 else { return nil } // (
    var k = j + 2
    while k < ns.length && ns.character(at: k) != 0x29 {    // )
        if ns.character(at: k) == 0x0A { return nil }
        k += 1
    }
    guard k < ns.length else { return nil }
    return (NSRange(location: textStart, length: j - textStart),
            NSRange(location: j + 2, length: k - (j + 2)), isImage)
}
```

**Step 3: wire into `inline`** — replace the `[` placeholder branch:

```swift
if c == 0x5B { // [
    if let (textRange, urlRange, isImage) = tryLink(ns, at: i) {
        let urlString = ns.substring(with: urlRange)
        if isImage {
            appendSyntax("![")
            out.append(NSAttributedString(string: ns.substring(with: textRange), attributes: style.codeAttributes())) // alt text, dim
            appendSyntax("](" + urlString + ")")
            if let url = URL(string: urlString) {
                let att = InlineImageAttachment(url: url, alt: ns.substring(with: textRange))
                out.append(NSAttributedString(attachment: att))
            }
        } else {
            appendSyntax("[")
            let styledText = NSMutableAttributedString(string: ns.substring(with: textRange), attributes: base)
            styledText.addAttribute(.foregroundColor, value: style.linkColor, range: NSRange(location: 0, length: styledText.length))
            styledText.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: styledText.length))
            if let url = URL(string: urlString) {
                styledText.addAttribute(.link, value: url, range: NSRange(location: 0, length: styledText.length))
            }
            out.append(styledText)
            appendSyntax("](" + urlString + ")")
        }
        i = NSMaxRange(urlRange) + 2 // past ')'
        continue
    }
    appendPlain("["); i += 1; continue
}
```

**Step 4: `InlineImageAttachment.swift`** — async image, max width ~ 420 pt, alt-text fallback (render alt in code style):

```swift
import AppKit

final class InlineImageAttachment: NSTextAttachment {
    init(url: URL, alt: String) {
        super.init(data: nil, ofType: nil)
        let placeholder = NSImage(size: NSSize(width: 200, height: 40), flipped: false) { rect in
            NSColor.quaternarySystemFillColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            (alt as NSString).draw(in: rect.insetBy(dx: 6, dy: 10), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
            return true
        }
        self.image = placeholder
        self.bounds = NSRect(x: 0, y: -20, size: placeholder.size)
        loadAsync(url: url, alt: alt)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func loadAsync(url: URL, alt: String) {
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let img = NSImage(data: data) else { return }
            let maxW: CGFloat = 420
            let scale = min(1, maxW / img.size.width)
            let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
            DispatchQueue.main.async {
                self.image = img
                self.bounds = NSRect(x: 0, y: -size.height, size: size)
                NotificationCenter.default.post(name: .imageAttachmentLoaded, object: self)
            }
        }
        task.resume()
    }
}
extension Notification.Name { static let imageAttachmentLoaded = Notification.Name("imageAttachmentLoaded") }
```

(EditorTextView observes `.imageAttachmentLoaded` in Task 11 and calls `layoutManager.invalidateLayout(forCharacterRange:)` + `needsDisplay`.)

**Step 5:** link clicks → `EditorTextView` delegate (add in Task 10):

```swift
func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    if let url = link as? URL { NSWorkspace.shared.open(url) }
    return true
}
```

**Verify + commit:** `git commit -m "Added markdown link and image support"`

---

## Task 8: Parser — fenced code blocks

**Objective:** ```` ```lang ```` / `~~~lang` fences → block in code font with background fill; fence lines are syntax ranges; content not inline-parsed.

**Step 1 (failing test):**

```swift
let f = MarkdownParser.parse("```swift\nlet x = 1\n```")
check("fence block", f.blocks == [.codeFence(language: "swift", code: "let x = 1")])
check("fence markers syntax", f.syntaxRanges.count == 2)
check("fence code bg", f.attributed.attribute(.backgroundColor, at: 11, effectiveRange: nil) != nil)
```

**Step 2: block loop branch** (before the paragraph fallback):

```swift
// Fenced code block
if let m = match(trimmed, pattern: "^(`{3,}|~{3,})(.*)$") {
    let fence = m[1]
    let lang = m[2].trimmingCharacters(in: .whitespaces)
    var codeLines: [String] = []
    i += 1
    var closed = false
    while i < lines.count {
        let l = lines[i]
        if l.trimmingCharacters(in: .whitespaces).hasPrefix(fence.prefix(3)) { closed = true; i += 1; break }
        codeLines.append(l)
        i += 1
    }
    append(out, &syntaxRanges, syntax: fence + (lang.isEmpty ? "" : " " + lang) + "\n",
           text: codeLines.joined(separator: "\n"), attrs: [
            .font: style.codeFont, .foregroundColor: style.codeTextColor,
            .backgroundColor: style.codeBackground,
            .paragraphStyle: style.bodyParagraph(),
           ], style: style)
    if closed { append(out, &syntaxRanges, syntax: fence, text: "", attrs: [:], style: style) }
    blocks.append(.codeFence(language: lang, code: codeLines.joined(separator: "\n")))
    continue
}
```

(Fence lines themselves keep the code font but syntax color; add `.markdownSyntax` via the syntax emission. Unclosed fence → rest of doc is code.)

**Verify + commit:** `git commit -m "Added fenced code block rendering"`

---

## Task 9: Parser — tables (NSTextTable) with fallback

**Objective:** GFM tables `| a | b |` + separator row (`|---|:--:|`) render as a real table via TextKit `NSTextTable`; pipes and the separator row are syntax ranges. Alignment honored.

**Step 1 (failing test):**

```swift
let t = MarkdownParser.parse("| a | b |\n|---|---|\n| 1 | 2 |")
check("table block", t.blocks == [.table(header: ["a", "b"], rows: [["1", "2"]], alignments: [.left, .left])])
check("table syntax pipes", t.syntaxRanges.count >= 4)
```

**Step 2: block loop branch:**

```swift
// Table: current line has '|', next line is a separator row (dashes + optional colons)
if trimmed.contains("|"), i + 1 < lines.count,
   let sep = match(lines[i + 1], pattern: "^\\s*\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)*\\|?\\s*$"),
   lines[i + 1].contains("-") {
    let headerCells = splitCells(trimmed)
    let alignments = splitCells(lines[i + 1]).map { cell -> Alignment in
        let c = cell.trimmingCharacters(in: .whitespaces)
        return c.hasPrefix(":") && c.hasSuffix(":") ? .center : c.hasSuffix(":") ? .right : .left
    }
    var rows: [[String]] = []
    i += 2
    while i < lines.count {
        let l = lines[i].trimmingCharacters(in: .whitespaces)
        guard l.contains("|"), !l.isEmpty else { break }
        rows.append(splitCells(l))
        i += 1
    }
    appendTable(out, &syntaxRanges, header: headerCells, rows: rows, alignments: alignments, style: style)
    blocks.append(.table(header: headerCells, rows: rows, alignments: alignments))
    continue
}

private static func splitCells(_ line: String) -> [String] {
    let t = line.trimmingCharacters(in: .whitespaces)
    let inner = t.hasPrefix("|") ? String(t.dropFirst()) : t
    let trimmedEnd = inner.hasSuffix("|") ? String(inner.dropLast()) : inner
    return trimmedEnd.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
}
```

**Step 3: `appendTable`** — NSTextTable (complete, with the documented fallback):

```swift
private static func appendTable(_ out: NSMutableAttributedString, _ syntaxRanges: inout [NSRange],
                                header: [String], rows: [[String]], alignments: [Alignment], style: MarkdownStyle) {
    let table = NSTextTable()
    table.numberOfColumns = header.count
    table.layoutAlgorithm = .fixed
    table.hidesBorder = false

    func cellAttrs(_ text: String, align: Alignment) -> [NSAttributedString.Key: Any] {
        let block = NSTextBlock()
        block.setWidth(1.0, type: .absoluteValueType, for: .contentWidth)
        block.setBorderColor(style.ruleColor, width: 0.5, for: .allEdges)
        block.setBackgroundColor(style.codeBackground)
        let p = NSMutableParagraphStyle()
        p.textBlocks = [block]
        switch align {
        case .center: p.alignment = .center
        case .right: p.alignment = .right
        case .left: p.alignment = .left
        }
        return [.font: style.codeFont, .foregroundColor: style.textColor, .paragraphStyle: p]
    }

    func emitRow(_ cells: [String], syntax: Bool) {
        for (idx, cell) in cells.enumerated() {
            let attrs = cellAttrs(cell, align: alignments[min(idx, alignments.count - 1)])
            let cellStr = NSMutableAttributedString(string: cell, attributes: attrs)
            if syntax { cellStr.addAttribute(.markdownSyntax, value: true, range: NSRange(location: 0, length: cellStr.length)) }
            out.append(cellStr)
            if idx < cells.count - 1 { out.append(NSAttributedString(string: "|", attributes: style.syntaxAttributes())) }
            out.append(NSAttributedString(string: "\n"))
        }
    }
    emitRow(header, syntax: false)
    // separator row: entire row is syntax
    emitRow(alignments.map { $0 == .left ? "---" : $0 == .center ? ":---:" : "---:" }, syntax: true)
    for row in rows { emitRow(row, syntax: false) }
}
```

Notes & risk: `NSTextTable` cell borders/row layout are the fiddliest part of TextKit 1 and have known quirks on recent macOS (cell heights, caret drawing). **Fallback if the user's visual pass shows broken tables:** emit the table as a code block (monospace, `|`-aligned) — parser block model stays the same; only `appendTable` changes. The self-test asserts the `Block` model, which is unchanged by the fallback.

**Verify + commit:** `git commit -m "Added markdown table rendering"`

---

## Task 10: Live re-styling on edit

**Objective:** every character edit re-parses and re-applies attributes; typing attributes stay body-style; undo only undoes characters; link clicks open URLs.

**Files:** Modify: `Markdown/EditorTextView.swift`

```swift
// In configure(): already set markdownStorage.delegate = self

func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                 range editedRange: NSRange, changeInLength delta: Int) {
    guard editedMask.contains(.editedCharacters) else { return }   // ignore attribute-only edits (no recursion)
    reapplyMarkdown()
}

private func reapplyMarkdown() {
    let parsed = MarkdownParser.parse(string, style: .standard)
    markdownStorage.beginEditing()
    markdownStorage.setAttributedString(parsed.attributed)   // same characters, new attributes
    markdownStorage.endEditing()
    typingAttributes = MarkdownStyle.standard.typingAttributes
    // refresh active-line hiding state after content changed
    if let lm = layoutManager as? EditorLayoutManager {
        lm.activeCharacterRange = currentActiveLineRange()
        lm.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: string.count))
    }
}

func textDidChange(_ notification: Notification) {
    typingAttributes = MarkdownStyle.standard.typingAttributes
}

func textViewDidChangeSelection(_ notification: Notification) {
    guard let lm = layoutManager as? EditorLayoutManager else { return }
    let newRange = currentActiveLineRange()
    let union = NSUnionRange(lm.activeCharacterRange, newRange)
    lm.activeCharacterRange = newRange
    lm.invalidateDisplay(forCharacterRange: union)
}

private func currentActiveLineRange() -> NSRange {
    let sel = selectedRange()
    let ns = string as NSString
    let loc = max(0, min(sel.location, ns.length))
    return ns.lineRange(for: NSRange(location: loc, length: 0))
}
```

Details:
- `setAttributedString` inside `didProcessEditing` is the standard derived-styling pattern; the `.editedCharacters` guard prevents the attribute-only pass from re-triggering.
- Selection is preserved because the character contents are identical.
- Undo behavior: only character edits are recorded by the undo manager; styles recompute on undo — correct for a derived-style editor.
- Link clicks: add the `clickedOnLink` delegate method (from Task 7) now.

**Verify:** build; launch `--smoke`; type into the window manually (user visual pass); check undo re-styles correctly. **Commit:** `git commit -m "Added live markdown re-styling"`

---

## Task 11: THE FEATURE — hide command symbols on inactive lines (EditorLayoutManager)

**Objective:** syntax glyphs outside the active line are not drawn; when the line is selected/caret is on it, they appear in tertiary color. This is the whole point of the custom layout manager.

**Files:** Modify: `Markdown/EditorLayoutManager.swift` (replace placeholder)

```swift
import AppKit

final class EditorLayoutManager: NSLayoutManager {
    /// Union of lines containing the current selection/caret. Syntax glyphs outside
    /// this range are skipped during drawing (Obsidian-style live preview).
    var activeCharacterRange: NSRange = NSRange(location: 0, length: 0)

    override func drawsGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else {
            super.drawsGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var drawRanges: [NSRange] = []
        var i = charRange.location
        let end = NSMaxRange(charRange)
        while i < end {
            var effective = NSRange(location: i, length: 0)
            let isSyntax = storage.attribute(.markdownSyntax, at: i, effectiveRange: &effective) != nil
            if effective.length == 0 { effective = NSRange(location: i, length: 1) }
            let clamped = NSIntersectionRange(effective, charRange)
            if clamped.length > 0 {
                let active = NSIntersectionRange(clamped, activeCharacterRange).length > 0
                if !isSyntax || active {
                    drawRanges.append(clamped)
                }
            }
            i = NSMaxRange(clamped)
            if i <= clamped.location { i += 1 }   // safety against zero-progress
        }
        for r in drawRanges {
            let glyphRange = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            if glyphRange.length > 0 {
                super.drawsGlyphs(forGlyphRange: glyphRange, at: origin)
            }
        }
    }
}
```

Why this works:
- `drawsGlyphs(forGlyphRange:at:)` is called per visible region; splitting into subranges and calling `super` per subrange draws everything except hidden syntax glyphs.
- Hidden glyphs keep their layout width (WYSIWYG spacing) — same as Obsidian.
- Selection highlight is drawn by `fillBackgroundRectArray` over the FULL glyph range, so selecting across hidden symbols still highlights them — correct behavior.
- The active range is maintained by `textViewDidChangeSelection` (Task 10); `invalidateDisplay` on the union of old+new lines repaints only the affected lines.
- Cost: one attribute walk over visible text per draw — negligible for typical documents; if profiling ever flags it, precompute hidden ranges on edit.

Known cosmetic limitation (documented): splitting glyph ranges can break kerning/ligatures at the seam of a hidden run (e.g. `fi` in `*fi*`). Acceptable; matches the tradeoff Obsidian's TextKit-1-based predecessors made.

Also in this task:
- Observe `.imageAttachmentLoaded` (Task 7) → `layoutManager.invalidateLayout(forCharacterRange:)` + `needsDisplay = true` on the view.
- Log line for verification: in `viewDidMoveToWindow`, after first styling, print `SYNTAX RANGES n=<count>` (from the parser result) — evidence for CLI verification.

**Verify:**
1. Build, run `--smoke` (log shows `SYNTAX RANGES n=…`, exit 0).
2. User visual pass (required): caret on a heading line → `#` visible in tertiary; caret on another line → `#` gone; bold text shows `**` only on its line; task checkbox still renders. Table row pipes appear only on the active row.
3. If the layout manager's split-draw produces artifacts on any construct (misaligned bullets, missing underline), fix by widening the seam handling (draw a 1-char overlap and rely on the syntax color being invisible-when-inactive… no — instead, include neighboring visible chars in both subranges and let overdraw be idempotent).

**Commit:** `git commit -m "Added live-preview syntax hiding"`

---

## Task 12: Sample document, smoke mode, polish, final verification

**Objective:** launch shows a representative markdown document exercising every feature; final full verification pass.

**Step 1: `Markdown/SampleDocument.swift`** — loaded in `EditorTextView` init (`string = SampleDocument.text`):

```swift
import Foundation

enum SampleDocument {
    static let text = """
    # Markdown Editor

    A **live-preview** markdown editor built on *AppKit* `NSTextView`. The markdown
    symbols only appear on the line you're editing — in the ~~tertiary~~ **tertiary color**,
    just like Obsidian. Here's a [link to Apple](https://www.apple.com).

    ## Features

    - Headings, **bold**, *italic*, ***both***, ~~strikethrough~~, and `inline code`
    - Bullet and numbered lists, nested lists, and task lists
    - Blockquotes, fenced code blocks, tables, and horizontal rules

    ### Task list

    - [x] Renders checkboxes inline
    - [ ] Hides syntax symbols on inactive lines
    - [ ] Looks good in dark mode

    > This is a blockquote. The `>` marker hides when you edit another line.

    ```swift
    let greeting = "Hello from the code block"
    print(greeting)   // no syntax highlighting needed
    ```

    | Feature | Status |
    |---------|--------|
    | Headings | ✅ |
    | Tables | ✅ |

    ---

    1. Numbered items work too
    2. With nesting:
       1. like this

    Try `Option+click`… actually just click the link above. Edit any line to see its
    symbols appear. Escape example: \\*not italic\\*.
    """
}
```

(Load in `init()` before `configure()`: `markdownStorage.setAttributedString(NSAttributedString(string: SampleDocument.text))` — the storage delegate re-styles it automatically. Note: table checkmark `✅` is an emoji — fine in TextKit; if it renders as tofu on some systems, swap for "yes".)

**Step 2: smoke mode** (`SmokeTest` referenced in main.swift — put in `SelfTest.swift` or its own file):

```swift
enum SmokeTest {
    static func schedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print("SMOKE OK")
            NSApp.terminate(nil)
        }
    }
}
```

**Step 3: polish (small, each verified by build):**
- Window title "Markdown" (already via `WindowGroup("Markdown")`).
- Font size adjust: add `CommandGroup(after: .textEditing)` with "Increase/Decrease Text Size" (`⌘+`/`⌘-`) calling `textView.changeFont`-style scale on `MarkdownStyle` (single `bodyFontSize` var, re-parse). Optional — skip if time-boxed.
- `.commands { TextEditingCommands() }` already provides Edit menu.

**Step 4: final verification (run all):**

```bash
# 1. clean build
xcodebuild -project Markdown.xcodeproj -target Markdown -configuration Debug -derivedDataPath build build
# 2. self-test: every parser check
build/Build/Products/Debug/Markdown.app/Contents/MacOS/Markdown --selftest
#   expected: SELFTEST <N> passed, 0 failed ; exit 0
# 3. smoke launch: window appears, logs, self-quits
build/Build/Products/Debug/Markdown.app/Contents/MacOS/Markdown --smoke
#   expected: EDITOR READY textKit1=true, SYNTAX RANGES n=<count>, SMOKE OK ; exit 0
# 4. user visual pass: see "Verify" checklist in Task 11 + table rendering + checkbox alignment
```

**Commit:** `git commit -m "Added sample document and smoke mode"` (final feature commit)

---

## Tests / validation summary

- CLI-verifiable TDD: `--selftest` runs ~35 assertions (blocks model, syntax ranges, fonts, colors, link URLs, attachments) with exit code; run after every parser task.
- Build gate: `xcodebuild … build` after every task (synchronized folder groups mean new files need no project edits).
- Runtime evidence (no screenshots, per house style): `EDITOR READY textKit1=true` proves the TextKit 1 stack; `SYNTAX RANGES n=…` proves styling ran; `SMOKE OK` proves the window/app loop is healthy.
- User visual confirmation: caret-line symbol show/hide, tertiary color, table layout, checkbox alignment, dark mode.

## Risks / tradeoffs / open questions

1. **TextKit 1 on macOS 27** — custom-layout-manager construction is the documented opt-out, but if `textKit1=false` at runtime (Task 2 gate), the whole approach needs rework (TextKit 2 `NSTextLayoutManager` delegate-based hiding). Gate early, fail loudly.
2. **`NSTextTable` quirks** — most fragile piece; fallback to code-block table rendering is one function swap, block model unchanged.
3. **Full CommonMark compliance is NOT claimed** — pragmatic subset (nested emphasis edge cases, reference-style links, HTML passthrough omitted). Documented deviations: no nested emphasis, `_` intraword rule only, paragraph joins wrapped lines with spaces.
4. **Performance** — full reparse per edit; fine to ~100 KB docs. Optimization path (only re-style edited paragraphs) documented in parser; not built (YAGNI).
5. **Image loading is network-dependent** — sample doc omits images; attachment falls back to alt text when offline.
6. **Undo granularity** — style changes aren't individually undoable (derived state); only characters undo. Matches Obsidian-ish behavior; acceptable.
7. **Open question: tertiary color** — interpreted as `NSColor.tertiaryLabelColor` (adaptive, matches system design language). If the user means a custom palette "tertiary", swap one constant in `MarkdownStyle`.
8. **Open question: checkboxes on inactive lines** — checkbox attachments are NOT syntax (always visible). Obsidian also always shows task checkboxes. Confirm in the visual pass.
