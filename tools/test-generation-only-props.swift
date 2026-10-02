// 物件**只从用户的素材生成**来：三轴尺寸逐轴兑现，不再手拼几何（用户 2026-10-02 的产品决定）。
//
// 原话「不能再用集合拼了」：`WorldPrimitiveTelevision`（面板 + 边框 + 底座那套手拼几何）
// **停用** —— 类型保留、产品路径零调用。生成器把形状做歪时（真机 2026-10-01「平面电视」：
// 用户给了 `1443 × 862 × 302 mm`，生成器交回来一个把参考图贴在各面上的大立方体），
// 正确做法是**按用户给的三维尺寸逐轴缩放到位**：素材会被拉伸，那正是"素材 + 他的尺寸"
// 这个取舍本身 —— 不是拿一个手拼的替代品糊上去，也不再给"重新生成 / 手拼几何"这种二选一。
//
// 这个文件两条腿，都配**注入负对照**（一个从不 FAIL 的门禁等于没有门禁）：
//   A. 接线（文本级）：App 侧零几何拼构造点、零"用几何拼"选项的文案与分支；
//   B. 行为（编**真** WorldRuntime 源码）：三轴 ⇒ 世界尺寸逐位是那三个数；
//      "形状差得远"不许再挡住逐轴（裁决只会给 `.exact` / `.unrealizable`）。
//
// 运行：`swift tools/test-generation-only-props.swift`
import Foundation

// WorldRuntime 的模块搜索路径与目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
// harness 一律调用它，绝不自己拼 `.build/...`（27 份各自拼写正是两份模块并存的根因）。
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

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appPath = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift")
guard let appSource = try? String(contentsOf: appPath, encoding: .utf8) else {
    print("FAIL: 读不到 App/GMGNRadioApp.swift"); exit(1)
}

// ── A：接线判据（文本级）────────────────────────────────────────────────────────
//
// 判据是**接线本身**，因为类型级判据可以全绿而 App 侧一个构造点都没有：编译得进、跑不起来。
/// 「物件只来自素材生成 + 三轴逐轴兑现」这条接线在不在。空数组 = 接线完整。
func generationOnlyProblems(_ app: String) -> [String] {
    var problems: [String] = []
    // ① 产品路径**零**几何拼构造点。
    if app.contains("WorldPrimitiveTelevision(") {
        problems.append("① 产品路径又在构造手拼几何（`WorldPrimitiveTelevision(`）："
            + "用户要的是物件一律来自他的素材生成")
    }
    // ② 那条"手拼"分支整个不在（局部名字与它专用的内容寻址搬运调用）。
    if app.contains("primitiveTelevision") {
        problems.append("② 「板形 ⇒ 手拼」那条分支还在（`primitiveTelevision`）")
    }
    if app.contains("Self.materializeContentAddressedAsset(") {
        problems.append("② 手拼几何专用的资产搬运调用还在（`Self.materializeContentAddressedAsset(`）")
    }
    // ③ 不再有"板形"这个门槛把三轴物件分流（板形判据本身在 `WorldScreenInference` 里保留）。
    if app.contains("WorldScreenFaceInference.rejection") {
        problems.append("③ 入库这一处还在按「板形」分流（`WorldScreenFaceInference.rejection`）")
    }
    // ④ 不再提供"用几何拼"这个选项：文案与分支都清掉。
    if app.contains("用几何拼") || app.contains("二选一") {
        problems.append("④ 还在给用户「用几何拼」这个选项（文案或分支）")
    }
    if app.contains("shapeChoiceNotice") || app.contains("geometryUnavailableNotice") {
        problems.append("④ 「重新生成 / 用几何拼」二选一的那两条文案调用还在")
    }
    // ⑤ 三轴尺寸只走**唯一一份**裁决与策略（app 不自己另写缩放、不自己判"要不要拉"）。
    if !app.contains("WorldPropSizePolicy.dimensionsVerdict(") {
        problems.append("⑤ 三轴尺寸没有走唯一一份裁决（`dimensionsVerdict(`）")
    }
    if !app.contains("WorldPropSizePolicy.intended(") {
        problems.append("⑤ 尺寸没有走唯一一份策略（`WorldPropSizePolicy.intended(`）")
    }
    // ⑥ 生成网格那条路必须真的走得到（外观 / 贴图 / 细节都来自用户那张素材）。
    if !app.contains("let url = URL(fileURLWithPath: path)") {
        problems.append("⑥ 生成网格那条路不见了：外观、贴图、细节都来自它")
    }
    if !app.contains("assetID: \"sha256:\" + hash.lowercased()") {
        problems.append("⑥ 生成产物的资产引用不再是那份网格的字节：素材的贴图与细节会丢")
    }
    // ⑦ 只有"明显不可用"才打扰用户，而且只给**唯一**那条建议。
    if !app.contains("换一张正面产品图重新生成") {
        problems.append("⑦ 明显不可用时没有那条唯一建议（换一张正面产品图重新生成）")
    }
    return problems
}

