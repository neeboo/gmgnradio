// 电视机**接线**的判据：覆盖层 / 三条 agent 工具是不是真的接进了 App，
// 以及**那块电视面板一个调用点都没有**。
//
// 为什么这一条要单独存在：`tools/test-resident-screen-overlay.swift` 的判据（几何、投影、
// 不吃指针、失败具名、只走官方嵌入）全部是**类型级**的。`Screen/**` 那 70 条断言可以全绿，
// 而 `WorldScreenStore` 在 App 侧**一个构造点都没有** —— 编译得进、跑不起来。
// 2026-10-01 的真机构建里 `strings | grep -c installScreenOverlayIfNeeded` = 0，
// 就是这件事的现场：整套代码一行都没跑过。
//
// 2026-10-02 用户决定推翻了"只在需要时出现"那个折中：「左下角那块电视面板压根儿不应该出现」
// —— 不自动显示、不常驻、也没有菜单入口。于是判据 ③ 从"面板装上并可见"**反过来**：
// 面板的挂载 / 显示标识符在产品源码里**一处都不许有**（把面板加回来 ⇒ 必须 FAIL）。
// 面板视图 `ScreenPanelView` 本身仍**保留**在 `Screen/ScreenPanel.swift`（不许 rm），
// 文件头写明它为什么不在产品界面里（判据 ⑦）。覆盖层与三条 agent 工具**照常**（判据 ②④⑤⑥）。
//
// 所以这里的判据是**接线本身**，不是"这些类型存在"：
//
//   ① App 侧 `WorldScreenStore` **唯一**构造点，且只接一次（`guard screenStore == nil`）；
//   ② 覆盖层真的接上舞台窗口（取宿主 → 建控制器 → `startTracking()`）；
//   ③ **面板不出现**：这两份源码里 0 处安装 / 显示调用点、0 处面板挂载标识符；
//   ④ 覆盖层容器在**视图树**里（`addSubview(screenOverlayContainer)`，不是只声明一个变量）；
//   ⑤ `installScreenOverlayIfNeeded()` 在舞台窗口出现的那条路上**有调用点**；
//   ⑥ `screenTools` 真的并进了本轮的 `additionalTools`（否则 agent 看不见这三条工具：
//      play_screen / stop_screen / read_screen）；
//   ⑦ 面板文件仍在仓库里、文件头保留「已从产品界面移除」的原文。
//   ⑧ **三条工具不依赖覆盖层 / 宿主视图的时机**（真机 2026-10-03）：接线里不许再有
//      `screenStore.map { … } ?? []` 那种"store 不存在 ⇒ 整批不注册"，必须是
//      "无条件构造转发器 + 真有调用进来时才去找 store"；
//   ⑨ 三条工具的 canonical 名只有一处定义（`ResidentScreenTools`）；
//   ⑩ **屏幕功能点真的注册到物件上**：注册表从物件状态派生，判据只有一处
//      （`WorldScreenResolution.resolve`），与窗口/覆盖层无关；
//   ⑪ 那份注册结果在**物件描述里读得到**（`read_owned_props` 的 `screen` 那一行）；
//   ⑫ 顶层 `interaction_status` 跟着事实走：有屏幕功能点就不许再说 `appearance_only`
//      （居民那句"这台电视登记的是纯外形摆件"就是读它读出来的）；
//   ⑬ **有屏幕才说能播**：那一行是条件写入，且没有任何"没注册也兜一份"的路径。
//
// 判据是文本级的，因为它要回答的正是"接线在不在、**什么时候**在"；每一条都配
// **注入负对照** —— 在源码副本上做手术（删掉那一行 / 把面板加回来 / 把接线退回时机依赖 /
// 不注册屏幕功能点 / 描述仍写无功能 / 无条件宣称能播），判据必须变红。
// 一个从不 FAIL 的门禁等于没有门禁。
//
// ⑧ 另有一条**真编译**的复核：`tools/test-living-resident-loop.swift` 原文抽编
// `makeResidentWorldTools`，在 `screenStore == nil`（= 覆盖层还没接上）的那一支下数清单 ——
// 退回时机依赖 ⇒ 那里少 3 条 schema、红。
//
// 现场演示：`SCREEN_WIRING_INJECT=dropInstallCall swift tools/test-resident-screen-app-wiring.swift`
// 会把**真源码**当成"接线被删掉"的那一份来判，于是主判据自己打出一条 FAIL。
// 面板那一条的现场：`SCREEN_WIRING_INJECT=restorePanelInstall …`（面板又回来了 ⇒ FAIL）。
// 时机依赖那一条的现场：`SCREEN_WIRING_INJECT=timingDependency …`（三条工具退回时机 ⇒ FAIL）。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")

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

