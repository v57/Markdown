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
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(name: "Md", targets: ["Md"]),
        .library(name: "MdCode", targets: ["MdCode"]),
    ],
    dependencies: [
        // swift-markdown (also an Xcode SPM dependency) — provides the Markdown module (cmark AST).
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.8.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Md",
            dependencies: ["MdCode", .product(name: "Markdown", package: "swift-markdown")],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .target(
            name: "MdCode",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "MdTests",
            dependencies: ["Md", "MdCode"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "MdCodeTests",
            dependencies: ["MdCode"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
