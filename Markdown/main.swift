import AppKit
import SwiftUI
import Md

if CommandLine.arguments.contains("--selftest") {
    SelfTest.runAndExit()   // Never
}
if CommandLine.arguments.contains("--smoke") {
    SmokeTest.schedule()    // quits after 3 s, prints SMOKE OK
}
if CommandLine.arguments.contains("--typingprobe") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { SelfTest.typingProbe() }
}
MarkdownApp.main()
