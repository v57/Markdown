import Foundation
import Testing

@testable import MarkdownKit

/// Links in a document open only what's safe to open at once (security audit H4).
@Suite struct LinkPolicyTests {
  @Test func webAndMailOpen() {
    #expect(MarkdownLinkPolicy.action(for: URL(string: "https://example.com/a")!) == .open)
    #expect(MarkdownLinkPolicy.action(for: URL(string: "http://example.com")!) == .open)
    #expect(MarkdownLinkPolicy.action(for: URL(string: "mailto:a@example.com")!) == .open)
  }

  @Test func otherSchemesAsk() {
    for link in ["smb://h/s", "x-apple.systempreferences:com.apple.preference.security", "shortcuts://run-shortcut?name=x",
                 "vnc://h", "ssh://h", "tel:123", "javascript:alert(1)"] {
      #expect(MarkdownLinkPolicy.action(for: URL(string: link)!) == .ask, "\(link)")
    }
  }

  @Test func launchersAreOnlyRevealed() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["a.command", "a.terminal", "a.fileloc", "a.webloc", "a.sh", "a.tool", "Some.app", "a.pkg"] {
      #expect(MarkdownLinkPolicy.action(for: folder.appendingPathComponent(name)) == .reveal, "\(name)")
    }
    // An executable file without a telling extension.
    let script = folder.appendingPathComponent("setup")
    try "#!/bin/sh\ntouch /tmp/x\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    #expect(MarkdownLinkPolicy.action(for: script) == .reveal)
    // An app bundle is a folder, but never a plain one.
    let app = folder.appendingPathComponent("Tool.app", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    #expect(MarkdownLinkPolicy.action(for: app) == .reveal)
  }

  @Test func markdownAndFoldersOpenOtherFilesAsk() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(MarkdownLinkPolicy.action(for: folder) == .open)
    #expect(MarkdownLinkPolicy.action(for: folder.appendingPathComponent("docs/setup.md")) == .open)
    #expect(MarkdownLinkPolicy.action(for: folder.appendingPathComponent("guide.pdf")) == .ask)
  }

  @Test func remoteImageSources() {
    #if canImport(AppKit) || canImport(UIKit)
      #expect(EditorTextView.isRemoteImage(URL(string: "https://tracker.example/p.png?u=alice")!))
      #expect(!EditorTextView.isRemoteImage(URL(fileURLWithPath: "/tmp/a.png")))
      #expect(!EditorTextView.isRemoteImage(URL(string: "data:image/png;base64,AAAA")!))
    #endif
  }
}

#if canImport(AppKit)
  import AppKit

  /// Opening a document requests none of its web images until the host lets them load (security audit M1).
  @MainActor @Suite struct RemoteImageTests {
    @Test func noRequestUntilAllowed() async {
      let url = URL(string: "http://127.0.0.1:9/pixel-\(UUID().uuidString).png")!
      var blocked: [Bool] = []
      let editor = EditorTextView(metrics: .standard, text: "# Note\n\n![](\(url.absoluteString))\n\nText.\n")
      editor.onRemoteImagesBlocked = { blocked.append($0) }
      editor.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
      editor.setText("# Note\n\n![](\(url.absoluteString))\n\nMore text.\n")
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(50))
      #expect(blocked.last == true)
      #expect(!MarkdownImageCache.shared.hasRequested(url))
      editor.loadsRemoteImages = true
      #expect(MarkdownImageCache.shared.hasRequested(url))
      #expect(blocked.last == false)
      MarkdownImageCache.shared.forget(url)
    }
  }
#endif
