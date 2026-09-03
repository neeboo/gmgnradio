import AppKit
@preconcurrency import MetalKit
import os
import simd

enum DesktopPMXMotionPolicy {
    static func resolvedMotionURL(
        for selection: DesktopAvatarSelection
    ) -> URL? {
        // Full-body VMD choreography is authored for the spatial stage. The
        // compact desktop pet keeps the renderer's natural idle so wrists,
        // fingers and silhouette remain readable at a small size.
        nil
    }
}

struct DesktopPMXCameraState: Equatable, Sendable {
    static let maximumPitch: Float = 0.92
    static let minimumZoom: Float = 0.45
    static let maximumZoom: Float = 2.8
    static let `default` = DesktopPMXCameraState()

    var yaw: Float = 0
    var pitch: Float = 0
    var zoom: Float = 1
    var pan = SIMD2<Float>.zero

    mutating func rotate(deltaX: Float, deltaY: Float) {
        yaw += deltaX * 0.006
        pitch = min(
            max(pitch - deltaY * 0.006, -Self.maximumPitch),
            Self.maximumPitch
        )
    }

    mutating func pan(
        deltaX: Float,
        deltaY: Float,
        modelHeight: Float
    ) {
        let scale = max(modelHeight, 0.5) * 0.0012 / max(zoom, 0.1)
        pan.x += deltaX * scale
        pan.y += deltaY * scale
        let limit = max(modelHeight, 0.5) * 0.42
        pan.x = min(max(pan.x, -limit), limit)
        pan.y = min(max(pan.y, -limit), limit)
    }

    mutating func zoom(delta: Float) {
        zoom = min(
            max(zoom * exp(delta * 0.025), Self.minimumZoom),
            Self.maximumZoom
        )
    }
}

enum DesktopPMXCameraSettings {
    private static let yawKey = "desktop.pmx.camera.yaw"
    private static let pitchKey = "desktop.pmx.camera.pitch"
    private static let zoomKey = "desktop.pmx.camera.zoom"
    private static let panXKey = "desktop.pmx.camera.pan.x"
    private static let panYKey = "desktop.pmx.camera.pan.y"
    private static let lockedKey = "desktop.pmx.camera.locked"

    static func load(
        defaults: UserDefaults
    ) -> (state: DesktopPMXCameraState, isLocked: Bool) {
        var state = DesktopPMXCameraState.default
        if defaults.object(forKey: yawKey) != nil {
            state.yaw = Float(defaults.double(forKey: yawKey))
            state.pitch = Float(defaults.double(forKey: pitchKey))
            state.zoom = min(
                max(
                    Float(defaults.double(forKey: zoomKey)),
                    DesktopPMXCameraState.minimumZoom
                ),
                DesktopPMXCameraState.maximumZoom
            )
            state.pan = SIMD2<Float>(
                Float(defaults.double(forKey: panXKey)),
                Float(defaults.double(forKey: panYKey))
            )
        }
        let isLocked = defaults.object(forKey: lockedKey) == nil
            ? true
            : defaults.bool(forKey: lockedKey)
        return (state, isLocked)
    }

    static func save(
        state: DesktopPMXCameraState,
        isLocked: Bool,
        defaults: UserDefaults
    ) {
        defaults.set(Double(state.yaw), forKey: yawKey)
        defaults.set(Double(state.pitch), forKey: pitchKey)
        defaults.set(Double(state.zoom), forKey: zoomKey)
        defaults.set(Double(state.pan.x), forKey: panXKey)
        defaults.set(Double(state.pan.y), forKey: panYKey)
        defaults.set(isLocked, forKey: lockedKey)
    }
}

enum DesktopPMXPointerAction: Equatable, Sendable {
    case moveWindow
    case orbitCamera
    case panCamera
    case none
}

enum DesktopPMXInteractionPolicy {
    static func dragAction(
        buttonNumber: Int,
        shiftPressed: Bool,
        cameraLocked: Bool
    ) -> DesktopPMXPointerAction {
        switch buttonNumber {
        case 0:
            return .moveWindow
        case 1 where !cameraLocked:
            return shiftPressed ? .panCamera : .orbitCamera
        default:
            return .none
        }
    }
}

