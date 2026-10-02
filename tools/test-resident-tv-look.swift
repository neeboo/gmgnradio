// 电视的**观感**与**面板文案**：外观材质 / 姿态 / 人话。
//
// 为什么要有这一条（真机 2026-10-02，用户截图 + 原话「**什么玩意儿**」）：
//
// ① 按尺寸拼出来的电视（1.443 × 0.862 × 0.302 m）确实进了场景，但画面是
//    **一块灰板 + 一个大的黑色矩形** —— GLB 里一个 `materials` 都没写，七块盒子全落回
//    渲染器缺省材质（白 + 全金属 + 全粗糙，`GLTFMaterialUniforms`），在中性灰环境光下
//    就是一块灰；而正面那块屏幕被"未播放时的纯黑 web 视图"整个盖住。
// ② 面板上摆着的是 `由最大平坦面推断：法向 +Z（正面），面积 1.244 m²…` 与
//    `前景遮挡：24 × 14 格全部可见（117.98 ms）` —— 工程读数，不是给用户看的。
//
// 这一条把两件事都钉住，**并且不许它顺手改坏判据**：
//
//   A. 外观：GLB 必须带 3 份深色材质（屏幕 / 机身 / 底座），屏幕面**深灰偏黑、有一点反光**，
//      **不是纯黑、也不是灰白**；同时盒子数量 7、三轴 1.443 × 0.862 × 0.302、面板厚 0.04、
//      底座进深 0.302、屏幕面 = 正面 z = size.z/2 **逐位不变**，立柱顶在面板背面上。
//   B. 姿态：入库与预览的 yaw 必须是 0、屏幕面的 pitch 必须是 0（= 屏幕朝房间 +Z）。
//      "歪着/后仰"的观感来源是立柱悬在面板后面 0.081 m 的空气里（A 的最后一条钉它），
//      不是姿态数据 —— 所以这里只改几何的**连接**，不碰任何 yaw/pitch 的语义。
//   C. 文案：面板上给用户看的字全部来自 `ScreenPanelCopy`，逐字断言
//      **不出现 法向 / 面积 / m² / 格 / ms / `key=value`**；遮挡只在**真被挡**时给**一句**
//      常量话（不刷屏、不带格数与毫秒）。
//
// 计划是**跑真的源码**：A 段把生产源码里的 `Part` / `parts(for:)` / `PrimitiveGLBWriter`
// 逐字切出来现编现跑（不是替身），B 段跑真的 `residentProp` 与 `WorldScreenQuad`，
// C 段直接编 `Screen/**` 那几份生产文件。每一条判据都配**注入负对照** —— 在源码副本上做
// 手术，判据必须变红（注入只改内存/临时副本，跑完即弃）。
//
// 现场演示：
//   TVLOOK_INJECT=old-grey-material  swift tools/test-resident-tv-look.swift
//   TVLOOK_INJECT=screen-pure-black  swift tools/test-resident-tv-look.swift
//   TVLOOK_INJECT=drop-materials     swift tools/test-resident-tv-look.swift
//   TVLOOK_INJECT=pitched-screen     swift tools/test-resident-tv-look.swift
//   TVLOOK_INJECT=yaw-drift          swift tools/test-resident-tv-look.swift
//   TVLOOK_INJECT=engineering-copy   swift tools/test-resident-tv-look.swift
//   TVLOOK_INJECT=occlusion-spam     swift tools/test-resident-tv-look.swift
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let screenRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Screen")
let appRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let worldRoot = root.appendingPathComponent(
    "apps/macos/Packages/WorldRuntime/Sources/WorldRuntime")

var failureCount = 0
func check(_ condition: Bool, _ message: String) {
    if condition { print("PASS \(message)") } else { print("FAIL \(message)"); failureCount += 1 }
}

func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

/// 非重叠出现次数。
func occurrences(of needle: String, in text: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var cursor = text.startIndex
    while let range = text.range(of: needle, range: cursor..<text.endIndex) {
        count += 1
        cursor = range.upperBound
    }
    return count
}

/// 从源码里切出 `signature` 开头的**那一个**花括号块（含嵌套）。切不出来就地崩 ——
/// 不许悄悄用手写替身顶上（那会让"判据测的是哪份源码"变成两处）。
func declarationBody(_ signature: String, in text: String) -> String {
    guard let start = text.range(of: signature)?.lowerBound,
          let open = text[start...].firstIndex(of: "{")
    else { fatalError("切不出生产源码里的声明「\(signature)」——签名改了？") }
    var depth = 0
    var index = open
    while index < text.endIndex {
        let character = text[index]
        if character == "{" { depth += 1 }
        if character == "}" {
            depth -= 1
            if depth == 0 { return String(text[start...index]) }
        }
        index = text.index(after: index)
    }
    fatalError("声明「\(signature)」的花括号不平衡")
}

let injection = ProcessInfo.processInfo.environment["TVLOOK_INJECT"]

