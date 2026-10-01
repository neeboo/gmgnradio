import AppKit
import Foundation
import simd
import WorldRuntime

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
        let persistDefinition: (@MainActor (WorldScreenDefinition) -> Void)?
        /// 把屏幕内容**持久化**。为 nil 时同上。
        let persistContent: (@MainActor (WorldScreenContent) -> Void)?
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
    private let source: Source
    private let projectionProvider: @MainActor () -> WorldScreenProjection
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
    private var trackingTask: Task<Void, Never>?
    private var lastTrackingKey = ""
    private var tickCount = 0
    /// 最后一次覆盖层隐藏原因（诊断/面板可读）。
    var hiddenReasons: [String: String] { overlay.hiddenReasons }

    /// 每块屏幕最近一次的**前景遮挡**账（格数 + 耗时）。面板/`read_screen`/诊断读它。
    var occlusionStats: [String: WorldScreenOcclusionStat] { overlay.occlusionStats }

    init(
        spatialStage: SpatialStageStore,
        overlay: WorldScreenOverlayController,
        source: Source,
        projectionProvider: @escaping @MainActor () -> WorldScreenProjection
    ) {
        self.spatialStage = spatialStage
        self.overlay = overlay
        self.source = source
        self.projectionProvider = projectionProvider
    }

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
    private func tick(refreshEvery: Int) {
        tickCount += 1
        let projection = projectionProvider()
        let camera = WorldScreenCamera(
            position: spatialStage.camera.position,
            yaw: spatialStage.camera.yaw,
            pitch: spatialStage.camera.pitch
        )
        let key = Self.trackingKey(camera: camera, projection: projection)
        let needsRefresh = tickCount % refreshEvery == 0
        guard key != lastTrackingKey || needsRefresh else { return }
        lastTrackingKey = key
        overlay.setWorldVisible(spatialStage.isWorldVisible)
        if needsRefresh { rebuild() }
        updateOverlay(projection: projection, camera: camera)
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
        let states = source.objectStates()
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
            overlay.removeSurface(for: objectID)
        }
        for objectID in Array(issues.keys) where !seen.contains(objectID) {
            issues[objectID] = nil
            placements[objectID] = nil
            overlay.removeSurface(for: objectID)
        }
        snapshots = makeSnapshots()
    }

    private func resolve(objectID: String, state: WorldObjectState) {
        let calibratedJSON: String?
        if let override = calibrationOverrides[objectID] {
            calibratedJSON = WorldScreenDefinitionCoding.encode(override)
        } else {
            calibratedJSON = state.metadata[WorldScreenMetadataKey.definition]
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
        guard let json = state.metadata[WorldScreenMetadataKey.content],
              let data = json.data(using: .utf8),
              let stored = try? JSONDecoder().decode(WorldScreenContent.self, from: data),
              stored.isValid, stored.objectID == objectID
        else { return nil }
        contents[objectID] = stored
        return stored.url
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
        overlay.update(
            quads: world.quads, normals: world.normals, projection: projection,
            camera: camera, occluders: occluders()
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

    private func makeSnapshots() -> [WorldScreenSnapshot] {
        var ids = Set(definitions.keys)
        ids.formUnion(issues.keys)
        let stats = overlay.occlusionStats
        return ids.sorted().map { objectID in
            let definition = definitions[objectID]
            let surface = overlay.surfaces[objectID]
            let stateText = issues[objectID]?.errorDescription
                ?? surface?.state.displayText
                ?? "未开始"
            return WorldScreenSnapshot(
                objectID: objectID,
                displayName: source.displayName(objectID),
                source: definition?.source,
                note: definition?.note ?? "",
                aspect: definition?.quad.aspect ?? 0,
                geometryIssue: issues[objectID],
                contentURL: contents[objectID]?.url ?? surface?.requestedURL,
                stateText: stateText,
                isPlaying: surface?.state.isPlaying ?? false,
                occlusionText: stats[objectID]?.displayText
            )
        }
    }

    func playScreen(objectID: String?, rawContent: String) async -> WorldScreenCommandOutcome {
        rebuild()
        guard let target = resolveTarget(objectID) else {
            return .failure(
                .screenNotFound,
                objectID == nil
                    ? "这个空间里没有电视。先生成一件电视，或在面板里把一件物件标定成屏幕。"
                    : "这个空间里没有「\(objectID ?? "")」这台电视。"
            )
        }
        if let issue = issues[target] {
            return .failure(
                .screenGeometryMissing, issue.errorDescription, details: ["screen_id": target]
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
        let surface = overlay.surface(for: target)
        guard surface.state.isPlaying || overlay.canLoad(anotherThan: target) else {
            return .failure(
                .screenCapacityExceeded,
                "同时最多放 \(Self.maximumSimultaneousScreens) 块屏幕，先关一块。",
                details: ["screen_id": target, "playing": String(overlay.playingCount)]
            )
        }
        let content = WorldScreenContent(
            objectID: target, kind: .officialEmbed, url: url.absoluteString,
            title: WorldScreenEmbedPolicy.displayName(for: url)
        )
        contents[target] = content
        source.persistContent?(content)
        surface.geometryIssue = nil
        surface.load(url: url)

        // 等一小段时间：能当场具名报出来的失败，就在这**一次**调用里报出去，
        // 而不是留给下一次 `read_screen` 去发现。
        let deadline = ContinuousClock.now + Self.immediateFailureWindow
        while ContinuousClock.now < deadline {
            if case let .failed(failure) = surface.state {
                return .failure(
                    .screenLoadFailed,
                    failure.errorDescription,
                    details: ["screen_id": target, "url": url.absoluteString]
                )
            }
            if surface.state.isPlaying { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        snapshots = makeSnapshots()
        return .ok(
            "\(source.displayName(target))：\(surface.state.displayText)",
            details: [
                "screen_id": target,
                "url": url.absoluteString,
                "source": WorldScreenEmbedPolicy.displayName(for: url),
                "state": surface.state.displayText,
            ]
        )
    }

    func stopScreen(objectID: String?) -> WorldScreenCommandOutcome {
        rebuild()
        guard let target = resolveTarget(objectID) else {
            return .failure(.screenNotFound, "这个空间里没有可关的电视。")
        }
        overlay.surface(for: target).stop()
        snapshots = makeSnapshots()
        return .ok("已关掉\(source.displayName(target))。", details: ["screen_id": target])
    }

    func calibrateScreen(
        objectID: String, widthMeters: Float, heightMeters: Float, centerHeightMeters: Float
    ) -> WorldScreenCommandOutcome {
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
                "标定值不合理：宽高必须在 0.04–10 m，中心高必须在 ±100 m 内。"
            )
        }
        calibrationOverrides[objectID] = definition
        definitions[objectID] = definition
        issues[objectID] = nil
        overlay.surface(for: objectID).geometryIssue = nil
        source.persistDefinition?(definition)
        snapshots = makeSnapshots()
        return .ok("已标定\(source.displayName(objectID))：\(note)", details: ["screen_id": objectID])
    }

    /// 把一台电视**显式**指定成屏幕（给"名字里没有 tv 但确实是电视"的物件一条明路）。
    func designateScreen(objectID: String, size: SIMD3<Float>?) -> WorldScreenCommandOutcome {
        switch WorldScreenResolution.resolve(
            objectID: objectID, calibratedJSON: nil, size: size, allowsDefault: true
        ) {
        case let .success(definition):
            calibrationOverrides[objectID] = definition
            definitions[objectID] = definition
            issues[objectID] = nil
            source.persistDefinition?(definition)
            snapshots = makeSnapshots()
            return .ok(
                "已把\(source.displayName(objectID))当屏幕：\(definition.note)",
                details: ["screen_id": objectID, "geometry_source": definition.source.rawValue]
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
