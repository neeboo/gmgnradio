import Foundation

// ===========================================================================
// 生成工作流自带的碰撞数据：契约类型 + **唯一一条**判定通路
// ===========================================================================
//
// ## 为什么要有这一份
//
// 到今天为止，物件的碰撞形状是 app **猜**出来的：先把模型缩放到目标高度，再拿
// "尺寸 × 朝向"拼一个偏航盒子（`WorldObjectState.generatedCollisionVolume`）。后果是
//
// - 薄/凹/细长的物件（斧头、长剑）用盒子表示会**要么挡空气、要么漏**；
// - **换一个生成后端 ⇒ 轮廓不同 ⇒ 碰撞不同**，同一张图在两台机器上得到两种物理。
//
// 用户的原话是「包括碰撞为什么不能在工作流里面自动加」——他要的是生成侧**自动产出**
// 碰撞数据。这一份就是接收端：生成侧在回执里给出 `collision_*` 与 `authoritative_size`，
// 守护进程把它下载并核验，app 把它解成三角形，然后**按代理**做碰撞。
//
// ## 一条判定通路（这是本项目反复踩过的坑）
//
// 世界回答"胶囊能不能站在这里"的地方有三个消费者：
//   1. 运行时移动/站立（`PropLayoutCollisionWorld` → `CollisionVolumeWorld`）；
//   2. 摆放时的"会不会挡住唯一通路"预检（`WorldPlacementRouteMap.blockedNodes`）；
//   3. 摆放时的"和别的物件互斥"预检（`PropPlacementEvaluator`）。
//
// 它们**只能**问同一个函数：`WorldCapsuleClearance.isClear(_:at:of:)`。这一份给那个函数
// 加了 `WorldPropObstacle` 重载，内部按形状分派：
//   - `.orientedBox` → **逐字**转交给今天那个 `WorldCollisionVolume` 重载（盒子行为不变）；
//   - `.proxyMesh`   → 胶囊 × 三角形，复用 `TriangleMeshCollisionWorld` 里**同一份**
//                      `segmentTriangleDistanceSquared`。
// 于是"代理"不是第二套几何，而是同一个判据的另一个形状分支。
//
// ## fail-closed
//
// 元数据说"有代理"但代理解不出来（没安装进 store、三角形非法、文件缺失）时，
// `generatedCollisionObstacle` 返回 nil ⇒ `WorldLayoutObstacles.resolve` 把该物件记进
// `unmodelledObjectIDs` ⇒ 摆放服务按今天那条 `unmodelledPlacedProp` **可见地拒绝**。
// 绝不静默退回盒子：那会让碰撞形状在用户不知情下变掉。

/// 生成侧声明的代理格式。两者都用同一个 `GLBColliderDecoder` 解；差别在导出方式与
/// 审计语义（`glb-hull` 保证凸，将来可以用凸特有的快速路径）。
public enum WorldPropCollisionFormat: String, Codable, Equatable, Sendable {
    case glbHull = "glb-hull"
    case glbDecimated = "glb-decimated"
}

/// 回执里"碰撞代理"那五个字段的 app 侧镜像。**不含三角形** —— 三角形在
/// `WorldPropCollisionProxyStore` 里按摘要寻址，世界状态里只留这份可审计的描述。
public struct WorldPropCollisionProxy: Codable, Equatable, Sendable {
    /// 与 `model_url` 同一风格的任务路径，例如 `/v1/jobs/<id>/collider.glb`。
    public let url: String
    public let format: WorldPropCollisionFormat
    public let sha256: String
    public let bytes: Int
    public let triangles: Int

    /// 与守护进程 `model::COLLIDER_TRIANGLE_LIMIT` 同一个上界。app 侧**也**要卡住，
    /// 因为一次 `canOccupy` 要遍历代理的全部三角形：契约里的上界不能只靠生成侧自觉。
    public static let maximumTriangles = 4096
    /// 与守护进程 `model::COLLIDER_LIMIT` 同一个上界（4 MiB）。
    public static let maximumBytes = 4 * 1024 * 1024

    public init(url: String, format: WorldPropCollisionFormat, sha256: String, bytes: Int, triangles: Int) {
        self.url = url
        self.format = format
        self.sha256 = sha256
        self.bytes = bytes
        self.triangles = triangles
    }

    public var isValid: Bool {
        // 路径必须就是那个固定任务路径：与守护进程 `download_collision` 同一条口径，
        // 于是"元数据里的 URL"不可能指到别处去。
        url.hasPrefix("/v1/jobs/") && url.hasSuffix("/collider.glb") && !url.contains("..")
            && url.count <= 256
            && sha256.count == 64 && sha256.allSatisfy(\.isHexDigit)
            && bytes > 0 && bytes <= Self.maximumBytes
            && triangles > 0 && triangles <= Self.maximumTriangles
    }
}

