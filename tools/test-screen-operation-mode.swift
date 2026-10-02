// 「操作屏幕」：让用户**偶尔**能点网页里的按钮，而**默认绝不影响场景**。
//
// 真机 2026-10-03 的现场：电视能自动播了（播放参数改成站方口径），但覆盖层
// `hitTest` 恒 `nil` 是既有红线，于是**页面里一个按钮都点不到** —— Twitch 停在 ▶
// 就永远是 ▶。这一份 harness 钉的就是那件事的两半：
//
//   ① **默认关**：不进入这个模式时，覆盖层容器的 `hitTest` **恒 nil**（场景照旧拿点）；
//   ② **显式进入**：进入之后网页真的收得到点击（离屏：**合成了真的 mouseDown/mouseUp**，
//      页面按钮的 `click` 计数从 0 变 1），而场景那一下收不到了（指针链让路）；
//   ③ **退出立刻恢复**：同一条断言反向验证（计数不再涨、场景又拿到了点）；
//   ④ **裁决仍只有一处**：`ResidentPropEditorState.consumesScenePointer` 的签名与函数体
//      逐字不变、生产里仍只有一个调用点、场景的指针/键盘入口里一个字都没提这个模式。
//
// 手法沿袭仓里的离线 harness：
//   * 生产源码**原文**切片（不是在这里抄一份）；`WorldScreenOverlayContainer` 是
//     `productionDeclaration` 按花括号配对切出来的**那一份**，容器行为不是替身；
//   * 探针用 `/usr/bin/swiftc` 现编现跑：**不启动 App**、不碰 Metal、不碰网络
//     （页面是本地 HTML 字符串）；
//   * 窗口放在屏幕外（-2400, -2400），只为了让 WebKit 认为这一页在一个真的窗口里
//     —— 不在任何窗口里的离屏 WKWebView 连最简视频都不播（另一条线的量具陷阱）。
//   * 注入负对照在**源码副本**上做手术，真源码一个字节都不动。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let screenRoot = sourceRoot.appendingPathComponent("Screen")
let visualRoot = sourceRoot.appendingPathComponent("VisualEngine")

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

