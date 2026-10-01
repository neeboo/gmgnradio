// 「摆正 + 靠墙」的离线判据（不启动 app、不碰网络）。
//
// 两件事各自独立可断言：
//   A. **摆正**：生成服务交回来的网格不保证立着，入库时必须把它摆正（真机那把剑的真实尺寸）。
//   B. **靠墙**：竖直面从**既有几何**派生（真实舱体的 collider.glb），背朝墙的候选落点
//      交给**既有那一条**判定通路验；插进墙里的候选必须被拒。
//
// 这里刻意**不抽 App 源码**（只用 WorldRuntime + 资源里的真实几何），
// 因为这两件事的判据全在 WorldRuntime 里；App 侧的接线由其它 harness 看着。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let worldRoot = root.appendingPathComponent("apps/macos/Resources/Worlds/marble-living-cabin")
guard FileManager.default.fileExists(atPath: worldRoot.appendingPathComponent("collider.glb").path) else {
    print("FAIL: 缺少真实舱体几何 apps/macos/Resources/Worlds/marble-living-cabin/collider.glb")
    exit(1)
}

// ---- 接线判据（纯文本，生产源码）--------------------------------------------
//
// 摆正旋转只有**一个出口**（`WorldGeneratedProp.orientationRotation`），四个消费者都必须读它：
// 渲染矩阵、碰撞代理、手持姿态、以及入库那一处。这里逐条钉住"接线还在" ——
// 任何人只要把其中**一处**改成自己算，`同源` 这一条就会 FAIL。
func source(_ relative: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
}
func require(_ condition: Bool, _ message: String) {
    guard condition else { print("FAIL: \(message)"); exit(1) }
}
func declaration(_ text: String, _ signature: String) -> String {
    guard let start = text.range(of: signature)?.lowerBound,
          let open = text[start...].firstIndex(of: "{") else { return "" }
    var depth = 0
    for index in text[open...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    return ""
}
let layoutSource = try source("apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldPropLayout.swift")
require(layoutSource.contains("orientation: prop.orientation"),
        "碰撞代理必须与模型共用同一份摆正旋转（WorldGeneratedProp.generatedCollisionObstacle）")
require(layoutSource.contains("public var orientationRotation: WorldQuaternion"),
        "摆正旋转必须只有一个出口 orientationRotation")
let descriptorSource = try source("apps/macos/Sources/GMGNRadio/Presence/WishMachineOutputDescriptor.swift")
require(descriptorSource.contains("orientation: WorldQuaternion = .identity"),
        "渲染描述符必须携带资产级摆正旋转（缺省 = 单位四元数 ⇒ 老路径逐字节不变）")
let matrixSource = declaration(descriptorSource, "static func transform(minimum: SIMD3<Float>")
require(matrixSource.contains("orientation") && matrixSource.contains("orientedBounds"),
        "摆放矩阵必须按**转正后**的包围盒归一（否则躺着的网格会被按原始 Y 跨度缩放）")
let rendererSource = try source("apps/macos/Sources/GMGNRadio/Presence/ResidentPropRenderer.swift")
let renderBody = declaration(rendererSource, "func render(commandBuffer: MTLCommandBuffer")
require(renderBody.contains("orientation:item.orientation"),
        "渲染路径必须把描述符里的摆正旋转喂给矩阵（只喂给 prepare 不算：画面仍会是躺着的）")
require(rendererSource.contains("rotation: item.orientation"), "prepare 也按转正后的高度量")
let attachmentSource = try source("apps/macos/Sources/GMGNRadio/Presence/PropAttachment.swift")
require(attachmentSource.contains("let orientation = descriptor.orientation"),
        "手持姿态必须读同一份摆正旋转（否则同一件东西'地上立着、手里躺着'）")
let appSource = try source("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift")
let registration = declaration(appSource, "private func synchronizeOwnedResidentProps()")
require(registration.contains("WorldPropOrientationPolicy.resolve("),
        "摆正必须发生在**入库那一处**")
require(registration.contains("let sourceExtent = orientedExtent"),
        "尺寸策略必须吃**转正后**的包围盒（摆正先于尺寸）")
require(registration.contains("orientation: orientation.shouldArchive ? orientation : nil"),
        "摆正结果必须进存档（立着的资产不写这个键）")
require(appSource.contains("orientation: asset.prop.orientationRotation"),
        "已摆物件的渲染描述符必须读物件元数据里的那一份摆正旋转")
require(appSource.contains("targetHeightMeters: prop.effectiveSize.y"),
        "渲染目标高度仍然只有 effectiveSize 一个出口")

let harness = #"""
import Foundation
import WorldRuntime
import simd

struct Config: Decodable {
    struct Framing: Decodable { let origin: [Float]; let scale: Float }
    let framing: Framing
}

@main struct Test {
    static func main() throws {
        var count = 0
        func check(_ ok: Bool, _ message: String) {
            count += 1
            guard ok else { print("FAIL: \(message)"); exit(1) }
        }

        // =====================================================================
        // A. 摆正
        // =====================================================================
        // 真机那把「2B 白色长剑（外形摆件）」的真实尺寸（GLB 字节级重算，与
        // test-resident-prop-size.swift 同一组数）：长 × 高 × 厚。
        let sword = WorldVector3(x: 1.005432426929474, y: 0.1334928721189499, z: 0.05656638368964195)
        let orientation = WorldPropOrientationPolicy.resolve(sourceExtent: sword)
        check(orientation.source == .inferredPrincipalAxis,
              "躺着生成的网格必须被主轴判据认出来（实测 \(orientation.source)）")
        check(!orientation.isIdentity && orientation.notice != nil, "摆了就要说")
        let oriented = WorldPropOrientationPolicy.orientedExtent(of: sword, by: orientation)
        check(oriented.y >= oriented.x && oriented.y >= oriented.z && abs(oriented.y - 1.0054324) < 1e-4,
              "摆正后必须**立着**：最长边在 Y 轴（实测 \(oriented)）")
        guard let sized = WorldPropSizePolicy.automatic(sourceExtent: oriented, requestedHeight: 1.1) else {
            print("FAIL: 摆正后的尺寸算不出来"); exit(1)
        }
        check(sized.basis == .height && abs(sized.size.y - 1.1) < 1e-3,
              "1.1 m 的请求 ⇒ 一把立着的 1.1 m 剑（实测 \(sized.size)，basis=\(sized.basis)）")

        // 不瞎掰：说不出话就**保留原样** + 可见说明。
        let ambiguous = WorldPropOrientationPolicy.resolve(
            sourceExtent: WorldVector3(x: 0.55, y: 0.35, z: 0.4))
        check(ambiguous.source == .unresolved && ambiguous.isIdentity && ambiguous.notice != nil,
              "朝向无法确定时必须保留原样并留下说明（实测 \(ambiguous.source) identity=\(ambiguous.isIdentity)）")
        let upright = WorldPropOrientationPolicy.resolve(
            sourceExtent: WorldVector3(x: 0.3, y: 0.42, z: 0.4))
        check(upright.source == .alreadyUpright && upright.notice == nil,
              "本来就立着的资产不该被改动、也不该每次都弹说明")

        // 存档同源：摆正旋转只有一份（物件元数据），解码回来逐位相同。
        let prop = WorldGeneratedProp(
            objectID: "wish-prop-sword", sourceWishID: "wish", assetID: "sha256:sword",
            displayName: "2B 白色长剑", size: sized.size, sourceHeight: oriented.y,
            orientation: orientation)
        let encoded = try JSONEncoder().encode(prop)
        let decoded = try JSONDecoder().decode(WorldGeneratedProp.self, from: encoded)
        check(decoded.orientationRotation == prop.orientationRotation, "存档里的摆正旋转必须原样回来")
        check(decoded.effectiveSize == prop.effectiveSize && decoded.isOrientationNormalized,
              "尺寸与朝向都只有一份出口（effectiveSize / orientationRotation）")
        let plain = String(decoding: try JSONEncoder().encode(WorldGeneratedProp(
            objectID: "o", sourceWishID: "w", assetID: "a", displayName: "n",
            size: sized.size, sourceHeight: oriented.y)), as: UTF8.self)
        check(!plain.contains("orientation"), "立着的资产不得多写这个键（老元数据逐字节不变）")

        // =====================================================================
        // B. 靠墙（真实舱体几何）
        // =====================================================================
        let resources = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin")
        let manifest = try JSONDecoder().decode(
            WorldManifest.self, from: Data(contentsOf: resources.appendingPathComponent("world.json")))
        let config = try JSONDecoder().decode(
            Config.self, from: Data(contentsOf: resources.appendingPathComponent("marble.json")))
        let origin = SIMD3<Float>(config.framing.origin[0], config.framing.origin[1], config.framing.origin[2])
        let triangles = try GLBColliderDecoder().decode(
            data: Data(contentsOf: resources.appendingPathComponent("collider.glb")),
            transform: WorldMeshTransform(axisConversion: .flipYAndZ, origin: origin,
                                          uniformScale: config.framing.scale))
        let mesh = TriangleMeshCollisionWorld(triangles: triangles)
        let derivation = PropSupportDerivationWorld(
            base: mesh, topVolumes: manifest.collisionVolumes.filter(\.isBlocking))

        let parameters = PropSupportGridParameters()
        let positions = manifest.waypoints.filter(\.enabled).map(\.position)
        var minimumX = positions[0].x, maximumX = positions[0].x
        var minimumZ = positions[0].z, maximumZ = positions[0].z
        for p in positions {
            minimumX = min(minimumX, p.x); maximumX = max(maximumX, p.x)
            minimumZ = min(minimumZ, p.z); maximumZ = max(maximumZ, p.z)
        }
        let margin = parameters.spacing + parameters.capsuleRadius
        let bounds = WorldPlanarBounds(minimumX: minimumX - margin, maximumX: maximumX + margin,
                                       minimumZ: minimumZ - margin, maximumZ: maximumZ + margin)
        let grid = PropSupportGridBuilder.build(
            collision: derivation, bounds: bounds, seed: manifest.spawn.position, parameters: parameters)
        check(grid.report.seeded && !grid.layers.isEmpty,
              "真实舱体的承托网格必须派生出来（层=\(grid.layers.count)）")

        let wallTriangles = derivation.triangles(in: bounds)
        let walls = WorldPropWallGrid.derive(triangles: wallTriangles, bounds: bounds, grid: grid)
        print("INFO 真实舱体：承托层 \(grid.layers.count)，竖直面 \(walls.count)")
        check(!walls.isEmpty, "真实舱体里必须派生得出**竖直面**（否则'靠墙'无从谈起）")
        for wall in walls.prefix(5) {
            check(wall.isValid, "墙面必须合法：\(wall.id)")
            check(!wall.columns.isEmpty, "墙面必须挨着至少一列格子：\(wall.id)")
        }
        // 顺序确定：同一份几何派生两次必须逐项相同。
        check(walls == WorldPropWallGrid.derive(triangles: wallTriangles, bounds: bounds, grid: grid),
              "墙面派生必须确定（同一份几何 ⇒ 同一批墙面）")

        // 真机那台咖啡机（与 test-resident-prop-grid-placement.swift 同一份尺寸）。
        let coffee = WorldVector3(x: 0.35069498, y: 0.41999996, z: 0.56627256)
        let blocking = manifest.collisionVolumes.filter(\.isBlocking)
        func reason(_ candidate: WorldPropWallAttachment) -> PropSupportBlockReason? {
            PropPlacementEvaluator.evaluate(
                footprint: WorldPlanarFootprint(size: SIMD2(coffee.x, coffee.z), yaw: candidate.yaw),
                height: coffee.y,
                at: candidate.layer,
                grid: grid,
                collision: derivation,
                blockingVolumes: blocking
            )
        }
        var accepted: WorldPropWallAttachment?
        var visited = 0
        outer: for wall in walls {
            for candidate in WorldPropWallGrid.candidateAttachments(patch: wall, grid: grid, size: coffee)
                .prefix(12) {
                visited += 1
                if reason(candidate) == nil { accepted = candidate; break outer }
            }
        }
        guard let acceptance = accepted else {
            print("FAIL: 真实舱体上，咖啡机在 \(visited) 个靠墙候选里一个都放不下")
            exit(1)
        }
        let normal = SIMD2<Float>(acceptance.patch.normal.x, acceptance.patch.normal.y)
        // 背面必须朝墙：本地 +Z（正面）转到外法线 ⇒ Ry(yaw)·ẑ == n。
        let facing = SIMD2<Float>(sin(acceptance.yaw), cos(acceptance.yaw))
        check(abs(facing.x - normal.x) < 1e-4 && abs(facing.y - normal.y) < 1e-4,
              "正面必须朝房间（外法线），背面才贴着墙（实测 facing=\(facing) normal=\(normal)）")
        // 背面（中心 - 半深·n）离墙面的距离必须在一格之内（承托网格剔除了贴墙一圈，
        // 所以"最贴墙"也就是最近的**可放**格）。
        let backOffset = (acceptance.position.x - acceptance.patch.coordinate) * normal.x
            + (acceptance.position.z - acceptance.patch.coordinate) * normal.y
        let backToWall = backOffset - coffee.z / 2
        print("INFO 靠墙落点：墙=\(acceptance.patch.id) 背面离墙 \(backToWall) m（格距 \(grid.spacing)，即 \(backToWall / grid.spacing) 格）")
        check(backToWall >= -1e-4,
              "背面必须在**房间一侧**（绝不嵌进墙里，实测 \(backToWall) m）")
        check(backToWall <= Float(WorldPropWallGrid.maximumAnchorDepth) * grid.spacing + 1e-4,
              "背面最多退 \(WorldPropWallGrid.maximumAnchorDepth) 格（实测 \(backToWall) m）")
        // 诊断：这一面墙上"离墙由近到远"的候选各自被怎么判的（贴墙那几格为什么放不下）。
        for (index, candidate) in WorldPropWallGrid
            .candidateAttachments(patch: acceptance.patch, grid: grid, size: coffee)
            .prefix(6).enumerated() {
            let back = (candidate.position.x - acceptance.patch.coordinate) * normal.x
                + (candidate.position.z - acceptance.patch.coordinate) * normal.y - coffee.z / 2
            print("INFO 候选[\(index)] 背面离墙 \(back) m ⇒ \(reason(candidate).map(\.errorDescription) ?? "可放")")
        }

        // **注入"允许穿墙"**：把同一个盒子沿外法线往墙里推 5 厘米 ⇒ 判据必须拒绝。
        func volume(into wallDepth: Float) -> WorldCollisionVolume {
            // `wallDepth` = 把这个盒子沿外法线往墙里推多少米。0 ⇒ 就是那个被接受的候选。
            let centreX = acceptance.position.x - normal.x * wallDepth
            let centreZ = acceptance.position.z - normal.y * wallDepth
            let yaw = acceptance.yaw
            return WorldCollisionVolume(
                id: "probe",
                center: WorldVector3(x: centreX, y: acceptance.layer.supportHeight + coffee.y / 2, z: centreZ),
                halfExtents: WorldVector3(x: coffee.x / 2, y: coffee.y / 2, z: coffee.z / 2),
                rotation: WorldQuaternion(x: 0, y: sin(yaw / 2), z: 0, w: cos(yaw / 2)),
                isBlocking: true)
        }
        let localTriangles = derivation.triangles(in: WorldPlanarBounds(
            centerX: acceptance.position.x, centerZ: acceptance.position.z,
            halfExtentX: 2, halfExtentZ: 2))
        check(WorldPropMeshClearance.canPlace(
                volume(into: 0), supportHeight: acceptance.layer.supportHeight, triangles: localTriangles),
              "不推的话可放（同一份几何、同一个判据）")
        // 从**被接受的落点**再往墙里推「离墙距离 + 5 厘米」⇒ 背面越过墙面 5 厘米 ⇒ 必须拒绝。
        // （只推 5 厘米是不够的：那个落点本来就离墙 0.5 m，推 5 厘米根本够不着墙。）
        check(!WorldPropMeshClearance.canPlace(
                volume(into: backToWall + 0.05),
                supportHeight: acceptance.layer.supportHeight, triangles: localTriangles),
              "背面越过墙面 5 厘米 ⇒ **必须拒绝**（这就是'不许穿墙'）")

        print("PASS: 摆正（真机那把剑 1.005×0.133×0.057 ⇒ 立着 1.1 m）+ 不瞎掰（无法确定就保留原样并说明）+ 存档同源")
        print("PASS: 靠墙（真实舱体派生 \(walls.count) 面竖直面；背朝墙候选经既有判据接受；插入墙里被拒）")
        print("PASS: \(count) checks")
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-prop-orientation-wall-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Test.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("test")
func run(_ binary: String, _ args: [String]) throws -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: binary); p.arguments = args
    try p.run(); p.waitUntilExit(); return p.terminationStatus
}
// WorldRuntime 的模块搜索路径 + 目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
// 不要在这里拼 `.build/...`：27 份各自拼写正是 SwiftPM 与 xcodebuild 两份模块并存的根因。
// `build` 由那唯一一份定义**推出来**（= Modules 的上一级），本文件不持有路径字面量。
func worldRuntimeHarnessFlags() -> [String] {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [FileManager.default.currentDirectoryPath + "/tools/world-runtime-harness-flags.sh"]
    process.standardOutput = pipe
    try? process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
}
let worldRuntimeFlags = worldRuntimeHarnessFlags()
let build = URL(fileURLWithPath: worldRuntimeFlags[1]).deletingLastPathComponent()
let objects = try FileManager.default.contentsOfDirectory(
    at: build.appendingPathComponent("WorldRuntime.build"), includingPropertiesForKeys: nil
).filter { $0.pathExtension == "o" }.map(\.path)
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library",
    "-I", build.appendingPathComponent("Modules").path, program.path, "-o", executable.path] + objects)
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, Array(CommandLine.arguments.dropFirst())))
