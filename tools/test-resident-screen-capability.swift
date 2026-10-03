// 电视机「屏幕功能点**真的注册到物件上**」的行为判据（真机 2026-10-03）。
//
// ## 现场
//
// 用户说「电视播放这个」，居民答的是：
//
//   这台电视在空间里登记的是**纯外形摆件**，我**这一轮也没有能把视频投到屏幕上的能力**……
//
// 两句话是**同一个断点**的两面：屏幕这件事原先只活在 `WorldScreenStore` 里，
// 而 store 只在 `installScreenOverlayIfNeeded()` 里建 —— 那一条路要求舞台窗口
// **已经出现过**。于是：
//
//   · 三条工具（play_screen / stop_screen / read_screen）在"窗口还没出现过"的那一轮
//     里**整批不存在**（App 侧是 `screenStore.map { … } ?? []`）⇒ 居民说"我没有能力"；
//   · 物件描述那边，`read_owned_props` 的回执里只有 `interaction_status: appearance_only`
//     （判据是"有没有哪一件带 `capability`"）⇒ 居民说"登记的是纯外形摆件"。
//
// 这一份判据钉的就是**第二面**：屏幕功能点必须真的注册到物件上，
// 而且这份注册必须**不依赖**窗口 / 视图树 / 覆盖层。
//
// ## 判据是行为级的，不是文本级的
//
// `tools/test-resident-screen-app-wiring.swift` 用文本级判据回答"接线在不在"；
// 这一份把生产的 **`WorldScreenCapabilityRegistry.derive`** 与
// **`WorldScreenControlRelay`** 原文切进来**现编现跑**，用真实的 `WorldObjectState`
// 替身驱动它：真机那一轮屋里那几件物件（电视 / 咖啡机 / 长剑 / 落地灯）就是夹具。
//
// 三条断言，每条都配注入负对照（注入只在**临时副本**上做手术，跑完即弃）：
//
//   ① 物件**真的有屏幕** ⇒ 注册表里有它（含几何出处与宽高比）；
//      不像屏幕的物件（咖啡机 / 长剑）⇒ 一件都不许被说成能播；
//   ② 注册**不依赖覆盖层**：`live` 拿不到 store 时 `listScreens()` 照样说得出是哪一台、
//      `play_screen` 仍返回**具名且可行动**的答复（是哪一件 + 怎么改）；
//   ③ **有屏幕才说能播**：一件都没注册时，三条工具仍然在（清单靠的是接线），
//      但 `read_screen` 说"没有"，`play_screen` 不许说"已经放起来了"。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let screenRoot = sourceRoot.appendingPathComponent("Screen")

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

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-screen-capability-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

// ---------------------------------------------------------------------------
// MARK: 生产源码（`WorldScreenMetadata.swift` 需要去掉 WorldRuntime 的 import：
// 这一层用替身）
// ---------------------------------------------------------------------------

let metadataPath = screenRoot.appendingPathComponent("WorldScreenMetadata.swift")
let productionMetadata = try read(metadataPath)
let toolsPath = screenRoot.appendingPathComponent("ResidentScreenTools.swift")
let productionTools = try read(toolsPath)
guard productionMetadata.contains("import WorldRuntime") else {
    print("FAIL 生产源码的 import 变了：`WorldScreenMetadata.swift` 里没有 `import WorldRuntime`（替身接不上）")
    exit(1)
}

/// `WorldRuntime` 的替身这一层只有一个类型：切进来的生产代码要的字段就是这几个。
let innerPrelude = ##"""
import Foundation

/// `WorldRuntime.WorldVector3` 的类型替身（与 `test-resident-screen-overlay.swift` 同形）。
struct WorldVector3: Equatable, Sendable {
    var x: Float
    var y: Float
    var z: Float
    init(x: Float, y: Float, z: Float) { self.x = x; self.y = y; self.z = z }
    init(_ value: SIMD3<Float>) { self.init(x: value.x, y: value.y, z: value.z) }
    var simd: SIMD3<Float> { SIMD3(x, y, z) }
}

/// 生成道具的替身。生产那边注册表读的就是 `displayName` 与 `effectiveSize`。
struct WorldGeneratedPropStub: Equatable, Sendable {
    let objectID: String
    let displayName: String
    let size: WorldVector3
    var effectiveSize: WorldVector3 { size }
}

