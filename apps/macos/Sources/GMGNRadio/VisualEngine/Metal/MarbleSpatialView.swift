import AppKit
@preconcurrency import MetalKit
import MetalSplatter
import os
@preconcurrency import QuartzCore
@preconcurrency import SceneKit
import simd
import SplatIO
import VRMMetalKit
import WorldRuntime
#if DEBUG
import ImageIO
#endif

#if DEBUG
// BEGIN DEBUG FRAME CAPTURE
/// Opt-in export of this renderer's drawable only; never captures the desktop.
@MainActor
final class MarbleDebugFrameCapture {
    static let shared: MarbleDebugFrameCapture? = {
        let environment = ProcessInfo.processInfo.environment
        guard let url = outputURL(environment: environment) else {
            if environment["GMGN_SPACE_FRAME_OUTPUT"] != nil {
                Logger(subsystem: "ai.gmgn.radio", category: "SpaceFrameExport")
                    .error("GMGN_SPACE_FRAME_OUTPUT must be an absolute PNG path")
            }
            return nil
        }
        return MarbleDebugFrameCapture(outputURL: url)
    }()

    let outputURL: URL
    private var readyFrameCount = 0
    private var attempted = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    static func outputURL(environment: [String: String]) -> URL? {
        guard let path = environment["GMGN_SPACE_FRAME_OUTPUT"],
              path.hasPrefix("/"),
              (path as NSString).pathExtension.lowercased() == "png"
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    func claimIfReady(_ isReady: Bool) -> Bool {
        guard !attempted else { return false }
        readyFrameCount = isReady ? readyFrameCount + 1 : 0
        guard readyFrameCount >= 3 else { return false }
        attempted = true
        return true
    }

    func encode(
        texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        isReady: Bool
    ) {
        guard claimIfReady(isReady) else { return }
        let log = Logger(subsystem: "ai.gmgn.radio", category: "SpaceFrameExport")
        let width = texture.width
        let height = texture.height
        let bytesPerRow = (width * 4 + 255) & ~255
        guard texture.pixelFormat == .bgra8Unorm_srgb,
              let buffer = texture.device.makeBuffer(
                  length: bytesPerRow * height,
                  options: .storageModeShared
              ),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            log.error("Space frame export failed to allocate GPU readback")
            return
        }
        blit.label = "gmgn single debug frame export"
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()
        let outputURL = self.outputURL
        commandBuffer.addCompletedHandler { completed in
            guard completed.status == .completed else {
                log.error("Space frame export GPU failure: \(completed.error?.localizedDescription ?? "unknown", privacy: .public)")
                return
            }
            do {
                let pixels = Data(bytes: buffer.contents(), count: bytesPerRow * height)
                try Self.writePNG(
                    pixels, width: width, height: height,
                    bytesPerRow: bytesPerRow, outputURL: outputURL
                )
                log.notice("Space frame exported: \(outputURL.path, privacy: .public)")
            } catch {
                log.error("Space frame PNG failure: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated static func writePNG(
        _ pixels: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        outputURL: URL
    ) throws {
        guard let provider = CGDataProvider(data: pixels as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: width, height: height,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                  ),
                  provider: provider, decode: nil,
                  shouldInterpolate: false, intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                  outputURL as CFURL, "public.png" as CFString, 1, nil
              )
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
// END DEBUG FRAME CAPTURE
#endif

enum MarbleViewportMetrics {
    static func resolve(
        reportedSize: CGSize,
        drawableSize: CGSize
    ) -> CGSize {
        guard reportedSize.width > 1, reportedSize.height > 1 else {
            return drawableSize
        }
        return reportedSize
    }
}

struct MarbleSceneFraming: Equatable, Sendable {
    static let normalizedMaximumExtent: Float = 4

    let center: SIMD3<Float>
    let groundedOrigin: SIMD3<Float>
    let uniformScale: Float
    let normalizedMinimum: SIMD3<Float>
    let normalizedMaximum: SIMD3<Float>

    /// Adopted worlds provide a measured ground origin and metre conversion.
    /// Bounds are in source coordinates; no room-size fitting is applied.
    init(
        groundedOrigin: SIMD3<Float>,
        uniformScale: Float,
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>
    ) {
        self.center = (minimum + maximum) * 0.5
        self.groundedOrigin = groundedOrigin
        self.uniformScale = uniformScale
        self.normalizedMinimum = (minimum - groundedOrigin) * uniformScale
        self.normalizedMaximum = (maximum - groundedOrigin) * uniformScale
    }

    init(positions: [SIMD3<Float>]) {
        guard !positions.isEmpty else {
            center = .zero
            groundedOrigin = .zero
            uniformScale = 1
            normalizedMinimum = .zero
            normalizedMaximum = .zero
            return
        }

        let xBounds = Self.trimmedBounds(positions.map(\.x))
        let yBounds = Self.trimmedBounds(positions.map(\.y))
        let zBounds = Self.trimmedBounds(positions.map(\.z))
        center = SIMD3(
            (xBounds.lower + xBounds.upper) * 0.5,
            (yBounds.lower + yBounds.upper) * 0.5,
            (zBounds.lower + zBounds.upper) * 0.5
        )
        groundedOrigin = SIMD3(
            center.x,
            yBounds.lower,
            center.z
        )
        let maximumExtent = max(
            xBounds.upper - xBounds.lower,
            yBounds.upper - yBounds.lower,
            zBounds.upper - zBounds.lower
        )
        guard maximumExtent > 0.0001 else {
            uniformScale = 1
            normalizedMinimum = .zero
            normalizedMaximum = .zero
            return
        }
        uniformScale = min(
            max(Self.normalizedMaximumExtent / maximumExtent, 0.05),
            20
        )
        let rawMinimum = SIMD3<Float>(
            xBounds.lower,
            yBounds.lower,
            zBounds.lower
        )
        let rawMaximum = SIMD3<Float>(
            xBounds.upper,
            yBounds.upper,
            zBounds.upper
        )
        normalizedMinimum = (rawMinimum - groundedOrigin) * uniformScale
        normalizedMaximum = (rawMaximum - groundedOrigin) * uniformScale
    }

    func recommendedCameraHome(worldID: String?) -> SpatialCameraState {
        let extent = normalizedMaximum - normalizedMinimum
        guard extent.y > 0.2, extent.z > 0.2 else {
            return .defaultHome
        }

        let centerX = (normalizedMinimum.x + normalizedMaximum.x) * 0.5
        let eyeHeight = min(
            max(normalizedMinimum.y + extent.y * 0.55, 0.65),
            max(normalizedMaximum.y - 0.12, 0.65)
        )
        let rearInteriorZ = normalizedMaximum.z - extent.z * 0.225
        let yaw: Float = switch worldID {
        case "world-labs-example-warm-kitchen": 0
        default: 0
        }

        return SpatialCameraState(
            position: SIMD3<Float>(centerX, eyeHeight, rearInteriorZ),
            yaw: yaw,
            pitch: 0
        )
    }

    func normalize(_ positions: [SIMD3<Float>]) -> [SIMD3<Float>] {
        positions.map { ($0 - groundedOrigin) * uniformScale }
    }

    func colliderTransform(
        sourceCoordinates: MarbleColliderSourceCoordinates
    ) -> WorldMeshTransform {
        WorldMeshTransform(
            axisConversion: sourceCoordinates.axisConversion,
            origin: groundedOrigin,
            uniformScale: uniformScale
        )
    }

    func normalizedSample(
        position: SIMD3<Float>,
        scale sourceScale: SIMD3<Float>,
        rotation: simd_quatf
    ) -> SpatialSplatSample {
        let normalizedScale = sourceScale * uniformScale
        let rotationMatrix = simd_float3x3(rotation)
        let squaredScale = normalizedScale * normalizedScale
        let scaleCovariance = simd_float3x3(columns: (
            SIMD3<Float>(squaredScale.x, 0, 0),
            SIMD3<Float>(0, squaredScale.y, 0),
            SIMD3<Float>(0, 0, squaredScale.z)
        ))
        let covariance = rotationMatrix
            * scaleCovariance
            * rotationMatrix.transpose
        let visibleSigma: Float = 2.5
        let horizontalRadius = min(
            max(
                sqrt(max(max(covariance[0, 0], covariance[2, 2]), 0))
                    * visibleSigma,
                0.002
            ),
            0.55
        )
        let verticalRadius = min(
            max(
                sqrt(max(covariance[1, 1], 0)) * visibleSigma,
                0.002
            ),
            0.55
        )
        return SpatialSplatSample(
            position: (position - groundedOrigin) * uniformScale,
            horizontalRadius: horizontalRadius,
            verticalRadius: verticalRadius
        )
    }

    private static func trimmedBounds(
        _ values: [Float]
    ) -> (lower: Float, upper: Float) {
        let sorted = values.sorted()
        let trimCount = sorted.count >= 100 ? sorted.count / 50 : 0
        return (
            sorted[trimCount],
            sorted[sorted.count - trimCount - 1]
        )
    }
}

enum MarbleAvatarLoadError: Error, Equatable, LocalizedError, Sendable {
    case pmxRequiresVMD
    case missingVMDFile

    var errorDescription: String? {
        switch self {
        case .pmxRequiresVMD:
            "PMX 角色只能使用 VMD 动作。"
        case .missingVMDFile:
            "找不到选中的 VMD 动作文件。"
        }
    }
}

enum MarbleAvatarLoadPlan: Equatable, Sendable {
    case none
    case vrm(modelURL: URL, motion: StageMotionAsset?)
    case pmx(
        modelURL: URL,
        resourceRootURL: URL,
        motionURL: URL?
    )

    static func resolve(
        _ snapshot: StageAvatarRuntimeSnapshot
    ) throws -> MarbleAvatarLoadPlan {
        guard let avatar = snapshot.avatar else {
            return .none
        }
        switch avatar.format {
        case .vrm:
            return .vrm(modelURL: avatar.modelURL, motion: snapshot.motion)
        case .pmx:
            let motionURL: URL?
            switch snapshot.motion?.format {
            case nil, .procedural:
                motionURL = nil
            case .vmd:
                guard let url = snapshot.motion?.url else {
                    throw MarbleAvatarLoadError.missingVMDFile
                }
                motionURL = url
            case .vrma:
                throw MarbleAvatarLoadError.pmxRequiresVMD
            }
            return .pmx(
                modelURL: avatar.modelURL,
                resourceRootURL: avatar.resourceRootURL,
                motionURL: motionURL
            )
        }
    }
}

enum MarblePMXFraming {
    private static let normalizedHeight: Float = 1.7

    static func modelTransform(
        bounds: PMXAvatarBounds?,
        placement: StageAvatarPlacement,
        localGroundingOffsetY: Float = 0,
        soleReferenceY: Float? = nil
    ) -> simd_float4x4 {
        let bounds = bounds ?? PMXAvatarBounds(
            minimum: SIMD3<Float>(-0.5, 0, -0.5),
            maximum: SIMD3<Float>(0.5, normalizedHeight, 0.5)
        )
        let groundY = soleReferenceY.flatMap { $0.isFinite ? $0 : nil }
            ?? bounds.minimum.y
        let height = max(bounds.maximum.y - groundY, 0.001)
        let modelOrigin = SIMD3<Float>(
            bounds.center.x,
            groundY,
            bounds.center.z
        )
        return translation(placement.position)
            * rotationY(placement.yaw)
            * scale(placement.scale * normalizedHeight / height)
            * translation(
                -modelOrigin + SIMD3<Float>(0, localGroundingOffsetY, 0)
            )
    }

    static func viewMatrix(
        bounds: PMXAvatarBounds?,
        placement: StageAvatarPlacement,
        localGroundingOffsetY: Float = 0,
        sharedCameraView: simd_float4x4
    ) -> simd_float4x4 {
        sharedCameraView * modelTransform(
            bounds: bounds,
            placement: placement,
            localGroundingOffsetY: localGroundingOffsetY
        )
    }

    private static func translation(
        _ value: SIMD3<Float>
    ) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(value.x, value.y, value.z, 1)
        ))
    }

    private static func scale(_ value: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(value, 0, 0, 0),
            SIMD4(0, value, 0, 0),
            SIMD4(0, 0, value, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    private static func rotationY(_ angle: Float) -> simd_float4x4 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return simd_float4x4(columns: (
            SIMD4(cosine, 0, -sine, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(sine, 0, cosine, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    private static func rotationX(_ angle: Float) -> simd_float4x4 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, cosine, sine, 0),
            SIMD4(0, -sine, cosine, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }
}

struct MarblePMXRenderMatrices {
    let cameraView: simd_float4x4
    let modelTransform: simd_float4x4

    static func fullStage(
        bounds: PMXAvatarBounds?,
        placement: StageAvatarPlacement,
        localGroundingOffsetY: Float = 0,
        soleReferenceY: Float? = nil,
        sharedCameraView: simd_float4x4
    ) -> Self {
        Self(
            cameraView: sharedCameraView,
            modelTransform: MarblePMXFraming.modelTransform(
                bounds: bounds,
                placement: placement,
                localGroundingOffsetY: localGroundingOffsetY,
                soleReferenceY: soleReferenceY
            )
        )
    }
}

enum MarbleSpatialDepthPolicy {
    /// Gaussian splats are translucent volumes. Their depth must be blended by
    /// alpha before an opaque avatar is depth-tested against the scene.
    static let usesAlphaAwareDepth = true

    /// Avatar occlusion is sourced from the prepared GLB mesh. Raw Gaussian
    /// depth is cleared because translucent capture residue covers the frame.
    static let avatarUsesSceneDepth = true

    static func configureAvatarDepth(
        _ pass: MTLRenderPassDescriptor,
        hasPreparedOccluder: Bool,
        convention: MarbleSceneDepthConvention
    ) {
        pass.depthAttachment.loadAction = avatarUsesSceneDepth
            && hasPreparedOccluder ? .load : .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = convention.clearDepth
    }
}

enum MarbleSceneDepthConvention: Equatable, Sendable {
    case metalForward
    case sceneKitReverse

    static func resolve(
        avatarFormat: StageAvatarFormat?
    ) -> MarbleSceneDepthConvention {
        avatarFormat == .pmx ? .sceneKitReverse : .metalForward
    }

    var compareFunction: MTLCompareFunction {
        switch self {
        case .metalForward: .less
        case .sceneKitReverse: .greater
        }
    }

    var clearDepth: Double {
        switch self {
        case .metalForward: 1
        case .sceneKitReverse: 0
        }
    }

    var shaderFlag: Float {
        self == .sceneKitReverse ? 1 : 0
    }

    func convert(_ forwardDepth: Float) -> Float {
        self == .sceneKitReverse ? 1 - forwardDepth : forwardDepth
    }
}

enum MarbleOccluderMesh {
    static func boxPositions(
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>,
        transform: simd_float4x4
    ) -> [SIMD3<Float>] {
        let corners: [SIMD3<Float>] = [
            SIMD3(minimum.x, minimum.y, minimum.z),
            SIMD3(maximum.x, minimum.y, minimum.z),
            SIMD3(maximum.x, maximum.y, minimum.z),
            SIMD3(minimum.x, maximum.y, minimum.z),
            SIMD3(minimum.x, minimum.y, maximum.z),
            SIMD3(maximum.x, minimum.y, maximum.z),
            SIMD3(maximum.x, maximum.y, maximum.z),
            SIMD3(minimum.x, maximum.y, maximum.z),
        ].map {
            let point = transform * SIMD4<Float>($0, 1)
            return SIMD3<Float>(point.x, point.y, point.z)
        }
        let indices = [
            0, 1, 2, 0, 2, 3, 4, 6, 5, 4, 7, 6,
            0, 4, 5, 0, 5, 1, 3, 2, 6, 3, 6, 7,
            0, 3, 7, 0, 7, 4, 1, 5, 6, 1, 6, 2,
        ]
        return indices.map { corners[$0] }
    }

    static func positions(
        for triangles: [WorldTriangle]
    ) -> [SIMD3<Float>] {
        triangles.flatMap { [$0.first, $0.second, $0.third] }
    }
}

@MainActor
enum ResidentPropSurfaceEligibility {
    static func isActive(_ view: MTKView) -> Bool {
        // The controller deliberately pauses MTKView's private display link
        // and runs its own manual loop. Its explicit activity is authoritative.
        guard let surface = view as? MarbleSpatialView else { return false }
        return surface.residentPropRenderingActive && view.window?.isVisible == true
            && view.window?.isMiniaturized == false
            && !view.isHiddenOrHasHiddenAncestor
    }
}

@MainActor
final class MarbleSpatialView: MTKView {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.gmgn.radio",
        category: "MarbleSpatialView"
    )

#if arch(arm64)
    private var spatialRenderer: MarbleSpatialRenderer?
    private var loadedURL: URL?
    private var loadingURL: URL?
#endif
    private var loadTask: Task<Void, Never>?
    private var avatarLoadTask: Task<Void, Never>?
    private var avatarObserverID: UUID?
    private var appliedAvatarRevision: UInt64?
    private var loadingAvatarRevision: UInt64?
    private var appliedAvatarAsset: StageAvatarAsset?
    private let avatarRuntime: StageAvatarRuntimeStore
    private let spatialStage: SpatialStageStore
    private let library: MarbleWorldLibrary
    private var renderScale: CGFloat = 1
    private var renderProfile = LiveCamRenderProfile.fullStage
    private var liveCamOrbit = LiveCamCharacterOrbit()
    private var pendingWorldURL: URL?
    private var didRequestWorldPreparation = false

    private(set) var residentPropRenderingActive = false

    /// 居民视觉帧回读源(仅渲染器自身 drawable,不截桌面);供应用接线交给
    /// ResidentVisionCaptureService / ResidentVisionToolbox。
    private var residentVisionSurface: (any ResidentVisionSurface)?

    /// 非空时表示本视图(arm64 渲染器)可为居民观察提供真实画面帧。
    var residentVisionSurfaceHandle: (any ResidentVisionSurface)? {
        residentVisionSurface
    }

    func setResidentPropRenderingActive(_ active: Bool) {
        residentPropRenderingActive = active
        if !active {
#if arch(arm64)
            spatialRenderer?.suspendResidentPropRendering()
#endif
        }
    }

    override var isHidden: Bool {
        didSet {
            if isHidden {
#if arch(arm64)
                spatialRenderer?.suspendResidentPropRendering()
#endif
            }
        }
    }

    init(
        frame: CGRect,
        spatialStage: SpatialStageStore,
        library: MarbleWorldLibrary,
        avatarRuntime: StageAvatarRuntimeStore = .shared
    ) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("gmgn radio requires a Metal-capable Mac")
        }
        self.avatarRuntime = avatarRuntime
        self.spatialStage = spatialStage
        self.library = library
        super.init(frame: frame, device: device)

        colorPixelFormat = .bgra8Unorm_srgb
        depthStencilPixelFormat = .depth32Float
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        clearDepth = 1
        framebufferOnly = true
#if DEBUG
        if MarbleDebugFrameCapture.shared != nil {
            framebufferOnly = false
        }
#endif
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        autoResizeDrawable = false
        wantsLayer = true
        layer?.isOpaque = false
        isHidden = true

#if arch(arm64)
        do {
            let renderer = try MarbleSpatialRenderer(
                view: self,
                spatialStage: spatialStage,
                avatarRuntime: avatarRuntime
            )
            spatialRenderer = renderer
            restoreAvatarObservationAfterReparent()
            delegate = renderer
            let visionSurface = MarbleResidentVisionSurface()
            residentVisionSurface = visionSurface
            spatialRenderer?.residentVisionSurface = visionSurface
            visionSurface.attach(hostView: self)
            library.onLocalSplatChange = { [weak self] url in
                self?.receiveWorldURL(url)
            }
        } catch {
            Self.log.error("Unable to create Marble renderer: \(error.localizedDescription, privacy: .public)")
            isHidden = true
        }
#else
        isHidden = true
#endif
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
        avatarLoadTask?.cancel()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            setResidentPropRenderingActive(false)
            avatarRuntime.removeObserver(avatarObserverID)
            avatarObserverID = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        restoreAvatarObservationAfterReparent()
        updateScaledDrawableSize()
    }

    override func layout() {
        super.layout()
        updateScaledDrawableSize()
    }

    func applyRenderQuality(
        framesPerSecond: Int,
        renderScale: CGFloat
    ) {
        preferredFramesPerSecond = min(max(framesPerSecond, 1), 120)
        self.renderScale = min(max(renderScale, 0.25), 1)
        updateScaledDrawableSize()
    }

    func applyRenderProfile(_ profile: LiveCamRenderProfile) {
        renderProfile = profile
#if arch(arm64)
        spatialRenderer?.applyRenderProfile(profile)
        if profile.drawsWorld {
            prepareWorldIfNeeded()
        }
#endif
    }

    /// The local living pod ships with the app and renders synchronously through
    /// its own SceneKit renderer, so it has no Marble SPZ to prepare or wait on.
    /// When the full stage requests its world presentation, complete it here so
    /// entering the local picture never blocks on a remote world.
    private func presentLocalLivingPodIfRequested() {
        guard LivingPodScene.isLocalWorld(spatialStage.selectedWorldID),
              renderProfile.drawsWorld,
              spatialStage.isWorldPresentationRequested
        else {
            return
        }
        spatialStage.finishWorldPresentation()
    }

    /// Reconciles the renderer with the library's current selection whenever
    /// the shared surface moves from the character-only Live Cam into the
    /// full stage. This recovers a selection callback that arrived while the
    /// world layer was intentionally disabled.
    func prepareSelectedWorldForFullStage() {
        guard renderProfile.drawsWorld else { return }
        if LivingPodScene.isLocalWorld(spatialStage.selectedWorldID) {
            presentLocalLivingPodIfRequested()
            return
        }
#if arch(arm64)
        if let selectedURL = library.localSplatURL {
            receiveWorldURL(selectedURL)
        } else {
            didRequestWorldPreparation = false
            prepareWorldIfNeeded()
        }
#endif
    }

    /// Decodes the selected world while the lightweight Live Cam is visible,
    /// so entering the full stage can reuse the already loaded GPU scene.
    func prewarmSelectedWorld() {
        if LivingPodScene.isLocalWorld(spatialStage.selectedWorldID) {
            presentLocalLivingPodIfRequested()
            return
        }
#if arch(arm64)
        if let selectedURL = library.localSplatURL {
            load(
                url: selectedURL,
                renderer: spatialRenderer,
                spatialStage: spatialStage
            )
            return
        }
        guard !didRequestWorldPreparation else { return }
        didRequestWorldPreparation = true
        loadTask = Task { [weak self] in
            guard let self, let url = await self.library.prepare() else {
                return
            }
            self.pendingWorldURL = url
            self.load(
                url: url,
                renderer: self.spatialRenderer,
                spatialStage: self.spatialStage
            )
        }
#endif
    }

    func updateLiveCamOrbit(_ orbit: LiveCamCharacterOrbit) {
        liveCamOrbit = orbit
#if arch(arm64)
        spatialRenderer?.updateLiveCamOrbit(orbit)
#endif
    }

    /// Runs after the next successfully encoded frame has completed on the
    /// GPU. Live Cam uses this to keep the panel transparent until its local
    /// camera has replaced the full-stage drawable.
    func onNextRenderedFrame(
        _ completion: @escaping @MainActor () -> Void
    ) {
#if arch(arm64)
        spatialRenderer?.onNextRenderedFrame(completion)
        draw()
#else
        completion()
#endif
    }

    func restartContinuousRenderingIfNeeded() {
        guard window != nil, !isPaused else { return }
#if arch(arm64)
        if let spatialRenderer {
            delegate = nil
            delegate = spatialRenderer
        }
#endif
        isPaused = true
        isPaused = false
        draw()
    }

    func restoreAvatarObservationAfterReparent() {
#if arch(arm64)
        guard avatarObserverID == nil, let renderer = spatialRenderer else {
            return
        }
        avatarObserverID = avatarRuntime.observe {
            [weak self, weak renderer, weak avatarRuntime] snapshot in
            guard let avatarRuntime else { return }
            self?.loadAvatar(
                from: snapshot,
                renderer: renderer,
                runtime: avatarRuntime
            )
        }
        avatarRuntime.refresh()
#endif
    }

    private func updateScaledDrawableSize() {
        let backingBounds = convertToBacking(bounds)
        let width = max(backingBounds.width * renderScale, 1)
        let height = max(backingBounds.height * renderScale, 1)
        let scaledSize = CGSize(width: width, height: height)
        guard drawableSize != scaledSize else { return }
        drawableSize = scaledSize
    }

#if arch(arm64)
    private func receiveWorldURL(_ url: URL) {
        if LivingPodScene.isLocalWorld(spatialStage.selectedWorldID) {
            presentLocalLivingPodIfRequested()
            return
        }
        pendingWorldURL = url
        guard renderProfile.drawsWorld else { return }
        load(
            url: url,
            renderer: spatialRenderer,
            spatialStage: spatialStage
        )
    }

    private func prepareWorldIfNeeded() {
        if LivingPodScene.isLocalWorld(spatialStage.selectedWorldID) {
            presentLocalLivingPodIfRequested()
            return
        }
        if let pendingWorldURL {
            load(
                url: pendingWorldURL,
                renderer: spatialRenderer,
                spatialStage: spatialStage
            )
            return
        }
        guard !didRequestWorldPreparation else { return }
        didRequestWorldPreparation = true
        loadTask = Task { [weak self] in
            guard let self, let url = await self.library.prepare() else {
                return
            }
            self.receiveWorldURL(url)
        }
    }

    private func load(
        url: URL,
        renderer: MarbleSpatialRenderer?,
        spatialStage: SpatialStageStore
    ) {
        if LivingPodScene.isLocalWorld(spatialStage.selectedWorldID) {
            presentLocalLivingPodIfRequested()
            return
        }
        if loadedURL == url {
            if spatialStage.isWorldPresentationRequested {
                spatialStage.finishWorldPresentation()
            }
            return
        }
        guard loadingURL != url else {
            return
        }
        loadingURL = url
        loadTask?.cancel()
        loadTask = Task { [weak self, weak renderer] in
            do {
                try await renderer?.load(url: url)
                guard !Task.isCancelled else {
                    return
                }
                self?.loadingURL = nil
                self?.loadedURL = url
                if spatialStage.isWorldPresentationRequested {
                    spatialStage.finishWorldPresentation()
                }
            } catch is CancellationError {
                return
            } catch {
                self?.loadingURL = nil
                spatialStage.exitWorld()
                if let cabin = spatialStage.marbleLivingCabin,
                   cabin.worldID == spatialStage.selectedWorldID
                {
                    self?.library.reportLivingCabinFailure(error)
                }
                Self.log.error("Unable to load Marble SPZ: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func loadAvatar(
        from snapshot: StageAvatarRuntimeSnapshot,
        renderer: MarbleSpatialRenderer?,
        runtime: StageAvatarRuntimeStore
    ) {
        guard appliedAvatarRevision != snapshot.revision,
              loadingAvatarRevision != snapshot.revision
        else {
            return
        }

        if appliedAvatarRevision != nil,
           appliedAvatarAsset == snapshot.avatar,
           loadingAvatarRevision == nil
        {
            appliedAvatarRevision = snapshot.revision
            renderer?.resetWorldMotionSynchronization()
            return
        }
        avatarLoadTask?.cancel()
        loadingAvatarRevision = snapshot.revision
        renderer?.clearAvatar()

        let plan: MarbleAvatarLoadPlan
        do {
            plan = try MarbleAvatarLoadPlan.resolve(snapshot)
        } catch {
            loadingAvatarRevision = nil
            runtime.markFailed(error)
            Self.log.error(
                "Unable to prepare stage avatar: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        guard plan != .none else {
            appliedAvatarRevision = snapshot.revision
            appliedAvatarAsset = nil
            loadingAvatarRevision = nil
            return
        }

        let revision = snapshot.revision
        runtime.markLoading()
        avatarLoadTask = Task { [weak self, weak renderer] in
            guard let renderer else {
                if self?.loadingAvatarRevision == revision {
                    self?.loadingAvatarRevision = nil
                }
                return
            }
            do {
                try await renderer.loadAvatar(using: plan)
                guard !Task.isCancelled else {
                    if self?.loadingAvatarRevision == revision {
                        self?.loadingAvatarRevision = nil
                    }
                    return
                }
                guard runtime.snapshot.revision == revision else {
                    if self?.loadingAvatarRevision == revision {
                        self?.loadingAvatarRevision = nil
                    }
                    return
                }
                self?.appliedAvatarRevision = revision
                self?.appliedAvatarAsset = snapshot.avatar
                self?.loadingAvatarRevision = nil
                runtime.markReady()
            } catch is CancellationError {
                if self?.loadingAvatarRevision == revision {
                    self?.loadingAvatarRevision = nil
                }
                return
            } catch {
                guard !Task.isCancelled,
                      runtime.snapshot.revision == revision
                else {
                    if self?.loadingAvatarRevision == revision {
                        self?.loadingAvatarRevision = nil
                    }
                    return
                }
                self?.loadingAvatarRevision = nil
                renderer.clearAvatar()
                runtime.markFailed(error)
                Self.log.error(
                    "Unable to load stage avatar: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
#endif

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

#if arch(arm64)
private final class MarbleFrameCompletion: @unchecked Sendable {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func complete() {
        Task { @MainActor in
            action()
        }
    }
}

private struct MarbleOccluderUniforms {
    var viewProjection: simd_float4x4
    var depthConvention: SIMD4<Float>
}

// BEGIN RESIDENT VISION FRAME SOURCE
/// Resident vision frame source that reads back this renderer's own full-stage
/// drawable only — never the desktop, never a screen recording. Captures are
/// strictly request-driven (one in flight at a time) and only the frame that is
/// newly rendered *after* the request is returned.
///
/// Request identity: every request gets a fresh `captureID` generation through
/// the hostless `ResidentVisionSingleFlight` gate. Completion (GPU readback),
/// cancellation and immediate frame-offer resolutions all carry that generation
/// and only take effect while it is still the current request — so when request
/// A is cancelled and request B starts, A's late GPU callback or A's late cancel
/// task can never resolve or cancel B.
@MainActor
final class MarbleResidentVisionSurface: ResidentVisionSurface {
    private struct Pending {
        let captureID: UUID
        let request: ResidentVisionCaptureRequest
        let requestedAt: Date
        /// framebufferOnly 在本次请求开始前的原值。任何出口都只恢复该原值,
        /// 绝不无条件置 true(DEBUG 帧导出等可能合法地要求保持 false)。
        let originalFramebufferOnly: Bool
        let continuation: CheckedContinuation<
            ResidentVisionSurfaceFrameResult, Never
        >
    }

    private weak var hostView: MTKView?
    private var pending: Pending?
    private var readbackInFlight = false
    /// 单飞 + 代次匹配(纯逻辑,离线测试直接覆盖同一份生产代码)。
    private let flight = ResidentVisionSingleFlight()

    func attach(hostView: MTKView) {
        self.hostView = hostView
    }

    func captureCurrentObservation(
        request: ResidentVisionCaptureRequest,
        requestedAt: Date
    ) async -> ResidentVisionSurfaceFrameResult {
        // 每次调用一个 captureID 身份;完成/取消都带它,过期回调不能碰新请求。
        let captureID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard let hostView else {
                    // 无画面视图:立即失败 —— 不登记请求、不改 framebufferOnly、
                    // 也不空等到超时。
                    continuation.resume(
                        returning: .failure(
                            code: .captureUnavailable,
                            message: "没有可用的舞台画面视图(全舞台渲染器未接入)"
                        )
                    )
                    return
                }
                guard self.flight.begin(captureID: captureID) else {
                    continuation.resume(
                        returning: .failure(
                            code: .captureUnavailable,
                            message: "上一次画面请求尚未完成,请稍后重试"
                        )
                    )
                    return
                }
                self.pending = Pending(
                    captureID: captureID,
                    request: request,
                    requestedAt: requestedAt,
                    originalFramebufferOnly: hostView.framebufferOnly,
                    continuation: continuation
                )
                // Drawable readback needs a non-framebufferOnly drawable. Flip
                // the layer flag only while this request is active; the recorded
                // original value is restored on every exit path (frame, failure,
                // cancel, timeout, no picture).
                hostView.framebufferOnly = false
                // Produce a fresh frame promptly even if the explicit render
                // loop is between beats.
                hostView.draw()
            }
        } onCancel: { [weak self, captureID] in
            Task { @MainActor [weak self] in
                self?.finishIfCurrent(
                    captureID,
                    .failure(
                        code: .cancelled,
                        message: "画面请求已取消"
                    )
                )
            }
        }
    }

    /// Called by the renderer at the end of every rendered frame, after every
    /// pass (world, props, avatar) has drawn into the shared drawable.
    func offerRenderedFrame(
        view: MTKView,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer,
        profile: LiveCamRenderProfile,
        worldID: String?,
        worldVisible: Bool,
        camera: SpatialCameraState,
        avatarAssetID: String?,
        avatarFrameRevision: UInt64,
        avatarPosition: SIMD3<Float>,
        frameIndex: UInt64
    ) {
        guard let pending, !readbackInFlight else { return }
        let captureID = pending.captureID
        guard profile == .fullStage, worldVisible,
              let worldID, !worldID.isEmpty
        else {
            finishIfCurrent(
                captureID,
                .failure(
                    code: .noPicture,
                    message:
                        "当前没有可见的全舞台画面(full-stage 未激活或空间不可见)"
                )
            )
            return
        }
        guard worldID == pending.request.worldID else {
            finishIfCurrent(
                captureID,
                .failure(
                    code: .staleWorld,
                    message: "等待画面期间空间已切换,画面不属于请求的空间"
                )
            )
            return
        }
        encodeReadback(
            view: view,
            drawable: drawable,
            commandBuffer: commandBuffer,
            captureID: captureID,
            worldID: worldID,
            camera: camera,
            avatarAssetID: avatarAssetID,
            avatarFrameRevision: avatarFrameRevision,
            avatarPosition: avatarPosition,
            frameIndex: frameIndex
        )
    }

    private func encodeReadback(
        view: MTKView,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer,
        captureID: UUID,
        worldID: String,
        camera: SpatialCameraState,
        avatarAssetID: String?,
        avatarFrameRevision: UInt64,
        avatarPosition: SIMD3<Float>,
        frameIndex: UInt64
    ) {
        guard let pending, pending.captureID == captureID else { return }
        let originalFramebufferOnly = pending.originalFramebufferOnly
        let texture = drawable.texture
        let width = texture.width
        let height = texture.height
        let bytesPerRow = (width * 4 + 255) & ~255
        guard texture.pixelFormat == .bgra8Unorm_srgb,
              let buffer = texture.device.makeBuffer(
                  length: bytesPerRow * height,
                  options: .storageModeShared
              ),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            finishIfCurrent(
                captureID,
                .failure(
                    code: .encodingFailed,
                    message: "无法为画面分配 GPU 回读缓冲"
                )
            )
            return
        }
        readbackInFlight = true
        blit.label = "gmgn resident vision single frame readback"
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()

        let stamp = ResidentVisionRenderedStamp(
            surfaceProfile: "full_stage_drawable",
            frameIndex: frameIndex,
            capturedAt: Date(),
            worldID: worldID,
            residentAvatarID: avatarAssetID,
            residentAvatarFrameRevision: avatarFrameRevision,
            residentPosition: [
                avatarPosition.x, avatarPosition.y, avatarPosition.z,
            ],
            camera: ResidentVisionCameraStamp(
                label: "全舞台固定观察相机(full-stage observer)",
                kind: .fullStageObserver,
                position: [
                    camera.position.x, camera.position.y, camera.position.z,
                ],
                yaw: camera.yaw,
                pitch: camera.pitch,
                fieldOfViewDegrees: 66,
                coordinateSpace: "stage_renderer_current_world"
            )
        )
        commandBuffer.addCompletedHandler { [weak self, captureID] completed in
            guard completed.status == .completed else {
                let message = "画面 GPU 回读失败:"
                    + (completed.error?.localizedDescription ?? "unknown")
                Task { @MainActor [weak self] in
                    self?.finishIfCurrent(
                        captureID,
                        .failure(
                            code: .encodingFailed,
                            message: message
                        )
                    )
                }
                return
            }
            let pixels = Data(
                bytes: buffer.contents(),
                count: bytesPerRow * height
            )
            Task { @MainActor [weak self] in
                self?.finishIfCurrent(
                    captureID,
                    .frame(
                        ResidentVisionRenderedFrame(
                            pixelsBGRA: pixels,
                            width: width,
                            height: height,
                            bytesPerRow: bytesPerRow,
                            stamp: stamp
                        )
                    )
                )
            }
        }
        // The blit is already encoded, so the current drawable no longer needs
        // to stay readable while the readback finishes: restore the
        // framebufferOnly value recorded when this request started (never
        // unconditionally true — a DEBUG frame export or another reader may
        // legitimately require it to stay false).
        view.framebufferOnly = originalFramebufferOnly
    }

    /// 只有 captureID 仍是当前请求时才结束它并恢复 framebufferOnly 原值。
    /// 过期回调(旧请求的 GPU 完成、旧取消任务)在这里被丢弃,无法解析或
    /// 取消之后才开始的新请求。
    private func finishIfCurrent(
        _ captureID: UUID,
        _ result: ResidentVisionSurfaceFrameResult
    ) {
        guard let pending, pending.captureID == captureID else { return }
        guard flight.finish(captureID) else { return }
        self.pending = nil
        readbackInFlight = false
        let originalFramebufferOnly = pending.originalFramebufferOnly
        hostView?.framebufferOnly = originalFramebufferOnly
        pending.continuation.resume(returning: result)
    }
}
// END RESIDENT VISION FRAME SOURCE

/// Renders supplied room or prop geometry into the shared Metal drawable.
/// The local legacy room clears the background; a standalone Marble prop
/// preserves the SPZ colour already rendered. Neither owns the avatar.
@MainActor
private final class LivingPodRoomRenderer {
    /// SceneKit encodes depth in its reversed convention; the room pass clears
    /// to the far plane. The avatar pass clears depth again after the room, so
    /// in v1 furniture is allowed not to occlude the character.
    private static let reverseDepthClear = 0.0

    /// Very dark starfield backdrop outside the open-front cabin shell.
    private static let backgroundClearColor = MTLClearColorMake(
        0.008,
        0.012,
        0.02,
        1
    )

    private let sceneRenderer: SCNRenderer
    private let scene = SCNScene()
    private let roomNode: SCNNode
    private let cameraNode = SCNNode()
    private let ambientLightNode = SCNNode()
    private let keyLightNode = SCNNode()
    private let fillLightNode = SCNNode()

    init(device: MTLDevice, rootNode: SCNNode) {
        sceneRenderer = SCNRenderer(device: device, options: nil)
        sceneRenderer.scene = scene

        roomNode = rootNode
        scene.rootNode.addChildNode(roomNode)

        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = false
        cameraNode.name = "gmgn-living-pod-camera"
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        configureWarmInteriorLighting()

        scene.background.contents = NSColor.clear
        sceneRenderer.pointOfView = cameraNode
        sceneRenderer.autoenablesDefaultLighting = false
        sceneRenderer.isPlaying = false
    }

    /// Renders the cabin into the current frame's color and depth targets.
    /// Returns false when the target is unusable so the caller can skip the
    /// rest of the frame.
    @discardableResult
    func render(
        commandBuffer: MTLCommandBuffer,
        colorTexture: MTLTexture,
        depthTexture: MTLTexture,
        projection: simd_float4x4,
        camera: SpatialCameraState,
        preservesBackground: Bool = false,
        preservesDepth: Bool = false
    ) -> Bool {
        let width = colorTexture.width
        let height = colorTexture.height
        guard width > 0, height > 0 else { return false }

        let cameraView = Self.rotationX(-camera.pitch)
            * Self.rotationY(-camera.yaw)
            * Self.translation(-camera.position)
        cameraNode.simdTransform = cameraView.inverse
        cameraNode.camera?.projectionTransform = SCNMatrix4(projection)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = preservesBackground ? .load : .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Self.backgroundClearColor
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = preservesDepth ? .load : .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = Self.reverseDepthClear

        sceneRenderer.render(
            atTime: 0,
            viewport: CGRect(
                x: 0,
                y: 0,
                width: width,
                height: height
            ),
            commandBuffer: commandBuffer,
            passDescriptor: pass
        )
        return true
    }

    private func configureWarmInteriorLighting() {
        ambientLightNode.name = "gmgn-living-pod-ambient-light"
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 125
        ambient.color = NSColor(
            calibratedRed: 0.90,
            green: 0.69,
            blue: 0.48,
            alpha: 1
        )
        ambientLightNode.light = ambient
        scene.rootNode.addChildNode(ambientLightNode)

        keyLightNode.name = "gmgn-living-pod-key-light"
        let key = SCNLight()
        key.type = .directional
        key.intensity = 880
        key.color = NSColor(
            calibratedRed: 1,
            green: 0.78,
            blue: 0.56,
            alpha: 1
        )
        keyLightNode.light = key
        keyLightNode.simdEulerAngles = SIMD3<Float>(-0.72, 0.48, 0)
        scene.rootNode.addChildNode(keyLightNode)

        fillLightNode.name = "gmgn-living-pod-fill-light"
        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 240
        fill.color = NSColor(
            calibratedRed: 0.46,
            green: 0.58,
            blue: 0.82,
            alpha: 1
        )
        fillLightNode.light = fill
        fillLightNode.simdEulerAngles = SIMD3<Float>(-0.28, -0.86, 0)
        scene.rootNode.addChildNode(fillLightNode)
    }

    private static func translation(
        _ value: SIMD3<Float>
    ) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(value.x, value.y, value.z, 1)
        ))
    }

    private static func rotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, c, s, 0),
            SIMD4(0, -s, c, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    private static func rotationY(_ angle: Float) -> simd_float4x4 {
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

@MainActor
private final class MarbleSpatialRenderer: NSObject, MTKViewDelegate {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.gmgn.radio",
        category: "MarbleSpatialRenderer"
    )

    private let commandQueue: MTLCommandQueue
    private let spatialStage: SpatialStageStore
    private var renderer: SplatRenderer
    private let occluderPipeline: MTLRenderPipelineState
    private let occluderForwardDepthState: MTLDepthStencilState
    private let occluderReverseDepthState: MTLDepthStencilState
    private var occluderVertexBuffer: MTLBuffer?
    private var occluderVertexCount = 0
    private var appliedOccluderRevision = UInt64.max
    private var drawableSize = CGSize.zero
    private var sceneFraming = MarbleSceneFraming(positions: [])
    private let inFlightSemaphore = DispatchSemaphore(value: 2)
    private let clock = ContinuousClock()
    private var previousFrameAt: ContinuousClock.Instant
    private let avatarRuntime: StageAvatarRuntimeStore
    private var avatarRenderer: VRMRenderer?
    private var avatarModel: VRMModel?
    private var avatarAnimationPlayer: AnimationPlayer?
    private var appliedVRMLocomotionGait: StageLocomotionGait?
    private var avatarRestRotations: [VRMHumanoidBone: simd_quatf] = [:]
    private var pmxAvatarRenderer: PMXStageAvatarRenderer?
    private var appliedVRMResolvedMotion: StageAvatarResolvedMotion?
    private var appliedPMXResolvedMotion: StageAvatarResolvedMotion?
    private var appliedVRMPlaybackIdentity: StageMotionPlaybackIdentity?
    private var appliedPMXPlaybackIdentity: StageMotionPlaybackIdentity?
    /// Terminal failed playback identities, retained so a failed motion stays
    /// failed across temporary thinking/world-motion changes. Entries are
    /// pruned whenever the snapshot revision advances and the arrays are
    /// capped, so retention cannot grow indefinitely.
    private var failedVRMPlaybackIdentities: [StageMotionPlaybackIdentity] = []
    private var failedPMXPlaybackIdentities: [StageMotionPlaybackIdentity] = []
    private var lastLoggedPMXRenderProfile: LiveCamRenderProfile?
    private var renderProfile = LiveCamRenderProfile.fullStage
    private var liveCamOrbit = LiveCamCharacterOrbit()
    private var fullStageFrameSampler = FrameRateSampler()
    private var nextFrameCompletions: [MarbleFrameCompletion] = []
    /// 居民视觉帧回读源(渲染器自身 drawable 的请求式导出)。
    var residentVisionSurface: MarbleResidentVisionSurface?
    private var renderedFrameCounter: UInt64 = 0
    private var livingPodRoomRenderer: LivingPodRoomRenderer?
    private var marbleJukeboxRenderer: LivingPodRoomRenderer?
    private var marbleJukeboxNode: SCNNode?
    private var marbleWishMachineNode: SCNNode?
    private var wishMachineOutputRenderer: WishMachineOutputRenderer?
    private var residentPropRenderer: ResidentPropRenderer?
    private var propSupportGridRenderer: PropSupportGridRenderer?
    private let residentPropRenderOwner = ResidentPropRenderOwner()
    private var residentPropRenderRevision: UInt64?
    private var residentDisplayStandNode: SCNNode?
    private var residentDisplayStandDescriptor: ResidentPropDisplayStand?
    private var marbleIndependentPropsNode: SCNNode?

    init(
        view: MTKView,
        spatialStage: SpatialStageStore,
        avatarRuntime: StageAvatarRuntimeStore
    ) throws {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue()
        else {
            throw StageRendererError.missingCommandQueue
        }
        guard let library = device.makeDefaultLibrary(),
              let occluderVertex = library.makeFunction(
                  name: "marbleOccluderVertex"
              ),
              let occluderFragment = library.makeFunction(
                  name: "marbleOccluderFragment"
              )
        else {
            throw StageRendererError.missingShaderLibrary
        }
        let occluderPipelineDescriptor = MTLRenderPipelineDescriptor()
        occluderPipelineDescriptor.label = "gmgn radio GLB depth occluder"
        occluderPipelineDescriptor.vertexFunction = occluderVertex
        occluderPipelineDescriptor.fragmentFunction = occluderFragment
        occluderPipelineDescriptor.colorAttachments[0].pixelFormat =
            view.colorPixelFormat
        occluderPipelineDescriptor.colorAttachments[0].writeMask = []
        occluderPipelineDescriptor.depthAttachmentPixelFormat =
            view.depthStencilPixelFormat
        occluderPipeline = try device.makeRenderPipelineState(
            descriptor: occluderPipelineDescriptor
        )
        let forwardDepthDescriptor = MTLDepthStencilDescriptor()
        forwardDepthDescriptor.depthCompareFunction = .less
        forwardDepthDescriptor.isDepthWriteEnabled = true
        let reverseDepthDescriptor = MTLDepthStencilDescriptor()
        reverseDepthDescriptor.depthCompareFunction = .greater
        reverseDepthDescriptor.isDepthWriteEnabled = true
        guard let occluderForwardDepthState = device.makeDepthStencilState(
            descriptor: forwardDepthDescriptor
        ), let occluderReverseDepthState = device.makeDepthStencilState(
            descriptor: reverseDepthDescriptor
        ) else {
            throw StageRendererError.missingDepthState
        }
        self.commandQueue = commandQueue
        self.occluderForwardDepthState = occluderForwardDepthState
        self.occluderReverseDepthState = occluderReverseDepthState
        self.spatialStage = spatialStage
        self.avatarRuntime = avatarRuntime
        previousFrameAt = clock.now
        renderer = try SplatRenderer(
            device: device,
            colorFormat: view.colorPixelFormat,
            depthFormat: view.depthStencilPixelFormat,
            sampleCount: view.sampleCount,
            maxViewCount: 1,
            maxSimultaneousRenders: 2,
            highQualityDepth: MarbleSpatialDepthPolicy.usesAlphaAwareDepth,
            clearColor: view.clearColor
        )
        super.init()
    }

    func load(url: URL) async throws {
        guard !Task.isCancelled else {
            return
        }
        let device = renderer.device
        let worldID = spatialStage.selectedWorldID
        let cabinPresentation = spatialStage.marbleLivingCabin.flatMap {
            $0.worldID == worldID ? $0 : nil
        }
        let scene = spatialStage.selectedScene
        let worldCalibration = SpatialWorldCalibration.resolve(
            worldID: worldID
        )
        let loggedWorldID = worldID ?? "nil"
        Self.log.notice(
            "Loading world id=\(loggedWorldID, privacy: .public) calibrated=\(worldCalibration != nil, privacy: .public)"
        )
        let loadedScene = try await Task.detached(priority: .userInitiated) {
            let reader = try AutodetectSceneReader(url)
            let points = try await reader.readAll()
            let sampleStride = max(points.count / 40_000, 1)
            let sampledPoints = stride(
                from: 0,
                to: points.count,
                by: sampleStride
            ).map { points[$0] }
            let framing = cabinPresentation?.sceneFraming
                ?? MarbleSceneFraming(positions: sampledPoints.map(\.position))
            let cameraHome = cabinPresentation?.camera
                ?? worldCalibration?.cameraHome
                ?? framing.recommendedCameraHome(worldID: worldID)
            let samples = sampledPoints.map { point in
                framing.normalizedSample(
                    position: point.position,
                    scale: point.scale.asLinearFloat,
                    rotation: point.rotation
                )
            }
            let avatarPlacement = if let authoredPlacement =
                cabinPresentation?.avatarPlacement
            {
                authoredPlacement
            } else if let calibratedPlacement =
                worldCalibration?.avatarPlacement
            {
                StageAvatarPlacementSolver.grounded(
                    placement: calibratedPlacement,
                    normalizedSamples: samples
                )
            } else {
                StageAvatarPlacementSolver.resolve(
                    normalizedSamples: samples,
                    camera: cameraHome,
                    scene: scene
                )
            }
            return (
                chunk: try SplatChunk(device: device, from: points),
                framing: framing,
                cameraHome: cameraHome,
                avatarPlacement: avatarPlacement
            )
        }.value
        guard !Task.isCancelled else {
            return
        }
        await renderer.removeAllChunks()
        sceneFraming = loadedScene.framing
        spatialStage.installSceneFraming(loadedScene.framing)
        spatialStage.installCameraHome(loadedScene.cameraHome)
        spatialStage.installAvatarPlacement(loadedScene.avatarPlacement)
        Self.log.notice(
            "Installed avatar placement x=\(loadedScene.avatarPlacement.position.x, privacy: .public) y=\(loadedScene.avatarPlacement.position.y, privacy: .public) z=\(loadedScene.avatarPlacement.position.z, privacy: .public) scale=\(loadedScene.avatarPlacement.scale, privacy: .public) yaw=\(loadedScene.avatarPlacement.yaw, privacy: .public)"
        )
        await renderer.addChunk(loadedScene.chunk)
    }

    func loadAvatar(using plan: MarbleAvatarLoadPlan) async throws {
        switch plan {
        case .none:
            clearAvatar()
        case let .vrm(modelURL, motion):
            try await loadVRMAvatar(from: modelURL, motion: motion)
        case let .pmx(modelURL, resourceRootURL, motionURL):
            try await loadPMXAvatar(
                from: modelURL,
                resourceRootURL: resourceRootURL,
                motionURL: motionURL
            )
        }
    }

    private func loadVRMAvatar(
        from url: URL,
        motion: StageMotionAsset?
    ) async throws {
        guard !Task.isCancelled else { return }
        let model = try await VRMModel.load(from: url, device: renderer.device)
        guard !Task.isCancelled else { return }

        let config = RendererConfig(
            strict: .off,
            colorPixelFormat: .bgra8Unorm_srgb,
            sampleCount: 1
        )
        let avatarRenderer = VRMRenderer(
            device: renderer.device,
            config: config
        )
        avatarRenderer.outlineWidth = 0.016
        avatarRenderer.setLight(
            0,
            direction: SIMD3<Float>(0.25, -0.32, -0.9),
            color: SIMD3<Float>(1, 0.94, 0.88),
            intensity: 0.95
        )
        avatarRenderer.setLight(
            1,
            direction: SIMD3<Float>(-0.65, -0.12, -0.55),
            color: SIMD3<Float>(0.24, 0.74, 1),
            intensity: 0.42
        )
        avatarRenderer.setLight(
            2,
            direction: SIMD3<Float>(0.12, -0.2, 0.92),
            color: SIMD3<Float>(0.74, 0.35, 1),
            intensity: 0.32
        )
        avatarRenderer.setAmbientColor(SIMD3<Float>(0.10, 0.12, 0.16))
        avatarRenderer.loadModel(model)
        avatarRenderer.enableSpringBone = true
        avatarRenderer.lookAtController?.enabled = true
        avatarRenderer.lookAtController?.target = .camera

        var restRotations: [VRMHumanoidBone: simd_quatf] = [:]
        for bone in [
            VRMHumanoidBone.spine,
            .chest,
            .upperChest,
            .neck,
            .head,
            .leftUpperArm,
            .rightUpperArm,
            .leftLowerArm,
            .rightLowerArm,
        ] {
            if let rotation = model.getLocalRotation(for: bone) {
                restRotations[bone] = rotation
            }
        }
        avatarModel = model
        self.avatarRenderer = avatarRenderer
        avatarAnimationPlayer = nil
        appliedVRMLocomotionGait = nil
        // Apply through the frame synchronizer so load failures use the same
        // identity cache and feedback path as later motion changes.
        appliedVRMResolvedMotion = nil
        appliedVRMPlaybackIdentity = nil
        avatarRestRotations = restRotations
        pmxAvatarRenderer = nil
        appliedPMXResolvedMotion = nil
    }

    private func loadPMXAvatar(
        from modelURL: URL,
        resourceRootURL: URL,
        motionURL: URL?
    ) async throws {
        guard !Task.isCancelled else { return }
        let pmxRenderer = PMXStageAvatarRenderer(device: renderer.device)
        pmxRenderer.setLightingProfile(
            PMXAvatarLightingPolicy.resolve(
                renderProfile: renderProfile,
                worldLighting: SpatialWorldCalibration.resolve(
                    worldID: spatialStage.selectedWorldID
                )?.lighting
            )
        )
        try await pmxRenderer.loadModel(
            from: modelURL,
            resourceRootURL: resourceRootURL
        )
        guard !Task.isCancelled else { return }
        guard !Task.isCancelled else { return }

        avatarRenderer = nil
        avatarModel = nil
        avatarAnimationPlayer = nil
        appliedVRMLocomotionGait = nil
        appliedVRMResolvedMotion = nil
        avatarRestRotations.removeAll(keepingCapacity: false)
        pmxAvatarRenderer = pmxRenderer
        appliedPMXResolvedMotion = nil
        appliedPMXPlaybackIdentity = nil
    }

    func clearAvatar() {
        avatarRenderer = nil
        avatarModel = nil
        avatarAnimationPlayer = nil
        appliedVRMLocomotionGait = nil
        appliedVRMResolvedMotion = nil
        avatarRestRotations.removeAll(keepingCapacity: false)
        pmxAvatarRenderer = nil
        appliedPMXResolvedMotion = nil
    }

    func resetWorldMotionSynchronization() {
        appliedVRMResolvedMotion = nil
        appliedPMXResolvedMotion = nil
    }

    func applyRenderProfile(_ profile: LiveCamRenderProfile) {
        guard renderProfile != profile else { return }
        renderProfile = profile
        if !profile.drawsWorld {
            suspendResidentPropRendering()
        }
        fullStageFrameSampler.reset()
        pmxAvatarRenderer?.setLightingProfile(
            PMXAvatarLightingPolicy.resolve(
                renderProfile: profile,
                worldLighting: SpatialWorldCalibration.resolve(
                    worldID: spatialStage.selectedWorldID
                )?.lighting
            )
        )
    }

    func suspendResidentPropRendering() {
        spatialStage.releaseResidentPropRenderer(residentPropRenderOwner)
        residentPropRenderRevision = nil
        residentPropRenderer?.update([], preview: nil, worldID: nil, isVisible: false)
        spatialStage.isResidentPropBuildModeActive = false
        spatialStage.residentPropGridCells = []
        spatialStage.residentPropGridStates = [:]
        // 原因与格子同生共死：格子收掉了，"为什么不能放"当然也不该留在屏幕上。
        spatialStage.residentPropBlockReason = nil
    }

    func updateLiveCamOrbit(_ orbit: LiveCamCharacterOrbit) {
        liveCamOrbit = orbit
    }

    func onNextRenderedFrame(
        _ completion: @escaping @MainActor () -> Void
    ) {
        nextFrameCompletions.append(MarbleFrameCompletion(completion))
    }

    func draw(in view: MTKView) {
        renderedFrameCounter &+= 1
        if !ResidentPropSurfaceEligibility.isActive(view) { suspendResidentPropRendering() }
        if residentPropRenderer == nil, renderProfile.drawsWorld {
            residentPropRenderer = ResidentPropRenderer(device: renderer.device, colorFormat: view.colorPixelFormat, depthFormat: view.depthStencilPixelFormat)
        }
        if propSupportGridRenderer == nil, renderProfile.drawsWorld {
            propSupportGridRenderer = PropSupportGridRenderer(device: renderer.device, colorFormat: view.colorPixelFormat, depthFormat: view.depthStencilPixelFormat)
        }
        let propLease = spatialStage.residentPropRenderOwnership.claim(
            owner: residentPropRenderOwner, worldID: spatialStage.selectedWorldID,
            drawsWorld: renderProfile.drawsWorld, isVisible: spatialStage.isWorldVisible && ResidentPropSurfaceEligibility.isActive(view)
        )
        if let revision = propLease, revision != residentPropRenderRevision, let propRenderer = residentPropRenderer {
            let owner = residentPropRenderOwner, worldID = spatialStage.selectedWorldID
            propRenderer.onStatusChanged = { [weak spatialStage, weak owner, weak view] id, status in
                guard let spatialStage, let owner, let view, ResidentPropSurfaceEligibility.isActive(view), spatialStage.residentPropRenderOwnership.accepts(owner: owner, worldID: worldID, revision: revision) else { return }
                spatialStage.residentPropRenderStatuses[id] = status == .empty ? nil : status
            }
            spatialStage.residentPropPrepareHandler = { [weak propRenderer, weak spatialStage, weak owner, weak view] descriptor in
                guard let propRenderer, let spatialStage, let owner, let view, ResidentPropSurfaceEligibility.isActive(view),
                      spatialStage.residentPropRenderOwnership.accepts(owner: owner, worldID: descriptor.worldID, revision: revision) else { throw CancellationError() }
                let prepared = try await propRenderer.prepare(descriptor)
                guard ResidentPropSurfaceEligibility.isActive(view), spatialStage.residentPropRenderOwnership.accepts(owner: owner, worldID: descriptor.worldID, revision: revision) else { throw CancellationError() }
                return prepared
            }
            spatialStage.residentPropPreparedHandler = { [weak propRenderer, weak spatialStage, weak owner, weak view] assetID, modelURL, worldID in
                guard let spatialStage, let owner, let view, ResidentPropSurfaceEligibility.isActive(view), spatialStage.residentPropRenderOwnership.accepts(owner: owner, worldID: worldID, revision: revision) else { return false }
                return propRenderer?.isPrepared(assetID: assetID, modelURL: modelURL, worldID: worldID) ?? false
            }
            spatialStage.residentPropAttachmentValidationHandler = { [weak self, weak spatialStage, weak owner, weak view] avatarID, point in
                guard let self, let spatialStage, let owner, let view,
                      ResidentPropSurfaceEligibility.isActive(view),
                      spatialStage.residentPropRenderOwnership.accepts(
                          owner: owner,
                          worldID: worldID,
                          revision: revision
                      ),
                      self.renderProfile.drawsWorld,
                      self.avatarRuntime.snapshot.avatar?.id == avatarID,
                      let pmxAvatarRenderer = self.pmxAvatarRenderer
                else {
                    throw PropAttachmentError.unsupportedAvatar
                }
                try pmxAvatarRenderer.validateAttachmentPoint(point)
            }
            spatialStage.residentPropClearHandler = { [weak propRenderer] in
                propRenderer?.update([], preview: nil, worldID: nil, isVisible: false)
            }
            spatialStage.residentPropActiveHandler = { [weak spatialStage, weak owner, weak view] in
                guard let spatialStage, let owner, let view, ResidentPropSurfaceEligibility.isActive(view) else { return false }
                return spatialStage.residentPropRenderOwnership.accepts(owner: owner, worldID: worldID, revision: revision)
            }
            residentPropRenderRevision = revision
        }
        residentPropRenderer?.update(
            spatialStage.residentPropOutputs,
            preview: spatialStage.residentPropPreview,
            held: renderProfile.drawsWorld ? spatialStage.residentHeldProp : nil,
            worldID: spatialStage.selectedWorldID,
            isVisible: propLease != nil
        )
        reconcileMarbleWishMachineNode()
        if wishMachineOutputRenderer == nil, renderProfile.drawsWorld {
            let outputRenderer = WishMachineOutputRenderer(device: renderer.device, colorFormat: view.colorPixelFormat, depthFormat: view.depthStencilPixelFormat)
            outputRenderer.onStatusChanged = { [weak spatialStage] status in
                guard let spatialStage else { return }
                switch status {
                case .empty: break
                case let .loading(id), let .ready(id), let .failed(id, _):
                    guard spatialStage.wishMachineOutput?.id == id,
                          spatialStage.wishMachineOutput?.worldID == spatialStage.selectedWorldID,
                          spatialStage.isWorldVisible else { return }
                }
                spatialStage.wishMachineOutputStatus = status
            }
            wishMachineOutputRenderer = outputRenderer
        }
        wishMachineOutputRenderer?.update(
            spatialStage.wishMachineOutput, worldID: spatialStage.selectedWorldID,
            isVisible: spatialStage.isWorldVisible && WishMachineScene.shouldDisplay(worldID: spatialStage.selectedWorldID, drawsWorld: renderProfile.drawsWorld)
        )
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        let now = clock.now
        let duration = previousFrameAt.duration(to: now).components
        previousFrameAt = now
        let delta = Float(
            Double(duration.seconds)
                + Double(duration.attoseconds) / 1_000_000_000_000_000_000
        )
        spatialStage.stepCamera(
            deltaTime: delta,
            speedBoosted: spatialStage.isSpeedBoosted
        )
        // Avatar-follow rotation arrives at snapshot cadence (about 30 Hz).
        // Digest it at render cadence before any view matrix below reads the
        // camera, so the world rotates on every rendered frame instead of
        // stepping whole snapshot deltas every other 60 fps frame.
        spatialStage.advanceAvatarFollowRotation(deltaTime: delta)

        _ = inFlightSemaphore.wait(timeout: .distantFuture)
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }

        let drawsLivingPodRoom = LivingPodScene.shouldDisplay(
            worldID: spatialStage.selectedWorldID,
            drawsWorld: renderProfile.drawsWorld
        )
        if drawsLivingPodRoom,
           spatialStage.isWorldPresentationRequested,
           !spatialStage.isWorldVisible
        {
            // The pod's SceneKit room below is renderable immediately, so its
            // world presentation never waits for a Marble download.
            spatialStage.finishWorldPresentation()
        }

        if renderProfile.drawsWorld {
            if drawsLivingPodRoom {
                guard drawLivingPodRoom(
                    in: view,
                    drawable: drawable,
                    commandBuffer: commandBuffer
                ) else {
                    commandBuffer.commit()
                    return
                }
            } else {
                guard renderer.isReadyToRender else {
                    commandBuffer.commit()
                    return
                }
                do {
                    let didRender = try renderer.render(
                        viewports: [viewport(for: view)],
                        colorTexture: drawable.texture,
                        colorStoreAction: .store,
                        depthTexture: view.depthStencilTexture,
                        rasterizationRateMap: nil,
                        renderTargetArrayLength: 0,
                        to: commandBuffer
                    )
                    guard didRender else {
                        commandBuffer.commit()
                        return
                    }
                } catch {
                    commandBuffer.commit()
                    return
                }
                drawMarbleJukebox(
                    in: view,
                    drawable: drawable,
                    commandBuffer: commandBuffer
                )
            }
        } else {
            clearLocalSurface(
                in: view,
                drawable: drawable,
                commandBuffer: commandBuffer
            )
        }

        let projection = projectionMatrix(for: view)
        let hasPreparedOccluder = drawSceneOccluder(
            in: view,
            drawable: drawable,
            commandBuffer: commandBuffer,
            projection: projection
        )

        var hasGeneratedOutputDepth = false
        if renderProfile.drawsWorld, let depthTexture = view.depthStencilTexture {
            let camera = spatialStage.camera
            let cameraView = rotationX(-camera.pitch) * rotationY(-camera.yaw) * translation(-camera.position)
            if propLease != nil { spatialStage.residentPropViewProjection = projection * cameraView }
            hasGeneratedOutputDepth = wishMachineOutputRenderer?.render(
                commandBuffer: commandBuffer, colorTexture: drawable.texture, depthTexture: depthTexture,
                viewProjection: projection * cameraView, cameraPosition: camera.position,
                reversedDepth: MarbleSceneDepthConvention.resolve(avatarFormat: avatarRuntime.snapshot.avatar?.format) == .sceneKitReverse,
                preservesDepth: hasPreparedOccluder
            ) ?? false
            let hasPlacedProps = residentPropRenderer?.render(
                commandBuffer: commandBuffer, colorTexture: drawable.texture, depthTexture: depthTexture,
                viewProjection: projection * cameraView, cameraPosition: camera.position,
                reversedDepth: MarbleSceneDepthConvention.resolve(avatarFormat: avatarRuntime.snapshot.avatar?.format) == .sceneKitReverse,
                preservesDepth: hasPreparedOccluder || hasGeneratedOutputDepth
            ) ?? false
            hasGeneratedOutputDepth = hasGeneratedOutputDepth || hasPlacedProps

            // 建造模式的格子。只做深度测试、不写深度，所以它的返回值**不并入**
            // preservesDepth 链：它没有让后面的绘制多一层遮挡。
            if spatialStage.isResidentPropBuildModeActive, let propSupportGridRenderer {
                propSupportGridRenderer.render(
                    commandBuffer: commandBuffer, colorTexture: drawable.texture, depthTexture: depthTexture,
                    viewProjection: projection * cameraView,
                    reversedDepth: MarbleSceneDepthConvention.resolve(avatarFormat: avatarRuntime.snapshot.avatar?.format) == .sceneKitReverse,
                    preservesDepth: hasPreparedOccluder || hasGeneratedOutputDepth,
                    instances: spatialStage.residentPropGridInstances(cameraPosition: camera.position)
                )
            }
        }

        if renderProfile.drawsAvatar {
            drawAvatar(
                in: view,
                drawable: drawable,
                commandBuffer: commandBuffer,
                projection: projection,
                hasPreparedOccluder: hasPreparedOccluder || hasGeneratedOutputDepth,
                deltaTime: max(delta, 0)
            )
        }
        renderResidentHeldProp(
            in: view,
            drawable: drawable,
            commandBuffer: commandBuffer,
            projection: projection
        )
        residentVisionSurface?.offerRenderedFrame(
            view: view,
            drawable: drawable,
            commandBuffer: commandBuffer,
            profile: renderProfile,
            worldID: spatialStage.selectedWorldID,
            worldVisible: spatialStage.isWorldVisible,
            camera: spatialStage.camera,
            avatarAssetID: avatarRuntime.snapshot.avatar?.id,
            avatarFrameRevision: avatarRuntime.snapshot.revision,
            avatarPosition: spatialStage.avatarPlacement.position,
            frameIndex: renderedFrameCounter
        )
#if DEBUG
        if renderProfile == .fullStage,
           let frameCapture = MarbleDebugFrameCapture.shared
        {
            frameCapture.encode(
                texture: drawable.texture,
                commandBuffer: commandBuffer,
                isReady: renderer.isReadyToRender
                    && spatialStage.isWorldVisible
                    && spatialStage.marbleLivingCabin?.worldID == spatialStage.selectedWorldID
                    && marbleJukeboxNode != nil
                    && marbleWishMachineNode?.parent != nil
                    && (avatarModel != nil || pmxAvatarRenderer != nil)
                    && hasPreparedOccluder
                    && occluderVertexCount > 0
            )
        }
#endif
        commandBuffer.present(drawable)
        let frameCompletions = nextFrameCompletions
        nextFrameCompletions.removeAll(keepingCapacity: true)
        if !frameCompletions.isEmpty {
            commandBuffer.addCompletedHandler { _ in
                frameCompletions.forEach { $0.complete() }
            }
        }
        commandBuffer.commit()

        if renderProfile == .fullStage,
           spatialStage.isWorldVisible,
           let report = fullStageFrameSampler.recordFrame(
               at: ProcessInfo.processInfo.systemUptime
           )
        {
            Self.log.notice(
                "Full-stage 30-minute frame report samples=\(report.sampleCount, privacy: .public) averageFPS=\(report.averageFramesPerSecond, privacy: .public) p95FrameMS=\(report.p95FrameTimeMilliseconds, privacy: .public) p95FPS=\(report.p95FramesPerSecond, privacy: .public)"
            )
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }

    private func drawLivingPodRoom(
        in view: MTKView,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard let depthTexture = view.depthStencilTexture else {
            return false
        }
        let podRenderer: LivingPodRoomRenderer
        if let livingPodRoomRenderer {
            podRenderer = livingPodRoomRenderer
        } else {
            let roomRenderer = LivingPodRoomRenderer(
                device: self.renderer.device,
                rootNode: LivingPodScene.makeRoomNode()
            )
            livingPodRoomRenderer = roomRenderer
            podRenderer = roomRenderer
        }
        return podRenderer.render(
            commandBuffer: commandBuffer,
            colorTexture: drawable.texture,
            depthTexture: depthTexture,
            projection: projectionMatrix(for: view),
            camera: spatialStage.camera
        )
    }

    private func drawMarbleJukebox(
        in view: MTKView,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer
    ) {
        guard renderProfile.drawsWorld,
              let cabin = spatialStage.marbleLivingCabin,
              cabin.worldID == spatialStage.selectedWorldID,
              let depthTexture = view.depthStencilTexture
        else { return }

        if marbleJukeboxRenderer == nil {
            let node = LivingPodScene.makeIndependentJukebox()
            marbleJukeboxNode = node
            let props = SCNNode()
            marbleIndependentPropsNode = props
            props.name = "marble-interactive-props"
            props.addChildNode(node)
            marbleJukeboxRenderer = LivingPodRoomRenderer(
                device: renderer.device,
                rootNode: props
            )
        }
        reconcileMarbleWishMachineNode()
        marbleJukeboxNode?.simdPosition = cabin.jukeboxPosition
        let stand = spatialStage.residentPropDisplayStand.flatMap { $0.worldID == spatialStage.selectedWorldID ? $0 : nil }
        if stand != residentDisplayStandDescriptor {
            residentDisplayStandNode?.removeFromParentNode()
            residentDisplayStandNode = stand.map { ResidentPropScene.makeDisplayStand($0) }
            if let node = residentDisplayStandNode { marbleIndependentPropsNode?.addChildNode(node) }
            residentDisplayStandDescriptor = stand
        }
        marbleJukeboxNode?.simdEulerAngles = SIMD3<Float>(0, cabin.jukeboxYaw, 0)
        // Exclude the device proxy here so it does not hide its own geometry.
        let hasSceneDepth = drawSceneOccluder(
            in: view,
            drawable: drawable,
            commandBuffer: commandBuffer,
            projection: projectionMatrix(for: view),
            depthOverride: .sceneKitReverse,
            includeCabinProp: false
        )
        marbleJukeboxRenderer?.render(
            commandBuffer: commandBuffer,
            colorTexture: drawable.texture,
            depthTexture: depthTexture,
            projection: projectionMatrix(for: view),
            camera: spatialStage.camera,
            preservesBackground: true,
            preservesDepth: hasSceneDepth
        )
    }

    private func reconcileMarbleWishMachineNode() {
        guard let propsRoot = marbleIndependentPropsNode else {
            marbleWishMachineNode = nil
            return
        }
        marbleWishMachineNode = WishMachineScene.reconcileMachineNode(
            in: propsRoot,
            worldID: spatialStage.selectedWorldID,
            drawsWorld: renderProfile.drawsWorld
        )
        if let marbleWishMachineNode {
            WishMachineScene.update(
                marbleWishMachineNode,
                state: spatialStage.wishMachineState
            )
        }
    }

    private func viewport(for view: MTKView) -> SplatRenderer.ViewportDescriptor {
        let size = MarbleViewportMetrics.resolve(
            reportedSize: drawableSize,
            drawableSize: view.drawableSize
        )
        let width = max(Float(size.width), 1)
        let height = max(Float(size.height), 1)
        let projection = perspectiveMatrix(
            fieldOfView: 66 * .pi / 180,
            aspect: width / height,
            near: 0.05,
            far: 250
        )
        let camera = spatialStage.camera
        let sceneTransform = scale(sceneFraming.uniformScale)
            * translation(-sceneFraming.groundedOrigin)
        let viewMatrix = rotationX(-camera.pitch)
            * rotationY(-camera.yaw)
            * translation(-camera.position)
            * sceneTransform

        return SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(width),
                height: Double(height),
                znear: 0,
                zfar: 1
            ),
            projectionMatrix: projection,
            viewMatrix: viewMatrix,
            screenSize: SIMD2(Int(width), Int(height))
        )
    }

    private func projectionMatrix(for view: MTKView) -> simd_float4x4 {
        let size = MarbleViewportMetrics.resolve(
            reportedSize: drawableSize,
            drawableSize: view.drawableSize
        )
        return perspectiveMatrix(
            fieldOfView: (renderProfile == .liveCam ? 44 : 66) * .pi / 180,
            aspect: max(Float(size.width), 1) / max(Float(size.height), 1),
            near: 0.05,
            far: 250
        )
    }

    private func drawSceneOccluder(
        in view: MTKView,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer,
        projection: simd_float4x4,
        depthOverride: MarbleSceneDepthConvention? = nil,
        includeCabinProp: Bool = true
    ) -> Bool {
        guard renderProfile == .fullStage,
              spatialStage.isWorldVisible,
              !LivingPodScene.isLocalWorld(spatialStage.selectedWorldID),
              let depthTexture = view.depthStencilTexture
        else {
            return false
        }
        refreshOccluderBufferIfNeeded()
        let propVertices: [SIMD3<Float>]
        if includeCabinProp,
           let cabin = spatialStage.marbleLivingCabin,
           cabin.worldID == spatialStage.selectedWorldID,
           let node = marbleJukeboxNode
        {
            let bounds = node.boundingBox
            var vertices = MarbleOccluderMesh.boxPositions(
                minimum: SIMD3<Float>(Float(bounds.min.x), Float(bounds.min.y), Float(bounds.min.z)),
                maximum: SIMD3<Float>(Float(bounds.max.x), Float(bounds.max.y), Float(bounds.max.z)),
                transform: node.simdTransform
            )
            if let machine = marbleWishMachineNode, !machine.isHidden {
                let bounds = machine.boundingBox
                vertices += MarbleOccluderMesh.boxPositions(
                    minimum: SIMD3<Float>(Float(bounds.min.x), Float(bounds.min.y), Float(bounds.min.z)),
                    maximum: SIMD3<Float>(Float(bounds.max.x), Float(bounds.max.y), Float(bounds.max.z)),
                    transform: machine.simdTransform
                )
            }
            if let stand = residentDisplayStandNode {
                let bounds = stand.boundingBox
                vertices += MarbleOccluderMesh.boxPositions(
                    minimum: SIMD3(Float(bounds.min.x),Float(bounds.min.y),Float(bounds.min.z)),
                    maximum: SIMD3(Float(bounds.max.x),Float(bounds.max.y),Float(bounds.max.z)),
                    transform: stand.simdTransform
                )
            }
            propVertices = vertices
        } else {
            propVertices = []
        }
        guard occluderVertexCount > 0 || !propVertices.isEmpty else {
            return false
        }

        let camera = spatialStage.camera
        let cameraView = rotationX(-camera.pitch)
            * rotationY(-camera.yaw)
            * translation(-camera.position)
        let depthConvention = depthOverride ?? MarbleSceneDepthConvention.resolve(
            avatarFormat: avatarRuntime.snapshot.avatar?.format
        )
        var uniforms = MarbleOccluderUniforms(
            viewProjection: projection * cameraView,
            depthConvention: SIMD4<Float>(
                depthConvention.shaderFlag,
                0,
                0,
                0
            )
        )
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = depthConvention.clearDepth
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            return false
        }
        encoder.label = "gmgn radio GLB depth occluder"
        encoder.setRenderPipelineState(occluderPipeline)
        encoder.setDepthStencilState(
            depthConvention == .sceneKitReverse
                ? occluderReverseDepthState
                : occluderForwardDepthState
        )
        encoder.setCullMode(.none)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<MarbleOccluderUniforms>.stride,
            index: 1
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<MarbleOccluderUniforms>.stride,
            index: 1
        )
        if let occluderVertexBuffer, occluderVertexCount > 0 {
            encoder.setVertexBuffer(occluderVertexBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: occluderVertexCount
            )
        }
        if !propVertices.isEmpty {
            propVertices.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                encoder.setVertexBytes(baseAddress, length: bytes.count, index: 0)
            }
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: propVertices.count
            )
        }
        encoder.endEncoding()
        return true
    }

    private func refreshOccluderBufferIfNeeded() {
        guard appliedOccluderRevision != spatialStage.sceneOccluderRevision
        else {
            return
        }
        appliedOccluderRevision = spatialStage.sceneOccluderRevision
        let positions = MarbleOccluderMesh.positions(
            for: spatialStage.sceneOccluderTriangles
        )
        guard !positions.isEmpty else {
            occluderVertexBuffer = nil
            occluderVertexCount = 0
            return
        }
        occluderVertexBuffer = positions.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return renderer.device.makeBuffer(
                bytes: baseAddress,
                length: bytes.count,
                options: .storageModeShared
            )
        }
        occluderVertexBuffer?.label = "gmgn radio GLB depth vertices"
        occluderVertexCount = occluderVertexBuffer == nil
            ? 0
            : positions.count
    }

