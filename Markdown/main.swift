import AppKit
import SwiftUI
import Md

// Top-level code is nonisolated; the Md harness types are @MainActor. The app's
// entry point runs on the main thread, so assumeIsolated is safe here.
if CommandLine.arguments.contains("--selftest") {
    MainActor.assumeIsolated { SelfTest.runAndExit() }   // Never
}
if CommandLine.arguments.contains("--smoke") {
    MainActor.assumeIsolated { SmokeTest.schedule() }    // quits after 3 s, prints SMOKE OK
}
if CommandLine.arguments.contains("--typingprobe") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { MainActor.assumeIsolated { SelfTest.typingProbe() } }
}
MarkdownApp.main()