/// `WorldRuntime.WorldObjectState` 的替身：注册表只读 `isEnabled` / `metadata` /
/// `generatedProp`，一个都不多。
struct WorldObjectState {
    var isEnabled: Bool = true
    var metadata: [String: String] = [:]
    var generatedProp: WorldGeneratedPropStub?

    init(isEnabled: Bool = true, metadata: [String: String] = [:],
         generatedProp: WorldGeneratedPropStub? = nil) {
        self.isEnabled = isEnabled
        self.metadata = metadata
        self.generatedProp = generatedProp
    }
}

var failuresTotal = 0
func expect(_ condition: Bool, _ message: String) {
    if condition { print("PASS \(message)") } else { print("FAIL \(message)"); failuresTotal += 1 }
}

/// 夹具：**真机 2026-10-03 那一轮屋里那几件物件**（尺寸来自当时的
/// `gmgn_read_owned_props` 回执与生成记录）。
enum Fixture {
    static func tv(displayName: String = "超大荧幕电视", enabled: Bool = true) -> WorldObjectState {
        WorldObjectState(isEnabled: enabled, generatedProp: WorldGeneratedPropStub(
            objectID: "wish-prop-f9682580-da52-47b5-b10a-b549f09cd23b",
            displayName: displayName,
            size: WorldVector3(x: 1.443, y: 0.862, z: 0.302)
        ))
    }
    static func coffeeMachine() -> WorldObjectState {
        WorldObjectState(generatedProp: WorldGeneratedPropStub(
            objectID: "wish-prop-ebfc07be-6af3-4e25-af6c-9e795c6e28c6",
            displayName: "E2E-0907 咖啡机",
            size: WorldVector3(x: 0.2915, y: 0.35, z: 0.4719)
        ))
    }
    static func axe() -> WorldObjectState {
        WorldObjectState(generatedProp: WorldGeneratedPropStub(
            objectID: "wish-prop-02bfee6e-82ad-4680-8525-db2d86791bf1",
            displayName: "斧头",
            size: WorldVector3(x: 0.8855, y: 0.7, z: 0.0865)
        ))
    }
    static func sword() -> WorldObjectState {
        WorldObjectState(generatedProp: WorldGeneratedPropStub(
            objectID: "wish-prop-4210db95-9253-4caf-83a3-3c45f090b099",
            displayName: "2B 白色长剑（外形摆件）",
            size: WorldVector3(x: 0.1460, y: 1.1, z: 0.0619)
        ))
    }
    static func floorLamp() -> WorldObjectState {
        WorldObjectState(generatedProp: WorldGeneratedPropStub(
            objectID: "wish-prop-b8594eb9-ad6c-46d4-a754-99be7f510042",
            displayName: "暖光落地灯",
            size: WorldVector3(x: 0.3483, y: 1.5, z: 0.7670)
        ))
    }

    /// **真机那一轮屋里那五件**（尺寸逐位来自当时的 `gmgn_read_owned_props` 回执）。
    static var livingRoom: [String: WorldObjectState] {
        var states: [String: WorldObjectState] = [:]
        for state in [tv(), coffeeMachine(), axe(), sword(), floorLamp()] {
            states[state.generatedProp!.objectID] = state
        }
        return states
    }

    /// 屋里这几件的几何分类（判据是**几何**：最薄轴 / 最长轴 > 1/4 就不是板）：
    /// - 咖啡机 0.29 × 0.35 × 0.47 ⇒ 0.62 > 0.25 ⇒ **不像板**（注册与候选两边都不出现）；
    /// - 斧头 0.89 × 0.70 × 0.09 ⇒ 0.098、长剑 0.15 × 1.10 × 0.06 ⇒ 0.056、
    ///   落地灯 0.35 × 1.50 × 0.77 ⇒ 0.232 ⇒ 都**像一块板**，但名字里都没有
    ///   「电视 / 屏幕」⇒ 只进"还没被认成屏幕"的候选，**绝不**进注册表。
    static let panelLikeButNotNamedIDs: Set<String> = [
        "wish-prop-02bfee6e-82ad-4680-8525-db2d86791bf1",
        "wish-prop-4210db95-9253-4caf-83a3-3c45f090b099",
        "wish-prop-b8594eb9-ad6c-46d4-a754-99be7f510042",
    ]

    static let tvObjectID = "wish-prop-f9682580-da52-47b5-b10a-b549f09cd23b"

    static func displayName(_ states: [String: WorldObjectState]) -> (String) -> String {
        { states[$0]?.generatedProp?.displayName ?? $0 }
    }

