import Foundation
import Observation
import os
import simd
import WorldRuntime

enum SpatialWeather: String, Codable, CaseIterable, Identifiable, Sendable {
    case clear
    case rain
    case thunderstorm

    var id: String { rawValue }
}

enum SpatialScenePreset: String, Codable, CaseIterable, Identifiable,
    Sendable
{
    case djHouse = "dj_house"
    case cosyWoodHouse = "cosy_wood_house"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .djHouse:
            "DJ House"
        case .cosyWoodHouse:
            "Cosy Wood House"
        }
    }

    var worldDisplayName: String {
        "gmgn \(displayName)"
    }

    var subtitle: String {
        switch self {
        case .djHouse:
            "夜景、唱机、音箱与节拍灯光"
        case .cosyWoodHouse:
            "木屋、壁炉、雨窗与黑胶角落"
        }
    }

    var symbolName: String {
        switch self {
        case .djHouse:
            "waveform.path.ecg"
        case .cosyWoodHouse:
            "fireplace.fill"
        }
    }

    var tags: [String] {
        switch self {
        case .djHouse:
            [
                "gmgn-radio",
                "dj-house",
                "image-v3",
                "recording-studio",
            ]
        case .cosyWoodHouse:
            ["gmgn-radio", "cosy-wood-house"]
        }
    }

    var generationModel: String {
        switch self {
        case .djHouse:
            "marble-1.0-draft"
        case .cosyWoodHouse:
            "marble-1.1-plus"
        }
    }

    var imageMediaAssetID: String? {
        switch self {
        case .djHouse:
            // dj-house-source-v3.png, uploaded to the gmgn Marble account.
            "b14767e2-448c-4f61-9c17-b051f3cea509"
        case .cosyWoodHouse:
            nil
        }
    }

    var generationPrompt: String {
        switch self {
        case .djHouse:
            """
            A premium nighttime electronic music recording studio and \
            intimate DJ listening room. Matte black acoustic walls, brushed \
            dark metal, restrained cyan and violet neon accents, a central \
            professional mixing console, studio monitors, synthesizers and \
            turntables. Keep a clear walkable floor, realistic interior \
            scale, cinematic high contrast and warm practical lights. No \
            people, no text, no logos, no floating interface.
            """
        case .cosyWoodHouse:
            """
            A complete explorable cosy wood cabin interior made for listening \
            to records at night. The camera begins at human eye level in a \
            warm timber living room with a built-in fireplace, a physical \
            record player and vinyl shelves, soft sofa, wool rugs, reading \
            lamps and large rain-covered windows looking into a dark pine \
            forest. Keep realistic room scale, connected walking space, rich \
            warm materials and restrained cinematic lighting. No text, no \
            people, no floating interface, no isolated product render.
            """
        }
    }

    static func inferred(worldID: String, name: String) -> SpatialScenePreset {
        let searchable = "\(worldID) \(name)".lowercased()
        if searchable.contains("kitchen")
            || searchable.contains("厨房")
            || searchable.contains("library")
            || searchable.contains("图书馆")
            || searchable.contains("cosy")
            || searchable.contains("cabin")
        {
            return .cosyWoodHouse
        }
        return .djHouse
    }
}

enum SpatialMovement: String, CaseIterable, Hashable, Sendable {
    case forward
    case backward
    case left
    case right
}

enum SpatialCameraCommandDirection: String, Codable, CaseIterable, Sendable {
    case forward
    case backward
    case left
    case right
    case reset
}

enum StageAvatarActivity: String, Equatable, Sendable {
    case idle
    case listening
    case speaking
}

struct StageAvatarMotionFrame: Equatable, Sendable {
    let mouthWeight: Float
    let blinkWeight: Float
    let spineYaw: Float
    let headTilt: Float
    let bodyLift: Float
    let leftUpperArmDrop: Float
    let rightUpperArmDrop: Float
    let leftElbowBend: Float
    let rightElbowBend: Float

    static func resolve(
        activity: StageAvatarActivity,
        voiceLevel: Float,
        time: TimeInterval,
        residentSpeechLevel: Float? = nil
    ) -> StageAvatarMotionFrame {
        let phase = Float(time)
        let voice = min(max(voiceLevel, 0), 1)
        let fallbackSpeech = (sin(phase * 13) + 1) * 0.16
        let mouth = residentSpeechLevel.map { min(max($0 * 1.18, 0), 1) }
            ?? (activity == .speaking
                ? min(max(voice * 1.18, fallbackSpeech), 1)
                : 0)
        let blinkPhase = phase.truncatingRemainder(dividingBy: 4.6)
        let blink = max(0, 1 - abs(blinkPhase - 0.12) / 0.1)
        let motionScale: Float = switch activity {
        case .idle:
            1
        case .listening:
            1.35
        case .speaking:
            1.7
        }

        return StageAvatarMotionFrame(
            mouthWeight: mouth,
            blinkWeight: min(blink, 1),
            spineYaw: sin(phase * 0.72) * 0.018 * motionScale,
            headTilt: sin(phase * 0.51 + 0.7) * 0.026 * motionScale,
            bodyLift: sin(phase * 1.22) * 0.006 * motionScale,
            leftUpperArmDrop: 1.2,
            rightUpperArmDrop: -1.2,
            leftElbowBend: -0.35,
            rightElbowBend: 0.35
        )
    }
}

enum StageAvatarAnimationPlayback {
    static func speed(for activity: StageAvatarActivity) -> Float {
        switch activity {
        case .idle:
            0.65
        case .listening:
            0.52
        case .speaking:
            0.78
        }
    }

}

struct StageAvatarPlacement: Equatable, Sendable {
    let position: SIMD3<Float>
    let scale: Float
    let yaw: Float

