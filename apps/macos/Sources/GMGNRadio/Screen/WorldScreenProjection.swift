import Foundation
import simd

// MARK: - 相机与投影（与生产**同算式**）

/// 渲染档位。决定视场角，与 `MarbleSpatialView.projectionMatrix(for:)` 的取值逐字一致。
enum WorldScreenRenderProfile: Equatable, Sendable {
    case fullStage
    case liveCam

    var fieldOfView: Float {
        switch self {
        case .fullStage: 66 * .pi / 180
        case .liveCam: 44 * .pi / 180
        }
    }

    var near: Float { 0.05 }
    var far: Float { 250 }
}

/// 世界相机。字段与 `SpatialCameraState` 一一对应（`position`/`yaw`/`pitch`）。
struct WorldScreenCamera: Equatable, Sendable {
    var position: SIMD3<Float>
    var yaw: Float
    var pitch: Float

    init(position: SIMD3<Float> = SIMD3(0, 0.8, 1.1), yaw: Float = 0, pitch: Float = 0) {
        self.position = position
        self.yaw = yaw
        self.pitch = pitch
    }
}

/// 世界 → 归一化屏幕坐标的投影。
///
/// **这不是第二份定义，是生产算式的离线等价物**：`MarbleSpatialView` 里
/// `cameraView = rotationX(-pitch) * rotationY(-yaw) * translation(-position)`、
/// `projection = perspectiveMatrix(fieldOfView:aspect:near:far:)`，
/// `SpatialStageStore.residentPropScreenPoint(world:)` 里
/// `clip = viewProjection * SIMD4(world,1)`、`guard clip.w > 0.000001`、
/// `SIMD2((clip.x/clip.w+1)/2, (1-clip.y/clip.w)/2)`。
///
/// 为什么不在运行时直接调那一份、而要有这一份：覆盖层要**在没有 prop 租约时**
/// （还没摆放任何东西、或世界刚加载）也能算出屏幕四角，而
/// `residentPropScreenPoint` 被 `isWorldVisible && residentPropActiveHandler?() == true`
/// 门禁住。运行时优先用生产那一份；这一份是等价回退，且被
/// `tools/test-resident-screen-overlay.swift` 以**生产源码原文**逐点比对钉住：
/// 生产改了视场角、近远平面或相机变换，这个 harness 立刻红。
struct WorldScreenProjection: Equatable, Sendable {
    let viewProjection: simd_float4x4
    let viewportSize: SIMD2<Float>

    init(camera: WorldScreenCamera, profile: WorldScreenRenderProfile, viewportSize: SIMD2<Float>) {
        let width = max(viewportSize.x, 1)
        let height = max(viewportSize.y, 1)
        self.viewportSize = SIMD2(width, height)
        let view = Self.rotationX(-camera.pitch)
            * Self.rotationY(-camera.yaw)
            * Self.translation(-camera.position)
        let projection = Self.perspectiveMatrix(
            fieldOfView: profile.fieldOfView,
            aspect: width / height,
            near: profile.near,
            far: profile.far
        )
        viewProjection = projection * view
    }

    init(viewProjection: simd_float4x4, viewportSize: SIMD2<Float>) {
        self.viewProjection = viewProjection
        self.viewportSize = SIMD2(max(viewportSize.x, 1), max(viewportSize.y, 1))
    }

    /// 归一化屏幕坐标：**左上原点、`0...1`**。相机背后的点返回 `nil`（不画半个屏幕）。
    ///
    /// 与 `SpatialStageStore.residentPropScreenPoint(world:)` 逐字同式（含 `1e-6` 那个阈值）。
    func screenPoint(world: SIMD3<Float>) -> SIMD2<Float>? {
        let clip = viewProjection * SIMD4<Float>(world, 1)
        guard clip.w > 0.000001 else { return nil }
        return SIMD2((clip.x / clip.w + 1) / 2, (1 - clip.y / clip.w) / 2)
    }

    /// 世界四角 → 归一化屏幕坐标。**任何一个角在相机背后就整块返回 `nil`**
    /// （宁可整块不画，也不画一个翻过来的破四边形）。
    func screenQuad(worldCorners: [SIMD3<Float>]) -> [SIMD2<Float>]? {
        guard worldCorners.count == 4 else { return nil }
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(4)
        for corner in worldCorners {
            guard let point = screenPoint(world: corner) else { return nil }
            points.append(point)
        }
        return points
    }

