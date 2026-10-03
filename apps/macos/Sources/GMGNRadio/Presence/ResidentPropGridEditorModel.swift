import Combine
import Foundation
import os
import simd
import WorldRuntime

/// 建造模式格子的**唯一真相来源**：网格、悬停格、footprint 判定与着色。
///
/// 分工：
/// - `WorldRuntime` 负责几何（`PropSupportGridBuilder` 派生、`PropPlacementEvaluator` 判定）；
/// - `PropSupportGridMapping` 负责纯映射与着色（可离线验证）；
/// - 本类型只做"持有 + 编排"，不自己算几何，也不自己决定颜色。
///
/// **缓存策略**：网格只依赖几何、种子与参数，**与已放物件无关**（`commitPropLayout` 只把
/// 物件包进碰撞世界，网格几何不变）。所以按调用方给的 `key`（例如 worldID）派生一次即可，
/// 每次放置都重建是浪费：真实生活舱一次派生在 -O 下约 0.5 s。
///
/// 缓存**跨装修会话存活**（`deactivate()` 只清"当前激活状态"，不丢网格）：真机 2026-09-28
/// 的阻塞缺陷里，Debug 构建一次派生要 4.8 s，而用户每次切窗口都会（错误地）关掉装修会话，
/// 于是派生永远跑不完、结果永远被丢弃。结果一旦算出来就必须留住 —— 同一个世界算一遍就够。
@MainActor final class ResidentPropGridEditorModel: ObservableObject {
    /// 派生这条链的常驻诊断（与宿主同一个 subsystem/category，`log show` 一条命令就能读全）。
    ///
    /// 为什么要它：真机 2026-09-28 的"面板永远说格子还在生成"之所以查了很久，是因为这条
    /// 链**每一步都是静默的** —— 缓存命中、算完被丢弃、派生出空网格，全都不留痕迹。
    /// 日志是 `.notice` 级：不带 `--info` 也能看到。
    static let log = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "LivingWorld")
    /// 建造模式是否开启。关闭时渲染层不该画格子，拾取也不该命中。
    @Published private(set) var isBuildModeActive = false
    @Published private(set) var grid: PropSupportGrid?
    @Published private(set) var report: PropSupportGridReport?
    /// 当前悬停的格子（已映射成呈现层类型）。
    @Published private(set) var hovered: PropSupportGridPresentation.Cell?
    /// 悬停位置放不下时的原因；nil 表示可放。文案由 `PropSupportBlockReason.errorDescription` 给出。
    @Published private(set) var hoveredBlockReason: PropSupportBlockReason?
    /// 需要着色的格子（footprint 内 + 悬停物件的发光）。缺省即"可放"。
    @Published private(set) var cellStates: [PropSupportGridPresentation.Cell: PropSupportGridPresentation.CellState] = [:]
    /// 当前 footprint 朝向（弧度，已归一化）。45° 步进由 `rotateFootprint(bySteps:)` 驱动。
    @Published private(set) var footprintYaw: Float = 0
    /// **靠墙可放**的格子数（面板读它）。与 `cellStates` 里 `.wallPlaceable` 的个数**同一个数**。
    @Published private(set) var wallPlaceableCellCount = 0
    /// 派生出来的竖直面（墙面）。**从既有几何派生**，与承托网格同一批三角形、同一份边界；
    /// 不存档、不写回，每次重开建造模式重算。
    private(set) var wallPatches: [WorldPropWallPatch] = []
    /// 靠墙可放的那批格子（与 footprint/发光同一份 `cellStates`，写入口只有 `publishCellStates`）。
    private var wallStates: [PropSupportGridPresentation.Cell: PropSupportGridPresentation.CellState] = [:]
    /// 上一次算靠墙可放时的输入签名：只在**物件或网格变了**时重算，鼠标移动不重算。
    private var wallVerdictKey: String?
    /// 一次重算最多给**每面墙**试几个候选（防御：真实舱体的墙很长、候选很多）。
    static let maximumWallCandidatesPerPatch = 12

    /// 一次派生的两样产物：承托网格 + 从同一批三角形派生出来的竖直面。
    private struct ResidentPropGridDerivation: Sendable {
        let grid: PropSupportGrid
        let walls: [WorldPropWallPatch]
    }
    /// 光标正悬停的**已摆物件**（The Sims 的 white glow 语义）。nil = 光标不在任何已摆物件上。
    ///
    /// 由宿主在每次光标移动时设置（见 `setHoveredProp`）。它**不是**"选中"：
    /// 选中/携带仍然是 `ResidentPropEditorState.selectedID` 那一条路。
    private(set) var hoveredPropID: String?

    /// 每次状态变更**之后**触发，供宿主把网格与着色转发给渲染层。
    ///
    /// 刻意不用 `objectWillChange`：它在变更**之前**发，订阅者读到的是旧值。
    var onGridChanged: (@MainActor () -> Void)?

    /// 格子的黄/红由**与落地完全相同的那条判定**回答。
    ///
    /// 为什么必须这么接：真机 2026-09-29 的缺陷是"格子说可放、一点却被拒绝" ——
    /// 着色那条路（`PropPlacementEvaluator`）完全不知道路点/通道，而落地那条路
    /// （`ResidentPropPlacementService.validate`）额外要求"居民还走得到活动锚点"。
    /// 273 个"可放=true"的去重格被服务拒绝 273/273，用户看到的却是一格绿。
    ///
    /// 现在两条路共用同一个出口：宿主把 `ResidentPropPlacementService.preview`
    /// （fail-closed，返回"能不能放 + 真正的原因"）包成这个闭包。于是
    ///
    /// - 服务会接受 ⇒ footprint 黄（可放）；
    /// - 服务会拒绝 ⇒ footprint 红，且 `hoveredBlockReason` 就是**服务给出的那个原因**
    ///   （不再是评估器那条不知道路点的路给出的 nil）。
    ///
    /// 判据仍然只有一条：能不能放由服务回答，`fail-closed` 一个字都没放宽。
    var verdictForPlacement: (@MainActor (_ objectID: String, _ footprint: SIMD2<Float>, _ height: Float,
                                          _ position: WorldVector3, _ yaw: Float) -> PropSupportBlockReason?)?

    /// 判定结果的**有界缓存**：`格心 + 朝向(+物件)` → 判定。
    ///
    /// 为什么需要：这一条判定要跑完整服务校验（实测真实舱体冷调用中位 0.11 ms、p95 4.6 ms），而 `updateHover`
    /// 每次鼠标移动都会跑。鼠标在同一格内移动本来就已经被 `snappedPlacement` 那一层挡住，
    /// 但"在同一块 footprint 里挪半格""来回划过同一行格子"仍然会重复问同一个格子。
    /// 缓存让重复询问变成 O(1)。
    ///
    /// 失效点只有一处：`ResidentPropEditorState.update(_:)` 收到新快照（`revision` 变了）
    /// 时宿主会调 `invalidateVerdicts()` —— 判定依赖"房间里现在有什么"，revision 是那条
    /// 事实的版本号。
    private struct VerdictKey: Hashable {
        let x: Float
        let y: Float
        let z: Float
        let yaw: Float
        let width: Float
        let height: Float
        let depth: Float
    }
    /// 上界：一个 footprint 的候选格 + 8 个朝向远小于它，超过就整体丢弃（不淘汰单条，
    /// 避免在"用户正在犹豫"的时候把最常命中的那一条淘汰掉）。
    static let verdictCacheLimit = 4096
    private var verdicts: [VerdictKey: PropSupportBlockReason?] = [:]
    /// 缓存命中/未命中计数（诊断与实测用）。
    private(set) var verdictCacheHits = 0
    private(set) var verdictCacheMisses = 0

    private var collision: (any WorldPropSupportQuerying)?
    private var gridKey: String?
    /// **与装修会话无关**的承托几何：许愿机的自动摆放（agent 的 `apply_prop_placement`、
    /// 入库落位）不需要装修面板开着，但几何过去只在 `activate`（进入装修）时派生 ——
    /// 于是面板关着时 `list_placement_surfaces` 为空、摆放一律 fail-closed。
    ///
    /// 这一份由 `preparePlacementSupport` 在**世界加载后**准备，`deactivate()` 不碰它：
    /// 装修会话的开关只决定"画不画格子、拾不拾取"，不该决定"能不能摆放"。
    /// 只按世界 key 生效（`supportForPlacement(key:)`），换世界时旧的几何不会冒充新的。
    private var placementGrid: PropSupportGrid?
    private var placementCollision: (any WorldPropSupportQuerying)?
    /// **最近一次请求**摆放几何的世界（派生在飞时也会先写下）。
    private var placementKey: String?
    /// `placementGrid` **真的装的是哪个世界**的几何。只在网格写回时更新，
    /// 于是"新世界的派生还没完成、旧世界的网格还在"不会被当成新世界的几何（fail-closed）。
    private var placementGridKey: String?
    /// 当前**激活会话**的世界键（`activate` 一开始就写下，`deactivate` 清掉）。
    ///
    /// 与 `gridKey`（"已经就绪的那份网格属于谁"）分开：派生是异步的，一次派生跑完时
    /// 会话可能已经换到别的世界了 —— 那种结果只能进缓存，不能写回激活状态。
    private var activeKey: String?
    /// 派生结果的**按世界缓存**（最近使用在后，上界 `retainedGridLimit`）。
    ///
    /// 值类型 `PropSupportGrid` 是 `Sendable` 的不可变快照，本类型又是 `@MainActor`，
    /// 所以这份持有不引入任何跨线程共享（`SWIFT_STRICT_CONCURRENCY: complete` 下合法）。
    private var cachedGrids: [String: PropSupportGrid] = [:]
    /// 与 `cachedGrids` 同键的竖直面（同一次派生算出来的，命中缓存时一起复用）。
    private var cachedWalls: [String: [WorldPropWallPatch]] = [:]
    private var cachedGridOrder: [String] = []
    /// 缓存上界：只保留最近这么多个世界的网格，避免换世界时无限增长。
    static let retainedGridLimit = 2
    /// 当前缓存的网格数（诊断用）。
    var retainedGridCount: Int { cachedGrids.count }
    private var cells: [PropSupportGridPresentation.Cell] = []
    private var candidates: [PropSupportGridPicker.Candidate] = []
    private var layerRefs: [PropSupportColumn: [Int: PropSupportLayerRef]] = [:]

    /// 最近一次评估的输入。旋转时要据此重算着色，而不需要新的光标位置。
    private struct EvaluationInputs {
        /// 手上这一件的 objectID（= 落地时交给摆放服务的那个）。
        let objectID: String
        let footprintSize: SIMD2<Float>
        let height: Float
        let blockingVolumes: [WorldCollisionVolume]
        let placedProps: [WorldCollisionVolume]
    }
    private var evaluationInputs: EvaluationInputs?
    private var hoveredLayerRef: PropSupportLayerRef?
    /// 当前 footprint 的判定着色（不含悬停发光）。`publishCellStates()` 把它与发光合并。
    private var footprintStates: [PropSupportGridPresentation.Cell: PropSupportGridPresentation.CellState] = [:]
    private var hoverTarget: HoverTarget?

    var isReady: Bool { grid != nil }
    /// 摆放校验需要的碰撞世界（能给出三角形）。与 `grid` 同时可用，否则为 nil。
    var supportCollision: (any WorldPropSupportQuerying)? { collision }

    /// 「居民还走不走得到活动锚点」用的**移动图**（收窄后的唯一一条路点判据）。
    ///
    /// 只依赖派生出的承托网格与"可站带"，**与已放物件无关** —— 所以按网格缓存一份，
    /// 换网格（换世界 / 重新派生）时自动重建。建图实测 1.6 ms（真机舱体 3160 层 / 2948
    /// 个可站节点，-O，n=5），一次派生只付一次。
    private var routeMap: WorldPlacementRouteMap?
    /// 移动图缓存属于哪一份网格。用网格的层数当身份（同一世界重复派生出的层数一致，
    /// 换世界/换参数则不同），并额外在 `setRouteBand` / `deactivate` 处显式失效。
    private var routeMapLayerCount: Int?
    private var routeBand: (lower: Float, upper: Float)?

    /// 告诉模型"可站立的承托带"在哪（来自世界里的路点高度：居民只在这些高度上走）。
    ///
    /// 必须在服务开始判摆放**之前**调用一次（`GMGNRadioApp.activateResidentPropGrid`），
    /// 否则移动图拿不到范围，判据走 fail-closed（拒绝摆放）而不是放行。
    func setRouteBand(lower: Float, upper: Float) {
        routeBand = (lower, upper)
        routeMap = nil
        routeMapLayerCount = nil
    }

    /// 从世界路点推"可站带"：居民只在这些高度上站立/行走，桌面与屋顶都在带外。
    ///
    /// 唯一一份推导：生产宿主与离线 harness 都走这里，避免两处各抄一个 margin。
    /// 路点为空（或全部停用）时返回 false ⇒ 拿不到可站带 ⇒ 拒绝摆放（fail-closed）。
    @discardableResult
    func setRouteBand(fromWaypoints waypoints: [WorldWaypoint], margin: Float = 0.2) -> Bool {
        let heights = waypoints.filter(\.enabled).map(\.position.y)
        guard let lowest = heights.min(), let highest = heights.max() else { return false }
        setRouteBand(lower: lowest - margin, upper: highest + margin)
        return true
    }

    /// 从活动锚点表推 `RouteConstraint`（收窄判据的**世界固有**锚点部分）。
    ///
    /// 锚点 = `WorldActivityAnchor.entryWaypointID`：活动一律先走到它的入口路点，
    /// 所以"每个锚点都要能站、要走得到"就是居民真正需要的东西；639 个 `wp.auto.*`
    /// 只是中间路点，运行时本来就会绕路。
    ///
    /// **道具功能点锚点不在这里**：它们没有烘焙几何（`entryWaypointID == nil`），
    /// 由摆放服务在判定时从**候选状态**派生出来并合并进来（`WorldPropAnchorRegistry`
    /// 是唯一来源）。这里跳过它们不是放宽判据 —— 那个集合只会更全，不会更松。
    ///
    /// 拿不到地图、或锚点一个都对不上路点 ⇒ nil ⇒ 服务拒绝摆放（fail-closed）。
    func routeConstraint(activities: [WorldActivityAnchor],
                         waypoints: [WorldWaypoint]) -> ResidentPropPlacementSupport.RouteConstraint? {
        guard let map = placementRouteMap() else { return nil }
        var positions: [String: WorldVector3] = [:]
        for activity in activities {
            guard let entryWaypointID = activity.entryWaypointID,
                  let waypoint = waypoints.first(where: {
                      $0.id == entryWaypointID && $0.enabled
                  }) else { continue }
            // 病态输入（非有限 / 离谱的世界坐标）一律当作"拿不到判据" ⇒ 拒绝摆放。
            // 绝不能把它们喂进移动图：列号换算会溢出，而"溢出"不是一条判据。
            guard Self.isUsableWorldPosition(waypoint.position) else {
                Self.log.notice("摆放判据：锚点位置不可用 \(entryWaypointID, privacy: .public)，按 fail-closed 处理")
                return nil
            }
            positions[entryWaypointID] = waypoint.position
        }
        guard !positions.isEmpty else { return nil }
        return .init(map: map, anchorIDs: positions.keys.sorted(), anchorPositions: positions)
    }

    /// 世界坐标是否可用作判据输入：有限，且换算成列号不会溢出（|坐标| / 间距 < 1e6 与
    /// `Int` 余量都够）。
    static func isUsableWorldPosition(_ position: WorldVector3) -> Bool {
        let limit: Float = 1e6
        return position.x.isFinite && position.y.isFinite && position.z.isFinite
            && abs(position.x) < limit && abs(position.y) < limit && abs(position.z) < limit
    }

    /// 当前的移动图（按需建、按网格缓存）。拿不到网格/范围时返回 nil ⇒ 服务拒绝摆放。
    func placementRouteMap() -> WorldPlacementRouteMap? {
        // 移动图按**承托几何**建：装修会话激活时用激活中的那一份，否则用与面板无关的
        // 保留位（世界加载后由 `preparePlacementSupport` 备好）。两者都是同一个世界的同一份网格。
        guard let grid = placementGrid ?? grid, let routeBand else { return nil }
        if let routeMap, routeMapLayerCount == grid.layers.count { return routeMap }
        let map = WorldPlacementRouteMap(
            grid: grid,
            lowerHeight: routeBand.lower,
            upperHeight: routeBand.upper
        )
        Self.log.notice(
            "摆放判据：移动图已建 可站节点=\(map.standableNodeCount, privacy: .public) 带=[\(routeBand.lower, privacy: .public), \(routeBand.upper, privacy: .public)]"
        )
        routeMap = map
        routeMapLayerCount = grid.layers.count
        return map
    }
    /// 供渲染层使用的格子，与 `cellStates` 同一坐标系（缺省状态的格子也在这里）。
    var renderCells: [PropSupportGridPresentation.Cell] { cells }
    var spacing: Float { grid?.spacing ?? PropSupportGridParameters.default.spacing }

    /// 开启建造模式并（按需）派生网格。
    ///
    /// `key` 用来避免重复派生：同一个 key 且已有网格时直接复用。调用方应传能代表"几何身份"
    /// 的值（worldID 即可）——已放物件的增删不改变几何，不需要重新派生。
    func activate(
        collision: any WorldPropSupportQuerying,
        seed: WorldVector3,
        bounds: WorldPlanarBounds,
        key: String,
        parameters: PropSupportGridParameters = .default
    ) async {
        self.collision = collision
        // 装修会话用的就是摆放服务的那一份几何：一起记进"与面板无关"的保留位，
        // 于是退出装修之后 `list_placement_surfaces` / 摆放仍然可用。
        // **碰撞世界与网格同生共死**（都只在装填时写），避免"网格还是 A、碰撞已是 B"。
        placementKey = key
        isBuildModeActive = true
        activeKey = key
        if let cached = cachedGrids[key] {
            // 已有同一份几何的网格（哪怕上一次装修会话已经退出）：只把缓存重新指向它，
            // 不重新派生 —— 这就是"重开装修不再等 4.8 s"。
            touchCachedGrid(key)
            grid = cached
            placementGrid = cached
            placementCollision = collision
            placementGridKey = key
            report = cached.report
            gridKey = key
            Self.log.notice("格子派生：命中缓存 key=\(key, privacy: .public) 层=\(cached.layers.count, privacy: .public) 墙面=\(self.cachedWalls[key]?.count ?? -1, privacy: .public)")
            rebuildCaches(from: cached)
            setWallPatches(cachedWalls[key] ?? [])
            clearHover()
            onGridChanged?()
            return
        }
        Self.log.notice(
            "格子派生：开始 key=\(key, privacy: .public) 已缓存网格=\(self.cachedGrids.count, privacy: .public)/\(Self.retainedGridLimit, privacy: .public)"
        )
        let startedAt = ContinuousClock.now
        let built = await Self.buildDerivation(collision: collision, seed: seed, bounds: bounds, parameters: parameters)
        let elapsed = startedAt.duration(to: .now)
        // 算完的东西**先留在缓存里**：关掉面板不该丢掉一次已经跑完的派生（"同一世界算一遍就够"）。
        // 之前这里在写回之前就返回，于是"关掉再打开"每次都要从头再算一遍。
        storeCachedGrid(built.grid, key: key)
        cachedWalls[key] = built.walls
        // 派生期间编辑器可能已经被关掉（明确意图）或切到了别的世界：那就别把结果写回**激活状态**。
        guard activeKey == key, gridKey != key else {
            // 这条过去是完全静默的：一次算完的派生被丢掉，外面却还留着"请求过"的印记。
            // 真机排查必须能一眼看出是**哪一半**把它丢掉的。
            Self.log.notice("格子派生：结果已进缓存但未写回激活状态（建造模式开着=\(self.isBuildModeActive, privacy: .public) 缓存键相同=\(self.gridKey == key, privacy: .public) 激活键=\(self.activeKey ?? "nil", privacy: .public)）key=\(key, privacy: .public)")
            return
        }
        grid = built.grid
        placementGrid = built.grid
        placementCollision = collision
        placementGridKey = key
        report = built.grid.report
        gridKey = key
        rebuildCaches(from: built.grid)
        setWallPatches(built.walls)
        clearHover()
        let report = built.grid.report
        Self.log.notice(
            "格子派生：完成 key=\(key, privacy: .public) 耗时=\(elapsed.description, privacy: .public) 层=\(built.grid.layers.count, privacy: .public) 列=\(self.cells.count, privacy: .public) 种上=\(report.seeded, privacy: .public) 过滤前=\(report.layersBeforeFilter, privacy: .public)"
        )
        onGridChanged?()
    }

    /// 派生是**纯计算**，真实舱体一次要 0.5 s（-O）/ 6.6 s（-Onone）：放后台，别卡住调用帧。
    /// `PropSupportGrid` 与 `WorldPropWallPatch` 都是 Sendable。
    private static func buildDerivation(
        collision: any WorldPropSupportQuerying,
        seed: WorldVector3,
        bounds: WorldPlanarBounds,
        parameters: PropSupportGridParameters
    ) async -> ResidentPropGridDerivation {
        await Task.detached(priority: .userInitiated) {
            let grid = PropSupportGridBuilder.build(
                collision: collision,
                bounds: bounds,
                seed: seed,
                parameters: parameters
            )
            // 竖直面从**同一批三角形**派生（与承托网格同一次范围查询），不新开一份世界几何。
            let walls = WorldPropWallGrid.derive(
                triangles: collision.triangles(in: bounds), bounds: bounds, grid: grid
            )
            return ResidentPropGridDerivation(grid: grid, walls: walls)
        }.value
    }

    /// 为**摆放**准备好承托几何：与装修面板是否打开无关。
    ///
    /// 世界加载后由宿主调用（`GMGNRadioApp.prepareResidentPlacementSupport`），
    /// 命中缓存立即返回，否则后台派生。它**不打开装修会话、不向渲染层发布格子**：
    /// 面板的开关只决定"画不画、拾不拾取"，不该决定 agent 能不能摆放。
    func preparePlacementSupport(
        collision: any WorldPropSupportQuerying,
        seed: WorldVector3,
        bounds: WorldPlanarBounds,
        key: String,
        parameters: PropSupportGridParameters = .default
    ) async {
        placementKey = key
        if let cached = cachedGrids[key] {
            touchCachedGrid(key)
            placementGrid = cached
            placementCollision = collision
            placementGridKey = key
            Self.log.notice("摆放承托几何：命中缓存 key=\(key, privacy: .public) 层=\(cached.layers.count, privacy: .public)")
            return
        }
        Self.log.notice("摆放承托几何：开始派生 key=\(key, privacy: .public)")
        let built = await Self.buildDerivation(collision: collision, seed: seed, bounds: bounds, parameters: parameters)
        storeCachedGrid(built.grid, key: key)
        cachedWalls[key] = built.walls
        // 派生期间可能已经换世界：只把结果写给**仍然是最新摆放目标**的那一个 key。
        guard placementKey == key else { return }
        placementGrid = built.grid
        placementCollision = collision
        placementGridKey = key
        Self.log.notice("摆放承托几何：完成 key=\(key, privacy: .public) 层=\(built.grid.layers.count, privacy: .public)")
    }

    /// 摆放服务读取的承托几何。按世界 key 校验：拿不到就是 nil（服务 fail-closed），
    /// 绝不拿上一个世界的几何冒充当前世界。装修会话激活中的那一份优先。
    func supportForPlacement(key: String) -> (grid: PropSupportGrid, collision: any WorldPropSupportQuerying)? {
        if let grid, let collision, gridKey == key { return (grid, collision) }
        guard placementGridKey == key, let placementGrid, let placementCollision else { return nil }
        return (placementGrid, placementCollision)
    }

    /// 直接装一份**已经派生好的**网格（连同能给出三角形的碰撞世界）。
    ///
    /// 与 `activate` 的差别：`activate` 会自己去派生（真实舱体 -O 下约 8 s）。
    /// 这里给的是"别人已经算出来的同一份几何"，用于：
    /// - 离线 harness 在**真实舱体**派生网格上驱动着色/判定（推导一次，反复用）；
    /// - 将来宿主把派生结果从别处接手时复用同一条装填路径（不是测试专用 API）。
    func installDerivedGrid(_ grid: PropSupportGrid,
                            collision: any WorldPropSupportQuerying,
                            key: String) {
        self.collision = collision
        placementCollision = collision
        placementKey = key
        placementGrid = grid
        placementGridKey = key
        isBuildModeActive = true
        activeKey = key
        storeCachedGrid(grid, key: key)
        self.grid = grid
        report = grid.report
        gridKey = key
        rebuildCaches(from: grid)
        clearHover()
        onGridChanged?()
    }

    /// 停用**当前激活会话**：渲染层立刻不该再画格子，拾取也不该命中。
    ///
    /// 但**不丢网格本身**：几何与"这次装修会话开没开"无关，重开同一个世界时直接复用
    /// （见 `activate` 的命中分支）。只有 LRU 上界（`storeCachedGrid`）会淘汰它。
    func deactivate() {
        Self.log.notice(
            "格子派生：停用（此前缓存键=\(self.gridKey ?? "nil", privacy: .public)，已缓存网格=\(self.cachedGrids.count, privacy: .public)/\(Self.retainedGridLimit, privacy: .public)）"
        )
        isBuildModeActive = false
        activeKey = nil
        onGridChanged?()
        grid = nil
        report = nil
        gridKey = nil
        collision = nil
        cells = []
        candidates = []
        layerRefs = [:]
        hoveredPropID = nil
        hoverTarget = nil
        wallPatches = []
        wallStates = [:]
        wallVerdictKey = nil
        wallPlaceableCellCount = 0
        clearHover()
        onGridChanged?()
    }

    /// 把一份派生结果放进按世界的缓存，并按 LRU 上界淘汰最老的。
    ///
    /// 刻意**与"当前有没有在装修"无关**：一次跑完的派生结果不能因为用户关了面板就消失。
    private func storeCachedGrid(_ grid: PropSupportGrid, key: String) {
        cachedGrids[key] = grid
        cachedGridOrder.removeAll { $0 == key }
        cachedGridOrder.append(key)
        while cachedGridOrder.count > Self.retainedGridLimit {
            // 只淘汰**不是当前激活会话**的那一份：激活中的网格必须始终留在缓存里，
            // 否则"退出装修 → 重进"会退化回重新派生。
            guard let index = cachedGridOrder.firstIndex(where: { $0 != activeKey }) else { return }
            let evicted = cachedGridOrder.remove(at: index)
            cachedGrids[evicted] = nil
            Self.log.notice(
                "格子派生：缓存淘汰 key=\(evicted, privacy: .public) 上界=\(Self.retainedGridLimit, privacy: .public)"
            )
        }
    }

    /// 标记某个世界的网格是"最近用过"的（命中缓存时调用）。
    private func touchCachedGrid(_ key: String) {
        cachedGridOrder.removeAll { $0 == key }
        cachedGridOrder.append(key)
    }

    /// 光标移到一件**已摆出来的**物件上：它的 footprint 格子进入 `.hoverTarget`（发光）。
    ///
    /// 唯一一份尺寸来源是 `WorldObjectState.generatedCollisionVolume`（摆放/碰撞用的那个盒子），
    /// 所以"看起来在发光的范围"与"系统认为它占的地方"是同一个事实。
    ///
    /// `placement` 语义上与 `ResidentPropEditorState.select(objectID:)` 初始化携带态用的是同一个
    /// 事实（物件自己的 transform），所以"发光的 footprint"就是"拿起来后跟着鼠标的那块 footprint"。
    func setHoveredProp(objectID: String, volume: WorldCollisionVolume) {
        guard isBuildModeActive, grid != nil else { return }
        let yaw = Self.yaw(of: volume.rotation)
        guard yaw.isFinite else { return }
        let spacing = self.spacing
        guard spacing.isFinite, spacing > 0,
              volume.halfExtents.x > 0, volume.halfExtents.z > 0 else { return }
        // 摆件的位置是**格心**（列最小角 + 半格），所以列号 = `floor(格心 / 间距)` ——
        // 与 `PropSupportGridPicker.pick` 把命中点量化成列用的是同一条换算（这里不另立一份）。
        let column = PropSupportColumn(
            x: Int((volume.center.x / spacing).rounded(.down)),
            z: Int((volume.center.z / spacing).rounded(.down))
        )
        let target = HoverTarget(
            objectID: objectID,
            column: column,
            // 盒底 = 它坐在哪一层承托面上（高度容差与摆放校验同口径）。
            supportHeight: volume.center.y - volume.halfExtents.y,
            footprint: WorldPlanarFootprint(
                size: SIMD2(volume.halfExtents.x * 2, volume.halfExtents.z * 2), yaw: yaw
            )
        )
        // 光标在**同一件**物件上继续移动（每秒几十次）不该重算整块 footprint 的着色。
        guard target != hoverTarget else { return }
        hoverTarget = target
        hoveredPropID = objectID
        publishCellStates()
    }

    /// 光标离开所有已摆物件（或进入携带态、装修结束）：熄掉发光。
    func clearHoveredProp() {
        guard hoveredPropID != nil || hoverTarget != nil else { return }
        hoveredPropID = nil
        hoverTarget = nil
        publishCellStates()
    }

    func clearHover() {
        hovered = nil
        hoveredBlockReason = nil
        hoveredLayerRef = nil
        evaluationInputs = nil
        footprintStates = [:]
        publishCellStates()
    }

    /// 45° 步进旋转（步长在 `PropSupportGridMapping.yaw(rotatedBySteps:from:)`）。
    /// 旋转后立刻按上一次的评估输入重算整块 footprint 的着色，
    /// 这样用户按住旋转键就能看到绿/红跟着转。
    func rotateFootprint(bySteps steps: Int) {
        footprintYaw = PropSupportGridMapping.yaw(rotatedBySteps: steps, from: footprintYaw)
        reevaluateFootprint()
        onGridChanged?()
    }

    /// 光标 → 最近格子 → footprint 整体判定 → 整块着色。
    ///
    /// 纯 CPU：格子平面 `y = supportHeight` 与光标射线闭式求交，不做 GPU readback。
    func updateHover(
        normalizedCursor: SIMD2<Float>,
        inverseViewProjection: simd_float4x4,
        footprintSize: SIMD2<Float>,
        height: Float,
        objectID: String,
        blockingVolumes: [WorldCollisionVolume],
        placedProps: [WorldCollisionVolume],
        maximumDistance: Float = 30
    ) {
        guard isBuildModeActive, let grid, collision != nil else {
            clearHover()
            return
        }
        guard let picked = PropSupportGridPicker.pick(
            normalized: normalizedCursor,
            inverseViewProjection: inverseViewProjection,
            candidates: candidates,
            spacing: grid.spacing,
            maximumDistance: maximumDistance
        ) else {
            clearHover()
            return
        }
        let column = PropSupportColumn(x: picked.columnX, z: picked.columnZ)
        guard let layerRef = layerRefs[column]?[picked.layer] else {
            clearHover()
            return
        }
        hoveredLayerRef = layerRef
        // 房间里的摆设变了 ⇒ 那一批"这一格能不能放"的答案全部作废。
        //
        // 缓存按「格心 + 朝向 + 物件尺寸」存，而判定的输入还包括"房间里现在摆着什么"
        // （`placedProps` / `blockingVolumes`）。输入变了还复用旧答案，红/绿就会与落地判定
        // 分叉 —— 那正是这次要修的缺陷，绝不能靠缓存重新引入。宿主收到新快照时也会调
        // `invalidateVerdicts()`（revision 是另一个失效信号），这里是**按输入**的那一道。
        if evaluationInputs?.placedProps != placedProps
            || evaluationInputs?.blockingVolumes != blockingVolumes {
            invalidateVerdicts()
        }
        evaluationInputs = EvaluationInputs(
            objectID: objectID,
            footprintSize: footprintSize,
            height: height,
            blockingVolumes: blockingVolumes,
            placedProps: placedProps
        )
        // 靠墙可放：与地板判定同一组输入（物件 + 尺寸 + 房间现状），同一**判定出口**。
        refreshWallPlaceability(
            objectID: objectID, footprintSize: footprintSize, height: height
        )
        reevaluateFootprint()
    }

    /// 吸附后的摆放位置与朝向（格心 + 当前 footprint 朝向）。没有悬停时返回 nil。
    var snappedPlacement: (position: SIMD3<Float>, yaw: Float)? {
        guard let layerRef = hoveredLayerRef, grid != nil else { return nil }
        return (
            PropSupportGridMapping.snappedPlacementPosition(
                columnX: layerRef.column.x,
                columnZ: layerRef.column.z,
                spacing: spacing,
                supportHeight: layerRef.supportHeight
            ),
            footprintYaw
        )
    }

    /// 悬停所在层的标识。`surfaceID` 现在是层标识，不再是具名摆放面。
    var hoveredLayerName: String? {
        hoveredLayerRef.map { "grid.layer\($0.layer)" }
    }

    /// 当前悬停是否可放（`hoveredBlockReason == nil` 且有悬停）。
    var canPlaceAtHover: Bool { hoveredLayerRef != nil && hoveredBlockReason == nil }

    // MARK: - 内部

    /// 光标下那件已摆物件的**发光轮廓**。
    private struct HoverTarget: Equatable {
        let objectID: String
        let column: PropSupportColumn
        let supportHeight: Float
        let footprint: WorldPlanarFootprint
    }

    /// 悬停发光与"坐在哪一层"共用的高度容差。与
    /// `ResidentPropPlacementService.supportLayer(at:grid:)` 的 0.005 m 同口径：
    /// 两处不一致的话，发光会落在物件**旁边**那一层上。
    private static let hoverTargetHeightTolerance: Float = 0.005

    /// 四元数 → 绕 y 的 yaw。与 `ResidentPropEditorState.select(objectID:)` 用的是同一个式子
    /// （摆放与发光必须对同一件物件得到同一个朝向）。
    private static func yaw(of rotation: WorldQuaternion) -> Float {
        atan2(2 * (rotation.w * rotation.y + rotation.x * rotation.z),
              1 - 2 * (rotation.y * rotation.y + rotation.z * rotation.z))
    }

    private func rebuildCaches(from grid: PropSupportGrid) {
        let layers = grid.layers.map { layer in
            PropSupportGridMapping.LayerInput(
                columnX: layer.column.x,
                columnZ: layer.column.z,
                layer: layer.layer.layer,
                supportHeight: layer.supportHeight,
                spacing: grid.spacing
            )
        }
        cells = PropSupportGridMapping.presentationCells(layers)
        candidates = PropSupportGridMapping.pickerCandidates(layers)
        var refs: [PropSupportColumn: [Int: PropSupportLayerRef]] = [:]
        for layer in grid.layers { refs[layer.column, default: [:]][layer.layer.layer] = layer }
        layerRefs = refs
    }

    /// 悬停物件的 footprint 格子。**写进 `cellStates` 就同时决定了焦点裁剪的锚点**
    /// （`PropSupportGridPresentation.focus` 的 `core` 就是 `states` 的键），
    /// 所以发光只能出现在"物件脚下那一小块 + 两圈淡格"里 —— 它不可能绕开裁剪去铺满地面。
    private func hoverTargetStates() -> [PropSupportGridPresentation.Cell: PropSupportGridPresentation.CellState] {
        guard let target = hoverTarget, let grid else { return [:] }
        let spacing = grid.spacing
        guard spacing.isFinite, spacing > 0 else { return [:] }
        let columns = Set(
            target.footprint.columns(anchoredAt: target.column, spacing: spacing)
                .map { PropSupportGridMapping.ColumnKey(x: $0.x, z: $0.z) }
        )
        guard !columns.isEmpty else { return [:] }
        var states: [PropSupportGridPresentation.Cell: PropSupportGridPresentation.CellState] = [:]
        for cell in cells
        where abs(cell.supportHeight - target.supportHeight) < Self.hoverTargetHeightTolerance
            && columns.contains(PropSupportGridMapping.ColumnKey(x: cell.columnX, z: cell.columnZ)) {
            states[cell] = .hoverTarget
        }
        return states
    }

    /// `cellStates` 的**唯一**写入口：footprint 的判定着色 + 悬停物件的发光。
    ///
    /// 发光**覆盖**在同一格上的判定色（那件物件所在的位置，用户此刻要的是"点它能拿起来"，
    /// 而不是"这里能不能放"）。
    private func publishCellStates() {
        // 层级：靠墙（蓝） < footprint 判定（黄/红） < 悬停发光（青白）。后写的赢。
        var states = wallStates
        for (cell, state) in footprintStates { states[cell] = state }
        for (cell, state) in hoverTargetStates() { states[cell] = state }
        cellStates = states
        onGridChanged?()
    }

    private func reevaluateFootprint() {
        guard let grid, collision != nil, let layerRef = hoveredLayerRef, let inputs = evaluationInputs else {
            hovered = nil
            hoveredBlockReason = nil
            footprintStates = [:]
            publishCellStates()
            return
        }
        let footprint = WorldPlanarFootprint(size: inputs.footprintSize, yaw: footprintYaw)
        let reason = verdict(footprint: footprint, height: inputs.height, layerRef: layerRef,
                             objectID: inputs.objectID)
        let columns = footprint.columns(anchoredAt: layerRef.column, spacing: grid.spacing)
        let covered = Set(columns.map { PropSupportGridMapping.ColumnKey(x: $0.x, z: $0.z) })
        let nextStates = PropSupportGridMapping.footprintStates(
            cells: cells,
            coveredColumns: covered,
            anchorLayer: layerRef.layer.layer,
            isFootprintValid: reason == nil
        )
        hovered = cells.first {
            $0.columnX == layerRef.column.x && $0.columnZ == layerRef.column.z
                && $0.layer == layerRef.layer.layer
        }
        // 只在**判定或着色真的变了**时才重推：本函数每次鼠标移动都会跑，而
        // `publishCellStates` 会触发宿主那条"推给预览 + 推给渲染层"的链。
        let changed = footprintStates != nextStates || hoveredBlockReason != reason
        footprintStates = nextStates
        hoveredBlockReason = reason
        if changed { publishCellStates() }
    }

    /// 悬停落点的**唯一判定出口**：与落地完全同源。
    ///
    /// - 拿不到 `footprint`（编辑器还没选中任何物件）时**不判定**，也就没有一个"绿格"
    ///   会骗用户：`isBuildModeActive` 仍然为真，但没有任何 footprint 被着色。
    /// - 判定结果按「格心 + 朝向 + 物件尺寸」缓存（见 `verdicts`）。
    /// 悬停落点的判定出口。`internal`（不是 `private`）是为了让离线 harness 能**直接**
    /// 驱动判定的缓存行为并实测耗时 —— 那条断言（同一格重复询问必须全部命中）只有在这里
    /// 才看得见，走 `updateHover` 还要先命中格子平面。
    func verdict(footprint: WorldPlanarFootprint, height: Float,
                 layerRef: PropSupportLayerRef, objectID: String) -> PropSupportBlockReason? {
        guard let provider = verdictForPlacement, let grid else { return nil }
        let position = PropSupportGridMapping.snappedPlacementPosition(
            columnX: layerRef.column.x,
            columnZ: layerRef.column.z,
            spacing: grid.spacing,
            supportHeight: layerRef.supportHeight
        )
        let key = VerdictKey(
            x: position.x, y: position.y, z: position.z, yaw: footprint.yaw,
            width: footprint.size.x, height: height, depth: footprint.size.y
        )
        if let cached = verdicts[key] {
            verdictCacheHits += 1
            return cached
        }
        verdictCacheMisses += 1
        let reason = provider(
            objectID,
            footprint.size, height,
            WorldVector3(x: position.x, y: position.y, z: position.z),
            footprint.yaw
        )
        // 结果里带 id 的原因（哪件已放物件 / 哪个锚点）逐条不同，缓存的是**这一格**的答案，
        // 所以原样存下来即可；上界到了就整体丢弃，绝不因为缓存让判定变松。
        if verdicts.count >= Self.verdictCacheLimit { verdicts.removeAll(keepingCapacity: true) }
        verdicts[key] = reason
        return reason
    }

    /// 丢掉全部判定缓存。**唯一**调用点是"房间里的摆放变了"（宿主收到新快照时）。
    ///
    /// 判定依赖"现在房间里有什么"，revision 就是那条事实的版本号；缓存跨 revision 复用
    /// 会让红/绿与落地判定分叉 —— 那正是这次要修的缺陷，绝不能重新引入。
    func invalidateVerdicts() {
        // 靠墙可放的答案同样依赖"房间里现在有什么" ⇒ 一起作废（下一次询问重算）。
        wallVerdictKey = nil
        guard !verdicts.isEmpty else { return }
        verdicts.removeAll(keepingCapacity: true)
    }

    // MARK: - 靠墙

    /// 装上一次派生出来的竖直面（与承托网格同一批三角形派生，见 `WorldPropWallGrid`）。
    func setWallPatches(_ patches: [WorldPropWallPatch]) {
        wallPatches = patches
        wallStates = [:]
        wallVerdictKey = nil
        wallPlaceableCellCount = 0
        publishCellStates()
    }

    /// 重算"这一件物件能不能靠着某面墙放"，并把可放的格子标成 `.wallPlaceable`。
    ///
    /// **判定出口与地板摆放是同一个**：`verdictForPlacement`（宿主包着摆放服务）。
    /// 这里只做两件事：把"背朝墙"的候选落点算出来（`WorldPropWallGrid`），以及把判据说"可以"
    /// 的那一个候选覆盖的格子染成蓝色。判据一个字都没放宽 —— 靠墙不是"另一种可放"，
    /// 而是"同一个可放判定"的另一组候选落点。
    ///
    /// 只在物件/尺寸/网格变化时重算（`wallVerdictKey`）：本函数会被每次鼠标移动间接触发。
    ///
    /// ⚠️ 写进 `cellStates` 的这批格子是**全局提示**（每面墙一个可放落点，散落在整个房间；
    /// 真机日志：`墙面=194`）。它们因此**不参与焦点锚点**（`PropSupportGridPresentation.focus`
    /// 刻意把 `.wallPlaceable` 排除在外）—— 参与的话，焦点窗口的外包框就是整个房间，
    /// 3160 个可绘制列会全部画出来，正是真机 2026-10-01「满地都是格子」那一次的成因。
    /// 它们仍然被着色：只是只在光标/选中物件附近那个窗口里画出来。
    func refreshWallPlaceability(objectID: String, footprintSize: SIMD2<Float>, height: Float) {
        guard isBuildModeActive, let grid, !wallPatches.isEmpty,
              footprintSize.x.isFinite, footprintSize.y.isFinite, height.isFinite,
              footprintSize.x > 0, footprintSize.y > 0, height > 0
        else {
            guard !wallStates.isEmpty || wallPlaceableCellCount != 0 else { return }
            wallStates = [:]
            wallPlaceableCellCount = 0
            wallVerdictKey = nil
            publishCellStates()
            return
        }
        let key = "\(objectID)|\(footprintSize.x)|\(footprintSize.y)|\(height)|\(wallPatches.count)|\(grid.layers.count)"
        guard key != wallVerdictKey else { return }
        wallVerdictKey = key
        var states: [PropSupportGridPresentation.Cell: PropSupportGridPresentation.CellState] = [:]
        guard let provider = verdictForPlacement else {
            wallStates = [:]
            wallPlaceableCellCount = 0
            publishCellStates()
            return
        }
        let size = WorldVector3(x: footprintSize.x, y: height, z: footprintSize.y)
        for patch in wallPatches {
            let candidates = WorldPropWallGrid
                .candidateAttachments(patch: patch, grid: grid, size: size)
                .prefix(Self.maximumWallCandidatesPerPatch)
            // 取**第一个**判据说"可以"的候选（候选顺序 = 离墙由近到远）：
            // 越靠前越贴墙，越靠后越退进房间。
            guard let accepted = candidates.first(where: { candidate in
                provider(objectID, footprintSize, height, candidate.position, candidate.yaw) == nil
            }) else { continue }
            let footprint = WorldPlanarFootprint(size: footprintSize, yaw: accepted.yaw)
            let covered = Set(
                footprint.columns(anchoredAt: accepted.layer.column, spacing: grid.spacing)
                    .map { PropSupportGridMapping.ColumnKey(x: $0.x, z: $0.z) }
            )
            guard !covered.isEmpty else { continue }
            for cell in cells where cell.layer == accepted.layer.layer.layer
                && covered.contains(PropSupportGridMapping.ColumnKey(x: cell.columnX, z: cell.columnZ)) {
                states[cell] = .wallPlaceable
            }
        }
        wallStates = states
        wallPlaceableCellCount = states.count
        publishCellStates()
    }
}
