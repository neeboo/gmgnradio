import AppKit
import os
import os.signpost
@preconcurrency import WebKit

/// 覆盖层每帧的账去这里（Instruments 里按 interval 看得到每一项）。
///
/// 与 `WorldScreenStore` 的 `screenPanelLogger` 同一 subsystem：电视这条线的工程细节
/// 只有一处出口。
private let overlaySignposter = OSSignposter(
    subsystem: "ai.gmgn.radio", category: .pointsOfInterest
)

// MARK: - 覆盖层宿主：默认**不吃任何指针事件**

/// 覆盖层的容器视图。
///
/// **默认关着**：`hitTest` 恒返回 `nil` —— 这个视图与它的整棵子树（包括 `WKWebView`）
/// **永远收不到**任何鼠标事件。这是"不抢场景鼠标"这条红线的**唯一**实现点，所以它只有一处。
///
/// 唯一能让它开始接事件的动作是**用户显式进入「操作屏幕」模式**
/// （`WorldScreenOverlayController.setScreenOperation(_:)`），此时 `acceptsScreenPointer`
/// 被置位、`hitTest` 才走 `super`，点击落到网页里；`Esc`（或再点一次那个开关）立刻退出。
/// 开关本身是**一个显式输入**，不是"看情况自动判断"—— 默认值就是关，所以不进入这个模式时
/// 覆盖层的行为与它出现之前逐字相同。
///
/// 为什么不在这里覆写 `mouseDown` / `keyDown` 这些入口：那会绕开场景的 14 条
/// `场景输入链[N]`（`tools/test-resident-screen-overlay.swift` 的断言 3 逐字钉着
/// "一个指针/键盘入口都不许有"）。这里只回答**一个**问题——"这个点是不是网页的？"——
/// 而这个问题在场景那一侧早就有唯一答案：`StageWorldInteractionView.mouseMoved` 的
/// hitTest 守卫（`场景输入链[3]`）本来就是为"上面有别的视图"写的。于是场景的指针链
/// 让路**不需要第二处判据**，`consumesScenePointer` 的签名、调用点与语义一个字都不动。
@MainActor
final class WorldScreenOverlayContainer: NSView {
    /// 「操作屏幕」模式的开关。**默认关闭**（`false` ⇒ `hitTest` 恒 `nil`）。
    var acceptsScreenPointer = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsScreenPointer else { return nil }
        return super.hitTest(point)
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - 一块屏幕

/// 一块屏幕 = 一个容器视图 + 一个 `WKWebView`。
///
/// 内容用 `WKWebsiteDataStore.default()`：用户在**这个 web 视图里自己登录**之后，
/// 会话由 WebKit 自己保持。我们**不读 cookie、不导出、不代持**任何凭据，
/// 也不为任何站点伪造 UA。
@MainActor
final class WorldScreenSurface: NSObject, WKNavigationDelegate {
    /// 页面没在 20 秒内 `didFinish` 就是失败 —— "一直转圈"不是一种状态。
    static let loadTimeout: Duration = .seconds(20)

    let objectID: String
    let container = WorldScreenOverlayContainer()
    let webView: WKWebView
    private(set) var state: WorldScreenSurfaceState = .idle
    /// 最近一次请求的官方嵌入 URL（`stop` 之后仍然读得到"上次放的是什么"）。
    private(set) var requestedURL: String?
    /// 几何缺失/无法定位时的具名原因（由宿主写；`nil` = 几何正常）。
    var geometryIssue: WorldScreenGeometryIssue?
    /// 本帧的遮挡掩码（`nil` = 还没算过 / 不算）。`isFullyVisible` 时**不挂掩码**。
    private(set) var occlusionMask: WorldScreenOcclusionMask?
    /// 最近一次掩码更新的耗时（诊断/回执用）。
    private(set) var lastOcclusionCost: Duration?
    /// 最近一次掩码落到图层上的账（路径构造 / 图层赋值）。
    private(set) var lastMaskCost = WorldScreenMaskCost()
    /// 最近一次真的写进容器的落位与变换。相同就**一个字节都不写**。
    var appliedFrameOrigin: CGPoint?
    var appliedFrameSize: CGSize?
    var appliedTransform: WorldScreenLayerTransform?
    private var occlusionMaskLayer: CAShapeLayer?
    var onStateChange: (@MainActor (WorldScreenSurfaceState) -> Void)?
    private var watchdog: Task<Void, Never>?
    /// 页面**侧**那一路的观察者（播放器自己报的错）。与 `watchdog` 分开：那一条管
    /// "页面有没有载进来"，这一条管"载进来了但播放器不肯放"。
    private var playerWatch: Task<Void, Never>?
    /// 承载这一页的那个**来源文档**的 origin（`nil` = 没在放）。只用于诊断/回执，
    /// 不是判据。
    private(set) var embeddingOrigin: String?
    private var isMediaSuspended = false

    override init() {
        fatalError("使用 init(objectID:)")
    }

