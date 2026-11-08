// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HackerNews",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "HackerNewsCore", targets: ["HackerNewsCore"]),
        .library(name: "HackerNewsAdapters", targets: ["HackerNewsAdapters"]),
        .library(name: "HackerNewsTUI", targets: ["HackerNewsTUI"]),
        .executable(name: "hn", targets: ["hn"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.14.0"),
    ],
    targets: [
        .target(name: "HackerNewsCore"),
        .target(
            name: "HackerNewsAdapters",
            dependencies: [
                "HackerNewsCore",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ]
        ),
        .target(
            name: "HackerNewsTUI",
            dependencies: [
                "HackerNewsCore",
                "HackerNewsAdapters",
            ]
        ),
        .executableTarget(
            name: "hn",
            dependencies: [
                "HackerNewsCore",
                "HackerNewsAdapters",
                "HackerNewsTUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "HackerNewsCoreTests",
            dependencies: ["HackerNewsCore"]
        ),
        .testTarget(
            name: "HackerNewsAdaptersTests",
            dependencies: ["HackerNewsCore", "HackerNewsAdapters"]
        ),
        .testTarget(
            name: "HackerNewsTUITests",
            dependencies: ["HackerNewsCore", "HackerNewsAdapters", "HackerNewsTUI"]
        ),
    ]
)
