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
  /// The item being renamed, and the name being typed.
  var renaming: URL?
  var newName = ""
  /// Whether the rename happens in the item's sidebar row (`kitRename`) instead of the Rename prompt.
  var renamesInPlace = false
  /// The item waiting for a delete confirmation (iOS, where deletion may be permanent).
  var deleting: URL?
  /// The notes waiting for a delete confirmation together (iOS).
  var deletingSeveral: [URL] = []
  /// Why the last action failed, for an alert.
  var error: String?
  /// Runs before anything moves on disk: the open document's pending edits must reach
  /// its file while the file is still where the editor thinks it is.
  @ObservationIgnored var willChangeFiles: () -> Void = {}
  /// Runs after an item moved or was renamed (pins and recents follow it).
  @ObservationIgnored var didMove: (URL, URL) -> Void = { _, _ in }
  /// Runs before a new note is made: the shown note goes if it's empty, so the new one takes its name.
  @ObservationIgnored var willCreateNote: () -> Void = {}
  /// Runs after a new note is made: when it took the name of the shown note, the same editor stays and takes the focus.
  @ObservationIgnored var didCreateNote: () -> Void = {}
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
  func newNote(in directory: URL, named name: String? = nil) {
    willCreateNote()
    // The empty note just left is still going (`removals`): the new one waits for it, so it can take its name.
    guard let removals else { return makeNote(in: directory, named: name) }
    Task {
      await removals.value
      makeNote(in: directory, named: name)
    }
  }

  private func makeNote(in directory: URL, named name: String?) {
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
    if url != nil {
      navigator.startsEditing = true
      didCreateNote()
    }
  }

  /// Adds the sample notes (`SampleNotes`) as a new folder in `directory` and returns their start note.
  func addSampleNotes(in directory: URL) -> URL? {
    let folder = create(Self.availableURL(for: SampleNotes.folderName, in: directory, isDirectory: true)) {
      try SampleNotes.write(into: $0)
    }
    return folder?.appendingPathComponent(SampleNotes.firstNote)
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
      try Self.coordinate(writing: url, options: []) { try make($0) }
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

  /// Starts renaming `url`: in its sidebar row with `inPlace` (the row's own menu), else in the Rename prompt.
  func beginRename(_ url: URL, inPlace: Bool = false) {
    // A note's name without its extension, as the sidebar shows it: the extension isn't the name's to edit (M-015).
    newName = Self.shownName(url)
    renamesInPlace = inPlace
    renaming = url
  }

  /// A note by the name the sidebar shows, without its extension ("Untitled", not "Untitled.mdenc", M-007); anything
  /// else by its file name.
  static func shownName(_ url: URL) -> String {
    !FolderLibrary.isDirectory(url) && FolderLibrary.isMarkdown(url)
      ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
  }

  /// Renames the item from `beginRename`. A markdown note keeps its extension: the name is edited without it
  /// ("Ideas" → "Ideas.mdenc"), one typed anyway isn't doubled ("Ideas.mdenc"), and any other ending is part of the
  /// name ("v1.2" → "v1.2.mdenc"), so a rename never makes an encrypted note a plain one or the other way round (M-015).
  func commitRename() {
    guard let url = renaming else { return }
    renaming = nil
    var name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    guard !name.contains("/"), !name.hasPrefix(".") else {
      error = String(localized: "“\(name)” can’t be used as a name.")
      return
    }
    if !FolderLibrary.isDirectory(url), FolderLibrary.isMarkdown(url),
      !name.lowercased().hasSuffix("." + url.pathExtension.lowercased())
    {
      name += "." + url.pathExtension
    }
    guard name != url.lastPathComponent else { return }
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
      error = String(localized: "An item named “\(target.lastPathComponent)” already exists there.")
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

  /// Moves several notes to the Trash at once, asking first on iOS like `delete(_:)`.
  func delete(_ urls: [URL]) {
    #if os(iOS)
      deletingSeveral = urls
    #else
      urls.forEach { remove($0) }
    #endif
  }

  func confirmDelete() {
    guard let url = deleting else { return }
    deleting = nil
    remove(url)
  }

  func confirmDeleteSeveral() {
    let urls = deletingSeveral
    deletingSeveral = []
    urls.forEach { remove($0) }
  }

  /// The removals still running, in order: a new note waits for them (`newNote`).
  @ObservationIgnored private var removals: Task<Void, Never>?

  /// Trashes or deletes `url` off the main thread, then updates the sidebar and the history. On the main thread the
  /// app froze for good on iOS (M-001): `trashItem` inside our coordinated write waited on the File Provider, which
  /// waited on that write. Nothing here coordinates or trashes on the main thread, and a removal that doesn't finish
  /// within `removalTimeout` is reported instead of waited for.
  private func remove(_ url: URL, permanently: Bool = false) {
    willChangeFiles()
    let previous = removals
    let task = Task { [weak self] in
      await previous?.value
      do {
        try await Self.discard(url, permanently: permanently, timeout: Self.removalTimeout)
      } catch {
        self?.error = error.localizedDescription
      }
      guard let self else { return }
      // Gone or not, the sidebar shows what's on disk.
      if !FileManager.default.fileExists(atPath: url.path) { navigator.forget(under: url) }
      library.reload()
    }
    removals = task
    Task { [weak self] in
      await task.value
      if self?.removals == task { self?.removals = nil }
    }
  }

  /// Deletes a note the user left empty. Only in the notes folder: an empty file in a project or a repository may
  /// well be meant to be there. It's deleted, not trashed: there's nothing in it to get back.
  func discardEmptyNote(_ url: URL) {
    guard isInNotesFolder(url), FileManager.default.fileExists(atPath: url.path) else { return }
    remove(url, permanently: true)
  }

  nonisolated static let removalTimeout: Duration = .seconds(15)

  nonisolated enum RemovalError: LocalizedError {
    case timedOut(String)
    var errorDescription: String? {
      switch self {
      case .timedOut(let name):
        String(localized: "“\(name)” couldn’t be deleted: the system didn’t finish in time. Try again in a moment.")
      }
    }
  }

  /// Moves `url` to the Trash, or deletes it with `permanently`, on a thread of its own. Where there's no Trash (an
  /// app's own folder on iPhone and iPad) it's deleted: the user confirmed that (`confirmDelete`). The trash isn't
  /// coordinated on iOS: the File Provider behind Files' folders (On My iPhone, iCloud Drive) coordinates it itself,
  /// and inside a coordinated write of ours it waits for that write to end, which never comes.
  nonisolated static func discard(_ url: URL, permanently: Bool, timeout: Duration) async throws {
    try await runBlocking(timeout: timeout, name: url.lastPathComponent) {
      if permanently { return try removeCoordinated(url) }
      #if os(iOS)
        do {
          try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
          try removeCoordinated(url)
        }
      #else
        try coordinate(writing: url, options: .forDeleting) {
          try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
      #endif
    }
  }

  nonisolated private static func removeCoordinated(_ url: URL) throws {
    try coordinate(writing: url, options: .forDeleting) { try FileManager.default.removeItem(at: $0) }
  }

  /// Runs `work` on a global queue and returns its result, or throws `RemovalError.timedOut` once `timeout` passes
  /// (the work goes on: a blocked call can't be stopped, but the app no longer waits for it).
  nonisolated static func runBlocking(
    timeout: Duration, name: String, _ work: @escaping @Sendable () throws -> Void
  ) async throws {
    let once = OnceFlag()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        let result = Result { try work() }
        if once.claim() { continuation.resume(with: result) }
      }
      let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
        if once.claim() { continuation.resume(throwing: RemovalError.timedOut(name)) }
      }
    }
  }

  /// True for the first caller only.
  nonisolated private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
      lock.withLock {
        defer { claimed = true }
        return !claimed
      }
    }
  }

  // MARK: - Helpers

  nonisolated private static func coordinate(
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
