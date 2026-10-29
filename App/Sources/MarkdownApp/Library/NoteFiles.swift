import Foundation
import VaultKit

/// Reading and writing note files, encrypted ones included.
///
/// An encrypted note is `Name.mdenc` (`EncryptedNote` in `../Vault`): its text is sealed with the vault key
/// every v57 app on the user's devices shares through iCloud Keychain, so iCloud Drive syncs it like any file
/// and Shell opens it too, while Finder, other apps and other users see only ciphertext. New notes in the notes
/// folder are encrypted unless the user turned that off; any note can be switched either way.
///
/// When two devices saved a note before seeing each other's version, iCloud Drive keeps both; the note is
/// merged line by line against the last version this device saw (`NoteConflicts`), and lines both changed stay
/// in the note between conflict markers.
enum NoteFiles {
  nonisolated static let keys: VaultKeyProvider = KeychainKeyProvider()
  nonisolated static let bases = NoteBaseCache(keys: keys)

  /// Whether new notes in the notes folder start encrypted.
  static let encryptNewNotesKey = "encryptsNewNotes"
  static var encryptsNewNotes: Bool {
    UserDefaults.standard.object(forKey: encryptNewNotesKey) as? Bool ?? true
  }

  nonisolated static func isEncrypted(_ url: URL) -> Bool { EncryptedNote.isEncrypted(url) }

  /// The text of a note, decrypted if needed. Reads plain notes as UTF-8, else in whatever encoding Foundation
  /// detects. Call inside a coordinated read.
  nonisolated static func text(at url: URL) throws -> String {
    if isEncrypted(url) {
      let data = try Data(contentsOf: url)
      return data.isEmpty ? "" : try EncryptedNote.open(data, keys: keys)
    }
    if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
    var encoding = String.Encoding.utf8
    return try String(contentsOf: url, usedEncoding: &encoding)
  }

  /// The bytes to write for `text` at `url`: sealed for an encrypted note.
  nonisolated static func data(for text: String, at url: URL) throws -> Data {
    isEncrypted(url) ? try EncryptedNote.seal(text, keys: keys) : Data(text.utf8)
  }

  /// Merges iCloud Drive's conflicting versions of a note, if any, before it's read.
  nonisolated static func resolveConflicts(at url: URL) {
    guard isUbiquitous(url) else { return }
    do {
      if let merged = try NoteConflicts.resolve(at: url, base: bases.base(for: url), keys: keys) {
        bases.setBase(merged, for: url)
      }
    } catch {
      // The versions stay; the next read tries again.
    }
  }

  /// Remembers the text as the version this device last saw in sync: the base of the next merge.
  nonisolated static func remember(_ text: String, for url: URL) {
    guard isUbiquitous(url) else { return }
    bases.setBase(text, for: url)
  }

  nonisolated private static func isUbiquitous(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
  }
}
