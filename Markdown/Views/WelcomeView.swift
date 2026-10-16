import ComponentKit
import SwiftUI

/// The welcome sheet, shown when the app opens (unless turned off) and from Window ›
/// Welcome to Markdown: start a note, open a folder of Markdown files, or go back to a
/// recent note. The kit's welcome window; on iPhone, where it doesn't fit, a scrolling page.
struct WelcomeView: View {
  var perform: (QuickOpenCommand) -> Void
  /// Folders and files dropped on the window.
  var open: ([URL]) -> Bool
  @Environment(NotePreferences.self) private var preferences
  @Environment(Navigator.self) private var navigator
  @Environment(FolderLibrary.self) private var library
  @Environment(NotesLocation.self) private var notes
  @Environment(\.dismiss) private var dismiss
  @AppStorage("showsWelcome") private var showsWelcome = true
  @AppStorage(NoteFiles.encryptNewNotesKey) private var encryptsNewNotes = true
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    #if os(macOS)
      welcome
    #else
      if idiom == .phone { page } else { welcome }
    #endif
  }

  private var welcome: some View {
    KitWelcome(
      appName: "Markdown", version: "Notes in plain Markdown files", showAtLaunch: $showsWelcome,
      emptyTitle: "No Recent Notes", emptyMessage: "Notes you open appear here.", close: { dismiss() },
      onDrop: { urls in
        dismiss()
        return open(urls)
      }
    ) {
      WelcomeAction("New Note", detail: newNoteDetail, systemImage: "square.and.pencil") { run(.newNote(nil)) }
      WelcomeAction(
        "Open Folder…", detail: "Edit the Markdown files already on your \(deviceName), in place.",
        systemImage: "folder"
      ) { run(.addFolder) }
      // New notes are encrypted with the key the v57 apps share (Shell opens them too).
      Toggle("Encrypt new notes", isOn: $encryptsNewNotes)
        .toggleStyle(.kitCheckbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)
        .padding(.top, 8)
    } recents: {
      ForEach(Array(preferences.existingRecents.prefix(8)), id: \.self) { url in
        RecentItem(
          url.deletingPathExtension().lastPathComponent, subtitle: subtitle(for: url), systemImage: "doc.text",
          id: url.path
        ) {
          openRecent(url)
        }
      }
    }
    #if os(macOS)
      .frame(height: 660)
    #endif
  }

  private var newNoteDetail: String {
    notes.isICloud
      ? "Notes are files on this \(deviceName) and sync through iCloud."
      : "Start writing. Notes are plain files on this \(deviceName)."
  }

  private func run(_ command: QuickOpenCommand) {
    dismiss()
    perform(command)
  }

  private func openRecent(_ url: URL) {
    dismiss()
    library.reveal(url, roots: library.builtInRoots)
    navigator.open(url)
  }

  #if os(iOS)
    private var page: some View {
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
    }

  private var start: some View {
    VStack(spacing: 0) {
      VStack(spacing: 6) {
        AppIconView()
          .frame(width: 88, height: 88)
          .padding(.bottom, 10)
        Text("Markdown")
          .kitFont(.largeTitle)
        Text("Notes in plain Markdown files")
          .kitFont(.callout)
          .foregroundStyle(.kitSecondary)
      }
      .padding(.top, 36)
      .padding(.bottom, 28)

      VStack(spacing: 4) {
        WelcomeAction("New Note", detail: newNoteDetail, systemImage: "square.and.pencil") { run(.newNote(nil)) }
        WelcomeAction(
          "Open Folder…", detail: "Edit the Markdown files already on your \(deviceName), in place.",
          systemImage: "folder"
        ) { run(.addFolder) }
      }
      .padding(.horizontal, 24)

      Spacer(minLength: 24)

      // New notes are encrypted with the key the v57 apps share (Shell opens them too).
      Toggle("Encrypt new notes", isOn: $encryptsNewNotes)
        .toggleStyle(.kitSwitch)
        .padding(.horizontal, 32)
        .padding(.bottom, 6)
      Toggle("Show when Markdown opens", isOn: $showsWelcome)
        .toggleStyle(.kitSwitch)
        .padding(.horizontal, 32)
        .padding(.bottom, 20)
    }
  }

  private var recents: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Recent")
        .kitFont(.headline)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
      let recents = preferences.existingRecents.prefix(8)
      if recents.isEmpty {
        Text("Notes you open appear here.")
          .kitFont(.callout)
          .foregroundStyle(.kitSecondary)
          .padding(.horizontal, 12)
      }
      ForEach(Array(recents), id: \.self) { url in
        Button {
          openRecent(url)
        } label: {
          HStack(spacing: 10) {
            Tile(systemImage: "doc.text", hue: .blue, size: 36)
            VStack(alignment: .leading, spacing: 1) {
              Text(url.deletingPathExtension().lastPathComponent).kitFont(.headline).lineLimit(1)
              Text(subtitle(for: url)).kitFont(.caption).lineLimit(1)
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
    .padding(.horizontal)
  }
  #endif

  private func subtitle(for url: URL) -> String {
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    return [url.deletingLastPathComponent().lastPathComponent, modified?.noteListText]
      .compactMap { $0 }.joined(separator: " · ")
  }

  private var deviceName: String {
    #if os(macOS)
      "Mac"
    #else
      UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    #endif
  }
}

#if os(iOS)
/// A row that highlights when pressed.
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

/// The app's mark, drawn: the icon can't be read back on iOS (a page in blush on v57 red).
private struct AppIconView: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(Color(red: 1, green: 0.153, blue: 0.251))
        .overlay {
          Image(systemName: "doc.text")
            .font(.system(size: 40, weight: .semibold))
            .foregroundStyle(Color(red: 1, green: 0.804, blue: 0.847))
        }
        .shadow(color: Color(red: 1, green: 0.153, blue: 0.251).opacity(0.3), radius: 8, y: 4)
        .accessibilityHidden(true)
  }
}
#endif