/// 在源码文本上做手术。注入只改**内存/临时副本**，原件一个字节都不动。
func patched(_ text: String, file: String) -> String {
    guard let injection else { return text }
    switch (injection, file) {
    case ("old-grey-material", "WorldPrimitiveTelevisionFinish.swift"):
        // 注入：把外观取值改回改造前的"没有材质"观感（白 + 全金属 + 全粗糙）。
        return text
            .replacingOccurrences(of: "0.060, 0.066, 0.076, 1", with: "1, 1, 1, 1")
            .replacingOccurrences(of: "0.030, 0.032, 0.036, 1", with: "1, 1, 1, 1")
            .replacingOccurrences(of: "0.075, 0.078, 0.086, 1", with: "1, 1, 1, 1")
    case ("screen-pure-black", "WorldPrimitiveTelevisionFinish.swift"):
        // 注入：屏幕面写成纯黑（"死黑的一块"）。
        return text.replacingOccurrences(of: "0.060, 0.066, 0.076, 1", with: "0, 0, 0, 1")
    case ("drop-materials", "WorldPrimitiveTelevision.swift"):
        // 注入：把材质从 GLB 里整块拿掉（真机那份字节就是这样）。
        return text.replacingOccurrences(of: "\"materials\": materials,", with: "")
    case ("pitched-screen", "WorldScreenInference.swift"):
        // 注入：正面屏幕面被加了一个俯仰 ⇒ 屏幕不再朝房间。
        return text.replacingOccurrences(of: "yaw: 0, pitch: 0,\n                halfWidth: size.x",
                                         with: "yaw: 0, pitch: 0.20,\n                halfWidth: size.x")
    case ("yaw-drift", "WishMachineOutputDescriptor.swift"):
        // 注入：yaw 抽取里混进一个常量 ⇒ 入库姿态不再是 0。
        return text.replacingOccurrences(
            of: "yaw: atan2(2 * rotation.w * rotation.y, 1 - 2 * rotation.y * rotation.y),",
            with: "yaw: atan2(2 * rotation.w * rotation.y, 1 - 2 * rotation.y * rotation.y) + 0.15,")
    case ("engineering-copy", "ResidentScreenTools.swift"):
        // 注入：把工程术语塞回面板那一句。
        return text.replacingOccurrences(
            of: "case .inferred: return \"屏幕范围：自动识别。\"",
            with: "case .inferred: return \"由最大平坦面推断：法向 +Z（正面），面积 1.244 m²。\"")
    case ("occlusion-spam", "ResidentScreenTools.swift"):
        // 注入：遮挡那一行开始报格数与毫秒（每帧都在变 ⇒ 刷屏）。
        return text.replacingOccurrences(
            of: "isBlocked ? \"画面有一部分被前面挡住了。\" : nil",
            with: "isBlocked ? \"前景遮挡：63/336 格被挡（117.98 ms）\" : nil")
    default:
        return text
    }
}

// ---------------------------------------------------------------------------
// MARK: 生产源码（可注入）
// ---------------------------------------------------------------------------

guard let televisionSource = read(worldRoot.appendingPathComponent("WorldPrimitiveTelevision.swift")),
      let finishSource = read(worldRoot.appendingPathComponent("WorldPrimitiveTelevisionFinish.swift")),
      let descriptorSource = read(appRoot.appendingPathComponent("Presence/WishMachineOutputDescriptor.swift")),
      let quadSource = read(screenRoot.appendingPathComponent("WorldScreenGeometry.swift")),
      let inferenceSource = read(screenRoot.appendingPathComponent("WorldScreenInference.swift")),
      let layoutSource = read(worldRoot.appendingPathComponent("WorldPropLayout.swift")),
      let appSource = read(appRoot.appendingPathComponent("App/GMGNRadioApp.swift")),
      let overlaySource = read(screenRoot.appendingPathComponent("WorldScreenOverlayController.swift"))
else {
    print("FAIL: 读不到生产源码（电视外观 / 姿态 / 覆盖层）")
    exit(1)
}

let television = patched(televisionSource, file: "WorldPrimitiveTelevision.swift")
let finish = patched(finishSource, file: "WorldPrimitiveTelevisionFinish.swift")
let descriptor = patched(descriptorSource, file: "WishMachineOutputDescriptor.swift")
let inference = patched(inferenceSource, file: "WorldScreenInference.swift")

// 渲染器名必须**照旧**（它进 `WorldPrimitiveTelevisionRecord.isValid`，改了老记录就废了）。
let rendererName = "primitive-television-v1"
check(television.contains("static let rendererName = \"\(rendererName)\""),
      "判据0：渲染器名照旧是 `\(rendererName)`（存档里的 `primitive` 记录读它）")

// ---------------------------------------------------------------------------
// MARK: 外层判据（姿态的来源与覆盖层的黑底）
// ---------------------------------------------------------------------------

// B：屏幕面在本体坐标系里 pitch = 0（= 朝房间 +Z 的水平面）。正面那一支**逐字**是这句；
// 侧面是 `.pi / 2`、顶面是 `.pi / 2`，所以这句在整份源码里只该出现一次。
let frontQuadIsLevel = occurrences(of: "yaw: 0, pitch: 0,", in: inference) == 1
check(frontQuadIsLevel,
      "判据B1：`WorldScreenFace.front.quad` 的 `yaw: 0, pitch: 0,` 逐字在且只出现一次"
        + "（实测 \(occurrences(of: "yaw: 0, pitch: 0,", in: inference)) 次）")
if injection == "pitched-screen" {
    check(!frontQuadIsLevel, "注入 pitched-screen ⇒ 判据B1（屏幕面 pitch = 0）必须变红")
}

// B：摆放矩阵是**纯绕 Y**：第二列必须是 (0,1,0,0)，没有任何绕 X 的俯仰项。
check(descriptor.contains("var rotation = matrix_identity_float4x4")
      && descriptor.contains("rotation.columns.0 = SIMD4(c, 0, -s, 0)")
      && descriptor.contains("rotation.columns.2 = SIMD4(s, 0, c, 0)"),
      "判据B2：`ResidentPropPlacementMatrix` 的旋转由 `matrix_identity_float4x4` 起手，只写第 0/2/3 列")