    private func drawAvatar(
        in view: MTKView,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer,
        projection: simd_float4x4,
        hasPreparedOccluder: Bool,
        deltaTime: Float
    ) {
        guard (renderProfile == .liveCam || spatialStage.isWorldVisible),
              let depthTexture = view.depthStencilTexture
        else {
            return
        }

        let placement = spatialStage.avatarPlacement
        let cameraView: simd_float4x4
        if renderProfile == .liveCam {
            let frame = liveCamOrbit.camera(following: placement.position)
            cameraView = lookAtMatrix(
                eye: frame.position,
                target: frame.target,
                up: SIMD3<Float>(0, 1, 0)
            )
        } else {
            let camera = spatialStage.camera
            cameraView = rotationX(-camera.pitch)
                * rotationY(-camera.yaw)
                * translation(-camera.position)
        }
        let pass = sharedAvatarPass(
            drawable: drawable,
            depthTexture: depthTexture,
            hasPreparedOccluder: hasPreparedOccluder,
            depthConvention: MarbleSceneDepthConvention.resolve(
                avatarFormat: avatarRuntime.snapshot.avatar?.format
            )
        )

        if let avatarRenderer, let avatarModel {
            drawVRMAvatar(
                in: view,
                renderer: avatarRenderer,
                model: avatarModel,
                commandBuffer: commandBuffer,
                pass: pass,
                cameraView: cameraView,
                projection: projection,
                placement: placement,
                deltaTime: deltaTime
            )
        } else if let pmxAvatarRenderer {
            synchronizePMXWorldMotion(pmxAvatarRenderer)
            let shouldLogPMXFrame = lastLoggedPMXRenderProfile != renderProfile
            let profileName = renderProfile == .liveCam ? "liveCam" : "fullStage"
            if shouldLogPMXFrame {
                lastLoggedPMXRenderProfile = renderProfile
            }
            let pmxCameraView: simd_float4x4
            let pmxProjection: simd_float4x4
            let pmxModelTransform: simd_float4x4
            if renderProfile == .liveCam {
                var localCamera = DesktopPMXCameraState.default
                localCamera.yaw = liveCamOrbit.yaw - placement.yaw
                localCamera.pitch = -liveCamOrbit.pitch
                localCamera.zoom = min(
                    max(
                        1.45 / liveCamOrbit.distance,
                        DesktopPMXCameraState.minimumZoom
                    ),
                    DesktopPMXCameraState.maximumZoom
                )
                let framing = DesktopPMXFraming.matrices(
                    bounds: pmxAvatarRenderer.localBounds,
                    drawableSize: view.drawableSize,
                    camera: localCamera,
                    trackingOffset: LiveCamPMXTrackingPolicy.cameraOffset(
                        animatedRootOffset: pmxAvatarRenderer.animatedRootOffset,
                        bounds: pmxAvatarRenderer.localBounds
                    )
                )
                pmxCameraView = framing.view
                pmxProjection = framing.projection
                pmxModelTransform = matrix_identity_float4x4
            } else {
                let groundingOffset = PMXFullStageGroundingPolicy.offset(
                    rootMotionEnabled: pmxAvatarRenderer.rootMotionEnabled,
                    animatedOffset: pmxAvatarRenderer.localGroundingOffsetY
                )
                let matrices = MarblePMXRenderMatrices.fullStage(
                    bounds: pmxAvatarRenderer.localBounds,
                    placement: placement,
                    localGroundingOffsetY: groundingOffset,
                    soleReferenceY: pmxAvatarRenderer.restFootReferenceY,
                    sharedCameraView: cameraView
                )
                pmxCameraView = matrices.cameraView
                pmxProjection = projection
                pmxModelTransform = matrices.modelTransform
            }
            PMXStageAvatarRenderer.configureSharedStagePass(pass)
            MarbleSpatialDepthPolicy.configureAvatarDepth(
                pass,
                hasPreparedOccluder: hasPreparedOccluder,
                convention: .sceneKitReverse
            )
            pmxAvatarRenderer.setCoffeeMachineVisible(
                PMXWarmKitchenCoffeeMachine.shouldDisplay(
                    worldID: spatialStage.selectedWorldID,
                    drawsWorld: renderProfile.drawsWorld
                )
            )
            if shouldLogPMXFrame {
                let bounds = pmxAvatarRenderer.localBounds
                let modelBounds = "min=\(String(describing: bounds?.minimum)) max=\(String(describing: bounds?.maximum))"
                let tracking = LiveCamPMXTrackingPolicy.cameraOffset(
                    animatedRootOffset: pmxAvatarRenderer.animatedRootOffset,
                    bounds: bounds
                )
                let eye = pmxCameraView.inverse.columns.3
                let localTarget = (bounds?.center ?? SIMD3<Float>(0, 0.9, 0))
                    + (renderProfile == .liveCam ? tracking : .zero)
                let transformedTarget = pmxModelTransform * SIMD4<Float>(localTarget, 1)
                let target = SIMD3<Float>(transformedTarget.x, transformedTarget.y, transformedTarget.z)
                let distance = simd_distance(SIMD3<Float>(eye.x, eye.y, eye.z), target)
                Self.log.notice(
                    "PMX frame geometry profile=\(profileName, privacy: .public) boundsWidth=\(view.bounds.width, privacy: .public) boundsHeight=\(view.bounds.height, privacy: .public) drawableWidth=\(view.drawableSize.width, privacy: .public) drawableHeight=\(view.drawableSize.height, privacy: .public) textureWidth=\(drawable.texture.width, privacy: .public) textureHeight=\(drawable.texture.height, privacy: .public) modelBounds=\(modelBounds, privacy: .public)"
                )
                Self.log.notice(
                    "PMX frame camera profile=\(profileName, privacy: .public) eyeX=\(eye.x, privacy: .public) eyeY=\(eye.y, privacy: .public) eyeZ=\(eye.z, privacy: .public) targetX=\(target.x, privacy: .public) targetY=\(target.y, privacy: .public) targetZ=\(target.z, privacy: .public) distance=\(distance, privacy: .public) tracking=\(String(describing: tracking), privacy: .public) projectionX=\(pmxProjection.columns.0.x, privacy: .public) projectionY=\(pmxProjection.columns.1.y, privacy: .public)"
                )
            }
            pmxAvatarRenderer.locomotionMeasuredSpeed = avatarRuntime.locomotion.isLocomotionActive
                ? avatarRuntime.locomotion.gaitGroundSpeed : nil
            pmxAvatarRenderer.encode(
                commandBuffer: commandBuffer,
                renderPassDescriptor: pass,
                viewMatrix: pmxCameraView,
                projectionMatrix: pmxProjection,
                modelTransform: pmxModelTransform,
                time: Date.timeIntervalSinceReferenceDate,
                diagnosticProfile: shouldLogPMXFrame ? profileName : nil
            )
        }
    }

