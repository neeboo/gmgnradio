// 电视机（屏幕四边形 + native 覆盖层 + 官方嵌入）的判据。
//
// 五条断言，每条都配**注入负对照**（"一个从不 FAIL 的门禁等于没有门禁"）：
//
//   1. 屏幕几何只有一处定义、可手动覆盖；推断不出来时**可见说明**（不硬猜）；
//   2. 覆盖层与屏幕四边形**几何一致**（给数字与容差）；相机移动后仍对齐；
//   3. **不抢场景鼠标**（注入"覆盖层吃事件" ⇒ 本 harness 必须 FAIL）；
//   4. 加载失败 / 无 URL / 几何缺失 ⇒ 各自**具名可见**失败，不静默；
//   5. 合规：只走**官方嵌入**；不许出现抓流 / 绕过登录的路径
//      （注入一条抓流路径 ⇒ 必须 FAIL；注入一条白名单旁路 ⇒ 必须 FAIL）。
//
// 手法沿袭仓里既有的离线 harness：
//   * 生产源码**原文**切片（不是在这儿抄一份）——`productionDeclaration` 按花括号配对切；
//   * 内层程序用 `/usr/bin/swiftc` 现编现跑，不启动 App、不碰 Metal、不碰网络；
//   * 反例在**源码副本**上做手术，证明判据真的会红。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let screenRoot = sourceRoot.appendingPathComponent("Screen")
let worldRuntimeRoot = root.appendingPathComponent(
    "apps/macos/Packages/WorldRuntime/Sources/WorldRuntime"
)

var failureCount = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("PASS \(message)")
    } else {
        print("FAIL \(message)")
        failureCount += 1
    }
}

func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

/// 从源码里切出 `signature` 开头的**那一个**花括号块（含嵌套）。切不出来就地崩 ——
/// 不许悄悄用一份手写的替身顶上（那会让"定义在哪儿"变成两处）。
func productionDeclaration(_ signature: String, in text: String) -> String {
    guard let start = text.range(of: signature)?.lowerBound,
          let open = text[start...].firstIndex(of: "{")
    else { fatalError("切不出生产源码里的声明「\(signature)」——签名改了？") }
    var depth = 0
    for index in text[open...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" {
            depth -= 1
            if depth == 0 { return String(text[start...index]) }
        }
    }
    fatalError("生产源码里的声明「\(signature)」括号不配对")
}

// ---------------------------------------------------------------------------
// MARK: 断言 3：覆盖层不吃场景鼠标
// ---------------------------------------------------------------------------

/// 「这个覆盖层会不会抢场景鼠标」的**唯一**判据。文本级，因为要看的是
/// "有没有覆写指针入口"这件事本身 —— 它一旦出现，14 条 `场景输入链[N]` 就会被绕开。
func overlayPointerVerdict(_ source: String) -> [String] {
    var problems: [String] = []
    if !source.contains("override func hitTest(_ point: NSPoint) -> NSView? { nil }") {
        problems.append("覆盖层容器没有 `override func hitTest(_ point: NSPoint) -> NSView? { nil }`：它没有明确宣称「不吃事件」")
    }
    let forbidden = [
        "override func mouseDown", "override func mouseDragged", "override func mouseUp",
        "override func rightMouseDown", "override func rightMouseUp", "override func mouseMoved",
        "override func scrollWheel", "override func acceptsFirstMouse",
        "override func magnify", "override func keyDown",
    ]
    for token in forbidden where source.contains(token) {
        problems.append("覆盖层覆写了指针/键盘入口「\(token)」：它会与场景的 14 条输入链抢事件")
    }
    return problems
}

// ---------------------------------------------------------------------------
// MARK: 断言 5（静态扫描）：生产源码里不许出现抓流 / 绕过登录的路径
// ---------------------------------------------------------------------------

/// 抓流、绕登录、绕地区的**能力痕迹**。这份表放在 harness 里而不是生产里：
/// 生产里出现这些字面量本身就该红。
let prohibitedCapabilityTokens = [
    "yt-dlp", "youtube-dl", "ytdl", "googlevideo", "signatureCipher", "streamingData",
    "videoplayback", "n-sig", "decryptSignature", "widevine", "Widevine",
    "cookiesFromBrowser", "--cookies", "proxyStream", "bypassRegion", "geoBypass",
]

/// 递归扫描一棵树，返回 `(文件, 命中词)`。只扫文本源码。
func scanForProhibitedCapabilities(at directory: URL) -> [(String, String)] {
    var hits: [(String, String)] = []
    let extensions: Set<String> = ["swift", "m", "mm", "c", "h", "py", "sh", "js", "ts", "json"]
    guard let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey]
    ) else { return hits }
    for case let url as URL in enumerator {
        guard extensions.contains(url.pathExtension.lowercased()) else { continue }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for token in prohibitedCapabilityTokens where text.contains(token) {
            hits.append(("\(url.lastPathComponent):\(token)", token))
        }
    }
    return hits
}

// ---------------------------------------------------------------------------
// MARK: 断言 1 / 2 / 4 / 5（白名单）——内层程序：把生产源码原文切进去现编现跑
// ---------------------------------------------------------------------------

let anchorsSource = try read(
    worldRuntimeRoot.appendingPathComponent("WorldPropFunctionAnchors.swift")
)
let worldPositionDeclaration = productionDeclaration(
    "public static func worldPosition(", in: anchorsSource
)
check(
    worldPositionDeclaration.contains("position.x + cosine * local.x + sine * local.z"),
    "断言1：生产 `WorldPropAnchorRegistry.worldPosition` 的算式被原文切到（屏幕四角的局部→世界规则必须与它同式）"
)
let splicedWorldPosition = worldPositionDeclaration
    .replacingOccurrences(of: "public static func worldPosition(", with: "static func productionWorldPosition(")

let marbleSource = try read(
    sourceRoot.appendingPathComponent("VisualEngine/Metal/MarbleSpatialView.swift")
)
guard let matrixTailStart = marbleSource.range(of: "    private func perspectiveMatrix(")?.lowerBound
else { fatalError("切不出 `MarbleSpatialView.perspectiveMatrix` —— 相机/投影换了写法？") }
var matrixRegion = String(marbleSource[matrixTailStart...])
guard matrixRegion.contains("\n}\n#endif") else {
    fatalError("`MarbleSpatialView.swift` 的尾部形状变了：切矩阵辅助函数的前提不成立")
}
matrixRegion = matrixRegion.replacingOccurrences(of: "\n}\n#endif", with: "\n")
matrixRegion = matrixRegion.replacingOccurrences(of: "private func", with: "static func")
for expected in [
    "let z = far / (near - far)",
    "SIMD4(0, 0, z, -1)",
    "SIMD4(0, 0, z * near, 0)",
] {
    check(
        matrixRegion.contains(expected),
        "断言2：生产 `perspectiveMatrix` 的原文里有「\(expected)」（投影算式只有一处）"
    )
}

let stageStoreSource = try read(
    sourceRoot.appendingPathComponent("VisualEngine/SpatialStageStore.swift")
)
let screenPointDeclaration = productionDeclaration(
    "func residentPropScreenPoint(world: SIMD3<Float>) -> SIMD2<Float>?", in: stageStoreSource
)
for expected in [
    "let clip = residentPropViewProjection * SIMD4(world, 1)",
    "guard clip.w > 0.000001 else { return nil }",
    "return SIMD2((clip.x/clip.w+1)/2, (1-clip.y/clip.w)/2)",
] {
    check(
        screenPointDeclaration.contains(expected),
        "断言2：生产 `residentPropScreenPoint` 的原文里有「\(expected)」（世界→屏幕只有一处）"
    )
}
/// 把生产那一份**逐行**改造成可离线调用的自由函数：只换输入名、只删门禁那一行，
/// 算式一个字不动。
let splicedScreenPoint: String = {
    var lines = screenPointDeclaration.split(separator: "\n", omittingEmptySubsequences: false)
    lines[0] = Substring(
        "static func productionScreenPoint(world: SIMD3<Float>, viewProjection: simd_float4x4) -> SIMD2<Float>? {"
    )
    let body = lines.dropFirst().filter { !$0.contains("isWorldVisible") }.map { line in
        line.replacingOccurrences(of: "residentPropViewProjection", with: "viewProjection")
    }
    return ([String(lines[0])] + body).joined(separator: "\n")
}()

