// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MMDSceneKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "MMDSceneKit", targets: ["MMDSceneKit"]),
    ],
    targets: [
        .target(
            name: "MMDSceneKit",
            path: "Sources/MMDSceneKit",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "MMDSceneKitTests",
            dependencies: ["MMDSceneKit"],
            path: "Tests/MMDSceneKitTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