    /// Drops failure records from earlier playback revisions. Entries keyed to
    /// a stale revision can never repeat, so this keeps retention bounded
    /// across avatar/session changes.
    private func pruneStaleFailedPlaybackIdentities(
        _ identities: inout [StageMotionPlaybackIdentity]
    ) {
        let revision = avatarRuntime.snapshot.revision
        identities.removeAll { $0.snapshotRevision != revision }
    }

    /// Remembers a terminal failed playback identity so it is not re-attempted
    /// when the same identity re-resolves after temporary thinking or
    /// world-motion changes. Only an explicit new playback revision or
    /// activity request (a fresh identity) permits another attempt.
    private func rememberFailedPlaybackIdentity(
        _ identity: StageMotionPlaybackIdentity,
        into identities: inout [StageMotionPlaybackIdentity]
    ) {
        pruneStaleFailedPlaybackIdentities(&identities)
        guard !identities.contains(identity) else { return }
        identities.append(identity)
        if identities.count > 32 { identities.removeFirst() }
    }

    private func synchronizePMXWorldMotion(
        _ renderer: PMXStageAvatarRenderer
    ) {
        let heldDisplayMotion: StageMotionAsset? = if renderProfile.drawsWorld,
           spatialStage.residentHeldProp?.calibration.avatarAssetID
            == avatarRuntime.snapshot.avatar?.id
        {
            avatarRuntime.residentHoldDisplayMotion
        } else {
            nil
        }
        let resolved = StageAvatarResolvedMotion.resolve(
            selectedMotion: avatarRuntime.snapshot.motion,
            worldPlayback: avatarRuntime.worldActivity?.renderPlayback,
            residentThinkingMotion: avatarRuntime.residentThinkingMotion,
            heldDisplayMotion: heldDisplayMotion,
            naturalIdleMotion: avatarRuntime.residentIdleMotion
        )
        let identity: StageMotionPlaybackIdentity? = if case let .asset(motion) = resolved {
            avatarRuntime.playbackIdentity(for: motion)
        } else { nil }
        pruneStaleFailedPlaybackIdentities(&failedPMXPlaybackIdentities)
        guard resolved != appliedPMXResolvedMotion || identity != appliedPMXPlaybackIdentity else { return }
        // Cache the attempt before loading, including failures. A fresh user
        // revision or world request explicitly permits another attempt.
        appliedPMXResolvedMotion = resolved
        appliedPMXPlaybackIdentity = identity
        renderer.onMotionFinished = nil
        if let identity, failedPMXPlaybackIdentities.contains(identity) {
            // A failed identity stays failed across temporary thinking and
            // world-motion changes. Restore the cleared renderer state without
            // re-loading the bad asset or re-reporting the terminal failure.
            // This path used to be silent; a body that keeps translating with
            // no motion is exactly the "sliding" defect, so it names itself.
            renderer.setCoffeeCupVisible(false)
            renderer.clearMotion()
            Self.log.error(
                "PMX motion \(identity.motion.id, privacy: .public) was already reported failed for this request; the avatar falls back to the rest pose instead of re-attempting it"
            )
            return
        }

        switch resolved {
        case .naturalIdle:
            renderer.setCoffeeCupVisible(false)
            renderer.clearMotion()
            appliedPMXResolvedMotion = resolved
            Self.log.notice(
                "Cleared PMX motion to the rest pose: the world resolved no playable clip (thinking/selected/idle all unavailable)"
            )
        case let .asset(motion):
            guard motion.format == .vmd, let motionURL = motion.url else {
                renderer.setCoffeeCupVisible(false)
                renderer.clearMotion()
                if let identity {
                    rememberFailedPlaybackIdentity(identity, into: &failedPMXPlaybackIdentities)
                    avatarRuntime.reportMotionPlayback(identity: identity, outcome: .failed("Resolved PMX motion has no compatible VMD asset"))
                }
                Self.log.error(
                    "Resolved PMX motion has no compatible VMD asset id=\(motion.id, privacy: .public) format=\(motion.format.rawValue, privacy: .public) url=\(motion.url == nil ? "nil" : "set", privacy: .public); the avatar falls back to the rest pose"
                )
                return
            }
            renderer.onMotionFinished = { [weak avatarRuntime] url in
                guard let identity, identity.motion.url == url else { return }
                avatarRuntime?.reportMotionPlayback(identity: identity, outcome: .completed)
            }
            let loaded = loadPMXMotion(
                motionURL,
                into: renderer,
                repeats: motion.loop,
                playbackRate: motion.playbackRate,
                inPlace: motion.inPlace == true,
                locomotion: PMXStageAvatarRenderer.locomotionGait(for: motion),
                identity: identity,
                failureMessage: "Unable to apply resolved PMX motion"
            )
            if loaded {
                appliedPMXResolvedMotion = resolved
                renderer.setCoffeeCupVisible(
                    PMXWarmKitchenCoffeeCup.shouldDisplay(motionID: motion.id)
                )
                Self.log.notice(
                    "Applied resolved PMX motion id=\(motion.id, privacy: .public) file=\(motionURL.lastPathComponent, privacy: .public) loop=\(motion.loop, privacy: .public)"
                )
            } else {
                renderer.setCoffeeCupVisible(false)
            }
        }
    }

