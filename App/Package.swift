// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// Another v57 repository: GitHub's main branch, or the checkout next to this repository with `V57_LOCAL=1` (in
/// Xcode, open Markdown-Local.xcworkspace instead).
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../../\(name)")
}

/// This repository's kits, the package at "..": SwiftPM names a path dependency after its folder, which is Markdown in
/// the main checkout and the worktree's own name in a worktree.
let kits = String(Context.packageDirectory.split(whereSeparator: { $0 == "/" || $0 == "\\" }).dropLast().last ?? "Markdown")

// The Markdown app, all of it but the bundle: Markdown.xcodeproj (at the repository's root) builds
// Sources/MarkdownEditor/MarkdownMain.swift into Markdown.app with Resources (the icon, Info.plist, entitlements and
// privacy manifest) and links MarkdownApp; on Linux and Windows the MarkdownEditor target below does. Its own package,
// so the repositories that use MarkdownKit (the package at ..) don't get the app's dependencies.
let package = Package(
  name: "MarkdownApp",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    .library(name: "MarkdownApp", targets: ["MarkdownApp"])
  ],
  dependencies: [
    // This repository's editor library.
    .package(path: ".."),
    // The shared design, in-app updates, screenshot scenes, the vault and GitHub (GitHubKit).
    v57("Component"), v57("UpdateKit"), v57("Dev"), v57("Vault"), v57("Git"),
  ],
  targets: [
    .target(
      name: "MarkdownApp",
      dependencies: [
        .product(name: "MarkdownKit", package: kits), .product(name: "ComponentKit", package: "Component"),
        // In-app updates only for the Mac's direct download and on Windows.
        .product(name: "UpdateKit", package: "UpdateKit", condition: .when(platforms: [.macOS, .windows])),
        .product(name: "DevScreenshots", package: "Dev"), .product(name: "VaultKit", package: "Vault"),
        .product(name: "VaultUI", package: "Vault"), .product(name: "GitHubKit", package: "Git"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
        .enableUpcomingFeature("MemberImportVisibility"),
      ])
  ])

#if os(Windows) || os(Linux)
// Off Apple platforms SwiftUI and SwiftData are v57/SwiftUI's. Only here: on Apple platforms the app uses Apple's
// SwiftUI, and v57/SwiftUI (with its swift-syntax) stays out of the package graph Xcode resolves.
package.dependencies += [v57("SwiftUI")]
#if os(Windows)
// On Apple platforms `import Foundation` brings Combine (ObservableObject, @Published), URLSession and the file APIs
// SwiftUIPortability adds along: every file gets them here too.
let appModules = ["Combine", "FoundationNetworking", "SwiftUIPortability"]
#else
// … and `import SwiftUI` brings Observation.
let appModules = ["Combine", "FoundationNetworking", "Observation", "SwiftUIPortability"]
#endif
let appSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .unsafeFlags(appModules.flatMap { ["-Xfrontend", "-import-module", "-Xfrontend", $0] }),
]
for target in package.targets where target.name == "MarkdownApp" {
  target.dependencies += [
    .product(name: "SwiftUI", package: "SwiftUI"), .product(name: "SwiftData", package: "SwiftUI"),
    .product(name: "SwiftUIPortability", package: "SwiftUI"),
  ]
  target.swiftSettings = appSettings
}
// The entry point, Sources/MarkdownEditor/MarkdownMain.swift, which the Xcode project builds on Apple platforms. Its
// target is MarkdownEditor (the Xcode target's module name too), not Markdown: swift-markdown, in the graph through
// MarkdownKit, already has a Markdown module and product.
#if os(Windows)
// The app: a DLL the SwiftUI WinUI host loads (SwiftUI's Windows/scripts/build-app.ps1 -PackagePath <this package>
// -Product MarkdownWinUI).
package.targets.append(
  .target(
    name: "MarkdownEditor", dependencies: ["MarkdownApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: appSettings))
package.products.append(.library(name: "MarkdownWinUI", type: .dynamic, targets: ["MarkdownEditor"]))
#elseif os(Linux)
// The app on SwiftUI's GTK backend (in App/: V57_LOCAL=1 swift build --product MarkdownEditor).
package.targets.append(
  .executableTarget(
    name: "MarkdownEditor", dependencies: ["MarkdownApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: appSettings))
package.products.append(.executable(name: "MarkdownEditor", targets: ["MarkdownEditor"]))
#endif
#endif