check(!descriptor.contains("rotation.columns.1"),
      "判据B2：第二列（(0,1,0,0)）**从不被赋值** ⇒ 矩阵里不可能混进俯仰/侧倾")

// B：这台电视的物件记录里**没有** `orientation`（⇒ nil ⇒ 单位四元数 ⇒ 不产生任何摆正旋转）。
//
// 判据锚在**类型自己**（`WorldPrimitiveTelevision.generatedProp`）而不是某个 App 调用点：
// 电视这条产品路径正在**另一条线上**被改成"用户显式选择"（`ResidentPropTelevisionRepair`），
// 调用点会搬；但"这台电视的几何是拼出来的、天生正立，所以它不带任何摆正旋转"是类型的性质。
func slice(_ text: String, from start: String, to end: String) -> String? {
    guard let lower = text.range(of: start)?.lowerBound,
          let upper = text.range(of: end, range: lower..<text.endIndex)?.upperBound
    else { return nil }
    return String(text[lower..<upper])
}
let televisionPropBlock = slice(television, from: "public func generatedProp(",
                                to: "primitive: record")
check(televisionPropBlock != nil, "判据B3：找得到 `WorldPrimitiveTelevision.generatedProp` 那份记录构造")
check(televisionPropBlock?.contains("orientation:") == false,
      "判据B3：基础几何电视的 `WorldGeneratedProp` 不带 `orientation`（⇒ nil ⇒ 单位四元数，"
        + "摆正旋转只有一个出口 `WorldPropLayout.orientationRotation`）")
check(layoutSource.contains("public var orientationRotation: WorldQuaternion { orientation?.rotation ?? .identity }"),
      "判据B3：摆正旋转的唯一出口是 `orientation?.rotation ?? .identity`")
check(appSource.contains("orientation: asset.prop.orientationRotation"),
      "判据B3：渲染描述符读的就是那个唯一出口（不自己算第二份朝向）")

// A：立柱顶在面板背面上（真机「后仰」观感的来源：原来悬在 0.081 m 的空气里）。
check(television.contains("let neckCenterZ = min(")
      && television.contains("max(panelBackZ - neckDepth / 2, lowestNeckCenterZ)"),
      "判据A6：立柱的 z 由 `panelBackZ - neckDepth / 2` 顶到面板背面（并夹在底板前后沿之间）")

// A（黑矩形）：未播放那块 web 视图**不许**是纯黑。
check(!overlaySource.contains("underPageBackgroundColor = .black"),
      "判据A7：未播放的屏幕底不许是纯黑（`.black`）")
check(overlaySource.contains("static let idleScreenBackground = NSColor("),
      "判据A7：未播放的屏幕底取 `idleScreenBackground`（深灰偏黑、带一点反光）")
check(!overlaySource.contains("background:#000"),
      "判据A7：空页 HTML 里不许有纯黑 `#000`")

// 面板宽 340：它在**宿主**那里，不在面板自己身上（面板一旦自己设宽度，两处就会打架）。
//
// ⚠️ 2026-10-02 现场：**另一条线**按用户的另一个要求把电视面板从产品界面移除了
// （`StageWindowController` 的 `installScreenPanel` 挂载点被删）—— 那是他们那一轮的改动，
// 与本条的判据无关，所以这里**如实报告**而不是假装绿 / 假装红。
if let screenPanel = read(screenRoot.appendingPathComponent("ScreenPanel.swift")) {
    // 面板里的输入框有自己的 `.frame(width: 56)`（宽/高/中心高三个框），那是格子宽度；
    // 这里钉的是**整块面板**不许自己定宽（`widthAnchor` / `frame(width: 340`）。
    check(!screenPanel.contains("widthAnchor") && !screenPanel.contains("frame(width: 340"),
          "判据C1：电视面板**自己不设整块面板的宽度**（340 由宿主约束；面板自己再定一处就是两份真相）")
} else {
    check(false, "判据C1：读不到 `Screen/ScreenPanel.swift`")
}
if let stage = read(appRoot.appendingPathComponent("VisualEngine/StageWindowController.swift")) {
    if stage.contains("host.widthAnchor.constraint(equalToConstant: 340)") {
        check(true, "判据C1：电视面板宽度仍然是 340（红线）")
    } else {
        print("  · NOTE 判据C1：产品路径上已经没有电视面板的挂载点了（另一条线把 `installScreenPanel` "
              + "移除了，理由是「左下角那块电视面板不应该出现」）。340 这条在这个宿主上无从断言；"
              + "面板视图本身仍**不设宽度**（上一条已断言），本轮的改动没有碰过它的宽度。")
    }
} else {
    check(false, "判据C1：读不到 `StageWindowController.swift`，无法确认面板宽 340")
}

// ---------------------------------------------------------------------------
// MARK: 内层程序 1：外观 + 姿态（编真的生产源码）
// ---------------------------------------------------------------------------

/// 把 `public ` 去掉（内层程序里这些类型是 internal 的嵌套声明）。
func internalized(_ block: String) -> String {
    block.replacingOccurrences(of: "public ", with: "")
}

let partBlock = internalized(declarationBody("public struct Part: Equatable, Sendable {", in: television))
let thicknessBlock = internalized(
    declarationBody("static func panelThickness(depth: Float) -> Float {", in: television))
let partsBlock = internalized(
    declarationBody("static func parts(for millimeters: WorldPropSizeMillimeters) -> [Part]? {",
                    in: television))
