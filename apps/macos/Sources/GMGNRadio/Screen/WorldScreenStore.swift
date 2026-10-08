import AppKit
import Foundation
import os
import os.signpost
import simd
import WorldRuntime

/// 电视这条线的统一日志（`subsystem = ai.gmgn.radio`）。
///
/// 面板上只留人话，**工程细节全部走这里**：几何出处原话（法向 / 面积 / m²）、
/// 前景遮挡的格数与掩码耗时（"63/336 格"、"117.98 ms"）。真机 2026-10-02 的教训是
/// "把这些摆到面板上" —— 用户看到的是「什么玩意儿」。
private let screenPanelLogger = Logger(subsystem: "ai.gmgn.radio", category: "screen")

/// 60 Hz 跟踪与 6 Hz 世界重读的耗时去这里（Instruments 的 points of interest）。
///
/// 与覆盖层那一份同一个 subsystem/category：一帧里"跟相机"（`screen.tick`）、
/// "重读世界"（`screen.rebuild`）与"贴覆盖层"（`screen.overlay.frame`）在时间轴上
/// 是三条可比的区段 —— 相机持续移动时哪一条占满了帧预算，一眼看得出来。
private let screenTrackingSignposter = OSSignposter(
    subsystem: "ai.gmgn.radio", category: .pointsOfInterest
)

/// 电视屏幕在 App 里的**唯一**接线点。
///
/// 它把三件事缝在一起，但一件都不**决定**：
/// - 几何：`WorldScreenResolution`（标定 → 推断 → 缺省，缺省必须说出来）；
/// - 内容：`WorldScreenEmbedPolicy`（官方嵌入白名单）；
/// - 画面：`WorldScreenOverlayController`（native `WKWebView` + 透视对齐，不吃指针）。
///
/// 它自己不读存档、不写权威：世界状态与持久化都从外面**注入**（`Source`），
/// 于是它能在离线 harness 里被完整驱动，也不会变成第三个世界状态的事实源。
@MainActor
final class WorldScreenStore: ObservableObject, WorldScreenControlling {
    /// 世界那一侧的注入点。四个闭包各回答一个问题，没有一个能"顺手"改状态。
    struct Source {
        /// 当前世界状态里的物件。
        let objectStates: @MainActor () -> [String: WorldObjectState]
        /// 物件的显示名（面板与回执用）。
        let displayName: @MainActor (String) -> String
        /// 把一份屏幕定义**持久化**（写进物件 metadata / 走权威）。为 nil 时只在本次会话里生效。
        let persistDefinition: (@MainActor (WorldScreenDefinition) async throws -> Void)?
        /// 把屏幕内容**持久化**。为 nil 时同上。
        let persistContent: (@MainActor (WorldScreenContent) async throws -> Void)?
        /// 从本机持久化恢复屏幕定义（标定 / 来源）。为 nil 时不恢复。
        let restoreDefinition: (@MainActor (String) async throws -> WorldScreenDefinition?)?
        /// 从本机持久化恢复屏幕内容。为 nil 时不恢复。
        let restoreContent: (@MainActor (String) async throws -> WorldScreenContent?)?
        /// 物件不再存在时清掉它的持久化记录（过期内容不许复活）。
        let removePersisted: (@MainActor (String) async throws -> Void)?
    }

    /// 同时播放的上限（与覆盖层同一份数字）。
    static let maximumSimultaneousScreens = WorldScreenOverlayController.maximumSimultaneousScreens
    /// `play_screen` 等嵌入页"立刻失败"的窗口。
    static let immediateFailureWindow: Duration = .seconds(3)
    /// 跟踪相机/视口的节拍（Hz）。只做四角投影与比较，比一帧渲染便宜几个数量级。
    static let trackingHz = 60.0
    /// 重新读世界状态（几何/摆放可能变了）的节拍（Hz）。
    ///
    /// 刻意比跟踪节拍慢两个数量级：`objectStates()` 是一份字典拷贝，60 Hz 读它是
    /// 拿世界状态当每帧输入，而屏幕几何一轮装修最多变几次。摆放变化最多滞后 1/6 s。
    static let refreshHz = 6.0

    /// 面板绑定的只读快照。
    @Published private(set) var snapshots: [WorldScreenSnapshot] = []