    init(objectID: String) {
        self.objectID = objectID
        let configuration = WKWebViewConfiguration()
        // 默认数据存储：登录态是**用户自己**在这个视图里建的，我们只让它留在 WebKit 自己手里。
        configuration.websiteDataStore = .default()
        configuration.allowsAirPlayForMediaPlayback = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        // **不是纯黑**：这块 web 视图在"还没放东西"时就是用户看到的屏幕面。纯黑在画面里
        // 是一个洞（真机 2026-10-02「灰板 + 一个大的黑色矩形」），而关着的屏幕是一块
        // **深灰偏黑、带一点点反光**的玻璃。这里与 GLB 的
        // `WorldPrimitiveTelevisionFinish.screen.baseColor` 取同一个观感，两处不能各说一套。
        webView.underPageBackgroundColor = Self.idleScreenBackground
        webView.allowsBackForwardNavigationGestures = false
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        // 容器是**不吃事件**的；webView 作为子视图也因此收不到任何指针事件
        // （`WorldScreenOverlayContainer.hitTest` 恒 nil）。
    }

    /// 把"被更近的东西挡住"的那一部分**按区域裁掉**。
    ///
    /// 这是覆盖层"不参与深度测试"这个结构性缺口的**唯一**补法（另一条路是让覆盖层进
    /// 渲染管线当纹理 —— 那要动 shader，是红线）。用的是 `CALayer.mask`：
    ///
    /// - **没被挡 ⇒ 直接摘掉掩码**（`mask = nil`）：正常观看时零裁切、零风险、零开销，
    ///   这同时就是"无人遮挡时不闪烁"的实现方式 —— 没有掩码就没有边界可以抖；
    /// - **被挡一部分 ⇒ 只裁被挡的那些格**：路径是**可见格**的并集，于是"人挡住左半边"
    ///   是左半边不画、右半边照画（**区域级**），而不是整块开关；
    /// - 路径写在容器**自己**的 bounds 坐标系里，跟着 `container.layer.transform`
    ///   一起被投到屏幕四边形上 —— 与画面同一条变换，不可能与几何错位。
    ///
    /// - Parameter mask: `nil` 或全可见时摘掉掩码。
    ///
    /// **同一张掩码 ⇒ 一个字节都不写。** `visibleRects` 的并集、`CGPath` 的构造与
    /// `CAShapeLayer` 的每一次赋值都不是免费的，而它们**只**取决于掩码本身：
    /// 掩码没变就没有任何理由重做。这条判据由 `lastMaskCost.didRebuildPath` 记账，
    /// 判据（`tools/test-resident-screen-overlay.swift` 断言9）直接断言它。
    func applyOcclusion(_ mask: WorldScreenOcclusionMask?, cost: Duration?) {
        let previous = occlusionMask
        occlusionMask = mask
        lastOcclusionCost = cost
        lastMaskCost = WorldScreenMaskCost()
        let bounds = container.bounds
        let size = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        guard let mask, !mask.isFullyVisible, size.x > 0, size.y > 0 else {
            // 没被挡 ⇒ 直接摘掉掩码（没有掩码就没有边界可以抖，也没有离屏合成的开销）。
            guard occlusionMaskLayer != nil else { return }
            let start = CFAbsoluteTimeGetCurrent()
            occlusionMaskLayer?.path = nil
            container.layer?.mask = nil
            occlusionMaskLayer = nil
            lastMaskCost.assign = CFAbsoluteTimeGetCurrent() - start
            return
        }
        // 同一张掩码、掩码图层的落位也没变 ⇒ 不重建路径、不碰图层。
        if mask == previous, let existing = occlusionMaskLayer, existing.frame == bounds {
            return
        }
        let layer: CAShapeLayer
        if let existing = occlusionMaskLayer {
            layer = existing
        } else {
            let created = CAShapeLayer()
            // 纯灰白而不是 `NSColor.white`：掩码要的是 alpha，动态颜色在这里没有意义。
            created.fillColor = CGColor(gray: 1, alpha: 1)
            created.fillRule = .nonZero
            container.layer?.mask = created
            occlusionMaskLayer = created
            layer = created
        }
        let pathStart = CFAbsoluteTimeGetCurrent()
        let path = CGMutablePath()
        for rect in mask.visibleRects(in: size) {
            path.addRect(
                CGRect(
                    x: CGFloat(rect.x), y: CGFloat(rect.y),
                    width: CGFloat(rect.width), height: CGFloat(rect.height)
                )
            )
        }
        var measured = WorldScreenMaskCost()
        measured.pathBuild = CFAbsoluteTimeGetCurrent() - pathStart
        measured.didRebuildPath = true
        let assignStart = CFAbsoluteTimeGetCurrent()
        layer.frame = bounds
        layer.path = path
        measured.assign = CFAbsoluteTimeGetCurrent() - assignStart
        lastMaskCost = measured
    }

    // MARK: 控制

    /// 载入一个**已经过白名单校验**的官方嵌入 URL。
    ///
    /// 官方嵌入页**不许被顶层直载**：顶层直载时它没有"嵌它的那个文档"，播放器会报
    /// 153（Twitch 报 `NoParent`）。所以这里不 `webView.load(URLRequest(url:))`，
    /// 而是把同一个官方嵌入 URL 放进一份**有合法 http(s) origin 的承载页**里
    /// （`WorldScreenEmbedOrigin`：回环 + 随机端口 + **不开任何监听套接字**）。
    /// 白名单、主机、路径、视频 id 一个字节都没动 —— 变的是"谁来嵌它"。
    func load(url: URL) {
        requestedURL = url.absoluteString
        geometryIssue = nil
        transition(to: .loading(url: url.absoluteString))
        resumeMediaIfNeeded()
        let port = WorldScreenEmbedOrigin.randomPort()
        let origin = WorldScreenEmbedOrigin.originString(port: port)
        guard WorldScreenEmbedOrigin.isLegalEmbeddingOrigin(origin),
              let baseURL = WorldScreenEmbedOrigin.baseURL(port: port)
        else {
            transition(to: .failed(.blocked("构造不出合法的承载来源")))
            return
        }
        embeddingOrigin = origin
        webView.loadHTMLString(
            WorldScreenEmbedPage.html(embedURL: url.absoluteString, origin: origin),
            baseURL: baseURL
        )
        startWatchdog()
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        playerWatch?.cancel()
        playerWatch = nil
        embeddingOrigin = nil
        webView.stopLoading()
        webView.loadHTMLString(Self.blankPage, baseURL: nil)
        suspendMedia()
        transition(to: .stopped)
    }

