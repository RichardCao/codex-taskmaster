// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CodexTaskmaster",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TaskMasterCoreLib",
            targets: ["TaskMasterCoreLib"]
        )
    ],
    targets: [
        .target(
            name: "TaskMasterCoreLib",
            path: ".",
            sources: ["TaskMasterCore.swift"]
        ),
        .testTarget(
            name: "TaskMasterCoreLibTests",
            dependencies: ["TaskMasterCoreLib"],
            path: "tests/TaskMasterCoreLibTests"
        )
    ]
)