let writerBlock = internalized(declarationBody("enum PrimitiveGLBWriter {", in: television))
let finishBlock = internalized(finish.replacingOccurrences(of: "import Foundation\n", with: ""))
let descriptorStructBlock = internalized(
    declarationBody("struct ResidentPropRenderDescriptor: Equatable, Sendable {", in: descriptor))
let descriptorExtensionBlock = internalized(
    declarationBody("extension ResidentPropRenderDescriptor {", in: descriptor))
let quadBlock = internalized(declarationBody("struct WorldScreenQuad: Equatable, Sendable {", in: quadSource))
let placementBlock = internalized(declarationBody("enum WorldScreenPlacement {", in: quadSource))

let appearanceProgram = #"""
import Foundation
import CryptoKit
import simd

// ---- 只替名字，不替算式：下面的几何/材质全部是生产源码原文 ----

struct WorldVector3: Equatable, Sendable {
    var x: Float; var y: Float; var z: Float
    init(x: Float, y: Float, z: Float) { self.x = x; self.y = y; self.z = z }
}

struct WorldPropSizeMillimeters: Equatable, Sendable {
    let x: Float; let y: Float; let z: Float
}

struct WorldQuaternion: Equatable, Sendable {
    var x: Float; var y: Float; var z: Float; var w: Float
    static let identity = WorldQuaternion(x: 0, y: 0, z: 0, w: 1)
}

enum WorldPrimitiveTelevision: Sendable {
    static let rendererName = "\#(rendererName)"

\#(partBlock)

\#(thicknessBlock)

\#(partsBlock)
}

\#(writerBlock)

\#(finishBlock)

\#(descriptorStructBlock)

\#(descriptorExtensionBlock)

\#(quadBlock)

\#(placementBlock)

// ---- 断言 ----

var failures = 0
func expect(_ ok: Bool, _ message: String) {
    if ok { print("PASS \(message)") } else { print("FAIL \(message)"); failures += 1 }
}

let spec = WorldPropSizeMillimeters(x: 1443, y: 862, z: 302)
guard let parts = WorldPrimitiveTelevision.parts(for: spec) else {
    print("FAIL A0：1443 × 862 × 302 必须能拼出零件（实测 nil）")
    print("INNER-FAILURES=1")
    exit(1)
}

// ── A0：盒子数量与角色分工**没变** ─────────────────────────────────────────
expect(parts.count == 7, "A0：盒子数量还是 7（实测 \(parts.count)）")
expect(parts.filter { $0.role == .panel }.count == 1, "A0：面板 1 块")
expect(parts.filter { $0.role == .bezel }.count == 4, "A0：边框 4 根")
expect(parts.filter { $0.role == .standNeck }.count == 1, "A0：立柱 1 根")
expect(parts.filter { $0.role == .standBase }.count == 1, "A0：底板 1 块")

// ── A1：尺寸判据**逐位不变** ───────────────────────────────────────────────
let minimum = WorldVector3(
    x: parts.map(\.minimum.x).min() ?? 0,
    y: parts.map(\.minimum.y).min() ?? 0,
    z: parts.map(\.minimum.z).min() ?? 0)
let maximum = WorldVector3(
    x: parts.map(\.maximum.x).max() ?? 0,
    y: parts.map(\.maximum.y).max() ?? 0,
    z: parts.map(\.maximum.z).max() ?? 0)
expect(abs((maximum.x - minimum.x) - 1.443) <= 1e-5,
       "A1：宽还是 1.443 m（实测 \(maximum.x - minimum.x)）")
expect(abs((maximum.y - minimum.y) - 0.862) <= 1e-5,
       "A1：高还是 0.862 m（实测 \(maximum.y - minimum.y)）")
expect(abs((maximum.z - minimum.z) - 0.302) <= 1e-5,
       "A1：深还是 0.302 m（实测 \(maximum.z - minimum.z)）")
expect(abs(minimum.y) <= 1e-5, "A1：还是落在地面上（min.y = \(minimum.y)）")
let panel = parts.first { $0.role == .panel }!
let standBase = parts.first { $0.role == .standBase }!
let neck = parts.first { $0.role == .standNeck }!
expect(abs(panel.size.z - 0.04) <= 1e-6, "A1：面板厚度还是 0.04 m（实测 \(panel.size.z)）")
expect(abs(standBase.size.z - 0.302) <= 1e-6,
       "A1：底座进深 = 用户给的第三个数 0.302 m（实测 \(standBase.size.z)）")
expect(abs(panel.maximum.z - maximum.z) <= 1e-6,
       "A1：屏幕面与整体正面同平面（panel.max.z = \(panel.maximum.z)，整体 \(maximum.z)）")

// ── A6：立柱**顶在**面板背面上（"后仰"观感的真正来源） ─────────────────────
if let panelBack = parts.first(where: { $0.name == "panel.screen" })?.minimum.z {
    expect(abs(neck.maximum.z - panelBack) <= 1e-6,
           "A6：立柱的前表面顶在面板背面上（neck.max.z = \(neck.maximum.z)，panel.min.z = \(panelBack)，"
             + "差距 \(abs(neck.maximum.z - panelBack)) m —— 改造前是 0.081 m 的空气）")
    expect(neck.minimum.z >= minimum.z - 1e-6 && neck.maximum.z <= maximum.z + 1e-6,
           "A6：立柱没有越过底板的前后沿（否则整体进深就不是 0.302 了）")
} else {
    expect(false, "A6：找不到 panel.screen 那块零件")
}