    static func forScene(_ scene: SpatialScenePreset) -> StageAvatarPlacement {
        switch scene {
        case .djHouse:
            StageAvatarPlacement(
                position: SIMD3<Float>(-0.72, 0, -0.58),
                scale: 0.82,
                yaw: 0
            )
        case .cosyWoodHouse:
            StageAvatarPlacement(
                position: SIMD3<Float>(0, 0, -0.58),
                scale: 0.78,
                yaw: 0
            )
        }
    }
}

enum SpatialAvatarPositionAxis: String, CaseIterable, Sendable {
    case x = "X"
    case y = "Y"
    case z = "Z"
}

struct SpatialWorldCalibration: Equatable, Sendable {
    let cameraHome: SpatialCameraState
    let avatarPlacement: StageAvatarPlacement?
    let lighting: PMXLightingProfile

    static func resolve(worldID: String?) -> SpatialWorldCalibration? {
        switch worldID {
        case "world-labs-example-warm-kitchen":
            // The original capture camera is the only position guaranteed to
            // be open walking space. Put the avatar on that ground anchor and
            // start the viewing camera diagonally behind it so both face each
            // other without sharing the same physical point.
            SpatialWorldCalibration(
                cameraHome: SpatialCameraState(
                    position: SIMD3<Float>(0, 0.82, 2.05),
                    yaw: 0,
                    pitch: 0
                ),
                avatarPlacement: StageAvatarPlacement(
                    position: SIMD3<Float>(0, 0, 1.1),
                    // Keep the avatar below the cabinets' visual midline and
                    // leave enough headroom for jumping and camera orbiting.
                    scale: 0.45,
                    yaw: 0.67
                ),
                lighting: .warmInterior
            )
        case LivingPodScene.worldID:
            // The pod renders SceneKit primitives in world metres, so its
            // camera and spawn use the same numbers as the authored package
            // (floor top y = 0.12). Camera starts on the open front apron and
            // the avatar at the bundled spawn on the deck.
            SpatialWorldCalibration(
                cameraHome: SpatialCameraState(
                    position: LivingPodScene.presentationCameraPosition,
                    yaw: 0,
                    pitch: 0
                ),
                avatarPlacement: StageAvatarPlacement(
                    position: LivingPodScene.spawnPosition,
                    scale: 1.0,
                    yaw: LivingPodScene.spawnYaw
                ),
                lighting: .warmInterior
            )
        default:
            nil
        }
    }
}

struct SpatialSplatSample: Equatable, Sendable {
    let position: SIMD3<Float>
    let horizontalRadius: Float
    let verticalRadius: Float

    init(
        position: SIMD3<Float>,
        horizontalRadius: Float,
        verticalRadius: Float
    ) {
        self.position = position
        self.horizontalRadius = max(horizontalRadius, 0)
        self.verticalRadius = max(verticalRadius, 0)
    }
}

enum StageAvatarPlacementSolver {
    private static let avatarRadius: Float = 0.22

    static func resolve(
        normalizedPoints: [SIMD3<Float>],
        camera: SpatialCameraState,
        scene: SpatialScenePreset
    ) -> StageAvatarPlacement {
        resolve(
            normalizedSamples: normalizedPoints.map {
                SpatialSplatSample(
                    position: $0,
                    horizontalRadius: 0.01,
                    verticalRadius: 0.01
                )
            },
            camera: camera,
            scene: scene
        )
    }

    static func grounded(
        placement: StageAvatarPlacement,
        normalizedSamples: [SpatialSplatSample]
    ) -> StageAvatarPlacement {
        guard let floorY = floorHeight(
            at: placement.position,
            normalizedSamples: normalizedSamples
        ) else {
            return placement
        }
        return StageAvatarPlacement(
            position: SIMD3<Float>(
                placement.position.x,
                floorY,
                placement.position.z
            ),
            scale: placement.scale,
            yaw: placement.yaw
        )
    }

    static func resolve(
        normalizedSamples: [SpatialSplatSample],
        camera: SpatialCameraState,
        scene: SpatialScenePreset
    ) -> StageAvatarPlacement {
        let fallback = StageAvatarPlacement.forScene(scene)
        guard normalizedSamples.count >= 20 else {
            return fallback
        }
        let xValues = normalizedSamples.map(\.position.x)
        let zValues = normalizedSamples.map(\.position.z)
        guard let minimumX = xValues.min(), let maximumX = xValues.max(),
              let minimumZ = zValues.min(), let maximumZ = zValues.max()
        else {
            return fallback
        }

        let forward = SIMD3<Float>(-sin(camera.yaw), 0, -cos(camera.yaw))
        let right = SIMD3<Float>(cos(camera.yaw), 0, -sin(camera.yaw))
        let lateralOffsets: [Float] = [
            0, -0.18, 0.18, -0.36, 0.36, -0.54, 0.54, -0.72, 0.72,
        ]
        let distances: [Float] = [0.45, 0.6, 0.75, 0.9, 1.05, 1.2, 1.35]
        var best: (score: Float, position: SIMD3<Float>)?

        for distance in distances {
            for lateral in lateralOffsets {
                var position = camera.position
                    + forward * distance
                    + right * lateral
                guard position.x > minimumX + 0.16,
                      position.x < maximumX - 0.16,
                      position.z > minimumZ + 0.16,
                      position.z < maximumZ - 0.16
                else {
                    continue
                }

                let nearbyFloor = normalizedSamples.filter { sample in
                    let dx = sample.position.x - position.x
                    let dz = sample.position.z - position.z
                    let radius = 0.24 + sample.horizontalRadius
                    return dx * dx + dz * dz < radius * radius
                        && sample.position.y - sample.verticalRadius <= 0.14
                        && sample.position.y + sample.verticalRadius >= -0.06
                        && sample.position.y < 0.24
                }
                let floorY = nearbyFloor.map(\.position.y).sorted().dropFirst(
                    nearbyFloor.count / 10
                ).first ?? 0
                position.y = min(max(floorY, 0), 0.14)

                let obstacleCount = normalizedSamples.reduce(into: 0) {
                    count, sample in
                    let dx = sample.position.x - position.x
                    let dz = sample.position.z - position.z
                    let radius = avatarRadius + sample.horizontalRadius
                    let sampleBottom = sample.position.y
                        - sample.verticalRadius
                    let sampleTop = sample.position.y
                        + sample.verticalRadius
                    if dx * dx + dz * dz < radius * radius,
                       sampleTop > position.y + 0.08,
                       sampleBottom < position.y + 1.55
                    {
                        count += 1
                    }
                }
                let targetEye = position + SIMD3<Float>(0, 0.92, 0)
                let sightCount = occlusionCount(
                    samples: normalizedSamples,
                    from: camera.position,
                    to: targetEye
                )
                let supportPenalty: Float = nearbyFloor.count < 2 ? 5_000 : 0
                let score = Float(obstacleCount) * 600
                    + Float(sightCount) * 80
                    + abs(lateral) * 0.6
                    + abs(distance - 0.75) * 1.2
                    + supportPenalty
                if best == nil || score < best!.score {
                    best = (score, position)
                }
            }
        }

        guard let best else {
            return fallback
        }
        let facing = camera.position - best.position
        return StageAvatarPlacement(
            position: best.position,
            scale: fallback.scale,
            yaw: atan2(facing.x, facing.z)
        )
    }