/// 尺寸是**谁给的**。可查的审计字段：`WorldGeneratedProp.sizeSource`。
public enum WorldPropSizeSource: String, Codable, Equatable, Sendable {
    /// app 从真实网格量出来的（今天的行为，也是没有权威尺寸时的回退）。
    case appMeasured = "app-measured"
    /// 生成工作流给的权威尺寸。
    case workflowAuthoritative = "workflow-authoritative"
    /// 提交时声明的**尺寸意图**（`size_intent`）定出来的尺寸。
    case submitIntent = "submit-intent"
}

/// 「这件东西的尺寸是**怎么定**的」——面板/任务行读它，四态与优先级一一对应：
/// 用户手动覆盖 > 尺寸意图 > 工作流权威尺寸 > 自动推断。
///
/// 与 `sizeSource` 的分工：`sizeSource` 说"这个数字来自哪份数据"（手动改过的尺寸仍然来自
/// app 量的那一份，所以仍是 `app-measured`）；本枚举说"最后是谁说了算"。
public enum WorldPropSizeProvenance: String, Codable, Equatable, Sendable {
    case manual = "manual"
    case submitIntent = "submit-intent"
    case workflowAuthoritative = "workflow-authoritative"
    case appMeasured = "app-measured"
    /// 给面板/回执用的中文说明。
    public var label: String {
        switch self {
        case .manual: return "手动改过"
        case .submitIntent: return "按你说的尺寸"
        case .workflowAuthoritative: return "工作流权威尺寸"
        case .appMeasured: return "自动推断"
        }
    }
}

public extension WorldPropCollisionProxy {
    /// 从回执那一组平铺字段构造。**全缺 ⇒ nil**（等于"这个后端没有代理"，行为与今天一致）。
    ///
    /// **部分缺 / 格式不在白名单 / 值越界 ⇒ 也是 nil**，但调用方不能把这当成"没有代理"：
    /// `WorldGeneratedProp.isValid` 在"回执声明了代理却非法"时把整件物件判无效 ⇒ 可见拒绝，
    /// 而不是静默退回盒子。这里的 nil 只表示"构造不出合法的代理描述"，两种情形的区分由
    /// 调用方按"字段是否出现"来做（守护进程侧就是 `invalid_collision_descriptor`）。
    ///
    /// 把这段换算放在 WorldRuntime 里（而不是宿主的回执代码里）是为了让它可测：
    /// `WorldPropCollisionProxyTests` 直接钉住"缺失 / 存在 / 非法"三态。
    static func fromReceipt(
        url: String?,
        format: String?,
        sha256: String?,
        bytes: Int?,
        triangles: Int?
    ) -> WorldPropCollisionProxy? {
        if url == nil, format == nil, sha256 == nil, bytes == nil, triangles == nil { return nil }
        guard let url, let format, let sha256, let bytes, let triangles,
              let parsedFormat = WorldPropCollisionFormat(rawValue: format)
        else { return nil }
        let proxy = WorldPropCollisionProxy(
            url: url, format: parsedFormat, sha256: sha256, bytes: bytes, triangles: triangles
        )
        return proxy.isValid ? proxy : nil
    }
}

public extension WorldPropAuthoritativeSize {
    /// 从回执的 `authoritative_size` 构造。整块缺失 ⇒ nil（app 照旧自己量）。
    static func fromReceipt(
        dimensions: [Double]?,
        units: String?,
        upAxis: String?,
        forwardAxis: String?
    ) -> WorldPropAuthoritativeSize? {
        guard let dimensions, dimensions.count == 3,
              let units, let upAxis, let forwardAxis
        else { return nil }
        let size = WorldPropAuthoritativeSize(
            dimensions: WorldVector3(
                x: Float(dimensions[0]), y: Float(dimensions[1]), z: Float(dimensions[2])
            ),
            units: units, upAxis: upAxis, forwardAxis: forwardAxis
        )
        return size.isValid ? size : nil
    }
}

/// 生成侧给出的权威尺寸与朝向（回执 `result.authoritative_size` 的 app 侧镜像）。
///
/// 有它以后 app **不再量**：`WorldGeneratedProp.effectiveSize` 直接用它，于是同一张图在
/// 任何后端上都得到同一组尺寸，进而同一组碰撞与同一组承托/可达性结论。
public struct WorldPropAuthoritativeSize: Codable, Equatable, Sendable {
    public let dimensions: WorldVector3
    /// 只接受米。世界本身就是米，收别的单位就要在 app 里做第二处换算。
    public let units: String
    public let upAxis: String
    public let forwardAxis: String

