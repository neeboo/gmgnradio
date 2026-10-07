// 尺寸意图（`size_intent`）的端到端行为检查。
//
// 这一轮修的是**提交前就说清楚「哪根轴、多少米」**，而不是事后靠界面自动缩放：
// 真机那把剑（2026-10-01「2B 白色长剑（外形摆件）」）按高度归一成了 8.28 m，
// 比 7 × 8 × 3.2 m 的舱室还长 ⇒ 被摆放判定拒绝、退回库存、从房间里消失。
//
// 这里跑的是**真的**那几份实现：真的 `ResidentWishMachineTools`、真的
// `WishMachineCoordinator`、真的 `PropGenerationStore`、真的 `PropTaskDaemonClient`
// —— 对面是一个鉴权 HTTP / SSE 的 Python 替身，它把收到的 `submit` 参数**原样记下来**，
// 于是「线上到底发了什么」可以逐字节断言（而不是读源码猜）。
//
// 每一条断言都对应一种「悄悄变坏」的方式：
//   1. 用户说「一把 1.1 米的剑」⇒ 线上必须是 {axis:longest, meters:1.1, source:user}；
//   2. 「高 35 厘米的咖啡机」⇒ {axis:height, meters:0.35}，而且 height_meters 就是同一个数；
//   3. 旧调用（只给 height_meters）⇒ 线上**根本没有** sizeIntent 这个键（逐字节兼容）；
//   4. 非法/缺失/猜出来的尺寸 ⇒ 可读拒绝，而且**一个提交都没有发出去**；
//   5. 任务的尺寸出处可读（任务行/回执），而且与记录的意图同源。
import Foundation

// WorldRuntime 的模块搜索路径与目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
// harness 一律调用它，绝不自己拼 `.build/...`（27 份各自拼写正是 SwiftPM 模块与 xcodebuild
// `Products/Debug` 旧模块两份并存的根因，后者报 `WorldQuaternion` 没有 `identity`）。
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
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let required = ["Presence/PropGenerationClient.swift", "Presence/PropGenerationStore.swift",
                "Presence/PropImagePreparation.swift", "Presence/PropTaskDaemonClient.swift", "Presence/TaskdHTTPTransport.swift",
                "Presence/WishMachineOutputDescriptor.swift", "Presence/WishMachineTaskPresentation.swift",
                // 任务行那一句委托给唯一投影（`OwnershipSentence` 是唯一出口），一起编。
                "Presence/ResidentOwnershipProjection.swift",
                "Presence/WishMachineCoordinator.swift", "Agent/WishMachineContract.swift",
                "Agent/ResidentWishMachineTools.swift",
                // 统一退避的**唯一**定义：`WishMachineCoordinator` 自动确认那一处读
                // `RetryBackoffSite.generationConfirmation` / `RetryJitter`，所以真源码必须
                // 跟着编（编的是跑在 App 里的那一份，不在 harness 里抄一套策略）。
                "Presence/RetryBackoff.swift"]
guard required.allSatisfy({ FileManager.default.fileExists(atPath: sources.appendingPathComponent($0).path) }) else {
    print("FAIL: size-intent sources are missing"); exit(1)
}

// ── 源码级断言：只有 GPU 才能跑到的分支（托盘渲染）与线上编码，用「编同一份源码」来钉 ──
func sourceContains(_ path: String, _ needles: [String], _ message: String) -> Bool {
    guard let text = try? String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8) else {
        print("FAIL: cannot read \(path)"); return false
    }
    guard needles.allSatisfy(text.contains) else {
        print("FAIL: \(message)（缺 \(needles.filter { !text.contains($0) })）"); return false
    }
    return true
}
// 托盘上那件还没登记：有意图就按用户的轴归一，没有才走今天的自动推断。
guard sourceContains("Presence/WishMachineOutputRenderer.swift",
    ["WorldPropSizePolicy.intended(", "intent.axis.policyAxis", "WorldPropSizePolicy.automatic("],
    "许愿机托盘没有按尺寸意图归一（那把剑会照旧被算成 8.28 m）") else { exit(1) }
// 托盘描述符必须带上意图（否则渲染端拿不到「用户说的哪根轴」）。
guard sourceContains("Presence/WishMachineCoordinator.swift",
    ["heightIsGenerationRequest: true, sizeIntent: job.sizeIntent"],
    "托盘描述符没有把尺寸意图带下去") else { exit(1) }
// 线上编码：意图就是契约那三个键，nil 时整块不发。
guard sourceContains("Presence/PropTaskDaemonClient.swift",
    ["sizeIntent: sizeIntent", "let sizeIntent: PropSizeIntent?"],
    "提交没有把尺寸意图编码到线上") else { exit(1) }
// 旧字段与意图的**唯一**判据在同一处：三态判据（可以提交 / 信息不足 / 畸形）与
// 结构化回执共用它，所以不可能各说一套。
guard sourceContains("Agent/ResidentWishMachineTools.swift",
    ["WishMachineContract", "func sizeIntentVerdict", "enum SizeIntentVerdict", "needsInput", "resolveDraft"],
    "许愿工具没有把参数收敛到唯一真相（WishMachineContract）与结构化信息不足上") else { exit(1) }
// 三轴形状必须在工具面与只读契约上都能说出来（否则用户给的 1443 x 862 x 302 mm 又会丢两维）。
guard sourceContains("Agent/ResidentWishMachineTools.swift",
    ["PropSizeIntent.dimensionsModeValue", "\"millimeters\"", "sizeIntentSource"],
    "提交工具没有暴露三轴形状（mode=dimensions + millimeters）") else { exit(1) }
guard sourceContains("Agent/WishMachineContract.swift",
    ["dimensionEdges", "min_millimeters", "dimensionOrderNote"],
    "只读契约没有公布三轴形状与轴序（x 宽 / y 高 / z 深）") else { exit(1) }
// 生成入库：意图优先于自动推断，而且落进世界状态的那一份尺寸就是按它算的。
guard sourceContains("App/GMGNRadioApp.swift",
    ["WorldPropSizePolicy.intended(", "sizeIntent: sizeIntent"],
    "生成入库没有把尺寸意图落成世界尺寸（那把剑仍会按高度被算成 8.28 m）") else { exit(1) }

// ── 断言 6：生成**永远是作者路径**；几何拼必须由**用户**选（2026-10-02 产品规则）────
//
// 真机 2026-10-01「平面电视」：用户发了一张平面电视的产品图、给了 `1443 × 862 × 302 mm`，
// 生成器交回来的是**一个大立方体**。当时那条"三轴 + 板形 ⇒ 直接用基础几何拼"的支路
// **静默**把生成结果换掉了 —— 用户那张参考图（外观、贴图、细节）**一次都没被用上**。
// 用户 2026-10-02 的反对原话：「**不行啊，这样用户就没办法自定义外观了啊**」。
//
// 所以这条门禁要抓的是**两个方向**，而且判据一条都不许放宽：
//   · **生成是默认路径**：生成网格那条路必须真的走得到（外观 / 贴图 / 细节都来自那张素材）；
//   · **几何拼只由用户开门**：`job.appearanceChoice == .primitiveTelevision`（走
//     `build_primitive_television` 工具，形状上就要求 `confirm=true`），拼出来的仍是
//     **正常物件**（同一个 `WorldGeneratedProp`、同一条登记路径），板形判据一个字不改；
//   · **不许静默替换**：生成结果不是板形时，「生成器把它做成了方块」+ **两个选择**
//     （①换张图重做，②用几何拼）必须说得出来。
//
// 判据是**接线本身**（文本级），因为类型级判据可以全绿而 App 侧一个构造点都没有：
// 编译得进、跑不起来。每一条都配**注入负对照** —— 在源码副本上做手术，判据必须变红；
// 一个从不 FAIL 的门禁等于没有门禁。
let appSourcePath = "App/GMGNRadioApp.swift"
guard let appSourceText = readSource(appSourcePath) else {
    print("FAIL: 读不到 \(appSourcePath)"); exit(1)
}

/// 「生成是默认路径 + 几何拼由用户开门」这条接线在不在。空数组 = 接线完整。
func primitiveTelevisionWiringProblems(_ app: String) -> [String] {
    var problems: [String] = []
    // ① 真的调了基础几何那条入口（`WorldPrimitiveTelevision(millimeters:)`）。
    if !app.contains("WorldPrimitiveTelevision(millimeters: spec)") {
        problems.append("① 入库这一处没有构造 `WorldPrimitiveTelevision(millimeters:)`："
            + "用户说的 1443 × 862 × 302 还是只会落成一个生成网格")
    }
    // ② 门是**三轴形状**，不是"只要有尺寸意图"（一根轴/最长边那条路不许被改成走几何）。
    if !app.contains("intent.mode == .dimensions") {
        problems.append("② 没有按 `mode == .dimensions` 区分形状：三轴与单轴会走同一条路")
    }
    // ③ 板形判据必须是**既有那一份**（`WorldScreenFaceInference.rejection`：板形 + 最大面面积），
    //    不许在这里另写一套"最薄轴 ≤ 最长轴 1/4"。
    if !app.contains("WorldScreenFaceInference.rejection(size: meters, objectID: job.objectID) == nil") {
        problems.append("③ 没有用既有的板形判据（`WorldScreenFaceInference.rejection`）："
            + "方块柜子会被当成电视去拼")
    }
    // ④ 三根轴必须**进世界状态 metadata**（`primitive: television.record`），面板才回读得出。
    if !app.contains("primitive: television.record") {
        problems.append("④ 三轴没有随物件落进世界状态（缺 `primitive: television.record`）："
            + "面板回读不出 1443 × 862 × 302")
    }
    // ⑤ 资产字节必须走内容寻址那一个 put（同一个住处、同一种命名、同一种引用形式）。
    if !app.contains("materializeContentAddressedAsset(television)") {
        problems.append("⑤ 基础几何的资产字节没有走内容寻址的 put")
    }
    // ⑥ 拼出来的几何与**渲染端量出来**的包围盒必须逐位相同（画面/判据/碰撞盒只有一份尺寸），
    //    不相等要可见拒绝，绝不画一台尺寸不对的电视。三根轴一根都不能少。
    for axis in ["x", "y", "z"] where !app.contains("abs(measured.\(axis) - television.size.\(axis))") {
        problems.append("⑥ 没有校验「渲染端量出来的包围盒就是拼出来的那一份」的 \(axis) 轴")
    }
    // ⑦ **生成结果照旧入库**（作者路径）：生成网格那条路必须真的走得到 —— 它的字节、它的
    //    `assetID`（就是**那份网格**的 sha256）都在。几何拼**不是**默认替代，所以下面这条
    //    断言与 ⑧ 一起把"生成被用上"和"几何拼由用户开门"两件事钉死。
    if !app.contains("let url = URL(fileURLWithPath: path)") {
        problems.append("⑦ 生成网格那条路不见了：外观、贴图、细节都来自它（作者路径）")
    }
    if !app.contains("assetID: \"sha256:\" + hash.lowercased()") {
        problems.append("⑦ 生成产物的资产引用不再是那份网格的字节：素材的贴图与细节会丢")
    }
    // ⑦b 「生成器把它做成了方块」+ **两个选择**必须说得出来（人话，唯一一份文案在
    //     `Presence/ResidentPropTelevisionRepair.swift`；App 这一处只管调用它）。
    if !app.contains(".shapeChoiceNotice(name: job.name, millimeters: millimeters)") {
        problems.append("⑦b 生成结果不是板形时没有把「生成器把它做成了方块 + 两个选择」说给用户："
            + "那就成了一次静默的观感缺陷（用户只看到「它没照我说的做」）")
    }
    // ⑦c 反向也要说：用户**选过**几何拼、可那三个数本身拼不出板形物件时，
    //     不许静默落回生成网格（一次明确的选择"点了没反应"比不做更坏）。
    if !app.contains(".geometryUnavailableNotice(name: job.name, millimeters: millimeters)") {
        problems.append("⑦c 用户选了用几何拼、但那三个数拼不出来时没有可见说明"
            + "（会静默落回生成网格 —— 用户会以为「点了没反应」）")
    }
    // ⑧ 几何拼那一支的**门 = 用户的那一次选择**（`guard job.appearanceChoice ==
    //    .primitiveTelevision,`），而且它排在生成网格那条路**之前**、自己收场（`continue`）。
    //    这道门就是本轮要修的那件事：没有它，三轴 + 板形就会**静默**把生成结果换掉。
    guard let gate = app.range(of: "guard job.appearanceChoice == .primitiveTelevision,") else {
        problems.append("⑧ 几何拼没有「用户选过」这道门：三轴 + 板形会**静默**替换掉生成结果 ——"
            + "用户那张素材白给了（用户原话「这样用户就没办法自定义外观了啊」）")
        return problems
    }
    guard let primitiveBranch = app.range(of: "if let television = primitiveTelevision {") else {
        problems.append("⑧ 找不到几何拼那一支（`if let television = primitiveTelevision {`）："
            + "用户选过这条路也没人拼")
        return problems
    }
    if gate.lowerBound > primitiveBranch.lowerBound {
        problems.append("⑧ 门在拼几何那一支**之后**：等于没门（先拼出来再问用户）")
    }
    guard let meshPath = app.range(of: "let url = URL(fileURLWithPath: path)") else {
        problems.append("⑧ 找不到既有那条生成网格的落点")
        return problems
    }
    if primitiveBranch.lowerBound > meshPath.lowerBound {
        problems.append("⑧ 几何拼那一支排在生成网格那条路**之后**：先按网格算出尺寸再拼几何，"
            + "两份尺寸都会落盘")
    }
    if !app[primitiveBranch.upperBound...].contains("continue") {
        problems.append("⑧ 几何拼那一支没有收场（缺 `continue`）：会继续按生成网格再算一遍")
    }
    // ⑨ 两件东西的**入库是同一条路**：同一个类型、同一条登记路径（两条路都是正常物件）。
    if !app.contains("residentOwnedPropAssets[job.objectID] = ResidentOwnedPropAsset(") {
        problems.append("⑨ 几何拼那一支没有走既有的资产记录：它会不是一件「正常物件」"
            + "（摆放 / 承托 / 碰撞 / 删除 / 入库都读不到它）")
    }
    return problems
}