// ── A：GLB 必须带材质，而且一眼是电视 ──────────────────────────────────────
let bytes = PrimitiveGLBWriter.encode(parts: parts)
func u32(_ data: [UInt8], _ offset: Int) -> Int {
    Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
}
let byteArray = [UInt8](bytes)
var cursor = 12
var document: [String: Any]?
while cursor + 8 <= byteArray.count {
    let length = u32(byteArray, cursor), kind = u32(byteArray, cursor + 4)
    cursor += 8
    guard length >= 0, cursor + length <= byteArray.count else { break }
    if kind == 0x4E4F_534A {
        document = try? JSONSerialization.jsonObject(with: Data(byteArray[cursor..<(cursor + length)])) as? [String: Any]
    }
    cursor += length
}
guard let document else {
    print("FAIL A2：GLB 的 JSON 块解不出来")
    print("INNER-FAILURES=\(failures + 1)")
    exit(1)
}
let materials = (document["materials"] as? [[String: Any]]) ?? []
let meshPrimitives = ((document["meshes"] as? [[String: Any]])?.first?["primitives"] as? [[String: Any]]) ?? []
let accessors = (document["accessors"] as? [[String: Any]]) ?? []

expect(materials.count == 3,
       "A2：GLB 必须写出 3 份材质（屏幕 / 机身 / 底座），实测 \(materials.count) 份"
         + "—— 0 份就是真机那块「灰板」")
expect(meshPrimitives.count == materials.count,
       "A2：每个 finish 一个 primitive（实测 \(meshPrimitives.count) 个 primitive）")
expect(meshPrimitives.allSatisfy { $0["material"] != nil },
       "A2：每个 primitive 都要挂上材质索引（没有就是落回缺省的白 + 全金属）")

func material(_ finish: WorldPrimitiveTelevisionFinish) -> [String: Any]? {
    materials.first { ($0["name"] as? String) == finish.name }
}
func color(_ finish: WorldPrimitiveTelevisionFinish) -> [Float]? {
    guard let pbr = material(finish)?["pbrMetallicRoughness"] as? [String: Any],
          let raw = pbr["baseColorFactor"] as? [Double] else { return nil }
    return raw.map { Float($0) }
}
func scalar(_ finish: WorldPrimitiveTelevisionFinish, _ key: String) -> Float? {
    guard let pbr = material(finish)?["pbrMetallicRoughness"] as? [String: Any],
          let value = pbr[key] as? Double else { return nil }
    return Float(value)
}

expect(material(.screen) != nil && material(.body) != nil && material(.stand) != nil,
       "A2：三份材质分别是 screen / body / stand（名字读得到）")

if let screen = color(.screen), let body = color(.body), let stand = color(.stand) {
    // 不是灰板：没有一份是接近白的。
    let whiteish = [screen, body, stand].contains { $0[0] > 0.5 && $0[1] > 0.5 && $0[2] > 0.5 }
    expect(!whiteish, "A3：没有任何一份材质是白的（灰板的来源）。实测 屏幕 \(screen) / 机身 \(body) / 底座 \(stand)")
    // 深色机身：三个通道都 < 0.2（线性）。
    expect(body[0] < 0.2 && body[1] < 0.2 && body[2] < 0.2,
           "A3：机身/边框是深色（线性 \(body) —— 三个通道都 < 0.2）")
    // 屏幕面：深灰偏黑，但**不是纯黑**，也不是白。
    let screenMinimum = min(screen[0], min(screen[1], screen[2]))
    expect(screenMinimum > 0.02,
           "A3：屏幕面不是纯黑（最小通道 \(screenMinimum) > 0.02 —— 纯黑就是真机那块「黑洞」）")
    expect(screen[0] < 0.5 && screen[1] < 0.5 && screen[2] < 0.5,
           "A3：屏幕面是**深灰偏黑**（线性 \(screen)）")
    // 一点反光：屏幕的粗糙度最低。
    if let screenRoughness = scalar(.screen, "roughnessFactor"),
       let bodyRoughness = scalar(.body, "roughnessFactor") {
        expect(screenRoughness < 0.35,
               "A3：屏幕面带一点反光（粗糙度 \(screenRoughness) < 0.35）")
        expect(screenRoughness < bodyRoughness,
               "A3：屏幕比机身更光滑（屏幕 \(screenRoughness) < 机身 \(bodyRoughness)）")
    } else {
        expect(false, "A3：读不到 roughnessFactor")
    }
    // 三块分得开：机身最暗、屏幕居中、底座最亮。
    expect(max(body[0], max(body[1], body[2])) < min(screen[0], min(screen[1], screen[2])),
           "A3：机身比屏幕更暗（机身 \(body) < 屏幕 \(screen)）")
    expect(max(stand[0], max(stand[1], stand[2])) > max(body[0], max(body[1], body[2])),
           "A3：底座与机身是两个色（底座 \(stand) > 机身 \(body)）")
    // 材质取值必须**逐位**来自 `WorldPrimitiveTelevisionFinish`（唯一一处取值）。
    for finish in WorldPrimitiveTelevisionFinish.allCases {
        let expected = finish.baseColor
        let actual = color(finish)
        expect(actual != nil
               && abs((actual![0]) - expected.x) <= 1e-6
               && abs((actual![1]) - expected.y) <= 1e-6
               && abs((actual![2]) - expected.z) <= 1e-6
               && abs((actual![3]) - expected.w) <= 1e-6,
               "A3：\(finish.rawValue) 的基色逐位来自 `WorldPrimitiveTelevisionFinish`（实测 \(String(describing: actual))）")
    }
} else {
    expect(false, "A3：三份材质里读不出 baseColorFactor")
}

