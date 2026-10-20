// The editor where TextKit is missing (Windows, Linux on v57/SwiftUI): the Markdown source in a text editor, with
// the formatting commands, and the rendered document (drawn with SwiftUI from swift-markdown's tree) when read-only.
#if !canImport(AppKit) && !canImport(UIKit)
  import CodeHighlighting
  import Markdown
  import SwiftUI

  /// What `MarkdownEditorCommands` drives here: the portable editor's formatting.
  @MainActor final class EditorTextView {
    var isReadOnly = false
    var formatter: ((MarkdownFormat) -> Void)?
    func apply(_ format: MarkdownFormat) { formatter?(format) }
  }

  public struct MarkdownEditorView: View {
    public var metrics: MarkdownMetrics
    public var text: String?
    public var onChange: @MainActor (String) -> Void
    public var resolver: MarkdownURLResolver
    public var isReadOnly: Bool
    public var anchor: String?
    public var onOpenURL: (@MainActor (URL) -> Bool)?
    public var startsEditing: Bool
    public var commands: MarkdownEditorCommands?

    @State private var draft = ""
    @State private var loaded = false
    @State private var selection: TextSelection?
    @State private var editor = EditorTextView()
    @FocusState private var focused: Bool

    public init(
      metrics: MarkdownMetrics = .standard,
      text: String? = nil,
      resolver: MarkdownURLResolver = .absoluteOnly,
      isReadOnly: Bool = false,
      anchor: String? = nil,
      onChange: @escaping @MainActor (String) -> Void = { _ in },
      onOpenURL: (@MainActor (URL) -> Bool)? = nil,
      startsEditing: Bool = false,
      commands: MarkdownEditorCommands? = nil
    ) {
      self.metrics = metrics
      self.text = text
      self.resolver = resolver
      self.isReadOnly = isReadOnly
      self.anchor = anchor
      self.onChange = onChange
      self.onOpenURL = onOpenURL
      self.startsEditing = startsEditing
      self.commands = commands
    }

    public var body: some View {
      Group {
        if isReadOnly {
          MarkdownDocumentView(markdown: draft, metrics: metrics, resolver: resolver, anchor: anchor)
        } else {
          TextEditor(text: $draft, selection: $selection)
            .font(.system(size: metrics.bodyFontSize + 1, design: .monospaced))
            .textEditorStyle(.plain)
            .focused($focused)
            .padding(.horizontal, metrics.textContainerInsetWidth)
            .padding(.vertical, metrics.textContainerInsetHeight)
        }
      }
      .environment(\.openURL, OpenURLAction { url in onOpenURL?(url) == true ? .handled : .systemAction })
      .onAppear {
        if !loaded {
          draft = text ?? SampleDocument.text
          loaded = true
        }
        configure()
        if startsEditing && !isReadOnly { focused = true }
      }
      .onChange(of: text) { _, new in
        if let new, new != draft { draft = new }
      }
      .onChange(of: draft) { _, new in
        if loaded, new != text { onChange(new) }
      }
      .onChange(of: isReadOnly) { _, _ in configure() }
    }

    private func configure() {
      editor.isReadOnly = isReadOnly
      editor.formatter = { format in apply(format) }
      commands?.textView = editor
    }

    /// Applies a formatting command to the selection (the caret: the end of the text without one).
    private func apply(_ format: MarkdownFormat) {
      let utf16 = draft.utf16
      var range = NSRange(location: utf16.count, length: 0)
      if case .selection(let selected)? = selection?.indices,
        let lower = selected.lowerBound.samePosition(in: utf16), let upper = selected.upperBound.samePosition(in: utf16)
      {
        range = NSRange(location: utf16.distance(from: utf16.startIndex, to: lower), length: utf16.distance(from: lower, to: upper))
      }
      let edit = MarkdownFormatting.edit(applying: format, to: draft, selection: range)
      let updated = (draft as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
      draft = updated
      let start = updated.utf16.index(updated.utf16.startIndex, offsetBy: min(edit.selection.location, updated.utf16.count))
      let end = updated.utf16.index(start, offsetBy: min(edit.selection.length, updated.utf16.distance(from: start, to: updated.utf16.endIndex)))
      selection = TextSelection(range: start..<end)
      focused = true
    }
  }

  // MARK: - Rendering

  /// A Markdown document drawn with SwiftUI: headings, paragraphs with inline styles and links, lists and task
  /// lists, quotes, highlighted code, tables, images and rules.
  struct MarkdownDocumentView: View {
    var markdown: String
    var metrics: MarkdownMetrics
    var resolver: MarkdownURLResolver
    var anchor: String?

    var body: some View {
      let document = Document(parsing: markdown, options: [.parseBlockDirectives])
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: metrics.bodyParagraphSpacing + 4) {
            ForEach(Array(document.children.enumerated()), id: \.offset) { _, block in
              MarkdownBlockView(block: block, metrics: metrics, resolver: resolver)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, metrics.textContainerInsetWidth)
          .padding(.vertical, metrics.textContainerInsetHeight)
        }
        .onAppear { scroll(proxy) }
        .onChange(of: anchor) { _, _ in scroll(proxy) }
      }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
      guard let anchor else { return }
      DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
    }
  }

  struct MarkdownBlockView: View {
    let block: Markup
    let metrics: MarkdownMetrics
    let resolver: MarkdownURLResolver
    var depth = 0

    var body: some View {
      content
    }

    @ViewBuilder private var content: some View {
      if let heading = block as? Heading {
        let level = max(1, min(heading.level, metrics.headingSizes.count))
        SwiftUI.Text(MarkdownInline.attributed(heading.children, resolver: resolver))
          .font(.system(size: metrics.headingSizes[level - 1], weight: level <= 2 ? .bold : .semibold))
          .padding(.top, level <= 2 ? metrics.headingParagraphSpacingBefore / 2 : 2)
          .id(MarkdownParser.githubSlug(heading.plainText))
      } else if let paragraph = block as? Paragraph {
        paragraphView(paragraph)
      } else if let list = block as? UnorderedList {
        listView(Array(list.listItems), ordered: false, start: 1)
      } else if let list = block as? OrderedList {
        listView(Array(list.listItems), ordered: true, start: Int(list.startIndex))
      } else if let quote = block as? BlockQuote {
        HStack(alignment: .top, spacing: metrics.quoteIndent) {
          RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
          VStack(alignment: .leading, spacing: metrics.quoteParagraphSpacing) {
            ForEach(Array(quote.children.enumerated()), id: \.offset) { _, child in
              MarkdownBlockView(block: child, metrics: metrics, resolver: resolver, depth: depth)
            }
          }
          .foregroundStyle(.secondary)
        }
      } else if let code = block as? CodeBlock {
        MarkdownCodeView(code: code.code, language: code.language, metrics: metrics)
      } else if block is ThematicBreak {
        Divider().padding(.vertical, 4)
      } else if let table = block as? Markdown.Table {
        tableView(table)
      } else if let html = block as? HTMLBlock {
        SwiftUI.Text(MarkdownHTML.decodeEntities(html.rawHTML.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)))
          .font(.system(size: metrics.bodyFontSize))
      } else {
        SwiftUI.Text(block.format()).font(.system(size: metrics.bodyFontSize))
      }
    }

    @ViewBuilder private func paragraphView(_ paragraph: Paragraph) -> some View {
      let images = paragraph.children.compactMap { $0 as? Markdown.Image }
      if !images.isEmpty, paragraph.children.allSatisfy({ $0 is Markdown.Image || $0 is SoftBreak || ($0 as? Markdown.Text)?.string.trimmingCharacters(in: .whitespaces).isEmpty == true }) {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(images.enumerated()), id: \.offset) { _, image in
            MarkdownImageView(source: image.source ?? "", alt: image.plainText, resolver: resolver)
          }
        }
      } else {
        SwiftUI.Text(MarkdownInline.attributed(paragraph.children, resolver: resolver))
          .font(.system(size: metrics.bodyFontSize))
          .lineSpacing(metrics.bodyLineSpacing)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }

    private func listView(_ items: [ListItem], ordered: Bool, start: Int) -> some View {
      VStack(alignment: .leading, spacing: metrics.listParagraphSpacing + 2) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
              if let checkbox = item.checkbox {
                SwiftUI.Image(systemName: checkbox == .checked ? "checkmark.square.fill" : "square")
                  .foregroundStyle(checkbox == .checked ? Color.accentColor : Color.secondary)
              } else if ordered {
                SwiftUI.Text("\(start + index).").monospacedDigit()
              } else {
                SwiftUI.Text(depth % 2 == 0 ? "•" : "◦")
              }
            }
            .font(.system(size: metrics.bodyFontSize))
            .frame(minWidth: ordered ? metrics.listMarkerWidthOrdered - 8 : metrics.listMarkerWidthBullet - 6, alignment: .trailing)
            VStack(alignment: .leading, spacing: metrics.listParagraphSpacing) {
              ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                MarkdownBlockView(block: child, metrics: metrics, resolver: resolver, depth: depth + 1)
              }
            }
          }
        }
      }
    }

    private func tableView(_ table: Markdown.Table) -> some View {
      let alignments = table.columnAlignments
      let header = Array(table.head.cells)
      let rows = table.body.rows.map { Array($0.cells) }
      func alignment(_ column: Int) -> HorizontalAlignment {
        switch column < alignments.count ? alignments[column] : nil {
        case .center?: .center
        case .right?: .trailing
        default: .leading
        }
      }
      return ScrollView(.horizontal) {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
          GridRow {
            ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
              SwiftUI.Text(MarkdownInline.attributed(cell.children, resolver: resolver)).bold()
                .gridColumnAlignment(alignment(column))
            }
          }
          Divider()
          ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            GridRow {
              ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                SwiftUI.Text(MarkdownInline.attributed(cell.children, resolver: resolver))
              }
            }
          }
        }
        .font(.system(size: metrics.bodyFontSize))
        .padding(.vertical, 4)
      }
    }
  }

  /// Inline Markdown as an attributed string: emphasis, strong, strikethrough and code as presentation intents,
  /// links resolved against the document.
  enum MarkdownInline {
    static func attributed(_ children: some Sequence<Markup>, resolver: MarkdownURLResolver) -> AttributedString {
      var result = AttributedString()
      for child in children { append(child, intent: [], link: nil, to: &result, resolver: resolver) }
      return result
    }

    private static func append(_ markup: Markup, intent: InlinePresentationIntent, link: URL?, to result: inout AttributedString, resolver: MarkdownURLResolver) {
      func piece(_ string: String, _ extra: InlinePresentationIntent = []) {
        var part = AttributedString(string)
        let combined = intent.union(extra)
        if !combined.isEmpty { part.inlinePresentationIntent = combined }
        if let link { part.link = link }
        result += part
      }
      switch markup {
      case let text as Markdown.Text: piece(text.string)
      case let code as InlineCode: piece(code.code, .code)
      case is SoftBreak: piece(" ")
      case is LineBreak: piece("\n")
      case let html as InlineHTML: piece(MarkdownHTML.decodeEntities(html.rawHTML.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)))
      case let image as Markdown.Image: piece(image.plainText.isEmpty ? "🖼" : image.plainText)
      default:
        var inner = intent
        var innerLink = link
        if markup is Emphasis { inner.insert(.emphasized) }
        if markup is Strong { inner.insert(.stronglyEmphasized) }
        if markup is Strikethrough { inner.insert(.strikethrough) }
        if let linkNode = markup as? Markdown.Link, let destination = linkNode.destination {
          innerLink = resolver.resolveLink(destination)
        }
        for child in markup.children { append(child, intent: inner, link: innerLink, to: &result, resolver: resolver) }
      }
    }
  }

  /// A fenced code block, colored by CodeHighlighting.
  struct MarkdownCodeView: View {
    let code: String
    let language: String?
    let metrics: MarkdownMetrics
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
      ScrollView(.horizontal) {
        SwiftUI.Text(highlighted)
          .font(.system(size: metrics.codeFontSize - 1, design: .monospaced))
          .textSelection(.enabled)
          .padding(10)
      }
      .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private var highlighted: AttributedString {
      let source = code.hasSuffix("\n") ? String(code.dropLast()) : code
      var result = AttributedString(source)
      guard let language, !language.isEmpty else { return result }
      let scheme = CodeColorScheme.systemAware(isDark: colorScheme == .dark)
      for token in CodeHighlighter.tokens(in: source, language: language) {
        guard let range = Range(token.range, in: source), let attributed = Range(range, in: result) else { continue }
        let rgb = scheme.color(for: token.kind)
        result[attributed].foregroundColor = Color(
          red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
      }
      return result
    }
  }

  /// An image from the document: a file next to it or a web image.
  struct MarkdownImageView: View {
    let source: String
    let alt: String
    let resolver: MarkdownURLResolver

    var body: some View {
      if let url = resolver.resolveImage(source) {
        AsyncImage(url: url) { phase in
          if let image = phase.image {
            image.resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 720, alignment: .leading)
          } else if phase.error != nil {
            Label(alt.isEmpty ? source : alt, systemImage: "photo").foregroundStyle(.secondary)
          } else {
            ProgressView()
          }
        }
      } else {
        Label(alt.isEmpty ? source : alt, systemImage: "photo").foregroundStyle(.secondary)
      }
    }
  }

#endif