    private static func occlusionCount(
        samples: [SpatialSplatSample],
        from start: SIMD3<Float>,
        to end: SIMD3<Float>
    ) -> Int {
        let segment = end - start
        let lengthSquared = max(simd_length_squared(segment), 0.0001)
        return samples.reduce(into: 0) { count, sample in
            let progress = simd_dot(
                sample.position - start,
                segment
            ) / lengthSquared
            guard progress > 0.12, progress < 0.88 else { return }
            let closest = start + segment * progress
            let visibleRadius = max(
                sample.horizontalRadius,
                sample.verticalRadius
            ) + 0.045
            if simd_distance_squared(sample.position, closest)
                < visibleRadius * visibleRadius
            {
                count += 1
            }
        }
    }

    private static func floorHeight(
        at position: SIMD3<Float>,
        normalizedSamples: [SpatialSplatSample]
    ) -> Float? {
        let nearbyFloor = normalizedSamples.filter { sample in
            let dx = sample.position.x - position.x
            let dz = sample.position.z - position.z
            let radius = 0.24 + sample.horizontalRadius
            return dx * dx + dz * dz < radius * radius
                && sample.position.y - sample.verticalRadius <= 0.18
                && sample.position.y + sample.verticalRadius >= -0.08
                && sample.position.y < 0.28
        }
        guard nearbyFloor.count >= 2 else {
            return nil
        }
        let sortedHeights = nearbyFloor.map(\.position.y).sorted()
        let lowerSurfaceIndex = min(
            sortedHeights.count / 10,
            sortedHeights.count - 1
        )
        return min(max(sortedHeights[lowerSurfaceIndex], -0.08), 0.18)
    }
}

struct SpatialCameraState: Equatable, Sendable {
    static let maximumPitch: Float = 1.35
    static let dragSensitivity: Float = 0.0035
    static let defaultPosition = SIMD3<Float>(0, 0.8, 1.1)
    static let defaultPitch: Float = 0
    static let defaultHome = SpatialCameraState(
        position: defaultPosition,
        yaw: 0,
        pitch: defaultPitch
    )

    var position: SIMD3<Float>
    var yaw: Float
    var pitch: Float

    init(
        position: SIMD3<Float> = Self.defaultPosition,
        yaw: Float = 0,
        pitch: Float = Self.defaultPitch
    ) {
        self.position = position
        self.yaw = yaw
        self.pitch = pitch
    }

    mutating func look(deltaX: Float, deltaY: Float) {
        yaw += WorldCameraInputMapping.yawDelta(
            horizontalDrag: deltaX,
            sensitivity: Self.dragSensitivity
        )
        pitch = min(
            max(
                pitch + WorldCameraInputMapping.pitchDelta(
                    verticalDrag: deltaY,
                    sensitivity: Self.dragSensitivity
                ),
                -Self.maximumPitch
            ),
            Self.maximumPitch
        )
    }

    mutating func move(_ direction: SpatialMovement, distance: Float) {
        let forward = SIMD3<Float>(
            -sin(yaw) * cos(pitch),
            sin(pitch),
            -cos(yaw) * cos(pitch)
        )
        let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        switch direction {
        case .forward:
            position += forward * distance
        case .backward:
            position -= forward * distance
        case .left:
            position -= right * distance
        case .right:
            position += right * distance
        }
    }

    mutating func reset(to home: SpatialCameraState = Self.defaultHome) {
        self = home
    }

    mutating func dolly(scrollDelta: Float, precise: Bool) {
        guard scrollDelta.isFinite else { return }
        // Trackpads report points; ordinary wheels report much smaller steps.
        let metresPerUnit: Float = precise ? 0.01 : 0.2
        let distance = min(max(-scrollDelta * metresPerUnit, -0.5), 0.5)
        move(.forward, distance: distance)
    }
}

struct SpatialEnvironmentState: Equatable, Sendable {
    var weather: SpatialWeather = .clear
    var revision: UInt64 = 0
}

