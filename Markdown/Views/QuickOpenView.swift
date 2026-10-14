import SwiftData
import SwiftUI

/// Something Quick Open can do besides opening a note.
enum QuickOpenCommand: Hashable {
  /// A new note, named after what was typed (or "Untitled").
  case newNote(String?)
  case newFolder
  case addFolder
  case welcome
}

/// Quick Open (⌘K): one field that finds notes by name, finds text inside notes, and
/// runs commands. Arrow keys move, Return opens, Escape closes. With nothing typed it
/// lists recent notes.
struct QuickOpenView: View {
  var perform: (QuickOpenCommand) -> Void
  @Environment(FolderLibrary.self) private var library
  @Environment(Navigator.self) private var navigator
  @Environment(NotesLocation.self) private var notes
  @Environment(NotePreferences.self) private var preferences
  @Environment(RepositoryStore.self) private var repositories
  @Environment(WindowState.self) private var window
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]
  @State private var query = ""
  @State private var results: [SearchResult] = []
  @State private var selected = 0
  @State private var resultsHeight: CGFloat = 0
  @FocusState private var isFocused: Bool

  private struct Entry: Identifiable {
    enum Action { case open(URL), command(QuickOpenCommand) }
    let id: String
    let section: String
    let title: AttributedString
    let subtitle: AttributedString?
    let systemImage: String
    var shortcut: String?
    let action: Action
  }

  var body: some View {
    let entries = entries
    VStack(spacing: 0) {
      field(entries)
      Divider()
      // As tall as the results, up to a limit, then scrolling.
      ScrollViewReader { proxy in
        ScrollView {
          results(entries)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resultsHeight = $0 }
        }
        .frame(height: min(resultsHeight, 400))
        .onChange(of: selected) { _, index in
          guard entries.indices.contains(index) else { return }
          proxy.scrollTo(entries[index].id)
        }
      }
      #if os(macOS)
        Divider()
        footer
      #endif
    }
    .frame(maxWidth: 640)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(.separator.opacity(0.6))
    }
    .shadow(color: .black.opacity(0.25), radius: 32, y: 16)
    .task(id: query) { await search() }
    .onAppear { isFocused = ScreenshotDemo.focusesFields }
    .onChange(of: query) { selected = 0 }
  }

  private func results(_ entries: [Entry]) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
        if index == 0 || entries[index - 1].section != entry.section {
          Text(entry.section)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, index == 0 ? 4 : 10)
            .padding(.bottom, 2)
        }
        Button {
          activate(entry)
        } label: {
          row(entry, isSelected: index == selected)
        }
        .buttonStyle(.plain)
        .id(entry.id)
        #if os(macOS)
          .onContinuousHover { phase in
            if case .active = phase, selected != index { selected = index }
          }
        #endif
      }
      if entries.isEmpty {
        Text("No notes or commands match “\(query)”.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(24)
      }
    }
    .padding(8)
  }

  private func field(_ entries: [Entry]) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .font(.title3)
        .foregroundStyle(.secondary)
      TextField("Search notes and commands", text: $query)
        .textFieldStyle(.plain)
        .font(.title2)
        .focused($isFocused)
        .autocorrectionDisabled()
        .onSubmit {
          if entries.indices.contains(selected) { activate(entries[selected]) }
        }
        .onKeyPress(.downArrow) {
          selected = min(selected + 1, max(entries.count - 1, 0))
          return .handled
        }
        .onKeyPress(.upArrow) {
          selected = max(selected - 1, 0)
          return .handled
        }
        .onKeyPress(.escape) {
          close()
          return .handled
        }
      Button("Close", systemImage: "xmark.circle.fill") { close() }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .keyboardShortcut(.cancelAction)
        .help("Close (Esc)")
    }
    .padding(.horizontal, 16)
    .frame(height: 54)
  }

  private func row(_ entry: Entry, isSelected: Bool) -> some View {
    HStack(spacing: 10) {
      Image(systemName: entry.systemImage)
        .frame(width: 28, height: 28)
        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        .background(
          (isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      VStack(alignment: .leading, spacing: 1) {
        Text(entry.title).lineLimit(1)
        if let subtitle = entry.subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if let shortcut = entry.shortcut {
        Text(shortcut).font(.callout).foregroundStyle(.secondary)
      } else if isSelected {
        Image(systemName: "return").font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      isSelected ? Color.accentColor.opacity(0.16) : .clear,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  #if os(macOS)
    private var footer: some View {
      HStack(spacing: 16) {
        hint("↑↓", "Move")
        hint("↩", "Open")
        hint("esc", "Close")
        Spacer()
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 18)
      .frame(height: 34)
    }

    private func hint(_ key: String, _ label: String) -> some View {
      HStack(spacing: 4) {
        Text(key)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        Text(label)
      }
    }
  #endif

  // MARK: - Entries

  private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  private var entries: [Entry] {
    let query = trimmedQuery
    var entries: [Entry] = []
    if query.isEmpty {
      for url in preferences.existingRecents.prefix(6) {
        entries.append(noteEntry(url, section: "Recent", subtitle: AttributedString(location(of: url))))
      }
    } else {
      for result in results.filter(\.nameMatches).prefix(6) {
        entries.append(noteEntry(result.url, section: "Notes", subtitle: AttributedString(result.location)))
      }
      for result in results.filter({ !$0.nameMatches }).prefix(6) {
        let snippet = result.snippet.map { highlighted(NoteSummaries.plain($0)) } ?? AttributedString(result.location)
        entries.append(noteEntry(result.url, section: "Inside Notes", subtitle: snippet, systemImage: "text.alignleft"))
      }
    }
    entries += commands(matching: query)
    return entries
  }

  private func noteEntry(
    _ url: URL, section: String, subtitle: AttributedString, systemImage: String = "doc.text"
  ) -> Entry {
    Entry(
      id: section + url.path, section: section,
      title: highlighted(url.deletingPathExtension().lastPathComponent), subtitle: subtitle,
      systemImage: systemImage, action: .open(url))
  }

  private func commands(matching query: String) -> [Entry] {
    var all: [Entry] = [
      Entry(
        id: "new-note", section: "Commands",
        title: AttributedString(query.isEmpty ? "New Note" : "New Note “\(query)”"), subtitle: nil,
        systemImage: "square.and.pencil", shortcut: "⌘N", action: .command(.newNote(query.isEmpty ? nil : query))),
      Entry(
        id: "new-folder", section: "Commands", title: "New Folder", subtitle: nil,
        systemImage: "folder.badge.plus", shortcut: "⇧⌘N", action: .command(.newFolder)),
      Entry(
        id: "add-folder", section: "Commands", title: "Add Folder to Sidebar…", subtitle: nil,
        systemImage: "plus.rectangle.on.folder", shortcut: "⇧⌘O", action: .command(.addFolder)),
      Entry(
        id: "welcome", section: "Commands", title: "Welcome to Markdown", subtitle: nil,
        systemImage: "hand.wave", shortcut: "⇧⌘1", action: .command(.welcome)),
    ]
    #if os(iOS)
      for index in all.indices { all[index].shortcut = nil }
    #endif
    guard !query.isEmpty else { return all }
    // "New Note “…”" always; the rest when every typed word is in their title.
    let terms = query.split(separator: " ").map(String.init)
    return all.filter { entry in
      entry.id == "new-note"
        || terms.allSatisfy { String(entry.title.characters).localizedCaseInsensitiveContains($0) }
    }
  }

  /// `text` with the typed words in bold.
  private func highlighted(_ text: String) -> AttributedString {
    var attributed = AttributedString(text)
    for term in trimmedQuery.split(separator: " ") {
      var start = attributed.startIndex
      while start < attributed.endIndex,
        let range = attributed[start...].range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
      {
        attributed[range].inlinePresentationIntent = .stronglyEmphasized
        start = range.upperBound
      }
    }
    return attributed
  }

  /// "Projects · iCloud" for a recent note.
  private func location(of url: URL) -> String {
    let folder = url.deletingLastPathComponent()
    if let root = notes.url, folder == root { return notes.isICloud ? "iCloud" : "Notes" }
    if let root = notes.url, folder.path.hasPrefix(root.path + "/") {
      return folder.lastPathComponent + (notes.isICloud ? " · iCloud" : "")
    }
    return folder.lastPathComponent
  }

  // MARK: - Actions

  private func search() async {
    let query = trimmedQuery
    guard !query.isEmpty else {
      results = []
      return
    }
    try? await Task.sleep(for: .milliseconds(150))
    guard !Task.isCancelled else { return }
    let scope = SearchScope(library: library, notes: notes, repositories: repositories, folders: folders)
    let found = await scope.search(query)
    guard !Task.isCancelled else { return }
    results = found
  }

  private func activate(_ entry: Entry) {
    close()
    switch entry.action {
    case .open(let url):
      library.reveal(url, roots: library.roots(folders))
      navigator.open(url)
    case .command(let command):
      perform(command)
    }
  }

  private func close() {
    window.isQuickOpenShown = false
  }
}

