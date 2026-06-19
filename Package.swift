// swift-tools-version: 6.2
// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import PackageDescription

let package = Package(
    name: "TraversioMosh",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "TraversioMoshCore",
            targets: ["TraversioMoshCore"]
        ),
        .library(
            name: "TraversioMoshTransport",
            targets: ["TraversioMoshTransport"]
        ),
        .library(
            name: "TraversioMoshWire",
            targets: ["TraversioMoshWire"]
        ),
        .library(
            name: "TraversioMoshCrypto",
            targets: ["TraversioMoshCrypto"]
        ),
        .library(
            name: "TraversioMoshBootstrap",
            targets: ["TraversioMoshBootstrap"]
        ),
    ],
    targets: [
        .target(
            name: "TraversioMoshCrypto"
        ),
        .target(
            name: "TraversioMoshWire"
        ),
        .target(
            name: "TraversioMoshTransport"
        ),
        .target(
            name: "TraversioMoshBootstrap",
            dependencies: ["TraversioMoshCrypto"]
        ),
        .target(
            name: "TraversioMoshCore",
            dependencies: [
                "TraversioMoshCrypto",
                "TraversioMoshTransport",
                "TraversioMoshWire",
            ]
        ),
        .testTarget(
            name: "TraversioMoshTests",
            dependencies: [
                "TraversioMoshBootstrap",
                "TraversioMoshCrypto",
            ]
        ),
    ]
)