    private let spatialStage: SpatialStageStore
    private let overlay: WorldScreenOverlayController
#if GMGN_GPUI_PRODUCT_BOOTSTRAP
    var gpuiScreenOperationSnapshot: [String: Bool] {
        ["available": overlay.hasLiveScreen, "active": overlay.isOperatingScreen]
    }
#endif
    private let source: Source
    private let projectionProvider: @MainActor () -> WorldScreenProjection
    /// 网站链接原生播放：解析器 + AVPlayer 会话 + 场景取帧注册表。
    private let nativeRegistry: WorldScreenNativeVideoRegistry
    private let nativeCoordinator: NativeScreenPlaybackCoordinator
    /// 本次会话里的标定覆盖（① 那一级的即时形态）。持久化成功时与 metadata 等价。
    private var calibrationOverrides: [String: WorldScreenDefinition] = [:]
    private var definitions: [String: WorldScreenDefinition] = [:]
    private var issues: [String: WorldScreenGeometryIssue] = [:]
    private var contents: [String: WorldScreenContent] = [:]
    /// 刷新时算好、每拍只做一次变换的缓存。避免每帧读世界状态。
    private var placements: [String: (position: SIMD3<Float>, yaw: Float)] = [:]
    /// 房间遮挡三角面（静态）。只在 `spatialStage.sceneOccluderRevision` 变了时重取。
    private var occluderTriangles: [WorldScreenTriangle] = []
    private var occluderTrianglesRevision: UInt64 = .max
    /// 已摆放物件的遮挡盒（随世界状态刷新，跟着 `rebuild()` 走）。
    private var occluderPropBoxes: [WorldScreenBox] = []
    /// 每块屏幕上一次写进日志的"被挡"状态。只在**翻转**时写一行，绝不刷屏。
    private var lastOcclusionLogged: [String: Bool] = [:]
    /// 每块屏幕上一次写进日志的几何出处（`出处|原文`）。同样只在**变了**的时候写。
    private var lastGeometryLogged: [String: String] = [:]
    private var trackingTask: Task<Void, Never>?
    private let metadataWorldID: @MainActor () -> String?
    private var persistenceWorld: String?
    private var persistenceLease = UUID()
    private var persistenceTask: Task<Void, Never>?
    private var attemptedRemovals: Set<String> = []
    @Published private(set) var persistenceStatus = "loading"
    @Published private(set) var persistenceNotice = "正在读取屏幕记录。"
    var onPersistenceError: (@MainActor (String) -> Void)?
    private var lastTrackingKey = ""
    private var tickCount = 0
    /// 最近一拍的总耗时（毫秒）。60 Hz 节拍：**同状态时它是"什么都没做"的那一拍**。
    private(set) var lastTickMilliseconds: Double = 0
    /// 最近一次 6 Hz 世界重读（`rebuild()`）的耗时（毫秒）。
    private(set) var lastRebuildMilliseconds: Double = 0
    /// 最近一拍贴覆盖层的耗时（毫秒，含遮挡掩码）。
    private(set) var lastOverlayMilliseconds: Double = 0
    /// 最后一次覆盖层隐藏原因（诊断/面板可读）。
    var hiddenReasons: [String: String] { overlay.hiddenReasons }

    /// 每块屏幕最近一次的**前景遮挡**账（格数 + 耗时）。面板/`read_screen`/诊断读它。
    var occlusionStats: [String: WorldScreenOcclusionStat] { overlay.occlusionStats }

    init(
        spatialStage: SpatialStageStore,
        overlay: WorldScreenOverlayController,
        source: Source,
        projectionProvider: @escaping @MainActor () -> WorldScreenProjection,
        mediaCache: any ScreenMediaCaching = ScreenMediaCacheClient(),
        playbackAuthority: any ScreenPlaybackAuthorizing = RustScreenPlaybackClient(),
        worldID: @escaping @MainActor () -> String? = { nil }
    ) {
        self.spatialStage = spatialStage
        self.overlay = overlay
        self.source = source
        self.projectionProvider = projectionProvider
        metadataWorldID = worldID
        // Rust owns fetching and cache files; the player consumes its local progressive streams.
        let registry = WorldScreenNativeVideoRegistry()
        self.nativeRegistry = registry
        self.nativeCoordinator = NativeScreenPlaybackCoordinator(
            cache: mediaCache, registry: registry, authority: playbackAuthority, worldID: worldID
        )
        nativeCoordinator.onChange = { [weak self] in
            guard let self else { return }
            self.snapshots = self.makeSnapshots()
        }
    }

    /// 原生播放的真实解码度量（E2E / 诊断只读）。没有原生会话时 `nil`。
    func nativeMetrics(objectID: String) -> NativeScreenPlaybackCoordinator.Metrics? {
        nativeCoordinator.metrics(for: objectID)
    }

    /// 场景取帧注册表：渲染器每帧读它。没有登记屏幕时为空，既有画面逐字节不变。
    var nativeVideoRegistry: WorldScreenNativeVideoRegistry { nativeRegistry }

    // MARK: 生命周期