    public static let acceptedUnits = "m"
    public static let acceptedUpAxes = ["+Y", "-Y"]
    public static let acceptedForwardAxes = ["+Z", "-Z", "+X", "-X"]

    public init(dimensions: WorldVector3, units: String, upAxis: String, forwardAxis: String) {
        self.dimensions = dimensions
        self.units = units
        self.upAxis = upAxis
        self.forwardAxis = forwardAxis
    }

    public var isValid: Bool {
        let values = [dimensions.x, dimensions.y, dimensions.z]
        return units == Self.acceptedUnits
            && Self.acceptedUpAxes.contains(upAxis)
            && Self.acceptedForwardAxes.contains(forwardAxis)
            && values.allSatisfy { $0.isFinite && $0 > 0 && $0 <= 100 }
    }
}

/// 生成侧导出的碰撞代理，**已经归一化**。
///
/// 归一化不是装饰：app 用同一套摆放变换把模型放进世界（缩放到目标高度、X/Z 居中、底面贴
/// 承托面），代理必须与模型共用那个变换，否则代理与渲染会错位 —— 那就又变成"盒子挡空气"
/// 的同一种病。所以契约把归一化写死并在这里**校验**：
///
/// - 底面在 `y == 0`、顶面在 `y == 1`（高度恰好 1 个单位）；
/// - X/Z 以自身 AABB 居中（`min.x == -max.x`、`min.z == -max.z`）。
///
/// 校验不过就**不安装**（`install` 返回 false）⇒ 上层按"代理解不出来"处理（fail-closed）。
public struct WorldPropCollisionProxyMesh: Equatable, Sendable {
    /// 归一化空间（底面 y=0、顶面 y=1、X/Z 居中）里的三角形。
    public let triangles: [WorldTriangle]
    /// 这份代理的声明摘要，用于审计"这份碰撞形状来自哪一份代理"。
    public let sourceSHA256: String

    public let minimum: SIMD3<Float>
    public let maximum: SIMD3<Float>

    /// 归一化允许的偏差。生成侧导出时会有浮点噪声，1 毫米足够宽，也足够窄到能抓住
    /// "忘了居中/忘了归零"这类真实的导出错误。
    public static let normalizationTolerance: Float = 0.001

