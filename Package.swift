// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "Markdown",
  platforms: [
    // Match the app target (MACOSX_DEPLOYMENT_TARGET = 27.0). The macOS 26+ SDK
    // marks AppKit's NSLayoutManager/NSTextView methods @MainActor; targeting an
    // older platform would compile them as nonisolated and break the overrides.
    .macOS(.v27),
    // iOS support: the UIKit alternative editor stack (Sources/Md/UIKit) builds
    // on iOS 17+.
    .iOS(.v17),
  ],
  products: [
    // The single library: shared core + AppKit stack (macOS) + UIKit stack (iOS),
    // selected by #if canImport(...) in Sources/Md/AppKit and Sources/Md/UIKit.
    .library(name: "Md", targets: ["Md"])
  ],
  dependencies: [
    // swift-markdown (also an Xcode SPM dependency) — provides the Markdown module (cmark AST).
    .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.8.0")
  ],
  targets: [
    // The single target: every source under Sources/Md/ compiles into the Md
    // module on the host platform. Sources/Md/AppKit is #if canImport(AppKit)-
    // guarded (macOS only); Sources/Md/UIKit is #if canImport(UIKit)-guarded
    // (iOS only); the shared core in Sources/Md/ is platform-neutral.
    .target(
      name: "Md", dependencies: [.product(name: "Markdown", package: "swift-markdown")],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .testTarget(
      name: "MdTests", dependencies: ["Md"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
  ])