    private func renderResidentHeldProp(
        in view: MTKView,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer,
        projection: simd_float4x4
    ) {
        guard renderProfile.drawsWorld,
              spatialStage.isWorldVisible,
              let held = spatialStage.residentHeldProp,
              held.worldID == spatialStage.selectedWorldID,
              let depthTexture = view.depthStencilTexture
        else { return }
        guard held.calibration.avatarAssetID == avatarRuntime.snapshot.avatar?.id
        else {
            spatialStage.residentPropRenderStatuses[held.objectID] = .failed(
                id: held.objectID,
                message: PropAttachmentError.avatarMismatch.localizedDescription
            )
            return
        }
        guard let pmxAvatarRenderer, let residentPropRenderer else {
            spatialStage.residentPropRenderStatuses[held.objectID] = .failed(
                id: held.objectID,
                message: PropAttachmentError.unsupportedAvatar.localizedDescription
            )
            return
        }
        do {
            let handPose = try pmxAvatarRenderer.evaluatedAttachmentPose(
                for: held.attachmentPoint
            )
            let camera = spatialStage.camera
            let cameraView = rotationX(-camera.pitch)
                * rotationY(-camera.yaw)
                * translation(-camera.position)
            _ = try residentPropRenderer.renderAttachment(
                handPose: handPose,
                commandBuffer: commandBuffer,
                colorTexture: drawable.texture,
                depthTexture: depthTexture,
                viewProjection: projection * cameraView,
                cameraPosition: camera.position,
                reversedDepth: true,
                preservesDepth: true
            )
        } catch {
            spatialStage.residentPropRenderStatuses[held.objectID] = .failed(
                id: held.objectID,
                message: error.localizedDescription
            )
        }
    }