/// 注入负对照：把源码副本改成**已知会坏**的样子，判据必须变红。
let injections: [(name: String, old: String, new: String)] = [
    // 最要命的那一条：手拼几何又被接回产品路径（用户明说不要）。
    ("primitive-back",
     "                let url = URL(fileURLWithPath: path)",
     "                let primitiveTelevision = try? WorldPrimitiveTelevision(millimeters: spec)\n                let url = URL(fileURLWithPath: path)"),
    // "板形"门槛又回来了：三轴物件被分流去手拼。
    ("panel-gate-back",
     "                let url = URL(fileURLWithPath: path)",
     "                _ = WorldScreenFaceInference.rejection(size: .zero, objectID: job.objectID)\n                let url = URL(fileURLWithPath: path)"),
    // 二选一的文案又回来了。
    ("choice-copy-back",
     "                let url = URL(fileURLWithPath: path)",
     "                _ = ResidentPropTelevisionRepair.shapeChoiceNotice(name: job.name, millimeters: millimeters)\n                let url = URL(fileURLWithPath: path)"),
    // 三轴没兑现时的建议被删掉：用户看不到"换正面产品图重新生成"。
    ("drop-regenerate-advice",
     "换一张正面产品图重新生成",
     "请稍后再试"),
    // 裁决被绕开（自己另写一套"要不要拉"）。
    ("drop-verdict",
     "WorldPropSizePolicy.dimensionsVerdict(",
     "WorldPropSizePolicy.intended("),
]

// 现场演示：`GENERATION_ONLY_INJECT=primitive-back swift tools/test-generation-only-props.swift`
var observedAppSource = appSource
if let name = ProcessInfo.processInfo.environment["GENERATION_ONLY_INJECT"],
   let injection = injections.first(where: { $0.name == name }) {
    print("·· GENERATION_ONLY_INJECT=\(name)：把真源码当成被注入过的那一份来判")
    guard observedAppSource.contains(injection.old) else {
        print("FAIL: 注入锚点在真源码里找不到：\(injection.old)"); exit(1)
    }
    observedAppSource = observedAppSource.replacingOccurrences(of: injection.old, with: injection.new)
}

let wiringIssues = generationOnlyProblems(observedAppSource)
for issue in wiringIssues { print("FAIL: \(issue)") }
guard wiringIssues.isEmpty else {
    print("FAIL: 物件没有做到「只来自素材生成 + 三轴逐轴兑现」（判据见上）"); exit(1)
}
print("PASS: A. App 侧零几何拼构造点、零「用几何拼」选项；三轴走唯一一份裁决与策略")

for injection in injections {
    var injected = appSource
    guard injected.contains(injection.old) else {
        print("FAIL: 注入负对照「\(injection.name)」的锚点在源码里找不到：\(injection.old)"); exit(1)
    }
    injected = injected.replacingOccurrences(of: injection.old, with: injection.new)
    guard injected != appSource else {
        print("FAIL: 注入负对照「\(injection.name)」没有改到源码副本"); exit(1)
    }
    let issues = generationOnlyProblems(injected)
    guard !issues.isEmpty else {
        print("FAIL: 注入负对照「\(injection.name)」（\(injection.new)）⇒ 判据必须变红，它却全绿")
        exit(1)
    }
    print("PASS: 注入负对照「\(injection.name)」⇒ 判据变红（\(issues[0])）")
}

// ── B：行为判据（编**真** WorldRuntime 源码）──────────────────────────────────
//
// 判据不猜 API 名字：把**真机那份网格**（`TaskService/0C285296-….glb` 的逐顶点实测包围盒，
// 一个把参考图贴在各面上的立方体）与用户的三轴交给唯一一份策略，世界尺寸必须是那三个数。
//
// **先挡一条假绿**：harness 链接的是 SwiftPM 预编译的 `WorldRuntime` 目标文件
// （`tools/world-runtime-harness-flags.sh` 那一份）。它们比源文件旧 ⇒ 下面这些行为判据测的
// 是**旧语义**，会绿得毫无意义。判据看的是**真正被链进去的那些 .o**（不是 .swiftmodule：
// 公开接口没变时它不会被重写）：源文件比最新的 .o 新 ⇒ 先自己 `swift build` 一次再判；
// 重建之后仍然旧（源文件正在被改）⇒ FAIL 并给出命令（绝不拿旧语义冒充绿）。
var flags = worldRuntimeHarnessFlags()
let policySource = root.appendingPathComponent(
    "apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldPropSizePolicy.swift")
