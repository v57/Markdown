// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1` (in Xcode,
/// open Markdown-Local.xcworkspace instead).
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../\(name)")
}

// The editor library other repositories use (Shell, Agentus). The app is its own package in App/.
let package = Package(
  name: "Markdown",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    // The single library: shared core + AppKit stack (macOS) + UIKit stack (iOS),
    // selected by #if canImport(...) in Sources/MarkdownKit/AppKit and Sources/MarkdownKit/UIKit.
    .library(name: "MarkdownKit", targets: ["MarkdownKit"])
  ],
  dependencies: [
    // swift-markdown — provides the Markdown module (cmark AST).
    .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.8.0"),
    // The Code repo: CodeHighlighting colors fenced code blocks.
    v57("Code"),
  ],
  targets: [
    // The single target: every source under Sources/MarkdownKit/ compiles into the MarkdownKit
    // module on the host platform. Sources/MarkdownKit/AppKit is #if canImport(AppKit)-
    // guarded (macOS only); Sources/MarkdownKit/UIKit is #if canImport(UIKit)-guarded
    // (iOS only); the shared core in Sources/MarkdownKit/ is platform-neutral.
    .target(
      name: "MarkdownKit",
      dependencies: [
        .product(name: "Markdown", package: "swift-markdown"),
        .product(name: "CodeHighlighting", package: "Code"),
      ],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .testTarget(
      name: "MarkdownKitTests",
      dependencies: ["MarkdownKit", .product(name: "CodeHighlighting", package: "Code")],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
  ])

#if os(Windows) || os(Linux)
// Off Apple platforms SwiftUI is v57/SwiftUI's (MarkdownMetrics and the portable editor use it). Only here: on Apple
// platforms v57/SwiftUI (with its swift-syntax) stays out of the package graph Xcode resolves.
package.dependencies += [v57("SwiftUI")]
for target in package.targets where target.name == "MarkdownKit" {
  target.dependencies.append(.product(name: "SwiftUI", package: "SwiftUI"))
}
#endif
