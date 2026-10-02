// swift-tools-version: 5.9
import PackageDescription

// 离线探针：用**真机那份 PMX** 在 MMDSceneKit 里建一遍节点树，回答
// "`childNode(withName:recursively:)` 到底找不找得到挂点表里那些骨名"。
//
// 为什么必须是这个探针：`tools/test-resident-prop-hold.swift` 跑的是源码文本 + stub，
// 它的 `SceneNode` 是我们自己按骨名造的，于是"真机上节点名是什么"从来没有被判过。
// 这个包只读真 PMX、只打印事实，不参与 app 构建（不在 `make test-harnesses` 里）。
let package = Package(
    name: "pmx-node-probe",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../apps/macos/Packages/MMDSceneKit"),
    ],
    targets: [
        .executableTarget(
            name: "pmx-node-probe",
            dependencies: [.product(name: "MMDSceneKit", package: "MMDSceneKit")],
            path: "Sources/pmx-node-probe"
        ),
    ]
)