    static func snapshot(_ states: [String: WorldObjectState]) -> WorldScreenRegistrySnapshot {
        WorldScreenCapabilityRegistry.derive(
            objectStates: states, displayName: displayName(states)
        )
    }
}

/// 覆盖层**接上了**的替身：只有 `live` 给得出它时才会被问到。
@MainActor
final class StubLiveControl: WorldScreenControlling {
    var screens: [WorldScreenSnapshot] = []
    var candidates: [WorldScreenCandidate] = []
    var playResult = WorldScreenCommandOutcome.ok("已经放起来了。")
    var stopResult = WorldScreenCommandOutcome.ok("已关掉。")
    var asked = 0

    func listScreens() -> [WorldScreenSnapshot] { screens }
    func unrecognizedScreenCandidates() -> [WorldScreenCandidate] { candidates }
    func playScreen(objectID: String?, rawContent: String) async -> WorldScreenCommandOutcome {
        asked += 1
        return playResult
    }
    func stopScreen(objectID: String?) -> WorldScreenCommandOutcome { stopResult }
    func calibrateScreen(objectID: String, widthMeters: Float, heightMeters: Float,
                         centerHeightMeters: Float) -> WorldScreenCommandOutcome { playResult }
}

@main struct Test {
    @MainActor static func main() async {
        // =========================================================
        // 断言 1：物件真的有屏幕 ⇒ 注册表里有它；不像屏幕的一件都不许说成能播
        // =========================================================
        let room = Fixture.livingRoom
        let snapshot = Fixture.snapshot(room)

        let registeredIDs = Set(snapshot.registered.map(\.objectID))
        expect(registeredIDs == [Fixture.tvObjectID],
            "断言1：屋里只有那台电视真的注册了屏幕功能点（实测 \(registeredIDs.sorted())）")

        let tv = snapshot.registered.first { $0.objectID == Fixture.tvObjectID }
        expect(tv?.displayName == "超大荧幕电视",
            "断言1：注册结果带着**是哪一件**（\(tv?.displayName ?? "（没有）")）")
        expect(tv?.source == .inferred,
            "断言1：几何出处逐字来自 `WorldScreenDefinition`（实测 \(String(describing: tv?.source))）")
        expect((tv?.note.isEmpty == false),
            "断言1：出处原话非空（不确定就必须说得出来）")
        expect((tv?.aspect ?? 0) > 1.0,
            "断言1：屏幕面宽高比是真实的（1.443 × 0.862 的正面 ⇒ > 1，实测 \(tv?.aspect ?? 0)）")
        // 这一行是**物件描述里那一行的原文** —— `read_owned_props` 回执里 `screen` 那个键
        // （`key` / `can_play` / `source` / `note` / `aspect`）就是从它来的。
        // 真机 2026-10-03 那一轮，居民读到的物件描述里**没有**这一行。
        if let tv {
            let tvNote = tv.note
            let tvSource = tv.source.rawValue
            print("SCREEN-CAPABILITY object=\(tv.objectID) name=\(tv.displayName) source=\(tvSource) aspect=\(tv.aspect) note=\(tvNote)")
        }

        // 不像一块板的（咖啡机）：一件都不许被说成能播，也一件都不许跑进"还没被认成屏幕"。
        let coffeeID = Fixture.coffeeMachine().generatedProp!.objectID
        expect(!registeredIDs.contains(coffeeID), "断言1：咖啡机没有被说成有屏幕")
        expect(!snapshot.candidates.contains { $0.objectID == coffeeID },
            "断言1：咖啡机也不在「还没被认成屏幕」的候选里（0.62 > 0.25，它不像一块板）")

        // 像一块板、但名字里没有「电视 / 屏幕」的那几件：**绝不许**被认成屏幕（那才是夸口），
        // 但必须出现在"还没被认成屏幕"的候选里 —— 居民要答得出"是哪一件、为什么"。
        for (name, state) in [("斧头", Fixture.axe()), ("长剑", Fixture.sword()),
                              ("落地灯", Fixture.floorLamp())] {
            let id = state.generatedProp!.objectID
            expect(Fixture.panelLikeButNotNamedIDs.contains(id), "（夹具自查）\(name)确实是像板的")
            expect(!registeredIDs.contains(id), "断言1：\(name)没有被说成有屏幕（它不叫电视）")
            let candidate = snapshot.candidates.first { $0.objectID == id }
            expect(candidate != nil, "断言1：\(name)出现在「还没被认成屏幕」的候选里")
            expect(candidate?.reason.contains("名字里没有") == true,
                "断言1：\(name)的候选理由具名（\(candidate?.reason ?? "（没有）")）")
        }

        // 收回（isEnabled = false）的电视不再是屏幕：判据跟着**世界状态**走。
        var withdrawn = room
        withdrawn[Fixture.tvObjectID] = Fixture.tv(enabled: false)
        expect(Fixture.snapshot(withdrawn).registered.isEmpty,
            "断言1：物件被收回（isEnabled = false）后不再被认成屏幕")

        // 名字不像电视的一件普通家具：**不靠名字**也不许被认领成屏幕。
        var renamed = room
        renamed[Fixture.tvObjectID] = Fixture.tv(displayName: "客厅摆件")
        expect(Fixture.snapshot(renamed).registered.isEmpty,
            "断言1：名字里没有「电视 / 屏幕」时不再靠名字认领（尺寸判据说了算）")

        // =========================================================
        // 断言 2：注册**不依赖覆盖层**（`live` 拿不到 store 时照样说得清）
        // =========================================================
        let relay = WorldScreenControlRelay(
            live: { nil }, registered: { Fixture.snapshot(room) }
        )
        expect(relay.hasLiveOverlay == false, "断言2：夹具里覆盖层**没有**接上（正是真机那一轮）")

        let screens = relay.listScreens()
        expect(screens.count == 1 && screens[0].displayName == "超大荧幕电视",
            "断言2：覆盖层没接上时 `listScreens()` 照样说得出是哪一台（实测 \(screens.map(\.displayName))）")

        let unavailable = await relay.playScreen(
            objectID: nil, rawContent: "https://www.bilibili.com/video/BV1xx411c7mD"
        )
        expect(unavailable.code == .screenSurfaceUnavailable && unavailable.code.isError,
            "断言2：放不了时是**具名失败**（实测 \(unavailable.code.rawValue)）")
        expect(unavailable.message.contains("超大荧幕电视"),
            "断言2：说得出是哪一件（\(unavailable.message)）")
        expect(unavailable.message.contains("先打开一次空间窗口"),
            "断言2：说得出怎么改（\(unavailable.message)）")
        expect(!unavailable.message.contains("没有能把视频投到屏幕上"),
            "断言2：不许退回那句「我没有能力」（\(unavailable.message)）")

        // 三条工具**在覆盖层没接上时照样在**：control 是无条件构造出来的转发器。
        let tools = ResidentScreenTools(control: relay, isCurrent: { true }).tools
        expect(tools.map(\.name) == ["play_screen", "stop_screen", "read_screen"],
            "断言2：三条工具无条件存在（实测 \(tools.map(\.name))）")

        // 覆盖层**接上了**时，转发器把每一条都交给它（不是自己另判一遍）。
        let live = StubLiveControl()
        live.screens = screens
        let liveRelay = WorldScreenControlRelay(
            live: { live }, registered: { Fixture.snapshot(room) }
        )
        expect(liveRelay.hasLiveOverlay, "断言2：接上覆盖层后 `hasLiveOverlay` 为真")
        _ = await liveRelay.playScreen(objectID: nil, rawContent: "BV1xx411c7mD")
        expect(live.asked == 1, "断言2：接上覆盖层后 `play_screen` 真的交给了 store（不是自己答）")

        // =========================================================
        // 断言 3：**有屏幕才说能播**（一件都没注册时不许夸口）
        // =========================================================
        let emptyRelay = WorldScreenControlRelay(
            live: { nil }, registered: { .empty }
        )
        let emptyTools = ResidentScreenTools(control: emptyRelay, isCurrent: { true }).tools
        expect(emptyTools.count == 3,
            "断言3：一件屏幕都没有时，三条工具**仍然在清单里**（清单靠接线，不靠屏幕）")

        let emptyRead = emptyTools.first { $0.name == "read_screen" }!
        let emptyReadReply = await emptyRead.handle("c1", Data("{}".utf8))
        let emptyReadPayload = (try? JSONSerialization.jsonObject(with: emptyReadReply.payloadJSON))
            as? [String: Any] ?? [:]
        expect((emptyReadPayload["screens"] as? String) == "0" && !emptyReadReply.isError,
            "断言3：`read_screen` 如实说「一块屏幕都没有」（不是失败通道）")

        let emptyPlay = emptyTools.first { $0.name == "play_screen" }!
        let emptyPlayReply = await emptyPlay.handle(
            "c2", Data(#"{"url":"https://www.bilibili.com/video/BV1xx411c7mD"}"#.utf8)
        )
        expect(emptyPlayReply.isError && emptyPlayReply.code == "screen_not_found",
            "断言3：一件都没注册时 `play_screen` 说「没有电视」，绝不说「已经放起来了」（实测 \(emptyPlayReply.code)）")

        // 有屏幕的那一支：`read_screen` 必须读得到它。
        let readTool = tools.first { $0.name == "read_screen" }!
        let readReply = await readTool.handle("c3", Data("{}".utf8))
        let readPayload = (try? JSONSerialization.jsonObject(with: readReply.payloadJSON))
            as? [String: Any] ?? [:]
        let readScreens = readPayload["screens"] as? [[String: Any]] ?? []
        expect(!readReply.isError && readScreens.count == 1
                && (readScreens.first?["screen_id"] as? String) == Fixture.tvObjectID,
            "断言3：`read_screen` 读得到那台电视（实测 \(readScreens.count) 块）")

        if failuresTotal > 0 { exit(1) }
    }
}
"""##

// ---------------------------------------------------------------------------
// MARK: 现编现跑
// ---------------------------------------------------------------------------

/// 把源码切进临时目录、现编现跑，返回 (编译是否成功, 退出码)。
func compileAndRun(
    patch: (String, String) -> String = { _, text in text }
) throws -> (compiled: Bool, status: Int32) {
    let directory = temporary.appendingPathComponent("run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // 生产源码里的 `import WorldRuntime` 由替身顶上。
    var metadata = productionMetadata
        .replacingOccurrences(of: "import WorldRuntime\n", with: "")
    metadata = patch("WorldScreenMetadata.swift", metadata)

    var tools = productionTools
    tools = patch("ResidentScreenTools.swift", tools)

    let localMetadata = directory.appendingPathComponent("WorldScreenMetadata.swift")
    try metadata.write(to: localMetadata, atomically: true, encoding: .utf8)
    let localTools = directory.appendingPathComponent("ResidentScreenTools.swift")
    try tools.write(to: localTools, atomically: true, encoding: .utf8)

    // 这一份只要 `ResidentScreenTools.swift` 能编起来：几何/推断（判据本身）、
    // 内容与状态两个类型的产地。它们都只依赖 Foundation ——
    // **不用手写替身顶生产类型**（替身会让判据与真实形状脱钩）。
    let support = ["WorldScreenGeometry.swift", "WorldScreenInference.swift",
                   "WorldScreenContent.swift", "WorldScreenState.swift"]
    var sources = support.map { screenRoot.appendingPathComponent($0).path }
    sources.append(localMetadata.path)
    sources.append(localTools.path)

    let program = directory.appendingPathComponent("main.swift")
    try (innerPrelude).write(to: program, atomically: true, encoding: .utf8)

    let executable = directory.appendingPathComponent("test")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
    process.arguments = ["-j1", "-parse-as-library"] + sources + [program.path, "-o", executable.path]
    let pipe = Pipe()
    process.standardError = pipe
    process.standardOutput = pipe
    try process.run()
    let captured = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        for line in String(decoding: captured, as: UTF8.self).split(separator: "\n").prefix(25) {
            print("   · [内层编译] \(line)")
        }
        return (false, -1)
    }
    let run = Process()
    run.executableURL = executable
    let runPipe = Pipe()
    run.standardError = runPipe
    run.standardOutput = runPipe
    try run.run()
    let output = runPipe.fileHandleForReading.readDataToEndOfFile()
    run.waitUntilExit()
    for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
        // `SCREEN-CAPABILITY` 是**证据行**（物件描述里那一行的原文），不是判据 ——
        // 一并透出来，否则"功能点真的注册到物件上"只剩一句断言、看不到原文。
        if line.hasPrefix("PASS") || line.hasPrefix("FAIL") || line.hasPrefix("SCREEN-CAPABILITY") {
            print("  · \(line)")
        }
    }
    return (true, run.terminationStatus)
}

// ---------------------------------------------------------------------------
// MARK: 主线
// ---------------------------------------------------------------------------

let pristine = try compileAndRun()
check(pristine.compiled, "内层程序带着生产源码编译通过")
check(pristine.compiled && pristine.status == 0,
    "屏幕功能点注册 + 转发器判据（物件真的有屏幕 ⇒ 注册；不像屏幕的一件都不许说成能播；覆盖层没接上照样说得清）—— 实测退出码 \(pristine.status)")

// ---------------------------------------------------------------------------
// MARK: 注入负对照（只在临时副本上做手术）
// ---------------------------------------------------------------------------

/// 一条注入：在**源码副本**上做一处或多处手术，主判据必须红。
///
/// 手术打偏（needle 一处都没命中）会让副本等于原件 ⇒ 判据"不红" ⇒ 调用方报 FAIL。
/// 这条纪律是必需的：一个悄悄没生效的负对照等于没有负对照。
struct Injection {
    let name: String
    let target: String
    /// 逐条 (needle, replacement)。**每一条都必须命中**。
    let surgeries: [(String, String)]
    let reason: String

    func apply(to text: String) -> (text: String, applied: Int, missed: Int) {
        var result = text
        var applied = 0
        var missed = 0
        for (needle, replacement) in surgeries {
            if result.contains(needle) {
                result = result.replacingOccurrences(of: needle, with: replacement)
                applied += 1
            } else {
                missed += 1
            }
        }
        return (result, applied, missed)
    }
}

let injections: [Injection] = [
    Injection(
        name: "drop-registration",
        target: "WorldScreenMetadata.swift",
        surgeries: [(
            "guard case let .success(definition) = resolution else { continue }",
            "guard case let .success(definition) = resolution, false else { continue }"
        )],
        reason: "屏幕功能点**不注册**到物件上（回执里读不到「它有屏幕」）"
    ),
    Injection(
        name: "claim-every-object",
        target: "WorldScreenMetadata.swift",
        surgeries: [
            // 入场那一关放开（任何物件都去解析）…
            ("guard calibratedJSON != nil", "guard true || calibratedJSON != nil"),
            // …并且解析时无条件允许"缺省一台通用电视" ⇒ 不像屏幕的也会被认成屏幕。
            ("size: size(state), allowsDefault: nameLike",
             "size: size(state), allowsDefault: true"),
        ],
        reason: "不管物件上有没有屏幕功能点都宣称能播（夸口）"
    ),
    Injection(
        name: "unconditional-claim",
        target: "ResidentScreenTools.swift",
        surgeries: [(
            "return registered().registered.map(\\.snapshot)",
            "return registered().registered.isEmpty ? [WorldScreenSnapshot(objectID: \"编的\", displayName: \"编的电视\", source: .inferred, note: \"编的出处\", aspect: 1, geometryIssue: nil, contentURL: nil, stateText: \"已经放起来了。\", isPlaying: true)] : registered().registered.map(\\.snapshot)"
        )],
        reason: "没有注册也照样宣称有一台电视在放（夸口）"
    ),
    Injection(
        name: "raw-tool-reply",
        target: "ResidentScreenTools.swift",
        surgeries: [(
            "guard let live = live() else { return surfaceUnavailable(objectID: objectID) }",
            "guard let live = live() else { return .failure(.screenNotFound, \"我做不到。\") }"
        )],
        reason: "放不了时退回一句笼统的「我做不到」（不退具名 + 可行动）"
    ),
]

// 手术必须先**打中**：needle 一处都没命中 = 这个负对照根本没做，判它"红"是假证据。
for injection in injections {
    let targetText = injection.target == "WorldScreenMetadata.swift"
        ? productionMetadata : productionTools
    for (needle, _) in injection.surgeries {
        check(targetText.contains(needle),
            "注入负对照「\(injection.name)」的 needle 在生产源码里存在")
    }
}

for injection in injections {
    let outcome = try compileAndRun { file, text in
        guard file == injection.target else { return text }
        let result = injection.apply(to: text)
        if result.missed > 0 {
            print("   · [注入没打中] \(injection.name)：\(result.missed) 处 needle 一处都没命中")
        }
        return result.text
    }
    if !outcome.compiled {
        check(false, "注入负对照「\(injection.name)」的源码副本没编过（手术打偏了）")
        continue
    }
    check(outcome.status != 0,
        "注入负对照「\(injection.name)」（\(injection.reason)）⇒ 判据必须红（实测退出码 \(outcome.status)）")
}

print(failureCount == 0
    ? "PASS 屏幕功能点注册判据全部通过"
    : "FAIL 屏幕功能点注册判据有 \(failureCount) 条不通过")
exit(failureCount == 0 ? 0 : 1)