let screenFiles = [
    "WorldScreenGeometry.swift", "WorldScreenInference.swift", "WorldScreenProjection.swift",
    "WorldScreenContent.swift", "WorldScreenState.swift", "ResidentScreenTools.swift",
    // 前景遮挡（格级掩码）也钉在这里：它是覆盖层"不参与深度测试"这个结构性缺口的唯一补法，
    // 判据必须能**直接驱动**它，而不是只看覆盖层那边的文本。
    "WorldScreenOcclusion.swift",
]

let innerProgram = ##"""
import Foundation
import simd

/// `WorldRuntime` 的 `WorldVector3` 在这一层只做类型替身：切进来的生产算式
/// 用的就是它，替掉的只有名字。
struct WorldVector3: Equatable, Sendable {
    var x: Float
    var y: Float
    var z: Float
    init(x: Float, y: Float, z: Float) { self.x = x; self.y = y; self.z = z }
    init(_ value: SIMD3<Float>) { self.init(x: value.x, y: value.y, z: value.z) }
    var simd: SIMD3<Float> { SIMD3(x, y, z) }
}

enum ProductionMath {
\##(splicedWorldPosition)
}

enum ProductionMatrixMath {
\##(matrixRegion)
}

enum ProductionStageProjection {
\##(splicedScreenPoint)
}

/// 判据里唯一的计数器 —— 与 `tools/` 里其它 harness 同一形状。
var failuresTotal = 0
func expect(_ condition: Bool, _ message: String) {
    if condition { print("PASS \(message)") } else { print("FAIL \(message)"); failuresTotal += 1 }
}

@MainActor
final class StubScreenControl: WorldScreenControlling {
    var screens: [WorldScreenSnapshot]
    var playResult: WorldScreenCommandOutcome
    var stopResult: WorldScreenCommandOutcome
    init(screens: [WorldScreenSnapshot] = [], playResult: WorldScreenCommandOutcome,
         stopResult: WorldScreenCommandOutcome) {
        self.screens = screens; self.playResult = playResult; self.stopResult = stopResult
    }
    func listScreens() -> [WorldScreenSnapshot] { screens }
    func playScreen(objectID: String?, rawContent: String) async -> WorldScreenCommandOutcome { playResult }
    func stopScreen(objectID: String?) -> WorldScreenCommandOutcome { stopResult }
    func calibrateScreen(objectID: String, widthMeters: Float, heightMeters: Float,
                         centerHeightMeters: Float) -> WorldScreenCommandOutcome { playResult }
}

