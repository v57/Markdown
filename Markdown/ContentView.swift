import Md
import SwiftUI

@main struct MarkdownApp: App {
  // macOS CLI harness: run headless probes before the UI launches. The app
  // target defaults to MainActor isolation, so the @MainActor SelfTest/
  // SmokeTest calls are direct. --selftest/--smoke exit before any window.
  // On iOS there is no CLI (the harness lives in the AppKit-only Md stack),
  // so the init body compiles to nothing there.
  init() {
    #if os(macOS)
      if CommandLine.arguments.contains("--selftest") {
        SelfTest.runAndExit()  // Never
      }
      if CommandLine.arguments.contains("--smoke") {
        SmokeTest.schedule()  // quits after 3 s, prints SMOKE OK
      }
      if CommandLine.arguments.contains("--typingprobe") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { SelfTest.typingProbe() }
      }
    #endif
  }

  var body: some Scene {
    WindowGroup("Markdown") { MarkdownEditorView().frame(minWidth: 480, minHeight: 360) }
      .defaultSize(width: 900, height: 700)#if os(macOS)
        .commands { TextEditingCommands() }  // standard Edit menu so ⌘C/V/X/Z work
      #endif
  }
}
