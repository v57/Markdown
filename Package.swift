// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "Markdown",
  platforms: [
    .macOS(.v12),
    .iOS(.v15),
  ],
  products: [
    // The single library: shared core + AppKit stack (macOS) + UIKit stack (iOS),
    // selected by #if canImport(...) in Sources/MarkdownKit/AppKit and Sources/MarkdownKit/UIKit.
    .library(name: "MarkdownKit", targets: ["MarkdownKit"])
  ],
  dependencies: [
    // swift-markdown (also an Xcode SPM dependency) — provides the Markdown module (cmark AST).
    .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.8.0")
  ],
  targets: [
    // The single target: every source under Sources/MarkdownKit/ compiles into the MarkdownKit
    // module on the host platform. Sources/MarkdownKit/AppKit is #if canImport(AppKit)-
    // guarded (macOS only); Sources/MarkdownKit/UIKit is #if canImport(UIKit)-guarded
    // (iOS only); the shared core in Sources/MarkdownKit/ is platform-neutral.
    .target(
      name: "MarkdownKit", dependencies: [.product(name: "Markdown", package: "swift-markdown")],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .testTarget(
      name: "MarkdownKitTests", dependencies: ["MarkdownKit"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
  ])