// ── A4：三角形总数 = 7 块 × 12 个（几何一个三角形都没多、没少） ─────────────
var totalPositions = 0
var totalIndices = 0
var allPoints: [SIMD3<Float>] = []
for primitive in meshPrimitives {
    guard let attributes = primitive["attributes"] as? [String: Any],
          let positionIndex = attributes["POSITION"] as? Int, positionIndex < accessors.count,
          let indexIndex = primitive["indices"] as? Int, indexIndex < accessors.count
    else { continue }
    totalPositions += (accessors[positionIndex]["count"] as? Int) ?? 0
    totalIndices += (accessors[indexIndex]["count"] as? Int) ?? 0
    if let low = accessors[positionIndex]["min"] as? [Double],
       let high = accessors[positionIndex]["max"] as? [Double], low.count == 3, high.count == 3 {
        for x in [low[0], high[0]] {
            for y in [low[1], high[1]] {
                for z in [low[2], high[2]] {
                    allPoints.append(SIMD3<Float>(Float(x), Float(y), Float(z)))
                }
            }
        }
    }
}
expect(totalPositions == 56, "A4：顶点数 = 7 块 × 8 = 56（实测 \(totalPositions)）")
expect(totalIndices == 252, "A4：索引数 = 7 块 × 36 = 252 ⇒ 84 个三角形（实测 \(totalIndices)）")

if !allPoints.isEmpty {
    let low = allPoints.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
    let high = allPoints.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
    let extent = high - low
    expect(abs(extent.x - 1.443) <= 1e-5 && abs(extent.y - 0.862) <= 1e-5 && abs(extent.z - 0.302) <= 1e-5,
           "A4：GLB 里的包围盒还是 1.443 × 0.862 × 0.302（实测 \(extent)）")
    expect(abs(low.y) <= 1e-5, "A4：GLB 里的底还是 y = 0（实测 \(low.y)）")
    expect(abs(high.z - 0.151) <= 1e-5,
           "A4：屏幕那一面还在 z = size.z / 2 = 0.151（实测 \(high.z)）—— 屏幕推断读的是它")
}

// ── A5：内容寻址（同样三轴 ⇒ 同样字节） ───────────────────────────────────
let again = PrimitiveGLBWriter.encode(parts: WorldPrimitiveTelevision.parts(for: spec)!)
expect(again == bytes, "A5：同样的三轴必须得到同样的字节（内容寻址）")
let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
print("GLB-BYTES=\(bytes.count)")
print("GLB-SHA256=sha256:\(digest)")

// ── B：姿态数字（yaw / pitch） ────────────────────────────────────────────
let identityPlacement = ResidentPropRenderDescriptor.residentProp(
    objectID: "primitive-tv", worldID: "w", assetID: "sha256:x",
    modelURL: URL(fileURLWithPath: "/tmp/primitive.glb"), targetHeightMeters: 0.862,
    position: .zero, rotation: SIMD4<Float>(0, 0, 0, 1), orientation: .identity)
expect(identityPlacement.yaw == 0,
       "B4：入库/预览姿态的 yaw = 0（实测 \(identityPlacement.yaw) rad；来源 "
         + "`WorldObjectState.transform.rotation` → `ResidentPropRenderDescriptor.yaw`）")
expect(identityPlacement.orientation == WorldQuaternion.identity,
       "B4：这台电视的摆正旋转是单位四元数（它不带 `orientation`）")

// 绕 Y 转 30°：抽出来的必须就是 30°（证明抽的是纯 yaw，俯仰混不进来）。
let half = Float.pi / 12
let thirty = ResidentPropRenderDescriptor.residentProp(
    objectID: "primitive-tv", worldID: "w", assetID: "sha256:x",
    modelURL: URL(fileURLWithPath: "/tmp/primitive.glb"), targetHeightMeters: 0.862,
    position: .zero, rotation: SIMD4<Float>(0, sin(half), 0, cos(half)), orientation: .identity)
expect(abs(thirty.yaw - Float.pi / 6) <= 1e-4,
       "B4：绕 Y 转 30° 抽出来就是 30°（实测 \(thirty.yaw) rad）")

// pitch：屏幕面 pitch = 0 ⇒ 局部法向正好是 +Z（朝房间），不是 -Z（背对房间）。
let screenQuad = WorldScreenQuad(center: SIMD3<Float>(0, 0.431, 0.151), yaw: 0, pitch: 0,
                                halfWidth: 0.62, halfHeight: 0.32)
let screenNormal = screenQuad.normal
expect(abs(screenNormal.x) <= 1e-6 && abs(screenNormal.y) <= 1e-6 && abs(screenNormal.z - 1) <= 1e-6,
       "B4：屏幕面 pitch = 0 ⇒ 局部法向 = +Z（实测 \(screenNormal)）")
print("POSE-YAW=0.000000")
print("POSE-PITCH=0.000000")

print("INNER-FAILURES=\(failures)")
if failures > 0 { exit(1) }
"""#

// ---------------------------------------------------------------------------
// MARK: 内层程序 2：面板文案（编真的 Screen/**.swift）
// ---------------------------------------------------------------------------

let screenFiles = [
    "WorldScreenGeometry.swift", "WorldScreenInference.swift", "WorldScreenProjection.swift",
    "WorldScreenContent.swift", "WorldScreenState.swift", "ResidentScreenTools.swift",
    "WorldScreenOcclusion.swift",
]

let copyProgram = #"""
import Foundation
import simd

