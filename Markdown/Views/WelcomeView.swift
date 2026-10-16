import ComponentKit
import SwiftUI

/// The welcome sheet, shown when the app opens (unless turned off) and from Window ›
/// Welcome to Markdown: start a note, open a folder of Markdown files, or go back to a
/// recent note. The kit's welcome window (the whole width on iPhone), with Encrypt New Notes among its options.
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

  var body: some View {
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
    // New notes are encrypted with the key the v57 apps share (Shell opens them too).
    .options { Toggle("Encrypt new notes", isOn: $encryptsNewNotes) }
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