func occurrences(of needle: String, in text: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return text.components(separatedBy: needle).count - 1
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

func run(_ binary: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
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

// ---------------------------------------------------------------------------
// MARK: 断言 ④：指针裁决**只有一处**
// ---------------------------------------------------------------------------

/// 「场景的指针由谁裁决」的**唯一**判据。
///
/// 它要钉住的不是"模式开关存不存在"，而是**这个开关没有长出第二个判据点**：
///   * `ResidentPropEditorState.consumesScenePointer` 的**签名与函数体逐字不变**
///     （改签名 = 改那条红线的形状；改函数体 = 改 14 条链的语义）；
///   * 它在**生产**里只有一个调用点，而且那一次的实参逐字不变；
///   * 场景自己的指针/键盘入口里**一个字都不许提**这个模式（提了 = 场景开始自己判断
///     "是不是在操作屏幕"，那就是第二处判据）。
func scenePointerArbitrationVerdict(
    propEditor: String, controller: String
) -> [String] {
    var problems: [String] = []
    let declaration =
        "static func consumesScenePointer(isOpen: Bool, moving: Bool, inputOwnsFocus: Bool) -> Bool {"
    if !propEditor.contains(declaration) {
        problems.append("`consumesScenePointer` 的签名变了（唯一裁决点被动过）：\(declaration)")
    }
    if !propEditor.contains("        isOpen && moving && !inputOwnsFocus\n") {
        problems.append("`consumesScenePointer` 的函数体变了（`isOpen && moving && !inputOwnsFocus` 不再是它的全部语义）")
    }
    let callSites = occurrences(of: "ResidentPropEditorState.consumesScenePointer(", in: controller)
    if callSites != 1 {
        problems.append("生产里 `ResidentPropEditorState.consumesScenePointer(` 出现 \(callSites) 次，应**恰好 1 次**")
    }
    let gate = productionDeclaration("private var consumesPropPointer: Bool {", in: controller)
    if !gate.contains(
        "ResidentPropEditorState.consumesScenePointer(isOpen: propEditor.isOpen, "
            + "moving: propEditor.isCarrying || propEditor.isMoving,"
    ) || !gate.contains("inputOwnsFocus: inputOwnsFocus)") {
        problems.append("门禁那一次的实参变了（多一个输入就是多一处判据）")
    }
    let entries: [(String, String)] = [
        ("consumesPropPointer", gate),
        ("mouseDown", productionDeclaration("override func mouseDown(with event: NSEvent) {", in: controller)),
        ("mouseUp", productionDeclaration("override func mouseUp(with event: NSEvent) {", in: controller)),
        ("rightMouseUp", productionDeclaration("override func rightMouseUp(with event: NSEvent) {", in: controller)),
        ("mouseMoved", productionDeclaration("override func mouseMoved(with event: NSEvent) {", in: controller)),
        ("keyDown", productionDeclaration("override func keyDown(with event: NSEvent) {", in: controller)),
    ]
    for (label, body) in entries {
        for token in ["acceptsScreenPointer", "isOperatingScreen", "screenOperation"] where body.contains(token) {
            problems.append(
                "场景入口「\(label)」里提到了「\(token)」：场景开始自己判断「是不是在操作屏幕」，"
                    + "这就是第二处判据（唯一裁决点必须是 `consumesScenePointer`）"
            )
        }
    }
    return problems
}

// ---------------------------------------------------------------------------
// MARK: 断言 ①（文本）：默认关 + 只在一处改开关
// ---------------------------------------------------------------------------

/// 「这个覆盖层默认会不会抢场景鼠标」的**唯一**文本判据（容器**行为**由下面那个
/// 真编起来跑的探针钉，这一条只管"形状"：默认值、闸门、以及开关只有一处写）。
func screenOperationPointerVerdict(_ source: String) -> [String] {
    var problems: [String] = []
    if !source.contains("var acceptsScreenPointer = false") {
        problems.append("容器的「操作屏幕」开关不是**默认关闭**（`var acceptsScreenPointer = false`）")
    }
    if !source.contains("guard acceptsScreenPointer else { return nil }") {
        problems.append("容器没有 `guard acceptsScreenPointer else { return nil }`：默认不吃事件这件事没有唯一声明处")
    }
    if !source.contains("return super.hitTest(point)") {
        problems.append("容器进入模式后没有把点交给子树（`return super.hitTest(point)`）：网页收不到点击")
    }
    // 唯一写入点：开关的每一次赋值都必须在 `setScreenOperation` 里。
    let writes = occurrences(of: ".acceptsScreenPointer = ", in: source)
    if writes != 2 {
        problems.append(
            "`acceptsScreenPointer` 的赋值有 \(writes) 处，应恰好 2 处"
                + "（一处在 `setScreenOperation` 里统一改，一处在新建屏幕时跟上当前模式）"
        )
    }
    for token in [
        "override func mouseDown", "override func mouseDragged", "override func mouseUp",
        "override func rightMouseDown", "override func rightMouseUp", "override func mouseMoved",
        "override func scrollWheel", "override func acceptsFirstMouse",
        "override func magnify", "override func keyDown",
    ] where source.contains(token) {
        problems.append("覆盖层覆写了指针/键盘入口「\(token)」：它会与场景的 14 条输入链抢事件")
    }
    return problems
}

// ---------------------------------------------------------------------------
// MARK: 读生产源码
// ---------------------------------------------------------------------------

let overlaySource = try read(screenRoot.appendingPathComponent("WorldScreenOverlayController.swift"))
let propEditorSource = try read(sourceRoot.appendingPathComponent("Presence/ResidentPropEditorState.swift"))
let controllerSource = try read(visualRoot.appendingPathComponent("StageWindowController.swift"))

let pointerProblems = screenOperationPointerVerdict(overlaySource)
check(
    pointerProblems.isEmpty,
    "断言①：覆盖层的「操作屏幕」开关**默认关**、关着时 `hitTest` 恒 nil、进入后才把点交给网页"
        + (pointerProblems.isEmpty ? "" : " —— \(pointerProblems.joined(separator: "；"))")
)

// 注入①：默认改成开 ⇒ 必须红（"默认绝不影响场景"最直接的负对照）。
let injectedDefaultOn = overlaySource.replacingOccurrences(
    of: "var acceptsScreenPointer = false", with: "var acceptsScreenPointer = true"
)
check(injectedDefaultOn != overlaySource, "断言①（注入负对照）：开关的默认值确实被从 `false` 改成了 `true`")
let injectedDefaultOnProblems = screenOperationPointerVerdict(injectedDefaultOn)
check(
    !injectedDefaultOnProblems.isEmpty,
    "断言①（注入负对照「默认就是开」）：判据 FAIL。原话："
        + injectedDefaultOnProblems.joined(separator: "；")
)

// 注入②：去掉那道闸（照常命中）⇒ 必须红。
let injectedAlwaysHit = overlaySource.replacingOccurrences(
    of: "        guard acceptsScreenPointer else { return nil }\n", with: ""
)
check(injectedAlwaysHit != overlaySource, "断言①（注入负对照）：`guard acceptsScreenPointer else { return nil }` 确实被拿掉了")
let injectedAlwaysHitProblems = screenOperationPointerVerdict(injectedAlwaysHit)
check(
    !injectedAlwaysHitProblems.isEmpty,
    "断言①（注入负对照「照常命中」）：判据 FAIL。原话："
        + injectedAlwaysHitProblems.joined(separator: "；")
)

// 注入③：进了模式也不给点（hitTest 恒 nil）⇒ 必须红。
let injectedNeverDelivers = overlaySource.replacingOccurrences(
    of: "        return super.hitTest(point)\n", with: "        return nil\n"
)
check(injectedNeverDelivers != overlaySource, "断言①（注入负对照）：`return super.hitTest(point)` 确实被换成了 `return nil`")
let injectedNeverDeliversProblems = screenOperationPointerVerdict(injectedNeverDelivers)
check(
    !injectedNeverDeliversProblems.isEmpty,
    "断言①（注入负对照「进了模式也不给点」）：判据 FAIL。原话："
        + injectedNeverDeliversProblems.joined(separator: "；")
)

// 注入④：在第二处改开关（绕过 `setScreenOperation`）⇒ 必须红。
let injectedSecondWriter = overlaySource.replacingOccurrences(
    of: "    init(hostView: NSView) {",
    with: "    func forcePointerForTesting() { for surface in surfaces.values { surface.container.acceptsScreenPointer = true } }\n\n    init(hostView: NSView) {"
)
check(injectedSecondWriter != overlaySource, "断言①（注入负对照）：第二处 `acceptsScreenPointer` 赋值确实被塞进了副本")
let injectedSecondWriterProblems = screenOperationPointerVerdict(injectedSecondWriter)
check(
    !injectedSecondWriterProblems.isEmpty,
    "断言①（注入负对照「第二处写开关」）：判据 FAIL。原话："
        + injectedSecondWriterProblems.joined(separator: "；")
)

// ---------------------------------------------------------------------------
// MARK: 断言 ④：判据 + 两处注入（另造第二处判据 ⇒ FAIL）
// ---------------------------------------------------------------------------

let arbitrationProblems = scenePointerArbitrationVerdict(
    propEditor: propEditorSource, controller: controllerSource
)
check(
    arbitrationProblems.isEmpty,
    "断言④：指针裁决仍**只有一处**（`consumesScenePointer` 的签名与函数体逐字未变、"
        + "生产里只有一个调用点、场景入口一个字都没提这个模式）"
        + (arbitrationProblems.isEmpty ? "" : " —— \(arbitrationProblems.joined(separator: "；"))")
)

// 注入⑤：**再插一个调用点**（第二处判据）⇒ 必须红。
let injectedSecondGate = controllerSource
    + "\n// 注入负对照：第二处判据\nlet injectedSecondGate = "
    + "ResidentPropEditorState.consumesScenePointer(isOpen: true, moving: true, inputOwnsFocus: true)\n"
let injectedSecondGateProblems = scenePointerArbitrationVerdict(
    propEditor: propEditorSource, controller: injectedSecondGate
)
check(
    !injectedSecondGateProblems.isEmpty,
    "断言④（注入负对照「另造一处判据」）：判据 FAIL。原话："
        + injectedSecondGateProblems.joined(separator: "；")
)

// 注入⑥：把"操作屏幕"那条判断塞进场景的 mouseDown ⇒ 必须红。
let injectedSceneBranch = controllerSource.replacingOccurrences(
    of: "    override func mouseDown(with event: NSEvent) {",
    with: "    override func mouseDown(with event: NSEvent) {\n        if isOperatingScreen { return }"
)
check(injectedSceneBranch != controllerSource, "断言④（注入负对照）：场景 mouseDown 里的模式分支确实被塞进了副本")
let injectedSceneBranchProblems = scenePointerArbitrationVerdict(
    propEditor: propEditorSource, controller: injectedSceneBranch
)
check(
    !injectedSceneBranchProblems.isEmpty,
    "断言④（注入负对照「场景自己判断」）：判据 FAIL。原话："
        + injectedSceneBranchProblems.joined(separator: "；")
)

// 注入⑦：给唯一裁决点加第四个输入 ⇒ 必须红。
let injectedFourthInput = propEditorSource.replacingOccurrences(
    of: "static func consumesScenePointer(isOpen: Bool, moving: Bool, inputOwnsFocus: Bool) -> Bool {",
    with: "static func consumesScenePointer(isOpen: Bool, moving: Bool, inputOwnsFocus: Bool, operatingScreen: Bool) -> Bool {"
)
check(injectedFourthInput != propEditorSource, "断言④（注入负对照）：第四個输入确实被塞进了 `consumesScenePointer`")
let injectedFourthInputProblems = scenePointerArbitrationVerdict(
    propEditor: injectedFourthInput, controller: controllerSource
)
check(
    !injectedFourthInputProblems.isEmpty,
    "断言④（注入负对照「给裁决点加输入」）：判据 FAIL。原话："
        + injectedFourthInputProblems.joined(separator: "；")
)

// ---------------------------------------------------------------------------
// MARK: 断言 ②③：离屏探针 —— 真的合成一次点击
// ---------------------------------------------------------------------------

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-screen-operation-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

/// **生产那一份容器**（原文切片）。
let containerDeclaration = productionDeclaration(
    "@MainActor\nfinal class WorldScreenOverlayContainer: NSView {", in: overlaySource
)
check(
    containerDeclaration.contains("var acceptsScreenPointer = false")
        && containerDeclaration.contains("guard acceptsScreenPointer else { return nil }"),
    "断言②：探针切到的是生产那一份容器（默认关 + 关着时不吃事件）"
)

let probeProgram = ##"""
import AppKit
import WebKit

var probeFailures = 0
func probeCheck(_ condition: Bool, _ message: String) {
    if condition {
        print("PROBE-PASS \(message)")
    } else {
        print("PROBE-FAIL \(message)")
        probeFailures += 1
    }
}

// __CONTAINER_DECLARATION__

/// 场景那一侧的替身：它只回答"这个点有没有落到我身上" —— 生产里是
/// `StageWorldInteractionView` 的 hitTest 守卫（`场景输入链[3]`，逐字未改）。
final class ScenePointerProbeView: NSView {
    var mouseDownCount = 0
    override func mouseDown(with event: NSEvent) { mouseDownCount += 1 }
}

final class NavigationProbe: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}

let probeHTML = """
<!doctype html><html><head><meta charset="utf-8"><title>gmgn-screen-operation-probe</title>
<style>html,body{margin:0;height:100%;background:#123}
#target{position:absolute;left:40px;top:40px;width:200px;height:80px;font-size:20px}</style>
</head><body>
<button id="target">按我</button>
<script>
window.__clicks = 0;
document.getElementById('target').addEventListener('click', function () { window.__clicks += 1; });
window.__readClicks = function () { return window.__clicks; };
</script>
</body></html>
"""

// 整段现场都跑在**主线程的 actor 上下文**里：`WorldScreenOverlayContainer` 与 AppKit
// 都是 `@MainActor` 的（`main.swift` 的顶层代码在 Swift 5 模式下**不是**自动隔离的，
// 所以这里显式声明一次）。
MainActor.assumeIsolated {
    func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let width: CGFloat = 400
    let height: CGFloat = 300
    let window = NSWindow(
        contentRect: NSRect(x: -2400, y: -2400, width: width, height: height),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false

    let rootView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    window.contentView = rootView

    let scene = ScenePointerProbeView(frame: rootView.bounds)
    scene.autoresizingMask = [.width, .height]
    rootView.addSubview(scene)

    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    let container = WorldScreenOverlayContainer(frame: rootView.bounds)
    container.autoresizingMask = [.width, .height]
    container.wantsLayer = true
    container.addSubview(webView)
    // 与生产同序：覆盖层排在交互视图**之上**（`StageContentView` 里那一句
    // `addSubview(_:positioned:.above,relativeTo:)`）。AppKit 的 hitTest 只看子视图顺序。
    rootView.addSubview(container, positioned: .above, relativeTo: scene)

    window.orderFrontRegardless()

    let navigation = NavigationProbe()
    webView.navigationDelegate = navigation
    webView.loadHTMLString(probeHTML, baseURL: nil)

    let loadDeadline = Date().addingTimeInterval(10)
    while !navigation.finished && Date() < loadDeadline { pump(0.1) }
    probeCheck(navigation.finished, "屏幕外的窗口里，探针页载入了")
    pump(0.3)

    /// 与系统派发同一条路：先由 `hitTest` 决定"这个点归谁"（AppKit 的唯一裁决），
    /// 再把事件交给那个视图。
    func click(at point: NSPoint) -> NSView? {
        guard let target = rootView.hitTest(point) else { return nil }
        let windowPoint = rootView.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, NSEvent.EventType.leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: windowPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1
            ) else { continue }
            if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
        }
        return target
    }

    func webClicks() -> Int {
        var value = -1
        var done = false
        webView.evaluateJavaScript("window.__readClicks()") { result, _ in
            if let number = result as? NSNumber { value = number.intValue }
            done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !done && Date() < deadline { pump(0.05) }
        return value
    }

    func hitName(_ view: NSView?) -> String {
        guard let view else { return "nil" }
        if view === scene { return "场景视图" }
        if view.isDescendant(of: container) { return "覆盖层子树(\(type(of: view)))" }
        return String(describing: type(of: view))
    }

    // 网页里的按钮：CSS 左上原点 (40,40)–(240,120) ⇒ 视图坐标（左下原点）中心 (140, 220)。
    let buttonPoint = NSPoint(x: 140, y: 220)

    // 步骤 1：默认（开关关着）。
    probeCheck(container.acceptsScreenPointer == false, "默认：容器的「操作屏幕」开关是关的")
    let hitDefault = rootView.hitTest(buttonPoint)
    probeCheck(hitDefault === scene, "默认：这个点归场景（hitTest = \(hitName(hitDefault))）")
    _ = click(at: buttonPoint)
    pump(0.5)
    probeCheck(scene.mouseDownCount == 1, "默认：场景收到了这一下（实测 \(scene.mouseDownCount)）")
    let clicksDefault = webClicks()
    probeCheck(clicksDefault == 0, "默认：网页收到 0 次点击（实测 \(clicksDefault)）")

    // 步骤 2：进入「操作屏幕」。
    container.acceptsScreenPointer = true
    let hitActive = rootView.hitTest(buttonPoint)
    probeCheck(
        hitActive !== scene && (hitActive?.isDescendant(of: container) ?? false),
        "进入后：这个点归覆盖层/网页（hitTest = \(hitName(hitActive))）"
    )
    _ = click(at: buttonPoint)
    pump(0.8)
    let clicksActive = webClicks()
    probeCheck(clicksActive == 1, "进入后：网页收到了这一下（window.__clicks 0 → 1，实测 \(clicksActive)）")
    probeCheck(scene.mouseDownCount == 1, "进入后：场景**没有**再收到（指针链让路，实测 \(scene.mouseDownCount)）")

    // 步骤 3：退出（同一个开关置回 false —— Esc 走的就是这一步）。
    container.acceptsScreenPointer = false
    let hitRestored = rootView.hitTest(buttonPoint)
    probeCheck(hitRestored === scene, "退出后立刻恢复：这个点又归场景（hitTest = \(hitName(hitRestored))）")
    _ = click(at: buttonPoint)
    pump(0.5)
    probeCheck(scene.mouseDownCount == 2, "退出后：场景又收到了（实测 \(scene.mouseDownCount)）")
    let clicksRestored = webClicks()
    probeCheck(clicksRestored == 1, "退出后：网页不再收到新的点击（实测 \(clicksRestored)）")
}

print(probeFailures == 0 ? "PROBE-FAILURES=0" : "PROBE-FAILURES=\(probeFailures)")
exit(probeFailures == 0 ? 0 : 1)
"""##.replacingOccurrences(of: "// __CONTAINER_DECLARATION__", with: containerDeclaration)

let probeSource = temporary.appendingPathComponent("main.swift")
try probeProgram.write(to: probeSource, atomically: true, encoding: .utf8)
let probeBinary = temporary.appendingPathComponent("probe")
let compiled = try run("/usr/bin/swiftc", [probeSource.path, "-o", probeBinary.path])
guard compiled.status == 0 else {
    for line in compiled.output.split(separator: "\n").prefix(40) {
        print("   · [探针编译] \(line)")
    }
    check(false, "断言②③：离屏点击探针没编起来（exit \(compiled.status)）")
    print(failureCount == 0 ? "PASS 操作屏幕判据全部通过" : "FAIL 操作屏幕判据有 \(failureCount) 条不通过")
    exit(failureCount == 0 ? 0 : 1)
}

let executed = try run(probeBinary.path, [])
for line in executed.output.split(separator: "\n") where !line.isEmpty {
    print("   · [探针] \(line)")
}
check(
    executed.status == 0,
    "断言②③：屏幕外的真窗口里，**默认点不到网页 → 进入后网页收到点击、场景收不到 → "
        + "退出后立刻恢复**（探针 exit \(executed.status)）"
)

print(failureCount == 0 ? "PASS 操作屏幕判据全部通过" : "FAIL 操作屏幕判据有 \(failureCount) 条不通过")
exit(failureCount == 0 ? 0 : 1)
