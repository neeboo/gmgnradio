// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MotionDistribution",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MotionDistribution", targets: ["MotionDistribution"]),
    ],
    targets: [
        .target(name: "MotionDistribution"),
        .testTarget(
            name: "MotionDistributionTests",
            dependencies: ["MotionDistribution"]
        ),
    ]
)