/// 非重叠出现次数。用它而不是 `components(separatedBy:)`：后者在空串上会炸。
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

/// 「面板又回到产品路径里」的机器判据：这些标识符在产品源码里**一处都不许有**。
///
/// 覆盖三件事，缺一不可：
/// - 安装 / 显示调用点（`installScreenPanel(` / `setScreenPanelVisible(`）；
/// - 面板对象的创建（`ScreenPanelView(` —— 创建出来就是"半死状态"）；
/// - 面板在布局里的挂点与视图标识符（`screenPanelHost` / `stage.screen-panel`）。
let panelEntryPointNeedles = [
    "installScreenPanel(",
    "setScreenPanelVisible(",
    "ScreenPanelView(",
    "screenPanelHost",
    "stage.screen-panel",
]

/// 判据用的那两份源码里的面板痕迹（行级）。
func panelEntryPointHits(in sources: ScreenWiringSources) -> [String] {
    var hits: [String] = []
    let files = [
        ("App/GMGNRadioApp.swift", sources.app),
        ("VisualEngine/StageWindowController.swift", sources.stage),
    ]
    for (label, text) in files {
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            for needle in panelEntryPointNeedles where line.contains(needle) {
                hits.append("\(label):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
    return hits
}

/// 判据 ③ 的**全树**版本：不只上面那两份文件，整棵 `apps/macos/Sources/GMGNRadio`
/// 里都不许有面板痕迹（菜单 / 入口都在这棵树里）。
func productPanelEntryPoints() -> [String] {
    guard let walker = FileManager.default.enumerator(
        at: appRoot, includingPropertiesForKeys: nil
    ) else {
        return ["（扫不了 \(appRoot.path)）"]
    }
    var hits: [String] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        let relative = url.path.replacingOccurrences(of: appRoot.path + "/", with: "")
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            for needle in panelEntryPointNeedles where line.contains(needle) {
                hits.append("\(relative):\(index + 1)")
            }
        }
    }
    return hits.sorted()
}

// ---------------------------------------------------------------------------
// MARK: 判据
// ---------------------------------------------------------------------------

/// 判据只看这几份 App 侧源码。`Screen/**` 内部逻辑（遮挡 / 选面那一条线）不在范围内 ——
/// 接线判据只回答"有没有接上、**什么时候**接上"，不回答"接上之后对不对"。
struct ScreenWiringSources: Equatable {
    /// `App/GMGNRadioApp.swift`
    var app: String
    /// `VisualEngine/StageWindowController.swift`
    var stage: String
    /// `Agent/ResidentPropToolBridge.swift`：`read_owned_props` 回执的产地。
    var bridge: String
    /// `Screen/WorldScreenMetadata.swift`：屏幕功能点**运行时注册表**的产地。
    var metadata: String
    /// `Screen/ResidentScreenTools.swift`：三条工具与 `WorldScreenControlRelay` 的产地。
    var tools: String

    static func load() throws -> ScreenWiringSources {
        ScreenWiringSources(
            app: try read(appRoot.appendingPathComponent("App/GMGNRadioApp.swift")),
            stage: try read(appRoot.appendingPathComponent("VisualEngine/StageWindowController.swift")),
            bridge: try read(appRoot.appendingPathComponent("Agent/ResidentPropToolBridge.swift")),
            metadata: try read(appRoot.appendingPathComponent("Screen/WorldScreenMetadata.swift")),
            tools: try read(appRoot.appendingPathComponent("Screen/ResidentScreenTools.swift"))
        )
    }
}

/// 「电视接线在不在」的**唯一**判据。空数组 = 接线完整。
func screenAppWiringProblems(_ sources: ScreenWiringSources) -> [String] {
    var problems: [String] = []
    let app = sources.app
    let stage = sources.stage
    // 屏幕功能点那三条判据（⑩⑪⑫⑬）读的是**另外三份**生产源码：
    // 注册表在 `Screen/WorldScreenMetadata.swift`，回执在 `Agent/ResidentPropToolBridge.swift`，
    // 三条工具的 canonical 名在 `Screen/ResidentScreenTools.swift`。
    let bridge = sources.bridge
    let metadata = sources.metadata
    let tools = sources.tools

    // ① App 侧唯一构造点 + 只接一次。
    let constructors = occurrences(of: "WorldScreenStore(", in: app)
    if constructors != 1 {
        problems.append(
            "① App 侧 `WorldScreenStore(` 出现 \(constructors) 次，应**恰好 1 次**"
                + "（多了就是第二个事实源，少了就是一行都没跑）"
        )
    }
    if !app.contains("private func installScreenOverlayIfNeeded()") {
        problems.append("① 没有 `installScreenOverlayIfNeeded()`：接线没有唯一入口")
    }
    if !app.contains("guard screenStore == nil") {
        problems.append("① 接线没有「只接一次」的守卫（`guard screenStore == nil`）")
    }
    if !app.contains("screenStore = store") {
        problems.append("① 造出来的 store 没有被存下（`screenStore = store`）：agent 工具拿不到它")
    }

    // ② 覆盖层真的接上舞台窗口。
    if !app.contains("controller.screenOverlayHostView") {
        problems.append("② 接线没有取舞台窗口的覆盖层宿主（`controller.screenOverlayHostView`）")
    }
    if !app.contains("WorldScreenOverlayController(hostView: host)") {
        problems.append("② 没有构造覆盖层（`WorldScreenOverlayController(hostView: host)`）")
    }
    if !app.contains("store.startTracking()") {
        problems.append("② 覆盖层没有开始跟踪（`store.startTracking()`）：接上了也不动")
    }

    // ③ **面板不许出现**。用户 2026-10-02 的决定：「左下角那块电视面板压根儿不应该出现」
    //    —— 不自动显示、不常驻、也没有菜单入口。判据是挂载 / 显示标识符的**行级**扫描
    //    （不是"面板类型存在"）：一个都不许有。把面板加回来 ⇒ 这一条必须红。
    let panelHits = panelEntryPointHits(in: sources)
    if !panelHits.isEmpty {
        problems.append(
            "③ 产品路径里还有电视面板的挂载 / 显示入口 \(panelHits.count) 处："
                + panelHits.prefix(3).joined(separator: " | ")
        )
    }

    // ④ 覆盖层容器在**视图树**里。
    if !stage.contains("let screenOverlayContainer = WorldScreenOverlayContainer()") {
        problems.append("④ 舞台内容视图没有覆盖层容器")
    }
    // 容器**只在一处**进视图树，而且必须排在交互视图**之上**：AppKit 的 `hitTest` 只看
    // 子视图顺序、不看 `layer.zPosition`（2026-10-03 离线实测），所以"操作屏幕"模式要
    // 真的把点交给网页，这一句就不能停在容器自己的那段初始化里。
    // 覆盖层关着时 `hitTest` 恒 nil，顺序对场景没有任何影响。
    if !stage.contains(
        "addSubview(screenOverlayContainer, positioned: .above, relativeTo: worldInteractionView)"
    ) {
        problems.append(
            "④ 覆盖层容器没有加进视图树（`addSubview(screenOverlayContainer, positioned: .above,"
                + " relativeTo: worldInteractionView)`）：覆盖层无处可贴，或排在交互视图之下"
        )
    }
    if !stage.contains("var screenOverlayHostView: NSView") {
        problems.append("④ 没有把覆盖层宿主暴露给 App（`var screenOverlayHostView: NSView`）")
    }

    // ⑤ 接线在舞台窗口第一次出现的那条路上**有调用点**。类型齐全但没人调用 = 一行都不跑。
    if !app.contains("self?.installScreenOverlayIfNeeded()") {
        problems.append("⑤ `installScreenOverlayIfNeeded()` 没有调用点：编译得进、跑不起来")
    }

    // ⑥ 三条 agent 工具真的注册进本轮 lease。
    if !app.contains("control: WorldScreenControlRelay(") {
        problems.append(
            "⑥ 没有把控制面折成 `ResidentScreenTools(control: WorldScreenControlRelay(…))`"
        )
    }
    if !app.contains("+ screenTools") {
        problems.append(
            "⑥ `screenTools` 没有并进 `additionalTools`：play_screen / stop_screen / read_screen 对 agent 不可见"
        )
    }

    // ⑧ **三条工具不依赖覆盖层 / 宿主视图的时机**（真机 2026-10-03 的现场）。
    //
    // 缺陷形状：`screenStore.map { … } ?? []` —— store 只在
    // `installScreenOverlayIfNeeded()` 里建，而那条路要求舞台窗口已经出现过
    // （`StageWindowController.stageContentView != nil`）。于是"覆盖层有没有装好"这个
    // 纯画面时机决定了"agent 这一轮有没有 play_screen"：居民开机后的自主那一轮比人类
    // 打开空间窗口早 ⇒ 那一轮的清单里没有这三条；DSH 的会话清单是**建会话时**定的
    // （`ResidentDSHHostToolSet.parse(schemasJSON:)` 读那一刻的 schemasJSON），
    // 人类两分钟后说话时清单里仍然没有 ⇒ 居民只能答"我这轮没有能把视频投到屏幕上的能力"。
    //
    // 所以接线必须是"无条件构造一个转发器、真有调用进来时才去找 store"。
    // `tools/test-living-resident-loop.swift` 在同一条断言上做了**真编译**的复核：
    // 它在 `screenStore == nil` 的那一支下数 `makeResidentWorldTools` 的清单，
    // 退回时机依赖 ⇒ 那里少 3 条、红。
    // 只在**代码行**上找这个形状：注释里逐字引用这个缺陷形状是文档，不是接线。
    // （判据不看注释，也不许被注释骗过去。）
    let timingDependencyHits = app.components(separatedBy: .newlines).filter { line in
        !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && line.contains("screenStore.map {")
    }
    if !timingDependencyHits.isEmpty {
        problems.append(
            "⑧ 三条屏幕工具又挂回了 `screenStore` 的存在性上（`screenStore.map {`，代码行 "
                + "\(timingDependencyHits.count) 处）：覆盖层/宿主视图的时机一不成立，"
                + "这一轮的 lease 里就没有这三条工具"
        )
    }
    if !app.contains("let screenTools: [ResidentWorldToolSession.AdditionalTool] = ResidentScreenTools(") {
        problems.append("⑧ `screenTools` 不是**无条件**构造的（不是 `= ResidentScreenTools(…)`）")
    }
    if !app.contains("private func residentScreenControl()") {
        problems.append(
            "⑧ 没有 `residentScreenControl()`：control 必须在**调用那一刻**才去找 store / 补装覆盖层"
        )
    }

    // ⑨ 三条工具的 canonical 名只有一处定义（`ResidentScreenTools`）。
    for needle in ["static let playName = \"play_screen\"",
                   "static let stopName = \"stop_screen\"",
                   "static let readName = \"read_screen\""] {
        if !tools.contains(needle) {
            problems.append("⑨ 三条工具的 canonical 名不在 `ResidentScreenTools` 里：\(needle)")
        }
    }

    // ⑩ **屏幕功能点真的注册到物件上**：注册表从**物件状态**派生
    // （与覆盖层贴面读的是同一个 `WorldScreenResolution.resolve`），
    // 不依赖窗口、视图树、覆盖层。
    if !metadata.contains("enum WorldScreenCapabilityRegistry") {
        problems.append("⑩ 没有屏幕功能点的运行时注册表（`WorldScreenCapabilityRegistry`）")
    }
    if !metadata.contains("WorldScreenResolution.resolve(") {
        problems.append("⑩ 注册表没有走**唯一**那一份几何判据（`WorldScreenResolution.resolve`）")
    }
    if !metadata.contains("WorldScreenEligibility.isScreenCandidate(") {
        problems.append("⑩ 注册表没有走**唯一**那一份入场词法判据（`WorldScreenEligibility.isScreenCandidate`）")
    }
    if !metadata.contains("objectStates: [String: WorldObjectState]") {
        problems.append("⑩ 注册表的输入不是物件状态（读不出世界就又会挂回覆盖层的时机上）")
    }

    // ⑪ 那份注册结果**在物件描述里读得到**（`read_owned_props` 的 `screen` 那一行）。
    if !app.contains("screenCapability: { [weak self, weak context] objectID in") {
        problems.append("⑪ `read_owned_props` 的产地没有拿到屏幕功能点（没接 `screenCapability:`）")
    }
    if !bridge.contains("screenCapability: @escaping (String) -> ResidentPropScreenCapability?") {
        problems.append("⑪ 摆件工具桥没有屏幕功能点的注入点（桥自己不许判屏幕）")
    }
    if !bridge.contains("screen: screenCapability(objectID)") {
        problems.append("⑪ `read_owned_props` 没有把屏幕功能点算进每一件物件")
    }
    if !bridge.contains("result[\"screen\"] = screen.payload") {
        problems.append("⑪ 回执里没有写 `screen` 那一行：agent 读不到「它有屏幕、能播」")
    }

    // ⑫ 「纯外形摆件 / 无功能」那句必须跟着**事实**走：只要有物件真的有屏幕功能点，
    // 顶层 `interaction_status` 就不许再说 `appearance_only`。
    if !bridge.contains("$0[\"capability\"] != nil || $0[\"screen\"] != nil") {
        problems.append(
            "⑫ `interaction_status` 没有把屏幕功能点算进去：屋里摆着一台能播的电视时，"
                + "它照样说 `appearance_only`（真机 2026-10-03 居民就是读着它答出"
                + "「这台电视在空间里登记的是纯外形摆件」的）"
        )
    }

    // ⑬ **有屏幕才说能播**：回执那一行必须是条件写入，且没有任何"兜一份"的路径 ——
    // 判据是"注册表里有没有这一件"，不是"名字里像不像电视"。
    if !bridge.contains("if let screen {") {
        problems.append("⑬ `screen` 那一行不是条件写入的（没注册的物件也会被说成能播）")
    }
    for (label, text) in [("App", app), ("摆件工具桥", bridge)] {
        if text.contains("?? ResidentPropScreenCapability(") {
            problems.append("⑬ \(label) 里有一条「没注册也兜一份屏幕功能点」的路径：这就是夸口")
        }
    }
    if !app.contains("guard let capability = snapshot.registered.first(where: { $0.objectID == objectID })") {
        problems.append("⑬ 屏幕功能点不是从**这一件在注册表里**判出来的")
    }
    if !app.contains("residentScreenRegistrySnapshot()") {
        problems.append("⑬ 没有 `residentScreenRegistrySnapshot()`：注册表没有接到 App 这一侧")
    }
    // ⑦ 面板文件**保留**在仓库里（不许 rm），文件头写明它为什么不在产品界面里。
    let panelFile = appRoot.appendingPathComponent("Screen/ScreenPanel.swift")
    if let panel = try? read(panelFile) {
        if !panel.contains("已从产品界面移除（用户要求：左下角那块电视面板不应该出现）") {
            problems.append("⑦ 面板文件头的移除说明丢了（保留代码供将来用别的入口）")
        }
    } else {
        problems.append("⑦ 面板文件不见了：它是「保留但不再被产品调用」，不是删掉")
    }
    return problems
}

// ---------------------------------------------------------------------------
// MARK: 注入负对照（在源码副本上做手术）
// ---------------------------------------------------------------------------

enum ScreenWiringInjection: String, CaseIterable {
    /// 删掉安装覆盖层的那一次调用。
    case dropInstallCall
    /// **把面板的安装 / 显示调用点加回 App**（面板"又回来了"）。
    case restorePanelInstall
    /// **把面板挂载加回舞台内容视图**（面板对象又会被创建、又占布局）。
    case restorePanelMount
    /// 删掉「只接一次」的落点（store 不存下来 ⇒ 下一拍会再建一个）。
    case dropStoreAssignment
    /// 删掉跟踪启动。
    case dropTracking
    /// 删掉覆盖层容器进视图树。
    case dropOverlayHostSubview
    /// 删掉 agent 工具注册。
    case dropToolsRegistration
    /// 再插一个构造点（第二个事实源）。
    case duplicateConstructor
    /// **把三条工具退回"覆盖层/store 的存在性"这个时机依赖**（真机 2026-10-03 的缺陷形状）。
    case timingDependency
    /// **不注册屏幕功能点**：回执里不再写 `screen` 那一行。
    case dropScreenRegistration
    /// **描述仍写"无功能"**：不管有没有屏幕功能点，`interaction_status` 都还说 `appearance_only`。
    case appearanceOnlyAlways
    /// **无条件宣称能播**：没注册也兜一份屏幕功能点。
    case unconditionalScreenClaim

    func apply(to sources: inout ScreenWiringSources) {
        func drop(_ needle: String, from text: inout String) {
            text = text.replacingOccurrences(of: needle, with: "")
        }
        switch self {
        case .dropInstallCall:
            drop("                self?.installScreenOverlayIfNeeded()\n", from: &sources.app)
        case .restorePanelInstall:
            // 负对照的正身：用户要求拿掉的那两行。加回来 ⇒ 判据③必须红。
            sources.app += "\n        controller.installScreenPanel(store)\n"
                + "        controller.setScreenPanelVisible(true)\n"
        case .restorePanelMount:
            // 负对照：面板挂载（含创建面板对象的那一句）回到舞台内容视图 ⇒ 判据③必须红。
            sources.stage += "\n        let injectedPanelHost = NSHostingView(rootView: ScreenPanelView(\n"
                + "            store: injectedStore,\n"
                + "            onClose: nil\n"
                + "        ))\n"
                + "        injectedPanelHost.identifier = NSUserInterfaceItemIdentifier(\"stage.screen-panel\")\n"
        case .dropStoreAssignment:
            drop("        screenStore = store\n", from: &sources.app)
        case .dropTracking:
            drop("        store.startTracking()\n", from: &sources.app)
        case .dropOverlayHostSubview:
            drop(
                "        addSubview(screenOverlayContainer, positioned: .above,"
                    + " relativeTo: worldInteractionView)\n",
                from: &sources.stage
            )
        case .dropToolsRegistration:
            sources.app = sources.app.replacingOccurrences(of: " + screenTools,", with: ",")
        case .duplicateConstructor:
            // 文本级注入：只要**多一个构造点**，判据①就该红。
            sources.app += "\n// 注入负对照：第二个构造点\nlet injectedSecondScreenStore = WorldScreenStore(\n"
        case .timingDependency:
            // 文本级注入：把"无条件转发器"退回 store 的存在性上 —— 判据⑧必须红。
            // 刻意**保住** `control: WorldScreenControlRelay(` 那一行（否则先红的是判据⑥，
            // 证明不了⑧这一条真的会抓），只在前面插一条真正的时机守卫。
            // （不需要编得过：接线判据是文本级的，它回答的正是"接线长什么样"。）
            sources.app = sources.app.replacingOccurrences(
                of: "        let screenTools: [ResidentWorldToolSession.AdditionalTool] = ResidentScreenTools(",
                with: "        // 负对照：三条工具退回「store 存在才注册」\n"
                    + "        let injectedTimingGuard = screenStore.map { store in store }\n"
                    + "        let screenTools: [ResidentWorldToolSession.AdditionalTool] = ResidentScreenTools("
            )
        case .dropScreenRegistration:
            // 文本级注入：屏幕功能点不再出现在回执里 —— 判据⑪必须红。
            drop("result[\"screen\"] = screen.payload\n", from: &sources.bridge)
        case .appearanceOnlyAlways:
            // 文本级注入：有屏幕也还说"纯外形" —— 判据⑫必须红。
            sources.bridge = sources.bridge.replacingOccurrences(
                of: "$0[\"capability\"] != nil || $0[\"screen\"] != nil",
                with: "false"
            )
        case .unconditionalScreenClaim:
            // 文本级注入：没注册也兜一份屏幕功能点（夸口）—— 判据⑬必须红。
            sources.app = sources.app.replacingOccurrences(
                of: "guard let capability = snapshot.registered.first(where: { $0.objectID == objectID })",
                with: "let capability = snapshot.registered.first(where: { $0.objectID == objectID })"
                    + " ?? ResidentPropScreenCapability("
                    + "key: \"\", source: \"\", note: \"\", aspect: 0)"
            )
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: 跑
// ---------------------------------------------------------------------------

let pristine = try ScreenWiringSources.load()
var observed = pristine

// 现场演示：把真源码当成"接线被删掉"的那一份来判（见文件头）。
// 注入负对照那一圈仍从 `pristine` 出发，免得演示模式污染它们各自的结论。
if let name = ProcessInfo.processInfo.environment["SCREEN_WIRING_INJECT"],
   let injection = ScreenWiringInjection(rawValue: name) {
    print("·· SCREEN_WIRING_INJECT=\(name)：把真源码当成被注入过的那一份来判")
    injection.apply(to: &observed)
}

let problems = screenAppWiringProblems(observed)
for problem in problems { print("   · \(problem)") }
check(
    problems.isEmpty,
    "接线判据：App 侧唯一构造点 + 覆盖层接上舞台窗口 + 面板不出现 + 覆盖层容器在视图树里"
        + " + 三条工具注册且**不依赖覆盖层时机** + 屏幕功能点注册到物件上并在物件描述里读得到"
        + " + 有屏幕才说能播"
)

// 判据③的**全树**版本：只看真源码（含菜单 / 所有产品文件）。注入负对照走上面那个
// 纯函数判据（在内存副本上做手术），这一条负责回答"这棵树现在到底干不干净"。
let treePanelHits = productPanelEntryPoints()
for hit in treePanelHits { print("   · 面板痕迹 \(hit)") }
check(
    treePanelHits.isEmpty,
    "产品源码树里 0 处电视面板的挂载 / 显示入口（实测 \(treePanelHits.count) 处）"
)

for injection in ScreenWiringInjection.allCases {
    var injected = pristine
    injection.apply(to: &injected)
    check(injected != pristine, "注入负对照「\(injection.rawValue)」确实改到了源码副本")
    let injectedProblems = screenAppWiringProblems(injected)
    check(
        !injectedProblems.isEmpty,
        "注入负对照「\(injection.rawValue)」⇒ 判据必须变红（第一条：\(injectedProblems.first ?? "（没有）")）"
    )
}

print(failureCount == 0 ? "PASS 电视机接线判据全部通过" : "FAIL 电视机接线判据有 \(failureCount) 条不通过")
exit(failureCount == 0 ? 0 : 1)