    func startTracking() {
        guard trackingTask == nil else { return }
        let interval = Duration.seconds(1 / Self.trackingHz)
        let refreshEvery = max(Int((Self.trackingHz / Self.refreshHz).rounded()), 1)
        trackingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick(refreshEvery: refreshEvery)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopTracking() {
        trackingTask?.cancel()
        trackingTask = nil
    }

    /// 每拍：相机/视口变了就重贴；每 `refreshEvery` 拍才重读一次世界状态。
    /// **同状态不重复做事**（`lastTrackingKey`）。
    ///
    /// 两条节拍各自带一节 signpost 区段；`lastTickMilliseconds` /
    /// `lastRebuildMilliseconds` / `lastOverlayMilliseconds` 是它们的最后一份数字
    /// （诊断可读，离线判据不依赖它 —— 判据驱动的是覆盖层那一份账）。
    private func tick(refreshEvery: Int) {
        let tickStart = CFAbsoluteTimeGetCurrent()
        let signpost = screenTrackingSignposter.beginInterval("screen.tick")
        defer { screenTrackingSignposter.endInterval("screen.tick", signpost) }
        tickCount += 1
        let projection = projectionProvider()
        let camera = WorldScreenCamera(
            position: spatialStage.camera.position,
            yaw: spatialStage.camera.yaw,
            pitch: spatialStage.camera.pitch
        )
        let key = Self.trackingKey(camera: camera, projection: projection)
        let needsRefresh = tickCount % refreshEvery == 0
        guard key != lastTrackingKey || needsRefresh else {
            lastTickMilliseconds = (CFAbsoluteTimeGetCurrent() - tickStart) * 1000
            lastOverlayMilliseconds = 0
            return
        }
        lastTrackingKey = key
        overlay.setWorldVisible(spatialStage.isWorldVisible)
        let rebuildStart = CFAbsoluteTimeGetCurrent()
        if needsRefresh { rebuild() }
        lastRebuildMilliseconds = (CFAbsoluteTimeGetCurrent() - rebuildStart) * 1000
        let overlayStart = CFAbsoluteTimeGetCurrent()
        updateOverlay(projection: projection, camera: camera)
        lastOverlayMilliseconds = (CFAbsoluteTimeGetCurrent() - overlayStart) * 1000
        lastTickMilliseconds = (CFAbsoluteTimeGetCurrent() - tickStart) * 1000
    }

    /// 相机 + 视口的完整签名。相机位姿与视口尺寸就是投影的全部输入，所以这个键
    /// 变了才需要重贴；键没变时重贴是纯粹的浪费。
    private static func trackingKey(
        camera: WorldScreenCamera, projection: WorldScreenProjection
    ) -> String {
        String(
            format: "%.5f|%.5f|%.5f|%.5f|%.5f|%.1f|%.1f",
            camera.position.x, camera.position.y, camera.position.z,
            camera.yaw, camera.pitch,
            projection.viewportSize.x, projection.viewportSize.y
        )
    }

    // MARK: 几何

    /// 重读世界状态、重算所有屏幕的几何。
    /// **每一级来源与每一种拒绝都被记下来**，没有静默分支。
    func rebuild() {
        let signpost = screenTrackingSignposter.beginInterval("screen.rebuild")
        defer { screenTrackingSignposter.endInterval("screen.rebuild", signpost) }
        let states = source.objectStates()
        guard preparePersistence(states: states) else { return }
        // 遮挡盒跟着世界状态的刷新节拍（6 Hz）重建 —— 与屏幕几何同一份输入。
        rebuildOccluderBoxes(from: states)
        var seen: Set<String> = []
        for (objectID, state) in states.sorted(by: { $0.key < $1.key }) where state.isEnabled {
            let displayName = source.displayName(objectID)
            guard state.metadata[WorldScreenMetadataKey.definition] != nil
                || calibrationOverrides[objectID] != nil
                || contents[objectID] != nil
                || WorldScreenEligibility.isScreenCandidate(
                    objectID: objectID, displayName: displayName
                )
            else { continue }
            seen.insert(objectID)
            resolve(objectID: objectID, state: state)
        }
        // 收掉已经不存在的屏幕（物件被收回 / 世界切换）。key 先取快照再改字典。
        for objectID in Array(definitions.keys) where !seen.contains(objectID) {
            definitions[objectID] = nil
            issues[objectID] = nil
            contents[objectID] = nil
            calibrationOverrides[objectID] = nil
            placements[objectID] = nil
            // 物件没了：原生会话连播放器一起彻底清掉，过期解析结果不许复活它。
            nativeCoordinator.remove(objectID)
            removePersisted(objectID)
            overlay.removeSurface(for: objectID)
        }
        for objectID in Array(issues.keys) where !seen.contains(objectID) {
            issues[objectID] = nil
            placements[objectID] = nil
            nativeCoordinator.remove(objectID)
            removePersisted(objectID)
            overlay.removeSurface(for: objectID)
        }
        logGeometryIfChanged()
        snapshots = makeSnapshots()
    }

    /// 每块屏幕**几何出处的那句原文**（法向 / 面积 / m² / 三边比值）写进统一日志
    /// （`subsystem = ai.gmgn.radio`）—— **只在它变了的那一次**。
    ///
    /// 面板上那句话是人话（`ScreenPanelCopy.screenRangeLine`：自动识别 / 你标定的）；
    /// 工程口径的原文跟 agent 回执（`details["note"]`）和 metadata 一起走，也走这里。
    /// 真机 2026-10-02 的教训是把这些摆到面板上 —— 用户看到的是「什么玩意儿」。
    private func logGeometryIfChanged() {
        for objectID in definitions.keys.sorted() {
            guard let definition = definitions[objectID] else { continue }
            let signature = "\(definition.source.rawValue)|\(definition.note)"
            guard lastGeometryLogged[objectID] != signature else { continue }
            lastGeometryLogged[objectID] = signature
            screenPanelLogger.notice(
                "电视屏幕范围 物件=\(objectID, privacy: .public) 出处=\(definition.source.rawValue, privacy: .public) 原文=\(definition.note, privacy: .public)"
            )
        }
        for objectID in lastGeometryLogged.keys where definitions[objectID] == nil {
            lastGeometryLogged[objectID] = nil
        }
    }

    private func preparePersistence(states: [String: WorldObjectState]) -> Bool {
        guard source.restoreDefinition != nil || source.restoreContent != nil else {
            persistenceStatus = "ready"; persistenceNotice = ""; return true
        }
        guard let world = metadataWorldID(), !world.isEmpty else { return false }
        if persistenceWorld != world {
            persistenceTask?.cancel(); persistenceWorld = world; persistenceLease = UUID()
            let lease = persistenceLease
            persistenceStatus = "loading"; persistenceNotice = "正在读取屏幕记录。"
            attemptedRemovals.removeAll()
            nativeCoordinator.stopAll()
            for id in Array(overlay.surfaces.keys) { overlay.removeSurface(for: id) }
            // Only the new-world projection is cleared; the actor retains confirmed records by world.
            definitions.removeAll(); issues.removeAll(); contents.removeAll(); calibrationOverrides.removeAll(); placements.removeAll()
            snapshots = []
            persistenceTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    var restoredDefinitions: [String: WorldScreenDefinition] = [:]
                    var restoredContents: [String: WorldScreenContent] = [:]
                    for id in states.keys.sorted() {
                        try Task.checkCancellation()
                        if let value = try await self.source.restoreDefinition?(id) {
                            guard value.isValid, value.objectID == id else { throw RustScreenStateError.invalidResponse }
                            restoredDefinitions[id] = value
                        }
                        if let value = try await self.source.restoreContent?(id) {
                            guard value.isValid, value.objectID == id else { throw RustScreenStateError.invalidResponse }
                            restoredContents[id] = value
                        }
                    }
                    guard self.persistenceLease == lease, self.metadataWorldID() == world else { return }
                    self.calibrationOverrides = restoredDefinitions; self.contents = restoredContents
                    self.persistenceStatus = "ready"; self.persistenceNotice = ""
                    self.rebuild()
                } catch {
                    guard self.persistenceLease == lease, self.metadataWorldID() == world, !Task.isCancelled else { return }
                    _ = self.persistenceFailure(error)
                }
            }
        }
        return persistenceStatus == "ready"
    }

    private func persistenceReady() async -> Bool {
        rebuild()
        if persistenceStatus == "loading" { await persistenceTask?.value }
        return persistenceStatus == "ready"
    }
    private func persistenceFailure(_ error: Error) -> WorldScreenCommandOutcome {
        let code = (error as? RustScreenStateError)?.code ?? "screen_state_unavailable"
        persistenceStatus = "error"; persistenceNotice = "屏幕记录尚未确认，已暂停修改（\(code)）。"
        onPersistenceError?(persistenceNotice)
        snapshots = makeSnapshots()
        return .failure(.screenLoadFailed, persistenceNotice, details: ["cause":code])
    }
    private func persistDefinition(_ definition: WorldScreenDefinition) async -> WorldScreenCommandOutcome? {
        guard await persistenceReady() else { return .failure(.screenLoadFailed, persistenceNotice) }
        let world = metadataWorldID()
        do { try await source.persistDefinition?(definition) }
        catch { return persistenceFailure(error) }
        guard world == metadataWorldID() else { return .failure(.screenNotFound, "屏幕所属世界已切换。") }
        return nil
    }
    private func persistContent(_ content: WorldScreenContent) async -> WorldScreenCommandOutcome? {
        guard await persistenceReady() else { return .failure(.screenLoadFailed, persistenceNotice) }
        let world = metadataWorldID()
        do { try await source.persistContent?(content) }
        catch { return persistenceFailure(error) }
        guard world == metadataWorldID() else { return .failure(.screenNotFound, "屏幕所属世界已切换。") }
        return nil
    }
    private func removePersisted(_ objectID: String) {
        guard let remove = source.removePersisted, attemptedRemovals.insert(objectID).inserted else { return }
        let world = metadataWorldID()
        Task { @MainActor [weak self] in
            guard let self, self.metadataWorldID() == world else { return }
            do { try await remove(objectID) }
            catch { guard self.metadataWorldID() == world else { return }; _ = self.persistenceFailure(error) }
        }
    }

    private func resolve(objectID: String, state: WorldObjectState) {
        let calibratedJSON: String?
        if let override = calibrationOverrides[objectID] {
            calibratedJSON = WorldScreenDefinitionCoding.encode(override)
        } else if let stored = state.metadata[WorldScreenMetadataKey.definition] {
            calibratedJSON = stored
        } else {
            calibratedJSON = nil
        }
        let size = state.generatedProp.map {
            SIMD3<Float>($0.effectiveSize.x, $0.effectiveSize.y, $0.effectiveSize.z)
        }
        let allowsDefault = WorldScreenEligibility.isScreenCandidate(
            objectID: objectID, displayName: source.displayName(objectID)
        )
        switch WorldScreenResolution.resolve(
            objectID: objectID, calibratedJSON: calibratedJSON,
            size: size, allowsDefault: allowsDefault
        ) {
        case let .success(definition):
            definitions[objectID] = definition
            issues[objectID] = nil
            overlay.surface(for: objectID).geometryIssue = nil
            _ = loadContent(objectID: objectID, state: state)
        case let .failure(issue):
            definitions[objectID] = nil
            issues[objectID] = issue
            overlay.surface(for: objectID).geometryIssue = issue
        }
        placements[objectID] = (
            SIMD3<Float>(
                state.transform.position.x, state.transform.position.y, state.transform.position.z
            ),
            WorldPropAnchorRegistry.yaw(of: state.transform.rotation)
        )
    }

    private func loadContent(objectID: String, state: WorldObjectState) -> String? {
        // 会话内的内容优先（刚在面板里换的片），其次是落盘的那一份。
        if let content = contents[objectID] { return content.url }
        if let json = state.metadata[WorldScreenMetadataKey.content],
           let data = json.data(using: .utf8),
           let stored = try? JSONDecoder().decode(WorldScreenContent.self, from: data),
           stored.isValid, stored.objectID == objectID {
            contents[objectID] = stored
            return stored.url
        }
        // Async authority restoration completes before rebuild; no HTTP on a render tick.
        return nil
    }

    /// 本帧的屏幕四边形。只包含**几何成立**的屏幕 —— 缺几何的走具名失败，不是画一块空气。
    func worldQuads() -> (quads: [String: [SIMD3<Float>]], normals: [String: SIMD3<Float>]) {
        var quads: [String: [SIMD3<Float>]] = [:]
        var normals: [String: SIMD3<Float>] = [:]
        for (objectID, definition) in definitions {
            guard let placement = placements[objectID] else { continue }
            quads[objectID] = definition.quad.worldCorners(
                placedAt: placement.position, yaw: placement.yaw
            )
            normals[objectID] = definition.quad.worldNormal(yaw: placement.yaw)
        }
        return (quads, normals)
    }

    func updateOverlay(projection: WorldScreenProjection, camera: WorldScreenCamera) {
        let world = worldQuads()
        // 原生链接的屏幕由 Metal 深度缓冲遮挡，停止/恢复时也不回到网页覆盖层。
        let nativeSceneScreenIDs = Set(contents.compactMap { objectID, content in
            content.kind == .nativeLink ? objectID : nil
        })
        overlay.update(
            quads: world.quads, normals: world.normals, projection: projection,
            camera: camera, occluders: occluders(),
            nativeSceneScreenIDs: nativeSceneScreenIDs
        )
    }

    // MARK: 前景遮挡的输入

    /// 本帧的遮挡物。三份来源，都是**已经在手上的同一份几何**：
    ///
    /// 1. **房间**：`spatialStage.sceneOccluderTriangles` —— 渲染器做深度遮挡用的就是这一份
    ///    （`MarbleSpatialView` 的 GLB depth occluder pass），所以 CPU 判出来的"谁在前面"
    ///    与画面是同一套几何。它只在 `sceneOccluderRevision` 变了时才重取。
    /// 2. **物件**：`WorldObjectState.generatedCollisionVolume` 的同一套换算
    ///    （盒心 `position.y + size.y/2`、半长 `size/2`、绕 Y 的摆放旋转）。
    ///    跟着 `rebuild()`（6 Hz）走 —— 屏幕几何一轮装修最多变几次，没必要每帧读世界状态。
    /// 3. **居民**：`spatialStage.avatarPlacement` + `MarblePMXFraming` 的缺省包围盒
    ///    `±0.5 × 1.7 × ±0.5`（本地单位），乘上摆放 `scale` 就是世界尺寸。
    ///    这就是"角色站在屏前"那一件 —— 每拍重取（读一个结构体，比读世界状态便宜几个数量级）。
    private func occluders() -> WorldScreenOccluders {
        if occluderTrianglesRevision != spatialStage.sceneOccluderRevision {
            occluderTrianglesRevision = spatialStage.sceneOccluderRevision
            occluderTriangles = spatialStage.sceneOccluderTriangles.map {
                WorldScreenTriangle($0.first, $0.second, $0.third)
            }
        }
        var boxes = occluderPropBoxes
        let avatar = spatialStage.avatarPlacement
        let scale = avatar.scale.isFinite && avatar.scale > 0 ? avatar.scale : 1
        boxes.append(
            WorldScreenBox(
                center: avatar.position + SIMD3<Float>(0, 0.85 * scale, 0),
                halfExtents: SIMD3<Float>(0.5 * scale, 0.85 * scale, 0.5 * scale),
                yaw: avatar.yaw
            )
        )
        return WorldScreenOccluders(
            triangles: occluderTriangles, boxes: boxes,
            revision: spatialStage.sceneOccluderRevision
        )
    }

    /// 已摆放物件的遮挡盒。与 `WorldObjectState.generatedCollisionVolume` **逐字同式**。
    private func rebuildOccluderBoxes(from states: [String: WorldObjectState]) {
        var boxes: [WorldScreenBox] = []
        for (objectID, state) in states.sorted(by: { $0.key < $1.key }) where state.isEnabled {
            guard let prop = state.generatedProp else { continue }
            let size = prop.effectiveSize
            guard size.x > 0, size.y > 0, size.z > 0 else { continue }
            let position = state.transform.position
            boxes.append(
                WorldScreenBox(
                    center: SIMD3<Float>(
                        position.x, position.y + size.y / 2, position.z
                    ),
                    halfExtents: SIMD3<Float>(size.x / 2, size.y / 2, size.z / 2),
                    yaw: WorldPropAnchorRegistry.yaw(of: state.transform.rotation),
                    owner: objectID
                )
            )
        }
        occluderPropBoxes = boxes
    }

    /// 只有一帧的机会（世界刚加载/刚装修完）也要贴上。
    func updateNow() {
        rebuild()
        let projection = projectionProvider()
        let camera = WorldScreenCamera(
            position: spatialStage.camera.position,
            yaw: spatialStage.camera.yaw,
            pitch: spatialStage.camera.pitch
        )
        updateOverlay(projection: projection, camera: camera)
    }

    // MARK: WorldScreenControlling

    func listScreens() -> [WorldScreenSnapshot] {
        rebuild()
        return snapshots
    }

    /// 「还没被认成屏幕的物件」——`read_screen` 回答「是哪一件」的唯一来源。
    ///
    /// 判据全部取自**运行时**：物件状态（`source.objectStates()`，与屏幕几何同一份输入）、
    /// 名称判据（`WorldScreenEligibility`）与几何判据（`WorldScreenFaceInference.rejection`）。
    /// 它**只报事实**：不让任何物件变成能放的屏幕，也不改任何状态。
    ///
    /// 只报"像一块板"的物件：把屋里每一件东西（斧头、椅子、零件）都说成"还没被认成屏幕"
    /// 等于没有信息；像一块屏的那些才是用户可能指的那一件。
    func unrecognizedScreenCandidates() -> [WorldScreenCandidate] {
        rebuild()
        var candidates: [WorldScreenCandidate] = []
        for (objectID, state) in source.objectStates().sorted(by: { $0.key < $1.key }) {
            guard state.isEnabled,
                  definitions[objectID] == nil,
                  issues[objectID] == nil else { continue }
            let displayName = source.displayName(objectID)
            if WorldScreenEligibility.isScreenCandidate(objectID: objectID, displayName: displayName) {
                // 名字像电视却不在上面两个集合里：这一帧的世界状态与几何对不上
                // （刚被收回 / 刚换过）。如实说"没读出来"，不硬猜一个原因。
                candidates.append(WorldScreenCandidate(
                    objectID: objectID, displayName: displayName,
                    reason: "名字像电视，但这一帧没读出可用的屏幕范围"
                ))
                continue
            }
            guard let prop = state.generatedProp else { continue }
            let size = SIMD3<Float>(
                prop.effectiveSize.x, prop.effectiveSize.y, prop.effectiveSize.z
            )
            guard size.x > 0, size.y > 0, size.z > 0,
                  WorldScreenFaceInference.rejection(size: size, objectID: objectID) == nil
            else { continue }
            candidates.append(WorldScreenCandidate(
                objectID: objectID, displayName: displayName,
                reason: "这块面像一块屏幕，但名字里没有「电视」或「屏幕」"
            ))
        }
        return candidates
    }

    private func makeSnapshots() -> [WorldScreenSnapshot] {
        var ids = Set(definitions.keys)
        ids.formUnion(issues.keys)
        // 原生链接会话也投影出来（停掉之后仍可见"上次放的是什么、已停"）。
        ids.formUnion(nativeCoordinator.objectIDs)
        let stats = overlay.occlusionStats
        return ids.sorted().map { objectID in
            let definition = definitions[objectID]
            let surface = overlay.surfaces[objectID]
            let native = nativeCoordinator.snapshot(for: objectID)
            let nativeState = native?.state
            let preparationText: String? = {
                guard let nativeState, case .loading = nativeState else { return nil }
                return native?.cacheState?.panelText
            }()
            let stateText = (persistenceStatus == "error" ? persistenceNotice : nil)
                ?? issues[objectID]?.errorDescription
                ?? preparationText
                ?? nativeState?.displayText
                ?? surface?.state.displayText
                ?? "未开始"
            let isPlaying = native?.isPlaying ?? surface?.state.isPlaying ?? false
            // 面板/回执优先看原生状态；官方嵌入没有原生会话时才回落到覆盖层。
            let surfaceState: WorldScreenSurfaceState? = {
                if issues[objectID] != nil { return nil }
                return nativeState ?? surface?.state
            }()
            logOcclusionIfChanged(objectID: objectID, stat: stats[objectID])
            return WorldScreenSnapshot(
                objectID: objectID,
                displayName: source.displayName(objectID),
                source: definition?.source,
                note: definition?.note ?? "",
                aspect: definition?.quad.aspect ?? 0,
                geometryIssue: issues[objectID],
                contentURL: contents[objectID]?.url ?? native?.contentURL ?? surface?.requestedURL,
                stateText: stateText,
                isPlaying: isPlaying,
                occlusionText: stats[objectID]?.displayText,
                isBlocked: (stats[objectID]?.blockedCellCount ?? 0) > 0,
                // 几何给不出来时**不**把覆盖层那个状态交给面板：那一步会把"没有屏幕"
                // 借道 `.blocked` 说成"这个视频不让嵌进来放"（误导）。此时面板由
                // 上面那句"屏幕范围：还没认出来"负责说清楚。
                surfaceState: surfaceState
            )
        }
    }

    /// 「画面被挡住」这件事的**工程账**：只在**状态翻转**的那一次写一行日志。
    ///
    /// 面板上那句话是人话、且被挡期间逐字不变（`ScreenPanelCopy.occlusionLine`）；格数与
    /// 掩码耗时（"63/336 格"、"117.98 ms"）是给工程用的，所以它们走这里去
    /// `subsystem = ai.gmgn.radio` 的统一日志，**不进面板**（真机 2026-10-02「什么玩意儿」）。
    ///
    /// 为什么只在翻转时写：`makeSnapshots()` 每次刷新都会调它，而耗时每帧都在变 ——
    /// 每次都写就是刷屏，日志也就没人看了。
    private func logOcclusionIfChanged(objectID: String, stat: WorldScreenOcclusionStat?) {
        let isBlocked = (stat?.blockedCellCount ?? 0) > 0
        guard lastOcclusionLogged[objectID] != isBlocked else { return }
        lastOcclusionLogged[objectID] = isBlocked
        guard let stat else { return }
        screenPanelLogger.notice(
            "电视画面遮挡 物件=\(objectID, privacy: .public) 被挡=\(isBlocked, privacy: .public) \(stat.displayText, privacy: .public)"
        )
    }

    func playScreen(objectID: String?, rawContent: String) async -> WorldScreenCommandOutcome {
        rebuild()
        guard let target = resolveTarget(objectID) else {
            // 放不了时**具名且可行动**：「是哪一件还没被认成屏幕」+「怎么改」。
            // 一句笼统的"没有电视"会让居民只能回一句"我做不到"（真机 2026-10-02 现场）。
            let candidates = unrecognizedScreenCandidates()
            let named = candidates.prefix(3)
                .map { "「\($0.displayName)」（\($0.reason)）" }
                .joined(separator: "；")
            let message: String
            if let objectID {
                message = "这个空间里没有「\(objectID)」这台电视。"
                    + (candidates.isEmpty
                        ? "现在没有一件物件被认成屏幕。"
                        : "看起来像屏幕的有：\(named)，但它们还没被认成屏幕。")
            } else if candidates.isEmpty {
                message = "这个空间里现在没有电视：没有一件物件被认成屏幕。"
                    + "先生成一件名字里带「电视」或「屏幕」的物件，它就会被认成屏幕。"
            } else {
                message = "这个空间里现在没有电视。"
                    + "这些物件还没被认成屏幕：\(named)。把名字里带上「电视」或「屏幕」，或者换一件。"
            }
            return .failure(
                .screenNotFound, message,
                details: [
                    "unrecognized": String(candidates.count),
                    "unrecognized_ids": candidates.map(\.objectID).joined(separator: ","),
                ]
            )
        }
        if let issue = issues[target] {
            // 面板与 agent 共用 `message` ⇒ 说人话（"还没认出来，点「调整屏幕范围」"）；
            // 具名的几何原因（三边、比值、阈值）进 `details` 与日志。
            return .failure(
                .screenGeometryMissing,
                ScreenPanelCopy.screenRangeLine(source: nil, hasGeometryIssue: true),
                details: ["screen_id": target, "cause": issue.errorDescription]
            )
        }
        // **链接优先**：受支持的公开观看页先走原生（链接解析器 + AVPlayer）。
        // 只有原生理不了的东西（裸 id、站方嵌入页之外的输入）才回落到官方嵌入。
        if ScreenLinkSitePolicy.accepts(rawContent) {
            return await playNativeLink(
                target: target,
                pageURL: rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let url: URL
        switch WorldScreenEmbedPolicy.validate(rawContent) {
        case let .success(value):
            url = value
        case let .failure(issue):
            if issue == .missingInput {
                return .needsInput(issue.errorDescription, details: ["screen_id": target])
            }
            return .failure(
                .screenContentRejected, issue.errorDescription, details: ["screen_id": target]
            )
        }
        // 官方嵌入接管同一块屏时，先撤掉可能还活着的原生会话（过期结果不许复活）。
        nativeCoordinator.remove(target)
        let surface = overlay.surface(for: target)
        guard surface.state.isPlaying || overlay.canLoad(anotherThan: target) else {
            return .failure(
                .screenCapacityExceeded,
                "同时最多放 \(Self.maximumSimultaneousScreens) 台电视，先停一台。",
                details: ["screen_id": target, "playing": String(overlay.playingCount)]
            )
        }
        let content = WorldScreenContent(
            objectID: target, kind: .officialEmbed, url: url.absoluteString,
            title: WorldScreenEmbedPolicy.displayName(for: url)
        )
        if let failure = await persistContent(content) { return failure }
        contents[target] = content
        surface.geometryIssue = nil
        // **先挂网页视图，再载页**（2026-10-03：待机不再挂着网页视图，所以"挂上"这一步
        // 被挪到了播放这条路上）。造的这一次 WebKit 内容进程是这条通路唯一的**一次性**代价，
        // 它发生在页面开始加载**之前** —— 不叠在视频第一帧上。已经挂着时它是空操作。
        surface.attachWebViewIfNeeded()
        surface.load(url: url)

        // 等一小段时间：能当场具名报出来的失败，就在这**一次**调用里报出去，
        // 而不是留给下一次 `read_screen` 去发现。
        let deadline = ContinuousClock.now + Self.immediateFailureWindow
        while ContinuousClock.now < deadline {
            if case let .failed(failure) = surface.state {
                // `message` 是**面板与 agent 共用**的那一句 ⇒ 说人话（`panelText`）。
                // 工程口径的原因（HTTP 码 / WebKit 给的原话）进 `details` 与日志，
                // 不摆到面板上 —— 真机 2026-10-02「什么玩意儿」。
                return .failure(
                    .screenLoadFailed,
                    failure.panelText,
                    details: [
                        "screen_id": target, "url": url.absoluteString,
                        "cause": failure.errorDescription,
                    ]
                )
            }
            if surface.state.isPlaying { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        snapshots = makeSnapshots()
        return .ok(
            "\(source.displayName(target))："
                + (ScreenPanelCopy.statusLine(for: surface.state, isPlaying: surface.state.isPlaying)
                   ?? "已经放起来了。"),
            details: [
                "screen_id": target,
                "url": url.absoluteString,
                "source": WorldScreenEmbedPolicy.displayName(for: url),
                "state": surface.state.displayText,
            ]
        )
    }

    /// 网站链接原生播放：解析 → AVPlayer → 场景纹理登记。落盘只写**原始页面 URL**，
    /// 解析出来的签名媒资地址永远只活在内存里。
    private func playNativeLink(target: String, pageURL: String) async -> WorldScreenCommandOutcome {
        // 同一块屏可能还挂着官方的网页视图：先撤掉，避免双重画面。
        overlay.surface(for: target).stop()
        let nativePlaying = nativeCoordinator.playingObjectIDs().count
        if nativeCoordinator.snapshot(for: target)?.isPlaying != true,
           nativePlaying >= Self.maximumSimultaneousScreens {
            return .failure(
                .screenCapacityExceeded,
                "同时最多放 \(Self.maximumSimultaneousScreens) 台电视，先停一台。",
                details: ["screen_id": target, "playing": String(nativePlaying)]
            )
        }
        let site = ScreenLinkSitePolicy.site(forPageURL: pageURL)
        let content = WorldScreenContent(
            objectID: target, kind: .nativeLink, url: pageURL,
            title: site?.displayName ?? "网站链接"
        )
        if let failure = await persistContent(content) { return failure }
        contents[target] = content
        overlay.surface(for: target).geometryIssue = nil
        let outcome = await nativeCoordinator.play(
            objectID: target, pageURL: pageURL,
            quadProvider: { [weak self] in self?.worldQuads().quads[target] }
        )
        snapshots = makeSnapshots()
        return outcome
    }

    /// E2E 诊断专用：把一条 **file-based 媒体直链**（带音轨的 mp4 等）交给原生播放器。
    ///
    /// 生产 `playScreen` 的白名单只放受支持的公开观看页，直链会被
    /// `screenContentRejected` 拒绝；这个入口**只**在显式测试控制面
    /// （`GMGN_E2E_DATA_ROOT`）下被调用，用来证明 `MTAudioProcessingTap` 的真实 PCM
    /// 采样链对 file-based 媒体可用。它复用与生产**完全同一条** `NativeLinkPlayer`，
    /// 不改 `playScreen` 的白名单，也不碰 HLS 判据。
    func playDirectFileMediaForDiagnostics(
        objectID: String, url: String
    ) async -> WorldScreenCommandOutcome {
        rebuild()
        guard let target = resolveTarget(objectID) else {
            return .failure(
                .screenNotFound, "这个空间里没有「\(objectID)」这台电视。",
                details: ["screen_id": objectID]
            )
        }
        if let issue = issues[target] {
            return .failure(
                .screenGeometryMissing,
                ScreenPanelCopy.screenRangeLine(source: nil, hasGeometryIssue: true),
                details: ["screen_id": target, "cause": issue.errorDescription]
            )
        }
        overlay.surface(for: target).stop()
        let content = WorldScreenContent(
            objectID: target, kind: .nativeLink, url: url, title: "非 HLS 声音对照"
        )
        contents[target] = content
        // Diagnostic file URLs are output-only and are not valid durable page metadata.
        overlay.surface(for: target).geometryIssue = nil
        let outcome = await nativeCoordinator.playDirectFileMedia(
            objectID: target, fileURL: url, title: "非 HLS 声音对照",
            quadProvider: { [weak self] in self?.worldQuads().quads[target] }
        )
        snapshots = makeSnapshots()
        return outcome
    }

    func stopScreen(objectID: String?) -> WorldScreenCommandOutcome {
        rebuild()
        guard let target = resolveTarget(objectID) else {
            return .failure(.screenNotFound, "这个空间里没有可关的电视。")
        }
        nativeCoordinator.stop(target)
        overlay.surface(for: target).stop()
        snapshots = makeSnapshots()
        return .ok("已关掉\(source.displayName(target))。", details: ["screen_id": target])
    }

    func calibrateScreen(
        objectID: String, widthMeters: Float, heightMeters: Float, centerHeightMeters: Float
    ) async -> WorldScreenCommandOutcome {
        let quad = WorldScreenQuad(
            center: SIMD3<Float>(0, centerHeightMeters, 0),
            yaw: 0, pitch: 0,
            halfWidth: widthMeters / 2, halfHeight: heightMeters / 2
        )
        let note = String(
            format: "用户在面板里标定：宽 %.2f m × 高 %.2f m，中心高 %.2f m。",
            widthMeters, heightMeters, centerHeightMeters
        )
        let definition = WorldScreenDefinition(
            objectID: objectID, source: .calibrated, quad: quad, note: note
        )
        guard definition.isValid else {
            return .failure(
                .invalidArguments,
                "这个大小不合适：宽高要在 0.04–10 m 之间，中心高在 ±100 m 之内。"
            )
        }
        if let failure = await persistDefinition(definition) { return failure }
        calibrationOverrides[objectID] = definition
        definitions[objectID] = definition
        issues[objectID] = nil
        overlay.surface(for: objectID).geometryIssue = nil
        snapshots = makeSnapshots()
        // `message` 是面板与 agent 共用的那一句 ⇒ 人话；`note`（工程口径的那份原文）
        // 已经随定义落进 metadata，进 `details` 给工具看，不摆到面板上。
        return .ok(
            "\(source.displayName(objectID))的屏幕范围已经按你给的大小调好了。",
            details: ["screen_id": objectID, "note": note]
        )
    }

    /// 把一台电视**显式**指定成屏幕（给"名字里没有 tv 但确实是电视"的物件一条明路）。
    func designateScreen(objectID: String, size: SIMD3<Float>?) async -> WorldScreenCommandOutcome {
        switch WorldScreenResolution.resolve(
            objectID: objectID, calibratedJSON: nil, size: size, allowsDefault: true
        ) {
        case let .success(definition):
            if let failure = await persistDefinition(definition) { return failure }
            calibrationOverrides[objectID] = definition
            definitions[objectID] = definition
            issues[objectID] = nil
            snapshots = makeSnapshots()
            return .ok(
                "已经把\(source.displayName(objectID))当成电视了。",
                details: [
                    "screen_id": objectID,
                    "geometry_source": definition.source.rawValue,
                    "note": definition.note,
                ]
            )
        case let .failure(issue):
            return .failure(
                .screenGeometryMissing, issue.errorDescription, details: ["screen_id": objectID]
            )
        }
    }

    private func resolveTarget(_ objectID: String?) -> String? {
        if let objectID {
            return definitions[objectID] != nil || issues[objectID] != nil ? objectID : nil
        }
        let playable = Set(definitions.keys).union(issues.keys).sorted()
        return playable.count == 1 ? playable[0] : nil
    }
}
