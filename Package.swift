// swift-tools-version: 6.0
// VisionX Project <src@lispm.net>
// Copyright (C) 2026 I. Finder
// SPDX-License-Identifier: MIT

import PackageDescription

let package = Package(
    name: "VisionX",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "VisionXCore", targets: ["VisionXCore"]),
        .library(name: "VisionGL", targets: ["VisionGL"]),
        .library(name: "CXOrgBridge", targets: ["CXOrgBridge"])
    ],
    targets: [
        .target(
            name: "CXOrgBridge",
            path: "Sources/CXOrgBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "VisionXCore",
            dependencies: ["CXOrgBridge", "VisionGL"]
        ),
        .target(name: "VisionGL"),
        .testTarget(
            name: "VisionXCoreTests",
            dependencies: ["VisionXCore"]
        ),
        .testTarget(
            name: "VisionGLTests",
            dependencies: ["VisionGL"]
        )
    ]
)
