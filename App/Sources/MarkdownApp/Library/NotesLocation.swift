import Foundation
import Observation
import VaultKit

/// Where the window's account's notes live, and how they sync.
///
/// The notes sync through the vault (`../Vault`): CloudKit, encrypted, no iCloud Drive needed, shared with Shell.
/// On each device they are also real files in a local folder (`NotesMirror` keeps the two the same both ways), so
/// Finder, Files, other editors and git work on them. The folder is the app's Documents (on iOS: On My iPhone ›
/// Markdown in Files) unless the user picked another one on the Mac (Choose Notes Folder…). Another vault account's
/// notes mirror its own vault into a folder of their own (`AccountStorage`).
///
/// Notes kept in the app's iCloud Drive folder by earlier versions are copied in once; the originals stay. A file
/// presenter on the folder reports changes (the mirror's writes, other apps), so the sidebar and the open note
/// follow them.
@Observable final class NotesLocation {
  /// The notes folder, once resolved.
  private(set) var url: URL?
  /// Whether the notes sync through iCloud (signed in, and the app has the vault's CloudKit container).
  private(set) var isICloud = false
  /// Bumped when files in the folder change outside the editor (sync, other apps).
  private(set) var externalChanges = 0
  /// The mirror's last problem, if any.
  var syncError: String? { mirror?.lastError }

  @ObservationIgnored private var presenter: FolderPresenter?
  @ObservationIgnored private var mirror: NotesMirror?
  @ObservationIgnored private var scopedFolder: URL?
  /// The window's account (`VaultAccountScope`).
  @ObservationIgnored private let vault: Vault

  private static let importedKey = "ImportedICloudDriveNotes"
  /// The chosen folder's bookmark, kept per account on this device.
  private var bookmarkKey: String { AccountStorage.key("NotesFolderBookmark", for: vault) }

  init(vault: Vault) {
    self.vault = vault
  }

  /// Resolves the folder, starts mirroring it, and imports the old iCloud Drive notes once.
  func resolve() async {
    guard url == nil else { return }
    // The screenshot demo's notes: no bookmark, no mirror, no import.
    if ScreenshotDemo.isOn {
      url = FolderLibrary.canonical(ScreenshotDemo.notes)
      return
    }
    use(chosenFolder() ?? AccountStorage.defaultNotesFolder(for: vault))
    isICloud = FileManager.default.ubiquityIdentityToken != nil && CloudSync.isEntitled
    // The iCloud Drive notes came before accounts: they are Personal's.
    if vault.isPersonal, !UserDefaults.standard.bool(forKey: Self.importedKey), let folder = url {
      await Task.detached(priority: .utility) { Self.importICloudDriveNotes(into: folder) }.value
      UserDefaults.standard.set(true, forKey: Self.importedKey)
      mirror?.scheduleReconcile(after: 0)
    }
  }

  /// Moves the notes to a folder the user picked: the notes are written there; the old folder keeps its files.
  func choose(_ folder: URL) {
    if let bookmark = try? folder.bookmarkData(options: Self.bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
      UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }
    use(folder)
  }

  private func use(_ folder: URL) {
    stop()
    if folder.startAccessingSecurityScopedResource() { scopedFolder = folder }
    let canonical = FolderLibrary.canonical(folder)
    url = canonical
    let presenter = FolderPresenter(url: canonical) { [weak self] in self?.externalChanges += 1 }
    NSFileCoordinator.addFilePresenter(presenter)
    self.presenter = presenter
    guard let store = vault.store else { return }
    // Every account seals with the vault keys (`NoteFiles.keys`); its notes are its own vault's.
    let mirror = NotesMirror(
      folder: canonical, store: store, keys: NoteFiles.keys,
      stateDirectory: AccountStorage.directory(for: vault).appendingPathComponent("NotesMirror", isDirectory: true))
    mirror.didChangeFiles = { [weak self] in
      MainActor.assumeIsolated { self?.externalChanges += 1 }
    }
    mirror.start()
    self.mirror = mirror
  }

  private func stop() {
    mirror?.stop()
    mirror = nil
    if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
    presenter = nil
    scopedFolder?.stopAccessingSecurityScopedResource()
    scopedFolder = nil
  }

  deinit {
    if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
  }

  #if os(macOS)
    private static let bookmarkOptions: URL.BookmarkCreationOptions = .withSecurityScope
    private static let resolveOptions: URL.BookmarkResolutionOptions = .withSecurityScope
  #else
    private static let bookmarkOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
  #endif

  private func chosenFolder() -> URL? {
    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
    var isStale = false
    return try? URL(resolvingBookmarkData: data, options: Self.resolveOptions, relativeTo: nil, bookmarkDataIsStale: &isStale)
  }

  /// Copies the notes earlier versions kept in the app's iCloud Drive folder into the notes folder, where the
  /// mirror makes them vault notes. Files already there (same path) are skipped.
  nonisolated private static func importICloudDriveNotes(into folder: URL) {
    let fileManager = FileManager.default
    guard let container = fileManager.url(forUbiquityContainerIdentifier: VaultConfiguration.notesContainer) else { return }
    let documents = container.appendingPathComponent("Documents", isDirectory: true)
    guard
      let enumerator = fileManager.enumerator(
        at: documents, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    else { return }
    let root = documents.standardizedFileURL.resolvingSymlinksInPath().path
    for case let url as URL in enumerator {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
      let path = url.standardizedFileURL.resolvingSymlinksInPath().path
      guard path.hasPrefix(root + "/") else { continue }
      let target = folder.appendingPathComponent(String(path.dropFirst(root.count + 1)))
      guard !fileManager.fileExists(atPath: target.path) else { continue }
      var error: NSError?
      // Coordinated: a file iCloud hasn't downloaded is fetched first.
      NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { source in
        guard let data = try? Data(contentsOf: source) else { return }
        try? fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: target, options: .withoutOverwriting)
      }
    }
  }
}

/// Calls `onChange` (debounced, on the main actor) when anything inside `url` changes
/// through a coordinated write by another process — iCloud sync, Finder, other editors.
nonisolated final class FolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue = OperationQueue()
  private let onChange: @MainActor () -> Void
  private var pending = false
  private let lock = NSLock()

  init(url: URL, onChange: @escaping @MainActor () -> Void) {
    presentedItemURL = url
    self.onChange = onChange
    presentedItemOperationQueue.maxConcurrentOperationCount = 1
  }

  func presentedSubitemDidChange(at url: URL) { changed() }
  func presentedSubitemDidAppear(at url: URL) { changed() }
  func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed() }
  // The completion-handler form: the async one crashes the Swift 6.4 compiler.
  func accommodatePresentedSubitemDeletion(
    at url: URL, completionHandler: @escaping @Sendable (Error?) -> Void
  ) {
    changed()
    completionHandler(nil)
  }

  /// Many events arrive together during a sync: report them once.
  private func changed() {
    lock.lock()
    defer { lock.unlock() }
    guard !pending else { return }
    pending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
      lock.lock()
      pending = false
      lock.unlock()
      MainActor.assumeIsolated { onChange() }
    }
  }
}
