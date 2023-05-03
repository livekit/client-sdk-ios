// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LiveKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "LiveKit",
            targets: ["LiveKit"]
        )
    ],
    dependencies: [
        .package(name: "WebRTC", url: "https://github.com/webrtc-sdk/Specs.git", .exact("104.5112.09")),
        .package(name: "SwiftProtobuf", url: "https://github.com/apple/swift-protobuf.git", .upToNextMajor(from: "1.20.2")),
        .package(name: "Promises", url: "https://github.com/google/promises.git", .upToNextMajor(from: "2.0.0")),
        .package(url: "https://github.com/apple/swift-log.git", .upToNextMajor(from: "1.4.4")),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", .upToNextMajor(from: "0.1.0"))
    ],
    targets: [
        .systemLibrary(name: "CHeaders"),
        .target(
            name: "LiveKit",
            dependencies: [
                .target(name: "CHeaders"),
                "WebRTC", "SwiftProtobuf", "Promises",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms")
            ],
            path: "Sources",
            swiftSettings: [
                // Compiler flags used to completely remove code for specific features to isolate issues.
                // Not defining the flag will turn off the feature.
                .define("LK_USING_CUSTOM_WEBRTC_BUILD")
            ]
        ),
        .testTarget(
            name: "LiveKitTests",
            dependencies: ["LiveKit"]
        )
    ]
)