    /// 看不见的时候**暂停**（不是销毁）：回来不掉登录态，也不白烧解码与网络。
    func suspendMedia() {
        guard !isMediaSuspended else { return }
        isMediaSuspended = true
        webView.pauseAllMediaPlayback(completionHandler: nil)
    }

    func resumeMediaIfNeeded() {
        guard isMediaSuspended else { return }
        isMediaSuspended = false
        webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
    }

    /// 应用一个具名几何问题（面板/工具据此报"这台电视还没有屏幕"）。
    func noteGeometryIssue(_ issue: WorldScreenGeometryIssue) {
        geometryIssue = issue
        transition(to: .failed(.blocked(issue.errorDescription)))
    }

    private func transition(to next: WorldScreenSurfaceState) {
        guard state != next else { return }
        state = next
        onStateChange?(next)
    }

    /// 页面**载进来之后**，继续看播放器自己报什么。
    ///
    /// 为什么必须有这一条：真机 2026-10-02 那块屏幕是 `didFinish` **成功**的
    /// —— 官方播放器的错误界面本身就是一张正常的网页 —— 于是状态一路变成 `playing`，
    /// 用户在"播放中"的屏幕上看着「错误 153」，而面板/居民那边一律说"放起来了"。
    /// 加载成功 != 放得出来，这两件事必须分开报。
    ///
    /// 读的是**承载页自己**的 `document.title`（我们那一页把播放器的 postMessage 转写好
    /// 放在那儿）：跨域 iframe 的内部读不到，也不该去读。
    private func startPlayerWatch() {
        playerWatch?.cancel()
        playerWatch = Task { @MainActor [weak self] in
            for _ in 0..<Self.playerWatchAttempts {
                try? await Task.sleep(for: Self.playerWatchInterval)
                guard !Task.isCancelled, let self, self.state.isPlaying else { return }
                let raw = try? await self.webView.evaluateJavaScript(
                    WorldScreenEmbedPage.probeScript
                )
                guard let json = raw as? String,
                      let diagnosis = WorldScreenPlayerDiagnosis.parse(probeJSON: json),
                      let failure = diagnosis.failure
                else { continue }
                self.transition(to: .failed(.playerRefused(failure)))
                return
            }
        }
    }

    /// 看多久、多久看一次。总量有界：**不是**每帧开销，也不是常驻轮询 ——
    /// 到点就退，`stop()` 也会取消它。
    static let playerWatchAttempts = 24
    static let playerWatchInterval: Duration = .seconds(1)

