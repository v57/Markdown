import Foundation
import Observation
import VaultKit

/// Organizing notes: create, rename, move and trash files and folders in any folder the
/// app can write (the notes folder, sidebar folders, GitHub repositories).
///
/// Every change is a coordinated file operation, so iCloud and other apps see it as one
/// step. The sidebar is reloaded afterwards and the navigator follows renamed and moved
/// items (selection and history).
@Observable final class FileActions {
  /// The item whose rename prompt is showing, and the name being typed.
  var renaming: URL?
  var newName = ""
  /// The item waiting for a delete confirmation (iOS, where deletion may be permanent).
  var deleting: URL?
  /// Why the last action failed, for an alert.
  var error: String?
  /// Runs before anything moves on disk: the open document's pending edits must reach
  /// its file while the file is still where the editor thinks it is.
  @ObservationIgnored var willChangeFiles: () -> Void = {}
  /// Runs after an item moved or was renamed (pins and recents follow it).
  @ObservationIgnored var didMove: (URL, URL) -> Void = { _, _ in }
  /// The app's notes folder, where new notes start encrypted (`NoteFiles.encryptsNewNotes`).
  @ObservationIgnored var notesFolder: () -> URL? = { nil }

  @ObservationIgnored private let library: FolderLibrary
  @ObservationIgnored private let navigator: Navigator

  init(library: FolderLibrary, navigator: Navigator) {
    self.library = library
    self.navigator = navigator
  }

  // MARK: - Create

  /// Creates an empty note in `directory` (named `name`, else "Untitled") and shows it. In the notes
  /// folder it's encrypted (`.mdenc`) unless the user turned that off.
  @discardableResult
  func newNote(in directory: URL, named name: String? = nil) -> URL? {
    let base = name?.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
    let title = base.map { $0.hasPrefix(".") ? String($0.drop { $0 == "." }) : $0 }
    let encrypted = NoteFiles.encryptsNewNotes && isInNotesFolder(directory)
    let fileName =
      (title?.isEmpty == false ? title! : "Untitled") + (encrypted ? "." + EncryptedNote.fileExtension : ".md")
    let contents = encrypted ? (try? NoteFiles.data(for: "", at: URL(fileURLWithPath: fileName))) ?? Data() : Data()
    let url = create(Self.availableURL(for: fileName, in: directory, isDirectory: false)) {
      try contents.write(to: $0, options: .withoutOverwriting)
    }
    if url != nil { navigator.startsEditing = true }
    return url
  }

