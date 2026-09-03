// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NanoemCore",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CNanoem",
            targets: ["CNanoem"]
        ),
    ],
    targets: [
        .target(
            name: "CNanoem",
            path: "Sources/CNanoem",
            sources: [
                "nanoem/nanoem.c",
                "nanoem/ext/cfstring.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("NANOEM_ENABLE_CFSTRING"),
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .testTarget(
            name: "CNanoemTests",
            dependencies: ["CNanoem"],
            path: "Tests/CNanoemTests"
        ),
    ]
)