/// 注入负对照：把源码副本改成**已知会坏**的样子，判据必须变红。
/// 每一条都对应一种真实的"悄悄退化"。
let primitiveWiringInjections: [(name: String, old: String, new: String)] = [
    // 本轮要拆掉的那条形状：把"用户选过"这道门去掉 ⇒ 三轴 + 板形又变成**静默替换**。
    ("silent-auto-replacement",
     "guard job.appearanceChoice == .primitiveTelevision,",
     ""),
    // 三轴与单轴不分：一根轴的意图也会被拿去拼几何（咖啡机会变成一台电视）。
    ("intent-shape-not-checked",
     "guard let intent = job.sizeIntent, intent.mode == .dimensions,",
     "guard let intent = job.sizeIntent,"),
    // 丢掉既有的板形判据：方块柜子也去拼电视。
    ("drop-panel-criterion",
     "return WorldScreenFaceInference.rejection(size: meters, objectID: job.objectID) == nil\n                        ? television : nil",
     "return television"),
    // 三轴不进世界状态：面板回读不出三个数（只有最长边）。
    ("drop-primitive-record",
     "sizeLocked: true, primitive: television.record)",
     "sizeLocked: true)"),
    // 资产字节不走内容寻址：`assetID` 与文件对不上，删除那条引用也释放不掉。
    ("drop-content-addressed-put",
     "let blobURL = try Self.materializeContentAddressedAsset(television)",
     "let blobURL = URL(fileURLWithPath: path)"),
    // 不做"量出来的就是拼出来的"这一校：画出来的尺寸可以与判据/碰撞盒分叉。
    ("drop-measured-match",
     "abs(measured.x - television.size.x) <= 0.002,",
     "true,"),
    // 不说"生成器把它做成了方块" + 两个选择：用户只看到"它没照我说的做"。
    ("drop-shape-choice-notice",
     ".shapeChoiceNotice(name: job.name, millimeters: millimeters)",
     ".shapeChoiceNoticeDisabled(name: job.name, millimeters: millimeters)"),
    // 用户选了几何拼、但那三个数拼不出来时不说 ⇒ 静默落回生成网格（"点了没反应"）。
    ("silent-when-unbuildable",
     ".geometryUnavailableNotice(name: job.name, millimeters: millimeters)",
     ".geometryUnavailableNoticeDisabled(name: job.name, millimeters: millimeters)"),
    // 几何拼那一支不走既有资产记录：它不是一件正常物件了。
    ("geometry-not-a-normal-object",
     "residentOwnedPropAssets[job.objectID] = ResidentOwnedPropAsset(",
     "residentOwnedPropAssets[job.objectID] = nil; _ = ResidentOwnedPropAsset("),
]

// 现场演示：`SIZE_INTENT_INJECT=silent-auto-replacement swift tools/test-resident-prop-size-intent.swift`
// 会把**真源码**当成"没有用户那道门、三轴就静默换掉生成结果"的那一份来判，于是主判据自己打出一条 FAIL。
var observedAppSource = appSourceText
if let name = ProcessInfo.processInfo.environment["SIZE_INTENT_INJECT"],
   let injection = primitiveWiringInjections.first(where: { $0.name == name }) {
    print("·· SIZE_INTENT_INJECT=\(name)：把真源码当成被注入过的那一份来判")
    guard observedAppSource.contains(injection.old) else {
        print("FAIL: 注入锚点在真源码里找不到：\(injection.old)"); exit(1)
    }
    observedAppSource = observedAppSource.replacingOccurrences(of: injection.old, with: injection.new)
}

// 2026-10-02 产品决定（用户原话「不能再用集合拼了」）：手拼几何**已停用** —— 产品路径零调用，
// 也不再给用户"重新生成 / 用几何拼"两条路。下面这一节钉的是**已废止**的产品规则
// （"三轴 + 板形 ⇒ 基础几何"与"几何拼由用户开门"）：只要 App 里再出现手拼几何的构造点，
// 它就**立刻重新生效**（原来那些断言一条都没删、也没放宽）。
//
// 同一条产品规则的**反面**由 `tools/test-generation-only-props.swift` 钉着：
// App 零构造点 / 零选项文案 + 三轴逐轴兑现（世界 size 逐位 1.443 × 0.862 × 0.302）+ 五条注入负对照。
let primitiveProductRuleRetired = !appSourceText.contains("WorldPrimitiveTelevision(")
if primitiveProductRuleRetired {
    print("PASS: 手拼几何已停用（2026-10-02 产品决定）—— 本节判据改由 tools/test-generation-only-props.swift 承接")
}
let primitiveWiringIssues = primitiveProductRuleRetired
    ? [] : primitiveTelevisionWiringProblems(observedAppSource)
for issue in primitiveWiringIssues { print("FAIL: \(issue)") }
guard primitiveWiringIssues.isEmpty else {
    print("FAIL: 生成不是默认路径 / 几何拼不是由用户选的（判据见上）"); exit(1)
}
if !primitiveProductRuleRetired {
    print("PASS: 生成是默认路径（作者路径照旧入库），几何拼只在用户选过时走，判据一个字没放宽")
}

if !primitiveProductRuleRetired {
for injection in primitiveWiringInjections {
    var injected = appSourceText
    guard injected.contains(injection.old) else {
        print("FAIL: 注入负对照「\(injection.name)」的锚点在源码里找不到：\(injection.old)"); exit(1)
    }
    injected = injected.replacingOccurrences(of: injection.old, with: injection.new)
    guard injected != appSourceText else {
        print("FAIL: 注入负对照「\(injection.name)」没有改到源码副本"); exit(1)
    }
    let issues = primitiveTelevisionWiringProblems(injected)
    guard !issues.isEmpty else {
        print("FAIL: 注入负对照「\(injection.name)」（\(injection.new)）⇒ 判据必须变红，它却全绿")
        exit(1)
    }
    print("PASS: 注入负对照「\(injection.name)」⇒ 判据变红（\(issues[0])）")
}
}

// ── 断言 7：「生成器没做对」那两句话**逐字**在这里（唯一一份文案）────────────────
//
// 人话一句 + **两个选择**：(a) 换张图重做（**给出建议**：正面、无背景、单件产品更容易出
// 扁平面板），(b) 用几何拼一台标准电视（**尺寸按你说的三个数**）。文案是**纯函数**，
// 唯一来源是 `Presence/ResidentPropTelevisionRepair.swift` —— 面板、任务行、agent 回执
// 读的都是它（不另写一套），所以这里逐字扫它。
let repairCopyPath = "Presence/ResidentPropTelevisionRepair.swift"
// 2026-10-02 产品决定：手拼几何停用 ⇒ 这份文案也**整体停用**（文件已清空，只留一行说明）。
// 所以本节**不再读它、也不再断言它** —— 这正是"引用改成不再需要它"。手拼几何一旦被接回
// 产品路径（下面那道 `primitiveProductRuleRetired` 门失效），本节立刻按原样重新生效：
// 原来那些断言一条都没删、也没放宽。
if !primitiveProductRuleRetired {
guard let repairCopyText = readSource(repairCopyPath) else {
    print("FAIL: 读不到 \(repairCopyPath)"); exit(1)
}

/// 文案里的违规项。空数组 = 两个选择都说清楚了。
func televisionRepairCopyProblems(_ copy: String) -> [String] {
    var problems: [String] = []
    // ① 一句人话：**生成器把它做成了方块**（说的是形状，不是"逐轴比例相差 N 倍"这种读数）。
    if !copy.contains("生成器把「\\(name)」做成了方块，不像一块扁平面板。") {
        problems.append("① 没有那句人话（`生成器把「…」做成了方块`）：用户看到的就只是"
            + "「它没照我说的做」，没人告诉他生成器交回来的是什么")
    }
    // ② 选择 (a)：重新生成，而且**给出建议**（正面、无背景、单件产品）。
    if !copy.contains("①换张图重做") {
        problems.append("② 没有选择 (a)（换张图重做）：用户没有第一条路可走")
    }
    if !copy.contains("正面、单件、无背景的图更容易出扁平面板") {
        problems.append("② 选择 (a) 没给建议：用户不知道「换一张什么样的图」才容易出扁平面板")
    }
    // ③ 选择 (b)：用几何拼，而且**尺寸按用户说的三个数**（原话逐位回读，不是近似值）。
    if !copy.contains("②对我说「拼一台标准电视」") {
        problems.append("③ 没有选择 (b)（用几何拼一台标准电视）：用户没法自己把这件换掉")
    }
    if !copy.contains("我用几何按你说的 \\(axes) 毫米拼一台") {
        problems.append("③ 选择 (b) 没有把**用户原话的三个数**写进去：拼出来会是另一样的尺寸")
    }
    // ④ 拼不出来时**也要说**（绝不静默落回生成网格）。
    if !copy.contains("你选了用几何拼，但你给的") || !copy.contains("所以我**没有**拼") {
        problems.append("④ 用户选了几何拼、但那三个数拼不出板形物件时没有可见说明"
            + "（会静默落回生成网格）")
    }
    return problems
}

/// 注入负对照：每一条都对应"这句话没说"的一种真实退化。
let televisionRepairCopyInjections: [(name: String, old: String, new: String)] = [
    ("drop-plain-sentence",
     "生成器把「\\(name)」做成了方块，不像一块扁平面板。",
     "形状不太对。"),
    ("drop-regenerate-advice",
     "正面、单件、无背景的图更容易出扁平面板",
     "换一张图"),
    ("drop-geometry-option",
     "②对我说「拼一台标准电视」",
     "②换个办法"),
    ("drop-geometry-dimensions",
     "我用几何按你说的 \\(axes) 毫米拼一台",
     "我用几何拼一台"),
    ("silent-when-unbuildable",
     "所以我**没有**拼",
     "所以就算了"),
]

let repairCopyIssues = televisionRepairCopyProblems(repairCopyText)
for issue in repairCopyIssues { print("FAIL: \(issue)") }
guard repairCopyIssues.isEmpty else {
    print("FAIL: 「生成器没做对」的两句话没有说全（判据见上）"); exit(1)
}
print("PASS: 「生成器把它做成了方块」+ 两个选择（①换张图重做并给建议 ②用几何拼、尺寸按你说的三个数）")

for injection in televisionRepairCopyInjections {
    var injected = repairCopyText
    guard injected.contains(injection.old) else {
        print("FAIL: 文案注入负对照「\(injection.name)」的锚点在源码里找不到：\(injection.old)"); exit(1)
    }
    injected = injected.replacingOccurrences(of: injection.old, with: injection.new)
    guard injected != repairCopyText else {
        print("FAIL: 文案注入负对照「\(injection.name)」没有改到源码副本"); exit(1)
    }
    let issues = televisionRepairCopyProblems(injected)
    guard !issues.isEmpty else {
        print("FAIL: 文案注入负对照「\(injection.name)」（\(injection.new)）⇒ 判据必须变红，它却全绿")
        exit(1)
    }
    print("PASS: 文案注入负对照「\(injection.name)」⇒ 判据变红（\(issues[0])）")
}
} else {
    print("PASS: 「生成器没做对」那两句话已随产品决定停用（文案判据见 tools/test-generation-only-props.swift）")
}


// ── 断言 8：三轴意图的**米数换算**与"尺寸无效"的字段级原因 ────────────────────
//
// 上面那条钉的是几何（拼出来的 == 声明出来的 == 量出来的）；这一条钉的是**意图那本账**：
// 毫米 → 米的换算（真机 2026-10-02「超大荧幕电视」的根因）以及"是哪一条判据不成立"
// 必须说得出来（用户原话只有一句"许愿机产物的尺寸无效"，字段与数字一个都没有）。
//
// 判据仍是接线本身（文本级）+ 注入负对照：一个从不 FAIL 的门禁等于没有门禁。
func dimensionAccountingProblems(client: String, descriptor: String, renderer: String,
                                 resident: String) -> [String] {
    var problems: [String] = []
    // ① 毫米 → 米：少一层括号就是 `edges.max() ?? (0 / 1000)`，1443 mm 会被当成 1443 米。
    if !client.contains("var longestMeters: Double { (edges.max() ?? 0) / 1000 }") {
        problems.append("① 三轴意图的 `longestMeters` 不是「(最长边) / 1000」："
            + "1443 mm 会被当成 1443 米 ⇒ 托盘归一失败（现场那句「尺寸无效」）")
    }
    // ② 托盘归一失败必须说得出**哪个字段、什么数值**，而且不许退回裸抛。
    if !renderer.contains("field: basisField, value: basisMeters") {
        problems.append("② 托盘归一失败的拒绝没有字段与实测数值（用户只看到一句「尺寸无效」）")
    }
    if renderer.contains("guard let resolution else { throw WishMachineOutputError.invalidDimensions }") {
        problems.append("② 托盘归一失败又回到了裸抛（判据塌成一句话）")
    }
    // ③ 尺寸判据的**唯一**出口必须带字段级原因，而且用户看得见那一句。
    if !descriptor.contains("case invalidDimensions(WishMachineDimensionRejection)") {
        problems.append("③ `WishMachineOutputError.invalidDimensions` 不带字段级原因")
    }
    if !descriptor.contains("许愿机产物的尺寸无效：\\(rejection.summary)") {
        problems.append("③ 「尺寸无效」那一句没有把字段与数值拼进去（用户读不出是哪一条）")
    }
    // ④ 已登记物件那条（摆正后高度为零）也要说得出来。
    if !resident.contains("field: \"sourceHeight（摆正后网格的高度）\"") {
        problems.append("④ 已登记物件的尺寸拒绝没有字段与数值")
    }
    return problems
}

/// 注入负对照：每一条都对应一种真实的"悄悄退化"。
let dimensionAccountingInjections: [(name: String, file: String, old: String, new: String)] = [
    // 现场缺陷本身：少一层括号 ⇒ 毫米当米。
    ("millimeters-as-meters", "client",
     "var longestMeters: Double { (edges.max() ?? 0) / 1000 }",
     "var longestMeters: Double { edges.max() ?? 0 / 1000 }"),
    // 只留一句话：字段与数值又没了（这正是用户截图里那一行）。
    ("one-sentence-dimension-failure", "descriptor",
     "\"许愿机产物的尺寸无效：\\(rejection.summary)。暂时无法显示。\"",
     "\"许愿机产物的尺寸无效，暂时无法显示。\""),
    // 托盘那条又变回不说数字。
    ("bare-tray-dimension-throw", "renderer",
     "field: basisField, value: basisMeters,",
     "field: \"尺寸\", value: 0,"),
]

func readAccountingSources() -> [String: String] {
    var result: [String: String] = [:]
    let files = ["client": "Presence/PropGenerationClient.swift",
                 "descriptor": "Presence/WishMachineOutputDescriptor.swift",
                 "renderer": "Presence/WishMachineOutputRenderer.swift",
                 "resident": "Presence/ResidentPropRenderer.swift"]
    for (key, path) in files {
        guard let text = try? String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8) else {
            print("FAIL: 读不到 \(path)"); exit(1)
        }
        result[key] = text
    }
    return result
}
func dimensionAccountingIssues(_ files: [String: String]) -> [String] {
    dimensionAccountingProblems(client: files["client"] ?? "", descriptor: files["descriptor"] ?? "",
                                renderer: files["renderer"] ?? "", resident: files["resident"] ?? "")
}