  /// Creates a folder in `directory`, shows it and asks for its name.
  func newFolder(in directory: URL) {
    let url = create(Self.availableURL(for: "New Folder", in: directory, isDirectory: true)) {
      try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false)
    }
    if let url { beginRename(url) }
  }

  private func create(_ url: URL, _ make: (URL) throws -> Void) -> URL? {
    willChangeFiles()
    do {
      try coordinate(writing: url, options: []) { try make($0) }
    } catch {
      self.error = error.localizedDescription
      return nil
    }
    let url = FolderLibrary.canonical(url)
    library.expanded.insert(FolderLibrary.canonical(url.deletingLastPathComponent()))
    library.reload()
    navigator.open(url)
    return url
  }

  private func isInNotesFolder(_ directory: URL) -> Bool {
    guard let notes = notesFolder() else { return false }
    let root = FolderLibrary.canonical(notes).path
    let path = FolderLibrary.canonical(directory).path
    return path == root || path.hasPrefix(root + "/")
  }

  // MARK: - Encryption

  /// Whether a note can be encrypted (a markdown file) or decrypted (an encrypted note).
  func canToggleEncryption(_ url: URL) -> Bool {
    !FolderLibrary.isDirectory(url) && FolderLibrary.isMarkdown(url)
  }

  /// Encrypts a note (`Name.md` → `Name.mdenc`, its text sealed with the vault key) or decrypts one back
  /// to a plain file. The file keeps its place; the editor follows it.
  func setEncrypted(_ url: URL, _ encrypted: Bool) {
    guard NoteFiles.isEncrypted(url) != encrypted else { return }
    willChangeFiles()
    let name = EncryptedNote.url(for: url, encrypted: encrypted).lastPathComponent
    let target = Self.availableURL(for: name, in: url.deletingLastPathComponent(), isDirectory: false)
    do {
      var text: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
      var coordinationError: NSError?
      NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { from in
        text = Result { try NoteFiles.text(at: from) }
      }
      if let coordinationError { throw coordinationError }
      let data = try NoteFiles.data(for: try text.get(), at: target)
      var writeError: Error?
      let coordinator = NSFileCoordinator()
      coordinator.coordinate(
        writingItemAt: url, options: .forMoving, writingItemAt: target, options: .forReplacing,
        error: &coordinationError
      ) { from, to in
        do {
          // Moved first, so iCloud sees one item renamed, then rewritten.
          try FileManager.default.moveItem(at: from, to: to)
          coordinator.item(at: from, didMoveTo: to)
          try data.write(to: to, options: .atomic)
        } catch {
          writeError = error
        }
      }
      if let failure = coordinationError ?? writeError { throw failure }
    } catch {
      self.error = error.localizedDescription
      return
    }
    let old = FolderLibrary.canonical(url)
    let new = FolderLibrary.canonical(target)
    NoteFiles.bases.moveBase(from: old, to: new)
    navigator.replace(old, with: new)
    didMove(old, new)
    library.reload()
  }

  // MARK: - Rename

  func beginRename(_ url: URL) {
    newName = url.lastPathComponent
    renaming = url
  }

  /// Renames the item from `beginRename`. A markdown note keeps its extension when the
  /// new name leaves it out ("Ideas" → "Ideas.md").
  func commitRename() {
    guard let url = renaming else { return }
    renaming = nil
    var name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != url.lastPathComponent else { return }
    guard !name.contains("/"), !name.hasPrefix(".") else {
      error = "“\(name)” can’t be used as a name."
      return
    }
    if !FolderLibrary.isDirectory(url), FolderLibrary.isMarkdown(url),
      (name as NSString).pathExtension.isEmpty
    {
      name += "." + url.pathExtension
    }
    let target = url.deletingLastPathComponent().appendingPathComponent(name)
    move(url, to: target)
  }

  // MARK: - Move

  /// Moves (items inside the app's folders) or copies (anything dropped from outside)
  /// `urls` into `directory`. Returns whether anything was dropped.
  @discardableResult
  func drop(_ urls: [URL], into directory: URL, roots: [URL]) -> Bool {
    var any = false
    for url in urls where url.isFileURL {
      let source = FolderLibrary.canonical(url)
      let dir = FolderLibrary.canonical(directory)
      // Onto itself, into its own folder, or into its own subtree: nothing to do.
      guard source != dir, source.deletingLastPathComponent() != dir,
        !dir.path.hasPrefix(source.path + "/")
      else { continue }
      let target = Self.availableURL(
        for: source.lastPathComponent, in: dir, isDirectory: FolderLibrary.isDirectory(source))
      if library.root(of: source, roots: roots) != nil {
        move(source, to: target)
      } else {
        copy(url, to: target)
      }
      any = true
    }
    return any
  }

  private func move(_ url: URL, to target: URL) {
    willChangeFiles()
    guard !FileManager.default.fileExists(atPath: target.path) || Self.sameItem(url, target) else {
      error = "An item named “\(target.lastPathComponent)” already exists there."
      return
    }
    do {
      var coordinationError: NSError?
      var moveError: Error?
      let coordinator = NSFileCoordinator()
      coordinator.coordinate(
        writingItemAt: url, options: .forMoving, writingItemAt: target, options: .forReplacing,
        error: &coordinationError
      ) { from, to in
        do {
          try FileManager.default.moveItem(at: from, to: to)
          coordinator.item(at: from, didMoveTo: to)
        } catch {
          moveError = error
        }
      }
      if let failure = coordinationError ?? moveError { throw failure }
    } catch {
      self.error = error.localizedDescription
      return
    }
    let target = FolderLibrary.canonical(target)
    library.expanded.insert(FolderLibrary.canonical(target.deletingLastPathComponent()))
    navigator.replace(FolderLibrary.canonical(url), with: target)
    didMove(FolderLibrary.canonical(url), target)
    library.reload()
  }

  /// "Ideas.md" → "ideas.md" on a case-insensitive volume: the target "exists" but is
  /// the item itself.
  private static func sameItem(_ a: URL, _ b: URL) -> Bool {
    let ida = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    let idb = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    guard let ida, let idb else { return false }
    return ida.isEqual(idb)
  }

  private func copy(_ url: URL, to target: URL) {
    let started = url.startAccessingSecurityScopedResource()
    defer { if started { url.stopAccessingSecurityScopedResource() } }
    do {
      var coordinationError: NSError?
      var copyError: Error?
      NSFileCoordinator().coordinate(
        readingItemAt: url, options: [], writingItemAt: target, options: .forReplacing,
        error: &coordinationError
      ) { from, to in
        do { try FileManager.default.copyItem(at: from, to: to) } catch { copyError = error }
      }
      if let failure = coordinationError ?? copyError { throw failure }
    } catch {
      self.error = error.localizedDescription
      return
    }
    library.expanded.insert(FolderLibrary.canonical(target.deletingLastPathComponent()))
    library.reload()
  }

  // MARK: - Delete

  /// Moves the item to the Trash. On iOS, where an app's files may have no Trash, it
  /// asks first (`deleting`) and `confirmDelete()` does the work.
  func delete(_ url: URL) {
    #if os(iOS)
      deleting = url
    #else
      remove(url)
    #endif
  }

  func confirmDelete() {
    guard let url = deleting else { return }
    deleting = nil
    remove(url)
  }

  private func remove(_ url: URL) {
    willChangeFiles()
    do {
      try coordinate(writing: url, options: .forDeleting) { url in
        do {
          try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
          #if os(iOS)
            try FileManager.default.removeItem(at: url)  // confirmed by the user
          #else
            throw error
          #endif
        }
      }
    } catch {
      self.error = error.localizedDescription
      return
    }
    navigator.forget(under: url)
    library.reload()
  }

  // MARK: - Helpers

  private func coordinate(
    writing url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void
  ) throws {
    var coordinationError: NSError?
    var bodyError: Error?
    NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError)
    { target in
      do { try body(target) } catch { bodyError = error }
    }
    if let failure = coordinationError ?? bodyError { throw failure }
  }

  /// `name` in `directory`, numbered ("Untitled 2.md") when taken.
  nonisolated static func availableURL(for name: String, in directory: URL, isDirectory: Bool)
    -> URL
  {
    let fm = FileManager.default
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var candidate = directory.appendingPathComponent(name, isDirectory: isDirectory)
    var number = 2
    while fm.fileExists(atPath: candidate.path) {
      let numbered = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
      candidate = directory.appendingPathComponent(numbered, isDirectory: isDirectory)
      number += 1
    }
    return candidate
  }
}
