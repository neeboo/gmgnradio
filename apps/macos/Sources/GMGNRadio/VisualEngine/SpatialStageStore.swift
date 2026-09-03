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
        time: TimeInterval
    ) -> StageAvatarMotionFrame {
        let phase = Float(time)
        let voice = min(max(voiceLevel, 0), 1)
        let fallbackSpeech = (sin(phase * 13) + 1) * 0.16
        let mouth = activity == .speaking
            ? min(max(voice * 1.18, fallbackSpeech), 1)
            : 0
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
        let forward = SIMD3<Float>(-sin(yaw), 0, -cos(yaw))
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
}

struct SpatialEnvironmentState: Equatable, Sendable {
    var weather: SpatialWeather = .clear
    var revision: UInt64 = 0
}

@MainActor
@Observable
final class SpatialStageStore {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.gmgn.radio",
        category: "SpatialStageStore"
    )

    var selectedWorldID: String?
    private(set) var selectedScene: SpatialScenePreset = .djHouse
    var camera = SpatialCameraState()
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
            clearSceneOccluderTriangles()
        }
        if changedWorld, calibratedWorldID != id {
            cameraHome = .defaultHome
            installBaseAvatarPlacement(
                StageAvatarPlacement.forScene(selectedScene)
            )
        }
        camera.reset(to: cameraHome)
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
    }

    func installCameraHome(_ home: SpatialCameraState) {
        cameraHome = home
        calibratedWorldID = selectedWorldID
        camera.reset(to: home)
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
        for observer in worldVisibilityObservers.values {
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
    }

    func move(_ direction: SpatialMovement, distance: Float) {
        camera.move(direction, distance: min(max(distance, 0.5), 10))
    }

    func resetCamera() {
        camera.reset(to: cameraHome)
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