@main struct Test {
    @MainActor static func main() async throws {
        // =============================================================
        // 断言 1：几何只有一处定义 / 可手动覆盖 / 推不出来时可见说明
        // =============================================================
        let localPoints = [
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(1.3, 0, -0.7), SIMD3<Float>(-2.2, 0.9, 3.1),
            SIMD3<Float>(0.4, 1.7, 0.05), SIMD3<Float>(-0.6, -0.2, -1.9),
        ]
        let placements: [(SIMD3<Float>, Float)] = [
            (SIMD3<Float>(0, 0, 0), 0), (SIMD3<Float>(3.2, 0, -1.4), 0.7),
            (SIMD3<Float>(-1.1, 0, 2.6), -2.4), (SIMD3<Float>(0.5, 1.2, 0.5), Float.pi),
        ]
        var worstLocalToWorld: Float = 0
        for point in localPoints {
            for (position, yaw) in placements {
                let production = ProductionMath.productionWorldPosition(
                    of: WorldVector3(point), placedAt: WorldVector3(position), yaw: yaw
                ).simd
                let mine = WorldScreenPlacement.worldPosition(of: point, placedAt: position, yaw: yaw)
                worstLocalToWorld = max(worstLocalToWorld, simd_length(production - mine))
            }
        }
        expect(worstLocalToWorld <= 1e-5,
            "断言1：局部→世界与生产 `WorldPropAnchorRegistry.worldPosition` 逐点一致（最大偏差 \(worstLocalToWorld)）")

        // ① 标定优先：有合法标定块时，绝不给推断值或缺省值。
        let calibrated = WorldScreenDefinition(
            objectID: "tv-1", source: .calibrated,
            quad: WorldScreenQuad(center: SIMD3<Float>(0, 1.4, 0.1), yaw: 0.3, pitch: 0,
                                  halfWidth: 0.75, halfHeight: 0.42),
            note: "编辑器标定：宽 1.50 m × 高 0.84 m"
        )
        let encoded = WorldScreenDefinitionCoding.encode(calibrated)
        expect(encoded != nil, "断言1：合法标定块能编码成 `gmgn.screen.v1` 的载荷")
        switch WorldScreenResolution.resolve(
            objectID: "tv-1", calibratedJSON: encoded,
            size: SIMD3<Float>(2.0, 2.0, 2.0), allowsDefault: true
        ) {
        case let .success(value):
            expect(value.source == .calibrated && abs(value.quad.halfWidth - 0.75) < 1e-6,
                "断言1：① 标定压过推断与缺省（source=\(value.source.rawValue)，半宽 \(value.quad.halfWidth)）")
        case let .failure(issue):
            expect(false, "断言1：合法标定必须直接可用，却拿到 \(issue)")
        }

        // ① 坏标定是**错误**，不许静默降级成推断值。
        switch WorldScreenResolution.resolve(
            objectID: "tv-1", calibratedJSON: "{\"objectID\":\"tv-1\"}",
            size: SIMD3<Float>(1.2, 0.7, 0.06), allowsDefault: true
        ) {
        case let .failure(issue):
            expect(issue == .invalidCalibration(objectID: "tv-1"),
                "断言1：坏标定块报具名错误（\(issue.errorDescription)），不静默落到推断")
        case .success:
            expect(false, "断言1：坏标定块被静默接受")
        }

        // ② 由最大平坦面推断：电视 = 宽 × 高 × 薄 ⇒ 正面（+Z）。
        let tvSize = SIMD3<Float>(1.24, 0.70, 0.055)
        switch WorldScreenResolution.resolve(
            objectID: "tv-2", calibratedJSON: nil, size: tvSize, allowsDefault: false
        ) {
        case let .success(value):
            let expectedWidth = tvSize.x * WorldScreenResolution.panelInset
            expect(value.source == .inferred,
                "断言1：② 无标定时按最大平坦面推断（source=\(value.source.rawValue)）")
            expect(abs(value.quad.width - expectedWidth) < 1e-5
                    && abs(value.quad.normal.z - 1) < 1e-5,
                "断言1：② 推断出的屏幕是 +Z 正面、宽 \(value.quad.width) m（期望 \(expectedWidth) m）")
            expect(value.quad.center.y > 0 && value.quad.center.y < tvSize.y,
                "断言1：② 屏幕中心落在包围盒的 y 区间内（局部包围盒约定：y ∈ [0, size.y]）")
            expect(value.note.contains("推断") && value.note.contains("不是标定值"),
                "断言1：② 推断结果自带出处原话：「\(value.note)」")
        case let .failure(issue):
            expect(false, "断言1：一块 1.24×0.70×0.055 的电视必须能被推断出来，却拿到 \(issue)")
        }

        // ② 不像板 / 面积太小：**不猜**，具名拒绝。
        let cubeSize = SIMD3<Float>(1.0, 1.0, 1.0)
        switch WorldScreenResolution.resolve(
            objectID: "cube", calibratedJSON: nil, size: cubeSize, allowsDefault: false
        ) {
        case let .failure(issue):
            if case let .notPanelLike(objectID, size, ratio, threshold) = issue {
                expect(objectID == "cube" && simd_length(size - cubeSize) < 1e-6
                        && abs(ratio - 1) < 1e-6
                        && abs(threshold - WorldScreenResolution.maximumPanelThicknessRatio) < 1e-6,
                    "断言1：② 方块柜子判不出屏幕 ⇒ 具名拒绝（\(issue.errorDescription)）")
            } else {
                expect(false, "断言1：② 方块柜子应当报 notPanelLike，却拿到 \(issue)")
            }
        case .success:
            expect(false, "断言1：一个 1×1×1 的方块被当成了屏幕（最大面成了掷骰子）")
        }
        let tinySize = SIMD3<Float>(0.12, 0.12, 0.01)
        switch WorldScreenResolution.resolve(
            objectID: "tiny", calibratedJSON: nil, size: tinySize, allowsDefault: false
        ) {
        case let .failure(issue):
            if case let .belowAreaThreshold(_, area) = issue {
                expect(area < WorldScreenResolution.minimumFaceArea,
                    "断言1：② 面积阈值生效（最大面 \(area) m² < \(WorldScreenResolution.minimumFaceArea) m²）")
            } else {
                expect(false, "断言1：面积不足应报 belowAreaThreshold，却拿到 \(issue)")
            }
        case .success:
            expect(false, "断言1：12 cm 见方的面被当成了屏幕")
        }

        // ③ 缺省：**必须**说"这是猜的"；调用方没声明是电视时**不给**缺省。
        switch WorldScreenResolution.resolve(
            objectID: "mystery", calibratedJSON: nil, size: nil, allowsDefault: false
        ) {
        case let .failure(issue):
            expect(issue == .missingGeometry(objectID: "mystery"),
                "断言1：③ 没有标定也没有尺寸、且没声明是电视 ⇒ 具名缺失（\(issue.errorDescription)）")
        case .success:
            expect(false, "断言1：说不出来处的屏幕还是被造出来了")
        }
        switch WorldScreenResolution.resolve(
            objectID: "tv-3", calibratedJSON: nil, size: nil, allowsDefault: true
        ) {
        case let .success(value):
            expect(value.source == .default && value.note.contains("猜"),
                "断言1：③ 缺省值必须自带「这是猜的」的可见说明：「\(value.note)」")
        case let .failure(issue):
            expect(false, "断言1：显式声明是电视时应当给缺省，却拿到 \(issue)")
        }

        // note 为空 ⇒ 定义**构造不出来**："不猜"不是靠自觉，是靠类型。
        let noteLess = WorldScreenDefinition(
            objectID: "tv-4", source: .default,
            quad: WorldScreenQuad(center: SIMD3<Float>(0, 1, 0), halfWidth: 0.5, halfHeight: 0.3),
            note: "   "
        )
        expect(!noteLess.isValid && WorldScreenDefinitionCoding.encode(noteLess) == nil,
            "断言1：note 为空的屏幕定义非法 ⇒ 一条说不出出处的屏幕定义无法落盘")

        // =============================================================
        // 断言 2：覆盖层与屏幕四边形几何一致；相机移动后仍对齐
        // =============================================================
        let viewport = SIMD2<Float>(1440, 900)
        let poses: [(WorldScreenCamera, WorldScreenRenderProfile)] = [
            (WorldScreenCamera(position: SIMD3(0, 0.8, 1.1), yaw: 0, pitch: 0), .fullStage),
            (WorldScreenCamera(position: SIMD3(1.4, 1.1, -0.6), yaw: 0.8, pitch: -0.35), .fullStage),
            (WorldScreenCamera(position: SIMD3(-2.0, 0.5, 2.4), yaw: -0.6, pitch: 0.5), .fullStage),
            (WorldScreenCamera(position: SIMD3(0.2, 0.3, 0.4), yaw: 2.9, pitch: 0.1), .liveCam),
        ]
        var worstProjectionDelta: Float = 0
        var worstScreenPointDelta: Float = 0
        for (camera, profile) in poses {
            let productionVP = ProductionMatrixMath.perspectiveMatrix(
                fieldOfView: profile == .liveCam ? 44 * .pi / 180 : 66 * .pi / 180,
                aspect: viewport.x / viewport.y, near: 0.05, far: 250
            ) * ProductionMatrixMath.rotationX(-camera.pitch)
              * ProductionMatrixMath.rotationY(-camera.yaw)
              * ProductionMatrixMath.translation(-camera.position)
            let mine = WorldScreenProjection(
                camera: camera, profile: profile, viewportSize: viewport
            )
            for column in 0 ..< 4 {
                let a = productionVP[column]
                let b = mine.viewProjection[column]
                for index in 0 ..< 4 {
                    worstProjectionDelta = max(worstProjectionDelta, abs(a[index] - b[index]))
                }
            }
            for point in localPoints {
                guard let production = ProductionStageProjection.productionScreenPoint(
                    world: point, viewProjection: productionVP
                ), let myPoint = mine.screenPoint(world: point) else { continue }
                worstScreenPointDelta = max(
                    worstScreenPointDelta, simd_length(production - myPoint)
                )
            }
        }
        expect(worstProjectionDelta <= 1e-5,
            "断言2：我的视图投影 == 生产 `perspectiveMatrix`×相机变换（16 个分量最大偏差 \(worstProjectionDelta)）")
        expect(worstScreenPointDelta <= 1e-5,
            "断言2：我的 `screenPoint` == 生产 `residentPropScreenPoint`（归一化空间最大偏差 \(worstScreenPointDelta)）")

        // 覆盖层回投：矩形四角经 `layer.transform` ⇒ 必须落到投影出来的四个角上。
        let quad = WorldScreenQuad(
            center: SIMD3<Float>(0, 1.05, 0.03), yaw: 0, pitch: 0,
            halfWidth: 0.62, halfHeight: 0.35
        )
        let propPlacements: [(SIMD3<Float>, Float)] = [
            (SIMD3<Float>(0, 0, -1.6), 0), (SIMD3<Float>(1.9, 0, -0.3), 0.9),
            (SIMD3<Float>(-1.2, 0, 1.1), -1.7),
        ]
        // 12 步相机轨迹：绕着屏幕转 + 抬头低头，**每一步都看向屏幕中心**。
        // 这样"对齐"这条断言在每一步都有意义，而不是靠大量背影位姿把样本凑少。
        var trajectory: [WorldScreenCamera] = []
        var trajectoryCentres: [SIMD3<Float>] = []
        for (position, yaw) in propPlacements {
            let centre = quad.worldCenter(placedAt: position, yaw: yaw)
            for step in 0 ..< 12 {
                let t = Float(step) / 11
                let angle = -0.8 + 1.6 * t      // |angle| < π/2 ⇒ 一直落在屏幕正面
                let radius = 0.8 + 2.0 * t
                let height = 0.25 + 1.3 * t
                let offset = SIMD3<Float>(sin(angle) * radius, height, cos(angle) * radius)
                let toCentre = -offset
                let length = simd_length(toCentre)
                trajectory.append(WorldScreenCamera(
                    position: centre + offset,
                    yaw: atan2(-toCentre.x, -toCentre.z),   // 与 cameraView 的 yaw 口径一致
                    pitch: asin(toCentre.y / length)
                ))
                trajectoryCentres.append(centre)
            }
        }
        var worstOverlayError: Float = 0
        var usableSteps = 0
        var backFacingHidden = 0
        for index in trajectory.indices {
            let camera = trajectory[index]
            let alignedCentre = trajectoryCentres[index]
            let projection = WorldScreenProjection(
                camera: camera, profile: .fullStage, viewportSize: viewport
            )
            for (position, yaw) in propPlacements {
                let worldCorners = quad.worldCorners(placedAt: position, yaw: yaw)
                let normal = quad.worldNormal(yaw: yaw)
                let centre = (worldCorners[0] + worldCorners[1] + worldCorners[2] + worldCorners[3]) / 4
                guard simd_length(centre - alignedCentre) < 1e-5 else { continue }
                guard WorldScreenProjection.isFrontFacing(
                    normal: normal, center: centre, camera: camera
                ) else { backFacingHidden += 1; continue }
                guard let normalized = projection.screenQuad(worldCorners: worldCorners),
                      let placement = WorldScreenOverlayAlignment.placement(
                          normalizedCorners: normalized, projection: projection
                      ) else { continue }
                usableSteps += 1
                let points = normalized.map { projection.viewPoint(normalized: $0) }
                let size = placement.frame
                // `CALayer.transform` 作用在**锚点相对坐标**上（锚点默认是层中心），
                // 所以两边都减去同一个 `size/2` 再比 —— 这一处口径写错，
                // 覆盖层就会整体平移半个屏幕（真机表现：画面贴在电视机旁边）。
                let anchor = SIMD2(size.x / 2, size.y / 2)
                let source: [SIMD2<Float>] = [
                    SIMD2(0, 0), SIMD2(size.x, 0), SIMD2(size.x, size.y), SIMD2(0, size.y),
                ]
                for corner in 0 ..< 4 {
                    guard let actual = placement.transform.apply(to: source[corner] - anchor) else {
                        expect(false, "断言2：覆盖层变换在角 \(corner) 上退化了")
                        continue
                    }
                    let expected = points[corner] - placement.frameOrigin - anchor
                    worstOverlayError = max(worstOverlayError, simd_length(actual - expected))
                }
            }
        }
        expect(usableSteps >= 24 && usableSteps + backFacingHidden == 36,
            "断言2：绕每一块屏各 12 步、共 36 个位姿，\(usableSteps) 个正对可用、\(backFacingHidden) 个被判背面剔除（每个位姿都必须落在「可用」或「明确剔除」之一，不许静默丢掉）")
        expect(worstOverlayError <= 0.5,
            "断言2：覆盖层矩形四角经 `layer.transform` 回投到屏幕四角，最大偏差 \(worstOverlayError) px（容差 0.5 px = 1080p 下半个像素）")

        // 背面必须被剔除（转过去就不该看见画面）。
        let behind = WorldScreenCamera(position: SIMD3(0, 1.05, -4), yaw: 0, pitch: 0)
        expect(!WorldScreenProjection.isFrontFacing(
            normal: SIMD3(0, 0, 1), center: SIMD3(0, 1.05, 0), camera: behind
        ), "断言2：屏幕背对相机时 `isFrontFacing` 为假 ⇒ 覆盖层整块隐藏")
        // 相机背后的角点必须让整块消失，而不是画一个翻过来的破四边形。
        expect(WorldScreenProjection(
            camera: WorldScreenCamera(position: SIMD3(0, 0.8, 1.1), yaw: 0, pitch: 0),
            profile: .fullStage, viewportSize: viewport
        ).screenQuad(worldCorners: [
            SIMD3(0, 1, 5), SIMD3(1, 1, 5), SIMD3(1, 2, 5), SIMD3(0, 2, 5),
        ]) == nil, "断言2：有角点落在相机背后时 `screenQuad` 返回 nil（整块不画）")

        // =============================================================
        // 断言 4：失败各自具名、可见、不静默
        // =============================================================
        let geometryIssues: [WorldScreenGeometryIssue] = [
            .missingGeometry(objectID: "tv"),
            .notPanelLike(
                objectID: "tv", size: SIMD3<Float>(1.44, 0.90, 1.44),
                thinnestOverLongest: 0.624, threshold: 0.25
            ),
            .belowAreaThreshold(objectID: "tv", largestFaceArea: 0.01),
            .invalidCalibration(objectID: "tv"),
        ]
        let geometrySentences = geometryIssues.map(\.errorDescription)
        expect(geometrySentences.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            "断言4：四种几何缺失各自有人话")
        expect(Set(geometrySentences).count == geometryIssues.count,
            "断言4：四种几何缺失的文案**互不相同**（不能糊成一句「没有屏幕」）")
        expect(geometrySentences.allSatisfy { $0.contains("tv") },
            "断言4：几何缺失的文案里带着是哪一件物件")

        let contentIssues: [WorldScreenContentIssue] = [
            .missingInput, .insecureScheme("http"), .malformedURL("::::"),
            .unsupportedHost("evil.example"), .notEmbedPath(host: "www.youtube.com", path: "/watch"),
        ]
        let contentSentences = contentIssues.map(\.errorDescription)
        expect(contentSentences.allSatisfy { !$0.isEmpty },
            "断言4：五种内容失败各自有人话")
        expect(Set(contentSentences).count == contentIssues.count,
            "断言4：五种内容失败的文案互不相同")

        let failures: [WorldScreenFailure] = [
            .network("无法连接到服务器"), .httpStatus(403), .timeout, .blocked("内容策略"),
        ]
        expect(Set(failures.map(\.errorDescription)).count == failures.count
                && failures.allSatisfy { !$0.errorDescription.isEmpty },
            "断言4：四种加载失败各自有人话且互不相同")
        let states: [WorldScreenSurfaceState] = [
            .idle, .loading(url: "https://www.youtube.com/embed/x"),
            .playing(url: "https://www.youtube.com/embed/x"), .stopped,
            .failed(.timeout),
        ]
        expect(states.allSatisfy { !$0.displayText.isEmpty },
            "断言4：五种屏幕状态都能读出一行话")
        expect(states.last!.displayText.contains("失败：") && states.last!.displayText.contains("20 秒"),
            "断言4：失败状态那行话带上具体原因：「\(states.last!.displayText)」")

        // 工具层：信息不足走**成功通道**（isError=false），其余是真错误。
        let emptySchemaScreens: [WorldScreenSnapshot] = [WorldScreenSnapshot(
            objectID: "tv-1", displayName: "客厅电视", source: .inferred,
            note: "由最大平坦面推断：法向 +Z（正面），面积 0.87 m²。不是标定值。",
            aspect: 1.77, geometryIssue: nil,
            contentURL: "https://www.youtube.com/embed/x", stateText: "播放中", isPlaying: true
        )]
        let needsInputControl = StubScreenControl(
            screens: emptySchemaScreens,
            playResult: .needsInput(WorldScreenContentIssue.missingInput.errorDescription),
            stopResult: .ok("已关掉。")
        )
        let tools = ResidentScreenTools(control: needsInputControl, isCurrent: { true }).tools
        expect(tools.map(\.name) == ["play_screen", "stop_screen", "read_screen"],
            "断言4：三条工具的名字与顺序固定（\(tools.map(\.name).joined(separator: ", "))）")
        guard let playTool = tools.first(where: { $0.name == "play_screen" }),
              let readTool = tools.first(where: { $0.name == "read_screen" })
        else { expect(false, "断言4：找不到 play_screen / read_screen"); return }
        let missingURLReply = await playTool.handle("call-1", Data("{}".utf8))
        expect(missingURLReply.isError == false && missingURLReply.code == "insufficient_input",
            "断言4：缺 URL ⇒ code=insufficient_input 且 isError=false（走成功通道，与既有 `insufficient_input` 同一字面量）")
        let payload = (try? JSONSerialization.jsonObject(with: missingURLReply.payloadJSON)) as? [String: Any]
        expect((payload?["message"] as? String)?.isEmpty == false,
            "断言4：insufficient_input 的回执带一句人话：「\((payload?["message"] as? String) ?? "")」")
        let readReply = await readTool.handle("call-2", Data("{}".utf8))
        expect(readReply.isError == false
                && String(decoding: readReply.payloadJSON, as: UTF8.self).contains("客厅电视"),
            "断言4：read_screen 只读且带得出屏幕状态")
        let failureControl = StubScreenControl(
            screens: emptySchemaScreens,
            playResult: .failure(.screenGeometryMissing, WorldScreenGeometryIssue
                .missingGeometry(objectID: "tv-1").errorDescription),
            stopResult: .failure(.screenNotFound, "没有可关的电视。")
        )
        let failureTools = ResidentScreenTools(control: failureControl, isCurrent: { true }).tools
        let geometryReply = await failureTools[0].handle("call-3", Data(#"{"url":"https://www.youtube.com/embed/x"}"#.utf8))
        expect(geometryReply.isError && geometryReply.code == "screen_geometry_missing",
            "断言4：几何缺失 ⇒ screen_geometry_missing 且 isError=true")
        let loadFailureControl = StubScreenControl(
            screens: emptySchemaScreens,
            playResult: .failure(.screenLoadFailed, WorldScreenFailure.network("无法连接").errorDescription),
            stopResult: .ok("已关掉。")
        )
        let loadReply = await ResidentScreenTools(control: loadFailureControl, isCurrent: { true })
            .tools[0].handle("call-4", Data(#"{"url":"https://www.youtube.com/embed/x"}"#.utf8))
        expect(loadReply.isError && loadReply.code == "screen_load_failed",
            "断言4：加载失败 ⇒ screen_load_failed 且 isError=true（不静默）")
        let staleReply = await ResidentScreenTools(control: needsInputControl, isCurrent: { false })
            .tools[0].handle("call-5", Data(#"{"url":"https://www.youtube.com/embed/x"}"#.utf8))
        expect(staleReply.isError, "断言4：本轮已被替换时工具具名拒绝，而不是假装成功")

        // =============================================================
        // 断言 5：只走官方嵌入
        // =============================================================
        let mustReject: [(String, WorldScreenContentIssue)] = [
            ("https://www.googlevideo.com/videoplayback?itag=18", .unsupportedHost("www.googlevideo.com")),
            ("https://r1---sn-a5m7lnl6.googlevideo.com/videoplayback", .unsupportedHost("r1---sn-a5m7lnl6.googlevideo.com")),
            ("http://www.youtube.com/embed/dQw4w9WgXcQ", .insecureScheme("http")),
            ("https://evil.example/embed/dQw4w9WgXcQ", .unsupportedHost("evil.example")),
            ("https://www.youtube.com/watch?list=PLx", .notEmbedPath(host: "www.youtube.com", path: "/watch")),
            ("file:///tmp/movie.mp4", .insecureScheme("file")),   // 协议先判，不报"读不出来"
            ("https://www.youtube.com/embed/", .missingVideoID(host: "www.youtube.com")),
        ]
        for (raw, expected) in mustReject {
            switch WorldScreenEmbedPolicy.validate(raw) {
            case let .failure(issue):
                expect(issue == expected,
                    "断言5：拒绝「\(raw)」⇒ \(issue.errorDescription)")
            case let .success(url):
                expect(false, "断言5：**放行了**不该放行的「\(raw)」（得到 \(url.absoluteString)）")
            }
        }
        // 官方嵌入：三种输入都通向**站方自己的嵌入页**。
        let accepted: [(String, String)] = [
            ("https://www.youtube.com/embed/dQw4w9WgXcQ",
             "https://www.youtube.com/embed/dQw4w9WgXcQ"),
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ",
             "https://www.youtube.com/embed/dQw4w9WgXcQ"),
            ("https://youtu.be/dQw4w9WgXcQ", "https://www.youtube.com/embed/dQw4w9WgXcQ"),
            ("dQw4w9WgXcQ", "https://www.youtube.com/embed/dQw4w9WgXcQ"),
            ("https://player.bilibili.com/player.html?bvid=BV1xx411c7mD",
             "https://player.bilibili.com/player.html?bvid=BV1xx411c7mD"),
            ("BV1xx411c7mD", "https://player.bilibili.com/player.html?bvid=BV1xx411c7mD&autoplay=0"),
        ]
        for (raw, expected) in accepted {
            switch WorldScreenEmbedPolicy.validate(raw) {
            case let .success(url):
                expect(url.absoluteString == expected,
                    "断言5：「\(raw)」⇒ 官方嵌入页 \(url.absoluteString)")
                expect(url.host != "googlevideo.com" && !(url.host ?? "").hasSuffix("googlevideo.com"),
                    "断言5：落到播放的域名**不是**字节 CDN（\(url.host ?? "nil")）")
            case let .failure(issue):
                expect(false, "断言5：合法的官方嵌入「\(raw)」被拒了：\(issue.errorDescription)")
            }
        }
        let watchRewrite = WorldScreenEmbedPolicy.validate("https://www.bilibili.com/video/BV1xx411c7mD")
        if case let .success(url) = watchRewrite {
            expect(url.host == "player.bilibili.com",
                "断言5：哔哩哔哩公开观看链接被换写成**站方播放器**（\(url.absoluteString)）")
        } else {
            expect(false, "断言5：哔哩哔哩公开观看链接应当被换写成官方播放器")
        }

        // =============================================================
        // 断言 6：前景遮挡 —— **区域级**，不是整块开关
        // =============================================================
        //
        // 覆盖层是 native `CALayer`，**不参与深度测试**（这是第一版自己标注的限制，
        // 真机表现："人身上糊着一块网页"）。这一节钉的就是补它的那一层：
        // 从相机到每一格中心连线，先撞上更近的东西的那一格**不画**。
        //
        // 场景：屏幕 1.24 m × 0.70 m 立在 z = 0（BL/BR/TR/TL），相机在 z = +3；
        // 角色用 `MarblePMXFraming` 缺省包围盒那一份（±0.5 × 1.7 × ±0.5 m × scale）。
        let occlQuad: [SIMD3<Float>] = [
            SIMD3(-0.62, 0.35, 0), SIMD3(0.62, 0.35, 0), SIMD3(0.62, 1.05, 0), SIMD3(-0.62, 1.05, 0),
        ]
        let occlViewer = SIMD3<Float>(0, 0.85, 3.0)
        let occlColumns = 24
        let occlRows = 14
        func occlusion(_ occluders: WorldScreenOccluders) -> WorldScreenOcclusionMask {
            WorldScreenOcclusion.mask(
                quadCorners: occlQuad, cameraPosition: occlViewer, occluders: occluders,
                columns: occlColumns, rows: occlRows
            )
        }
        let noOccluders = occlusion(.empty)
        expect(noOccluders.isFullyVisible && noOccluders.blockedCellCount == 0,
            "断言6：没有遮挡物时 \(occlColumns) × \(occlRows) 格**全部可见**"
                + "（\(noOccluders.blockedCellCount)/\(noOccluders.cellCount) 格被挡）")

        // 角色站在屏前 0.6 m ⇒ 正中一片被挡，两侧仍然显示。
        let occlResident = WorldScreenBox(
            center: SIMD3(0, 0.85, 0.6), halfExtents: SIMD3(0.25, 0.85, 0.2), yaw: 0
        )
        let residentMask = occlusion(WorldScreenOccluders(boxes: [occlResident]))
        expect(residentMask.blockedCellCount == 196 && residentMask.visibleCellCount == 140,
            "断言6：角色站在屏前 ⇒ 被角色挡住的那部分（期望 196/336 格，约 58%）不画网页，"
                + "两侧 140 格照画（实测 \(residentMask.blockedCellCount)/\(residentMask.cellCount)）")
        expect(!residentMask.isBlocked(column: 0, row: 0)
                && !residentMask.isBlocked(column: occlColumns - 1, row: occlRows - 1),
            "断言6：区域级 —— 屏幕的 BL / TR 两角仍然显示（整块开关会把它们一起抹掉）")
        expect(residentMask.isBlocked(
            column: occlColumns / 2, row: occlRows / 2
        ), "断言6：角色身后的正中心那一格必须被挡（格子 (12, 7)）")

        // **部分遮挡**：左半边被挡时，右半边**仍然显示**（逐格核对，不是"差不多"）。
        let occlLeftPanel = WorldScreenBox(
            center: SIMD3(-0.31, 0.7, 1.5), halfExtents: SIMD3(0.31, 0.35, 0.05), yaw: 0
        )
        let halfMask = occlusion(WorldScreenOccluders(boxes: [occlLeftPanel]))
        var leftHalfBlocked = 0
        var rightHalfBlocked = 0
        for row in 0 ..< occlRows {
            for column in 0 ..< occlColumns where halfMask.isBlocked(column: column, row: row) {
                if column < occlColumns / 2 { leftHalfBlocked += 1 } else { rightHalfBlocked += 1 }
            }
        }
        expect(leftHalfBlocked == 168 && rightHalfBlocked == 0,
            "断言6：部分遮挡是按**格**判的 —— 左半边 168 格全被挡、右半边 0 格被挡"
                + "（实测 左 \(leftHalfBlocked) / 右 \(rightHalfBlocked)）")

        // 与屏幕**同深**的东西不算遮挡：只算"在前面**进入**"的。
        expect(WorldScreenOcclusion.isBlocked(
            nearestOccluderDistance: 2.99, screenDistance: 3.0, depthMargin: 0.02
        ) == false && WorldScreenOcclusion.isBlocked(
            nearestOccluderDistance: 2.97, screenDistance: 3.0, depthMargin: 0.02
        ), "断言6：遮挡物必须比屏幕**近** 2 cm 才作数（贴面/共面的东西不许把屏打花）")
        expect(WorldScreenOcclusion.isBlocked(
            nearestOccluderDistance: nil, screenDistance: 3.0, depthMargin: 0.02
        ) == false, "断言6：射线没撞到任何东西 ⇒ 这一格可见")

        // **正常观看（无人遮挡）时不闪烁**：连续 240 帧、相机有一点点手抖，
        // 掩码必须逐位相同；屏幕**后面**的东西一律不参与。
        let behindWall = WorldScreenOccluders(
            triangles: [WorldScreenTriangle(SIMD3(-5, -1, -1), SIMD3(5, -1, -1), SIMD3(0, 5, -1))],
            revision: 1
        )
        var flickers = 0
        for frame in 0 ..< 240 {
            let jitter = Float(frame % 2 == 0 ? 1 : -1) * 0.001
            let shaky = WorldScreenOcclusion.mask(
                quadCorners: occlQuad, cameraPosition: occlViewer + SIMD3(jitter, jitter, 0),
                occluders: behindWall, columns: occlColumns, rows: occlRows
            )
            if shaky.blocked != noOccluders.blocked { flickers += 1 }
        }
        expect(flickers == 0,
            "断言6：正常观看时不闪烁 —— 屏幕后面有墙、相机 1 mm 手抖，连续 240 帧掩码逐位相同"
                + "（实测翻转 \(flickers) 帧）")
        var worstJitterDelta = 0
        for frame in 0 ..< 240 {
            let jitter = Float(frame % 2 == 0 ? 1 : -1) * 0.001
            let shaky = WorldScreenOcclusion.mask(
                quadCorners: occlQuad, cameraPosition: occlViewer + SIMD3(jitter, jitter, 0),
                occluders: WorldScreenOccluders(boxes: [occlResident]),
                columns: occlColumns, rows: occlRows
            )
            var delta = 0
            for index in 0 ..< shaky.blocked.count where shaky.blocked[index] != residentMask.blocked[index] {
                delta += 1
            }
            worstJitterDelta = max(worstJitterDelta, delta)
        }
        expect(worstJitterDelta == 0,
            "断言6：角色站在屏前时，相机 1 mm 手抖一帧都不翻（实测最多翻 \(worstJitterDelta) 格）")

        // 屏幕**自己**那件不许挡自己（否则整块屏幕永远是被挡的）。
        let ownBox = WorldScreenBox(
            center: SIMD3(0, 0.85, 0.6), halfExtents: SIMD3(0.25, 0.85, 0.2), yaw: 0, owner: "tv-9"
        )
        let selfExcluded = WorldScreenOcclusion.mask(
            quadCorners: occlQuad, cameraPosition: occlViewer,
            occluders: WorldScreenOccluders(boxes: [ownBox]),
            excluding: "tv-9", columns: occlColumns, rows: occlRows
        )
        expect(selfExcluded.isFullyVisible,
            "断言6：屏幕自己那件物件的盒被排除（\(selfExcluded.blockedCellCount) 格被挡 —— 必须是 0）")

        // 掩码 → `CALayer.mask` 的路径：可见格并集，坐标在容器的 bounds 里。
        let maskRects = residentMask.visibleRects(in: SIMD2(1240, 700))
        let maskedArea = maskRects.reduce(Float(0)) { $0 + $1.width * $1.height }
        expect(maskRects.allSatisfy { $0.width > 0 && $0.height > 0 }
                && maskRects.allSatisfy { $0.x >= 0 && $0.y >= 0 }
                && maskRects.allSatisfy { $0.x + $0.width <= 1240.001 && $0.y + $0.height <= 700.001 },
            "断言6：可见区矩形全部落在容器 bounds 内（\(maskRects.count) 条，1080p 下每格约 52 × 50 px）")
        let expectedArea = Float(residentMask.visibleCellCount) / Float(residentMask.cellCount) * 1240 * 700
        expect(abs(maskedArea - expectedArea) < 1,
            "断言6：可见区矩形的总面积 = 可见格数占比 × 屏幕面积"
                + "（\(Int(maskedArea)) px² vs \(Int(expectedArea)) px²，140/336 格）")
        expect(residentMask.blockedRects(in: SIMD2(1240, 700)).isEmpty == false,
            "断言6：被挡区同样能给出矩形（诊断/回执要说得出「哪一块不画」）")
        let fullRects = noOccluders.visibleRects(in: SIMD2(1240, 700))
        let fullArea = fullRects.reduce(Float(0)) { $0 + $1.width * $1.height }
        expect(abs(fullArea - 1240 * 700) < 1,
            "断言6：全可见时可见区矩形并集刚好铺满整块屏幕（\(fullRects.count) 条）")

        // =============================================================
        // 断言 7：真机那件电视道具的屏幕面**可复核**
        // =============================================================
        //
        // 数字来自真机（不是编的）：生成任务 `2F633C0F-A868-4442-AD2A-C73D2A1D04E1`
        // 「超大荧幕电视」，用户尺寸意图 `{axis: longest, meters: 1.443}`；网格 AABB
        // 1.0079008 × 0.6289793 × 1.0079044（模型单位）⇒ 世界尺寸 1.443 × 0.901 × 1.443 m。
        let realTVSize = SIMD3<Float>(1.443, 0.9007, 1.443)
        let realTVRatio = WorldScreenFaceInference.thinnestOverLongest(size: realTVSize)
        expect(abs(realTVRatio - 0.624) < 0.002,
            "断言7：真机那件电视道具 最薄/最长 = \(String(format: "%.3f", realTVRatio))"
                + "（1.443 × 0.901 × 1.443 m）⇒ 它**不是一块板**，所以它压根没有「最大平坦面」可言")
        expect(WorldScreenFaceInference.defaultFace(size: realTVSize) == .front,
            "断言7：判不出板形时的兜底面 = 面积较大的**竖直面**（+Z 正面），不是朝上的那一面")

        // 不声明是电视 ⇒ 具名拒绝，且拒绝的话里能复核到数字。
        switch WorldScreenResolution.resolve(
            objectID: "wish-prop-2f633c0f", calibratedJSON: nil,
            size: realTVSize, allowsDefault: false
        ) {
        case let .failure(issue):
            if case let .notPanelLike(objectID, size, ratio, threshold) = issue {
                expect(objectID == "wish-prop-2f633c0f"
                        && simd_length(size - realTVSize) < 1e-6
                        && abs(ratio - realTVRatio) < 1e-6
                        && abs(threshold - WorldScreenResolution.maximumPanelThicknessRatio) < 1e-6,
                    "断言7：拒绝时把三边、实测比值与阈值都带出来（可复核，不是「我觉得不行」）")
            } else {
                expect(false, "断言7：判不出板形应当报 notPanelLike，却拿到 \(issue)")
            }
            expect(issue.errorDescription.contains("1.44") && issue.errorDescription.contains("0.62"),
                "断言7：拒绝的原话里能读到数字：「\(issue.errorDescription)」")
        case .success:
            expect(false, "断言7：没声明是电视时不该给出任何屏幕")
        }

        // 声明是电视 ⇒ 取的仍然是**这件道具自己的一个面**，不是那台与它无关的通用电视。
        switch WorldScreenResolution.resolve(
            objectID: "wish-prop-2f633c0f", calibratedJSON: nil,
            size: realTVSize, allowsDefault: true
        ) {
        case let .success(definition):
            let expected = WorldScreenFace.front.quad(size: realTVSize)
            expect(definition.source == .default,
                "断言7：兜底仍然**如实标注**成猜的（source=\(definition.source.rawValue)）")
            expect(abs(definition.quad.center.y - realTVSize.y / 2) < 1e-5,
                "断言7：屏幕中心落在**道具身上**（y = \(String(format: "%.4f", definition.quad.center.y)) m"
                    + " ≤ 道具高 \(String(format: "%.3f", realTVSize.y)) m），不再浮在它上方 0.15 m")
            expect(definition.quad.pitch == 0 && definition.quad.center.z > 0.7,
                "断言7：选中的是 +Z **竖直面**（pitch = 0、中心在 z = "
                    + "\(String(format: "%.3f", definition.quad.center.z))），不是朝上的那一面")
            expect(abs(definition.quad.width - expected.width) < 1e-5
                    && abs(definition.quad.height - expected.height) < 1e-5,
                "断言7：面的大小跟着道具走：\(String(format: "%.3f", definition.quad.width)) m × "
                    + "\(String(format: "%.3f", definition.quad.height)) m"
                    + "（= 1.443 × 0.86 与 0.901 × 0.86，不是那台通用电视的 1.10 × 0.62）")
            expect(abs(definition.quad.width - WorldScreenResolution.defaultWidth) > 1e-3,
                "断言7：兜底**不可能**再落到那台与道具无关的通用电视（宽 "
                    + "\(WorldScreenResolution.defaultWidth) m）")
            expect(definition.note.contains("猜") && definition.note.contains("1.44"),
                "断言7：出处原话可复核：「\(definition.note)」")
            expect(definition.isValid,
                "断言7：这份猜出来的定义本身必须合法（note 非空且 ≤ \(WorldScreenDefinition.maximumNoteLength) 字）")
        case let .failure(issue):
            expect(false, "断言7：声明是电视时应当给这块道具自己的面，却拿到 \(issue.errorDescription)")
        }

        print("INNER-FAILURES=\(failuresTotal)")
        if failuresTotal > 0 { exit(1) }
    }
}
"""##

// 现编现跑
let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-screen-overlay-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func run(_ binary: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let program = temporary.appendingPathComponent("Test.swift")
try innerProgram.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("test")
let screenSources = screenFiles.map { screenRoot.appendingPathComponent($0).path }
let compiled = try run(
    "/usr/bin/swiftc",
    ["-j1", "-parse-as-library"] + screenSources + [program.path, "-o", executable.path]
)
guard compiled == 0 else {
    print("FAIL 内层程序编译失败（exit \(compiled)）—— 判据没能跑起来")
    exit(compiled)
}
let innerStatus = try run(executable.path, [])
check(innerStatus == 0, "内层判据（断言 1/2/4/5-白名单/6-遮挡/7-真机道具的面）全部通过")


// ---------------------------------------------------------------------------
// MARK: 断言 6（行为）：遮挡判据的**注入负对照**（在源码副本上做手术）
// ---------------------------------------------------------------------------

/// 只跑遮挡本身的探针。两份源码（原件 / 打了手术的副本）都必须编得起来：
/// 原件 ⇒ 退出 0；手术版 ⇒ 必须 FAIL。这样"判据真的会红"才是被证明的。
let occlusionProbeProgram = ##"""
import Foundation
import simd

var probeFailures = 0
func probe(_ condition: Bool, _ message: String) {
    if condition {
        print("PROBE-PASS \(message)")
    } else {
        print("PROBE-FAIL \(message)")
        probeFailures += 1
    }
}

@main struct OcclusionProbe {
    static func main() {
        let quad: [SIMD3<Float>] = [
            SIMD3(-0.62, 0.35, 0), SIMD3(0.62, 0.35, 0),
            SIMD3(0.62, 1.05, 0), SIMD3(-0.62, 1.05, 0),
        ]
        let viewer = SIMD3<Float>(0, 0.85, 3.0)
        let resident = WorldScreenBox(
            center: SIMD3(0, 0.85, 0.6), halfExtents: SIMD3(0.25, 0.85, 0.2), yaw: 0
        )
        let blocked = WorldScreenOcclusion.mask(
            quadCorners: quad, cameraPosition: viewer,
            occluders: WorldScreenOccluders(boxes: [resident]), columns: 24, rows: 14
        )
        probe(blocked.blockedCellCount > 0,
              "角色站在屏前 ⇒ 有格被挡（实测 \(blocked.blockedCellCount)/336）")
        probe(blocked.visibleCellCount > 0,
              "角色站在屏前 ⇒ 不是整块消失（可见 \(blocked.visibleCellCount)/336 格）")

        let panel = WorldScreenBox(
            center: SIMD3(-0.31, 0.7, 1.5), halfExtents: SIMD3(0.31, 0.35, 0.05), yaw: 0
        )
        let half = WorldScreenOcclusion.mask(
            quadCorners: quad, cameraPosition: viewer,
            occluders: WorldScreenOccluders(boxes: [panel]), columns: 24, rows: 14
        )
        var left = 0
        var right = 0
        for row in 0 ..< 14 {
            for column in 0 ..< 24 where half.isBlocked(column: column, row: row) {
                if column < 12 { left += 1 } else { right += 1 }
            }
        }
        probe(left == 168 && right == 0,
              "左半边被挡 168 格、右半边 0 格（实测 \(left)/\(right)）")
        exit(probeFailures == 0 ? 0 : 1)
    }
}
"""##

/// 把两份几何源码复制到临时目录、可选地对 `WorldScreenOcclusion.swift` 做一次文本替换，
/// 编出探针跑一次，返回退出码（`-1` = 锚点没找到或没编起来，连同原因）。
func runOcclusionProbe(patch: (from: String, to: String)?) throws -> (status: Int32, note: String) {
    let directory = temporary.appendingPathComponent("occlusion-probe-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var sources: [String] = []
    for name in ["WorldScreenGeometry.swift", "WorldScreenOcclusion.swift"] {
        var text = try read(screenRoot.appendingPathComponent(name))
        if name == "WorldScreenOcclusion.swift", let patch {
            guard text.contains(patch.from) else {
                return (-1, "注入锚点在源码里找不到（签名改过？）：\(patch.from)")
            }
            text = text.replacingOccurrences(of: patch.from, with: patch.to)
        }
        let destination = directory.appendingPathComponent(name)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        sources.append(destination.path)
    }
    let probeProgram = directory.appendingPathComponent("Probe.swift")
    try occlusionProbeProgram.write(to: probeProgram, atomically: true, encoding: .utf8)
    let binary = directory.appendingPathComponent("probe")
    let compileStatus = try run(
        "/usr/bin/swiftc", ["-j1", "-parse-as-library"] + sources + [probeProgram.path, "-o", binary.path]
    )
    guard compileStatus == 0 else {
        return (-1, "探针没编起来（exit \(compileStatus)）—— 注入把源码改坏了")
    }
    return (try run(binary.path, []), "")
}

let occlusionProbeClean = try runOcclusionProbe(patch: nil)
check(occlusionProbeClean.status == 0,
    "断言6（探针）：**原件**上跑遮挡判据通过（exit \(occlusionProbeClean.status)）"
        + (occlusionProbeClean.note.isEmpty ? "" : " —— \(occlusionProbeClean.note)"))

// 注入①「不遮挡」：把格判据改成永远 false ⇒ 探针必须 FAIL（上面那条 PROBE-FAIL 就是原话）。
let occlusionProbeNoOcclusion = try runOcclusionProbe(patch: (
    from: "        return hit > 0 && hit < screenDistance - max(depthMargin, 0)",
    to: "        _ = hit; return false"
))
check(occlusionProbeNoOcclusion.status != 0,
    "断言6（注入负对照①「不遮挡」）：探针 FAIL（exit \(occlusionProbeNoOcclusion.status)）"
        + (occlusionProbeNoOcclusion.note.isEmpty ? "" : " —— \(occlusionProbeNoOcclusion.note)"))

// 注入②「整块隐藏」：有任意一格被挡就整块隐藏 ⇒ 探针必须 FAIL。
let occlusionProbeWholeBlock = try runOcclusionProbe(patch: (
    from: "        return WorldScreenOcclusionMask(columns: columns, rows: rows, blocked: blocked)",
    to: "        let anyBlocked = blocked.contains(true)\n"
        + "        return WorldScreenOcclusionMask(columns: columns, rows: rows, blocked: [Bool](repeating: anyBlocked, count: blocked.count))"
))
check(occlusionProbeWholeBlock.status != 0,
    "断言6（注入负对照②「整块隐藏」）：探针 FAIL（exit \(occlusionProbeWholeBlock.status)）"
        + (occlusionProbeWholeBlock.note.isEmpty ? "" : " —— \(occlusionProbeWholeBlock.note)"))

// ---------------------------------------------------------------------------
// MARK: 断言 3 + 5（静态扫描）：文本级判据与**注入负对照**
// ---------------------------------------------------------------------------

let overlaySource = try read(screenRoot.appendingPathComponent("WorldScreenOverlayController.swift"))
let overlayProblems = overlayPointerVerdict(overlaySource)
check(overlayProblems.isEmpty,
    "断言3：覆盖层不吃场景鼠标（容器 hitTest 恒 nil，且没有覆写任何指针/键盘入口）"
        + (overlayProblems.isEmpty ? "" : " —— \(overlayProblems.joined(separator: "；"))"))

// 注入：把 hitTest 改成"照常命中" ⇒ 判据必须红。
let injectedHitTest = overlaySource.replacingOccurrences(
    of: "override func hitTest(_ point: NSPoint) -> NSView? { nil }",
    with: "override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) }"
)
let injectedHitTestProblems = overlayPointerVerdict(injectedHitTest)
check(!injectedHitTestProblems.isEmpty,
    "断言3（注入负对照）：把覆盖层的 hitTest 改成会命中 ⇒ 判据 FAIL。原话："
        + injectedHitTestProblems.joined(separator: "；"))

// 注入：加一个 mouseDown ⇒ 判据必须红。
let injectedMouseDown = overlaySource.replacingOccurrences(
    of: "override var acceptsFirstResponder: Bool { false }",
    with: "override var acceptsFirstResponder: Bool { false }\n    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event) }"
)
let injectedMouseDownProblems = overlayPointerVerdict(injectedMouseDown)
check(!injectedMouseDownProblems.isEmpty,
    "断言3（注入负对照）：给覆盖层加一个 mouseDown ⇒ 判据 FAIL。原话："
        + injectedMouseDownProblems.joined(separator: "；"))

// ---------------------------------------------------------------------------
// MARK: 断言 6（覆盖层侧）：被挡的部分**真的会被裁掉**，且只走 `CALayer.mask`
// ---------------------------------------------------------------------------

/// 覆盖层侧的结构性判据（文本级：这一份不参与内层编译）。
///
/// 三条缺一不可：
/// 1. 被挡时挂的是 `container.layer.mask` 的**可见格并集**路径 —— 区域级，
///    既不是 `isHidden` 整块开关，也不碰 shader（红线）；
/// 2. 一格都没被挡时**摘掉** mask（正常观看零裁切、零抖动）；
/// 3. 屏幕自己那件被排除（否则它永远挡着自己）。
func overlayOcclusionVerdict(_ source: String) -> [String] {
    var problems: [String] = []
    if !source.contains("container.layer?.mask = created") {
        problems.append("被挡时没有挂 `CALayer.mask`")
    }
    if !source.contains("guard let mask, !mask.isFullyVisible else") {
        problems.append("全可见时没有摘掉 mask 的早退回")
    }
    if !source.contains("mask.visibleRects(in: size)") {
        problems.append("裁的不是可见格并集（区域级）")
    }
    if source.contains("if mask.blockedCellCount > 0 { container.isHidden = true") {
        problems.append("把遮挡做成了整块开关")
    }
    if !source.contains("WorldScreenOcclusion.mask(")
        || !source.contains("excluding: surface.objectID") {
        problems.append("没有按屏幕自己那件排除遮挡物（会自己挡自己）")
    }
    if !source.contains("occluders: WorldScreenOccluders = .empty") {
        problems.append("`update` 没有收遮挡物输入")
    }
    return problems
}

let overlayOcclusionProblems = overlayOcclusionVerdict(overlaySource)
check(overlayOcclusionProblems.isEmpty,
    "断言6：覆盖层按**区域**裁掉被挡的部分（`CALayer.mask` = 可见格并集；全可见时摘掉）"
        + (overlayOcclusionProblems.isEmpty ? "" : " —— \(overlayOcclusionProblems.joined(separator: "；"))"))

// 注入：把"全可见就摘掉 mask"改成"永远挂一块掩码" ⇒ 判据必须红。
let injectedAlwaysMask = overlaySource.replacingOccurrences(
    of: "guard let mask, !mask.isFullyVisible else",
    with: "guard let mask, mask.cellCount > 0 else"
)
check(!overlayOcclusionVerdict(injectedAlwaysMask).isEmpty,
    "断言6（注入负对照）：把「全可见就摘掉 mask」改掉 ⇒ 判据 FAIL。原话："
        + overlayOcclusionVerdict(injectedAlwaysMask).joined(separator: "；"))

// 注入：把"排除屏幕自己那件"去掉 ⇒ 判据必须红（真机上表现为整块屏幕永远被挡）。
let injectedNoExclusion = overlaySource.replacingOccurrences(
    of: "excluding: surface.objectID",
    with: "excluding: nil"
)
check(!overlayOcclusionVerdict(injectedNoExclusion).isEmpty,
    "断言6（注入负对照）：不再排除屏幕自己那件 ⇒ 判据 FAIL。原话："
        + overlayOcclusionVerdict(injectedNoExclusion).joined(separator: "；"))

// 静态扫描：生产源码里不许有抓流 / 绕登录的能力痕迹。
let prohibitedHits = scanForProhibitedCapabilities(at: sourceRoot)
check(prohibitedHits.isEmpty,
    "断言5：生产代码里没有任何抓流 / 绕过登录 / 绕过地区的路径痕迹（扫 \(sourceRoot.lastPathComponent)/**，命中 \(prohibitedHits.count) 条）"
        + (prohibitedHits.isEmpty ? "" : " —— \(prohibitedHits.map(\.0).joined(separator: "；"))"))

// 注入：往一棵临时树里塞一条抓流路径 ⇒ 扫描器必须报出来。
let injectedTree = temporary.appendingPathComponent("ripping")
try FileManager.default.createDirectory(at: injectedTree, withIntermediateDirectories: true)
try "let fetcher = \"yt-dlp --cookies-from-browser safari -o out.mp4\"\n"
    .write(to: injectedTree.appendingPathComponent("Rip.swift"), atomically: true, encoding: .utf8)
let injectedHits = scanForProhibitedCapabilities(at: injectedTree)
check(injectedHits.count >= 2,
    "断言5（注入负对照）：塞进一条抓流路径 ⇒ 扫描器报出 \(injectedHits.count) 条命中（\(injectedHits.map(\.1).joined(separator: ", "))）")

// 白名单旁路注入：给 `WorldScreenEmbedPolicy` 开一个后门 ⇒ 不该放行的域名必须被放行，
// 从而证明"拒绝"这件事真的来自那份白名单，而不是别处的巧合。
let contentSource = try read(screenRoot.appendingPathComponent("WorldScreenContent.swift"))
let bypass = """
        if host.hasSuffix("googlevideo.com") { return .success(url) }
        guard let rule = rules.first(where: { $0.host == host }) else {
"""
let injectedContent = contentSource.replacingOccurrences(
    of: "        guard let rule = rules.first(where: { $0.host == host }) else {",
    with: bypass
)
check(injectedContent != contentSource, "断言5（注入负对照）：白名单旁路确实被注入到了源码副本里")
let patchedContent = temporary.appendingPathComponent("WorldScreenContentBypassed.swift")
try injectedContent.write(to: patchedContent, atomically: true, encoding: .utf8)
let bypassProgram = temporary.appendingPathComponent("main.swift")
try #"""
import Foundation
let result = WorldScreenEmbedPolicy.validate("https://r1---sn-x.googlevideo.com/videoplayback")
if case let .success(url) = result {
    print("BYPASS-ACCEPTED \(url.absoluteString)")
    exit(0)
}
print("BYPASS-REJECTED")
exit(1)
"""#.write(to: bypassProgram, atomically: true, encoding: .utf8)
let bypassExecutable = temporary.appendingPathComponent("bypass")
let bypassCompiled = try run(
    "/usr/bin/swiftc",
    ["-j1", patchedContent.path, bypassProgram.path, "-o", bypassExecutable.path]
)
if bypassCompiled != 0 {
    check(false, "断言5（注入负对照）：旁路副本没编起来（exit \(bypassCompiled)）")
} else {
    let bypassStatus = try run(bypassExecutable.path, [])
    check(bypassStatus == 0,
        "断言5（注入负对照）：给白名单开后门之后，`googlevideo.com` 直链**会被放行** ⇒ 证明拒绝确实来自白名单")
}

print(failureCount == 0 ? "PASS 电视机判据全部通过" : "FAIL 电视机判据有 \(failureCount) 条不通过")
exit(failureCount == 0 ? 0 : 1)