var failures = 0
func expect(_ ok: Bool, _ message: String) {
    if ok { print("PASS \(message)") } else { print("FAIL \(message)"); failures += 1 }
}

/// 「面板文案不许出现的工程术语」。判据就是这张表 —— 出现在**任何**一句给用户看的话里
/// （含 `key=value` 形状的数值对）都算缺陷。
let forbidden = ["法向", "面积", "m²", "格", "ms", "法线", "normal", "area"]
let numberPairs = try! NSRegularExpression(pattern: "[A-Za-z_]+\\s*=\\s*[-0-9.]")
func leaked(_ line: String) -> [String] {
    var hits = forbidden.filter(line.contains)
    let range = NSRange(line.startIndex..., in: line)
    if numberPairs.firstMatch(in: line, range: range) != nil { hits.append("key=value") }
    return hits
}

// ── C1：屏幕范围那一句 ────────────────────────────────────────────────────
let rangeLines: [(WorldScreenSource?, Bool)] = [
    (.calibrated, false), (.inferred, false), (.default, false), (nil, false), (nil, true),
]
for (source, hasIssue) in rangeLines {
    let line = ScreenPanelCopy.screenRangeLine(source: source, hasGeometryIssue: hasIssue)
    expect(leaked(line).isEmpty,
           "C1：屏幕范围那一句没有人看的懂的字：\(line)（泄漏 \(leaked(line))）")
}
expect(ScreenPanelCopy.screenRangeLine(source: .inferred, hasGeometryIssue: false).contains("自动识别"),
       "C1：自动认出来的那句说的是「自动识别」")
expect(ScreenPanelCopy.screenRangeLine(source: .calibrated, hasGeometryIssue: false).contains("你标定的"),
       "C1：用户标定的那句说的是「你标定的」")

// ── C2：状态那一句（含播放失败） ──────────────────────────────────────────
let states: [WorldScreenSurfaceState?] = [
    nil, .idle, .loading(url: "https://www.youtube.com/embed/abc"),
    .playing(url: "https://www.youtube.com/embed/abc"), .stopped,
    .failed(.network("The Internet connection appears to be offline.")),
    .failed(.httpStatus(404)), .failed(.timeout), .failed(.blocked("X-Frame-Options")),
]
for state in states {
    guard let line = ScreenPanelCopy.statusLine(for: state, isPlaying: state?.isPlaying ?? false) else {
        continue
    }
    expect(leaked(line).isEmpty,
           "C2：状态那一句是人话：\(line)（泄漏 \(leaked(line))）")
}
expect(ScreenPanelCopy.statusLine(for: .playing(url: "x"), isPlaying: true) == nil,
       "C2：播放中面板不摆状态行（画面本身就是状态）")

// ── C3：遮挡只在**真的被挡**时给一句，而且不刷屏 ───────────────────────────
expect(ScreenPanelCopy.occlusionLine(isBlocked: false) == nil,
       "C3：没被挡 ⇒ 面板一个字都不说（实测 \(String(describing: ScreenPanelCopy.occlusionLine(isBlocked: false)))）")
guard let blockedLine = ScreenPanelCopy.occlusionLine(isBlocked: true) else {
    print("FAIL C3：被挡时必须说一句（实测 nil）")
    print("INNER-FAILURES=\(failures + 1)")
    exit(1)
}
expect(leaked(blockedLine).isEmpty, "C3：被挡那一句没有人看的懂的字：\(blockedLine)（泄漏 \(leaked(blockedLine))）")
expect(!blockedLine.contains("336") && !blockedLine.contains("/") && !blockedLine.contains("117"),
       "C3：被挡那一句不说格数、不说毫秒：\(blockedLine)")
// 不刷屏 = 同一状态永远是**同一句**（没有每帧都在变的数字）。
let repeated = (0..<50).map { _ in ScreenPanelCopy.occlusionLine(isBlocked: true) ?? "" }
expect(Set(repeated).count == 1,
       "C3：被挡的整段时间里是同一句话（实测 \(Set(repeated).count) 种说法 ⇒ 不会刷屏）")

// ── C4：动作与提示 ────────────────────────────────────────────────────────
let labels = [ScreenPanelCopy.playActionTitle, ScreenPanelCopy.stopActionTitle,
              ScreenPanelCopy.adjustRangeActionTitle, ScreenPanelCopy.contentPlaceholder]
for label in labels {
    expect(leaked(label).isEmpty, "C4：面板上的字是人话：\(label)（泄漏 \(leaked(label))）")
}
expect(labels.contains("调整屏幕范围"),
       "C4：那个动作叫「调整屏幕范围」，不叫「标定」")
expect(leaked(ScreenPanelCopy.capacityLine(maximum: 2)).isEmpty,
       "C4：容量那一句是人话：\(ScreenPanelCopy.capacityLine(maximum: 2))")

// ── C5：面板**不再**显示工程的原文 ────────────────────────────────────────
let engineeringNote = "由最大平坦面推断：法向 +Z（正面），面积 1.244 m²（1.24 m × 0.74 m）。不是标定值，可在面板里改。"
let engineeringOcclusion = "前景遮挡：24 × 14 格全部可见（117.98 ms）"
expect(!leaked(engineeringNote).isEmpty && !leaked(engineeringOcclusion).isEmpty,
       "C5：判据自己抓得住真机那两句工程原文（负对照：判据不是恒真）")