struct MarbleLivingCabinPresentation: Equatable, Sendable {
    let worldID: String
    let camera: SpatialCameraState
    let avatarPlacement: StageAvatarPlacement
    let jukeboxPosition: SIMD3<Float>
    let jukeboxYaw: Float
    let sceneFraming: MarbleSceneFraming
}

@MainActor
@Observable
final class SpatialStageStore {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.gmgn.radio",
        category: "SpatialStageStore"
    )

    var selectedWorldID: String?
    @ObservationIgnored
    var onWorldSelectionChanged: (@MainActor () -> Void)?
    var marbleLivingCabin: MarbleLivingCabinPresentation?
    var wishMachineState: WishMachineScene.State = .idle
    var wishMachineOutput: WishMachineOutputDescriptor?
    var wishMachineOutputStatus: WishMachineOutputStatus = .empty {
        didSet {
            guard wishMachineOutputStatus != oldValue else { return }
            onWishMachineOutputStatusChanged?()
        }
    }
    @ObservationIgnored
    var onWishMachineOutputStatusChanged: (@MainActor () -> Void)?
    var residentPropOutputs: [ResidentPropRenderDescriptor] = []
    var residentPropPreview: ResidentPropRenderDescriptor?
    var residentHeldProp: ResidentHeldPropDescriptor?
    var residentPropDisplayStand: ResidentPropDisplayStand?

    /// 建造模式的格子与着色。由 `ResidentPropGridEditorModel` 提供，这里只做转发，
    /// 让格子与其他道具数据走同一条路：同一帧、同一相机、同一个深度缓冲。
    var residentPropGridCells: [PropSupportGridPresentation.Cell] = []
    var residentPropGridStates: [PropSupportGridPresentation.Cell: PropSupportGridPresentation.CellState] = [:]
    var residentPropGridSpacing: Float = 0
    /// 当前落点**放不下**的原因，由 `ResidentPropGridEditorModel.hoveredBlockReason` 原样转发
    /// （nil = 能放）。与上面的格子/着色同一处转发、同一个时机。
    ///
    /// 消费者只有一个：场景里跟随光标的"为什么不能放"标签
    /// （`StageWorldInteractionView.drawBlockReasonLabel`）。这里**不拼文案**，也不做取舍 ——
    /// 文案由 `PropSupportBlockReason.errorDescription` 投影，与面板那行 `notice` 是同一份。
    var residentPropBlockReason: PropSupportBlockReason?
    var isResidentPropBuildModeActive = false
    var residentPropRenderStatuses: [String: WishMachineOutputStatus] = [:]
    @ObservationIgnored var residentPropPrepareHandler: (@MainActor (ResidentPropRenderDescriptor) async throws -> ResidentPropPreparedAsset)?
    @ObservationIgnored var residentPropPreparedHandler: (@MainActor (String, URL, String) -> Bool)?
    @ObservationIgnored var residentPropAttachmentValidationHandler: (@MainActor (String, PropAttachmentPoint) throws -> Void)?
    @ObservationIgnored var residentPropClearHandler: (@MainActor () -> Void)?
    @ObservationIgnored var residentPropActiveHandler: (@MainActor () -> Bool)?
    @ObservationIgnored var residentPropViewProjection: simd_float4x4?
    @ObservationIgnored let residentPropRenderOwnership = ResidentPropRenderOwnership()

    func releaseResidentPropRenderer(_ owner: ResidentPropRenderOwner) {
        guard residentPropRenderOwnership.release(owner: owner) else { return }
        clearResidentPropRendererHooks()
    }

    private func clearResidentPropRendererHooks() {
        residentPropClearHandler?()
        residentPropClearHandler = nil
        residentPropActiveHandler = nil
        residentPropPrepareHandler = nil
        residentPropPreparedHandler = nil
        residentPropAttachmentValidationHandler = nil
        residentPropViewProjection = nil
        residentPropRenderStatuses = [:]
    }

    /// Explicit readiness for launch-time recovery: the visible world renderer
    /// publishes its handlers on the first eligible draw, which races app
    /// startup. Callers defer while this is false instead of reporting a
    /// claimed prop as an asset failure. The query touches no task, ownership
    /// or model record.
    func canPrepareResidentProp(worldID: String) -> Bool {
        ResidentPropStartupRecovery.canPrepare(
            isWorldVisible: isWorldVisible,
            hasActiveRenderer: residentPropActiveHandler?() == true,
            selectedWorldID: selectedWorldID,
            descriptorWorldID: worldID,
            hasPrepareHandler: residentPropPrepareHandler != nil
        )
    }

    func prepareResidentProp(_ descriptor: ResidentPropRenderDescriptor) async throws -> ResidentPropPreparedAsset {
        guard canPrepareResidentProp(worldID: descriptor.worldID), let residentPropPrepareHandler else { throw WishMachineOutputError.renderUnavailable }
        let result = try await residentPropPrepareHandler(descriptor)
        guard canPrepareResidentProp(worldID: descriptor.worldID) else { throw CancellationError() }
        return result
    }

    func isResidentPropPrepared(assetID: String, modelURL: URL) -> Bool {
        guard isWorldVisible, residentPropActiveHandler?() == true, let selectedWorldID else { return false }
        return residentPropPreparedHandler?(assetID, modelURL, selectedWorldID) ?? false
    }

    func validateResidentPropAttachment(
        avatarID: String,
        assetID: String,
        modelURL: URL,
        point: PropAttachmentPoint
    ) throws {
        // 这一层的每一条判据都**自己说自己是哪一条**（`PropAttachmentError` 里各有 case），
        // 并且每一次拒绝都落统一日志。原来这四条塌成 `.assetNotPrepared` 一句话，
        // 真机上"剑挂不到背后"因此既没有日志、也给不出任何可行动的线索。
        guard isWorldVisible else {
            Self.log.notice("挂点拒绝：空间不可见 world=\(self.selectedWorldID ?? "nil", privacy: .public) 挂点=\(PropAttachmentSlots.displayName(for: point), privacy: .public) asset=\(assetID, privacy: .public)")
            throw PropAttachmentError.worldNotVisible(worldID: selectedWorldID)
        }
        guard residentPropActiveHandler?() == true, let selectedWorldID else {
            Self.log.notice("挂点拒绝：渲染器未接管 world=\(self.selectedWorldID ?? "nil", privacy: .public) 挂点=\(PropAttachmentSlots.displayName(for: point), privacy: .public)")
            throw PropAttachmentError.rendererNotActive(worldID: selectedWorldID)
        }
        guard residentPropPreparedHandler?(assetID, modelURL, selectedWorldID) == true else {
            Self.log.notice("挂点拒绝：资产未备好 world=\(selectedWorldID, privacy: .public) asset=\(assetID, privacy: .public) url=\(modelURL.lastPathComponent, privacy: .public) 挂点=\(PropAttachmentSlots.displayName(for: point), privacy: .public)")
            throw PropAttachmentError.assetNotRenderable(assetID: assetID)
        }
        guard avatarID == ResidentPropAttachmentEligibility.supportedAvatarID else {
            Self.log.notice("挂点拒绝：角色未适配 avatarID=\(avatarID, privacy: .public) 受支持=\(ResidentPropAttachmentEligibility.supportedAvatarID, privacy: .public)")
            throw PropAttachmentError.unsupportedAvatar
        }
        guard let residentPropAttachmentValidationHandler else {
            Self.log.notice("挂点拒绝：挂点检查未接线 world=\(selectedWorldID, privacy: .public) 挂点=\(PropAttachmentSlots.displayName(for: point), privacy: .public)")
            throw PropAttachmentError.validationHandlerUnavailable
        }
        try residentPropAttachmentValidationHandler(avatarID, point)
    }

    /// Normalized viewport point uses top-left origin, independent of backing pixels.
    func residentPropPoint(normalizedPoint: SIMD2<Float>, surfaceY: Float) -> SIMD3<Float>? {
        guard isWorldVisible, residentPropActiveHandler?() == true, let residentPropViewProjection else { return nil }
        return ResidentPropProjection.point(normalized: normalizedPoint, surfaceY: surfaceY, inverseViewProjection: simd_inverse(residentPropViewProjection))
    }

    /// 建造模式拾取所需的逆视图投影与格距。
    ///
    /// 与 `residentPropPoint` 同一套约定（归一化、左上原点、`0...1`）。没开建造模式、或还没有
    /// 投影矩阵时返回 nil —— 这样普通游玩时的鼠标移动不会误触发格子拾取。
    var residentPropBuildModeProjection: (inverseViewProjection: simd_float4x4, spacing: Float)? {
        guard isWorldVisible, isResidentPropBuildModeActive,
              residentPropGridSpacing > 0, let residentPropViewProjection else { return nil }
        return (simd_inverse(residentPropViewProjection), residentPropGridSpacing)
    }

    /// 本帧要画的格子实例。
    ///
    /// 走 `focusedInstances`：**只画当前 footprint（或空手时的光标格）周围一小块**
    /// —— 本体按状态着色全对比，外扩两圈压到 `Focus.ringAlpha`，更远的格子在这里就
    /// 不生成实例（The Sims 的做法）。没有锚点时不画，不再铺满整个地面。
    /// 距离裁剪、淡出与预算仍然都在 `PropSupportGridPresentation` 里；这里只做
    /// "没开建造模式就不画"的判断。
    func residentPropGridInstances(cameraPosition: SIMD3<Float>) -> [PropSupportGridPresentation.Instance] {
        guard isResidentPropBuildModeActive, !residentPropGridCells.isEmpty else { return [] }
        return PropSupportGridPresentation.focusedInstances(
            cells: residentPropGridCells,
            states: residentPropGridStates,
            cameraPosition: cameraPosition,
            spacing: residentPropGridSpacing
        )
    }

    func residentPropScreenPoint(world: SIMD3<Float>) -> SIMD2<Float>? {
        guard isWorldVisible, residentPropActiveHandler?() == true, let residentPropViewProjection else { return nil }
        let clip = residentPropViewProjection * SIMD4(world, 1)
        guard clip.w > 0.000001 else { return nil }
        return SIMD2((clip.x/clip.w+1)/2, (1-clip.y/clip.w)/2)
    }
    private(set) var selectedScene: SpatialScenePreset = .djHouse
    var camera = SpatialCameraState()
    /// Avatar-follow rotation state (see AvatarFollowYawDigester). Living-world
    /// snapshots arrive near 30 Hz and enqueue whole-step yaw deltas here; each
    /// rendered frame then advances the shared camera through them, so the
    /// world never turns in 30 Hz jumps. The store is the only writer of the
    /// camera, which lets user drags/resets cancel the queue at the exact
    /// moment of the interaction.
    private(set) var isAvatarFollowActive = false
    private var avatarFollowYawDigester = AvatarFollowYawDigester()
    private var lastCameraYawInteractionAt = ContinuousClock.now.advanced(
        by: .seconds(-(AvatarFollowUserPolicy.suppressionInterval + 1))
    )
    private(set) var isWorldPresentationRequested = false
    private(set) var isWorldVisible = false
    var isSpeedBoosted = false
    private(set) var environment = SpatialEnvironmentState()
    private(set) var sceneFraming: MarbleSceneFraming?
    private(set) var sceneOccluderTriangles: [WorldTriangle] = []
    private(set) var sceneOccluderRevision: UInt64 = 0
    private(set) var avatarPlacement = StageAvatarPlacement.forScene(.djHouse)
    private var baseAvatarPlacement = StageAvatarPlacement.forScene(.djHouse)
    private var stableAvatarPlacement = StageAvatarPlacement.forScene(.djHouse)
    private var transientAvatarPlacement: StageAvatarPlacement?
    private var cameraHome = SpatialCameraState.defaultHome
    private var calibratedWorldID: String?
    private var activeMovement: Set<SpatialMovement> = []
    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private var worldVisibilityObservers: [UUID: (Bool) -> Void] = [:]
    @ObservationIgnored
    private var sceneFramingObservers: [UUID: (MarbleSceneFraming) -> Void] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var shouldRenderEnvironmentEffects: Bool {
        isWorldVisible
            && environment.weather != .clear
    }

    func selectWorld(id: String?) {
        let changedWorld = selectedWorldID != id
        selectedWorldID = id
        if changedWorld {
            residentPropRenderOwnership.invalidate()
            clearResidentPropRendererHooks()
            residentPropPreview = nil
            residentHeldProp = nil
            residentPropDisplayStand = nil
            residentPropOutputs = []
            residentPropRenderStatuses = [:]
            residentPropViewProjection = nil
            onWorldSelectionChanged?()
            clearSceneOccluderTriangles()
        }
        if changedWorld, calibratedWorldID != id {
            cameraHome = .defaultHome
            installBaseAvatarPlacement(
                StageAvatarPlacement.forScene(selectedScene)
            )
        }
        camera.reset(to: cameraHome)
        cancelAvatarFollowRotation()
    }

    func selectScene(_ scene: SpatialScenePreset) {
        if selectedScene != scene {
            selectedScene = scene
            cameraHome = .defaultHome
            calibratedWorldID = nil
            installBaseAvatarPlacement(StageAvatarPlacement.forScene(scene))
        } else {
            selectedScene = scene
        }
        camera.reset(to: cameraHome)
        cancelAvatarFollowRotation()
    }

    func installCameraHome(_ home: SpatialCameraState) {
        cameraHome = home
        calibratedWorldID = selectedWorldID
        camera.reset(to: home)
        cancelAvatarFollowRotation()
    }

    func installSceneFraming(_ framing: MarbleSceneFraming) {
        sceneFraming = framing
        sceneFramingObservers.values.forEach { $0(framing) }
    }

    func installSceneOccluderTriangles(_ triangles: [WorldTriangle]) {
        sceneOccluderTriangles = triangles
        sceneOccluderRevision &+= 1
    }

    private func clearSceneOccluderTriangles() {
        guard !sceneOccluderTriangles.isEmpty else { return }
        sceneOccluderTriangles.removeAll(keepingCapacity: false)
        sceneOccluderRevision &+= 1
    }

    func observeSceneFraming(
        _ observer: @escaping (MarbleSceneFraming) -> Void
    ) -> UUID {
        let id = UUID()
        sceneFramingObservers[id] = observer
        if let sceneFraming { observer(sceneFraming) }
        return id
    }

    func removeSceneFramingObserver(_ id: UUID?) {
        guard let id else { return }
        sceneFramingObservers.removeValue(forKey: id)
    }

    func installAvatarPlacement(_ placement: StageAvatarPlacement) {
        installBaseAvatarPlacement(placement)
    }

    func setAvatarPosition(
        _ value: Float,
        axis: SpatialAvatarPositionAxis
    ) {
        guard value.isFinite else { return }
        var position = stableAvatarPlacement.position
        switch axis {
        case .x:
            position.x = value
        case .y:
            position.y = value
        case .z:
            position.z = value
        }
        stableAvatarPlacement = StageAvatarPlacement(
            position: position,
            scale: stableAvatarPlacement.scale,
            yaw: stableAvatarPlacement.yaw
        )
        if transientAvatarPlacement == nil {
            avatarPlacement = stableAvatarPlacement
        }
        defaults.set(
            [Double(position.x), Double(position.y), Double(position.z)],
            forKey: avatarPositionStorageKey
        )
    }

    func resetAvatarPosition() {
        defaults.removeObject(forKey: avatarPositionStorageKey)
        stableAvatarPlacement = baseAvatarPlacement
        if transientAvatarPlacement == nil {
            avatarPlacement = stableAvatarPlacement
        }
    }

    /// Applies a world-space offset from the user's calibrated spawn for the
    /// current tick. It is memory-only; clearing it restores that saved spawn.
    func setTransientAvatarPlacement(_ placement: StageAvatarPlacement) {
        transientAvatarPlacement = placement
        applyTransientAvatarPlacement()
    }

    /// Applies deterministic world movement over the authored scene anchor.
    /// Saved manual XYZ offsets belong to the user's placement mode and must
    /// not move navigation waypoints or push the avatar outside the world.
    func setWorldAvatarPlacement(_ placement: StageAvatarPlacement) {
        transientAvatarPlacement = placement
        avatarPlacement = StageAvatarPlacement(
            position: SIMD3<Float>(
                baseAvatarPlacement.position.x + placement.position.x,
                baseAvatarPlacement.position.y + placement.position.y,
                baseAvatarPlacement.position.z + placement.position.z
            ),
            scale: baseAvatarPlacement.scale,
            yaw: baseAvatarPlacement.yaw + placement.yaw
        )
    }

    func clearTransientAvatarPlacement() {
        transientAvatarPlacement = nil
        avatarPlacement = stableAvatarPlacement
    }

    private func installBaseAvatarPlacement(
        _ placement: StageAvatarPlacement
    ) {
        baseAvatarPlacement = placement
        stableAvatarPlacement = StageAvatarPlacement(
            position: storedAvatarPosition() ?? placement.position,
            scale: placement.scale,
            yaw: placement.yaw
        )
        if transientAvatarPlacement == nil {
            avatarPlacement = stableAvatarPlacement
        } else {
            applyTransientAvatarPlacement()
        }
    }

    /// Composes gameplay movement over the calibrated/user-authored spawn.
    /// Avatar size remains owned by the loaded world's visual calibration.
    private func applyTransientAvatarPlacement() {
        guard let transientAvatarPlacement else { return }
        avatarPlacement = StageAvatarPlacement(
            position: SIMD3<Float>(
                stableAvatarPlacement.position.x
                    + transientAvatarPlacement.position.x,
                stableAvatarPlacement.position.y
                    + transientAvatarPlacement.position.y,
                stableAvatarPlacement.position.z
                    + transientAvatarPlacement.position.z
            ),
            scale: stableAvatarPlacement.scale,
            yaw: stableAvatarPlacement.yaw + transientAvatarPlacement.yaw
        )
    }

    private var avatarPositionStorageKey: String {
        let scope = if let selectedWorldID {
            "world.\(selectedWorldID)"
        } else {
            "scene.\(selectedScene.rawValue)"
        }
        return "ai.gmgn.radio.spatial.avatar-position.\(scope)"
    }

    private func storedAvatarPosition() -> SIMD3<Float>? {
        guard let values = defaults.array(forKey: avatarPositionStorageKey),
              values.count == 3
        else {
            return nil
        }
        let numbers = values.compactMap { ($0 as? NSNumber)?.floatValue }
        guard numbers.count == 3,
              numbers.allSatisfy(\.isFinite)
        else {
            return nil
        }
        return SIMD3<Float>(numbers[0], numbers[1], numbers[2])
    }

    func setWorldVisible(_ visible: Bool) {
        if visible {
            requestWorldPresentation()
            finishWorldPresentation()
        } else {
            exitWorld()
        }
    }

    func requestWorldPresentation() {
        isWorldPresentationRequested = true
        updateWorldVisibility(false)
        clearMovement()
        Self.log.notice(
            "World presentation requested world=\(self.selectedWorldID ?? "nil", privacy: .public)"
        )
    }

    func finishWorldPresentation() {
        guard isWorldPresentationRequested else {
            Self.log.notice("Ignored world presentation finish without request")
            return
        }
        guard !isWorldVisible else {
            Self.log.notice("Ignored duplicate world presentation finish")
            return
        }
        updateWorldVisibility(true)
        Self.log.notice(
            "World presentation visible world=\(self.selectedWorldID ?? "nil", privacy: .public)"
        )
    }

    func exitWorld() {
        isWorldPresentationRequested = false
        updateWorldVisibility(false)
        clearMovement()
        isSpeedBoosted = false
        Self.log.notice(
            "World presentation exited world=\(self.selectedWorldID ?? "nil", privacy: .public)"
        )
    }

    func observeWorldVisibility(
        _ observer: @escaping (Bool) -> Void
    ) -> UUID {
        let id = UUID()
        worldVisibilityObservers[id] = observer
        observer(isWorldVisible)
        return id
    }

    func removeWorldVisibilityObserver(_ id: UUID?) {
        guard let id else { return }
        worldVisibilityObservers[id] = nil
    }

    private func updateWorldVisibility(_ visible: Bool) {
        isWorldVisible = visible
        if !visible {
            residentPropRenderOwnership.invalidate()
            clearResidentPropRendererHooks()
            residentPropPreview = nil
        }
        for observer in worldVisibilityObservers.values {
            // A prior observer may synchronously finish or exit the world.
            // Its nested notification has already delivered the newer state.
            guard isWorldVisible == visible else { break }
            observer(visible)
        }
    }

    func setSpeedBoosted(_ boosted: Bool) {
        isSpeedBoosted = boosted
    }

    func setMovement(_ movement: SpatialMovement, active: Bool) {
        if active {
            activeMovement.insert(movement)
        } else {
            activeMovement.remove(movement)
        }
    }

    func clearMovement() {
        activeMovement.removeAll()
    }

    func look(deltaX: Float, deltaY: Float) {
        camera.look(deltaX: deltaX, deltaY: deltaY)
        noteCameraYawInteraction()
    }

    func move(_ direction: SpatialMovement, distance: Float) {
        camera.move(direction, distance: min(max(distance, 0.5), 10))
    }

    @ObservationIgnored private var cameraScrollInputCount = 0
    @ObservationIgnored private var cameraScrollInvalidTimestampCount = 0
    @ObservationIgnored private var cameraScrollDispatchMilliseconds: [Double] = []

    /// OS event timestamp to main-thread handling only; not input-to-display latency.
    var cameraInputDiagnostics: [String: Any] {
        let samples = cameraScrollDispatchMilliseconds.sorted()
        var result: [String: Any] = [
            "scrollInputCount": cameraScrollInputCount,
            "invalidOrMissingTimestampCount": cameraScrollInvalidTimestampCount,
            "sampleCount": samples.count,
            "sampleCapacity": 120,
            "latencyScope": "os-event-to-main-thread-handler"
        ]
        if !samples.isEmpty {
            func percentile(_ fraction: Double) -> Double {
                samples[max(0, Int(ceil(Double(samples.count) * fraction)) - 1)]
            }
            result["dispatchLatencyP50Milliseconds"] = percentile(0.50)
            result["dispatchLatencyP95Milliseconds"] = percentile(0.95)
            result["dispatchLatencyMaxMilliseconds"] = samples.last!
        }
        return result
    }

    func dollyCamera(scrollDelta: Float, precise: Bool, eventTimestamp: TimeInterval? = nil) {
        cameraScrollInputCount += 1
        let uptime = ProcessInfo.processInfo.systemUptime
        if let eventTimestamp, eventTimestamp.isFinite, eventTimestamp > 0,
           uptime.isFinite, eventTimestamp <= uptime {
            let milliseconds = max(0, (uptime - eventTimestamp) * 1_000)
            if milliseconds.isFinite {
                cameraScrollDispatchMilliseconds.append(milliseconds)
                if cameraScrollDispatchMilliseconds.count > 120 {
                    cameraScrollDispatchMilliseconds.removeFirst()
                }
            } else {
                cameraScrollInvalidTimestampCount += 1
            }
        } else {
            cameraScrollInvalidTimestampCount += 1
        }
        camera.dolly(scrollDelta: scrollDelta, precise: precise)
    }

    func resetCamera() {
        camera.reset(to: cameraHome)
        noteCameraYawInteraction()
    }

    // MARK: - Avatar follow rotation (queued at ~30 Hz, digested per frame)

    var pendingAvatarFollowYaw: Float {
        avatarFollowYawDigester.pending
    }

    /// Seconds since the user last drove the camera directly (orbit drag or
    /// reset). The camera coordinator uses this to suppress follow rotation
    /// while the user is still interacting.
    var timeSinceLastCameraYawInteraction: TimeInterval {
        Self.durationSeconds(ContinuousClock.now - lastCameraYawInteractionAt)
    }

    /// Enables or disables queued avatar-follow rotation. The full-stage camera
    /// coordinator turns this on when it takes ownership and off when Live Cam
    /// (or another owner) takes over, so follow rotation can never leak into a
    /// view the follow does not own.
    func setAvatarFollowActive(_ active: Bool) {
        isAvatarFollowActive = active
        avatarFollowYawDigester.cancel()
        if active {
            // A fresh full-stage session starts with follow ready to run: a
            // look that happened while another owner held the camera must not
            // suppress the new session's follow.
            lastCameraYawInteractionAt = ContinuousClock.now.advanced(
                by: .seconds(-(AvatarFollowUserPolicy.suppressionInterval + 1))
            )
        }
    }

    /// Queues one snapshot-cadence follow yaw delta (from the camera
    /// coordinator). Ignored unless the full stage is following.
    func enqueueAvatarFollowYaw(_ delta: Float) {
        guard isAvatarFollowActive else { return }
        avatarFollowYawDigester.enqueue(delta)
    }

    /// Digests queued follow yaw at render cadence. The renderer calls this on
    /// every drawn frame, before any view matrix reads the camera, and applies
    /// the returned rotation to the shared camera so every pass of the frame
    /// (world, occluder, avatar, props) stays on one consistent view.
    @discardableResult
    func advanceAvatarFollowRotation(deltaTime: Float) -> Float {
        guard isAvatarFollowActive else { return 0 }
        let applied = avatarFollowYawDigester.advance(deltaTime: deltaTime)
        if applied != 0 {
            camera.yaw += applied
        }
        return applied
    }

    /// Records a direct user camera interaction (orbit drag or reset) and
    /// cancels any queued follow rotation so it cannot fight the user or apply
    /// late after the interaction. `at` exists for deterministic tests.
    func noteCameraYawInteraction(at time: ContinuousClock.Instant = ContinuousClock.now) {
        lastCameraYawInteractionAt = time
        avatarFollowYawDigester.cancel()
    }

    /// Drops queued follow rotation without suppressing future follow. Used
    /// when the whole camera is replaced (world/scene/home switches) so a
    /// backlog computed against the previous view cannot rotate the new one.
    func cancelAvatarFollowRotation() {
        avatarFollowYawDigester.cancel()
    }

    private static func durationSeconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    func applyCameraCommand(
        _ direction: SpatialCameraCommandDirection,
        distance: Float
    ) {
        switch direction {
        case .forward:
            move(.forward, distance: distance)
        case .backward:
            move(.backward, distance: distance)
        case .left:
            move(.left, distance: distance)
        case .right:
            move(.right, distance: distance)
        case .reset:
            resetCamera()
        }
    }

    func stepCamera(deltaTime: Float, speedBoosted: Bool) {
        let delta = min(max(deltaTime, 0), 0.1)
        let speed: Float = speedBoosted ? 6 : 2.5
        for movement in activeMovement {
            camera.move(movement, distance: speed * delta)
        }
    }

    func applyEnvironment(
        weather: SpatialWeather? = nil
    ) {
        if let weather {
            environment.weather = weather
        }
        environment.revision &+= 1
    }
}

/// Pure launch-recovery decision for claimed resident props, kept free of
/// Metal/AppKit so tools/test-resident-prop-startup.swift can compile and
/// exercise it. The world renderer installs its handlers on the first eligible
/// draw, which races app startup; recovery defers that window silently and
/// lets the existing refreshWishMachine cycle retry once handlers exist.
enum ResidentPropStartupRecovery {
    enum Action: Equatable {
        case prepare
        case deferUntilRendererReady
        case ignoreRendererLoss
        case report(String)
    }

    static func canPrepare(
        isWorldVisible: Bool,
        hasActiveRenderer: Bool,
        selectedWorldID: String?,
        descriptorWorldID: String,
        hasPrepareHandler: Bool
    ) -> Bool {
        isWorldVisible && hasActiveRenderer && selectedWorldID == descriptorWorldID && hasPrepareHandler
    }

    static func action(rendererReady: Bool, error: Error?) -> Action {
        guard let error else {
            return rendererReady ? .prepare : .deferUntilRendererReady
        }
        if error is CancellationError { return .ignoreRendererLoss }
        if let renderError = error as? WishMachineOutputError, case .renderUnavailable = renderError, !rendererReady {
            return .ignoreRendererLoss
        }
        return .report(error.localizedDescription)
    }
}