    private func startWatchdog() {
        watchdog?.cancel()
        let expected = requestedURL
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.loadTimeout)
            guard !Task.isCancelled, let self else { return }
            guard self.state.isLoading, self.requestedURL == expected else { return }
            self.transition(to: .failed(.timeout))
        }
    }

    /// 「没在放东西」那一面屏幕的颜色与底纹 —— **外观**，不是判据。
    ///
    /// 深灰偏黑（sRGB 约 #1b1e24 ⇒ 线性约 0.011–0.016），加一道很淡的斜向高光当"反光"：
    /// 于是它读起来是一块关着的屏幕玻璃，而不是一个死黑的矩形。**唯一**一处取值，
    /// `underPageBackgroundColor` 与空页 HTML 都读它，不各写一份。
    static let idleScreenBackground = NSColor(
        srgbRed: 0.106, green: 0.118, blue: 0.141, alpha: 1
    )

    static let blankPage = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;height:100%;background:#1b1e24;
        background-image:linear-gradient(115deg,rgba(255,255,255,0.075) 0%,
        rgba(255,255,255,0.020) 22%,rgba(255,255,255,0) 46%),
        linear-gradient(#20242b,#12141a)}</style></head>
        <body></body></html>
        """

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        watchdog?.cancel()
        watchdog = nil
        // `stop()` 载的那张空页也会走一次 `didFinish`：只有"正在载入"才算载好了。
        // 少了这一条，**关掉的屏幕会被这条回调重新说成"播放中"**（`requestedURL`
        // 是刻意留着给"上次放的是什么"读的，不能靠清空它来兜）。
        guard let requestedURL, state.isLoading else { return }
        transition(to: .playing(url: requestedURL))
        startPlayerWatch()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        fail(with: error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        fail(with: error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if let response = navigationResponse.response as? HTTPURLResponse,
           response.statusCode >= 400 {
            watchdog?.cancel()
            watchdog = nil
            transition(to: .failed(.httpStatus(response.statusCode)))
            return .cancel
        }
        return .allow
    }

    private func fail(with error: any Error) {
        watchdog?.cancel()
        watchdog = nil
        let nsError = error as NSError
        // 分两类就够："网络层没通"与"WebKit 自己拒了"。两者给用户的话不一样，
        // 所以必须分开 —— 这是"失败可见"里最容易糊过去的一处。
        if nsError.domain == NSURLErrorDomain {
            transition(to: .failed(.network(nsError.localizedDescription)))
            return
        }
        transition(to: .failed(.blocked(nsError.localizedDescription)))
    }
}

// MARK: - 覆盖层：多块屏幕 + 每帧对齐

/// 电视覆盖层的**唯一**宿主。
///
/// 职责边界（刻意收窄）：
/// - 它**不决定**屏幕几何（`WorldScreenResolution` 决定）；
/// - 它**不决定**放什么（`WorldScreenEmbedPolicy` 决定）；
/// - 它**不裁决**指针（`hitTest` 恒 `nil`）；
/// - 它只做两件事：把几何贴到视图上、把状态说清楚。
@MainActor
final class WorldScreenOverlayController {
    /// 同时播放的上限。每块屏一个 WebKit 内容进程，内存与解码都是线性的。
    static let maximumSimultaneousScreens = 2

    private(set) var surfaces: [String: WorldScreenSurface] = [:]
    /// 一块屏幕被"看不见"（世界不可见 / 背向 / 相机背后）而隐藏的**具名**原因，
    /// 供面板与诊断读取。`nil` = 当前可见。
    private(set) var hiddenReasons: [String: String] = [:]
    /// 每块屏幕最近一次遮挡计算的账（格数 + 耗时）。
    private(set) var occlusionStats: [String: WorldScreenOcclusionStat] = [:]
    /// 房间三角面的 BVH。只在 `occluders.revision` 变了时重建。
    private var occluderIndex: WorldScreenOccluderIndex?
    /// 每块屏幕上一次算掩码时的输入签名：没变就**一格都不重算**。
    private var occlusionKeys: [String: String] = [:]
    /// 每块屏幕上一次掩码重算的时刻（秒，注入时钟）。
    private var lastMaskRecompute: [String: Double] = [:]
    /// 每块屏幕**当前渲染尺寸**（点）。它不跟着相机每帧变 —— 见 `renderedSize`。
    private var renderedSizes: [String: SIMD2<Float>] = [:]
    /// 本帧的账（每项耗时 + 计数器）。诊断与判据读同一份。
    private(set) var frameCost = WorldScreenFrameCost()
    /// **可注入的时钟**（秒）。生产用 `CFAbsoluteTimeGetCurrent`；harness 注入合成时间，
    /// 于是"掩码最多 30 Hz"这条判据能在离线探针里被驱动，不需要真机启动。
    var clock: () -> Double = { CFAbsoluteTimeGetCurrent() }
    private weak var hostView: NSView?
    var onSurfaceStateChange: (@MainActor (String, WorldScreenSurfaceState) -> Void)?

    /// 「操作屏幕」模式：**默认关闭**。只有它是 `true` 时，各屏的容器才接受鼠标事件。
    ///
    /// 这是"偶尔点一下网页里的按钮"与"默认绝不影响场景"之间**唯一**的开关：它不进
    /// `consumesScenePointer`（那条判据的签名、调用点、语义一个字不改），也不给覆盖层
    /// 加任何指针/键盘入口 —— 它只改一件事：容器 `hitTest` 从现在起会不会返回自己。
    private(set) var isOperatingScreen = false
    /// 进入/退出时通知宿主（按钮外观与"正在操作电视"提示条读它）。
    var onScreenOperationChange: (@MainActor (Bool) -> Void)?
    /// `Esc` 的局部监听器。只在模式开着的时候挂着，退出即摘。
    private var escapeMonitor: Any?

    /// 至少一块屏幕**有东西**（在放或在载）。入口按钮的可用性读它 —— 一块屏幕都没有时
    /// 那个开关是灰的，所以它不会变成常驻噪音。
    var hasLiveScreen: Bool {
        surfaces.values.contains { $0.state.isPlaying || $0.state.isLoading }
    }

    /// 进入 / 退出「操作屏幕」。两个方向都是**显式**的：没有"看情况自动进入"。
    func setScreenOperation(_ active: Bool) {
        guard isOperatingScreen != active else { return }
        isOperatingScreen = active
        for surface in surfaces.values { surface.container.acceptsScreenPointer = active }
        if active { installEscapeMonitor() } else { removeEscapeMonitor() }
        onScreenOperationChange?(active)
    }

    /// `Esc`（或点「完成」）立刻退出，恢复"不吃事件"。
    func endScreenOperation() {
        setScreenOperation(false)
    }

    /// `Esc` 的局部监听器：**只读、只对 `Esc` 生效**，其它按键原样返回（不消费、不改写）。
    ///
    /// 为什么不能用容器的 `keyDown`：那会给覆盖层加一个键盘入口，正是断言 3 禁掉的东西；
    /// 而且点击进网页之后第一响应者是 `WKWebView`，键盘根本不会走到容器。
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            guard let self, self.isOperatingScreen else { return event }
            self.endScreenOperation()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }

    /// 屏幕上没有活的东西了（关掉 / 被收回 / 世界退出）⇒ 模式自动退出：
    /// 留着它只会让"用户在操作一块已经不存在的屏幕"这个状态悬在那儿。
    private func endScreenOperationIfNothingLive() {
        guard isOperatingScreen, !hasLiveScreen else { return }
        endScreenOperation()
    }

    init(hostView: NSView) {
        self.hostView = hostView
    }

    /// 取（或建）一块屏幕的容器。调用方拿到后把 `container` 放进宿主视图。
    func surface(for objectID: String) -> WorldScreenSurface {
        if let existing = surfaces[objectID] { return existing }
        let surface = WorldScreenSurface(objectID: objectID)
        surface.onStateChange = { [weak self] state in
            self?.onSurfaceStateChange?(objectID, state)
            self?.endScreenOperationIfNothingLive()
        }
        surface.container.identifier = NSUserInterfaceItemIdentifier("stage.screen-overlay")
        // 模式开着的时候新建的屏幕也要跟上：否则"进入模式后再放一部"的那块屏点不到。
        surface.container.acceptsScreenPointer = isOperatingScreen
        surface.container.wantsLayer = true
        surface.container.layer?.zPosition = 1.6
        surface.container.autoresizingMask = []
        // 容器必须真的进视图树 —— 否则"每帧算对了变换"也只是在算一个没有画出来的东西。
        // 这一处是覆盖层唯一一次往宿主里挂子视图。
        if let hostView, surface.container.superview !== hostView {
            hostView.addSubview(surface.container)
        }
        surfaces[objectID] = surface
        return surface
    }

    /// 正在 `playing` 的屏幕数。
    var playingCount: Int { surfaces.values.filter { $0.state.isPlaying }.count }

    /// 当前是否还能再开一块。
    func canLoad(anotherThan objectID: String?) -> Bool {
        let playing = surfaces.values.filter {
            $0.objectID != objectID && ($0.state.isPlaying || $0.state.isLoading)
        }
        return playing.count < Self.maximumSimultaneousScreens
    }

    /// 移除一块屏幕（物件被收回 / 世界切换）。
    func removeSurface(for objectID: String) {
        guard let surface = surfaces.removeValue(forKey: objectID) else { return }
        surface.stop()
        surface.container.removeFromSuperview()
        hiddenReasons[objectID] = nil
        occlusionKeys[objectID] = nil
        lastMaskRecompute[objectID] = nil
        renderedSizes[objectID] = nil
        occlusionStats[objectID] = nil
        // 被移除的那块正好是最后一块活着的屏幕 ⇒ 模式跟着退出（Esc/开关之外的第三条收场路）。
        endScreenOperationIfNothingLive()
    }

    func removeAll() {
        for objectID in surfaces.keys { removeSurface(for: objectID) }
    }

    /// 每帧（相机/视口变化时）调用：把每块屏幕的容器贴到它自己的四边形上。
    ///
    /// - Parameters:
    ///   - quads: `objectID` → 该屏的**世界**四角（顺序 BL, BR, TR, TL）。
    ///   - normals: `objectID` → 该屏的世界法向。
    ///   - projection: 本帧的相机投影。
    ///   - camera: 本帧相机（背向判据用）。
    ///   - occluders: 本帧的遮挡物（房间三角面 + 物件盒 + 居民盒）。
    ///     默认为空 = 不裁任何区域（旧调用点/离线驱动逐字不变）。
    ///
    /// 一帧的每一项都记进 `frameCost`（见 `WorldScreenFrameCost`）：这是"推进镜头爆卡"
    /// 唯一能被复核的口径 —— 光有"每帧 0.6 ms"说不清是算遮挡、画遮挡还是贴覆盖层。
    func update(
        quads: [String: [SIMD3<Float>]],
        normals: [String: SIMD3<Float>],
        projection: WorldScreenProjection,
        camera: WorldScreenCamera,
        occluders: WorldScreenOccluders = .empty
    ) {
        frameCost = WorldScreenFrameCost()
        let signpost = overlaySignposter.beginInterval("screen.overlay.frame")
        defer { overlaySignposter.endInterval("screen.overlay.frame", signpost) }
        if occluderIndex?.revision != occluders.revision {
            let start = CFAbsoluteTimeGetCurrent()
            occluderIndex = occluders.triangles.isEmpty
                ? nil
                : WorldScreenOccluderIndex(
                    triangles: occluders.triangles, revision: occluders.revision
                )
            frameCost.occluderIndexBuild = CFAbsoluteTimeGetCurrent() - start
            frameCost.didRebuildOccluderIndex = true
            overlaySignposter.emitEvent("screen.occluder-index.build")
        }
        for (objectID, surface) in surfaces {
            guard let worldCorners = quads[objectID], worldCorners.count == 4 else {
                hide(surface, reason: "没有屏幕几何")
                continue
            }
            guard surface.geometryIssue == nil else {
                hide(surface, reason: surface.geometryIssue?.errorDescription ?? "几何非法")
                continue
            }
            let normal = normals[objectID] ?? SIMD3<Float>(0, 0, 1)
            let centre = (worldCorners[0] + worldCorners[1] + worldCorners[2] + worldCorners[3]) / 4
            guard WorldScreenProjection.isFrontFacing(
                normal: normal, center: centre, camera: camera
            ) else {
                hide(surface, reason: "屏幕背对相机")
                continue
            }
            guard let normalized = projection.screenQuad(worldCorners: worldCorners),
                  let boundsSize = WorldScreenOverlayAlignment.boundingSize(
                      normalizedCorners: normalized, projection: projection
                  )
            else {
                hide(surface, reason: "屏幕在相机背后或投影退化")
                continue
            }
            // 宿主渲染尺寸**带滞回**：相机连续移动时尺寸不动，全部由 transform 吸收。
            let rendered = Self.renderedSize(
                current: renderedSizes[objectID], desired: boundsSize,
                hysteresis: WorldScreenFrameBudget.renderedSizeHysteresis
            )
            renderedSizes[objectID] = rendered
            guard let placement = WorldScreenOverlayAlignment.placement(
                normalizedCorners: normalized, projection: projection,
                referenceSize: rendered
            ) else {
                hide(surface, reason: "屏幕在相机背后或投影退化")
                continue
            }
            surface.container.isHidden = false
            hiddenReasons[objectID] = nil
            applyPlacement(surface, placement: placement)
            surface.resumeMediaIfNeeded()
            updateOcclusion(
                surface, worldCorners: worldCorners, camera: camera,
                placement: placement, occluders: occluders
            )
        }
    }

    /// 宿主的**渲染尺寸**：只在包围盒相对它涨/缩超过 `hysteresis` 时换一次。
    ///
    /// 这是"推进镜头爆卡"的要害。`container.bounds` 一变，里面的 `WKWebView` 就换一次
    /// 尺寸，WebKit 于是让内容进程**重新布局并重画整页**（视频页还要重建播放器层）。
    /// 实测：120 帧的推进里，尺寸原来换了 **120 次**（每帧一次）；带滞回之后 **0 次**
    /// （一次推近里最多换几次），中间的相机移动全部由 `layer.transform` 吸收 ——
    /// 对齐逐点不变（`placement` 的源矩形与变换一起换）。
    static func renderedSize(
        current: SIMD2<Float>?, desired: SIMD2<Float>, hysteresis: Float
    ) -> SIMD2<Float> {
        guard let current, current.x > 0, current.y > 0 else { return desired }
        let limit = max(hysteresis, 0)
        let upper = 1 + limit
        let lower = 1 / upper
        let fits = desired.x <= current.x * upper && desired.x >= current.x * lower
            && desired.y <= current.y * upper && desired.y >= current.y * lower
        return fits ? current : desired
    }

    /// 把宿主贴到这一帧的位置上。**只在真的变了的时候写。**
    ///
    /// `frame` / `transform` 的每一次赋值都是一次 CoreAnimation 事务；`frame` 还带着
    /// AppKit 的布局副作用（子视图 autoresizing），所以"值一样就别写"。
    /// 尺寸没变时只写原点，**不经过尺寸那条路** —— 否则 `NSView.setFrame` 仍会把新尺寸
    /// 递给 `WKWebView`。
    ///
    /// **为什么变换必须按图层现在的值重写**（2026-10-02 真机「覆盖层与电视对不齐」的根因）：
    /// AppKit 的 `frame` / `setFrameOrigin` 会把 `layer.transform` **重置成单位阵**
    /// （实测两条路都会）。于是"变换与我们缓存里那一份相等就早退"这条优化，在
    /// **尺寸被滞回吸附住**之后（原点每帧都动、尺寸不动）会把变换**永久留在单位阵上**：
    /// 画面还贴在原地，但角度与大小从第一帧起就不再跟着相机走 —— 用户看到的就是"对不上"。
    ///
    /// 修法是两条一起：
    /// 1. 判据读**图层现在真的拿着的那一份**（`layer.transform`）而不是我们自己记的缓存，
    ///    AppKit 重置过就一定会被写回去；
    /// 2. 写下去的变换要过 `layerTransform(forAnchor:)` 这个**唯一的口径转换** ——
    ///    `placement` 解出的是"绕包围盒中心"施加的单应，而 AppKit backing layer 的
    ///    `anchorPoint` 是 `(0,0)` 且改不动（实测赋 `(0.5,0.5)` 会被立刻改回 `(0,0)`）。
    ///
    /// 尺寸仍然只在超过滞回阈值时换一次（每次换都会付一次 `WKWebView` 重排），
    /// 相机移动全部由这一份变换吸收 —— 性能收益与逐点对齐因此同时成立。
    private func applyPlacement(
        _ surface: WorldScreenSurface, placement: WorldScreenOverlayAlignment.Placement
    ) {
        let container = surface.container
        let size = CGSize(
            width: CGFloat(placement.frame.x), height: CGFloat(placement.frame.y)
        )
        let layer = container.layer
        let start = CFAbsoluteTimeGetCurrent()
        if surface.appliedFrameSize != size {
            frameCost.didResizeSurface = true
            // AppKit 的尺寸那条路会重置 `layer.transform` ⇒ 同帧内必须重写变换（见下）。
            container.frame = CGRect(
                x: CGFloat(placement.frameOrigin.x), y: CGFloat(placement.frameOrigin.y),
                width: size.width, height: size.height
            )
            surface.appliedFrameSize = size
            surface.appliedFrameOrigin = CGPoint(
                x: CGFloat(placement.frameOrigin.x), y: CGFloat(placement.frameOrigin.y)
            )
            surface.appliedTransform = nil
        } else if surface.appliedFrameOrigin?.x != CGFloat(placement.frameOrigin.x)
            || surface.appliedFrameOrigin?.y != CGFloat(placement.frameOrigin.y) {
            // 尺寸没变时只动原点：**不经过尺寸那条路**（否则 `NSView.setFrame` 仍会把
            // 新尺寸递给 `WKWebView`，那正是爆卡的主因）。
            let origin = CGPoint(
                x: CGFloat(placement.frameOrigin.x), y: CGFloat(placement.frameOrigin.y)
            )
            container.setFrameOrigin(origin)
            surface.appliedFrameOrigin = origin
        }
        frameCost.overlayFrame = CFAbsoluteTimeGetCurrent() - start
        let transformStart = CFAbsoluteTimeGetCurrent()
        // 口径转换只有一处：`placement` 解出的是**层心**口径，写进图层前必须换成
        // AppKit backing layer 的**原点**口径（见 `layerTransform(forAnchor:)`）。
        let layerTransform = placement.transform.layerTransform(
            forAnchor: SIMD2(placement.frame.x / 2, placement.frame.y / 2)
        )
        // 判据读**图层现在的值**而不是缓存：AppKit 会在尺寸那条路上把 `layer.transform`
        // 重置成单位阵，缓存说"没变"就会漏写（这正是"角度慢慢对不上"的另一半）。
        let written = layer.map { WorldScreenLayerTransform(cgTransform: $0.transform) }
        if written != layerTransform {
            layer?.transform = layerTransform.cgTransform
            surface.appliedTransform = layerTransform
        }
        frameCost.overlayTransform = CFAbsoluteTimeGetCurrent() - transformStart
    }

    // MARK: 前景遮挡

    /// 掩码只在**输入真的变了**、**且离上一次够久**的时候重算。
    ///
    /// 两条闸门各管一件事：
    /// 1. **签名没变 ⇒ 一格都不重算**（相机不动、遮挡物不动、四边形没变）。这既是成本控制，
    ///    也是"正常观看时不闪烁"的实现方式：不重算就不可能抖；
    /// 2. **签名变了也要间隔 ≥ `maskMinimumInterval`**（≈30 Hz）。相机连续移动时签名每帧
    ///    都在变，只有第 1 条拦不住 —— 于是 24 × 14 格的射线求交、可见格并集、`CGPath`
    ///    构造与图层赋值全都变成每帧一次。格级掩码在 33 ms 内不可能被看出滞后，
    ///    而这三件事加起来是这一级唯一有量级的 CPU 成本（真机实测见断言9）。
    ///
    /// 被节流挡掉时**不记签名**：下一拍（窗口过了）会拿当时的输入重算，所以不会漏。
    private func updateOcclusion(
        _ surface: WorldScreenSurface,
        worldCorners: [SIMD3<Float>],
        camera: WorldScreenCamera,
        placement: WorldScreenOverlayAlignment.Placement,
        occluders: WorldScreenOccluders
    ) {
        let keyStart = CFAbsoluteTimeGetCurrent()
        let key = Self.occlusionKey(
            corners: worldCorners, camera: camera, placement: placement,
            occluders: occluders, owner: surface.objectID
        )
        frameCost.occlusionKey = CFAbsoluteTimeGetCurrent() - keyStart
        guard key != occlusionKeys[surface.objectID] else { return }
        let now = clock()
        if let last = lastMaskRecompute[surface.objectID],
           now - last < Self.maskMinimumInterval {
            return
        }
        occlusionKeys[surface.objectID] = key
        lastMaskRecompute[surface.objectID] = now
        frameCost.didRecomputeMask = true
        let start = CFAbsoluteTimeGetCurrent()
        let mask = WorldScreenOcclusion.mask(
            quadCorners: worldCorners,
            cameraPosition: camera.position,
            occluders: occluders,
            index: occluderIndex,
            excluding: surface.objectID
        )
        let seconds = CFAbsoluteTimeGetCurrent() - start
        frameCost.maskCompute = seconds
        let cost = Duration.seconds(seconds)
        surface.applyOcclusion(mask, cost: cost)
        frameCost.maskPath = surface.lastMaskCost.pathBuild
        frameCost.maskAssign = surface.lastMaskCost.assign
        frameCost.didRebuildMaskPath = surface.lastMaskCost.didRebuildPath
        occlusionStats[surface.objectID] = WorldScreenOcclusionStat(
            objectID: surface.objectID, columns: mask.columns, rows: mask.rows,
            blockedCellCount: mask.blockedCellCount, cost: cost
        )
        overlaySignposter.emitEvent("screen.occlusion.recompute")
    }

    /// 两次掩码重算之间的**最小间隔**（秒）。相机连续移动时掩码最多这么勤。
    static let maskMinimumInterval = 1.0 / WorldScreenFrameBudget.maximumMaskRecomputesPerSecond

    /// 掩码的输入签名。相机位姿、四角、容器尺寸、遮挡物（含每个盒）都在里面 ——
    /// 少一项就会"该重算的时候没重算"，多一项就会白算。
    private static func occlusionKey(
        corners: [SIMD3<Float>],
        camera: WorldScreenCamera,
        placement: WorldScreenOverlayAlignment.Placement,
        occluders: WorldScreenOccluders,
        owner: String
    ) -> String {
        var key = String(
            format: "%.4f|%.4f|%.4f|%.4f|%.4f|%.3f|%.3f|%d|%llu|%@|",
            camera.position.x, camera.position.y, camera.position.z,
            camera.yaw, camera.pitch,
            placement.frame.x, placement.frame.y,
            occluders.boxes.count, occluders.revision, owner
        )
        for corner in corners {
            key += String(format: "%.4f,%.4f,%.4f;", corner.x, corner.y, corner.z)
        }
        for box in occluders.boxes {
            key += String(
                format: "%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%@;",
                box.center.x, box.center.y, box.center.z,
                box.halfExtents.x, box.halfExtents.y, box.halfExtents.z,
                box.yaw, box.owner ?? "-"
            )
        }
        return key
    }

    /// 世界不可见时（Live Cam / 世界未呈现）整块收起来，并**暂停**媒体。
    func setWorldVisible(_ visible: Bool) {
        // 世界都退出去了就没有"正在操作的那块屏"：模式必须跟着收，否则它会以"开着但
        // 什么都点不到"的形态留到下一次进世界（用户看到的就是"场景坏了"）。
        if !visible { endScreenOperation() }
        for surface in surfaces.values {
            if visible {
                surface.container.isHidden = false
            } else {
                hide(surface, reason: "世界当前不可见")
            }
        }
    }

    private func hide(_ surface: WorldScreenSurface, reason: String) {
        surface.container.isHidden = true
        hiddenReasons[surface.objectID] = reason
        surface.suspendMedia()
    }
}

extension WorldScreenLayerTransform {
    /// 纯值 → `CATransform3D`。转换只有这一处（几何文件不依赖 QuartzCore，
    /// 于是它能在离线 harness 里逐点验证）。
    var cgTransform: CATransform3D {
        CATransform3D(
            m11: CGFloat(m11), m12: CGFloat(m12), m13: CGFloat(m13), m14: CGFloat(m14),
            m21: CGFloat(m21), m22: CGFloat(m22), m23: CGFloat(m23), m24: CGFloat(m24),
            m31: CGFloat(m31), m32: CGFloat(m32), m33: CGFloat(m33), m34: CGFloat(m34),
            m41: CGFloat(m41), m42: CGFloat(m42), m43: CGFloat(m43), m44: CGFloat(m44)
        )
    }

    /// `CATransform3D` → 纯值。与 `cgTransform` 是同一个转换的两个方向，所以也放在一处：
    /// `applyPlacement` 用它判断"图层现在这一份是不是我想要的那一份"（AppKit 会把
    /// `layer.transform` 重置成单位阵，光看缓存会漏写）。
    init(cgTransform value: CATransform3D) {
        self.init(
            m11: Float(value.m11), m12: Float(value.m12), m13: Float(value.m13),
            m14: Float(value.m14),
            m21: Float(value.m21), m22: Float(value.m22), m23: Float(value.m23),
            m24: Float(value.m24),
            m31: Float(value.m31), m32: Float(value.m32), m33: Float(value.m33),
            m34: Float(value.m34),
            m41: Float(value.m41), m42: Float(value.m42), m43: Float(value.m43),
            m44: Float(value.m44)
        )
    }

    /// **图层口径的修正**（覆盖层对齐的唯一一处口径转换）。
    ///
    /// `WorldScreenOverlayAlignment.placement` 解出的单应 H，是把"宿主 bounds 的四角
    /// （相对包围盒中心）"搬到"四边形四角（相对同一个中心）"—— 它默认图层绕**层心**
    /// 施加变换，也就是 `anchorPoint = (0.5, 0.5)`。
    ///
    /// 而 AppKit 的 backing layer（`NSViewBackingLayer`）`anchorPoint` 实测是 **`(0, 0)`**、
    /// `position` 等于 `frame.origin`（改 frame、设 transform 之后都不变），CoreAnimation
    /// 实际施加的是 `position + T(bounds 角)`。两个口径之间差的**不是一段平移，而是
    /// 绕层心与绕原点的一次共轭**：
    ///
    ///     G(q) = a + H(q − a)        （a = bounds.size / 2）
    ///
    /// 所以"把 `m41/m42` 归零"不是这个修正 —— 那会把"包围盒中心 → 四边形中心"那段平移
    /// 一起丢掉，比不修更偏。下面六个分量（外加 `m44`）要一起动，才是那次共轭。
    ///
    /// 实测（`tools/test-resident-screen-overlay.swift` 断言10，同一段 120 帧推进，
    /// 按图层**实际**口径 `position + G(bounds 角)` 与投影四角的距离）：
    /// 原样写层心口径 ⇒ 最大 **24.6 px**；归零 `m41/m42` ⇒ **更差**；
    /// 共轭修正 ⇒ **0.0001 px**。
    func layerTransform(forAnchor a: SIMD2<Float>) -> WorldScreenLayerTransform {
        // 共轭之后的分母常数项：`w(q − a) = m14·qx + m24·qy + (m44 − m14·ax − m24·ay)`。
        let constant = m44 - m14 * a.x - m24 * a.y
        var conjugated = self
        conjugated.m11 = m11 + a.x * m14
        conjugated.m21 = m21 + a.x * m24
        conjugated.m41 = m41 - m11 * a.x - m21 * a.y + a.x * constant
        conjugated.m12 = m12 + a.y * m14
        conjugated.m22 = m22 + a.y * m24
        conjugated.m42 = m42 - m12 * a.x - m22 * a.y + a.y * constant
        conjugated.m44 = constant
        return conjugated
    }
}
