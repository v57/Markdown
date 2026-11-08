import Foundation

#if canImport(UniformTypeIdentifiers)
  import UniformTypeIdentifiers
#endif

/// What a clicked link may do once the host passed on it (security audit H4). A document is anyone's text — a cloned
/// README, a downloaded note, a synced or shared one — and its link text hides the target, so:
/// - `http`, `https` and `mailto` open at once;
/// - Markdown files and plain folders open as before (the host shows them, else the system does);
/// - programs, scripts and launchers (`.command`, `.terminal`, `.fileloc`, `.webloc`, apps and packages, any
///   executable file) are only revealed in Finder, never handed to LaunchServices, which would run them with no
///   Gatekeeper prompt;
/// - any other file or scheme (`smb:`, `vnc:`, `x-apple.systempreferences:`, `shortcuts:`, a PDF) asks first, naming
///   the full target and the app that would open it.
public enum MarkdownLinkPolicy {
  public enum Action: Equatable, Sendable {
    case open
    case ask
    case reveal
  }

  /// The Markdown extensions that open like a note.
  public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdenc"]

  /// File extensions that run, install or launch something when opened.
  static let launcherExtensions: Set<String> = [
    "command", "tool", "terminal", "fileloc", "webloc", "inetloc", "url", "desktop", "app", "pkg", "mpkg", "workflow",
    "action", "scpt", "scptd", "applescript", "jar", "prefpane", "saver", "kext", "osax", "plugin", "bundle",
    "mobileconfig", "shortcut", "sh", "bash", "zsh", "csh", "ksh", "fish", "exe", "bat", "cmd", "ps1", "vbs", "msi",
    "lnk", "appimage", "run", "dmg", "iso", "xpi", "crx",
  ]

  public static func action(for url: URL) -> Action {
    switch url.scheme?.lowercased() {
    case "http", "https", "mailto": .open
    case "file": fileAction(url)
    default: .ask
    }
  }

  static func fileAction(_ url: URL) -> Action {
    let ext = url.pathExtension.lowercased()
    if launcherExtensions.contains(ext) || isLauncherType(ext) { return .reveal }
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    if exists, isDirectory.boolValue { return isPackage(url) ? .reveal : .open }
    if markdownExtensions.contains(ext) { return .open }
    if exists, FileManager.default.isExecutableFile(atPath: url.path) { return .reveal }
    return .ask
  }

  private static func isLauncherType(_ ext: String) -> Bool {
    #if canImport(UniformTypeIdentifiers)
      guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
      return [UTType.executable, .script, .shellScript, .application, .applicationBundle, .internetShortcut]
        .contains { type.conforms(to: $0) }
    #else
      return false
    #endif
  }

  /// A folder the system treats as one item (an app, a bundle): opening it launches or installs.
  private static func isPackage(_ url: URL) -> Bool {
    if !url.pathExtension.isEmpty, launcherExtensions.contains(url.pathExtension.lowercased()) { return true }
    #if canImport(Darwin)
      return (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    #else
      return false
    #endif
  }
}

/// A link that needs the reader's go-ahead before it leaves the app (`MarkdownLinkPolicy.Action.ask`). A host shows
/// it in its own confirmation and calls `open()` on yes; without a host handler, the editor asks with a system alert.
public struct MarkdownLinkRequest: Identifiable {
  public let id = UUID()
  public let url: URL
  /// The app that would open it ("Preview", "Finder"), when the system names one.
  public let opener: String?
  /// What to show for the target: a file's name, else the whole URL.
  public var target: String { url.isFileURL ? url.lastPathComponent : url.absoluteString }
  public let open: @MainActor () -> Void

  public init(url: URL, opener: String?, open: @escaping @MainActor () -> Void) {
    self.url = url
    self.opener = opener
    self.open = open
  }

  /// The question, for a host without strings of its own.
  public var title: String {
    url.isFileURL ? String(localized: "Open “\(target)”?") : String(localized: "Open this link?")
  }

  public var message: String {
    let place = url.isFileURL ? url.path : url.absoluteString
    if let opener { return String(localized: "\(place) opens in \(opener).") }
    return String(localized: "\(place) opens in another app.")
  }
}