    public init?(triangles: [WorldTriangle], sourceSHA256: String) {
        guard !triangles.isEmpty,
              triangles.count <= WorldPropCollisionProxy.maximumTriangles,
              sourceSHA256.count == 64, sourceSHA256.allSatisfy(\.isHexDigit)
        else { return nil }
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for triangle in triangles {
            for vertex in [triangle.first, triangle.second, triangle.third] {
                guard vertex.x.isFinite, vertex.y.isFinite, vertex.z.isFinite else { return nil }
                minimum = SIMD3(Swift.min(minimum.x, vertex.x), Swift.min(minimum.y, vertex.y), Swift.min(minimum.z, vertex.z))
                maximum = SIMD3(Swift.max(maximum.x, vertex.x), Swift.max(maximum.y, vertex.y), Swift.max(maximum.z, vertex.z))
            }
        }
        let tolerance = Self.normalizationTolerance
        guard maximum.x - minimum.x > 0, maximum.y - minimum.y > 0, maximum.z - minimum.z > 0,
              abs(minimum.y) <= tolerance,
              abs(maximum.y - 1) <= tolerance,
              abs(minimum.x + maximum.x) <= tolerance,
              abs(minimum.z + maximum.z) <= tolerance
        else { return nil }
        self.triangles = triangles
        self.sourceSHA256 = sourceSHA256
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// 一份代理已经**摆到世界坐标**之后的三角形集合。
///
/// 与 `.orientedBox` 并列成为"一个物件的碰撞形状"，因此它也带着审计信息
/// （摘要 + 格式）—— "这份碰撞是工作流给的还是 app 的盒子" 在运行时就可查。
public struct WorldPropProxyObstacleMesh: Equatable, Sendable {
    public let id: String
    public let proxySHA256: String
    public let format: WorldPropCollisionFormat
    public let triangles: [WorldTriangle]
    public let minimum: SIMD3<Float>
    public let maximum: SIMD3<Float>
    /// 这件物件摆放时的底面落点与偏航角。保守投影要用它把盒子摆回**同一个朝向**。
    public let origin: SIMD3<Float>
    public let yaw: Float
    /// 这份网格是不是**水密**的（每条边恰好被两个三角形共用）。
    ///
    /// 为什么要这一位：`pointInsideMesh` 用射线奇偶性判"点是不是在实体内部"，而奇偶性
    /// **只对闭合网格有定义**。开口的壳（一片薄板、一个两端不封口的管子）会让一条射线
    /// 命中奇数次，于是壳外面的点被判成"在实体内"⇒ 代理凭空多挡一块 ⇒ 连"代理 ⊆ 保守
    /// 投影"这条包含关系都不再成立（实测空心管外面有 1179 个落点被误判）。
    /// 所以奇偶判定只在 `isClosed` 时使用；开口壳只走"离表面太近"那一条。
    public let isClosed: Bool

    public init(
        id: String,
        proxySHA256: String,
        format: WorldPropCollisionFormat,
        triangles: [WorldTriangle],
        origin: SIMD3<Float> = .zero,
        yaw: Float = 0
    ) {
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for triangle in triangles {
            for vertex in [triangle.first, triangle.second, triangle.third] {
                minimum = SIMD3(Swift.min(minimum.x, vertex.x), Swift.min(minimum.y, vertex.y), Swift.min(minimum.z, vertex.z))
                maximum = SIMD3(Swift.max(maximum.x, vertex.x), Swift.max(maximum.y, vertex.y), Swift.max(maximum.z, vertex.z))
            }
        }
        self.id = id
        self.proxySHA256 = proxySHA256
        self.format = format
        self.triangles = triangles
        self.minimum = minimum
        self.maximum = maximum
        self.origin = origin
        self.yaw = yaw
        self.isClosed = Self.isWatertight(triangles)
    }

    /// 每条无向边恰好被两个三角形共用 ⇒ 水密。顶点按 1e-5 量化，抵掉导出时的浮点噪声。
    static func isWatertight(_ triangles: [WorldTriangle]) -> Bool {
        struct Vertex: Hashable { let x: Int64; let y: Int64; let z: Int64 }
        struct Edge: Hashable { let first: Vertex; let second: Vertex }
        func key(_ value: SIMD3<Float>) -> Vertex {
            let scale: Float = 100_000
            return Vertex(
                x: Int64((value.x * scale).rounded()),
                y: Int64((value.y * scale).rounded()),
                z: Int64((value.z * scale).rounded())
            )
        }
        func ordered(_ first: Vertex, _ second: Vertex) -> Edge {
            (first.x, first.y, first.z) <= (second.x, second.y, second.z)
                ? Edge(first: first, second: second)
                : Edge(first: second, second: first)
        }
        var counts: [Edge: Int] = [:]
        for triangle in triangles {
            let vertices = [key(triangle.first), key(triangle.second), key(triangle.third)]
            for index in 0 ..< 3 {
                counts[ordered(vertices[index], vertices[(index + 1) % 3]), default: 0] += 1
            }
        }
        guard !counts.isEmpty else { return false }
        return counts.values.allSatisfy { $0 == 2 }
    }
}

/// 一个物件的碰撞形状：盒子（今天）或代理（生成侧给的）。
public enum WorldPropCollisionShape: Equatable, Sendable {
    case orientedBox(WorldCollisionVolume)
    case proxyMesh(WorldPropProxyObstacleMesh)
}

/// 世界里的一个障碍：编号 + 是不是阻挡 + 形状。
///
/// 之所以要有这个类型：三个消费者（运行时、通路预检、互斥预检）过去都直接拿
/// `WorldCollisionVolume`，于是"换成代理"只能靠各改各的 —— 那正是两条几何的来源。
/// 现在它们统一拿 `WorldPropObstacle`，形状的分派只发生在 `WorldCapsuleClearance` 里。
public struct WorldPropObstacle: Equatable, Sendable {
    public let id: String
    public let isBlocking: Bool
    public let shape: WorldPropCollisionShape

    public init(id: String, isBlocking: Bool, shape: WorldPropCollisionShape) {
        self.id = id
        self.isBlocking = isBlocking
        self.shape = shape
    }

    /// 由今天的盒子构造。旧调用方（清单里的 `WorldCollisionVolume`）走这一条。
    public init(volume: WorldCollisionVolume) {
        self.init(id: volume.id, isBlocking: volume.isBlocking, shape: .orientedBox(volume))
    }

    /// **保守**的盒子投影：代理障碍给出它的世界轴包围盒。
    ///
    /// 只给"只认盒子"的旧消费者用（见 `WorldLayoutObstacles.Resolution.volumes` 的说明）。
    /// 关键性质是**只会多挡、不会漏挡**：包围盒包含代理本身，所以任何被代理挡住的胶囊
    /// 一定也被这个盒子挡住。这条性质有断言锁着（`WorldPropLayoutTests`）。
    public var conservativeBoxProjection: WorldCollisionVolume {
        switch shape {
        case .orientedBox(let volume):
            return volume
        case .proxyMesh(let mesh):
            // **同朝向的 yaw OBB**，不是世界轴 AABB。两个理由：
            //
            // 1. 旧消费者（`ResidentPropPlacementService`）从盒子的四元数反推 footprint 的
            //    偏航角。给一个恒等旋转的盒子会让一件转了 90° 的物件的 footprint 变成不转的
            //    —— 那正是 2026-09-30 那把斧头的老毛病（轴向搞反 ⇒ 摆放预检与运行时两个答案）。
            // 2. yaw OBB 比世界轴 AABB 紧得多，假拒绝少。
            //
            // 关键性质不变：它**包含**代理本身，所以只会多挡、不会漏挡（有断言锁着）。
            let cosine = cos(mesh.yaw)
            let sine = sin(mesh.yaw)
            var localMinimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var localMaximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for triangle in mesh.triangles {
                for vertex in [triangle.first, triangle.second, triangle.third] {
                    let offset = vertex - mesh.origin
                    // 世界 → 物件局部（绕 Y 反向旋转）。
                    let local = SIMD3<Float>(
                        cosine * offset.x - sine * offset.z,
                        offset.y,
                        sine * offset.x + cosine * offset.z
                    )
                    localMinimum = SIMD3(
                        Swift.min(localMinimum.x, local.x),
                        Swift.min(localMinimum.y, local.y),
                        Swift.min(localMinimum.z, local.z)
                    )
                    localMaximum = SIMD3(
                        Swift.max(localMaximum.x, local.x),
                        Swift.max(localMaximum.y, local.y),
                        Swift.max(localMaximum.z, local.z)
                    )
                }
            }
            let localCenter = (localMinimum + localMaximum) / 2
            let localHalf = (localMaximum - localMinimum) / 2
            // 局部 → 世界。
            let worldCenter = mesh.origin + SIMD3<Float>(
                cosine * localCenter.x + sine * localCenter.z,
                localCenter.y,
                -sine * localCenter.x + cosine * localCenter.z
            )
            return WorldCollisionVolume(
                id: mesh.id,
                center: WorldVector3(x: worldCenter.x, y: worldCenter.y, z: worldCenter.z),
                // 半尺寸必须严格为正，否则 `OrientedBox` 会判它"无法表示"（fail-closed）。
                halfExtents: WorldVector3(
                    x: Swift.max(localHalf.x, .leastNormalMagnitude),
                    y: Swift.max(localHalf.y, .leastNormalMagnitude),
                    z: Swift.max(localHalf.z, .leastNormalMagnitude)
                ),
                rotation: WorldQuaternion(x: 0, y: sin(mesh.yaw / 2), z: 0, w: cos(mesh.yaw / 2)),
                // `CollisionVolumeWorld(volumes:)` 会过滤 `isBlocking`，而
                // `generatedCollisionVolume` 一直是 true —— 投影必须保持这一点，
                // 否则旧消费者会把它当成"不挡人的体积"而静默漏挡。
                isBlocking: true
            )
        }
    }
}

// MARK: - 唯一一条判定通路

/// 「**待摆物件的 yaw 盒子** 与 **一个已放障碍** 有没有重叠」——互斥预检的唯一一份几何。
///
/// 为什么会存在：运行时判的是"胶囊 × 障碍"，摆放互斥判的是"候选盒子 × 障碍"，形状本来就
/// 不同。但**障碍的那一侧**必须是同一份几何，否则同一个代理在运行时挡人、在互斥预检里却不挡。
/// 所以这里同样按形状分派：
/// - `.orientedBox` → 既有的 `WorldPropBoxOverlap`（OBB–OBB SAT），逐字复用；
/// - `.proxyMesh`   → 既有的 `WorldPropMeshClearance.canPlace`（yaw 盒子 × 三角形的
///   SAT，就是房间网格用的那一份）把 `supportHeight` 压到网格下方 ⇒ 不做"贴地放行"，
///   任何穿进盒子的三角形都算重叠；再补一条**盒心在实体内部**的判定，
///   与胶囊那条一样，否则一个完全落在闭合凸包里的小盒子会被判成"不重叠"（漏）。
public enum WorldPropObstacleOverlap {
    public static func overlaps(box: WorldCollisionVolume, obstacle: WorldPropObstacle) -> Bool {
        switch obstacle.shape {
        case .orientedBox(let volume):
            return WorldPropBoxOverlap.overlaps(box, volume)
        case .proxyMesh(let mesh):
            guard !mesh.triangles.isEmpty else {
                // 空网格是"解不出来的障碍"，不是"没有障碍"：按重叠处理（fail-closed）。
                return true
            }
            let center = SIMD3(box.center.x, box.center.y, box.center.z)
            if mesh.isClosed, center.isFinite,
               WorldCapsuleClearance.pointInsideMesh(center, mesh: mesh) {
                return true
            }
            return !WorldPropMeshClearance.canPlace(
                box,
                supportHeight: mesh.minimum.y - 1,
                triangles: mesh.triangles,
                restingTolerance: 0
            )
        }
    }
}

public extension WorldCapsuleClearance {
    /// 胶囊与**任意形状的物件障碍**不相交时返回 true。
    ///
    /// 这是世界回答"这里有没有东西"的**唯一**入口：运行时移动、通路预检、互斥预检
    /// 全部经过它。分派只发生在内部，而且
    /// - 盒子分支**逐字**调用既有的 `isClear(_:at:of: WorldCollisionVolume)`；
    /// - 代理分支复用 `TriangleMeshCollisionWorld` 的同一份三角形距离原语。
    ///
    /// 形状无法表示（盒子尺寸非正、代理为空、坐标非有限）时返回 **false**（fail-closed）。
    static func isClear(
        _ capsule: WorldCapsule,
        at position: SIMD3<Float>,
        of obstacle: WorldPropObstacle
    ) -> Bool {
        switch obstacle.shape {
        case .orientedBox(let volume):
            return isClear(capsule, at: position, of: volume)
        case .proxyMesh(let mesh):
            return isClear(capsule, at: position, of: mesh)
        }
    }

    /// 障碍在世界坐标下的半尺寸（世界轴包围盒的一半）。
    ///
    /// 通路预检用它决定"只扫物件真正覆盖的那几列"。无法表示时返回 nil（调用方 fail-closed）。
    static func worldHalfExtents(of obstacle: WorldPropObstacle) -> SIMD3<Float>? {
        switch obstacle.shape {
        case .orientedBox(let volume):
            return worldHalfExtents(of: volume)
        case .proxyMesh(let mesh):
            let half = (mesh.maximum - mesh.minimum) / 2
            guard half.x.isFinite, half.y.isFinite, half.z.isFinite,
                  half.x > 0, half.y > 0, half.z > 0
            else { return nil }
            return half
        }
    }

    /// 代理网格的世界轴包围盒中心（通路预检的扫描范围要用它）。
    static func worldCenter(of obstacle: WorldPropObstacle) -> SIMD3<Float>? {
        switch obstacle.shape {
        case .orientedBox(let volume):
            let center = volume.center
            let value = SIMD3(center.x, center.y, center.z)
            return value.isFinite ? value : nil
        case .proxyMesh(let mesh):
            let center = (mesh.maximum + mesh.minimum) / 2
            return center.isFinite ? center : nil
        }
    }

    /// 胶囊 × 代理三角形。语义与盒子分支**对齐**：整体都是障碍，
    /// 不因为"三角形的法线朝上"就把它当成可以踩的承托面
    /// （`PropLayoutCollisionWorld` 明确写着生成物件只挡身体、不提供可站顶面）。
    ///
    /// 两件事都要测，缺一不可：
    /// 1. **离表面太近**（`segmentTriangleDistanceSquared`）—— 处理薄板、细杆、外壳；
    /// 2. **在实体内部**（竖直射线奇偶性）—— 距离测试漏掉"整个胶囊落在闭合实体里"
    ///    （密网格的内部离表面很远）。少了第 2 条，一个封闭凸包就是个**漏**：
    ///    小物件可以整个塞进大物件里面。
    static func isClear(
        _ capsule: WorldCapsule,
        at position: SIMD3<Float>,
        of mesh: WorldPropProxyObstacleMesh
    ) -> Bool {
        guard capsule.isValid, position.isFinite, !mesh.triangles.isEmpty,
              mesh.minimum.isFinite, mesh.maximum.isFinite
        else { return false }
        let bottom = position + SIMD3(0, capsule.radius, 0)
        let top = position + SIMD3(0, capsule.height - capsule.radius, 0)
        let radiusSquared = capsule.radius * capsule.radius
        // 先用胶囊自身的世界 AABB 做整体剔除：绝大多数落点离这件物件很远，
        // 代价因此与代理的三角形数无关（只有真的落在附近才逐三角形测）。
        let capsuleMinimum = SIMD3(
            Swift.min(bottom.x, top.x) - capsule.radius,
            Swift.min(bottom.y, top.y) - capsule.radius,
            Swift.min(bottom.z, top.z) - capsule.radius
        )
        let capsuleMaximum = SIMD3(
            Swift.max(bottom.x, top.x) + capsule.radius,
            Swift.max(bottom.y, top.y) + capsule.radius,
            Swift.max(bottom.z, top.z) + capsule.radius
        )
        guard mesh.minimum.x <= capsuleMaximum.x, mesh.maximum.x >= capsuleMinimum.x,
              mesh.minimum.y <= capsuleMaximum.y, mesh.maximum.y >= capsuleMinimum.y,
              mesh.minimum.z <= capsuleMaximum.z, mesh.maximum.z >= capsuleMinimum.z
        else { return true }

        // 2. 实体内部：沿胶囊轴线取**有界**几个采样点做射线奇偶判定。
        //
        // 为什么采样点够用：任何比采样间距还薄的实体，其内部到自身表面的距离必然小于
        // 采样间距，因而已经被第 1 条的距离测试（半径）抓住。两条合起来才是"实体"语义。
        //
        // **只在网格水密时做**：奇偶性对开口壳没有定义（见 `isClosed` 的说明）。开口壳
        // 只有"离表面太近"这一条约束 —— 那也正是"薄板/细杆"该有的语义。
        if mesh.isClosed {
            let samples = 4
            for index in 0 ... samples {
                let progress = Float(index) / Float(samples)
                let axisPoint = bottom + (top - bottom) * progress
                if pointInsideMesh(axisPoint, mesh: mesh) { return false }
            }
        }

        // 1. 离表面太近。
        for triangle in mesh.triangles {
            // 逐三角形的廉价剔除：三角形 AABB 与胶囊 AABB 不相交就跳过。
            let triangleMinimum = triangle.minimum
            let triangleMaximum = triangle.maximum
            guard triangleMinimum.x <= capsuleMaximum.x, triangleMaximum.x >= capsuleMinimum.x,
                  triangleMinimum.y <= capsuleMaximum.y, triangleMaximum.y >= capsuleMinimum.y,
                  triangleMinimum.z <= capsuleMaximum.z, triangleMaximum.z >= capsuleMinimum.z
            else { continue }
            if segmentTriangleDistanceSquared(start: bottom, end: top, triangle: triangle) < radiusSquared - 0.000001 {
                return false
            }
        }
        return true
    }

    /// 从点出发沿一条**通用方向**的射线与网格的相交次数为奇数 ⇒ 点在网格内部。
    ///
    /// 为什么不用竖直射线（第一版就是它，实测漏了）：网格的三角化有共享边，正方形底面的
    /// **正中心**恰好落在那条对角边上，射线同时命中两个三角形 ⇒ 奇偶性变偶数 ⇒ 实体内部
    /// 被判成外部。取一个各分量都不同的方向把"正好命中边/顶点"变成实际不可能。
    static func pointInsideMesh(
        _ point: SIMD3<Float>,
        mesh: WorldPropProxyObstacleMesh
    ) -> Bool {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
              point.x >= mesh.minimum.x, point.x <= mesh.maximum.x,
              point.y >= mesh.minimum.y, point.y <= mesh.maximum.y,
              point.z >= mesh.minimum.z, point.z <= mesh.maximum.z
        else { return false }
        let direction = SIMD3<Float>(1, 3, 7) / (Float(1) * Float(1) + Float(3) * Float(3) + Float(7) * Float(7)).squareRoot()
        var crossings = 0
        for triangle in mesh.triangles {
            let edge1 = triangle.second - triangle.first
            let edge2 = triangle.third - triangle.first
            let p = proxyCross(direction, edge2)
            let determinant = proxyDot(edge1, p)
            guard abs(determinant) > 0.0000001 else { continue }
            let inverse = 1 / determinant
            let t = point - triangle.first
            let u = proxyDot(t, p) * inverse
            guard u >= 0, u <= 1 else { continue }
            let q = proxyCross(t, edge1)
            let v = proxyDot(direction, q) * inverse
            guard v >= 0, u + v <= 1 else { continue }
            if proxyDot(edge2, q) * inverse > 0 { crossings += 1 }
        }
        return crossings % 2 == 1
    }
}

private func proxyDot(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
    lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
}

private func proxyCross(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(
        lhs.y * rhs.z - lhs.z * rhs.y,
        lhs.z * rhs.x - lhs.x * rhs.z,
        lhs.x * rhs.y - lhs.y * rhs.x
    )
}

// MARK: - 代理的进程内注册表

/// 按声明摘要寻址的代理注册表。
///
/// 世界状态（`WorldObjectState.metadata`）里只存**描述**（摘要/字节数/三角形数/格式），
/// 三角形放在这里：几千个三角形 base64 进元数据会把每一份状态快照撑到几百 KB，
/// 而状态会经 daemon 的 SQLite 与 IPC 来回搬。摘要寻址还顺带给了"同一份代理被多件
/// 物件共用"的自然去重。
///
/// **fail-closed 的落点**：元数据声明了摘要、注册表里却没有那一份 ⇒
/// `WorldGeneratedProp.generatedCollisionObstacle` 返回 nil ⇒ 可见拒绝。绝不用盒子顶上。
public final class WorldPropCollisionProxyStore: @unchecked Sendable {
    public static let shared = WorldPropCollisionProxyStore()

    private let lock = NSLock()
    private var meshes: [String: WorldPropCollisionProxyMesh] = [:]

    public init() {}

    /// 安装一份代理。归一化校验不过时返回 false 且**不**留下任何东西。
    @discardableResult
    public func install(_ mesh: WorldPropCollisionProxyMesh) -> Bool {
        guard !mesh.sourceSHA256.isEmpty else { return false }
        lock.withLock { meshes[mesh.sourceSHA256] = mesh }
        return true
    }

    /// 直接"解码 GLB 字节 → 归一化校验 → 安装"。任一步失败都返回 nil 并保持 store 不变，
    /// 于是调用方得到一个**可见的**失败，而不是一个半装好的代理。
    ///
    /// 这条路径就是 app 侧真正要接的那一行：拿到 daemon 落盘的 `collider.glb` 字节与回执里的
    /// `collision_sha256` 之后 `try WorldPropCollisionProxyStore.shared.install(
    ///   decoding: data, sha256: inspection.collisionSHA256)`。
    @discardableResult
    public func install(decoding data: Data, sha256: String) -> Bool {
        guard let mesh = try? Self.decode(data, sha256: sha256) else { return false }
        return install(mesh)
    }

    /// 解 GLB 并做归一化校验。抛出的错误就是 `GLBColliderError` / 归一化失败。
    public static func decode(
        _ data: Data,
        sha256: String,
        transform: WorldMeshTransform = WorldMeshTransform()
    ) throws -> WorldPropCollisionProxyMesh {
        let triangles = try GLBColliderDecoder().decode(data: data, transform: transform)
        guard let mesh = WorldPropCollisionProxyMesh(triangles: triangles, sourceSHA256: sha256) else {
            throw WorldPropCollisionProxyError.unnormalizedProxy
        }
        return mesh
    }

    public func mesh(forSHA256 sha256: String) -> WorldPropCollisionProxyMesh? {
        lock.withLock { meshes[sha256] }
    }

    public func removeAll() {
        lock.withLock { meshes.removeAll() }
    }

    public var count: Int { lock.withLock { meshes.count } }
}

public enum WorldPropCollisionProxyError: Error, Equatable, Sendable {
    /// 代理不在归一化空间里（底面不是 y=0 / 顶面不是 y=1 / XZ 没居中 / 三角形非法）。
    case unnormalizedProxy
}

// MARK: - 把归一化代理摆到世界坐标

public extension WorldPropCollisionProxyMesh {
    /// 用与模型**同一套**摆放变换把代理放进世界：
    /// 缩放到目标高度（米）、绕 Y 转 `yaw`、底面落在 `position`。
    ///
    /// 归一化保证了这里的算术是确定的：底面在 y=0，所以缩放后底面正好在 `position.y`；
    /// X/Z 居中，所以它和 `ResidentPropPlacementMatrix` 把模型 AABB 居中到 `position`
    /// 的做法落在同一处。
    func placed(
        id: String,
        format: WorldPropCollisionFormat,
        position: WorldVector3,
        yaw: Float,
        heightMeters: Float
    ) -> WorldPropProxyObstacleMesh? {
        let origin = SIMD3(position.x, position.y, position.z)
        guard origin.isFinite, yaw.isFinite, heightMeters.isFinite, heightMeters > 0 else {
            return nil
        }
        let cosine = cos(yaw)
        let sine = sin(yaw)
        let scale = heightMeters / (maximum.y - minimum.y)
        guard scale.isFinite, scale > 0 else { return nil }
        var placedTriangles: [WorldTriangle] = []
        placedTriangles.reserveCapacity(triangles.count)
        for triangle in triangles {
            let converted = [triangle.first, triangle.second, triangle.third].map { vertex -> SIMD3<Float> in
                let scaled = vertex * scale
                let rotated = SIMD3(
                    cosine * scaled.x + sine * scaled.z,
                    scaled.y,
                    -sine * scaled.x + cosine * scaled.z
                )
                return origin + rotated
            }
            placedTriangles.append(WorldTriangle(converted[0], converted[1], converted[2]))
        }
        return WorldPropProxyObstacleMesh(
            id: id,
            proxySHA256: sourceSHA256,
            format: format,
            triangles: placedTriangles,
            origin: origin,
            yaw: yaw
        )
    }
}

private extension SIMD3 where Scalar == Float {
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

private extension WorldTriangle {
    var minimum: SIMD3<Float> {
        SIMD3(
            Swift.min(first.x, second.x, third.x),
            Swift.min(first.y, second.y, third.y),
            Swift.min(first.z, second.z, third.z)
        )
    }

    var maximum: SIMD3<Float> {
        SIMD3(
            Swift.max(first.x, second.x, third.x),
            Swift.max(first.y, second.y, third.y),
            Swift.max(first.z, second.z, third.z)
        )
    }
}