enum DesktopPMXFraming {
    static func matrices(
        bounds: PMXAvatarBounds?,
        drawableSize: CGSize,
        camera: DesktopPMXCameraState = .default,
        trackingOffset: SIMD3<Float> = .zero
    ) -> (view: simd_float4x4, projection: simd_float4x4) {
        let bounds = bounds ?? PMXAvatarBounds(
            minimum: SIMD3<Float>(-0.5, 0, -0.5),
            maximum: SIMD3<Float>(0.5, 1.8, 0.5)
        )
        let height = max(bounds.size.y, 0.5)
        let width = max(bounds.size.x, height * 0.28)
        let aspect = max(Float(drawableSize.width), 1)
            / max(Float(drawableSize.height), 1)
        let fieldOfView: Float = 30 * .pi / 180
        let halfVerticalTangent = tan(fieldOfView * 0.5)
        let verticalDistance = height * 1.18 / (2 * halfVerticalTangent)
        let horizontalDistance = width * 1.12
            / (2 * halfVerticalTangent * max(aspect, 0.001))
        let distance = max(verticalDistance, horizontalDistance, 1.2)
            / max(camera.zoom, 0.1)
        let center = bounds.center + trackingOffset + SIMD3<Float>(
            camera.pan.x,
            camera.pan.y,
            0
        )
        let cosPitch = cos(camera.pitch)
        let orbit = SIMD3<Float>(
            sin(camera.yaw) * cosPitch,
            sin(camera.pitch),
            cos(camera.yaw) * cosPitch
        )
        let eye = center + orbit * distance

        return (
            view: lookAt(
                eye: eye,
                center: center,
                up: SIMD3<Float>(0, 1, 0)
            ),
            projection: perspective(
                fieldOfView: fieldOfView,
                aspect: aspect,
                near: max(distance - height * 2, 0.01),
                far: max(distance + height * 4, 10)
            )
        )
    }

    private static func lookAt(
        eye: SIMD3<Float>,
        center: SIMD3<Float>,
        up: SIMD3<Float>
    ) -> simd_float4x4 {
        let forward = simd_normalize(center - eye)
        let side = simd_normalize(simd_cross(forward, up))
        let correctedUp = simd_cross(side, forward)
        return simd_float4x4(
            SIMD4<Float>(side.x, correctedUp.x, -forward.x, 0),
            SIMD4<Float>(side.y, correctedUp.y, -forward.y, 0),
            SIMD4<Float>(side.z, correctedUp.z, -forward.z, 0),
            SIMD4<Float>(
                -simd_dot(side, eye),
                -simd_dot(correctedUp, eye),
                simd_dot(forward, eye),
                1
            )
        )
    }

    private static func perspective(
        fieldOfView: Float,
        aspect: Float,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        let y = 1 / tan(fieldOfView * 0.5)
        let x = y / max(aspect, 0.001)
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, near * z, 0)
        )
    }
}

enum LiveCamPMXTrackingPolicy {
    static func cameraOffset(
        animatedRootOffset: SIMD3<Float>,
        bounds _: PMXAvatarBounds?
    ) -> SIMD3<Float> {
        guard animatedRootOffset.x.isFinite,
              animatedRootOffset.y.isFinite,
              animatedRootOffset.z.isFinite
        else {
            return .zero
        }
        return SIMD3<Float>(animatedRootOffset.x, 0, animatedRootOffset.z)
    }
}