print("INNER-FAILURES=\(failures)")
if failures > 0 { exit(1) }
"""#

// ---------------------------------------------------------------------------
// MARK: 现编现跑
// ---------------------------------------------------------------------------

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-tv-look-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func run(_ binary: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    // 编不出来时根本没有可执行文件：**如实报**，不许把"没编起来"当成"通过了"。
    guard FileManager.default.isExecutableFile(atPath: binary) else {
        return (127, "（没有可执行文件：\(binary)）")
    }
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (126, "启动 \(binary) 失败：\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// A + B：外观与姿态。单文件 ⇒ 顶层代码写在 `main.swift` 里。
let appearanceDirectory = temporary.appendingPathComponent("Appearance", isDirectory: true)
try FileManager.default.createDirectory(at: appearanceDirectory, withIntermediateDirectories: true)
let appearanceFile = appearanceDirectory.appendingPathComponent("main.swift")
try appearanceProgram.write(to: appearanceFile, atomically: true, encoding: .utf8)
let appearanceBinary = temporary.appendingPathComponent("appearance-bin")
let appearanceCompile = try run("/usr/bin/swiftc",
    ["-j1", appearanceFile.path, "-o", appearanceBinary.path])
check(appearanceCompile.status == 0,
      "A/B 内层程序编译通过（exit \(appearanceCompile.status)）")
if appearanceCompile.status != 0 {
    print(appearanceCompile.output.split(separator: "\n").suffix(12).joined(separator: "\n"))
}
let appearanceRun = try run(appearanceBinary.path, [])
/// 每个注入打的是哪一层。**只有**打中的那一层必须变红 —— 否则判据会变成"任何改动都红"
/// 的噪音门禁（那种门禁最后一定被忽略）。
let appearanceInjections = ["old-grey-material", "screen-pure-black", "drop-materials", "yaw-drift"]
let copyInjections = ["engineering-copy", "occlusion-spam"]
if injection == nil {
    check(appearanceRun.status == 0, "A/B 所有断言通过（外观 + 姿态）")
    check(appearanceRun.output.contains("POSE-YAW=0.000000") && appearanceRun.output.contains("POSE-PITCH=0.000000"),
          "A/B 姿态数字：yaw = 0.000000 rad、pitch = 0.000000 rad")
    if let sha = appearanceRun.output.split(separator: "\n").first(where: { $0.hasPrefix("GLB-SHA256=") }),
       let count = appearanceRun.output.split(separator: "\n").first(where: { $0.hasPrefix("GLB-BYTES=") }) {
        print("  · \(count) \(sha)")
    }
} else if appearanceInjections.contains(injection!) {
    check(appearanceRun.status != 0,
          "注入 \(injection!) ⇒ A/B 判据必须变红（实测 exit \(appearanceRun.status)）")
}
if let line = appearanceRun.output.split(separator: "\n").last(where: { $0.hasPrefix("INNER-FAILURES=") }) {
    print("  · A/B 内层 \(line)")
}
// 内层的每一条都打出来（含 PASS）：判据的**材料取值**必须看得见，审计才不用读源码。
for line in appearanceRun.output.split(separator: "\n")
where line.hasPrefix("PASS") || line.hasPrefix("FAIL") {
    print("  · \(line)")
}

/// C：面板文案。注入时把打了手术的副本写到临时目录再编（原件一个字节都不动）。
let copySourcesRoot = temporary.appendingPathComponent("Screen", isDirectory: true)
try FileManager.default.createDirectory(at: copySourcesRoot, withIntermediateDirectories: true)
var copySourcePaths: [String] = []
for name in screenFiles {
    let original = try String(contentsOf: screenRoot.appendingPathComponent(name), encoding: .utf8)
    let text = patched(original, file: name)
    let target = copySourcesRoot.appendingPathComponent(name)
    try text.write(to: target, atomically: true, encoding: .utf8)
    copySourcePaths.append(target.path)
}
let copyDirectory = temporary.appendingPathComponent("Copy", isDirectory: true)
try FileManager.default.createDirectory(at: copyDirectory, withIntermediateDirectories: true)
let copyFile = copyDirectory.appendingPathComponent("main.swift")
try copyProgram.write(to: copyFile, atomically: true, encoding: .utf8)
let copyBinary = temporary.appendingPathComponent("copy-bin")
// 多文件时顶层代码只允许写在 `main.swift` 里 ⇒ 上面就是那个名字。
let copyCompile = try run("/usr/bin/swiftc",
    ["-j1"] + copySourcePaths + [copyFile.path, "-o", copyBinary.path])
check(copyCompile.status == 0, "C 内层程序编译通过（exit \(copyCompile.status)）")
if copyCompile.status != 0 {
    print(copyCompile.output.split(separator: "\n").suffix(12).joined(separator: "\n"))
}
let copyRun = try run(copyBinary.path, [])
if injection == nil {
    check(copyRun.status == 0, "C 所有断言通过（面板文案无工程术语、遮挡只说一次）")
} else if copyInjections.contains(injection!) {
    check(copyRun.status != 0,
          "注入 \(injection!) ⇒ C 判据必须变红（实测 exit \(copyRun.status)）")
}
if let line = copyRun.output.split(separator: "\n").last(where: { $0.hasPrefix("INNER-FAILURES=") }) {
    print("  · C 内层 \(line)")
}
for line in copyRun.output.split(separator: "\n")
where line.hasPrefix("PASS") || line.hasPrefix("FAIL") {
    print("  · \(line)")
}

print(failureCount == 0 ? "PASS: 电视外观 + 姿态 + 面板人话（含注入负对照）" : "FAIL: 共 \(failureCount) 条")
exit(failureCount == 0 ? 0 : 1)