let accountingFiles = readAccountingSources()
// 现场演示：`SIZE_INTENT_INJECT=millimeters-as-meters swift tools/test-resident-prop-size-intent.swift`
// 会把**真源码**当成"毫米当米"的那一份来判，于是主判据自己打出一条 FAIL。
var observedAccountingFiles = accountingFiles
if let name = ProcessInfo.processInfo.environment["SIZE_INTENT_INJECT"],
   let injection = dimensionAccountingInjections.first(where: { $0.name == name }) {
    print("·· SIZE_INTENT_INJECT=\(name)：把真源码当成被注入过的那一份来判")
    guard let text = observedAccountingFiles[injection.file], text.contains(injection.old) else {
        print("FAIL: 注入锚点在真源码里找不到：\(injection.old)"); exit(1)
    }
    observedAccountingFiles[injection.file] = text.replacingOccurrences(of: injection.old, with: injection.new)
}
let accountingIssues = dimensionAccountingIssues(observedAccountingFiles)
for issue in accountingIssues { print("FAIL: \(issue)") }
guard accountingIssues.isEmpty else {
    print("FAIL: 三轴意图的米数换算 / 尺寸拒绝的字段级原因不成立（判据见上）"); exit(1)
}
print("PASS: 三轴意图按毫米 → 米换算，尺寸无效类失败带字段与数值（字段 + 实测值 + 期望）")

for injection in dimensionAccountingInjections {
    guard let text = accountingFiles[injection.file], text.contains(injection.old) else {
        print("FAIL: 注入负对照「\(injection.name)」的锚点在源码里找不到：\(injection.old)"); exit(1)
    }
    var injected = accountingFiles
    injected[injection.file] = text.replacingOccurrences(of: injection.old, with: injection.new)
    guard injected[injection.file] != text else {
        print("FAIL: 注入负对照「\(injection.name)」没有改到源码副本"); exit(1)
    }
    let issues = dimensionAccountingIssues(injected)
    guard !issues.isEmpty else {
        print("FAIL: 注入负对照「\(injection.name)」（\(injection.new)）⇒ 判据必须变红，它却全绿")
        exit(1)
    }
    print("PASS: 注入负对照「\(injection.name)」⇒ 判据变红（\(issues[0])）")
}

// ── 断言 10：**三个数就是三个数**（逐轴）+「渲染与碰撞读同一组尺寸」+ 判据未放宽 ─────
//
// 用户 2026-10-02 的现场原话（连续两条）：「我都给了尺寸了为什么不能按照尺寸出」/「你改契约啊」。
// 旧契约按**最长边等比**归一、另外两维只写进 `reason` 当"期望值" ⇒ 给了三个数，场景里只有
// 最长边那一维兑现 —— 这就是用户抱怨的实质。这一节钉的是新契约的**接线**（行为判据在下面
// 编译出来的那个程序里跑，用的是真机那份网格的逐顶点实测 AABB）：
//
//   (a) 三轴意图逐轴兑现（`Resolution(size: target, …)`），越界**具名拒绝**而不是静默夹取；
//   (b) 渲染端读的**就是**世界里那一份 `effectiveSize`，并按 `size[i] / 网格跨度[i]` 逐轴缩放；
//   (c) 碰撞 / 承托 / 摆放判据读**同一份** `effectiveSize`（尺寸只有一个出口）；
//   (d) 单轴 `axis=longest` 那一档**一字不动**（只给一个数时等比到那个数）；
//   (e) 范围与形状冲突校验**一条都没放宽**。
//
// 每条都配**注入负对照**：在源码副本上做手术，判据必须变红 —— 一个从不 FAIL 的门禁等于没有门禁。
let worldRuntimeSources = root.appendingPathComponent(
    "apps/macos/Packages/WorldRuntime/Sources/WorldRuntime")
