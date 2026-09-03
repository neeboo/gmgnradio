// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WorldRuntime",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "WorldRuntime", targets: ["WorldRuntime"]),
    ],
    targets: [
        .target(name: "WorldRuntime"),
        .testTarget(
            name: "WorldRuntimeTests",
            dependencies: ["WorldRuntime"]
        ),
    ]
)
