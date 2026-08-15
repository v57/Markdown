import AppKit
import SwiftUI

if CommandLine.arguments.contains("--selftest") {
    SelfTest.runAndExit()   // Never
}
if CommandLine.arguments.contains("--smoke") {
    SmokeTest.schedule()    // quits after 3 s, prints SMOKE OK
}
MarkdownApp.main()
