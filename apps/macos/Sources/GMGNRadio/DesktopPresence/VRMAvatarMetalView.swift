import AppKit
@preconcurrency import MetalKit
import os
import simd
import VRMMetalKit

struct DesktopAvatarSelection: Equatable, Sendable {
    let avatar: StageAvatarAsset
    let motion: StageMotionAsset?
    let revision: UInt64

    var snapshot: StageAvatarRuntimeSnapshot {
        StageAvatarRuntimeSnapshot(
            avatar: avatar,
            motion: motion,
            revision: revision
        )
    }
}

struct DesktopAvatarLoadGeneration: Equatable, Sendable {
    let revision: UInt64

    func canCommit(
        currentRevision: UInt64,
        taskIsCancelled: Bool,
        rendererIsAlive: Bool
    ) -> Bool {
        revision == currentRevision
            && !taskIsCancelled
            && rendererIsAlive
    }
}

enum DesktopPresenceKind: Equatable, Sendable {
    case orb
    case vrm
    case pmx
}

enum DesktopPresenceSelection: Equatable, Sendable {
    case orb
    case vrm(DesktopAvatarSelection)
    case pmx(DesktopAvatarSelection)

    static func resolve(
        snapshot: StageAvatarRuntimeSnapshot
    ) -> DesktopPresenceSelection {
        guard let avatar = snapshot.avatar else {
            return .orb
        }
        let selection = DesktopAvatarSelection(
            avatar: avatar,
            motion: snapshot.motion,
            revision: snapshot.revision
        )
        return switch avatar.format {
        case .vrm:
            .vrm(selection)
        case .pmx:
            .pmx(selection)
        }
    }

    var kind: DesktopPresenceKind {
        switch self {
        case .orb:
            .orb
        case .vrm:
            .vrm
        case .pmx:
            .pmx
        }
    }

    var avatarSelection: DesktopAvatarSelection? {
        switch self {
        case .orb:
            nil
        case let .vrm(selection), let .pmx(selection):
            selection
        }
    }

    var preferredSize: CGSize {
        switch self {
        case .orb:
            CGSize(width: 168, height: 168)
        case .vrm, .pmx:
            CGSize(width: 224, height: 288)
        }
    }
}

private enum DesktopVRMAvatarLoadError: LocalizedError {
    case missingAvatar
    case unsupportedFormat(StageAvatarFormat)

    var errorDescription: String? {
        switch self {
        case .missingAvatar:
            "没有可加载的桌面角色模型。"
        case let .unsupportedFormat(format):
            "桌面 VRM 渲染器无法加载 \(format.rawValue.uppercased()) 模型。"
        }
    }
}