    /// 归一化屏幕坐标（左上原点）→ 视图坐标（左下原点，单位是视图的点）。
    /// `CATransform3D` / `CALayer` 的坐标系是 y 向上的，这一处翻转是**唯一**的一次。
    func viewPoint(normalized: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(normalized.x * viewportSize.x, (1 - normalized.y) * viewportSize.y)
    }

    /// 背向判据：屏幕法向是否**朝着相机**。朝相机 = 正面 = 该显示。
    ///
    /// 符号是这一处最容易写反的地方（写反了表现为"屏幕只在转过背面时才出现"）：
    /// 屏幕正面在**本体坐标系 +Z**，所以相机必须落在屏幕中心沿法向的那一侧，
    /// 也就是 `dot(法向, 相机 − 中心) > 0`。第一次跑 harness 时这里正是反的，
    /// 12 步正对屏幕的相机位姿被判成 0/12 可用。
    static func isFrontFacing(
        normal: SIMD3<Float>,
        center: SIMD3<Float>,
        camera: WorldScreenCamera
    ) -> Bool {
        let toCamera = camera.position - center
        let length = simd_length(toCamera)
        guard length > 1e-6 else { return false }
        return simd_dot(simd_normalize(normal), toCamera / length) > 0
    }

    // MARK: 与生产逐字同式的矩阵（`MarbleSpatialView` 同名函数）