func modificationDate(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
}
func newestObjectDate(_ flags: [String]) -> Date? {
    flags.filter { $0.hasSuffix(".o") }.compactMap(modificationDate).max()
}
if let sourceDate = modificationDate(policySource.path), let objectDate = newestObjectDate(flags),
   sourceDate > objectDate {
    let build = Process()
    build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    build.arguments = ["swift", "build", "--package-path",
                       root.appendingPathComponent("apps/macos/Packages/WorldRuntime").path]
    build.standardOutput = FileHandle.nullDevice
    build.standardError = FileHandle.nullDevice
    try? build.run(); build.waitUntilExit()
    flags = worldRuntimeHarnessFlags()
    if let retrySource = modificationDate(policySource.path), let retryObject = newestObjectDate(flags),
       retrySource > retryObject {
        print("FAIL: SwiftPM 的 WorldRuntime 目标文件比源文件旧（行为判据会测旧语义）："
            + "先跑 swift build --package-path apps/macos/Packages/WorldRuntime")
        exit(1)
    }
}
let program = #"""
import Foundation
import simd
import WorldRuntime

var checks = 0
var failures: [String] = []
@MainActor func check(_ value: Bool, _ label: String) { if value { checks += 1 } else { failures.append(label) } }

// 真机那份生成网格（字节级实测）：1.007901 × 0.628927 × 1.007904 米。
let mesh = WorldVector3(x: 1.007901, y: 0.628927, z: 1.007904)
let spec = WorldPropSizeMillimeters(x: 1443, y: 862, z: 302)!

// ① 三轴**逐轴**兑现：世界尺寸逐位就是用户说的三个数（米）。
let resolution = WorldPropSizePolicy.intended(sourceExtent: mesh, millimeters: spec)
check(resolution != nil, "三轴意图必须能兑现（实测 nil ⇒ 现场那句「尺寸无效」）")
check(resolution.map {
    abs($0.size.x - 1.443) <= 1e-5 && abs($0.size.y - 0.862) <= 1e-5 && abs($0.size.z - 0.302) <= 1e-5
} ?? false,
"世界 size 必须逐位是 1.443 × 0.862 × 0.302（实测 \(String(describing: resolution?.size))）")

// ② 形状差得远**不许**再挡住逐轴：立方体 → 扁平面板这一份网格的偏离度是 4.78（> 2）。
if case .exact = WorldPropSizePolicy.dimensionsVerdict(sourceExtent: mesh, millimeters: spec) {
    check(true, "形状差 4.78 倍时裁决仍是 .exact（用户决定：宁可拉素材，不换手拼件）")
} else {
    check(false, "裁决把「形状差得远」当成了不许逐轴的理由（实测不是 .exact）")
}

// ③ 注入负对照（数值）：退回"按最长边等比"那一条路时，三个数**不可能**都对 ——
//    这条判据真的会红，不是一份自证的形状。
let uniform = WorldPropSizePolicy.intended(sourceExtent: mesh, axis: .longest, meters: 1.443)
let uniformMatches = uniform.map {
    abs($0.size.x - 1.443) <= 1e-4 && abs($0.size.y - 0.862) <= 1e-4 && abs($0.size.z - 0.302) <= 1e-4
} ?? false
check(!uniformMatches,
      "注入负对照：等比归一那一条路必须**不**满足三轴逐位（实测 \(String(describing: uniform?.size))）")

for failure in failures { print("FAIL: " + failure) }
guard failures.isEmpty else { exit(1) }
print("PASS: B. 三轴逐轴兑现 \(checks) 条（世界 size 逐位 1.443 × 0.862 × 0.302；形状差得远不再挡）")
"""#

let temp = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-generation-only-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let main = temp.appendingPathComponent("main.swift")
try program.write(to: main, atomically: true, encoding: .utf8)
let binary = temp.appendingPathComponent("checks")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
compiler.arguments = ["swiftc", "-swift-version", "6"]
    + flags + [main.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let run = Process(); run.executableURL = binary
try run.run(); run.waitUntilExit(); exit(run.terminationStatus)
