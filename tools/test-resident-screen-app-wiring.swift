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
//
// 判据是文本级的，因为它要回答的正是"接线在不在"；每一条都配**注入负对照** ——
// 在源码副本上做手术（删掉那一行 / 把面板加回来），判据必须变红。
// 一个从不 FAIL 的门禁等于没有门禁。
//
// 现场演示：`SCREEN_WIRING_INJECT=dropInstallCall swift tools/test-resident-screen-app-wiring.swift`
// 会把**真源码**当成"接线被删掉"的那一份来判，于是主判据自己打出一条 FAIL。
// 面板那一条的现场：`SCREEN_WIRING_INJECT=restorePanelInstall …`（面板又回来了 ⇒ FAIL）。
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

/// 判据只看这两份 App 侧源码。`Screen/**` 内部逻辑（遮挡 / 选面那一条线）不在范围内 ——
/// 接线判据只回答"有没有接上"，不回答"接上之后对不对"。
struct ScreenWiringSources: Equatable {
    /// `App/GMGNRadioApp.swift`
    var app: String
    /// `VisualEngine/StageWindowController.swift`
    var stage: String

    static func load() throws -> ScreenWiringSources {
        ScreenWiringSources(
            app: try read(appRoot.appendingPathComponent("App/GMGNRadioApp.swift")),
            stage: try read(appRoot.appendingPathComponent("VisualEngine/StageWindowController.swift"))
        )
    }
}

/// 「电视接线在不在」的**唯一**判据。空数组 = 接线完整。
func screenAppWiringProblems(_ sources: ScreenWiringSources) -> [String] {
    var problems: [String] = []
    let app = sources.app
    let stage = sources.stage

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
    if !stage.contains("addSubview(screenOverlayContainer)") {
        problems.append("④ 覆盖层容器没有加进视图树（`addSubview(screenOverlayContainer)`）：覆盖层无处可贴")
    }
    if !stage.contains("var screenOverlayHostView: NSView") {
        problems.append("④ 没有把覆盖层宿主暴露给 App（`var screenOverlayHostView: NSView`）")
    }

    // ⑤ 接线在舞台窗口第一次出现的那条路上**有调用点**。类型齐全但没人调用 = 一行都不跑。
    if !app.contains("self?.installScreenOverlayIfNeeded()") {
        problems.append("⑤ `installScreenOverlayIfNeeded()` 没有调用点：编译得进、跑不起来")
    }

    // ⑥ 三条 agent 工具真的注册进本轮 lease。
    if !app.contains("ResidentScreenTools(control: store, isCurrent: isCurrent)") {
        problems.append("⑥ 没有把 store 折成 `ResidentScreenTools`")
    }
    if !app.contains("+ screenTools") {
        problems.append(
            "⑥ `screenTools` 没有并进 `additionalTools`：play_screen / stop_screen / read_screen 对 agent 不可见"
        )
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
            drop("        addSubview(screenOverlayContainer)\n", from: &sources.stage)
        case .dropToolsRegistration:
            sources.app = sources.app.replacingOccurrences(of: " + screenTools,", with: ",")
        case .duplicateConstructor:
            // 文本级注入：只要**多一个构造点**，判据①就该红。
            sources.app += "\n// 注入负对照：第二个构造点\nlet injectedSecondScreenStore = WorldScreenStore(\n"
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
    "接线判据：App 侧唯一构造点 + 覆盖层接上舞台窗口 + 面板不出现 + 覆盖层容器在视图树里 + 三条工具注册"
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