@MainActor
final class VRMAvatarMetalView: MTKView {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.gmgn.radio",
        category: "VRMAvatarMetalView"
    )

    private var avatarRenderer: DesktopVRMAvatarRenderer?
    private var loadTask: Task<Void, Never>?

    init(
        frame: CGRect,
        snapshot: StageAvatarRuntimeSnapshot,
        runtime: StageAvatarRuntimeStore
    ) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("gmgn radio requires a Metal-capable Mac")
        }
        super.init(frame: frame, device: device)

        colorPixelFormat = .bgra8Unorm_srgb
        depthStencilPixelFormat = .depth32Float
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        clearDepth = 1
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        autoResizeDrawable = true
        wantsLayer = true
        layer?.isOpaque = false

        let generation = DesktopAvatarLoadGeneration(
            revision: snapshot.revision
        )

        guard let avatar = snapshot.avatar else {
            if generation.canCommit(
                currentRevision: runtime.snapshot.revision,
                taskIsCancelled: false,
                rendererIsAlive: true
            ) {
                runtime.markFailed(DesktopVRMAvatarLoadError.missingAvatar)
            }
            return
        }
        guard avatar.format == .vrm else {
            if generation.canCommit(
                currentRevision: runtime.snapshot.revision,
                taskIsCancelled: false,
                rendererIsAlive: true
            ) {
                runtime.markFailed(
                    DesktopVRMAvatarLoadError.unsupportedFormat(avatar.format)
                )
            }
            return
        }

        do {
            let avatarRenderer = try DesktopVRMAvatarRenderer(
                view: self,
                runtime: runtime
            )
            self.avatarRenderer = avatarRenderer
            delegate = avatarRenderer
            if generation.canCommit(
                currentRevision: runtime.snapshot.revision,
                taskIsCancelled: false,
                rendererIsAlive: true
            ) {
                runtime.markLoading()
            }
            loadTask = Task {
                @MainActor [weak self, weak avatarRenderer, weak runtime] in
                guard let avatarRenderer else { return }
                do {
                    try await avatarRenderer.load(
                        avatar: avatar,
                        motion: snapshot.motion
                    )
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
                        "Unable to load desktop VRM: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        } catch {
            if generation.canCommit(
                currentRevision: runtime.snapshot.revision,
                taskIsCancelled: false,
                rendererIsAlive: true
            ) {
                runtime.markFailed(error)
                Self.log.error(
                    "Unable to create desktop VRM renderer: \(error.localizedDescription, privacy: .public)"
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
            snapshot: selection.snapshot,
            runtime: runtime
        )
    }

    convenience init(
        frame: CGRect,
        modelURL: URL,
        runtime: StageAvatarRuntimeStore
    ) {
        let snapshot = if runtime.snapshot.modelURL == modelURL {
            runtime.snapshot
        } else {
            StageAvatarRuntimeSnapshot(
                modelURL: modelURL,
                name: modelURL.deletingPathExtension().lastPathComponent,
                revision: runtime.snapshot.revision
            )
        }
        self.init(frame: frame, snapshot: snapshot, runtime: runtime)
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
        nil
    }
}

@MainActor
private final class DesktopVRMAvatarRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let runtime: StageAvatarRuntimeStore
    private let clock = ContinuousClock()
    private var previousFrameAt: ContinuousClock.Instant
    private var renderer: VRMRenderer?
    private var model: VRMModel?
    private var animationPlayer: AnimationPlayer?
    private var restRotations: [VRMHumanoidBone: simd_quatf] = [:]
    private var framingCenter = SIMD3<Float>(0, 0.9, 0)
    private var framingHeight: Float = 1.8

    init(
        view: MTKView,
        runtime: StageAvatarRuntimeStore
    ) throws {
        guard
            let device = view.device,
            let commandQueue = device.makeCommandQueue()
        else {
            throw StageRendererError.missingCommandQueue
        }
        self.commandQueue = commandQueue
        self.runtime = runtime
        previousFrameAt = clock.now
        super.init()
    }

    func load(
        avatar: StageAvatarAsset,
        motion: StageMotionAsset?
    ) async throws {
        guard avatar.format == .vrm else {
            throw DesktopVRMAvatarLoadError.unsupportedFormat(avatar.format)
        }
        guard let device = commandQueue.device as MTLDevice? else {
            throw StageRendererError.missingCommandQueue
        }
        let model = try await VRMModel.load(
            from: avatar.modelURL,
            device: device
        )
        guard !Task.isCancelled else { return }

        let renderer = VRMRenderer(
            device: device,
            config: RendererConfig(
                strict: .off,
                colorPixelFormat: .bgra8Unorm_srgb,
                sampleCount: 1
            )
        )
        renderer.outlineWidth = 0.014
        renderer.setLight(
            0,
            direction: SIMD3<Float>(0.28, -0.35, -0.88),
            color: SIMD3<Float>(1, 0.96, 0.92),
            intensity: 1.05
        )
        renderer.setLight(
            1,
            direction: SIMD3<Float>(-0.72, -0.10, -0.45),
            color: SIMD3<Float>(0.28, 0.78, 1),
            intensity: 0.46
        )
        renderer.setLight(
            2,
            direction: SIMD3<Float>(0.16, -0.15, 0.92),
            color: SIMD3<Float>(0.78, 0.38, 1),
            intensity: 0.34
        )
        renderer.setAmbientColor(SIMD3<Float>(0.13, 0.15, 0.19))
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.lookAtController?.enabled = true
        renderer.lookAtController?.target = .camera

        let animationPlayer = try StageAvatarAnimationLoader.makeLoopingPlayer(
            for: motion,
            model: model
        )
        animationPlayer?.lookAtController = renderer.lookAtController

        let bounds = model.modelLocalBounds
        framingCenter = (bounds.min + bounds.max) * 0.5
        framingHeight = max(bounds.max.y - bounds.min.y, 0.5)

        var rotations: [VRMHumanoidBone: simd_quatf] = [:]
        for bone in [
            VRMHumanoidBone.spine,
            .head,
            .leftUpperArm,
            .rightUpperArm,
            .leftLowerArm,
            .rightLowerArm,
        ] {
            if let rotation = model.getLocalRotation(for: bone) {
                rotations[bone] = rotation
            }
        }
        self.model = model
        self.renderer = renderer
        self.animationPlayer = animationPlayer
        restRotations = rotations
    }

    func draw(in view: MTKView) {
        guard
            let renderer,
            let model,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let pass = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable
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
        let motion = StageAvatarMotionFrame.resolve(
            activity: runtime.activity,
            voiceLevel: runtime.voiceLevel,
            time: Date.timeIntervalSinceReferenceDate,
            residentSpeechLevel: runtime.residentSpeechLevel
        )
        animationPlayer?.speed = StageAvatarAnimationPlayback.speed(
            for: runtime.activity
        )
        animationPlayer?.update(
            deltaTime: min(max(delta, 1 / 240), 1 / 20),
            model: model
        )
        apply(
            motion: motion,
            to: model,
            renderer: renderer,
            usesFullBodyAnimation: animationPlayer != nil
        )

        let aspect = max(Float(view.drawableSize.width), 1)
            / max(Float(view.drawableSize.height), 1)
        let fieldOfView: Float = 30 * .pi / 180
        let distanceForHeight = framingHeight
            / (2 * tan(fieldOfView * 0.5))
        let distance = max(distanceForHeight * max(0.72 / aspect, 1), 1.2)
        let liftedCenter = framingCenter + SIMD3<Float>(0, motion.bodyLift, 0)
        renderer.viewMatrix = lookAt(
            eye: liftedCenter + SIMD3<Float>(0, 0.02, distance),
            center: liftedCenter,
            up: SIMD3<Float>(0, 1, 0)
        )
        renderer.projectionMatrix = perspective(
            fieldOfView: fieldOfView,
            aspect: aspect,
            near: 0.01,
            far: max(distance + framingHeight * 3, 10)
        )
        renderer.simulationDeltaTime = TimeInterval(
            min(max(delta, 1 / 240), 1 / 20)
        )
        renderer.draw(
            in: view,
            commandBuffer: commandBuffer,
            renderPassDescriptor: pass
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

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

        if let rest = restRotations[.spine] {
            model.setLocalRotation(
                rest * simd_quatf(
                    angle: motion.spineYaw,
                    axis: SIMD3<Float>(0, 1, 0)
                ),
                for: .spine
            )
        }
        if let rest = restRotations[.head] {
            model.setLocalRotation(
                rest * simd_quatf(
                    angle: motion.headTilt,
                    axis: SIMD3<Float>(0, 0, 1)
                ),
                for: .head
            )
        }
        let rotations: [(VRMHumanoidBone, Float, SIMD3<Float>)] = [
            (.leftUpperArm, motion.leftUpperArmDrop, SIMD3<Float>(0, 0, 1)),
            (.rightUpperArm, motion.rightUpperArmDrop, SIMD3<Float>(0, 0, 1)),
            (.leftLowerArm, motion.leftElbowBend, SIMD3<Float>(0, 1, 0)),
            (.rightLowerArm, motion.rightElbowBend, SIMD3<Float>(0, 1, 0)),
        ]
        for (bone, angle, axis) in rotations {
            guard let rest = restRotations[bone] else { continue }
            model.setLocalRotation(
                rest * simd_quatf(angle: angle, axis: axis),
                for: bone
            )
        }
        model.updateNodeTransforms()
    }

    private func lookAt(
        eye: SIMD3<Float>,
        center: SIMD3<Float>,
        up: SIMD3<Float>
    ) -> simd_float4x4 {
        let forward = normalize(center - eye)
        let side = normalize(cross(forward, up))
        let adjustedUp = cross(side, forward)
        return simd_float4x4(columns: (
            SIMD4(side.x, adjustedUp.x, -forward.x, 0),
            SIMD4(side.y, adjustedUp.y, -forward.y, 0),
            SIMD4(side.z, adjustedUp.z, -forward.z, 0),
            SIMD4(-dot(side, eye), -dot(adjustedUp, eye), dot(forward, eye), 1)
        ))
    }

    private func perspective(
        fieldOfView: Float,
        aspect: Float,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        let tangent = tan(fieldOfView * 0.5)
        return simd_float4x4(columns: (
            SIMD4(1 / (aspect * tangent), 0, 0, 0),
            SIMD4(0, 1 / tangent, 0, 0),
            SIMD4(0, 0, -(far + near) / (far - near), -1),
            SIMD4(0, 0, -(2 * far * near) / (far - near), 0)
        ))
    }
}
