import AppKit
@preconcurrency import WebKit

// MARK: - 覆盖层宿主：**不吃任何指针事件**

/// 覆盖层的容器视图。
///
/// `hitTest` 恒返回 `nil` —— 这个视图与它的整棵子树（包括 `WKWebView`）**永远收不到**
/// 任何鼠标事件。这是"不抢场景鼠标"这条红线的**唯一**实现点，所以它只有一处。
///
/// 为什么不做"显式进入操作电视模式"那条路：场景指针的所有权由
/// `ResidentPropEditorState.consumesScenePointer(isOpen:moving:inputOwnsFocus:)` 一处裁决，
/// 它的**签名**是红线（`tools/test-stage-resident-chat.swift` 逐字断言），14 条
/// `场景输入链[N]` 也全都锚在它周围。要在这里插一条"操作电视"分支，就得改那条判据的
/// 输入或它的调用点 —— 收益（在电视上点网页）远小于风险（装修的点击/拖动/旋转
/// 与相机操作同时失效，正是 2026-09-29 那三个症状的同一族）。
///
/// 所以本切片里电视**是显示屏，不是输入设备**：开关与换片走面板（`ScreenPanel`）
/// 与 agent 工具（`play_screen` / `stop_screen`）。将来要开交互，正确做法是给
/// `consumesScenePointer` 增加一个**新的显式输入**并同步 14 条链的断言，
/// 那是独立的一轮工作，不是顺带塞进来的。
@MainActor
final class WorldScreenOverlayContainer: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    private var occlusionMaskLayer: CAShapeLayer?
    var onStateChange: (@MainActor (WorldScreenSurfaceState) -> Void)?
    private var watchdog: Task<Void, Never>?
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
    func applyOcclusion(_ mask: WorldScreenOcclusionMask?, cost: Duration?) {
        occlusionMask = mask
        lastOcclusionCost = cost
        guard let mask, !mask.isFullyVisible else {
            occlusionMaskLayer?.path = nil
            container.layer?.mask = nil
            occlusionMaskLayer = nil
            return
        }
        let bounds = container.bounds
        let size = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        guard size.x > 0, size.y > 0 else { return }
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
        let path = CGMutablePath()
        for rect in mask.visibleRects(in: size) {
            path.addRect(
                CGRect(
                    x: CGFloat(rect.x), y: CGFloat(rect.y),
                    width: CGFloat(rect.width), height: CGFloat(rect.height)
                )
            )
        }
        layer.frame = bounds
        layer.path = path
    }

    // MARK: 控制

    /// 载入一个**已经过白名单校验**的官方嵌入 URL。
    func load(url: URL) {
        requestedURL = url.absoluteString
        geometryIssue = nil
        transition(to: .loading(url: url.absoluteString))
        resumeMediaIfNeeded()
        webView.load(URLRequest(url: url))
        startWatchdog()
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
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
        guard let requestedURL else { return }
        transition(to: .playing(url: requestedURL))
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
    private weak var hostView: NSView?
    var onSurfaceStateChange: (@MainActor (String, WorldScreenSurfaceState) -> Void)?

    init(hostView: NSView) {
        self.hostView = hostView
    }

    /// 取（或建）一块屏幕的容器。调用方拿到后把 `container` 放进宿主视图。
    func surface(for objectID: String) -> WorldScreenSurface {
        if let existing = surfaces[objectID] { return existing }
        let surface = WorldScreenSurface(objectID: objectID)
        surface.onStateChange = { [weak self] state in
            self?.onSurfaceStateChange?(objectID, state)
        }
        surface.container.identifier = NSUserInterfaceItemIdentifier("stage.screen-overlay")
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
        occlusionStats[objectID] = nil
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
    func update(
        quads: [String: [SIMD3<Float>]],
        normals: [String: SIMD3<Float>],
        projection: WorldScreenProjection,
        camera: WorldScreenCamera,
        occluders: WorldScreenOccluders = .empty
    ) {
        if occluderIndex?.revision != occluders.revision {
            occluderIndex = occluders.triangles.isEmpty
                ? nil
                : WorldScreenOccluderIndex(
                    triangles: occluders.triangles, revision: occluders.revision
                )
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
                  let placement = WorldScreenOverlayAlignment.placement(
                      normalizedCorners: normalized, projection: projection
                  )
            else {
                hide(surface, reason: "屏幕在相机背后或投影退化")
                continue
            }
            surface.container.isHidden = false
            hiddenReasons[objectID] = nil
            surface.container.frame = CGRect(
                x: CGFloat(placement.frameOrigin.x),
                y: CGFloat(placement.frameOrigin.y),
                width: CGFloat(placement.frame.x),
                height: CGFloat(placement.frame.y)
            )
            surface.container.layer?.transform = placement.transform.cgTransform
            surface.resumeMediaIfNeeded()
            updateOcclusion(
                surface, worldCorners: worldCorners, camera: camera,
                placement: placement, occluders: occluders
            )
        }
    }

    // MARK: 前景遮挡

    /// 掩码只在**输入真的变了**的时候重算。
    ///
    /// 这既是成本控制（相机不动、遮挡物不动、四边形没变 ⇒ 一格都不重算），
    /// 也是"正常观看时不闪烁"的实现方式：**不重算就不可能抖**。
    private func updateOcclusion(
        _ surface: WorldScreenSurface,
        worldCorners: [SIMD3<Float>],
        camera: WorldScreenCamera,
        placement: WorldScreenOverlayAlignment.Placement,
        occluders: WorldScreenOccluders
    ) {
        let key = Self.occlusionKey(
            corners: worldCorners, camera: camera, placement: placement,
            occluders: occluders, owner: surface.objectID
        )
        guard key != occlusionKeys[surface.objectID] else { return }
        occlusionKeys[surface.objectID] = key
        let clock = ContinuousClock()
        let start = clock.now
        let mask = WorldScreenOcclusion.mask(
            quadCorners: worldCorners,
            cameraPosition: camera.position,
            occluders: occluders,
            index: occluderIndex,
            excluding: surface.objectID
        )
        let cost = clock.now - start
        surface.applyOcclusion(mask, cost: cost)
        occlusionStats[surface.objectID] = WorldScreenOcclusionStat(
            objectID: surface.objectID, columns: mask.columns, rows: mask.rows,
            blockedCellCount: mask.blockedCellCount, cost: cost
        )
    }

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
}