    static func perspectiveMatrix(
        fieldOfView: Float,
        aspect: Float,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        let y = 1 / tan(fieldOfView * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)
        ))
    }

    static func translation(_ value: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(value.x, value.y, value.z, 1)
        ))
    }

    static func rotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, c, s, 0),
            SIMD4(0, -s, c, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    static func rotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(columns: (
            SIMD4(c, 0, -s, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(s, 0, c, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }
}

// MARK: - 覆盖层对齐：矩形 → 四边形

/// 3×3 单应矩阵（**列向量约定**：`(X,Y,1)ᵀ ~ H·(x,y,1)ᵀ`）。
///
/// `CATransform3D`（`CALayer`）用的是行向量约定，所以 `layerTransform` 是它的转置形式 ——
/// 这个转换是覆盖层贴不准的头号来源，所以它只有**一处**，并且被 harness 用
/// "把矩阵作用到矩形四角 ⇒ 必须落回投影出来的四个角"这条判据逐点验证。
struct WorldScreenHomography: Equatable, Sendable {
    /// 行主序的 9 个分量。
    let components: [Float]

    /// 作用在点上。`w` 不为 0 才有解（退化情形返回 `nil`）。
    func apply(to point: SIMD2<Float>) -> SIMD2<Float>? {
        guard components.count == 9 else { return nil }
        let w = components[6] * point.x + components[7] * point.y + components[8]
        guard abs(w) > 1e-9 else { return nil }
        let x = components[0] * point.x + components[1] * point.y + components[2]
        let y = components[3] * point.x + components[4] * point.y + components[5]
        return SIMD2(x / w, y / w)
    }

    /// `CALayer.transform` 的 16 个分量（行向量约定的透视分量放 `m14/m24/m44`）。
    var layerTransform: WorldScreenLayerTransform {
        let h = components
        return WorldScreenLayerTransform(
            m11: h[0], m12: h[3], m13: 0, m14: h[6],
            m21: h[1], m22: h[4], m23: 0, m24: h[7],
            m31: 0, m32: 0, m33: 1, m34: 0,
            m41: h[2], m42: h[5], m43: 0, m44: h[8]
        )
    }
}

/// `CATransform3D` 的纯值形态：让几何文件**不依赖 QuartzCore/AppKit**，
/// 于是离线 harness 能直接编译并逐点验证它。
struct WorldScreenLayerTransform: Equatable, Sendable {
    var m11: Float = 1, m12: Float = 0, m13: Float = 0, m14: Float = 0
    var m21: Float = 0, m22: Float = 1, m23: Float = 0, m24: Float = 0
    var m31: Float = 0, m32: Float = 0, m33: Float = 1, m34: Float = 0
    var m41: Float = 0, m42: Float = 0, m43: Float = 0, m44: Float = 1

    static let identity = WorldScreenLayerTransform()

    /// **`CALayer` 的施加语义**（行向量：`x' = m11·x + m21·y + m41`，再除以
    /// `w' = m14·x + m24·y + m44`）。harness 验证的就是这一份 —— 与 CoreAnimation
    /// 实际做的事同一套算式。
    func apply(to point: SIMD2<Float>) -> SIMD2<Float>? {
        let w = m14 * point.x + m24 * point.y + m44
        guard abs(w) > 1e-9 else { return nil }
        let x = m11 * point.x + m21 * point.y + m41
        let y = m12 * point.x + m22 * point.y + m42
        return SIMD2(x / w, y / w)
    }
}
enum WorldScreenOverlayAlignment {
    /// 覆盖层宿主视图的落位与变换。
    ///
    /// 约定（`WorldScreenOverlayController` 逐字照做）：
    /// - 宿主视图的 `frame` 取目标四边形的**轴对齐包围盒**（给 `referenceSize` 时取那个固定
    ///   尺寸、居中放在同一个包围盒中心上 —— 见 `placement(normalizedCorners:projection:
    ///   minimumExtent:referenceSize:)`）；
    /// - 宿主视图的内容铺满自己的 `bounds`（`WKWebView` 用 `autoresizingMask` 跟着走）；
    /// - `layer.transform` 把 `bounds` 的四个角搬到目标四角。
    ///
    /// 用包围盒而不是别的：`CALayer` 的变换是绕 `anchorPoint`（默认中心）做的，
    /// 而 `frame == bounds` 时"未变换的层恰好落在包围盒上"这件事由 AppKit 保证 ——
    /// 于是只需把**源与目标都平移到包围盒中心**的同一相对坐标系里解单应矩阵，
    /// 就与 `anchorPoint` 取什么值无关。绕 anchorPoint 手工补偿是这类覆盖层贴歪的
    /// 头号原因（真机表现为"转相机时屏幕慢慢滑出去"）。
    struct Placement: Equatable, Sendable {
        /// 宿主视图的 frame（视图坐标，左下原点，单位 = 点）。
        let frame: SIMD2<Float>
        let frameOrigin: SIMD2<Float>
        let transform: WorldScreenLayerTransform
        /// 四个角是否都在视口内（有一个不在也仍然要画 —— 半块屏幕是正常的，
        /// 只有**相机背后**才整块不画，那一条在 `screenQuad` 里就返回 nil 了）。
        let isFullyInsideViewport: Bool
    }

    /// 四边形在视口里的**轴对齐包围盒尺寸**（点）。
    ///
    /// 不解释单应矩阵 ⇒ 比 `placement` 便宜一个量级，于是"这一帧要不要换宿主的渲染尺寸"
    /// 可以在解矩阵**之前**先判。
    static func boundingSize(
        normalizedCorners: [SIMD2<Float>],
        projection: WorldScreenProjection,
        minimumExtent: Float = 1
    ) -> SIMD2<Float>? {
        guard normalizedCorners.count == 4 else { return nil }
        let points = normalizedCorners.map { projection.viewPoint(normalized: $0) }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return nil }
        let width = max(maxX - minX, minimumExtent)
        let height = max(maxY - minY, minimumExtent)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return SIMD2(width, height)
    }

    /// 从归一化屏幕四角（左上原点）解出宿主的落位与变换。
    ///
    /// - Parameter normalizedCorners: 顺序 **BL, BR, TR, TL**（左上原点下的"视觉"左下角
    ///   对应归一化 y 最大的那一个 —— 由调用方保证顺序，与 `WorldScreenQuad.corners` 同序）。
    /// - Parameter referenceSize: 宿主的**固定渲染尺寸**（点）。给定时，宿主 `bounds` 就是它，
    ///   `frameOrigin` 把它居中放到四边形包围盒的中心上，四角仍由 `transform` 精确搬过去。
    ///
    ///   为什么需要它：宿主 `bounds` 一变，里面的 `WKWebView` 就跟着换一次尺寸，而 WebKit
    ///   会让**内容进程重新布局并重画整页**（视频页还要重建播放器层）。相机一帧动一下、
    ///   宿主尺寸就跟着动一下，于是"推进镜头"变成每帧一次跨进程重排版 —— 真机上是爆卡。
    ///   尺寸固定之后，相机移动全部由单应矩阵吸收：对齐**逐点不变**（变换与源矩形一起换），
    ///   只有"网页被渲染成多大"这件事不再跟着相机抖。
    ///
    ///   为 `nil` 时逐字退化成"宿主 `bounds` = 四边形包围盒"，也就是这一处原本的语义。
    static func placement(
        normalizedCorners: [SIMD2<Float>],
        projection: WorldScreenProjection,
        minimumExtent: Float = 1,
        referenceSize: SIMD2<Float>? = nil
    ) -> Placement? {
        guard normalizedCorners.count == 4 else { return nil }
        let points = normalizedCorners.map { projection.viewPoint(normalized: $0) }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return nil }
        let boundsWidth = max(maxX - minX, minimumExtent)
        let boundsHeight = max(maxY - minY, minimumExtent)
        guard boundsWidth.isFinite, boundsHeight.isFinite,
              boundsWidth > 0, boundsHeight > 0
        else { return nil }
        let width = referenceSize.map { max($0.x, minimumExtent) } ?? boundsWidth
        let height = referenceSize.map { max($0.y, minimumExtent) } ?? boundsHeight
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }

        // 层心：不给 `referenceSize` 时**逐字**是原来的那一处；给了就取包围盒的真实中心
        // （固定尺寸的矩形要正落在四边形上，绕的必须是同一个中心）。
        //
        // 注意这只定义了解算口径：解出来的单应按"**绕层心**"施加。写进图层前要换成
        // AppKit backing layer 的 `bounds` 原点口径（那一处在
        // `WorldScreenLayerTransform.layerTransform(forAnchor:)`，只有一处）。
        let centre = referenceSize == nil
            ? SIMD2(minX + boundsWidth / 2, minY + boundsHeight / 2)
            : SIMD2(minX + (maxX - minX) / 2, minY + (maxY - minY) / 2)
        let origin = SIMD2(centre.x - width / 2, centre.y - height / 2)
        let size = SIMD2(width, height)
        let source: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(width, 0), SIMD2(width, height), SIMD2(0, height),
        ]
        let destination = points.map { $0 - centre }
        let shiftedSource = source.map { $0 - SIMD2(width / 2, height / 2) }
        guard let homography = homography(source: shiftedSource, destination: destination) else {
            return nil
        }
        let viewport = projection.viewportSize
        let isInside = minX >= -1 && minY >= -1
            && maxX <= viewport.x + 1 && maxY <= viewport.y + 1
        return Placement(
            frame: size,
            frameOrigin: origin,
            transform: homography.layerTransform,
            isFullyInsideViewport: isInside
        )
    }

    /// 四组对应点 → 单应矩阵。退化（共线 / 重合）返回 `nil`，绝不给出一个"看起来能用"的矩阵。
    ///
    /// 解法是把 `h33` 钉成 1 之后的 8×8 线性方程组（列主元高斯消元）。四次点、
    /// 确定性、无迭代 —— 于是它在 harness 里可以逐位复现。
    static func homography(
        source: [SIMD2<Float>],
        destination: [SIMD2<Float>]
    ) -> WorldScreenHomography? {
        guard source.count == 4, destination.count == 4 else { return nil }
        var matrix = [[Float]](repeating: [Float](repeating: 0, count: 9), count: 8)
        for index in 0 ..< 4 {
            let s = source[index]
            let d = destination[index]
            guard s.x.isFinite, s.y.isFinite, d.x.isFinite, d.y.isFinite else { return nil }
            matrix[index * 2] = [s.x, s.y, 1, 0, 0, 0, -d.x * s.x, -d.x * s.y, d.x]
            matrix[index * 2 + 1] = [0, 0, 0, s.x, s.y, 1, -d.y * s.x, -d.y * s.y, d.y]
        }
        guard let solution = solve(matrix) else { return nil }
        return WorldScreenHomography(components: solution + [1])
    }

    /// 8×8 线性方程组，列主元高斯消元。`matrix[i]` 的最后一个是右端项。
    private static func solve(_ input: [[Float]]) -> [Float]? {
        var rows = input
        let n = 8
        guard rows.count == n else { return nil }
        for column in 0 ..< n {
            var pivot = column
            var best = abs(rows[column][column])
            for candidate in (column + 1) ..< n where abs(rows[candidate][column]) > best {
                best = abs(rows[candidate][column])
                pivot = candidate
            }
            guard best > 1e-9 else { return nil }
            if pivot != column { rows.swapAt(pivot, column) }
            let divisor = rows[column][column]
            for index in column ..< (n + 1) { rows[column][index] /= divisor }
            for row in 0 ..< n where row != column {
                let factor = rows[row][column]
                guard factor != 0 else { continue }
                for index in column ..< (n + 1) {
                    rows[row][index] -= factor * rows[column][index]
                }
            }
        }
        return rows.map { $0[n] }
    }
}
