// 电视机（屏幕四边形 + native 覆盖层 + 官方嵌入）的判据。
//
// 五条断言，每条都配**注入负对照**（"一个从不 FAIL 的门禁等于没有门禁"）：
//
//   1. 屏幕几何只有一处定义、可手动覆盖；推断不出来时**可见说明**（不硬猜）；
//   2. 覆盖层与屏幕四边形**几何一致**（给数字与容差）；相机移动后仍对齐；
//   3. **默认不抢场景鼠标**（「操作屏幕」开关默认关 ⇒ 关着时 `hitTest` 恒 nil；
//      注入"默认就是开" / "照常命中" / "进了模式也不给点" ⇒ 本 harness 必须 FAIL）；
//   4. 加载失败 / 无 URL / 几何缺失 ⇒ 各自**具名可见**失败，不静默；
//   5. 合规：只走**官方嵌入**；不许出现抓流 / 绕过登录的路径
//      （注入一条抓流路径 ⇒ 必须 FAIL；注入一条白名单旁路 ⇒ 必须 FAIL）；
//   5b. 播放参数**只有一个出口**（`WorldScreenEmbedOrigin.officialPlayerParameters`）：
//      换写/裸 id 交出来的链接里一个播放参数都不许有（注入"塞回一个" ⇒ 必须 FAIL）。
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
///
/// 2026-10-03：用户点不到网页里的按钮（覆盖层 `hitTest` 恒 `nil` 是红线的代价），
/// 于是多了「操作屏幕」这个**显式、默认关**的开关。判据的三条不变强也不变弱：
///   ① **默认必须是关**（`var acceptsScreenPointer = false`）；
///   ② 关着的时候必须**明确宣称不吃事件**（`guard acceptsScreenPointer else { return nil }`）；
///   ③ 开着的时候才把点交给子树（`return super.hitTest(point)`）—— 否则"进入后能点网页"
///      是假的。
/// 一个指针/键盘入口都不许新增（下表照旧），所以场景那 14 条链一个字都不用改。
func overlayPointerVerdict(_ source: String) -> [String] {
    var problems: [String] = []
    if !source.contains("var acceptsScreenPointer = false") {
        problems.append(
            "覆盖层容器的「操作屏幕」开关不是**默认关闭**（`var acceptsScreenPointer = false`）"
                + "：不进入这个模式时它必须恒不吃事件"
        )
    }
    if !source.contains("guard acceptsScreenPointer else { return nil }") {
        problems.append(
            "覆盖层容器没有 `guard acceptsScreenPointer else { return nil }`："
                + "它没有明确宣称「默认不吃事件」"
        )
    }
    if !source.contains("return super.hitTest(point)") {
        problems.append(
            "覆盖层容器进入「操作屏幕」模式后没有把点交给子树（`return super.hitTest(point)`）："
                + "网页永远收不到点击"
        )
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

/// 抓流、绕登录、绕地区的**能力痕迹**。
///
/// **范围已经更新**（用户本轮授权"链接优先 + 原生解析"）：这些字面量只允许出现在
/// `Screen/LinkResolver/` 与 `Screen/NativeMedia/` 两个受控目录里 —— 它们是解析器
/// 与原生播放器的实现细节。出现在别处（尤其是 `Screen/` 根、App、其它模块）一律红。
///
/// 凭据红线**不随范围放宽**：`cookie` / `Keychain` / `Authorization` 在受控目录里
/// 也一条都不许有（见 `credentialCapabilityTokens`）。
let prohibitedCapabilityTokens = [
    "yt-dlp", "youtube-dl", "ytdl", "googlevideo", "signatureCipher", "streamingData",
    "videoplayback", "n-sig", "decryptSignature", "widevine", "Widevine",
    "cookiesFromBrowser", "--cookies", "proxyStream", "bypassRegion", "geoBypass",
]

/// 允许出现上面那些 token 的**受控目录**（相对 `apps/macos/Sources/GMGNRadio`）。
let nativeLinkAllowedDirectories = ["Screen/LinkResolver", "Screen/NativeMedia"]

/// 即便在受控目录里也不许出现的凭据 / 系统授权痕迹。
let credentialCapabilityTokens = ["Keychain", "SecItem", "kSecClass", "Authorization: Bearer"]

/// 递归扫描一棵树，返回 `(文件, 命中词)`。受控目录里的解析器 token 放行；
/// 凭据 token 在任何地方都命中（含受控目录）。
func scanForProhibitedCapabilities(
    at directory: URL, controlledRoot: URL? = nil
) -> [(String, String)] {
    var hits: [(String, String)] = []
    let scopePath = (controlledRoot ?? sourceRoot).resolvingSymlinksInPath().standardizedFileURL.path
    let extensions: Set<String> = ["swift", "m", "mm", "c", "h", "py", "sh", "js", "ts", "json"]
    guard let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey]
    ) else { return hits }
    for case let url as URL in enumerator {
        guard extensions.contains(url.pathExtension.lowercased()) else { continue }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let relative = filePath.hasPrefix(scopePath + "/")
            ? String(filePath.dropFirst(scopePath.count + 1))
            : url.lastPathComponent
        let isControlled = nativeLinkAllowedDirectories.contains {
            relative.hasPrefix($0 + "/")
        }
        if isControlled {
            // 受控目录：解析器 token 放行，但**凭据红线照旧**。
            for token in credentialCapabilityTokens where text.contains(token) {
                hits.append(("\(url.lastPathComponent):\(token)", token))
            }
            continue
        }
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
    /// 「还没被认成屏幕」的物件：**运行时的另一份输入**。判据换一份它，答复就必须跟着换
    /// —— 写死"是哪一件"的实现在这里立刻红。
    var candidates: [WorldScreenCandidate]
    var playResult: WorldScreenCommandOutcome
    var stopResult: WorldScreenCommandOutcome
    init(screens: [WorldScreenSnapshot] = [], candidates: [WorldScreenCandidate] = [],
         playResult: WorldScreenCommandOutcome,
         stopResult: WorldScreenCommandOutcome) {
        self.screens = screens; self.candidates = candidates
        self.playResult = playResult; self.stopResult = stopResult
    }
    func listScreens() -> [WorldScreenSnapshot] { screens }
    func unrecognizedScreenCandidates() -> [WorldScreenCandidate] { candidates }
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
            // 期望值**从生产那一处派生**（`WorldScreenResolution.bezelMargin`），而不是在这儿
            // 再写一个比例：屏幕多大只有一处定义。这里原来钉的是 `tvSize.x * panelInset`
            // （0.86）—— 那一条把缺陷的数值钉进了门禁，屏幕铺不满正面时它反而是绿的。
            let expectedWidth = tvSize.x
                - 2 * WorldScreenResolution.bezelMargin(faceWidth: tvSize.x, faceHeight: tvSize.y)
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
              let readTool = tools.first(where: { $0.name == "read_screen" }),
              let stopTool = tools.first(where: { $0.name == "stop_screen" })
        else { expect(false, "断言4：找不到 play_screen / stop_screen / read_screen"); return }
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
        // 断言 8：能力被看见 —— 工具说明教会它，答复说的是**运行时**那一件
        // =============================================================
        // 真机 2026-10-02：用户说「电视播放 <YouTube 链接>」，居民答「那台电视是我做出来的
        // 外形摆件，没有播放功能」。工具在不在是一回事，**能力有没有被看见**是另一回事：
        // 说明没写"什么时候用、放什么链接"，系统提示里一个字都没有 —— 模型只能自己推断出
        // "外形摆件"。这两条断言钉的就是"它知道这件事"。

        // ① 说明：这是什么、什么时候用、放什么链接。
        expect(playTool.description.contains("官方嵌入")
                && playTool.description.contains("YouTube")
                && playTool.description.contains("哔哩哔哩"),
            "断言8：play_screen 的说明写明放的是官方嵌入链接（YouTube / 哔哩哔哩）")
        expect(playTool.description.contains("电视") && playTool.description.contains("用电视放这个链接"),
            "断言8：play_screen 的说明写明什么时候用它（用户说「用电视放这个链接」）")
        expect(readTool.description.contains("有没有") && readTool.description.contains("哪一件"),
            "断言8：read_screen 的说明写明先看「有没有、是哪一件」")
        expect(readTool.description.contains("还没被认成屏幕") && readTool.description.contains("怎么改"),
            "断言8：read_screen 的说明写明一件都没有时会说清是哪一件、怎么改")
        expect(!stopTool.description.isEmpty && stopTool.description.contains("电视"),
            "断言8：stop_screen 的说明说清它关的是电视")

        // ② 「是哪一件」必须从**运行时**来：换一份注册表 ⇒ 答复跟着换（写死就红）。
        let namedCandidates = [WorldScreenCandidate(
            objectID: "obj-大屏", displayName: "超大荧幕电视",
            reason: "这块面像一块屏幕，但名字里没有「电视」或「屏幕」"
        )]
        let screenlessControl = StubScreenControl(
            screens: [], candidates: namedCandidates,
            playResult: .failure(.screenNotFound, "这个空间里现在没有电视。"),
            stopResult: .failure(.screenNotFound, "没有可关的电视。")
        )
        let screenlessTools = ResidentScreenTools(control: screenlessControl, isCurrent: { true }).tools
        let screenlessRead = await screenlessTools.first(where: { $0.name == "read_screen" })!
            .handle("call-6", Data("{}".utf8))
        let screenlessPayload = (try? JSONSerialization.jsonObject(
            with: screenlessRead.payloadJSON)) as? [String: Any]
        let screenlessMessage = (screenlessPayload?["message"] as? String) ?? ""
        expect(screenlessRead.isError == false && screenlessRead.code == "insufficient_input",
            "断言8：一件屏幕都没有时 read_screen 走信息不足通道（不是「我做不到」式的失败）")
        expect(screenlessMessage.contains("超大荧幕电视") && screenlessMessage.contains("还没被认成屏幕"),
            "断言8：read_screen 具名说出是哪一件还没被认成屏幕：「\(screenlessMessage)」")
        expect(screenlessMessage.contains("名字里带上「电视」"),
            "断言8：read_screen 给出可行动的下一步（怎么改）：「\(screenlessMessage)」")
        expect(screenlessRead.isError == false
                && screenlessMessage.contains("这块面像一块屏幕"),
            "断言8：原因用的是运行时给的那一句，不是工具层自己编的")

        // 换一份运行时注册（另一件物件、另一个原因）⇒ 同一份工具必须给出**另一句**答复。
        let otherCandidates = [WorldScreenCandidate(
            objectID: "obj-旧", displayName: "旧显示器",
            reason: "名字像电视，但这一帧没读出可用的屏幕范围"
        )]
        let otherControl = StubScreenControl(
            screens: [], candidates: otherCandidates,
            playResult: .failure(.screenNotFound, "这个空间里现在没有电视。"),
            stopResult: .failure(.screenNotFound, "没有可关的电视。")
        )
        let otherRead = await ResidentScreenTools(control: otherControl, isCurrent: { true })
            .tools.first(where: { $0.name == "read_screen" })!.handle("call-7", Data("{}".utf8))
        let otherMessage = ((try? JSONSerialization.jsonObject(with: otherRead.payloadJSON))
            as? [String: Any])?["message"] as? String ?? ""
        expect(otherMessage.contains("旧显示器") && !otherMessage.contains("超大荧幕电视"),
            "断言8：换一份运行时注册 ⇒ 答复跟着换（写死「是哪一件」在这里必红）：「\(otherMessage)」")

        // 候选为空 ⇒ 如实说"没有一件物件被认成屏幕" + 怎么改，绝不认领一件。
        let bareControl = StubScreenControl(
            screens: [], candidates: [],
            playResult: .failure(.screenNotFound, "这个空间里现在没有电视。"),
            stopResult: .failure(.screenNotFound, "没有可关的电视。")
        )
        let bareRead = await ResidentScreenTools(control: bareControl, isCurrent: { true })
            .tools.first(where: { $0.name == "read_screen" })!.handle("call-8", Data("{}".utf8))
        let bareMessage = ((try? JSONSerialization.jsonObject(with: bareRead.payloadJSON))
            as? [String: Any])?["message"] as? String ?? ""
        expect(bareMessage.contains("没有一件物件被认成屏幕")
                && bareMessage.contains("名字里带「电视」")
                && !bareMessage.contains("旧显示器"),
            "断言8：一件候选都没有时如实说没有、并给出怎么改：「\(bareMessage)」")

        // ③ 放不了时：工具**原样转达**运行时给的具名原因（不许改写成一句笼统拒绝）。
        let namedPlayFailure = "这个空间里现在没有电视。"
            + "这些物件还没被认成屏幕：「超大荧幕电视」（这块面像一块屏幕，但名字里没有「电视」或「屏幕」）。"
            + "把名字里带上「电视」或「屏幕」，或者换一件。"
        let namedFailureControl = StubScreenControl(
            screens: [], candidates: namedCandidates,
            playResult: .failure(.screenNotFound, namedPlayFailure),
            stopResult: .failure(.screenNotFound, "没有可关的电视。")
        )
        let namedFailureReply = await ResidentScreenTools(control: namedFailureControl, isCurrent: { true })
            .tools.first(where: { $0.name == "play_screen" })!
            .handle("call-9", Data(#"{"url":"https://www.youtube.com/watch?v=aPcL35kgL6A"}"#.utf8))
        let namedFailureMessage = ((try? JSONSerialization.jsonObject(
            with: namedFailureReply.payloadJSON)) as? [String: Any])?["message"] as? String ?? ""
        expect(namedFailureReply.isError && namedFailureReply.code == "screen_not_found",
            "断言8：放不了 ⇒ 具名错误码 screen_not_found（不是静默成功）")
        expect(namedFailureMessage == namedPlayFailure
                && namedFailureMessage.contains("超大荧幕电视")
                && namedFailureMessage.contains("把名字里带上"),
            "断言8：放不了的答复是具名且可行动的，被工具原样转达：「\(namedFailureMessage)」")

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
            ("BV1xx411c7mD", "https://player.bilibili.com/player.html?bvid=BV1xx411c7mD"),
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
        // 断言 5b：播放参数**只有一个出口**
        // =============================================================
        //
        // 白名单（`WorldScreenEmbedPolicy.validate`）交出来的链接里**一个播放参数都不许有**。
        // 真机 2026-10-02：我们自己写进 B 站链接的 `autoplay=0` 就是「播放器起得来但不播」
        // 的根因；而站方读的是**第一个**同名参数，所以"换写时塞一个、承载页再补一个"
        // 这种两处出口的写法**必然**把承载页那一份废掉。播放参数的唯一出口是承载页的
        // `WorldScreenEmbedOrigin.officialPlayerParameters`。
        let playbackParameterNames: Set<String> = [
            "autoplay", "mute", "muted", "controls", "loop", "start", "end",
            "playsinline", "parent", "enablejsapi", "origin", "rel", "modestbranding",
        ]
        let sourceLinkInputs = [
            "https://www.youtube.com/embed/dQw4w9WgXcQ",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ",
            "dQw4w9WgXcQ",
            "https://www.bilibili.com/video/BV1xx411c7mD",
            "https://player.bilibili.com/player.html?bvid=BV1xx411c7mD",
            "BV1xx411c7mD",
        ]
        for input in sourceLinkInputs {
            guard case let .success(url) = WorldScreenEmbedPolicy.validate(input) else {
                expect(false, "断言5b：合法的官方嵌入「\(input)」被拒了")
                continue
            }
            let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems ?? []).map(\.name)
            let offenders = names.filter { playbackParameterNames.contains($0.lowercased()) }
            expect(offenders.isEmpty,
                "断言5b：换写/裸 id 交出来的链接里不许有播放参数（「\(input)」⇒ \(url.absoluteString)"
                    + " 带 \(offenders)）：播放参数只有承载页一个出口")
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
let compiledCapture = try runFitCapture(
    "/usr/bin/swiftc",
    ["-j1", "-parse-as-library"] + screenSources + [program.path, "-o", executable.path]
)
if compiledCapture.status != 0 {
    // 编译器原话要贴出来：只说"编译失败"等于没有信息（改坏了哪一处，当场看得见）。
    for line in compiledCapture.output.split(separator: "\n").prefix(40) {
        print("   · [内层编译] \(line)")
    }
}
let compiled = compiledCapture.status
guard compiled == 0 else {
    print("FAIL 内层程序编译失败（exit \(compiled)）—— 判据没能跑起来")
    exit(compiled)
}
let innerStatus = try run(executable.path, [])
check(innerStatus == 0, "内层判据（断言 1/2/4/5-白名单/6-遮挡/7-真机道具的面/8-能力可见）全部通过")

// ---------------------------------------------------------------------------
// MARK: 断言 8（文本）：居民系统提示里那条常识 + 放不了时的具名可行动
// ---------------------------------------------------------------------------

/// 系统提示里**必须**有的那条常识：物件可能带屏幕、先 read_screen 再 play_screen、
/// 放不了要说清哪一件/为什么/怎么改。真机现场是"一句都没有"，模型只能推断成"外形摆件"。
func screenCapabilityTeachingProblems(_ promptSource: String) -> [String] {
    var problems: [String] = []
    for needle in ["read_screen", "play_screen", "官方嵌入", "带屏幕"] {
        if !promptSource.contains(needle) {
            problems.append("系统提示里没有「\(needle)」：居民不知道空间里的物件可能带屏幕")
        }
    }
    if !promptSource.contains("不要只说做不到") {
        problems.append("系统提示没有要求放不了时说清是哪一件、为什么、怎么改（只剩一句「我做不到」）")
    }
    return problems
}

/// 「放不了」时那几句话**必须**具名且可行动。判据是文本级的，因为这些话住在
/// `WorldScreenStore`（App 侧要 AppKit，编不进离线 harness），而它正是居民读到的原文。
func screenFailureGuidanceProblems(_ storeSource: String) -> [String] {
    var problems: [String] = []
    for needle in ["还没被认成屏幕", "名字里带「电视」或「屏幕」", "unrecognized_ids"] {
        if !storeSource.contains(needle) {
            problems.append("放不了时的答复缺少「\(needle)」：既说不出是哪一件，也说不出怎么改")
        }
    }
    // 只看**当作答复用的那一句**（`.screenNotFound, "…"`），不看注释里引用过的说法。
    if storeSource.contains("screenNotFound, \"我做不到") || storeSource.contains("needsInput(\"我做不到") {
        problems.append("放不了时的答复退化成了笼统拒绝（「我做不到」）")
    }
    return problems
}

let residentPromptSource = try read(
    sourceRoot.appendingPathComponent("Agent/AgentConversationService.swift")
)
let storeSource = try read(screenRoot.appendingPathComponent("WorldScreenStore.swift"))

let teachingProblems = screenCapabilityTeachingProblems(residentPromptSource)
for problem in teachingProblems { print("   · \(problem)") }
check(teachingProblems.isEmpty,
    "断言8：居民系统提示教会了它「物件可能带屏幕、先 read_screen 再 play_screen、放不了要说清三样」")

let guidanceProblems = screenFailureGuidanceProblems(storeSource)
for problem in guidanceProblems { print("   · \(problem)") }
check(guidanceProblems.isEmpty,
    "断言8：放不了时的答复具名且可行动（说得出是哪一件、怎么改），不是笼统「我做不到」")

// 注入负对照（在**源码副本**上做手术，真源码一个字节都不动）：
// ① 把系统提示那条常识删掉 ⇒ 判据必须红。
let promptWithoutTeaching = residentPromptSource.replacingOccurrences(
    of: "空间里的物件可能带屏幕：用户让你放视频时，先用 read_screen 看这个空间里有没有、是哪一件，再用 play_screen 把用户给的官方嵌入链接（YouTube、哔哩哔哩等）放上去；\n        放不了就说清是哪一件、为什么、该怎么改，不要只说做不到。带屏幕的物件是真的能放，不是只能摆着看的外形。\n        ",
    with: ""
)
check(promptWithoutTeaching != residentPromptSource,
    "断言8（注入负对照）：系统提示那条常识确实被从副本里删掉了")
check(!screenCapabilityTeachingProblems(promptWithoutTeaching).isEmpty,
    "断言8（注入负对照）：删掉系统提示那条常识 ⇒ 判据必须红（第一条："
        + "\(screenCapabilityTeachingProblems(promptWithoutTeaching).first ?? "（没有）")）")

// ② 把"放不了"的答复换成一句笼统拒绝 ⇒ 判据必须红。
let genericFailure = storeSource.replacingOccurrences(
    of: ".failure(\n                .screenNotFound, message,",
    with: ".failure(\n                .screenNotFound, \"我做不到。\","
)
check(genericFailure != storeSource, "断言8（注入负对照）：笼统拒绝确实被注入到了 store 副本里")
check(!screenFailureGuidanceProblems(genericFailure).isEmpty,
    "断言8（注入负对照）：放不了的答复改成笼统「我做不到」⇒ 判据必须红（第一条："
        + "\(screenFailureGuidanceProblems(genericFailure).first ?? "（没有）")）")

// ③ 把「是哪一件」写死 / 把空回执换成笼统拒绝 ⇒ **同一份内层判据**必须 FAIL。
//    这里真的把源码副本编起来再跑一遍：判据能抓的缺陷，注入之后必须抓得到。
//    注入版的输出**收起来加前缀**：那几行红是"判据抓到了"，不是"门禁不过"，
//    不许混进门禁日志的 `^FAIL` 计数里（与 `PROBE-FAIL` 同一纪律）。
func runCapturingInner(_ executable: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    for line in String(decoding: data, as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
        print("   · [注入内层] \(line)")
    }
    return process.terminationStatus
}

func innerJudgementStatus(patching file: String, _ surgery: (String) -> String) throws
    -> (changed: Bool, status: Int32) {
    let original = try read(screenRoot.appendingPathComponent(file))
    let patched = surgery(original)
    guard patched != original else { return (false, -3) }
    let patchedURL = temporary.appendingPathComponent("patched-\(file)")
    try patched.write(to: patchedURL, atomically: true, encoding: .utf8)
    let sources = screenFiles.map { name in
        name == file ? patchedURL.path : screenRoot.appendingPathComponent(name).path
    }
    let patchedExecutable = temporary.appendingPathComponent("patched-\(UUID().uuidString)")
    let patchedCompiled = try run(
        "/usr/bin/swiftc",
        ["-j1", "-parse-as-library"] + sources + [program.path, "-o", patchedExecutable.path]
    )
    // 编译不过 = 这次注入没能跑成判据：返回 -2，调用方的 `== 1` 断言必须红（不许把
    // "没跑起来"当成"判据抓到了"）。
    guard patchedCompiled == 0 else { return (true, -2) }
    return (true, try runCapturingInner(patchedExecutable.path))
}

let hardcodedNames = try innerJudgementStatus(patching: "ResidentScreenTools.swift") { source in
    source.replacingOccurrences(
        of: "let candidates = control.unrecognizedScreenCandidates()",
        with: "let candidates = [WorldScreenCandidate(objectID: \"写死的\", "
            + "displayName: \"写死的电视\", reason: \"编的原因\")]"
    )
}
check(hardcodedNames.changed, "断言8（注入负对照）：写死「是哪一件」的手术确实改到了源码副本")
check(hardcodedNames.status == 1,
    "断言8（注入负对照）：把「是哪一件」写死 ⇒ 内层判据必须 FAIL（exit 1，实测 \(hardcodedNames.status)）")

let genericInner = try innerJudgementStatus(patching: "ResidentScreenTools.swift") { source in
    source.replacingOccurrences(
        of: "screenlessMessage(candidates),",
        with: "\"我做不到。\","
    )
}
check(genericInner.changed, "断言8（注入负对照）：笼统拒绝的手术确实改到了源码副本")
check(genericInner.status == 1,
    "断言8（注入负对照）：空回执改成笼统「我做不到」⇒ 内层判据必须 FAIL（exit 1，实测 \(genericInner.status)）")


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
    "断言3：覆盖层默认不吃场景鼠标（「操作屏幕」开关默认关、关着时 hitTest 恒 nil、"
        + "进入后才把点交给网页，且没有覆写任何指针/键盘入口）"
        + (overlayProblems.isEmpty ? "" : " —— \(overlayProblems.joined(separator: "；"))"))

// 注入①：**默认改成开**（开关的初值不再是 false）⇒ 判据必须红。
// 这是「默认绝不影响场景」那一条最直接的负对照。
let injectedDefaultOn = overlaySource.replacingOccurrences(
    of: "var acceptsScreenPointer = false",
    with: "var acceptsScreenPointer = true"
)
check(injectedDefaultOn != overlaySource,
    "断言3（注入负对照①）：开关的默认值确实被从 `false` 改成了 `true`")
let injectedDefaultOnProblems = overlayPointerVerdict(injectedDefaultOn)
check(!injectedDefaultOnProblems.isEmpty,
    "断言3（注入负对照①「默认就是开」）：判据 FAIL。原话："
        + injectedDefaultOnProblems.joined(separator: "；"))

// 注入②：去掉"关着就不吃事件"的那道闸（照常命中）⇒ 判据必须红。
let injectedHitTest = overlaySource.replacingOccurrences(
    of: "        guard acceptsScreenPointer else { return nil }\n        return super.hitTest(point)",
    with: "        return super.hitTest(point)"
)
check(injectedHitTest != overlaySource,
    "断言3（注入负对照②）：`guard acceptsScreenPointer else { return nil }` 确实被从副本里拿掉了")
let injectedHitTestProblems = overlayPointerVerdict(injectedHitTest)
check(!injectedHitTestProblems.isEmpty,
    "断言3（注入负对照②「照常命中」）：判据 FAIL。原话："
        + injectedHitTestProblems.joined(separator: "；"))

// 注入③：进入模式之后**也不**把点交给子树（hitTest 恒 nil）⇒ 判据必须红：
// 否则"进入后网页能收到点击"就是一句空话。
let injectedNeverHit = overlaySource.replacingOccurrences(
    of: "        guard acceptsScreenPointer else { return nil }\n        return super.hitTest(point)",
    with: "        guard acceptsScreenPointer else { return nil }\n        return nil"
)
check(injectedNeverHit != overlaySource,
    "断言3（注入负对照③）：`return super.hitTest(point)` 确实被从副本里换成了 `return nil`")
let injectedNeverHitProblems = overlayPointerVerdict(injectedNeverHit)
check(!injectedNeverHitProblems.isEmpty,
    "断言3（注入负对照③「进了模式也不给点」）：判据 FAIL。原话："
        + injectedNeverHitProblems.joined(separator: "；"))

// 注入④：加一个 mouseDown ⇒ 判据必须红。
let injectedMouseDown = overlaySource.replacingOccurrences(
    of: "override var acceptsFirstResponder: Bool { false }",
    with: "override var acceptsFirstResponder: Bool { false }\n    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event) }"
)
let injectedMouseDownProblems = overlayPointerVerdict(injectedMouseDown)
check(!injectedMouseDownProblems.isEmpty,
    "断言3（注入负对照④）：给覆盖层加一个 mouseDown ⇒ 判据 FAIL。原话："
        + injectedMouseDownProblems.joined(separator: "；"))

// ---------------------------------------------------------------------------
// MARK: 断言 5b（静态扫描）：播放参数的**唯一出口**是 `WorldScreenEmbedOrigin`
// ---------------------------------------------------------------------------

/// 「播放参数有几个来源」的**唯一**判据（文本级：`Screen/` 整目录一起看）。
///
/// 判据是"文件级唯一"而不是"函数级唯一"：`Screen/` 是这块屏幕的全部生产源码，
/// 只要播放参数还出现在**第二个文件**里，就说明链接上又长出了一处我们自己的参数来源
/// —— 而站方读**第一个**同名参数，两处出口必然互相废掉（真机 2026-10-02 的
/// 「B 站起得来但不播」正是这么来的）。
///
/// 用不着逐字匹参数值：`autoplay=` / `mute=` 这类字面量本身就在这里出现一次都嫌多。
let playbackParameterLiterals = [
    "autoplay=", "mute=", "muted=", "controls=", "loop=",
    "playsinline=", "parent=", "enablejsapi=", "modestbranding=",
]

func playbackParameterSourceVerdict(_ sources: [String: String]) -> [String] {
    var problems: [String] = []
    for (name, text) in sources.sorted(by: { $0.key < $1.key })
    where name != "WorldScreenEmbedOrigin.swift" {
        for literal in playbackParameterLiterals where text.contains(literal) {
            problems.append(
                "\(name) 里出现了播放参数「\(literal)」：链接上的播放参数只允许"
                    + " `WorldScreenEmbedOrigin.officialPlayerParameters` 一个出口"
            )
        }
    }
    return problems
}

let screenSourceTexts: [String: String] = try Dictionary(
    uniqueKeysWithValues: (screenFiles + ["WorldScreenEmbedOrigin.swift"]).map {
        ($0, try read(screenRoot.appendingPathComponent($0)))
    }
)
let playbackSourceProblems = playbackParameterSourceVerdict(screenSourceTexts)
check(playbackSourceProblems.isEmpty,
    "断言5b：播放参数只有一个出口（`Screen/` 里除 `WorldScreenEmbedOrigin.swift` 外"
        + "没有任何文件写播放参数）"
        + (playbackSourceProblems.isEmpty ? "" : " —— \(playbackSourceProblems.joined(separator: "；"))"))
check(screenSourceTexts["WorldScreenEmbedOrigin.swift"]?.contains("officialPlayerParameters") == true,
    "断言5b：唯一出口确实是 `WorldScreenEmbedOrigin.officialPlayerParameters`（承重墙在那儿）")

// 注入：把 `autoplay=0` 塞回换写那条路 ⇒ 判据必须红（这就是真机上发生过的那一次）。
let injectedSecondSource = screenSourceTexts.mapValues { text in
    text.replacingOccurrences(
        of: "return \"https://player.bilibili.com/player.html?bvid=\\(id)\"",
        with: "return \"https://player.bilibili.com/player.html?bvid=\\(id)&autoplay=0\""
    )
}
let injectedSecondSourceProblems = playbackParameterSourceVerdict(injectedSecondSource)
check(injectedSecondSourceProblems != playbackSourceProblems,
    "断言5b（注入负对照）：`autoplay=0` 确实被塞回了 `WorldScreenContent.swift` 的副本里")
check(!injectedSecondSourceProblems.isEmpty,
    "断言5b（注入负对照）：链接上出现**第二个播放参数来源** ⇒ 判据 FAIL。原话："
        + injectedSecondSourceProblems.joined(separator: "；"))

// 同一条判据在**内层程序**里也跑一遍（这次是真编起来跑的）：
// 把 `autoplay=0` 塞回换写那条路 ⇒ 内层断言 5b 必须 FAIL（exit 1）。
let secondPlaybackSourceInner = try innerJudgementStatus(patching: "WorldScreenContent.swift") { source in
    source.replacingOccurrences(
        of: "return \"https://player.bilibili.com/player.html?bvid=\\(id)\"",
        with: "return \"https://player.bilibili.com/player.html?bvid=\\(id)&autoplay=0\""
    )
}
check(secondPlaybackSourceInner.changed,
    "断言5b（注入负对照）：`autoplay=0` 的手术确实改到了 `WorldScreenContent.swift` 的副本")
check(secondPlaybackSourceInner.status == 1,
    "断言5b（注入负对照）：换写里塞回 `autoplay=0` ⇒ 内层断言必须 FAIL"
        + "（exit 1，实测 \(secondPlaybackSourceInner.status)）")

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
    if !source.contains("guard let mask, !mask.isFullyVisible")
        || !source.contains("container.layer?.mask = nil") {
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
    of: "guard let mask, !mask.isFullyVisible, size.x > 0, size.y > 0 else",
    with: "guard let mask, mask.cellCount > 0, size.x > 0, size.y > 0 else"
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

// 范围注入 A：受控目录（`Screen/LinkResolver/`）里的解析器 token 必须**放行**。
let controlledTree = temporary.appendingPathComponent("controlled-root")
let controlledResolver = controlledTree.appendingPathComponent("Screen/LinkResolver")
try FileManager.default.createDirectory(at: controlledResolver, withIntermediateDirectories: true)
try "let helper = \"yt-dlp --no-cookies\"\n"
    .write(to: controlledResolver.appendingPathComponent("Resolver.swift"),
           atomically: true, encoding: .utf8)
let controlledHits = scanForProhibitedCapabilities(at: controlledTree, controlledRoot: controlledTree)
check(controlledHits.isEmpty,
    "断言5（范围）：受控目录里的解析器 token 放行（命中 \(controlledHits.count) 条）")

// 范围注入 B：同样的 token 出现在 `Screen/` 根（非受控）⇒ 必须红。
let offScopeTree = temporary.appendingPathComponent("off-scope-root")
let offScopeScreen = offScopeTree.appendingPathComponent("Screen")
try FileManager.default.createDirectory(at: offScopeScreen, withIntermediateDirectories: true)
try "let helper = \"yt-dlp\"\n"
    .write(to: offScopeScreen.appendingPathComponent("Rip.swift"),
           atomically: true, encoding: .utf8)
let offScopeHits = scanForProhibitedCapabilities(at: offScopeTree, controlledRoot: offScopeTree)
check(offScopeHits.contains { $0.1 == "yt-dlp" },
    "断言5（范围负对照）：受控目录之外的解析器 token 必须红（命中 \(offScopeHits.count) 条）")

// 凭据红线：即便在受控目录里，`Keychain` 也必须红。
let credentialTree = temporary.appendingPathComponent("credential-root")
let credentialResolver = credentialTree.appendingPathComponent("Screen/LinkResolver")
try FileManager.default.createDirectory(at: credentialResolver, withIntermediateDirectories: true)
try "let store = Keychain()\n"
    .write(to: credentialResolver.appendingPathComponent("Bad.swift"),
           atomically: true, encoding: .utf8)
let credentialHits = scanForProhibitedCapabilities(at: credentialTree, controlledRoot: credentialTree)
check(credentialHits.contains { $0.1 == "Keychain" },
    "断言5（凭据红线）：受控目录里的 Keychain 也必须红（命中 \(credentialHits.count) 条）")

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

// ---------------------------------------------------------------------------
// MARK: 断言 9：屏幕**铺满**最终正面（真机 2026-10-02「屏幕也没有 filled」）
// ---------------------------------------------------------------------------
//
// 修的是什么：屏幕四边形原来把每一面缩到 **86%**（`panelInset = 0.86`，每边吃掉该轴
// 7%）。真机那台 `1443 × 862 × 302 mm` 的电视，最终正面是 `1.443 × 0.862 m`，屏幕
// 四边形只有 `1.241 × 0.741 m`：左右各缩进 **101 mm**、上下各 **60 mm**，面积只占
// 正面的 **73.96%** —— 截图里那块"缩在正面中间、还偏下"的暗矩形就是它。
//
// 根因是 **inset 的取值**，不是"算在未拉伸的坐标系里"：`WorldScreenStore.resolve`
// 一直传的是 `generatedProp.effectiveSize`（**最终**尺寸），而**如果**它真按未拉伸的
// 网格 AABB 算，真机那份 GLB 实测 `1.0079 × 0.6287 × 1.0079` 的最薄/最长 =
// 0.62 > 0.25，会走 `notPanelLike` **具名拒绝** —— 连四边形都不会有。下面把这一条
// 也钉住（"未拉伸的 AABB 必须是具名拒绝"）。
//
// 判据（面积阈值 / 板形判据 / 最大平坦面那套）**一个字都没放宽**：9.4 就是钉它们的，
// 两条注入负对照（放宽任一条）必须红。
//
// 探针直接编**生产**的 `WorldScreenGeometry.swift` + `WorldScreenInference.swift`
// （这两份只依赖 Foundation + simd），只读它们的公开几何出口：`resolve` / `quad` /
// `corners` / `WorldScreenDefinitionCoding`。六条注入负对照在**临时副本**上做手术，
// 生产源码一个字节都不动。

let fitProbeProgram = ##"""
import Foundation
import simd

var failures = 0
func probe(_ condition: Bool, _ message: String) {
    if condition { print("FIT-PASS \(message)") } else { print("FIT-FAIL \(message)"); failures += 1 }
}
func f(_ value: Float) -> String { String(format: "%.4f", value) }
func percent(_ value: Float) -> String { String(format: "%.2f", value * 100) }

@main struct FitProbe {
    static func main() {
        // ---- 9.4：「屏幕推断判据零放宽」 ----
        probe(WorldScreenResolution.minimumFaceArea == 0.04,
              "9.4：面积阈值仍是 0.04 m²（实测 \(WorldScreenResolution.minimumFaceArea)）")
        probe(WorldScreenResolution.maximumPanelThicknessRatio == 0.25,
              "9.4：板形判据仍是 最薄/最长 ≤ 0.25（实测 \(WorldScreenResolution.maximumPanelThicknessRatio)）")
        if case let .failure(issue) = WorldScreenResolution.resolve(
            objectID: "cube", calibratedJSON: nil, size: SIMD3(1, 1, 1), allowsDefault: false
        ), case .notPanelLike = issue {
            probe(true, "9.4：1 × 1 × 1 的方块仍然判不出屏幕（notPanelLike）")
        } else {
            probe(false, "9.4：一个 1 × 1 × 1 的方块被当成了屏幕 —— 判据被放宽了")
        }
        if case let .failure(issue) = WorldScreenResolution.resolve(
            objectID: "tiny", calibratedJSON: nil, size: SIMD3(0.12, 0.12, 0.01), allowsDefault: false
        ), case .belowAreaThreshold = issue {
            probe(true, "9.4：12 cm 见方的面仍然低于面积阈值")
        } else {
            probe(false, "9.4：12 cm 见方的面被当成了屏幕 —— 面积阈值被放宽了")
        }
        // ---- 9.1：「在未拉伸的网格 AABB 里算」那一路不存在 ----
        if case let .failure(issue) = WorldScreenResolution.resolve(
            objectID: "raw", calibratedJSON: nil, size: SIMD3(1.0079, 0.6287, 1.0079),
            allowsDefault: false
        ), case .notPanelLike = issue {
            probe(true, "9.1：未拉伸的网格 AABB（真机 GLB 实测 1.0079 × 0.6287 × 1.0079）"
                + "走的是具名拒绝 ⇒ 现网那份四边形不可能算在这个坐标系里")
        } else {
            probe(false, "9.1：未拉伸的网格 AABB 被当成了屏幕 —— 屏幕几何回到未拉伸的坐标系了")
        }

        // ---- 9.1 / 9.2 / 9.3：三个尺寸各量一次 ----
        let cases: [(String, SIMD3<Float>)] = [
            ("真机 1443 × 862 × 302 mm", SIMD3(1.443, 0.862, 0.302)),
            ("1000 × 500 × 80 mm", SIMD3(1.0, 0.5, 0.08)),
            ("600 × 340 × 60 mm", SIMD3(0.6, 0.34, 0.06)),
        ]
        for (label, size) in cases {
            guard case let .success(definition) = WorldScreenResolution.resolve(
                objectID: "tv-fit", calibratedJSON: nil, size: size, allowsDefault: false
            ) else {
                probe(false, "\(label)：推断不出屏幕"); continue
            }
            let quad = definition.quad
            let faceWidth = size.x
            let faceHeight = size.y
            let coverage = (quad.width * quad.height) / (faceWidth * faceHeight)
            let marginX = (faceWidth - quad.width) / 2
            let marginY = (faceHeight - quad.height) / 2
            let corners = quad.corners
            print("FIT-NUM \(label)：正面 \(f(faceWidth)) × \(f(faceHeight)) m"
                + " ⇒ 四边形 \(f(quad.width)) × \(f(quad.height)) m"
                + "，覆盖率 面积 \(percent(coverage))% / 线宽 \(percent(quad.width / faceWidth))%"
                + " / 线高 \(percent(quad.height / faceHeight))%"
                + "，边框余量 每边 x \(f(marginX)) y \(f(marginY)) m"
                + "，中心 \(f(quad.center.x)), \(f(quad.center.y)), \(f(quad.center.z))")
            print("FIT-CORNERS \(label)：BL \(f(corners[0].x)), \(f(corners[0].y)), \(f(corners[0].z))"
                + " BR \(f(corners[1].x)), \(f(corners[1].y)), \(f(corners[1].z))"
                + " TR \(f(corners[2].x)), \(f(corners[2].y)), \(f(corners[2].z))"
                + " TL \(f(corners[3].x)), \(f(corners[3].y)), \(f(corners[3].z))")
            probe(definition.source == .inferred, "\(label)：仍走推断那一级（\(definition.source.rawValue)）")
            probe(coverage >= 0.95, "9.1 \(label)：屏幕占正面 ≥ 95%（实测 \(percent(coverage))%）")
            probe(quad.width / faceWidth >= 0.95 && quad.height / faceHeight >= 0.95,
                  "9.1 \(label)：两条边都铺到 ≥ 95%（线宽 \(percent(quad.width / faceWidth))%，"
                    + "线高 \(percent(quad.height / faceHeight))%）")
            probe(marginX > 0 && marginY > 0,
                  "9.1 \(label)：四角落在正面边缘**内侧**（余量 \(f(marginX)) / \(f(marginY)) m > 0）")
            probe(marginX <= faceWidth * 0.025 && marginY <= faceHeight * 0.025,
                  "9.1 \(label)：边框余量每边 ≤ 该轴 2.5%（\(f(marginX)) ≤ \(f(faceWidth * 0.025))，"
                    + "\(f(marginY)) ≤ \(f(faceHeight * 0.025))）")
            probe(abs(quad.center.x) <= 1e-6 && abs(quad.center.y - faceHeight / 2) <= 1e-6,
                  "9.1 \(label)：面内中心就是正面中心（偏移 \(f(quad.center.x)), "
                    + "\(f(quad.center.y - faceHeight / 2))）")
            probe(abs(quad.center.z - (size.z / 2 + WorldScreenResolution.surfaceOffset)) <= 1e-6,
                  "9.1 \(label)：法向外移只有防共面闪烁的那 "
                    + "\(WorldScreenResolution.surfaceOffset) m（实测 \(f(quad.center.z))）")
            probe(abs(quad.normal.x) <= 1e-6 && abs(quad.normal.y) <= 1e-6
                    && abs(quad.normal.z - 1) <= 1e-6,
                  "9.1 \(label)：屏幕朝向仍是正面 +Z（\(f(quad.normal.x)), \(f(quad.normal.y)), "
                    + "\(f(quad.normal.z))）")
            probe(corners.allSatisfy {
                abs($0.z - (size.z / 2 + WorldScreenResolution.surfaceOffset)) <= 1e-6
            }, "9.1 \(label)：四角都贴在正面那一层（z = size.z/2 + surfaceOffset）")
            // ---- 9.3：四角是**派生**的，不是第二份存货 ----
            // 用四边形自己的右轴 / 上轴（含 pitch）：于是这条对任意朝向都成立，
            // 而不是只在 pitch = 0 时恰好对。
            let right = quad.right * quad.halfWidth
            let up = quad.up * quad.halfHeight
            let derived = [quad.center - right - up, quad.center + right - up,
                           quad.center + right + up, quad.center - right + up]
            let worst = zip(derived, corners).map { simd_length($0 - $1) }.max() ?? 1
            probe(worst <= 1e-6, "9.3 \(label)：四角是派生的（最大偏差 \(worst)）")
        }

        // ---- 9.3：落盘的载荷里**只有一份**几何 ----
        guard case let .success(value) = WorldScreenResolution.resolve(
            objectID: "tv-fit", calibratedJSON: nil, size: SIMD3(1.443, 0.862, 0.302),
            allowsDefault: false
        ), let json = WorldScreenDefinitionCoding.encode(value) else {
            probe(false, "9.3：推断出来的定义编码不出来")
            print("FIT-FAILURES=\(failures)"); exit(1)
        }
        let expected: Set<String> = ["objectID", "source", "center", "yaw", "pitch",
                                     "halfWidth", "halfHeight", "note"]
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        let keys = Set(object?.keys.map { $0 } ?? [])
        probe(keys == expected,
              "9.3：`gmgn.screen.v1` 的载荷恰好 8 个键、只有一份几何（多出来 "
                + "\(keys.subtracting(expected).sorted())，少了 \(expected.subtracting(keys).sorted())）")
        probe(WorldScreenDefinitionCoding.decode(json, expecting: "tv-fit")?.quad == value.quad,
              "9.3：编解码往返之后四边形逐位相同（尺寸仍然只有 halfWidth/halfHeight 一处定义）")

        print("FIT-FAILURES=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
"""##

/// 跑一个可执行文件并**收回它的全部输出**（父进程不直接继承子进程的 stdout：两者同时
/// 写同一个 fd 会把行交错在一起，门禁的 `^FAIL` 就会数错行）。
func runFitCapture(_ binary: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// 把两份**只依赖 Foundation + simd** 的屏幕几何源码复制到临时目录、按需做一组文本替换，
/// 编出探针跑一次。返回 `(status, output, note)`：`note` 非空 = **探针压根没跑起来**
/// （注入锚点找不到 / 编不过），此时 `status` 是 `-1` —— 判据必须把这两件事分开，
/// 否则"锚点没找到"会被当成"注入被抓住了"（一个恒真的假门禁）。
/// 注入只改**临时副本**：生产源码一个字节都不动（跑完随临时目录一起删）。
func runFitProbe(
    patches: [(file: String, from: String, to: String)]
) throws -> (status: Int32, output: String, note: String) {
    let directory = temporary.appendingPathComponent("fit-probe-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var sources: [String] = []
    for name in ["WorldScreenGeometry.swift", "WorldScreenInference.swift"] {
        var text = try read(screenRoot.appendingPathComponent(name))
        for patch in patches where patch.file == name {
            guard text.contains(patch.from) else {
                return (-1, "", "注入锚点在 \(name) 里找不到（签名改过？）：\(patch.from)")
            }
            text = text.replacingOccurrences(of: patch.from, with: patch.to)
        }
        let destination = directory.appendingPathComponent(name)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        sources.append(destination.path)
    }
    let program = directory.appendingPathComponent("FitProbe.swift")
    try fitProbeProgram.write(to: program, atomically: true, encoding: .utf8)
    let binary = directory.appendingPathComponent("fit-probe")
    let compile = try runFitCapture(
        "/usr/bin/swiftc",
        ["-j1", "-parse-as-library"] + sources + [program.path, "-o", binary.path]
    )
    guard compile.status == 0 else {
        return (-1, compile.output, "探针没编起来（exit \(compile.status)）—— 注入把源码改坏了")
    }
    let run = try runFitCapture(binary.path, [])
    return (run.status, run.output, "")
}

/// 注入锚点就是**生产源码原文**（改签名会让它在这里具名报错，而不是静默跳过）。
let fitMarginBody = """
    static func bezelMargin(faceWidth: Float, faceHeight: Float) -> Float {
        min(faceWidth, faceHeight) * bezelMarginFraction
    }
"""

let fitProbeClean = try runFitProbe(patches: [])
check(fitProbeClean.note.isEmpty && fitProbeClean.status == 0
        && fitProbeClean.output.contains("FIT-FAILURES=0"),
    "断言9：**原件**上跑屏幕铺满判据通过（exit \(fitProbeClean.status)，"
        + "\(fitProbeClean.output.split(separator: "\n").last(where: { $0.hasPrefix("FIT-FAILURES=") }) ?? "没有结论"))"
        + (fitProbeClean.note.isEmpty ? "" : " —— \(fitProbeClean.note)"))
// 判据的**材料读数**必须看得见（审计不用去读源码）：尺寸 / 覆盖率 / 余量 / 四角。
for line in fitProbeClean.output.split(separator: "\n")
where line.hasPrefix("FIT-NUM") || line.hasPrefix("FIT-CORNERS") {
    print("  · \(line)")
}

// 「四边形跟着逐轴缩放走」的**接线处**：屏幕推断读的必须是**最终**尺寸（`effectiveSize`
// = 用户给的三轴），不是网格自己的包围盒。真机上它必须是 `1.443 × 0.862 × 0.302`；
// 网格自身的 AABB 是 `1.0079 × 0.6287 × 1.0079`（实测那份 GLB），拿它当尺寸会被
// 板形判据具名拒绝 —— 所以这一行要是被改成读网格包围盒，屏幕会直接消失，而不是变小。
let screenStoreSource = try read(screenRoot.appendingPathComponent("WorldScreenStore.swift"))
check(screenStoreSource.contains(
        "SIMD3<Float>($0.effectiveSize.x, $0.effectiveSize.y, $0.effectiveSize.z)"),
    "断言9：`WorldScreenStore.resolve` 传给屏幕推断的是**最终**尺寸 `generatedProp.effectiveSize`")
check(!screenStoreSource.contains("worldBounds"),
    "断言9：屏幕推断没有改读网格自身的 `worldBounds`（那一路会被板形判据具名拒绝，屏幕会消失）")

// 六条注入负对照：每一条都必须让探针红**在它该红的那一条判据上**（`expected` 就是
// 那一句的原话片段）。只看退出码不够 —— 锚点找不到 / 编不起来同样是"非零退出"。
//
// ① 覆盖"四边形算在未拉伸的坐标系里"那一路：0.86 是**比例**余量，与逐轴拉伸**可交换**
//    —— "按旧坐标系算完再拉伸"与"按最终尺寸算"给出的是同一块四边形，
//    所以它们本来就是同一个缺陷的两种写法（真机上都是 73.96%）。
let fitInjections: [(name: String, patches: [(file: String, from: String, to: String)], expected: String)] = [
    (name: "旧的四边 0.86（每边吃掉 7%）",
     patches: [(file: "WorldScreenInference.swift", from: fitMarginBody,
                to: "    static func bezelMargin(faceWidth: Float, faceHeight: Float) -> Float {\n"
                    + "        min(faceWidth, faceHeight) * 0.07\n    }\n")],
     expected: "屏幕占正面 ≥ 95%（实测 78.81%）"),
    (name: "固定毫米数（只在真机那个尺寸成立）",
     patches: [(file: "WorldScreenInference.swift", from: fitMarginBody,
                to: "    static func bezelMargin(faceWidth: Float, faceHeight: Float) -> Float {\n"
                    + "       0.00862\n    }\n")],
     expected: "屏幕占正面 ≥ 95%（实测 94.89%）"),
    (name: "写回第二份几何（四角）",
     patches: [
        (file: "WorldScreenGeometry.swift",
         from: "        case objectID, source, center, yaw, pitch, halfWidth, halfHeight, note\n",
         to: "        case objectID, source, center, yaw, pitch, halfWidth, halfHeight, note, corners\n"),
        (file: "WorldScreenGeometry.swift",
         from: "        try container.encode(note, forKey: .note)\n",
         to: "        try container.encode(note, forKey: .note)\n"
            + "        try container.encode(quad.corners, forKey: .corners)\n"),
     ],
     expected: "多出来 [\"corners\"]"),
    (name: "放宽板形判据（0.25 → 1.0）",
     patches: [(file: "WorldScreenInference.swift",
                from: "    static let maximumPanelThicknessRatio: Float = 0.25",
                to: "    static let maximumPanelThicknessRatio: Float = 1.0")],
     expected: "板形判据仍是 最薄/最长 ≤ 0.25（实测 1.0）"),
    (name: "放宽面积阈值（0.04 → 0）",
     patches: [(file: "WorldScreenInference.swift",
                from: "    static let minimumFaceArea: Float = 0.04",
                to: "    static let minimumFaceArea: Float = 0.0")],
     expected: "面积阈值仍是 0.04 m²（实测 0.0）"),
    (name: "屏幕面加俯仰（法向不再是 +Z）",
     patches: [(file: "WorldScreenInference.swift",
                from: "                yaw: 0, pitch: 0,\n",
                to: "                yaw: 0, pitch: 0.20,\n")],
     expected: "屏幕朝向仍是正面 +Z（0.0000, 0.1987, 0.9801）"),
]

for injection in fitInjections {
    let probe = try runFitProbe(patches: injection.patches)
    let caught = probe.note.isEmpty && probe.status == 1
        && probe.output.contains("FIT-FAILURES=")
        && !probe.output.contains("FIT-FAILURES=0")
        && probe.output.contains(injection.expected)
    check(caught,
        "断言9（注入负对照「\(injection.name)」）：探针必须红在「\(injection.expected)」这一条上"
            + "（exit \(probe.status)）"
            + (probe.note.isEmpty ? "" : " —— \(probe.note)"))
    // 注入时的 FAIL 原话贴出来（红的是哪一条，当场看得见）。
    for line in probe.output.split(separator: "\n").filter({ $0.hasPrefix("FIT-FAIL") }).prefix(3) {
        print("  · \(line)")
    }
}

// ---------------------------------------------------------------------------
// MARK: 断言 10（行为 + 性能预算）：相机持续移动时**不**每帧重建 BVH / 不每帧重算掩码
// ---------------------------------------------------------------------------

/// 相机连续推进 120 帧，逐项量遮挡与覆盖层每帧花掉的时间与**次数**。
///
/// 驱动的是**生产里那一份 `WorldScreenOverlayController` 原文**（连同 `WorldScreenProjection`
/// / `WorldScreenOcclusion` / `WorldScreenState` / `WorldScreenGeometry`），现编现跑：
/// AppKit 只在进程里建视图与图层，**不开窗口、不起 App、不碰 Metal、不碰网络**。
/// 节拍用**注入的时钟**驱动（`controller.clock`），所以"掩码最多 30 Hz"这条判据不需要
/// 真机启动就能机器判定。
///
/// 为什么必须能抓：真机 2026-10-02「推进镜头爆卡」。同一段 120 帧推进（1200 个房间三角面
/// + 居民盒，-O 编）的实测对比：
///
/// | 项 | 改造前 | 改造后 |
/// |---|---|---|
/// | 掩码重算 | 120 次（每帧） | 46 次（≈23 Hz） |
/// | 掩码路径重建 | 120 次 | 8 次（只在掩码真的变了时） |
/// | 宿主尺寸变化（⇒ WebKit 重排版） | 120 次 | 3 次 |
/// | 每帧平均 | 0.62–0.65 ms | 0.23–0.25 ms |
/// | 单帧峰值 | 2.03 ms | 0.68–1.03 ms |
///
/// 判据抓的就是这几个**量级**：`occluderIndexBuilds` 抬到帧数、`maskRecomputes` 超过
/// 30 Hz、宿主尺寸每帧一变，任何一条都立刻红。
///
/// **必须 -O 编**：这几十行是紧的 simd 内层循环，debug 构建下同一段代码慢 ~70 倍
/// （实测每帧 16.4 ms vs 0.23 ms）—— 用 debug 数字判性能预算等于判编译器。
let performanceProbeProgram = ##"""
import AppKit
import Foundation
import simd

// 使用生产 updateOverlay 原文验证内容类型路由；世界输入仅由此探针提供。
@MainActor final class StoreOverlayRoutingProbe {
    var contents: [String: WorldScreenContent] = [:]
    let overlay: WorldScreenOverlayController
    var quads: [String: [SIMD3<Float>]] = [:]
    var normals: [String: SIMD3<Float>] = [:]
    var blockers = WorldScreenOccluders.empty
    init(overlay: WorldScreenOverlayController) { self.overlay = overlay }
    func worldQuads() -> (quads: [String: [SIMD3<Float>]], normals: [String: SIMD3<Float>]) {
        (quads, normals)
    }
    func occluders() -> WorldScreenOccluders { blockers }
    \##(productionDeclaration("    func updateOverlay(", in: storeSource))
}

var perfFailures = 0
func perf(_ condition: Bool, _ message: String) {
    if condition {
        print("PERF-PASS \(message)")
    } else {
        print("PERF-FAIL \(message)")
        perfFailures += 1
    }
}

/// 一间 6 × 2.6 × 8 的房间（地板 / 天花 / 四壁），1200 个三角面 ——
/// 真机那一份碰撞 GLB 是用来做深度遮挡的同一份几何，就是这个量级。
func perfRoom() -> [WorldScreenTriangle] {
    var triangles: [WorldScreenTriangle] = []
    let halfX: Float = 3, height: Float = 2.6, halfZ: Float = 4
    let steps = 100
    for index in 0 ..< steps {
        let t0 = Float(index) / Float(steps) * 2 * halfZ - halfZ
        let t1 = Float(index + 1) / Float(steps) * 2 * halfZ - halfZ
        triangles.append(WorldScreenTriangle(
            SIMD3(-halfX, 0, t0), SIMD3(halfX, 0, t0), SIMD3(halfX, 0, t1)))
        triangles.append(WorldScreenTriangle(
            SIMD3(-halfX, 0, t0), SIMD3(halfX, 0, t1), SIMD3(-halfX, 0, t1)))
        triangles.append(WorldScreenTriangle(
            SIMD3(-halfX, height, t0), SIMD3(halfX, height, t1), SIMD3(halfX, height, t0)))
        triangles.append(WorldScreenTriangle(
            SIMD3(-halfX, height, t0), SIMD3(-halfX, height, t1), SIMD3(halfX, height, t1)))
    }
    triangles.append(WorldScreenTriangle(
        SIMD3(-halfX, 0, -halfZ), SIMD3(halfX, 0, -halfZ), SIMD3(halfX, height, -halfZ)))
    triangles.append(WorldScreenTriangle(
        SIMD3(-halfX, 0, -halfZ), SIMD3(halfX, height, -halfZ), SIMD3(-halfX, height, -halfZ)))
    for index in 0 ..< 12 {
        let y0 = Float(index) / 12 * height
        let y1 = Float(index + 1) / 12 * height
        triangles.append(WorldScreenTriangle(
            SIMD3(-halfX, y0, -halfZ), SIMD3(-halfX, y0, halfZ), SIMD3(-halfX, y1, halfZ)))
        triangles.append(WorldScreenTriangle(
            SIMD3(-halfX, y0, -halfZ), SIMD3(-halfX, y1, halfZ), SIMD3(-halfX, y1, -halfZ)))
        triangles.append(WorldScreenTriangle(
            SIMD3(halfX, y0, -halfZ), SIMD3(halfX, y1, halfZ), SIMD3(halfX, y0, halfZ)))
        triangles.append(WorldScreenTriangle(
            SIMD3(halfX, y0, -halfZ), SIMD3(halfX, y1, -halfZ), SIMD3(halfX, y1, halfZ)))
    }
    return triangles
}

/// 一段相机推进的读数。
struct PerfReading {
    var frames = 0
    var average = 0.0
    var peak = 0.0
    var bvhBuilds = 0
    var maskRecomputes = 0
    var maskPathRebuilds = 0
    var surfaceSizeChanges = 0
    var webViewResizes = 0
    var worstAlignmentError: Float = 0
    /// 图层实际用的锚点（`NSViewBackingLayer` 是 `(0, 0)`）—— 判据的口径出处。
    var anchorPoint = CGPoint.zero
    var blockedCells = 0
    var cellCount = 0
    var hiddenAfterTurnAround = false
    var maskDetachedWhenClear = false
}

@main struct PerformanceProbe {
    @MainActor static func main() {
        let quad = WorldScreenQuad(center: SIMD3<Float>(0, 0.8, -3.95), yaw: 0, pitch: 0,
                                   halfWidth: 0.62, halfHeight: 0.35)
        let corners = quad.worldCorners(placedAt: SIMD3<Float>(0, 0, 0), yaw: 0)
        let normal = quad.worldNormal(yaw: 0)
        let resident = WorldScreenBox(center: SIMD3(0, 0.85, -2.9),
                                      halfExtents: SIMD3(0.25, 0.85, 0.2), yaw: 0)

        func drive(blocked: Bool) -> PerfReading {
            var reading = PerfReading()
            let host = NSView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
            host.wantsLayer = true
            let controller = WorldScreenOverlayController(hostView: host)
            let surface = controller.surface(for: "tv-1")
            // 待机时**不挂着**网页视图（断言11），而这一条量的是"挂着网页视图时宿主尺寸
            // 换得稀不稀"（每次换都让 WebKit 重排整页）。所以这里显式挂上 —— 生产里
            // `playScreen` / `load(url:)` 走的是同一句。
            surface.attachWebViewIfNeeded()
            let webView = surface.container.subviews.first
            let occluders = WorldScreenOccluders(
                triangles: perfRoom(), boxes: blocked ? [resident] : [], revision: 7)

            let frames = 120
            let dt = 1.0 / 60.0
            var synthetic = 0.0
            controller.clock = { synthetic }
            var steadyTotal = 0.0
            var steadyPeak = 0.0
            var steadyFrames = 0
            var lastWebFrame = webView?.frame ?? .zero

            for frame in 0 ..< frames {
                let t = Float(frame) / Float(frames - 1)
                // 相机从 3.2 m 处推到 1.4 m 处，同时轻微转头 —— 用户说的「推进镜头」。
                let camera = WorldScreenCamera(
                    position: SIMD3(0.2 * t, 0.85, -0.8 + 2.4 * (1 - t)), yaw: 0.08 * t, pitch: 0)
                let projection = WorldScreenProjection(
                    camera: camera, profile: .fullStage, viewportSize: SIMD2(1600, 1000))
                synthetic += dt
                controller.update(quads: ["tv-1": corners], normals: ["tv-1": normal],
                                  projection: projection, camera: camera, occluders: occluders)
                let cost = controller.frameCost
                if cost.didRebuildOccluderIndex { reading.bvhBuilds += 1 }
                if cost.didRecomputeMask { reading.maskRecomputes += 1 }
                if cost.didRebuildMaskPath { reading.maskPathRebuilds += 1 }
                if cost.didResizeSurface { reading.surfaceSizeChanges += 1 }
                if let webView, webView.frame != lastWebFrame {
                    lastWebFrame = webView.frame
                    reading.webViewResizes += 1
                }
                if frame > 0 {
                    steadyTotal += cost.milliseconds
                    steadyPeak = max(steadyPeak, cost.milliseconds)
                    steadyFrames += 1
                }
                // 对齐：按图层**实际的口径**算它会画在哪 —— `NSViewBackingLayer` 的
                // `anchorPoint` 是 (0,0)、`position` 是 `frame.origin`，CoreAnimation 施加的是
                // `position + T(bounds 角)`。读的是**图层现在的值**，不是我们自己算的中间量：
                // 这样这条判据第一次真的在验"CoreAnimation 会画在哪"，而不是自证一句空话。
                guard let normalized = projection.screenQuad(worldCorners: corners),
                      let layer = surface.container.layer
                else { continue }
                let points = normalized.map { projection.viewPoint(normalized: $0) }
                let liveSize = surface.container.bounds.size
                let liveAnchor = layer.anchorPoint
                let livePosition = SIMD2(Float(layer.position.x), Float(layer.position.y))
                reading.anchorPoint = liveAnchor
                let writtenTransform = WorldScreenLayerTransform(cgTransform: layer.transform)
                let source: [SIMD2<Float>] = [
                    SIMD2(0, 0), SIMD2(Float(liveSize.width), 0),
                    SIMD2(Float(liveSize.width), Float(liveSize.height)),
                    SIMD2(0, Float(liveSize.height)),
                ]
                let anchorOffset = SIMD2(
                    Float(liveAnchor.x) * Float(liveSize.width),
                    Float(liveAnchor.y) * Float(liveSize.height)
                )
                for corner in 0 ..< 4 {
                    guard let actual = writtenTransform.apply(to: source[corner] - anchorOffset)
                    else { continue }
                    let absolute = livePosition + anchorOffset + actual
                    reading.worstAlignmentError = max(
                        reading.worstAlignmentError, simd_length(absolute - points[corner]))
                }
            }
            reading.frames = steadyFrames
            reading.average = steadyFrames > 0 ? steadyTotal / Double(steadyFrames) : 0
            reading.peak = steadyPeak

            let stat = controller.occlusionStats["tv-1"]
            reading.blockedCells = stat?.blockedCellCount ?? 0
            reading.cellCount = stat?.cellCount ?? 0
            reading.maskDetachedWhenClear = surface.occlusionMask?.isFullyVisible ?? true

            // 背向仍剔除：转到屏幕后面，整块必须隐藏并给出具名原因。
            let behind = WorldScreenCamera(position: SIMD3(0, 0.85, -5.2), yaw: .pi, pitch: 0)
            let behindProjection = WorldScreenProjection(
                camera: behind, profile: .fullStage, viewportSize: SIMD2(1600, 1000))
            controller.update(quads: ["tv-1": corners], normals: ["tv-1": normal],
                              projection: behindProjection, camera: behind,
                              occluders: WorldScreenOccluders.empty)
            reading.hiddenAfterTurnAround = surface.container.isHidden
            return reading
        }

        let clear = drive(blocked: false)
        let blockedReading = drive(blocked: true)
        // 原生屏不应再承担网页层的 CPU 射线遮挡；切回网页时必须恢复原有遮挡。
        let nativeHost = NSView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        nativeHost.wantsLayer = true
        let nativeController = WorldScreenOverlayController(hostView: nativeHost)
        let nativeSurface = nativeController.surface(for: "native-tv")
        let camera = WorldScreenCamera(position: SIMD3(0, 0.85, 1.6), yaw: 0, pitch: 0)
        let projection = WorldScreenProjection(
            camera: camera, profile: .fullStage, viewportSize: SIMD2(1600, 1000))
        let occluders = WorldScreenOccluders(triangles: perfRoom(), boxes: [resident], revision: 7)
        let routing = StoreOverlayRoutingProbe(overlay: nativeController)
        routing.blockers = occluders
        routing.contents["native-tv"] = .init(objectID: "native-tv", kind: .nativeLink,
            url: "https://www.twitch.tv/eslcs", title: "原生屏")
        routing.updateOverlay(projection: projection, camera: camera)
        perf(nativeSurface.container.isHidden && nativeController.hiddenReasons["native-tv"] == nil,
            "原生屏收起遗留层，不误报缺几何")
        perf(!nativeController.frameCost.didRebuildOccluderIndex
            && !nativeController.frameCost.didRecomputeMask,
            "只有原生屏时不建 CPU 索引、不计算掩码")
        routing.quads = ["native-tv": corners]
        routing.normals = ["native-tv": normal]
        routing.contents["native-tv"] = .init(objectID: "native-tv", kind: .officialEmbed,
            url: "https://player.bilibili.com/player.html?bvid=BV1xx411c7mD", title: "网页屏")
        routing.updateOverlay(projection: projection, camera: camera)
        perf(!nativeSurface.container.isHidden && nativeController.frameCost.didRecomputeMask
            && (nativeController.occlusionStats["native-tv"]?.blockedCellCount ?? 0) > 0,
            "切回网页屏后恢复 CPU 遮挡")
        routing.contents["native-tv"] = .init(objectID: "native-tv", kind: .nativeLink,
            url: "https://www.twitch.tv/eslcs", title: "原生屏")
        routing.updateOverlay(projection: projection, camera: camera)
        perf(nativeController.occlusionStats["native-tv"] == nil
            && !nativeController.frameCost.didRecomputeMask,
            "切回原生后清除旧遮挡统计且跳过 CPU 掩码")
        routing.contents["native-tv"] = .init(objectID: "native-tv", kind: .officialEmbed,
            url: "https://player.bilibili.com/player.html?bvid=BV1xx411c7mD", title: "网页屏")
        routing.updateOverlay(projection: projection, camera: camera)
        perf(nativeController.frameCost.didRecomputeMask,
            "再次切回网页后旧签名和节流时间不会阻止掩码恢复")
        let legacySurface = nativeController.surface(for: "legacy-tv")
        routing.contents["native-tv"] = .init(objectID: "native-tv", kind: .nativeLink,
            url: "https://www.twitch.tv/eslcs", title: "原生屏")
        routing.contents["legacy-tv"] = .init(objectID: "legacy-tv", kind: .officialEmbed,
            url: "https://player.bilibili.com/player.html?bvid=BV1xx411c7mD", title: "网页屏")
        routing.quads["legacy-tv"] = corners
        routing.normals["legacy-tv"] = normal
        routing.updateOverlay(projection: projection, camera: camera)
        perf(nativeSurface.container.isHidden && !legacySurface.container.isHidden
            && nativeController.occlusionStats["native-tv"] == nil
            && (nativeController.occlusionStats["legacy-tv"]?.blockedCellCount ?? 0) > 0,
            "原生和网页混合时仅原生退出 CPU 遮挡，网页仍按格遮挡")
        let seconds = Double(clear.frames) / 60.0

        // MARK: 每帧预算（遮挡 + 覆盖层）
        for (name, reading) in [("无遮挡", clear), ("居民挡在屏前", blockedReading)] {
            let problems = WorldScreenFrameBudget.problems(
                frames: reading.frames,
                averageCostMilliseconds: reading.average,
                peakCostMilliseconds: reading.peak,
                occluderIndexBuilds: reading.bvhBuilds,
                maskRecomputes: reading.maskRecomputes,
                maskPathRebuilds: reading.maskPathRebuilds,
                durationSeconds: seconds,
                surfaceSizeChanges: reading.surfaceSizeChanges
            )
            for problem in problems {
                perf(false, "\(name)：\(problem)")
            }
            let hertz = seconds > 0 ? Double(reading.maskRecomputes) / seconds : 0
            print(String(format: "PERF-COST %@: 每帧平均 %.3f ms / 峰值 %.3f ms；"
                         + "BVH 重建 %d 次、掩码重算 %d 次(%.1f Hz)、路径重建 %d 次、"
                         + "宿主尺寸变化 %d 次、WKWebView 换尺寸 %d 次、"
                         + "图层锚点 (%.1f,%.1f) 下最大对齐偏差 %.5f px",
                         name, reading.average, reading.peak, reading.bvhBuilds,
                         reading.maskRecomputes, hertz, reading.maskPathRebuilds,
                         reading.surfaceSizeChanges, reading.webViewResizes,
                         reading.anchorPoint.x, reading.anchorPoint.y,
                         reading.worstAlignmentError))
            perf(reading.anchorPoint == .zero,
                 "\(name)：`NSViewBackingLayer` 的锚点仍是 (0,0)（实测 "
                     + "(\(reading.anchorPoint.x),\(reading.anchorPoint.y))）—— "
                     + "覆盖层的图层口径修正就是按这一条推出来的")
            perf(reading.average <= WorldScreenFrameBudget.averageMilliseconds,
                 "\(name)：每帧平均 \(String(format: "%.3f", reading.average)) ms ≤ "
                     + "\(WorldScreenFrameBudget.averageMilliseconds) ms")
            perf(reading.peak <= WorldScreenFrameBudget.peakMilliseconds,
                 "\(name)：单帧峰值 \(String(format: "%.3f", reading.peak)) ms ≤ "
                     + "\(WorldScreenFrameBudget.peakMilliseconds) ms")
            perf(reading.bvhBuilds <= WorldScreenFrameBudget.maximumOccluderIndexBuilds,
                 "\(name)：房间 BVH 只重建 \(reading.bvhBuilds) 次（120 帧推进，房间没变）")
            perf(hertz <= WorldScreenFrameBudget.maximumMaskRecomputesPerSecond,
                 "\(name)：掩码重算 \(String(format: "%.1f", hertz)) Hz ≤ "
                     + "\(WorldScreenFrameBudget.maximumMaskRecomputesPerSecond) Hz")
            perf(reading.maskPathRebuilds <= reading.maskRecomputes,
                 "\(name)：掩码路径只重建 \(reading.maskPathRebuilds) 次，不多于掩码重算 "
                     + "\(reading.maskRecomputes) 次（同一张掩码不重建路径）")
            perf(reading.maskPathRebuilds < reading.maskRecomputes,
                 "\(name)：掩码没变就不重建路径 —— \(reading.maskRecomputes) 次重算里只有 "
                     + "\(reading.maskPathRebuilds) 次真的重建了路径")
            perf(reading.surfaceSizeChanges <= WorldScreenFrameBudget.maximumSurfaceSizeChanges,
                 "\(name)：宿主渲染尺寸只变 \(reading.surfaceSizeChanges) 次 ≤ "
                     + "\(WorldScreenFrameBudget.maximumSurfaceSizeChanges) 次（不再每帧换 WKWebView 尺寸）")
            perf(reading.worstAlignmentError <= 0.5,
                 "\(name)：固定渲染尺寸下，写进图层的变换把 bounds 四角搬到四角，"
                     + "最大偏差 \(reading.worstAlignmentError) px ≤ 0.5 px")
        }

        // MARK: 既有语义
        perf(clear.maskDetachedWhenClear,
             "无人遮挡 ⇒ 掩码整块摘掉（不挂 mask，正常观看没有可以抖的边界）")
        perf(clear.blockedCells == 0, "无人遮挡 ⇒ 0 格被挡（实测 \(clear.blockedCells)）")
        perf(blockedReading.blockedCells > 0 && blockedReading.blockedCells < blockedReading.cellCount,
             "居民挡在屏前 ⇒ **按格**裁切：\(blockedReading.blockedCells)/\(blockedReading.cellCount) 格被挡，"
                 + "不是整块消失")
        perf(clear.hiddenAfterTurnAround && blockedReading.hiddenAfterTurnAround,
             "相机转到屏幕背后 ⇒ 整块隐藏（背向剔除仍然生效）")

        print("PERF-FAILURES=\(perfFailures)")
        exit(perfFailures == 0 ? 0 : 1)
    }
}
"""##

/// 把屏幕那一组源码（含覆盖层宿主）复制到临时目录、按需做一组文本替换，编出探针跑一次。
///
/// **-O 是必须的**：这几项判据量的是紧的 simd 内层循环，debug 构建下同一段代码慢 ~70 倍。
/// 返回 `(status, output, note)`：`note` 非空 = 探针压根没跑起来（锚点找不到 / 编不过），
/// 此时 `status` 是 `-1` —— "锚点没找到"绝不能被当成"注入被抓住了"。
func runPerformanceProbe(
    patches: [(file: String, from: String, to: String)]
) throws -> (status: Int32, output: String, note: String) {
    let directory = temporary.appendingPathComponent("perf-probe-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // 覆盖层宿主还依赖一个**后来才加进来**的屏幕来源文件。它在就带上、不在就跳过：
    // 判据不该因为"别人正在写的那一个文件存不存在"而红，也不该在它存在时编不过。
    let optionalScreenFiles = ["WorldScreenEmbedOrigin.swift"].filter {
        FileManager.default.fileExists(atPath: screenRoot.appendingPathComponent($0).path)
    }
    let names = screenFiles + ["WorldScreenOverlayController.swift"] + optionalScreenFiles
    var sources: [String] = []
    for name in names {
        var text = try read(screenRoot.appendingPathComponent(name))
        for patch in patches where patch.file == name {
            guard text.contains(patch.from) else {
                return (-1, "", "注入锚点在 \(name) 里找不到（签名改过？）：\(patch.from)")
            }
            text = text.replacingOccurrences(of: patch.from, with: patch.to)
        }
        let destination = directory.appendingPathComponent(name)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        sources.append(destination.path)
    }
    let program = directory.appendingPathComponent("PerformanceProbe.swift")
    try performanceProbeProgram.write(to: program, atomically: true, encoding: .utf8)
    let binary = directory.appendingPathComponent("perf-probe")
    let compile = try runFitCapture(
        "/usr/bin/swiftc",
        ["-j1", "-parse-as-library", "-O"] + sources + [program.path, "-o", binary.path]
    )
    guard compile.status == 0 else {
        return (-1, compile.output, "探针没编起来（exit \(compile.status)）—— 注入把源码改坏了")
    }
    let run = try runFitCapture(binary.path, [])
    return (run.status, run.output, "")
}

let performanceProbeClean = try runPerformanceProbe(patches: [])
for line in performanceProbeClean.output.split(separator: "\n")
    .filter({ $0.hasPrefix("PERF-COST") || $0.hasPrefix("PERF-PASS") }) {
    print("  · \(line)")
}
let performanceProbeConclusion = performanceProbeClean.output.split(separator: "\n")
    .last(where: { $0.hasPrefix("PERF-FAILURES=") }) ?? "没有结论"
check(performanceProbeClean.note.isEmpty && performanceProbeClean.status == 0
        && performanceProbeClean.output.contains("PERF-FAILURES=0"),
    "断言10：原件上跑相机连续推进的每帧账全部通过（exit \(performanceProbeClean.status)，"
        + "\(performanceProbeConclusion))"
        + (performanceProbeClean.note.isEmpty ? "" : " —— \(performanceProbeClean.note)"))

// 注入负对照：逐条把"每帧都做"的写法塞回去，判据必须抓得住（红的是哪一条，原话贴出来）。
let performanceInjections: [(name: String, patches: [(file: String, from: String, to: String)], expected: String)] = [
    (name: "每帧重建房间 BVH",
     patches: [(file: "WorldScreenOverlayController.swift",
                from: "        if hasLegacySurface, occluderIndex?.revision != occluders.revision {",
                to: "        if hasLegacySurface {")],
     expected: "（上限 1）"),
    (name: "每帧重算掩码（去掉 30 Hz 节流）",
     patches: [(file: "WorldScreenOverlayController.swift",
                from: "        let now = clock()\n"
                    + "        if let last = lastMaskRecompute[surface.objectID],\n"
                    + "           now - last < Self.maskMinimumInterval {\n"
                    + "            return\n"
                    + "        }\n",
                to: "        let now = clock()\n")],
     expected: "超上限 30 Hz"),
    (name: "每帧重算掩码路径（去掉签名闸门 + 节流）",
     patches: [(file: "WorldScreenOverlayController.swift",
                from: "        guard key != occlusionKeys[surface.objectID] else { return }\n"
                    + "        let now = clock()\n"
                    + "        if let last = lastMaskRecompute[surface.objectID],\n"
                    + "           now - last < Self.maskMinimumInterval {\n"
                    + "            return\n"
                    + "        }\n",
                to: "        let now = clock()\n")],
     expected: "超上限 30 Hz"),
    (name: "同一张掩码也重建路径",
     patches: [(file: "WorldScreenOverlayController.swift",
                from: "        if mask == previous, let existing = occlusionMaskLayer, existing.frame == bounds {\n"
                    + "            return\n"
                    + "        }\n",
                to: "")],
     expected: "掩码没变就不重建路径"),
    (name: "宿主渲染尺寸跟着相机每帧变（去掉滞回）",
     patches: [(file: "WorldScreenOverlayController.swift",
                from: "        return fits ? current : desired",
                to: "        _ = fits\n        return desired")],
     expected: "（上限 8）"),
    // 只**超预算**、不动任何计数器的注入：格级掩码从 24 × 14 放大到 240 × 140（每帧真算更多格）。
    // 它证明"每帧平均 / 峰值"这两条本身是个会红的门禁，而不是一句恒真的空话。
    (name: "格级掩码放大 100 倍（每帧真算更多格）",
     patches: [(file: "WorldScreenOcclusion.swift",
                from: "    static let defaultColumns = 24\n    static let defaultRows = 14",
                to: "    static let defaultColumns = 240\n    static let defaultRows = 140")],
     expected: "超预算"),
]

for injection in performanceInjections {
    let probe = try runPerformanceProbe(patches: injection.patches)
    let caught = probe.note.isEmpty && probe.status == 1
        && probe.output.contains("PERF-FAILURES=")
        && !probe.output.contains("PERF-FAILURES=0")
        && probe.output.contains(injection.expected)
    check(caught,
        "断言10（注入负对照「\(injection.name)」）：探针必须红在「\(injection.expected)」这一条上"
            + "（exit \(probe.status)）"
            + (probe.note.isEmpty ? "" : " —— \(probe.note)"))
    for line in probe.output.split(separator: "\n").filter({ $0.hasPrefix("PERF-FAIL") }).prefix(3) {
        print("  · \(line)")
    }
}

print(failureCount == 0 ? "PASS 电视机判据全部通过" : "FAIL 电视机判据有 \(failureCount) 条不通过")
exit(failureCount == 0 ? 0 : 1)