    private func synchronizeVRMWorldMotion(_ model: VRMModel) {
        let resolved = StageAvatarResolvedMotion.resolve(
            selectedMotion: avatarRuntime.snapshot.motion,
            worldPlayback: avatarRuntime.worldActivity?.renderPlayback,
            residentThinkingMotion: avatarRuntime.residentThinkingMotion,
            naturalIdleMotion: avatarRuntime.residentIdleMotion
        )
        let identity: StageMotionPlaybackIdentity? = if case let .asset(motion) = resolved {
            avatarRuntime.playbackIdentity(for: motion)
        } else { nil }
        pruneStaleFailedPlaybackIdentities(&failedVRMPlaybackIdentities)
        guard resolved != appliedVRMResolvedMotion || identity != appliedVRMPlaybackIdentity else { return }
        appliedVRMResolvedMotion = resolved
        appliedVRMPlaybackIdentity = identity

        // Clear
        // the previous clip's complete local pose before the new player writes
        // its tracks, including when returning to idle or loading fails.
        avatarAnimationPlayer = nil
        appliedVRMLocomotionGait = nil
        for node in model.nodes { node.resetToBindPose() }
        model.updateNodeTransforms()
        avatarRenderer?.resetPhysics()

        // A failed identity stays failed across temporary thinking and
        // world-motion changes; only an explicit new playback revision or
        // activity request (a fresh identity) permits another attempt.
        if let identity, failedVRMPlaybackIdentities.contains(identity) {
            return
        }

        do {
            switch resolved {
            case .naturalIdle:
                avatarAnimationPlayer = nil
            case let .asset(motion):
                let loaded = try StageAvatarAnimationLoader.makeLoopingPlayerWithGait(
                    for: motion,
                    model: model
                )
                loaded.player?.lookAtController = avatarRenderer?.lookAtController
                avatarAnimationPlayer = loaded.player
                appliedVRMLocomotionGait = loaded.gait
            }
        } catch {
            avatarAnimationPlayer = nil
            if let identity {
                rememberFailedPlaybackIdentity(identity, into: &failedVRMPlaybackIdentities)
                avatarRuntime.reportMotionPlayback(identity: identity, outcome: .failed(error.localizedDescription))
            }
            Self.log.error(
                "Unable to apply resolved VRM motion: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    @discardableResult
    private func loadPMXMotion(
        _ url: URL,
        into renderer: PMXStageAvatarRenderer,
        repeats: Bool,
        playbackRate: Float,
        inPlace: Bool = false,
        locomotion: StageLocomotionGait? = nil,
        identity: StageMotionPlaybackIdentity? = nil,
        failureMessage: String
    ) -> Bool {
        do {
            try renderer.loadMotion(
                from: url,
                repeats: repeats,
                playbackRate: playbackRate,
                inPlace: inPlace,
                locomotion: locomotion
            )
            return true
        } catch {
            // The renderer declares ``motionLoadFailurePolicy``; honor it
            // instead of contradicting it. Clearing to the rest pose turned one
            // transient bad asset into "the avatar has no motion at all", which
            // reads as sliding whenever the world keeps translating it.
            switch PMXStageAvatarRenderer.motionLoadFailurePolicy {
            case .preserveCurrentMotion:
                break
            }
            if let identity {
                rememberFailedPlaybackIdentity(identity, into: &failedPMXPlaybackIdentities)
                avatarRuntime.reportMotionPlayback(identity: identity, outcome: .failed(error.localizedDescription))
            }
            Self.log.error(
                "\(failureMessage, privacy: .public): \(error.localizedDescription, privacy: .public); keeping the current PMX motion"
            )
            return false
        }
    }

    private func drawVRMAvatar(
        in view: MTKView,
        renderer avatarRenderer: VRMRenderer,
        model avatarModel: VRMModel,
        commandBuffer: MTLCommandBuffer,
        pass: MTLRenderPassDescriptor,
        cameraView: simd_float4x4,
        projection: simd_float4x4,
        placement: StageAvatarPlacement,
        deltaTime: Float
    ) {
        synchronizeVRMWorldMotion(avatarModel)
        StageAvatarAnimationLoader.applyLocomotion(
            telemetry: avatarRuntime.locomotion,
            gait: appliedVRMLocomotionGait,
            player: avatarAnimationPlayer
        )
        let motion = StageAvatarMotionFrame.resolve(
            activity: avatarRuntime.activity,
            voiceLevel: avatarRuntime.voiceLevel,
            time: Date.timeIntervalSinceReferenceDate,
            residentSpeechLevel: avatarRuntime.residentSpeechLevel
        )
        avatarAnimationPlayer?.update(
            deltaTime: min(max(deltaTime, 1 / 240), 1 / 20),
            model: avatarModel
        )
        if let player = avatarAnimationPlayer, player.isFinished,
           let identity = appliedVRMPlaybackIdentity, !identity.motion.loop {
            avatarAnimationPlayer = nil
            appliedVRMLocomotionGait = nil
            for node in avatarModel.nodes { node.resetToBindPose() }
            avatarModel.updateNodeTransforms()
            avatarRenderer.resetPhysics()
            avatarRuntime.reportMotionPlayback(identity: identity, outcome: .completed)
        }
        apply(
            motion: motion,
            to: avatarModel,
            renderer: avatarRenderer,
            usesFullBodyAnimation: avatarAnimationPlayer != nil
        )

        let bodyLift = avatarAnimationPlayer == nil ? motion.bodyLift : 0
        let placedPosition = placement.position
            + SIMD3<Float>(0, bodyLift, 0)
        let modelTransform = translation(placedPosition)
            * rotationY(placement.yaw)
            * scale(placement.scale)

        avatarRenderer.viewMatrix = cameraView * modelTransform
        avatarRenderer.projectionMatrix = projection
        avatarRenderer.simulationDeltaTime = TimeInterval(
            min(max(deltaTime, 1 / 240), 1 / 20)
        )

        avatarRenderer.draw(
            in: view,
            commandBuffer: commandBuffer,
            renderPassDescriptor: pass
        )
    }

    private func sharedAvatarPass(
        drawable: CAMetalDrawable,
        depthTexture: MTLTexture,
        hasPreparedOccluder: Bool,
        depthConvention: MarbleSceneDepthConvention
    ) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        MarbleSpatialDepthPolicy.configureAvatarDepth(
            pass,
            hasPreparedOccluder: hasPreparedOccluder,
            convention: depthConvention
        )
        return pass
    }

    private func clearLocalSurface(
        in view: MTKView,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        if let depthTexture = view.depthStencilTexture {
            pass.depthAttachment.texture = depthTexture
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .store
            pass.depthAttachment.clearDepth = 1
        }
        commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        )?.endEncoding()
    }

    private func lookAtMatrix(
        eye: SIMD3<Float>,
        target: SIMD3<Float>,
        up: SIMD3<Float>
    ) -> simd_float4x4 {
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, up))
        let cameraUp = simd_cross(right, forward)
        return simd_float4x4(columns: (
            SIMD4(right.x, cameraUp.x, -forward.x, 0),
            SIMD4(right.y, cameraUp.y, -forward.y, 0),
            SIMD4(right.z, cameraUp.z, -forward.z, 0),
            SIMD4(
                -simd_dot(right, eye),
                -simd_dot(cameraUp, eye),
                simd_dot(forward, eye),
                1
            )
        ))
    }

    private func apply(
        motion: StageAvatarMotionFrame,
        to model: VRMModel,
        renderer: VRMRenderer,
        usesFullBodyAnimation: Bool
    ) {
        renderer.setExpression(.aa, weight: motion.mouthWeight)
        renderer.setExpression(.blink, weight: motion.blinkWeight)

        guard !usesFullBodyAnimation else {
            return
        }

        if let rest = avatarRestRotations[.spine] {
            let delta = simd_quatf(
                angle: motion.spineYaw,
                axis: SIMD3<Float>(0, 1, 0)
            )
            model.setLocalRotation(rest * delta, for: .spine)
        }
        if let rest = avatarRestRotations[.head] {
            let delta = simd_quatf(
                angle: motion.headTilt,
                axis: SIMD3<Float>(0, 0, 1)
            )
            model.setLocalRotation(rest * delta, for: .head)
        }
        applyRelaxedArmPose(motion: motion, to: model)
        model.updateNodeTransforms()
    }

    private func applyRelaxedArmPose(
        motion: StageAvatarMotionFrame,
        to model: VRMModel
    ) {
        let rotations: [(VRMHumanoidBone, Float, SIMD3<Float>)] = [
            (.leftUpperArm, motion.leftUpperArmDrop, SIMD3<Float>(0, 0, 1)),
            (.rightUpperArm, motion.rightUpperArmDrop, SIMD3<Float>(0, 0, 1)),
            (.leftLowerArm, motion.leftElbowBend, SIMD3<Float>(0, 1, 0)),
            (.rightLowerArm, motion.rightElbowBend, SIMD3<Float>(0, 1, 0)),
        ]
        for (bone, angle, axis) in rotations {
            guard let rest = avatarRestRotations[bone] else { continue }
            model.setLocalRotation(
                rest * simd_quatf(angle: angle, axis: axis),
                for: bone
            )
        }
    }

    private func perspectiveMatrix(
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

    private func translation(_ value: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(value.x, value.y, value.z, 1)
        ))
    }

    private func scale(_ value: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(value, 0, 0, 0),
            SIMD4(0, value, 0, 0),
            SIMD4(0, 0, value, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    private func rotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, c, s, 0),
            SIMD4(0, -s, c, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    private func rotationY(_ angle: Float) -> simd_float4x4 {
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
#endif