// **先挡一条假绿**：下面的行为判据链接的是 SwiftPM 预编译的 `WorldRuntime` 目标文件
// （`tools/world-runtime-harness-flags.sh` 那一份，唯一一处定义）。它们比源文件旧 ⇒ 行为判据
// 测的是**旧语义**，会绿得毫无意义（"给了三个数却只兑现最长边"在新旧语义下都可能绿）。
// 判据看的是**真正被链进去的那些 `.o`**，不是 `.swiftmodule`：公开接口没变时它不会被重写。
let threeAxisFlags = worldRuntimeHarnessFlags()
let threeAxisObjectDates = threeAxisFlags.filter { $0.hasSuffix(".o") }.compactMap {
    (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date
}
let threeAxisSourceDate = (try? FileManager.default.attributesOfItem(
    atPath: worldRuntimeSources.appendingPathComponent("WorldPropSizePolicy.swift").path)[.modificationDate]) as? Date
if let threeAxisSourceDate, let newest = threeAxisObjectDates.max(), threeAxisSourceDate > newest {
    print("FAIL: SwiftPM 的 WorldRuntime 目标文件比源文件旧（三轴的行为判据会测旧语义）："
        + "先跑 swift build --package-path apps/macos/Packages/WorldRuntime")
    exit(1)
}
func readRuntimeSource(_ name: String) -> String? {
    try? String(contentsOf: worldRuntimeSources.appendingPathComponent(name), encoding: .utf8)
}

/// 三轴契约的接线违规项。空数组 = 接线完整。
func threeAxisContractProblems(app: String, descriptor: String, renderer: String,
                               placement: String, editor: String, policy: String,
                               tools: String, contract: String,
                               tray: String = "", coordinator: String = "",
                               attachment: String = "") -> [String] {
    var problems: [String] = []
    // (a) 契约语义：三轴那一份**就是**用户给的三个数。
    if !policy.contains("return Resolution(size: target, scales: scales, basis: .dimensions") {
        problems.append("(a) 三轴意图没有逐轴兑现（找不到 "
            + "`Resolution(size: target, scales: scales, basis: .dimensions)`）：另外两维又只是期望值了")
    }
    if policy.contains("三轴尺寸按最长边等比归一") {
        problems.append("(a) 三轴意图又回到「按最长边等比归一」：给了三个数只有一维兑现")
    }
    if !policy.contains("guard longest.isFinite, longest >= minimumExtentMeters, longest <= maximumExtentMeters else {") {
        problems.append("(a2) 三轴那一份没有上下限判据："
            + "「三个数就是三个数」要求越界**具名拒绝**，不许静默夹取")
    }
    // (b) 渲染端：描述符带三轴目标，矩阵有逐轴那一支，而且调用点给的就是 `effectiveSize`。
    if !descriptor.contains("var targetSizeMeters: WorldVector3? = nil") {
        problems.append("(b) 渲染描述符没有三轴目标（`targetSizeMeters`）：渲染端只能继续等比")
    }
    if !descriptor.contains("let scales = perAxis ?? SIMD3<Float>(repeating: scale)") {
        problems.append("(b) 放置矩阵没有逐轴缩放那一支：三轴意图画出来还是等比（画面与碰撞盒分叉）")
    }
    if !descriptor.contains("scaling.columns.0.x = scales.x; scaling.columns.1.y = scales.y; scaling.columns.2.z = scales.z") {
        problems.append("(b) 矩阵对角线没有用三个比例（画面按等比、判定按三轴 ⇒ 两处各推一份尺寸）")
    }
    if !renderer.contains("targetSize:item.targetSizeMeters") {
        problems.append("(b) 渲染端实际绘制那一行没有把三轴目标传进矩阵（会按等比画）")
    }
    // 已摆那一件与手持那一件**都要**共用世界里那一份 `effectiveSize`（两处，缺一不可）。
    let targetSizeWiring = app.components(separatedBy: "targetSizeMeters: prop.effectiveSize)").count - 1
    if targetSizeWiring != 2 {
        problems.append("(b) 渲染端拿到的三轴尺寸不是世界里那一份（`targetSizeMeters: prop.effectiveSize` "
            + "实测 \(targetSizeWiring) 处，应为 2：已摆 + 手持）⇒ 渲染与碰撞各读一份尺寸")
    }
    // (c) 碰撞 / 承托 / 摆放 / 红绿格读的是**同一份** `effectiveSize`。
    if !placement.contains("let size = prop.effectiveSize") {
        problems.append("(c) 摆放/承托判据没有读 `prop.effectiveSize`：碰撞盒会与画面分叉")
    }
    if !placement.contains("WorldPlanarFootprint(size: SIMD2(size.x, size.z), yaw: yaw)") {
        problems.append("(c) footprint 没有按逐轴尺寸取 x/z：碰撞体积会退回一个等比盒子")
    }
    if !editor.contains("return (SIMD2(prop.effectiveSize.x, prop.effectiveSize.z), prop.effectiveSize.y)") {
        problems.append("(c) 红/绿格（编辑器判据）没有读同一份 `effectiveSize`")
    }
    // (d) 单轴那一档**一字不动**。
    if !policy.contains("case .longest:\n            return clamp(shape: shape, scale: meters / shape.longest, basis: .longestEdge)") {
        problems.append("(d) 单轴 `axis=longest` 的等比归一被改了（只给一个数时行为必须不变）")
    }
    // (e) 合法性 / 形状冲突校验**一条都没放宽**。
    if !tools.contains("guard value[\"axis\"] == nil, value[\"meters\"] == nil else {") {
        problems.append("(e) 形状冲突校验没了：同时给 axis/meters 与 mode=dimensions 会被放行")
    }
    if !tools.contains("guard number.doubleValue >= PropSizeIntent.minimumMillimeters,") {
        problems.append("(e) 三轴毫米数的范围下界没了")
    }
    if !tools.contains("number.doubleValue <= PropSizeIntent.maximumMillimeters else {") {
        problems.append("(e) 三轴毫米数的范围上界没了")
    }
    if !contract.contains("two_shapes_pick_one") {
        problems.append("(e) 只读契约不再公布「两种形状只能给一种」")
    }
    // (e2) 三轴目标落不了地时必须**可见地**说（不许当成"没有意图"静默退回单轴）。
    if !app.contains("case .unrealizable:") {
        problems.append("(e2) 三轴意图落不了地时没有可见说明（会静默退回单轴等比）")
    }
    // (f) **四条路径读同一份尺寸**：预览 / 已摆 / 手持 走 `ResidentPropRenderDescriptor.targetSizeMeters`
    //     （世界里那一份 `effectiveSize`），托盘走 `WishMachineOutputRenderer` 里**同一个裁决**
    //     `dimensionsVerdict`。任何一条退回等比 ⇒ 画出来的是网格自己的形状：真机那台电视的网格是
    //     个 1.0079 × 0.6287 × 1.0079 的方盒子，等比之后就是 1.3815 × 0.862 × 1.3815 的**厚方块**
    //     （进深与宽度同量级）——正是用户 2026-10-02 说的「厚度不对啊」。
    if !renderer.contains("targetSizeMeters: held.targetSizeMeters") {
        problems.append("(f) 手持那一件没有把三轴目标带进渲染描述符"
            + "（找不到 `targetSizeMeters: held.targetSizeMeters`）⇒ 手里退回等比厚方块")
    }
    if !attachment.contains("let scaleValues = perAxis.map {") {
        problems.append("(f) 手持的缩放只剩一份等比（找不到 `let scaleValues = perAxis.map {`）"
            + "⇒ 地上的电视是薄板、手里那块又变回厚方块")
    }
    if !tray.contains("case let .exact(exact) = WorldPropSizePolicy.dimensionsVerdict(") {
        problems.append("(f) 托盘预览没有读**同一个裁决** `dimensionsVerdict`：三个数会只剩最长边")
    }
    if !tray.contains("resolvedSize = exact.size") {
        problems.append("(f) 托盘预览没把裁决出来的三个数记下来（找不到 `resolvedSize = exact.size`）")
    }
    if !tray.contains("targetHeight: resolvedHeight, targetSize: resolvedSize, outlet: outlet") {
        problems.append("(f) 托盘放置矩阵没有拿到三轴目标"
            + "（找不到 `targetHeight: resolvedHeight, targetSize: resolvedSize, outlet: outlet`）⇒ 托盘按等比画")
    }
    if !coordinator.contains("heightIsGenerationRequest: true, sizeIntent: job.sizeIntent") {
        problems.append("(f) 托盘描述符没有把尺寸意图带下去（找不到 "
            + "`heightIsGenerationRequest: true, sizeIntent: job.sizeIntent`）")
    }
    // (f2) 托盘与已摆共用**同一份**逐轴实现（`WishMachineOutputPlacement.transform`）：那一条主线
    //      在，三轴才可能在两条路上都成立。它被关掉 ⇒ 托盘只剩等比。
    if !descriptor.contains("if let targetSize, WorldPropSizePolicy.uniformFactor(from: extent, to: targetSize) == nil {") {
        problems.append("(f2) `WishMachineOutputPlacement.transform` 的逐轴分支没了：托盘会按等比画")
    }
    return problems
}

/// 注入负对照：每一条都对应一种真实的"悄悄退化"。
let threeAxisContractInjections: [(name: String, file: String, old: String, new: String)] = [
    // (a) 只取最长边那一维 —— 用户抱怨的那件事本身。
    ("longest-edge-only", "policy",
     "return Resolution(size: target, scales: scales, basis: .dimensions",
     "return Resolution(size: WorldVector3(x: target.x, y: target.x, z: target.x), scales: scales, basis: .dimensions"),
    // (a2) 夹取回来（静默改数字 = 你给的不是你要的）。
    ("clamp-instead-of-refuse", "policy",
     "guard longest.isFinite, longest >= minimumExtentMeters, longest <= maximumExtentMeters else {",
     "guard longest.isFinite else {"),
    // (b) 渲染端继续按**等比**画：画面与碰撞盒当场分叉（旧理由的形状）。
    ("render-still-uniform", "descriptor",
     "let scales = perAxis ?? SIMD3<Float>(repeating: scale)",
     "let scales = SIMD3<Float>(repeating: scale)"),
    // (b) 渲染端不再拿世界里那一份尺寸（各推一份）。
    ("render-recomputes-size", "app",
     "targetSizeMeters: prop.effectiveSize)",
     "targetSizeMeters: nil)"),
    // (c) 碰撞 / 承托不再读同一份 `effectiveSize`（退回按高度等比）。
    ("collision-uniform", "placement",
     "let size = prop.effectiveSize",
     "let size = WorldVector3(x: prop.effectiveSize.y, y: prop.effectiveSize.y, z: prop.effectiveSize.y)"),
    // (d) 单轴那一档被改：只给一个数时不再等比到那个数。
    ("longest-axis-changed", "policy",
     "case .longest:\n            return clamp(shape: shape, scale: meters / shape.longest, basis: .longestEdge)",
     "case .longest:\n            return clamp(shape: shape, scale: meters / shape.height, basis: .height)"),
    // (e) 放宽形状冲突：两种形状同时给也放行。
    ("loosen-shape-conflict", "tools",
     "guard value[\"axis\"] == nil, value[\"meters\"] == nil else {",
     "guard true else {"),
    // (e) 放宽三轴毫米数的范围。
    ("loosen-millimeter-range", "tools",
     "guard number.doubleValue >= PropSizeIntent.minimumMillimeters,\n                      number.doubleValue <= PropSizeIntent.maximumMillimeters else {",
     "guard number.doubleValue.isFinite else {"),
    // (e2) 三轴落不了地时不说了（静默退回单轴）。
    ("silent-unrealizable", "app",
     "case .unrealizable:",
     "case .unrealizableDisabled:"),
    // (f) 托盘预览退回**等比**：那一整条逐轴分支被关掉 ⇒ 用户看到的就是网格自己的厚方块。
    ("tray-uniform", "descriptor",
     "if let targetSize, WorldPropSizePolicy.uniformFactor(from: extent, to: targetSize) == nil {",
     "if let targetSize, perAxisDisabled {"),
    // (f) 托盘不再把裁决出来的三个数交给放置矩阵（各推一份尺寸）。
    ("tray-drops-size", "tray",
     "targetHeight: resolvedHeight, targetSize: resolvedSize, outlet: outlet",
     "targetHeight: resolvedHeight, targetSize: nil, outlet: outlet"),
    // (f) 手持那一件不再带三轴目标（地上是三轴、手里退回等比）。
    ("held-drops-size", "renderer",
     "targetSizeMeters: held.targetSizeMeters",
     "targetSizeMeters: nil"),
    // (f) 手持的缩放退回一份等比（`scaleValues` 不再逐轴）。
    ("held-scale-uniform", "attachment",
     "let scaleValues = perAxis.map {",
     "let scaleValues = Optional<SIMD3<Float>>.none.map {"),
]

func readThreeAxisContractSources() -> [String: String] {
    var result: [String: String] = [:]
    let appFiles = ["app": "App/GMGNRadioApp.swift",
                    "descriptor": "Presence/WishMachineOutputDescriptor.swift",
                    "renderer": "Presence/ResidentPropRenderer.swift",
                    // 手持那一件的**逐轴缩放**那一行（`PropAttachmentMatrix.transform`）。
                    "attachment": "Presence/PropAttachment.swift",
                    // 托盘那一条路：`WishMachineOutputRenderer`（画）+ `WishMachineCoordinator`（造描述符）。
                    "tray": "Presence/WishMachineOutputRenderer.swift",
                    "coordinator": "Presence/WishMachineCoordinator.swift",
                    "placement": "Presence/ResidentPropPlacementService.swift",
                    "editor": "Presence/ResidentPropEditorState.swift",
                    "tools": "Agent/ResidentWishMachineTools.swift",
                    "contract": "Agent/WishMachineContract.swift"]
    for (key, path) in appFiles {
        guard let text = readSource(path) else {
            print("FAIL: 读不到 \(path)"); exit(1)
        }
        result[key] = text
    }
    guard let policy = readRuntimeSource("WorldPropSizePolicy.swift") else {
        print("FAIL: 读不到 WorldRuntime/WorldPropSizePolicy.swift"); exit(1)
    }
    result["policy"] = policy
    return result
}
func threeAxisContractIssues(_ files: [String: String]) -> [String] {
    threeAxisContractProblems(app: files["app"] ?? "", descriptor: files["descriptor"] ?? "",
                              renderer: files["renderer"] ?? "", placement: files["placement"] ?? "",
                              editor: files["editor"] ?? "", policy: files["policy"] ?? "",
                              tools: files["tools"] ?? "", contract: files["contract"] ?? "",
                              tray: files["tray"] ?? "", coordinator: files["coordinator"] ?? "",
                              attachment: files["attachment"] ?? "")
}

let threeAxisFiles = readThreeAxisContractSources()
// 现场演示：`SIZE_INTENT_INJECT=longest-edge-only swift tools/test-resident-prop-size-intent.swift`
// 会把**真源码**当成"三轴只取最长边"的那一份来判，于是主判据自己打出一条 FAIL。
var observedThreeAxisFiles = threeAxisFiles
if let name = ProcessInfo.processInfo.environment["SIZE_INTENT_INJECT"],
   let injection = threeAxisContractInjections.first(where: { $0.name == name }) {
    print("·· SIZE_INTENT_INJECT=\(name)：把真源码当成被注入过的那一份来判")
    guard let text = observedThreeAxisFiles[injection.file], text.contains(injection.old) else {
        print("FAIL: 注入锚点在真源码里找不到：\(injection.old)"); exit(1)
    }
    observedThreeAxisFiles[injection.file] = text.replacingOccurrences(of: injection.old, with: injection.new)
}
let threeAxisIssues = threeAxisContractIssues(observedThreeAxisFiles)
for issue in threeAxisIssues { print("FAIL: \(issue)") }
guard threeAxisIssues.isEmpty else {
    print("FAIL: 三轴契约的接线不成立（三个数必须逐轴兑现，渲染与碰撞必须读同一组尺寸；判据见上）")
    exit(1)
}
print("PASS: 三个数就是三个数（逐轴兑现）；渲染与碰撞/承托/红绿格读同一份 `effectiveSize`；"
    + "单轴 `axis=longest` 一字未动；范围与形状冲突校验一条未放宽")

for injection in threeAxisContractInjections {
    guard let text = threeAxisFiles[injection.file], text.contains(injection.old) else {
        print("FAIL: 注入负对照「\(injection.name)」的锚点在源码里找不到：\(injection.old)"); exit(1)
    }
    var injected = threeAxisFiles
    injected[injection.file] = text.replacingOccurrences(of: injection.old, with: injection.new)
    guard injected[injection.file] != text else {
        print("FAIL: 注入负对照「\(injection.name)」没有改到源码副本"); exit(1)
    }
    let issues = threeAxisContractIssues(injected)
    guard !issues.isEmpty else {
        print("FAIL: 注入负对照「\(injection.name)」（\(injection.new)）⇒ 判据必须变红，它却全绿")
        exit(1)
    }
    print("PASS: 注入负对照「\(injection.name)」⇒ 判据变红（\(issues[0])）")
}

// ── 断言 2：参数与规则**只有一处**定义 ──────────────────────────────────────
// 唯一允许写这些事实的文件是 Agent/WishMachineContract.swift（agent 用只读工具
// `read_wish_machine_contract` 现读）。工具文件与系统提示里再存一份就是旧病复发：
// 三处各一份，改到两份等于没改 —— 真机那把剑就是这么被算成 8.28 m 的。
let parameterFacts = ["axis=longest", "axis=height", "\"longest\"", "\"height\"",
                      "0.01", "先问一句", "不要自己猜", "不要默认按高度"]
func leakedFacts(in text: String) -> [String] { parameterFacts.filter(text.contains) }
func readSource(_ path: String) -> String? {
    try? String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
}
/// 取一个声明的完整正文（括号配对）：断言只钉**那一段**，不在整份大文件上碰运气。
func declarationBody(_ text: String, _ signature: String) -> String? {
    guard let start = text.range(of: signature)?.lowerBound,
          let open = text[start...].firstIndex(of: "{") else { return nil }
    var depth = 0
    for index in text[open...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    return nil
}
guard let contractSource = readSource("Agent/WishMachineContract.swift") else {
    print("FAIL: 读不到唯一真相文件 Agent/WishMachineContract.swift"); exit(1)
}
// 唯一真相**必须**真的说得出这些事实（否则"只有一处"变成了"一处都没有"）。
guard leakedFacts(in: contractSource).count >= 3 else {
    print("FAIL: WishMachineContract 里没有轴名/范围/例子这些参数事实（实测 \(leakedFacts(in: contractSource))）")
    exit(1)
}
guard let toolSource = readSource("Agent/ResidentWishMachineTools.swift") else {
    print("FAIL: 读不到 Agent/ResidentWishMachineTools.swift"); exit(1)
}
guard leakedFacts(in: toolSource).isEmpty else {
    print("FAIL: 工具 schema/文案里**又**存了一份尺寸参数 \(leakedFacts(in: toolSource))：参数只允许在 WishMachineContract 一处")
    exit(1)
}
guard toolSource.contains("WishMachineContract.pointer") else {
    print("FAIL: 工具说明没有指向唯一真相接口（应引用 WishMachineContract.pointer）"); exit(1)
}
guard let appSource = readSource("App/GMGNRadioApp.swift"),
      let prompt = declarationBody(appSource, "private func wishMachinePromptContext(") else {
    print("FAIL: 找不到 wishMachinePromptContext"); exit(1)
}
guard leakedFacts(in: prompt).isEmpty else {
    print("FAIL: 系统提示里**又**存了一份尺寸参数 \(leakedFacts(in: prompt))：参数只允许在 WishMachineContract 一处")
    exit(1)
}
// 提示词里出现的必须是**指针**（运行时才展开成那句唯一的说明），不是又抄一份参数。
guard prompt.contains("WishMachineContract.pointer") else {
    print("FAIL: 系统提示没有引用唯一真相的指针（WishMachineContract.pointer）"); exit(1)
}
// 只读接口名只允许在唯一真相里定义一次（本脚本独立编译，所以比对字面量）。
guard contractSource.contains("static let toolName = \"read_wish_machine_contract\"") else {
    print("FAIL: 唯一真相没有定义只读接口名 read_wish_machine_contract"); exit(1)
}

let fixture = #"""
import http.server,threading,json,os,sys,uuid,time
root,path=sys.argv[1:]
token=str(uuid.uuid4())
lock=threading.RLock();jobs={}
def send(c,value):
 try:
  payload=json.dumps(value).encode()
  if c.path=='/events':
   c.send_response(200);c.send_header('Content-Type','text/event-stream');c.end_headers()
   c.wfile.write(b'data: '+payload+b'\n\n');c.wfile.flush()
   while True:
    time.sleep(.2);c.wfile.write(b': heartbeat\n\n');c.wfile.flush()
  else:
   c.send_response(200);c.send_header('Content-Type','application/json');c.send_header('Content-Length',str(len(payload)));c.end_headers()
   c.wfile.write(payload)
 except OSError: pass
def record(params):
 with open(root+'/submits.jsonl','a') as f: f.write(json.dumps(params,sort_keys=True)+'\n')
def handle(c,q):
 p=q['params'];m=q['method']
 if m=='configure': r={'configured':True}
 elif m=='snapshot': r={'jobs':[dict(j) for j in jobs.values()],'sequence':len(jobs)}
 elif m=='subscribe': r={'subscribed':True}
 elif m=='submit':
  record(p)
  # 与 Rust `store.submit` 一致：有意图才编码这个键，没有就**整个键都不出现**。
  j={'id':p['id'],'name':p['name'],'endpoint':p['endpoint'],'imagePath':root+'/image.png','imageSHA256':'a'*64,
     'heightMeters':p['heightMeters'],'source':p['source'],'idempotencyKey':p['id'],
     'backendStage':'queued','cancelRequested':False}
  if p.get('sizeIntent') is not None: j['sizeIntent']=p['sizeIntent']
  if p.get('context') is not None: j['context']=p['context']
  jobs[j['id']]=j;r={'job':j}
 else:
  send(c,{'id':q['id'],'error':{'code':'unknown','message':'unsupported'}});return
 send(c,{'id':q['id'],'result':r})
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  assert self.headers.get('Authorization')=='Bearer '+token
  assert self.path=='/health'
  payload=json.dumps({'version':2,'transport':'http'}).encode()
  self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(payload)));self.end_headers()
  self.wfile.write(payload)
 def do_POST(self):
  assert self.headers.get('Authorization')=='Bearer '+token
  assert self.headers.get('Content-Type')=='application/json'
  assert self.path in ('/rpc','/events')
  q=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  handle(self,q)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
with open(path,'w') as f:
 json.dump({'version':2,'address':'127.0.0.1:'+str(server.server_port),'token':token},f)
os.chmod(path,0o600)
server.serve_forever()
"""#

let program = #"""
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd
import WorldRuntime

/// 从**资产字节**里独立量一次包围盒（逐顶点；与渲染端 loader 的 `worldBounds` 同一件事）。
///
/// 它是"渲染端量出来的那一份"这条断言里**独立**的一腿：不读 `WorldPrimitiveTelevision.size`，
/// 只读那串字节，所以"拼出来的 == 声明出来的 == 量出来的"不是同一份数据自证。
enum PrimitiveGLBBounds {
    static func measure(_ data: Data) -> (minimum: SIMD3<Float>, maximum: SIMD3<Float>)? {
        let bytes = [UInt8](data)
        guard bytes.count > 20, String(decoding: bytes[0..<4], as: UTF8.self) == "glTF" else { return nil }
        func u32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        var offset = 12
        var document: [String: Any]?
        var binary: [UInt8]?
        while offset + 8 <= bytes.count {
            let length = u32(offset), kind = u32(offset + 4)
            offset += 8
            guard length >= 0, offset + length <= bytes.count else { return nil }
            let chunk = Array(bytes[offset..<(offset + length)])
            if kind == 0x4E4F_534A { document = try? JSONSerialization.jsonObject(with: Data(chunk)) as? [String: Any] }
            if kind == 0x004E_4942 { binary = chunk }
            offset += length
        }
        guard let document, let bin = binary,
              let accessors = document["accessors"] as? [[String: Any]],
              let bufferViews = document["bufferViews"] as? [[String: Any]],
              let meshes = document["meshes"] as? [[String: Any]] else { return nil }
        var minimum = SIMD3<Float>(repeating: .infinity)
        var maximum = SIMD3<Float>(repeating: -Float.infinity)
        var found = false
        for mesh in meshes {
            for primitive in (mesh["primitives"] as? [[String: Any]]) ?? [] {
                guard let attributes = primitive["attributes"] as? [String: Any],
                      let index = attributes["POSITION"] as? Int, index < accessors.count else { continue }
                let accessor = accessors[index]
                guard accessor["componentType"] as? Int == 5126, accessor["type"] as? String == "VEC3",
                      let count = accessor["count"] as? Int,
                      let viewIndex = accessor["bufferView"] as? Int, viewIndex < bufferViews.count else { continue }
                let view = bufferViews[viewIndex]
                let start = (view["byteOffset"] as? Int ?? 0) + (accessor["byteOffset"] as? Int ?? 0)
                let stride = view["byteStride"] as? Int ?? 12
                for vertex in 0..<count {
                    let base = start + vertex * stride
                    guard base + 12 <= bin.count else { return nil }
                    func float(_ at: Int) -> Float {
                        Float(bitPattern: UInt32(bin[at]) | UInt32(bin[at + 1]) << 8
                              | UInt32(bin[at + 2]) << 16 | UInt32(bin[at + 3]) << 24)
                    }
                    let point = SIMD3<Float>(float(base), float(base + 4), float(base + 8))
                    minimum = simd_min(minimum, point); maximum = simd_max(maximum, point)
                    found = true
                }
            }
        }
        return found ? (minimum, maximum) : nil
    }
}

