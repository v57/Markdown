import SwiftUI

/// The welcome sheet, shown when the app opens (unless turned off) and from Window ›
/// Welcome to Markdown: start a note, open a folder of Markdown files, or go back to a
/// recent note.
struct WelcomeView: View {
  var perform: (QuickOpenCommand) -> Void
  @Environment(NotePreferences.self) private var preferences
  @Environment(Navigator.self) private var navigator
  @Environment(FolderLibrary.self) private var library
  @Environment(NotesLocation.self) private var notes
  @Environment(\.dismiss) private var dismiss
  @AppStorage("showsWelcome") private var showsWelcome = true
  @AppStorage(NoteFiles.encryptNewNotesKey) private var encryptsNewNotes = true

  var body: some View {
    #if os(macOS)
      HStack(spacing: 0) {
        start
          .frame(width: 440)
        Divider()
        recents
          .frame(width: 280)
          .background(.background.secondary)
      }
      .frame(height: 500)
      .overlay(alignment: .topLeading) {
        Button("Close", systemImage: "xmark") { dismiss() }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .keyboardShortcut(.cancelAction)
          .help("Close (Esc)")
          .padding(14)
      }
    #else
      NavigationStack {
        ScrollView {
          VStack(spacing: 28) {
            start
            if !preferences.existingRecents.isEmpty { recents }
          }
          .padding(.vertical)
        }
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
      }
    #endif
  }

  private var start: some View {
    VStack(spacing: 0) {
      VStack(spacing: 6) {
        AppIconView()
          .frame(width: 88, height: 88)
          .padding(.bottom, 10)
        Text("Markdown")
          .font(.largeTitle.bold())
        Text("Notes in plain Markdown files")
          .foregroundStyle(.secondary)
      }
      .padding(.top, 36)
      .padding(.bottom, 28)

      VStack(spacing: 4) {
        action(
          "New Note", notes.isICloud ? "Start writing. Notes sync through iCloud Drive." : "Start writing. Notes are plain files on this \(deviceName).", systemImage: "square.and.pencil",
          shortcut: "⌘N", command: .newNote(nil))
        action(
          "Open Folder…", "Edit the Markdown files already on your \(deviceName), in place.",
          systemImage: "folder", shortcut: "⇧⌘O", command: .addFolder)
      }
      .padding(.horizontal, 32)

      Spacer(minLength: 24)

      // New notes are encrypted with the key the v57 apps share (Shell opens them too).
      Toggle("Encrypt new notes", isOn: $encryptsNewNotes)
        #if os(macOS)
          .toggleStyle(.checkbox)
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        #endif
        .padding(.horizontal, 32)
        .padding(.bottom, 6)
      Toggle(showsWelcomeLabel, isOn: $showsWelcome)
        #if os(macOS)
          .toggleStyle(.checkbox)
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        #endif
        .padding(.horizontal, 32)
        .padding(.bottom, 20)
    }
  }

  private func action(
    _ title: String, _ detail: String, systemImage: String, shortcut: String, command: QuickOpenCommand
  ) -> some View {
    Button {
      dismiss()
      perform(command)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .font(.title3)
          .foregroundStyle(Color.accentColor)
          .frame(width: 36, height: 36)
          .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.headline)
          Text(detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        #if os(macOS)
          Text(shortcut).foregroundStyle(.secondary)
        #endif
      }
      .padding(10)
      .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(WelcomeButtonStyle())
  }

  private var recents: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Recent")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
      let recents = preferences.existingRecents.prefix(8)
      if recents.isEmpty {
        Text("Notes you open appear here.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
      }
      ForEach(Array(recents), id: \.self) { url in
        Button {
          dismiss()
          library.reveal(url, roots: library.builtInRoots)
          navigator.open(url)
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
              Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
              Text(subtitle(for: url))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .contentShape(Rectangle())
        }
        .buttonStyle(WelcomeButtonStyle())
      }
      Spacer(minLength: 0)
    }
    #if os(macOS)
      .padding(.top, 44)
      .padding(.horizontal, 8)
      .padding(.bottom, 12)
    #else
      .padding(.horizontal)
    #endif
  }

  private func subtitle(for url: URL) -> String {
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    return [url.deletingLastPathComponent().lastPathComponent, modified?.noteListText]
      .compactMap { $0 }.joined(separator: " · ")
  }

  private var showsWelcomeLabel: String {
    #if os(macOS)
      "Show this window when Markdown opens"
    #else
      "Show when Markdown opens"
    #endif
  }

  private var deviceName: String {
    #if os(macOS)
      "Mac"
    #else
      UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    #endif
  }
}

/// A row that highlights when hovered or pressed.
private struct WelcomeButtonStyle: ButtonStyle {
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        Color.primary.opacity(configuration.isPressed ? 0.1 : isHovered ? 0.05 : 0),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .onHover { isHovered = $0 }
  }
}

/// The app's icon: the real one on macOS; on iOS, where the icon can't be read back, the
/// same mark drawn (a page in blush on v57 red).
private struct AppIconView: View {
  var body: some View {
    #if os(macOS)
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .accessibilityHidden(true)
    #else
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(Color(red: 1, green: 0.153, blue: 0.251))
        .overlay {
          Image(systemName: "doc.text")
            .font(.system(size: 40, weight: .semibold))
            .foregroundStyle(Color(red: 1, green: 0.804, blue: 0.847))
        }
        .shadow(color: Color(red: 1, green: 0.153, blue: 0.251).opacity(0.3), radius: 8, y: 4)
        .accessibilityHidden(true)
    #endif
  }
}
