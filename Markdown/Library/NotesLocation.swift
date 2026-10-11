import Foundation
import Observation

/// Where the app's own notes live: the app's iCloud Drive folder ("Markdown" in Finder
/// and Files) when iCloud is available, otherwise the app's local Documents folder (on
/// iOS that is On My iPhone › Markdown in Files).
///
/// Notes are plain markdown files either way; iCloud Drive syncs them. The first time
/// iCloud is available, notes written locally before are moved into it. A file presenter
/// on the folder reports changes that arrive from other devices (and other apps), so the
/// sidebar and the open note follow them.
@Observable final class NotesLocation {
  /// The notes folder, once resolved (resolving iCloud can take a moment at launch).
  private(set) var url: URL?
  private(set) var isICloud = false
  /// Bumped when files in the folder change outside the app (sync, other apps).
  private(set) var externalChanges = 0

  @ObservationIgnored private var presenter: FolderPresenter?

  /// Resolves the folder (off the main thread: the first iCloud lookup can block) and
  /// starts watching it.
  func resolve() async {
    guard url == nil else { return }
    let (folder, iCloud) = await Task.detached(priority: .userInitiated) {
      Self.locate()
    }.value
    url = folder
    isICloud = iCloud
    let presenter = FolderPresenter(url: folder) { [weak self] in self?.externalChanges += 1 }
    NSFileCoordinator.addFilePresenter(presenter)
    self.presenter = presenter
  }

  deinit {
    if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
  }

  nonisolated private static func locate() -> (URL, Bool) {
    let fm = FileManager.default
    let local = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try? fm.createDirectory(at: local, withIntermediateDirectories: true)
    guard let container = fm.url(forUbiquityContainerIdentifier: nil) else {
      return (FolderLibrary.canonical(local), false)
    }
    let documents = container.appendingPathComponent("Documents", isDirectory: true)
    try? fm.createDirectory(at: documents, withIntermediateDirectories: true)
    moveLocalNotes(from: local, to: documents)
    return (FolderLibrary.canonical(documents), true)
  }

  /// Moves notes written while iCloud was off into iCloud Drive (`setUbiquitous`, the
  /// system's way to hand a file to iCloud). A name already taken there gets a number.
  nonisolated private static func moveLocalNotes(from local: URL, to iCloud: URL) {
    let fm = FileManager.default
    guard
      let items = try? fm.contentsOfDirectory(
        at: local, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return }
    for item in items where FolderLibrary.isDirectory(item) || FolderLibrary.isText(item) {
      let target = FileActions.availableURL(
        for: item.lastPathComponent, in: iCloud, isDirectory: FolderLibrary.isDirectory(item))
      try? fm.setUbiquitous(true, itemAt: item, destinationURL: target)
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