struct ResidentImageAttachment: Identifiable, Codable, Sendable, Equatable { let id: UUID; let url: URL; let displayName: String }
struct RealtimeDJToolResult { let callID: String; let resultJSON: Data; let isError: Bool }
@MainActor final class ResidentWorldToolSession {
    struct AdditionalTool {
        let name: String; let description: String; let inputSchema: [String: Any]
        let validate: @MainActor ([String: Any]) -> Bool
        let handle: @MainActor (String, Data) async -> RealtimeDJToolResult
    }
}

@main struct Checks {
 @MainActor static func main() async throws {
  var checks = 0, failures: [String] = []
  func check(_ value: Bool, _ label: String) { if value { checks += 1 } else { failures.append(label) } }
  func until(_ label: String, _ predicate: @MainActor () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(6)
      while !predicate() {
          guard Date() < deadline else { failures.append("timeout: " + label); return }
          try await Task.sleep(for: .milliseconds(20))
      }
  }
  func readSubmits(_ root: URL) -> [[String: Any]] {
      guard let text = try? String(contentsOf: root.appendingPathComponent("submits.jsonl"), encoding: .utf8) else { return [] }
      return text.split(separator: "\n").compactMap { line in
          (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
      }
  }
  func parse(_ result: RealtimeDJToolResult) -> [String: Any] {
      (try? JSONSerialization.jsonObject(with: result.resultJSON)) as? [String: Any] ?? [:]
  }
  // 下标越界不许把整份 harness 崩掉：崩在 finish() 之前，累积的 FAIL 一条都印不出来。
  func submitRow(_ index: Int) -> [String: Any] {
      let rows = readSubmits(scratch)
      return index >= 0 && index < rows.count ? rows[index] : [:]
  }
  func arguments(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

  let scratch = URL(fileURLWithPath: "/tmp/gmgn-size-intent-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let endpoint = scratch.appendingPathComponent("taskd.endpoint.json")
  let server = Process()
  server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  server.arguments = ["-u", "-c", try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8), scratch.path, endpoint.path]
  server.standardOutput = FileHandle.nullDevice
  server.standardError = FileHandle.nullDevice
  try server.run()
  func finish() -> Never {
      server.terminate(); server.waitUntilExit()
      try? FileManager.default.removeItem(at: scratch)
      for failure in failures { print("FAIL: " + failure) }
      guard failures.isEmpty else { exit(1) }
      print("PASS: \(checks) size-intent checks")
      exit(0)
  }
  try await until("fixture HTTP endpoint") { FileManager.default.fileExists(atPath: endpoint.path) }

  // 一张真的 2×2 PNG：`PropImagePreparation` 与守护进程契约都只认真 PNG。
  let pixels = Data(repeating: 255, count: 16)
  let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  let imageURL = scratch.appendingPathComponent("input.png")
  let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, nil)
  check(CGImageDestinationFinalize(destination), "fixture PNG")

  let daemon = PropTaskDaemonClient(root: scratch, endpointFileURL: endpoint, allowsLaunching: false, requestTimeout: 2)
  let store = PropGenerationStore(directory: scratch, daemonClient: daemon)
  try store.configure(endpoint: URL(string: "http://127.0.0.1:8765")!, token: "fixture-secret-only-memory")

  let world = "size-world", resident = "size-resident"
  let coordinator = WishMachineCoordinator(store: store, directory: scratch.appendingPathComponent("wishes"), canClaim: { _ in nil })
  var grant = UUID()
  var attachment = ResidentImageAttachment(id: UUID(), url: imageURL, displayName: "reference.png")
  // 一次人类委托只生成一件：每件物件用自己的授权，否则第二件会被判成超用授权。
  func freshGrant() throws {
      grant = UUID()
      attachment = ResidentImageAttachment(id: UUID(), url: imageURL, displayName: "reference.png")
      try coordinator.authorize(attachments: [attachment], worldID: world, residentScope: resident,
          authorizationID: grant, source: .init(author: "user", license: "internal"))
  }
  func submitTool(capability: WishSizeIntentCapability = .unreadable) -> ResidentWorldToolSession.AdditionalTool {
      ResidentWishMachineTools(coordinator: coordinator, worldID: world, residentScope: resident,
          authorizationID: grant, isCurrent: { true },
          sizeIntentCapability: { capability }).tools.first { $0.name == "submit_wish_generation" }!
  }
  func contractTool(capability: WishSizeIntentCapability = .unreadable) -> ResidentWorldToolSession.AdditionalTool {
      ResidentWishMachineTools(coordinator: coordinator, worldID: world, residentScope: resident,
          authorizationID: grant, isCurrent: { true },
          sizeIntentCapability: { capability },
          serviceFacts: { (true, "fixture") }).tools.first { $0.name == "read_wish_machine_contract" }!
  }
  try freshGrant()
  let submit = submitTool()

  // ── 工具的参数契约：形状对 + **指向唯一真相**，不再自带第二份参数 ──────────
  let schema = submit.inputSchema
  let properties = schema["properties"] as? [String: Any] ?? [:]
  let intentSchema = properties["size_intent"] as? [String: Any] ?? [:]
  let intentProperties = intentSchema["properties"] as? [String: Any] ?? [:]
  check(properties["size_intent"] != nil, "提交工具的 schema 必须带尺寸意图参数")
  check(intentProperties["axis"] != nil && intentProperties["meters"] != nil,
      "尺寸意图必须说得出轴与米数")
  // 三轴形状必须在 schema 里：用户给「1443 x 862 x 302 mm」时 agent 要有地方**照实填**，
  // 否则它只能挑一根轴上报，另外两维就地丢掉（真机那台电视就是这么变成大立方体的）。
  check(intentProperties["mode"] != nil && intentProperties["millimeters"] != nil,
      "尺寸意图必须说得出**完整三维**（mode + millimeters）")
  let millimetersSchema = intentProperties["millimeters"] as? [String: Any] ?? [:]
  check(Set(millimetersSchema["required"] as? [String] ?? []) == ["x", "y", "z"],
      "三根轴必须都是必需的（缺一维不许有默认值，实测 \(String(describing: millimetersSchema["required"]))）")
  let requiredArguments = Set(schema["required"] as? [String] ?? [])
  check(requiredArguments == ["attachment_id", "name"],
      "尺寸是二选一，不能把旧字段列成必需（实测 \(requiredArguments.sorted())）")
  // 参数事实只能在唯一真相里：schema 自己不许再写轴枚举、轴名、米数范围。
  let ownFacts = ["axis=longest", "axis=height", "\"longest\"", "\"height\"", "0.01"]
  let schemaText = String(decoding: (try? JSONSerialization.data(withJSONObject: schema)) ?? Data(), as: UTF8.self)
      + submit.description
  check(ownFacts.filter { schemaText.contains($0) }.isEmpty,
      "工具 schema/说明里**又**存了一份尺寸参数 \(ownFacts.filter { schemaText.contains($0) })");
  check(schemaText.contains("read_wish_machine_contract"),
      "工具说明必须把 agent 指向唯一真相接口（实测缺 read_wish_machine_contract）")
  // size_intent 内部不许把 axis/meters 列成必需：否则"缺轴"会被 schema 拦成笼统错误，
  // 说不出"缺什么、该问哪一句"，结构化回问就实现不了。
  check((intentSchema["required"] as? [String] ?? []).isEmpty,
      "size_intent 内部不许把 axis/meters 列成必需（缺了要能说得出缺什么）")
  check(properties["pending_id"] != nil, "提交工具必须能接住续办用的 pending_id")

  // ── 断言 1：尺寸缺失 / 轴不明确 ⇒ **结构化**信息不足 ────────────────────────
  // 不抛错（成功通道）、不发提交、不填默认值；并且给出一句问话 + 一个 pending_id。
  try freshGrant()
  let firstAuthority = grant
  let askTool = submitTool()
  let base: [String: Any] = ["attachment_id": attachment.id.uuidString, "name": "没说尺寸的剑"]
  check(askTool.validate(base), "缺尺寸必须能走到 handle（否则说不出缺什么）")
  let askResult = await askTool.handle("needs-size", arguments(base))
  let askPayload = parse(askResult)
  check(!askResult.isError, "信息不足必须是**成功**通道（实测 isError=\(askResult.isError)）")
  check(askPayload["code"] as? String == WishMachineContract.Code.needsInput.rawValue,
      "信息不足的码必须是 \(WishMachineContract.Code.needsInput.rawValue)（实测 \(String(describing: askPayload["code"]))）")
  check((askPayload["needs"] as? [String]) == ["size"],
      "必须结构化说出缺什么（实测 \(String(describing: askPayload["needs"]))）")
  check((askPayload["question"] as? String)?.isEmpty == false, "必须给出一句问用户的话")
  check(askPayload["pending_id"] is String, "必须给出续办用的 pending_id")
  check((askPayload["missing"] as? [[String: Any]])?.first?["field"] as? String == "size_intent.axis",
      "missing[].field 必须与 schema 路径逐字一致")
  check(readSubmits(scratch).isEmpty, "信息不足时一个提交都不许发出去（实测 \(readSubmits(scratch).count) 条）")
  // 拿不到 pending_id 时**报 FAIL 退出**，而不是崩在 force-unwrap 上：
  // 崩溃点看不出是哪一条契约坏了，而这条正是"信息不足必须能续办"的那一条。
  guard let pendingID = askPayload["pending_id"] as? String else {
      print("FAIL: 信息不足回执没有可用的 pending_id，无法续办（实测 \(askPayload)）"); exit(1)
  }

  // 轴不明确（给了米数没给轴）同样是信息不足，而且**不填默认轴**。
  try freshGrant()
  let axisAsk = await submitTool().handle("needs-axis",
      arguments(base.merging(["size_intent": ["meters": 0.8] as [String: Any]]) { _, new in new }))
  let axisPayload = parse(axisAsk)
  check(!axisAsk.isError, "缺轴必须是成功通道的信息不足（实测 \(axisPayload)）")
  check((axisPayload["needs"] as? [String]) == ["size_axis"],
      "缺轴必须说缺轴（实测 \(String(describing: axisPayload["needs"]))）")
  check(readSubmits(scratch).isEmpty, "缺轴时一个提交都不许发出去")
  guard let axisPendingID = axisPayload["pending_id"] as? String else {
      print("FAIL: 缺轴的答复没有可用的 pending_id（实测 \(axisPayload)）"); exit(1)
  }

  // ── 断言 4：用户回答后**续上同一次委托**（幂等、不重复生成、不消耗新授权）────
  // 回答发生在**新的一轮**：宿主会开一份新授权。续办必须用草稿里的**原**授权与原
  // requestID，否则就是另一次委托。
  try freshGrant()
  let answerAuthority = grant
  check(answerAuthority != firstAuthority, "第二轮必须真的换了一份授权（否则这条断言没有意义）")
  // 原样回填**草稿**里的 attachment_id/name —— 回答的这一轮换了新授权，本轮附件编号
  // 与原委托不是一回事；回执里的 draft 就是给这个用的。
  let draftEcho = askPayload["draft"] as? [String: Any] ?? [:]
  check(draftEcho["attachment_id"] as? String == base["attachment_id"] as? String,
      "信息不足回执必须原样带回原委托的 attachment_id（实测 \(draftEcho)）")
  let resumeArgs: [String: Any] = ["attachment_id": draftEcho["attachment_id"] as? String ?? "",
      "name": draftEcho["name"] as? String ?? "没说尺寸的剑",
      "pending_id": pendingID, "size_intent": ["axis": "longest", "meters": 0.8] as [String: Any]]
  let resumeTool = submitTool()
  check(resumeTool.validate(resumeArgs), "续办参数必须放行")
  let resumeResult = await resumeTool.handle("needs-size-answer", arguments(resumeArgs))
  let resumePayload = parse(resumeResult)
  check(!resumeResult.isError, "回答之后必须受理（实测 \(resumePayload)）")
  try await until("续办的提交落到替身") { readSubmits(scratch).count == 1 }
  let resumeAuthorization = resumePayload["authorization"] as? [String: Any] ?? [:]
  check(resumeAuthorization["reused"] as? Bool == true
      && resumeAuthorization["source"] as? String == "pending_draft",
      "续办必须复用原委托的授权（实测 \(resumeAuthorization)）")
  check(resumeAuthorization["authority_id"] as? String == firstAuthority.uuidString,
      "必须用**原来**那一份授权，而不是本轮新开的（实测 \(String(describing: resumeAuthorization["authority_id"]))）")
  check(resumeAuthorization["request_id"] as? String == "needs-size",
      "必须复用**原来**那次工具调用的编号（实测 \(String(describing: resumeAuthorization["request_id"]))）")
  let resumedJobs = coordinator.residentJobs(worldID: world, residentScope: resident)
  check(resumedJobs.count == 1, "续办之后本空间只许有**一件**产物（实测 \(resumedJobs.count) 件）")
  check(resumedJobs.first?.authorizationID == firstAuthority,
      "产物必须挂在**原来**那一份授权上（实测 \(String(describing: resumedJobs.first?.authorizationID))）")
  check(!resumedJobs.contains { $0.authorizationID == answerAuthority },
      "回答那一轮的新授权**不许**被消耗")
  check(resumedJobs.first?.requestID == "needs-size", "任务的 requestID 必须是原委托那一个")

  // 幂等：同一次委托再调一次（新的 callID，同一个 pending_id）⇒ 回同一个任务，不新建。
  let repeatResult = await resumeTool.handle("needs-size-answer-again", arguments(resumeArgs))
  let repeatPayload = parse(repeatResult)
  check(!repeatResult.isError, "重复续办必须同样受理（实测 \(repeatPayload)）")
  check((repeatPayload["wish_id"] as? String) == (resumePayload["wish_id"] as? String),
      "重复续办必须回**同一个**任务（实测 \(String(describing: repeatPayload["wish_id"])) vs \(String(describing: resumePayload["wish_id"]))）")
  check((repeatPayload["authorization"] as? [String: Any])?["replayed"] as? Bool == true,
      "重复续办必须标成幂等重放")
  try await Task.sleep(for: .milliseconds(200))
  check(readSubmits(scratch).count == 1,
      "重复续办不许产生第二次提交（实测 \(readSubmits(scratch).count) 条）")
  check(coordinator.residentJobs(worldID: world, residentScope: resident).count == 1,
      "重复续办不许长出第二件产物")

  // 说不清是哪一件（pending_id 与 name/附件对不上）⇒ fail-closed：**不猜**，
  // 结构化要求先选定，并且把候选编号列出来。
  let ambiguous = await submitTool().handle("ambiguous",
      arguments(["attachment_id": attachment.id.uuidString, "name": "另一件东西",
                 "pending_id": axisPendingID,
                 "size_intent": ["axis": "longest", "meters": 0.5] as [String: Any]]))
  let ambiguousPayload = parse(ambiguous)
  check(!ambiguous.isError && (ambiguousPayload["needs"] as? [String]) == ["pending_id"],
      "对不上号时必须先选定是哪一件，不许猜（实测 \(ambiguousPayload)）")
  check((ambiguousPayload["missing"] as? [[String: Any]])?.first?["field"] as? String == "pending_id",
      "对不上号时 missing 必须指向 pending_id（实测 \(String(describing: ambiguousPayload["missing"]))）")
  check((ambiguousPayload["options"] as? [String: Any]) != nil, "信息不足回执必须带上可用选项")

  // ── 断言 3：能力读不到 ⇒ 不声称支持；读到了说不收 ⇒ 不发提交（fail-closed）──────
  let readableContract = parse(await contractTool().handle("contract", Data("{}".utf8)))
  let unreadableCapability = readableContract["capability"] as? [String: Any] ?? [:]
  check(unreadableCapability["readable"] as? Bool == false
      && (unreadableCapability["axes"] as? [String])?.isEmpty == true
      && unreadableCapability["applies"] is NSNull,
      "能力读不到时只读接口必须明确 readable=false、axes=[]（读不到 ≠ 支持，实测 \(unreadableCapability)）")
  // 读不到能力**不影响**其它功能：合法尺寸照常提交。
  try freshGrant()
  let unreadableSubmit = await submitTool(capability: .unreadable).handle("unreadable-ok",
      arguments(["attachment_id": attachment.id.uuidString, "name": "读不到能力也要能做",
                 "size_intent": ["axis": "longest", "meters": 0.6] as [String: Any]]))
  check(!parse(unreadableSubmit).isEmpty && !unreadableSubmit.isError,
      "读不到能力不等于不能用（实测 \(parse(unreadableSubmit))）")
  try await until("读不到能力的提交落到替身") { readSubmits(scratch).count >= 2 }
  // 服务声明**只收** height：用户要 longest ⇒ 结构化信息不足，**一个提交都不发**。
  let beforeDeclared = readSubmits(scratch).count
  try freshGrant()
  let narrow = WishSizeIntentCapability.declared(axes: ["height"], minimumMeters: 0.2,
      maximumMeters: 0.8, applies: "echo")
  let unsupported = await submitTool(capability: narrow).handle("axis-not-declared",
      arguments(["attachment_id": attachment.id.uuidString, "name": "服务不收最长边",
                 "size_intent": ["axis": "longest", "meters": 0.5] as [String: Any]]))
  let unsupportedPayload = parse(unsupported)
  check(!unsupported.isError
      && unsupportedPayload["reason"] as? String == WishMachineContract.NeedReason.axisNotDeclared.rawValue
      && unsupportedPayload["unsupported_axis"] as? String == "longest"
      && (unsupportedPayload["service_declared_axes"] as? [String]) == ["height"],
      "轴不被服务声明时必须是结构化信息不足并带上服务的轴（实测 \(unsupportedPayload)）")
  // 声明范围更窄：越界同样是结构化信息不足，**不夹取**。
  let narrowRange = await submitTool(capability: narrow).handle("meters-out-of-declared-range",
      arguments(["attachment_id": attachment.id.uuidString, "name": "超出服务范围",
                 "size_intent": ["axis": "height", "meters": 1.5] as [String: Any]]))
  check(!narrowRange.isError
      && (parse(narrowRange)["reason"] as? String) == WishMachineContract.NeedReason.metersOutOfRange.rawValue,
      "超出服务声明的米数范围必须结构化信息不足（实测 \(parse(narrowRange))）")
  try await Task.sleep(for: .milliseconds(200))
  check(readSubmits(scratch).count == beforeDeclared,
      "轴/范围不被服务接受时**一个提交都不许发**（实测 \(readSubmits(scratch).count - beforeDeclared) 条新增）")

  // ── 畸形输入仍然是**错误**（不伪装成"再问一句"）────────────────────────────
  let malformed: [(String, [String: Any], String)] = [
      ("轴名非法", base.merging(["size_intent": ["axis": "width", "meters": 1.1] as [String: Any]]) { _, new in new }, "longest"),
      ("米数越界", base.merging(["size_intent": ["axis": "longest", "meters": 9] as [String: Any]]) { _, new in new }, "0.01—3"),
      ("出处是猜的", base.merging(["size_intent": ["axis": "longest", "meters": 1.1, "source": "default"] as [String: Any]]) { _, new in new }, "先问"),
      ("尺寸给了两遍", base.merging(["height_meters": 1.1, "size_intent": ["axis": "height", "meters": 1.1] as [String: Any]]) { _, new in new }, "只能给一个"),
      ("三轴与一根轴同时给",
       base.merging(["size_intent": ["mode": "dimensions",
           "millimeters": ["x": 1443, "y": 862, "z": 302] as [String: Any],
           "axis": "longest", "meters": 1.443] as [String: Any]]) { _, new in new }, "只能给一种"),
      ("三轴缺一维",
       base.merging(["size_intent": ["mode": "dimensions",
           "millimeters": ["x": 1443, "y": 862] as [String: Any]] as [String: Any]]) { _, new in new }, "三个键"),
      ("三轴越界",
       base.merging(["size_intent": ["mode": "dimensions",
           "millimeters": ["x": 1443, "y": 862, "z": 9000] as [String: Any]] as [String: Any]]) { _, new in new }, "10—3000"),
      ("三轴缺 mode",
       base.merging(["size_intent": ["millimeters": ["x": 1443, "y": 862, "z": 302] as [String: Any]] as [String: Any]]) { _, new in new }, "mode"),
  ]
  for (label, args, needle) in malformed {
      let result = await submitTool().handle("invalid-" + label, arguments(args))
      let payload = parse(result)
      check(result.isError && payload["code"] as? String == WishMachineContract.Code.invalidSizeIntent.rawValue,
          "\(label)：必须是 \(WishMachineContract.Code.invalidSizeIntent.rawValue)（实测 \(String(describing: payload["code"]))）")
      check((payload["message"] as? String)?.contains(needle) == true,
          "\(label)：原因必须可读且提到 \(needle)（实测 \(String(describing: payload["message"]))）")
  }
  try await Task.sleep(for: .milliseconds(200))
  check(readSubmits(scratch).count == beforeDeclared, "畸形尺寸一个提交都不许发出去")
  let axisPending = coordinator.pendingDrafts(worldID: world, residentScope: resident)
  check(axisPending.contains { $0.id.uuidString == axisPendingID },
      "缺轴的草稿必须落盘（续办要用它）")

  // ── 「一把 1.1 米的剑」：线上必须说清是最长边 1.1 米 ──────────────────────
  // 上面已经有过成功的提交，所以这里的序号一律相对基线，不写死 1/2/3。
  let baseline = readSubmits(scratch).count
  try freshGrant()
  let swordTool = submitTool()
  let sword: [String: Any] = ["attachment_id": attachment.id.uuidString, "name": "2B 白色长剑",
                              "size_intent": ["axis": "longest", "meters": 1.1, "source": "user"] as [String: Any]]
  check(swordTool.validate(sword), "合法的尺寸意图必须放行")
  let swordResult = await swordTool.handle("sword", arguments(sword))
  check(!swordResult.isError, "最长边意图必须受理（实测 \(parse(swordResult))）")
  try await until("剑的提交落到替身") { readSubmits(scratch).count == baseline + 1 }
  let swordWire = submitRow(baseline)
  let swordIntent = swordWire["sizeIntent"] as? [String: Any] ?? [:]
  check(swordWire["heightMeters"] as? Double == 1.1,
      "生成请求的数字必须与用户说的一致（实测 \(String(describing: swordWire["heightMeters"]))）")
  check(swordIntent["axis"] as? String == "longest" && swordIntent["meters"] as? Double == 1.1,
      "线上必须是 {axis:longest, meters:1.1}，而不是按高度（实测 \(swordIntent)）")
  check(swordIntent["source"] as? String == "user", "出处必须是 user（实测 \(String(describing: swordIntent["source"]))）")
  let swordJob = coordinator.residentJobs(worldID: world, residentScope: resident).first { $0.name == "2B 白色长剑" }!
  check(swordJob.sizeIntent?.axis == .longest && swordJob.sizeIntent?.meters == 1.1,
      "意图必须随任务持久化（重放与托盘预览都读它）")
  check(swordJob.sizeIntentLine?.contains("最长边") == true && swordJob.sizeIntentLine?.contains("1.10") == true,
      "任务行必须说得出这个尺寸是怎么定的（实测 \(String(describing: swordJob.sizeIntentLine))）")

  // ── 「高 35 厘米的咖啡机」：老的按高度语义仍然表达得出来 ──────────────────
  try freshGrant()
  let machineTool = submitTool()
  let machine: [String: Any] = ["attachment_id": attachment.id.uuidString, "name": "咖啡机",
                                "size_intent": ["axis": "height", "meters": 0.35] as [String: Any]]
  check(machineTool.validate(machine), "按高度的意图必须放行")
  let machineResult = await machineTool.handle("machine", arguments(machine))
  check(!machineResult.isError, "高度意图必须受理（实测 \(parse(machineResult))）")
  try await until("咖啡机的提交落到替身") { readSubmits(scratch).count == baseline + 2 }
  let machineWire = submitRow(baseline + 1)
  let machineIntent = machineWire["sizeIntent"] as? [String: Any] ?? [:]
  check(machineWire["heightMeters"] as? Double == 0.35 && machineIntent["axis"] as? String == "height",
      "按高度的意图：height_meters 与 meters 必须是同一个数（实测 \(String(describing: machineWire["heightMeters"])) / \(machineIntent)）")
  check(machineIntent["source"] as? String == "user", "缺省出处就是 user（用户说的那一个）")

  // ── 旧调用（只有 height_meters）：线上**根本没有** sizeIntent 这个键 ──────
  try freshGrant()
  let legacyTool = submitTool()
  let legacy: [String: Any] = ["attachment_id": attachment.id.uuidString, "name": "旧调用斧头", "height_meters": 0.42]
  check(legacyTool.validate(legacy), "旧调用必须继续可用（兼容）")
  let legacyResult = await legacyTool.handle("legacy", arguments(legacy))
  check(!legacyResult.isError, "旧调用必须受理（实测 \(parse(legacyResult))）")
  try await until("旧调用落到替身") { readSubmits(scratch).count == baseline + 3 }
  let legacyWire = submitRow(baseline + 2)
  check(!legacyWire.keys.contains("sizeIntent"),
      "没有意图时线上不许出现 sizeIntent 这个键（逐字节兼容，实测 \(legacyWire.keys.sorted())）")
  check(legacyWire["heightMeters"] as? Double == 0.42, "旧调用的 height_meters 必须原样保留")
  let legacyJob = coordinator.residentJobs(worldID: world, residentScope: resident).first { $0.name == "旧调用斧头" }!
  check(legacyJob.sizeIntent == nil, "旧调用不产生意图（尺寸推断与今天逐位相同）")
  check(legacyJob.sizeIntentLine == nil, "旧调用的任务行不许因为本契约多出一行")

  // ── 三轴（真机那台「平面电视」）：用户给了 1443 x 862 x 302 mm ⇒ **照实填三轴** ──
  // 旧契约只有"一根轴 + 一个米数"，agent 只能挑一根上报、另外两维没有位置 ⇒
  // 生成器交回一个大立方体。这一条钉的就是"三根轴都要能进来、都要能读回"。
  try freshGrant()
  let televisionTool = submitTool()
  let television: [String: Any] = ["attachment_id": attachment.id.uuidString, "name": "平面电视",
      "size_intent": ["mode": "dimensions",
                      "millimeters": ["x": 1443, "y": 862, "z": 302] as [String: Any],
                      "source": "user"] as [String: Any]]
  check(televisionTool.validate(television), "三轴意图必须放行（不许被结构校验拦成 invalid_arguments）")
  let televisionResult = await televisionTool.handle("television", arguments(television))
  let televisionPayload = parse(televisionResult)
  check(!televisionResult.isError, "三轴意图必须受理（实测 \(televisionPayload)）")
  try await until("电视的提交落到替身") { readSubmits(scratch).count == baseline + 4 }
  let televisionWire = submitRow(baseline + 3)
  // 这一份 fixture 记的是 **taskd** 收到的参数：守护进程要拿到**完整三轴**才存得下来。
  // （"三轴意图从不转发给远端生成服务"是 taskd 内部的事，由 Rust
  // `SizeIntentSupport::accepts` 那条判据钉住：远端严格拒绝未知键。）
  let televisionWireIntent = televisionWire["sizeIntent"] as? [String: Any] ?? [:]
  let televisionWireMM = televisionWireIntent["millimeters"] as? [String: Any] ?? [:]
  check(televisionWireIntent["mode"] as? String == "dimensions"
      && televisionWireMM["x"] as? Double == 1443
      && televisionWireMM["y"] as? Double == 862
      && televisionWireMM["z"] as? Double == 302,
      "三轴意图必须**原话**上到守护进程（三个数一位不差，实测 \(televisionWireIntent)）")
  check(televisionWireIntent["axis"] == nil && televisionWireIntent["meters"] == nil,
      "三轴形状不许同时带 axis/meters（两种形状只能给一种，实测 \(televisionWireIntent.keys.sorted())）")
  check(televisionWire["heightMeters"] as? Double == 0.862,
      "生成请求的数字必须是三轴的 y（高）= 0.862（实测 \(String(describing: televisionWire["heightMeters"]))）")
  // 三根轴**都**落进了任务：一根都不能丢。
  let televisionJob = coordinator.residentJobs(worldID: world, residentScope: resident)
      .first { $0.name == "平面电视" }!
  check(televisionJob.sizeIntent?.mode == .dimensions, "任务上必须记得这是三轴形状")
  check(televisionJob.sizeIntent?.millimeters?.x == 1443
      && televisionJob.sizeIntent?.millimeters?.y == 862
      && televisionJob.sizeIntent?.millimeters?.z == 302,
      "三根轴必须原话落库（实测 \(String(describing: televisionJob.sizeIntent?.millimeters))）")
  check(televisionJob.sizeIntent?.heightMetersForSubmission == 0.862, "提交高度必须取三轴的 y")
  check(televisionJob.sizeIntentLine?.contains("1443 × 862 × 302") == true,
      "任务行必须原话回读三个毫米数（实测 \(String(describing: televisionJob.sizeIntentLine))）")
  // 工具回执也要能逐位核对（面板与 agent 转述读的就是它）。
  let televisionReadback = televisionPayload["size_intent"] as? [String: Any] ?? [:]
  let televisionReadbackMM = televisionReadback["millimeters"] as? [String: Any] ?? [:]
  check(televisionReadback["mode"] as? String == "dimensions"
      && televisionReadbackMM["x"] as? Double == 1443
      && televisionReadbackMM["y"] as? Double == 862
      && televisionReadbackMM["z"] as? Double == 302,
      "工具回执必须回读三根轴（实测 \(televisionReadback)）")
  check(televisionPayload["size_intent_forwarding"] as? String == "three_axis_never_forwarded_height_only",
      "回执必须说清三轴意图没有发给远端（实测 \(String(describing: televisionPayload["size_intent_forwarding"]))）")
  // 三轴的 y 与 height_meters 是同一件事：两者**同时给**就说不清是哪一份
  // （守护进程侧同一个语义的码是 `size_intent_conflict`）。
  try freshGrant()
  let conflictBefore = readSubmits(scratch).count
  let conflictResult = await submitTool().handle("television-conflict", arguments(
      base.merging(["height_meters": 0.862,
          "size_intent": ["mode": "dimensions",
                          "millimeters": ["x": 1443, "y": 862, "z": 302] as [String: Any]] as [String: Any]]) { _, new in new }))
  check(conflictResult.isError
      && (parse(conflictResult)["message"] as? String)?.contains("只能给一个") == true,
      "三轴意图与 height_meters 同时给必须具名拒绝（实测 \(parse(conflictResult))）")
  try await Task.sleep(for: .milliseconds(200))
  check(readSubmits(scratch).count == conflictBefore, "冲突时一个提交都不许发出去")

  // ── 意图回读：守护进程 job JSON → app 记录（面板与回执读同一份） ───────────
  await store.refreshSnapshot()
  let swordRecord = store.jobs.first { $0.id == swordJob.id }
  check(swordRecord?.sizeIntent?.axis == .longest && swordRecord?.sizeIntent?.meters == 1.1,
      "守护进程回显的意图必须能解回 app（实测 \(String(describing: swordRecord?.sizeIntent))）")
  check(swordRecord?.heightMeters == 1.1, "记录里的 height_meters 与意图同源")
  let legacyRecord = store.jobs.first { $0.id == legacyJob.id }
  check(legacyRecord?.sizeIntent == nil, "旧任务的记录里没有意图（是 nil，不是补一个按高度的意图）")
  let televisionRecord = store.jobs.first { $0.id == televisionJob.id }
  check(televisionRecord?.sizeIntent?.millimeters?.x == 1443
      && televisionRecord?.sizeIntent?.millimeters?.y == 862
      && televisionRecord?.sizeIntent?.millimeters?.z == 302,
      "守护进程回显的三轴必须能解回 app（实测 \(String(describing: televisionRecord?.sizeIntent))）")
  check(televisionRecord?.heightMeters == 0.862, "记录里的 height_meters 就是三轴的 y")

  // ── 真机缺陷（2026-10-02「超大荧幕电视」）：三轴意图派生的米数必须是**米** ──────
  //
  // 现场：用户在对话里给了参考图 + `1443 x 862 x 302 mm`，任务行最后是
  //   "场景加载失败 / 成品场景加载失败：许愿机产物的尺寸无效，暂时无法显示。"
  // 而那件东西**永远停在 `stage == .ready`**，走不到已经写好的
  // "三轴 + 板形 ⇒ 用基础几何拼电视"那条路 —— 因为托盘归一先失败了。
  //
  // 根因不在几何，在**意图的记账**：`PropSizeIntent.Millimeters.longestMeters` 少了一层括号，
  // `edges.max() ?? 0 / 1000` 被读成 `edges.max() ?? (0 / 1000)` ⇒ 派生的 `meters` 是
  // `1443`（毫米当米）。下面每一条都跑**真源码 + 真数字 + 真机那份网格量出来的包围盒**。
  let dimsIntent = PropSizeIntent(millimeters: .init(x: 1443, y: 862, z: 302), source: .user)!
  check(dimsIntent.mode == .dimensions && dimsIntent.axis == .longest,
      "三轴意图派生的轴必须是最长边（实测 \(dimsIntent.axis)）")
  check(dimsIntent.isValid, "三轴意图必须合法（三个毫米数都在 10—3000）")
  check(abs(dimsIntent.meters - 1.443) < 1e-9,
      "三轴意图派生的 meters 必须是**米**（实测 \(dimsIntent.meters)；毫米当米就是现场那句「尺寸无效」）")
  let worldDimsIntent = WorldPropSizeIntent(axis: dimsIntent.axis.rawValue, meters: dimsIntent.meters,
                                            source: dimsIntent.source.rawValue)
  check(worldDimsIntent != nil,
      "三轴意图必须能落进世界状态（实测 \(String(describing: worldDimsIntent))：nil ⇒ 意图被静默丢掉）")

  // 真机那份生成网格：`TaskService/0C285296-9164-4A2B-8FB7-6648E549A4AE.glb` 的**逐顶点**实测值。
  let measuredMesh = WorldVector3(x: 1.007901, y: 0.628927, z: 1.007904)
  let measuredMeshMin = SIMD3<Float>(-0.503954, -0.314110, -0.503955)
  let measuredMeshMax = SIMD3<Float>(0.503946, 0.314817, 0.503950)
  // 托盘那一步用的是同一个映射（`PropSizeIntent.Axis.policyAxis`，在 WishMachineOutputRenderer.swift）。
  let trayAxis: WorldPropSizeAxis = dimsIntent.axis == .longest ? .longest : .height
  let trayResolution = WorldPropSizePolicy.intended(
      sourceExtent: measuredMesh, axis: trayAxis, meters: Float(dimsIntent.meters))
  check(trayResolution != nil, "托盘必须能把这件电视归一成世界尺寸（实测 nil ⇒ 现场那句「尺寸无效」）")
  check(trayResolution.map { abs(WorldPropSizePolicy.longestEdge(of: $0.size) - 1.443) < 1e-5 } ?? false,
      "托盘归一后的最长边必须 = 1.443 米（实测 \(String(describing: trayResolution?.size))）")
  // 「描述符非 nil」在这里的机械形态：能算出放置矩阵 = 这一件真的画得出来。
  let trayTransform = trayResolution.flatMap { resolution in
      try? WishMachineOutputPlacement.transform(
          minimum: measuredMeshMin, maximum: measuredMeshMax,
          targetHeight: resolution.size.y, outlet: .zero)
  }
  check(trayTransform != nil, "托盘上这件必须能算出放置矩阵（描述符非 nil）")
  // 那条**不成立的不等式**本身：毫米当米（1443）超出了 `0.01—100` 米。
  check(WorldPropSizePolicy.intended(sourceExtent: measuredMesh, axis: trayAxis, meters: 1443) == nil,
      "毫米当米（1443 米）必须归不出来 —— 这就是现场那条判据")
  let namedRejection = WishMachineOutputError.invalidDimensions(WishMachineDimensionRejection(
      field: "size_intent.longest.meters", value: 1443, expected: "0.01—100 米"))
  check(namedRejection.localizedDescription.contains("size_intent.longest.meters")
      && namedRejection.localizedDescription.contains("1443"),
      "尺寸无效类失败必须带字段与数值（实测 \(namedRejection.localizedDescription)）")

  // ── 同一件电视在权威里的记录：拼出来的 == 声明出来的 == 渲染端量出来的 ──────────
  //
  // 几何侧那本账是**对的**：这一条把它逐位钉住，免得"修根因"顺手改坏几何，
  // 也钉住"画面、判据、碰撞盒只有一份尺寸"。
  //
  // 指纹在 2026-10-02 变过一次，而且是**只动外观、不动几何**的那一次：
  // 原来的 GLB **一个 `materials` 都没有** ⇒ 七块盒子全部落回渲染器缺省材质
  // （白 + 全金属 + 全粗糙），真机上就是用户截图里那块「灰板 + 一个大黑矩形」。
  // 现在每个部件带一份深色材质（`WorldPrimitiveTelevisionFinish`），字节 2408 → 4048，
  // 引用从 `sha256:05bc11fe…` 变成 `sha256:1b2d2c37…`。**盒子数量、位置、三轴、三角形
  // 一个都没动**（下面那几条逐位判据就是这件事的机械证据）。
  let tvSpec = WorldPropSizeMillimeters(x: 1443, y: 862, z: 302)!
  let tv = try WorldPrimitiveTelevision(millimeters: tvSpec)
  let tvProp = tv.generatedProp(objectID: "wish-prop-television", sourceWishID: "wish-television")
  check(tvProp.isValid, "基础几何电视的物件记录必须合法")
  check(tvProp.size == tv.size && tvProp.sourceHeight == tv.size.y,
      "声明出来的 size 必须就是拼出来的那一份（实测 \(tvProp.size) / \(tvProp.sourceHeight)）")
  check(abs(tvProp.size.x - 1.443) < 1e-5 && abs(tvProp.size.y - 0.862) < 1e-5
        && abs(tvProp.size.z - 0.302) < 1e-5,
      "三轴必须逐位是 1.443 × 0.862 × 0.302（实测 \(tvProp.size)）")
  check(abs(tv.minimum.y) <= 1e-5 && abs(tvProp.size.y / tvProp.sourceHeight - 1) < 1e-6,
      "必须落地（min.y = 0）且 size.y / sourceHeight = 1（画面、判据、碰撞盒同一个数）")
  // 「量出来的 == 拼出来的」这条判据本身（与 app 侧那一行同一个口径：逐分量 ≤ 0.002 米）。
  func tvBoundsMatches(_ extent: SIMD3<Float>, _ size: WorldVector3) -> Bool {
      abs(extent.x - size.x) <= 0.002 && abs(extent.y - size.y) <= 0.002 && abs(extent.z - size.z) <= 0.002
  }
  if let measured = PrimitiveGLBBounds.measure(tv.assetBytes) {
      let measuredExtent = measured.maximum - measured.minimum
      check(tv.assetBytes.count == 4048
            && tv.assetID == "sha256:1b2d2c37d232aaa3eadb5e0e41afd811079866016e97680443d0ab800af52b38",
          "基础几何电视的字节必须还是内容寻址那一份（实测 \(tv.assetBytes.count) 字节 / \(tv.assetID)）")
      check(tvBoundsMatches(measuredExtent, tv.size),
          "渲染端量出来的包围盒必须就是拼出来的那一份（实测 \(measuredExtent) vs \(tv.size)，容差 0.002）")
      check(abs(measured.minimum.y - tv.minimum.y) <= 0.002,
          "渲染端量出来的底必须落在 y = 0（实测 \(measured.minimum.y)）")
      // 注入负对照（数值）：同一个判据，把**一个分量**改掉 0.01 米（> 0.002）⇒ 必须变红。
      var perturbedExtent = measuredExtent; perturbedExtent.z += 0.01
      check(!tvBoundsMatches(perturbedExtent, tv.size),
          "注入负对照：把量出来的 z 改 0.01 米 ⇒ 「量出来的 == 拼出来的」必须不成立")
      check(!tvBoundsMatches(measuredExtent, WorldVector3(x: tv.size.x, y: tv.size.y,
                                                          z: tv.size.z + 0.01)),
          "注入负对照：把声明的 z 改 0.01 米 ⇒ 同一条判据必须不成立")
  } else {
      check(false, "基础几何电视的资产字节量不出包围盒（GLB 解不开 ⇒ 画不出来）")
  }
  // 幂等：同一份记录编码两次逐字节相同 ⇒ 重放不会产生第二条。
  let propEncoder = JSONEncoder(); propEncoder.outputFormatting = [.sortedKeys]
  let tvFirst = try propEncoder.encode(tvProp), tvSecond = try propEncoder.encode(tvProp)
  check(tvFirst == tvSecond, "同一份记录编码两次必须逐字节相同（幂等重放不产生第二条）")
  let tvDecoded = try JSONDecoder().decode(WorldGeneratedProp.self, from: tvFirst)
  check(tvDecoded == tvProp && tvDecoded.primitive?.sizeMeters == tv.size,
      "同形编码必须读回同一份（三轴回读 \(String(describing: tvDecoded.primitive?.millimeters))）")

  // ══ 断言 10（行为）：**三个数就是三个数**（逐轴）+ 渲染与碰撞读同一组尺寸 ══════════
  //
  // 用户 2026-10-02 的现场原话（连续两条）：「我都给了尺寸了为什么不能按照尺寸出」/「你改契约啊」。
  // 旧契约是三轴意图**按最长边等比**归一、另外两维只写进 reason 当"期望值" ⇒ 给了三个数，
  // 场景里只有最长边那一维兑现。这一节用**真源码 + 真机那份网格的逐顶点实测 AABB**跑行为判据。
  let threeAxis = WorldPropSizeMillimeters(x: 1443, y: 862, z: 302)!
  // 目标三轴（米）：与 `WorldPropSizeMillimeters.meters` 同一套算式，好做**逐位**比较。
  let exactTarget = WorldVector3(x: Float(1443) / 1000, y: Float(862) / 1000, z: Float(302) / 1000)
  let dimsResolution = WorldPropSizePolicy.intended(sourceExtent: measuredMesh, millimeters: threeAxis)
  check(dimsResolution != nil, "三轴意图必须归得出世界尺寸（实测 nil）")
  // **逐位**（`==`，不是"容差内"）：中间再走一次别的换算就会差出 ULP —— 那正是"两份尺寸"的形状。
  check(dimsResolution?.size == exactTarget,
      "世界 size 必须逐位是 1.443 × 0.862 × 0.302（实测 \(String(describing: dimsResolution?.size))）")
  check(dimsResolution?.basis == .dimensions,
      "走的必须是逐轴那一条（实测 \(String(describing: dimsResolution?.basis))）")
  check(dimsResolution.map {
      $0.scales == WorldVector3(x: exactTarget.x / measuredMesh.x,
                                y: exactTarget.y / measuredMesh.y,
                                z: exactTarget.z / measuredMesh.z)
  } ?? false,
      "逐轴比例必须逐位等于 size / 网格跨度（实测 \(String(describing: dimsResolution?.scales))）")

  // ── 渲染端：放置矩阵的三个比例必须**逐位**是 size / 摆正后网格跨度 ──────────────
  // 这是"画面按三个数画"的机械判据：矩阵对角线就是渲染端真正用的那一份缩放。
  let renderMatrix = try? ResidentPropPlacementMatrix.transform(
      minimum: measuredMeshMin, maximum: measuredMeshMax,
      targetHeight: exactTarget.y, targetSize: exactTarget,
      position: .zero, yaw: 0)
  check(renderMatrix != nil, "三轴那一件必须能算出放置矩阵（实测 nil ⇒ 画不出来）")
  if let renderMatrix {
      let meshExtent = measuredMeshMax - measuredMeshMin
      let renderScale = SIMD3<Float>(renderMatrix.columns.0.x, renderMatrix.columns.1.y,
                                     renderMatrix.columns.2.z)
      let wantedScale = SIMD3<Float>(exactTarget.x / meshExtent.x, exactTarget.y / meshExtent.y,
                                     exactTarget.z / meshExtent.z)
      check(renderScale == wantedScale,
          "渲染端的三个比例必须逐位是 size / 网格跨度（实测 \(renderScale) vs \(wantedScale)）："
          + "差一个数就是「画面与判定各推一份尺寸」")
      check(abs(renderScale.x - renderScale.y) > 1e-3 && abs(renderScale.y - renderScale.z) > 1e-3,
          "真机这件本来就不是等比（立方体网格 → 扁平面板），三个比例不该相同（实测 \(renderScale)）")
  }

  // ── 碰撞 / 承托：读的是**同一份** `effectiveSize`（世界里那一份 `size`） ───────────
  let dimsWorldIntent = WorldPropSizeIntent(axis: "longest", meters: 1.443, source: "user")!
  let dimsProp = WorldGeneratedProp(
      objectID: "wish-prop-3axis", sourceWishID: "wish-3axis",
      assetID: "sha256:" + String(repeating: "a", count: 64), displayName: "超大荧幕电视",
      size: exactTarget, sourceHeight: measuredMesh.y, sizeIntent: dimsWorldIntent)
  check(dimsProp.isValid, "三轴那一件必须是合法的世界物件（实测 false）")
  check(dimsProp.effectiveSize == exactTarget,
      "判据/碰撞读的 `effectiveSize` 必须逐位就是那三个数（实测 \(dimsProp.effectiveSize)）")
  let dimsFootprint = WorldPlanarFootprint(size: SIMD2(dimsProp.effectiveSize.x,
                                                       dimsProp.effectiveSize.z), yaw: 0)
  check(dimsFootprint.size == SIMD2<Float>(exactTarget.x, exactTarget.z),
      "footprint 的 x/z 必须就是那三个数里的 x/z（实测 \(dimsFootprint.size)）：碰撞盒与画面同一组数字")
  check(abs(dimsFootprint.halfExtents.x - 0.7215) <= 1e-6
        && abs(dimsFootprint.halfExtents.y - 0.151) <= 1e-6,
      "碰撞盒半长必须由同一份尺寸派生（实测 \(dimsFootprint.halfExtents)）")

  // ── 注入负对照（数值）：**只取最长边**那一条路必须被上面两条判据抓住 ──────────────
  // 旧契约就是这一条：按最长边等比。它算出来的 `size` 与那三个数**不等**，放置矩阵的三个比例
  // **全都相同** ⇒ 上面两条都会红。一个从不 FAIL 的门禁等于没有门禁。
  let legacyUniform = WorldPropSizePolicy.intended(sourceExtent: measuredMesh, axis: .longest, meters: 1.443)
  check(legacyUniform.map { $0.size != exactTarget } ?? true,
      "注入负对照：只取最长边那一条路**必须**给不出那三个数（实测 \(String(describing: legacyUniform?.size))）")
  if let legacyUniform,
     let legacyMatrix = try? ResidentPropPlacementMatrix.transform(
        minimum: measuredMeshMin, maximum: measuredMeshMax,
        targetHeight: legacyUniform.size.y, targetSize: legacyUniform.size, position: .zero, yaw: 0) {
      let legacyScale = SIMD3<Float>(legacyMatrix.columns.0.x, legacyMatrix.columns.1.y,
                                     legacyMatrix.columns.2.z)
      check(legacyScale.x == legacyScale.y && legacyScale.y == legacyScale.z,
          "注入负对照：只取最长边那一条路的三个比例必须全都相同（实测 \(legacyScale)）"
          + "⇒「三个比例逐位是 size / 网格跨度」那条判据必然 FAIL")
  }

  // ── 单轴那一档**一字不动**：`axis=longest` / `axis=height` 仍然等比到那个数 ────────
  let swordMesh = WorldVector3(x: 1.005, y: 0.133, z: 0.057)
  let swordOne = WorldPropSizePolicy.intended(sourceExtent: swordMesh, axis: .longest, meters: 1.1)
  check(swordOne != nil, "单轴 `axis=longest` 必须仍然归得出尺寸（实测 nil ⇒ 那把剑又变回 8.28 m）")
  check(swordOne.map { abs(WorldPropSizePolicy.longestEdge(of: $0.size) - 1.1) <= 1e-5 } ?? false,
      "单轴 `axis=longest` 的最长边必须 = 1.1 米（实测 \(String(describing: swordOne?.size))）")
  check(swordOne.map { WorldPropSizePolicy.uniformFactor(from: swordMesh, to: $0.size) != nil } ?? false,
      "单轴 `axis=longest` 仍然必须**等比**（实测 \(String(describing: swordOne?.size))）")
  let swordHeight = WorldPropSizePolicy.intended(sourceExtent: swordMesh, axis: .height, meters: 0.35)
  check(swordHeight.map { abs($0.size.y - 0.35) <= 1e-5 } ?? false,
      "单轴 `axis=height` 必须仍然按高度归一（实测 \(String(describing: swordHeight?.size))）")
  // 同一根网格：三轴那一档**不是**等比，单轴那一档**是** —— 两种形状不许混。
  check(WorldPropSizePolicy.uniformFactor(from: swordMesh, to: exactTarget) == nil,
      "三轴那一档本来就不是等比：拿它去过 `uniformFactor` 必须不成立（否则说明又被等比了）")
  // 三轴那一档**也不许**退化成单轴：`axis=longest` 只兑现已一维，两者必须给出不同的 `size`。
  check(swordOne.map { $0.size != exactTarget } ?? true,
      "三轴与单轴必须给出不同的 world size（否则三轴那一档只是在冒充最长边）")

  // ══ 断言 11（行为）：**画出来的三个轴逐轴等于用户给的三个数**（四条路径）══════════
  //
  // 用户 2026-10-02 原话「厚度不对啊」：真机那台电视的生成网格是个**方盒子**
  // （逐顶点实测 1.007901 × 0.628927 × 1.007904），逐轴缩放之后必须是
  // 1.443 × 0.862 × 0.302 的**薄板**；任何一条路径退回等比，画出来的就是
  // 1.3815 × 0.862 × 1.3815 的厚方块（进深与宽度同量级）—— 正是用户看到的那一件。
  //
  // 判据不看源码字符串，看**画出来的包围盒**：把源网格 8 个角过一遍真正的放置矩阵。
  // 已摆 / 预览 / 手持 走的是同一个 `ResidentPropPlacementMatrix`（手持那一件在
  // `ResidentPropRenderer.renderDescriptor(for:)` 里换成 `ResidentPropRenderDescriptor`
  // 之后走**同一行**渲染），托盘走 `WishMachineOutputPlacement`。
  func renderedExtent(_ matrix: simd_float4x4) -> SIMD3<Float> {
      var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
      var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
      for index in 0..<8 {
          let corner = SIMD3<Float>(index & 1 == 0 ? measuredMeshMin.x : measuredMeshMax.x,
                                    index & 2 == 0 ? measuredMeshMin.y : measuredMeshMax.y,
                                    index & 4 == 0 ? measuredMeshMin.z : measuredMeshMax.z)
          let projected = matrix * SIMD4<Float>(corner, 1)
          let point = SIMD3<Float>(projected.x, projected.y, projected.z)
          low = SIMD3<Float>(Swift.min(low.x, point.x), Swift.min(low.y, point.y), Swift.min(low.z, point.z))
          high = SIMD3<Float>(Swift.max(high.x, point.x), Swift.max(high.y, point.y), Swift.max(high.z, point.z))
      }
      return high - low
  }
  func bboxIsThreeNumbers(_ extent: SIMD3<Float>) -> Bool {
      abs(extent.x - exactTarget.x) <= 1e-4 && abs(extent.y - exactTarget.y) <= 1e-4
          && abs(extent.z - exactTarget.z) <= 1e-4
  }
  // ── 已摆 / 预览（世界里那一份 `effectiveSize`）────────────────────────────────
  if let placedMatrix = try? ResidentPropPlacementMatrix.transform(
      minimum: measuredMeshMin, maximum: measuredMeshMax,
      targetHeight: exactTarget.y, targetSize: exactTarget, position: .zero, yaw: 0) {
      let extent = renderedExtent(placedMatrix)
      print("实测 bbox[已摆/预览] = \(extent.x) × \(extent.y) × \(extent.z) 米"
          + "（应为 \(exactTarget.x) × \(exactTarget.y) × \(exactTarget.z)；差 "
          + "\(extent.x - exactTarget.x) / \(extent.y - exactTarget.y) / \(extent.z - exactTarget.z)）")
      check(bboxIsThreeNumbers(extent),
          "已摆/预览画出来的三个轴必须逐轴是 \(exactTarget)（实测 \(extent)）")
  } else {
      check(false, "已摆/预览那一件必须能算出放置矩阵（实测 nil ⇒ 画不出来）")
  }
  // ── 手持：手里那一件的**三个比例**是 `targetSize[i] / 摆正后跨度[i]`，不是一份等比 ──
  //
  // 手持的实际绘制走的是另一个矩阵（`PropAttachmentMatrix.transform` = 手骨位姿 × 标定 ×
  // **逐轴缩放** × 抓握点），它的缩放三轴就是 `scaleValues`；那一段依赖 `PropAttachment.swift`
  // 与真实骨骼位姿，本 harness 不编译它 —— 所以手持那一档由**源码判据**钉住（(f)：
  // `targetSizeMeters: held.targetSizeMeters`、`targetSizeMeters: prop.effectiveSize)` 与
  // `scaleValues = perAxis.map { … }` 三条都在，各有注入负对照）。
  // 已摆 / 预览与手持读的是**同一组数字**（世界里那一份 `effectiveSize`），所以上面那次 bbox
  // 实测对手持同样成立：它吃的就是 `targetSizeMeters` 这一个字段。
  // ── 托盘（`WishMachineOutputPlacement`，还没登记的那一件）────────────────────
  if let trayMatrix = try? WishMachineOutputPlacement.transform(
      minimum: measuredMeshMin, maximum: measuredMeshMax,
      targetHeight: exactTarget.y, targetSize: exactTarget, outlet: .zero) {
      let extent = renderedExtent(trayMatrix)
      print("实测 bbox[托盘] = \(extent.x) × \(extent.y) × \(extent.z) 米")
      check(bboxIsThreeNumbers(extent), "托盘画出来的三个轴必须逐轴是 \(exactTarget)（实测 \(extent)）")
  } else {
      check(false, "托盘那一件必须能算出放置矩阵（实测 nil ⇒ 画不出来）")
  }
  // ── 注入负对照（数值）：把第三个数丢掉 / 走等比那一支 ⇒ 上面三条判据**必须**不成立 ──
  if let uniformMatrix = try? ResidentPropPlacementMatrix.transform(
      minimum: measuredMeshMin, maximum: measuredMeshMax,
      targetHeight: exactTarget.y, targetSize: nil, position: .zero, yaw: 0) {
      let extent = renderedExtent(uniformMatrix)
      print("注入负对照 bbox[等比] = \(extent.x) × \(extent.y) × \(extent.z) 米")
      check(!bboxIsThreeNumbers(extent),
          "注入负对照：走等比那一支（`targetSize: nil`）必须与三个数不等 —— 实测却相等（\(extent)）")
  } else {
      check(false, "注入负对照：等比那一支必须算得出来（否则这条负对照空转）")
  }
  if let droppedMatrix = try? ResidentPropPlacementMatrix.transform(
      minimum: measuredMeshMin, maximum: measuredMeshMax, targetHeight: exactTarget.y,
      targetSize: WorldVector3(x: exactTarget.x, y: exactTarget.y, z: exactTarget.x),
      position: .zero, yaw: 0) {
      let extent = renderedExtent(droppedMatrix)
      check(!bboxIsThreeNumbers(extent),
          "注入负对照：把第三个数丢掉（z 借用 x）必须与三个数不等 —— 实测却相等（\(extent)）")
  }
  if let trayUniform = try? WishMachineOutputPlacement.transform(
      minimum: measuredMeshMin, maximum: measuredMeshMax,
      targetHeight: exactTarget.y, targetSize: nil, outlet: .zero) {
      let extent = renderedExtent(trayUniform)
      check(!bboxIsThreeNumbers(extent),
          "注入负对照：托盘走等比必须与三个数不等 —— 实测却相等（\(extent)）")
  }

  finish()
 }
}
"""#

let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-size-intent-harness-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let main = temp.appendingPathComponent("Checks.swift"), python = temp.appendingPathComponent("fixture.py")
try program.write(to: main, atomically: true, encoding: .utf8)
try fixture.write(to: python, atomically: true, encoding: .utf8)
let binary = temp.appendingPathComponent("checks")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
compiler.arguments = ["swiftc", "-swift-version", "6", "-parse-as-library"]
    + worldRuntimeHarnessFlags()
    + required.map { sources.appendingPathComponent($0).path } + [main.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let run = Process(); run.executableURL = binary; run.arguments = [python.path]
try run.run(); run.waitUntilExit(); exit(run.terminationStatus)
