import ComponentKit
import SwiftData
import SwiftUI

/// The welcome, the note pane's content while no note is open (and Window › Welcome to Markdown): start a note, open a
/// folder of Markdown files, or go back to a recent note. The kit's inline welcome, with Encrypt New Notes among its
/// options; a folder dropped on it joins the sidebar.
struct WelcomeView: View {
  @Environment(NotePreferences.self) private var preferences
  @Environment(Navigator.self) private var navigator
  @Environment(FolderLibrary.self) private var library
  @Environment(NotesLocation.self) private var notes
  @Environment(WindowState.self) private var window
  @Environment(\.modelContext) private var context
  @Query(sort: \SidebarFolder.addedAt) private var folders: [SidebarFolder]
  @AppStorage(NoteFiles.encryptNewNotesKey) private var encryptsNewNotes = true

  var body: some View {
    KitWelcome(
      appName: "Markdown", version: "Notes in plain Markdown files", emptyTitle: "No Recent Notes",
      emptyMessage: "Notes you open appear here.", onDrop: open
    ) {
      WelcomeAction("New Note", detail: newNoteDetail, systemImage: "square.and.pencil") { window.perform?(.newNote(nil)) }
      WelcomeAction(
        "Open Folder…", detail: "Edit the Markdown files already on your \(deviceName), in place.",
        systemImage: "folder"
      ) { window.perform?(.addFolder) }
    } recents: {
      ForEach(Array(preferences.existingRecents.prefix(8)), id: \.self) { url in
        RecentItem(
          url.deletingPathExtension().lastPathComponent, subtitle: subtitle(for: url), systemImage: "doc.text",
          id: url.path
        ) {
          library.reveal(url, roots: library.builtInRoots)
          navigator.open(url)
        }
      }
    }
    // New notes are encrypted with the key the v57 apps share (Shell opens them too).
    .options { Toggle("Encrypt new notes", isOn: $encryptsNewNotes) }
  }

  private var newNoteDetail: String {
    notes.isICloud
      ? "Notes are files on this \(deviceName) and sync through iCloud."
      : "Start writing. Notes are plain files on this \(deviceName)."
  }

  /// Folders and files dropped on the welcome join the sidebar; the first shows.
  private func open(_ urls: [URL]) -> Bool {
    let shown = library.add(urls, existing: folders, context: context)
    if let first = shown.first { navigator.open(first) }
    return !shown.isEmpty
  }

  private func subtitle(for url: URL) -> String {
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    return [url.deletingLastPathComponent().lastPathComponent, modified?.noteListText]
      .compactMap { $0 }.joined(separator: " · ")
  }

  private var deviceName: String { KitDevice.nameInSentence }
}
