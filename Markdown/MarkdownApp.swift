import MarkdownKit
import SwiftData
import SwiftUI

@main struct MarkdownApp: App {
  #if os(macOS) && DIRECT_DISTRIBUTION
    @State private var updates = UpdateChecker()
  #endif

  // macOS CLI harness: run headless probes before the UI launches. The app
  // target defaults to MainActor isolation, so the @MainActor SelfTest/
  // SmokeTest calls are direct. --selftest/--smoke exit before any window.
  // On iOS there is no CLI (the harness lives in the AppKit-only MarkdownKit stack),
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

  /// The probes drive the live sample editor, so they get it instead of the library UI.
  private static var runsProbes: Bool {
    #if os(macOS)
      ["--smoke", "--typingprobe"].contains { CommandLine.arguments.contains($0) }
    #else
      false
    #endif
  }

  /// Sidebar folders hold security-scoped bookmarks, which only resolve on this device, so the
  /// store stays local. The default configuration would mirror it to CloudKit because the app
  /// has an iCloud container, and CloudKit traps at launch without the CloudKit service.
  private static let sidebarStore: ModelContainer = {
    do {
      return try ModelContainer(
        for: SidebarFolder.self, configurations: ModelConfiguration(cloudKitDatabase: .none))
    } catch {
      fatalError("Could not open the sidebar store: \(error)")
    }
  }()

  var body: some Scene {
    WindowGroup("Markdown") {
      Group {
        if Self.runsProbes {
          MarkdownEditorView()
        } else {
          ContentView()
            .modelContainer(Self.sidebarStore)
            #if os(macOS) && DIRECT_DISTRIBUTION
              .modifier(UpdateAlerts(checker: updates))
            #endif
        }
      }
      // A minimum window size only makes sense where windows are freely resizable.
      // On iOS the scene is the screen (or a Split View/Slide Over column), and a
      // 480 pt minimum on a narrower iPhone centers the oversized content, shifting
      // it left by half the overflow and pushing toolbars past the right edge.
      #if os(macOS) || os(visionOS)
        .frame(minWidth: 480, minHeight: 360)
      #endif
    }
    .defaultSize(width: 1100, height: 760)
    #if os(macOS)
      .commands {
        TextEditingCommands()  // standard Edit menu so ⌘C/V/X/Z work
        #if DIRECT_DISTRIBUTION
          CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await updates.check(userInitiated: true) } }
          }
        #endif
      }
    #endif
  }
}