@MainActor
final class PMXAvatarMetalView: MTKView, MTKViewDelegate {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.gmgn.radio",
        category: "PMXAvatarMetalView"
    )

    private let commandQueue: MTLCommandQueue
    private let avatarRenderer: PMXStageAvatarRenderer
    private weak var runtime: StageAvatarRuntimeStore?
    private var loadTask: Task<Void, Never>?
    private let cameraDefaults: UserDefaults
    private var cameraState: DesktopPMXCameraState
    var onMenuRequest: (() -> Void)?
    private(set) var isCameraLocked: Bool

    var localBounds: PMXAvatarBounds? {
        avatarRenderer.localBounds
    }

    init(
        frame: CGRect,
        modelURL: URL,
        motionURL: URL? = nil,
        resourceRootURL: URL? = nil,
        runtime: StageAvatarRuntimeStore? = nil,
        snapshotRevision: UInt64? = nil,
        defaults: UserDefaults = .standard
    ) {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue()
        else {
            preconditionFailure("gmgn radio requires a Metal-capable Mac")
        }

        self.commandQueue = commandQueue
        avatarRenderer = PMXStageAvatarRenderer(device: device)
        self.runtime = runtime
        cameraDefaults = defaults
        let cameraSettings = DesktopPMXCameraSettings.load(defaults: defaults)
        cameraState = cameraSettings.state
        isCameraLocked = cameraSettings.isLocked
        super.init(frame: frame, device: device)

        Self.configureMetalSurface(self)
        delegate = self
        let generation = DesktopAvatarLoadGeneration(
            revision: snapshotRevision ?? runtime?.snapshot.revision ?? 0
        )
        if let runtime,
           generation.canCommit(
               currentRevision: runtime.snapshot.revision,
               taskIsCancelled: false,
               rendererIsAlive: true
           )
        {
            runtime.markLoading()
        }

        let avatarRenderer = self.avatarRenderer
        loadTask = Task {
            @MainActor [weak self, weak avatarRenderer, weak runtime] in
            guard let avatarRenderer else { return }
            do {
                try await avatarRenderer.loadModel(
                    from: modelURL,
                    resourceRootURL: resourceRootURL
                )
                if let motionURL {
                    try await avatarRenderer.loadMotion(from: motionURL)
                }
                guard
                    let runtime,
                    generation.canCommit(
                        currentRevision: runtime.snapshot.revision,
                        taskIsCancelled: Task.isCancelled,
                        rendererIsAlive:
                            self?.avatarRenderer === avatarRenderer
                    )
                else {
                    return
                }
                runtime.markReady()
            } catch is CancellationError {
                return
            } catch {
                guard
                    let runtime,
                    generation.canCommit(
                        currentRevision: runtime.snapshot.revision,
                        taskIsCancelled: Task.isCancelled,
                        rendererIsAlive:
                            self?.avatarRenderer === avatarRenderer
                    )
                else {
                    return
                }
                runtime.markFailed(error)
                Self.log.error(
                    "Unable to load desktop PMX: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    convenience init(
        frame: CGRect,
        selection: DesktopAvatarSelection,
        runtime: StageAvatarRuntimeStore
    ) {
        self.init(
            frame: frame,
            modelURL: selection.avatar.modelURL,
            motionURL: DesktopPMXMotionPolicy.resolvedMotionURL(
                for: selection
            ),
            resourceRootURL: selection.avatar.resourceRootURL,
            runtime: runtime,
            snapshotRevision: selection.revision
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let originalOrigin = window.frame.origin
        window.performDrag(with: event)
        let finalOrigin = window.frame.origin
        let distance = hypot(
            finalOrigin.x - originalOrigin.x,
            finalOrigin.y - originalOrigin.y
        )
        if distance < 3 {
            onMenuRequest?()
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        let action = DesktopPMXInteractionPolicy.dragAction(
            buttonNumber: event.buttonNumber,
            shiftPressed: event.modifierFlags.contains(.shift),
            cameraLocked: isCameraLocked
        )
        switch action {
        case .panCamera:
            cameraState.pan(
                deltaX: Float(event.deltaX),
                deltaY: Float(event.deltaY),
                modelHeight: avatarRenderer.localBounds?.size.y ?? 1.8
            )
        case .orbitCamera:
            cameraState.rotate(
                deltaX: Float(event.deltaX),
                deltaY: Float(event.deltaY)
            )
        case .moveWindow, .none:
            return
        }
        persistCamera()
    }

    override func scrollWheel(with event: NSEvent) {
        guard !isCameraLocked else {
            super.scrollWheel(with: event)
            return
        }
        cameraState.zoom(delta: Float(event.scrollingDeltaY))
        persistCamera()
    }

    func setCameraLocked(_ locked: Bool) {
        isCameraLocked = locked
        persistCamera()
    }

    func resetCamera() {
        cameraState = .default
        persistCamera()
    }

    private func persistCamera() {
        DesktopPMXCameraSettings.save(
            state: cameraState,
            isLocked: isCameraLocked,
            defaults: cameraDefaults
        )
    }

    static func configureMetalSurface(_ view: MTKView) {
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.clearDepth = 1
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true
        view.wantsLayer = true
        view.layer?.isOpaque = false
    }

    func loadMotion(from url: URL?) throws {
        if let url {
            try avatarRenderer.loadMotion(from: url)
        } else {
            avatarRenderer.clearMotion()
        }
    }

    func loadMotion(from url: URL?) async throws {
        if let url {
            try await avatarRenderer.loadMotion(from: url)
        } else {
            avatarRenderer.clearMotion()
        }
    }

    func draw(in view: MTKView) {
        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let pass = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable
        else {
            return
        }

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = view.clearColor
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = view.clearDepth

        let matrices = DesktopPMXFraming.matrices(
            bounds: avatarRenderer.localBounds,
            drawableSize: view.drawableSize,
            camera: cameraState
        )
        avatarRenderer.encode(
            commandBuffer: commandBuffer,
            renderPassDescriptor: pass,
            viewMatrix: matrices.view,
            projectionMatrix: matrices.projection,
            time: Date.timeIntervalSinceReferenceDate
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

}
