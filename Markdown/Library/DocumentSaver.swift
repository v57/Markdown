import Foundation
import Observation

/// Saves the open document's edits back to its file.
///
/// Edits are written a moment after typing pauses (`delay`), and immediately on `flush()`
/// — which the document view calls before switching files, reloading, going to the
/// background or quitting — so nothing typed is lost and disk writes stay infrequent.
/// Writes are coordinated (`NSFileCoordinator`) and atomic: another app reading the file
/// never sees half a document, and the code is ready for iCloud-backed folders.
@Observable final class DocumentSaver {
  enum State: Equatable {
    case saved
    case unsaved
    /// The last save failed. `permissionDenied`: the app only has read access to the
    /// folder (it was added before editing existed) — access can be granted again.
    case failed(String, permissionDenied: Bool)
  }

  private(set) var state: State = .saved
  /// The file edits go to; changing it saves anything pending for the previous file.
  @ObservationIgnored private(set) var file: URL?
  @ObservationIgnored private var pending: String?
  @ObservationIgnored private var lastWritten: String?
  @ObservationIgnored private var timer: Task<Void, Never>?
  @ObservationIgnored var delay: Duration = .milliseconds(600)

  /// Starts tracking `file`, whose content on disk is `text`.
  func open(_ file: URL, text: String) {
    if file != self.file { flush() }
    self.file = file
    lastWritten = text
    pending = nil
    state = .saved
  }

  /// The editor's full text after an edit.
  func edited(_ text: String) {
    guard file != nil else { return }
    pending = text
    if text == lastWritten {
      pending = nil
      if state == .unsaved { state = .saved }
      return
    }
    state = .unsaved
    timer?.cancel()
    timer = Task { [weak self, delay] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }

  /// Writes pending edits now.
  func flush() {
    timer?.cancel()
    timer = nil
    guard let file, let text = pending else { return }
    do {
      try Self.write(text, to: file)
      pending = nil
      lastWritten = text
      state = .saved
    } catch {
      let denied = Self.isPermissionDenied(error)
      state = .failed(Self.message(for: error, file: file, denied: denied), permissionDenied: denied)
    }
  }

  /// A permission failure means the app was only given read access to the folder
  /// (folders added before editing existed keep that through their bookmark).
  private static func message(for error: Error, file: URL, denied: Bool) -> String {
    guard denied else { return error.localizedDescription }
    return
      "Markdown only has read access to the folder containing “\(file.lastPathComponent)”. Allow editing to save your changes."
  }

  private static func isPermissionDenied(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError { return true }
    if ns.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(ns.code) { return true }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
      return isPermissionDenied(underlying)
    }
    return false
  }

  /// Whether `text` (just read from disk) is what this saver last wrote or still holds —
  /// i.e. reloading it would not change anything the user sees.
  func isCurrent(_ text: String, for file: URL) -> Bool {
    file == self.file && (text == lastWritten || text == pending)
  }

  nonisolated static func write(_ text: String, to url: URL) throws {
    var coordinationError: NSError?
    var writeError: Error?
    NSFileCoordinator().coordinate(
      writingItemAt: url, options: .forReplacing, error: &coordinationError
    ) { target in
      do {
        try Data(text.utf8).write(to: target, options: .atomic)
      } catch {
        writeError = error
      }
    }
    if let error = coordinationError ?? writeError { throw error }
  }
}
