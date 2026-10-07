import Foundation
import WorldRuntime
import os

/// The generated mesh supplies the floor; independent furniture only blocks.
struct MarbleLivingCabinCollisionWorld: WorldCollisionQuerying {
    let environment: any WorldCollisionQuerying
    let props: CollisionVolumeWorld

    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool {
        environment.canOccupy(capsule, at: position) && props.canOccupy(capsule, at: position)
    }

    func groundHeight(at position: SIMD3<Float>) -> Float? {
        environment.groundHeight(at: position)
    }
}

/// 摆放格子派生需要三角形几何，而这个组合类型只承诺 `any WorldCollisionQuerying`。
/// 三角形来自 `environment`（生成舱体的网格）；`props` 是独立的阻挡体积，没有三角形。
///
/// 拿不到几何时返回**空数组**是有意为之，而且**不是 fail-open**：
/// - `PropSupportGridBuilder.build` 先用 `triangles(in:)` 算 Y 范围，范围里没有可用几何时
///   它返回**空网格**（注释原文"不猜、不放行"）；
/// - `PropPlacementEvaluator.evaluate` 里局部三角形为空 → `.noSupport`（第二道闸）。
/// 所以"拿不到几何"的结果是**不能摆放**，不是处处可放。
extension MarbleLivingCabinCollisionWorld: WorldPropSupportQuerying {
    func triangles(in bounds: WorldPlanarBounds) -> [WorldTriangle] {
        (environment as? any WorldPropSupportQuerying)?.triangles(in: bounds) ?? []
    }
}

/// An effect is keyed by the execution instance, not the 30 Hz frame.
struct LivingCabinJukeboxGate {
    private var lastInstance: String?

    mutating func consume(
        worldID: String, activityID: String, startedAt: Date, phase: String,
        requestID: String? = nil
    ) -> Bool {
        guard activityID == "music.listen", phase == "enter" || phase == "loop" else {
            return false
        }
        let instance = "\(worldID):\(requestID ?? String(startedAt.timeIntervalSince1970))"
        guard instance != lastInstance else { return false }
        lastInstance = instance
        return true
    }
}

struct BundledLivingWorldPackage: Sendable {
    let manifest: WorldManifest
    let packageRoot: URL
}

struct MarbleLivingCabinDocument: Decodable {
    struct Vector: Decodable {
        let value: SIMD3<Float>
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let components = try container.decode([Float].self)
            guard components.count == 3, components.allSatisfy(\.isFinite) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected three finite coordinates")
            }
            value = SIMD3(components[0], components[1], components[2])
        }
    }
    struct Framing: Decodable {
        let origin: Vector
        let scale: Float
        let minimum: Vector
        let maximum: Vector
        enum CodingKeys: String, CodingKey { case origin, scale, minimum, maximum }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            origin = try c.decode(Vector.self, forKey: .origin)
            scale = try c.decode(Float.self, forKey: .scale)
            minimum = try c.decode(Vector.self, forKey: .minimum)
            maximum = try c.decode(Vector.self, forKey: .maximum)
            guard scale.isFinite, scale > 0,
                  minimum.value.x < maximum.value.x,
                  minimum.value.y < maximum.value.y,
                  minimum.value.z < maximum.value.z else {
                throw DecodingError.dataCorruptedError(forKey: .scale, in: c, debugDescription: "Invalid scene dimensions")
            }
        }
    }
    struct Camera: Decodable {
        let position: Vector
        let yaw: Float
        let pitch: Float
    }
    struct Jukebox: Decodable {
        let position: Vector
        let yaw: Float
    }
    let world: MarbleWorld
    let framing: Framing
    let camera: Camera
    let jukebox: Jukebox
}

struct BundledMarbleLivingCabin {
    let world: MarbleWorld
    let presentation: MarbleLivingCabinPresentation
    let splatURL: URL
    let colliderURL: URL
}

/// The adopted cabin's tray-only 1.2 upgrade preserves the 1.1 history.
/// Reads may fall back once; every checkpoint writes the versioned 1.2 file.
/// An existing broken 1.2 file must surface its error, never resurrect 1.1.
struct LivingCabinVersion12Persistence: WorldStatePersisting {
    /// **private**：迁移后这两个文件写入口不再对外暴露（`save` 只会被
    /// `LegacyWorldStatePreImage` 的只读包装读到，见 `makeContext`）。
    private let current: AtomicJSONWorldStatePersistence
    private let previous: AtomicJSONWorldStatePersistence

    init(current: AtomicJSONWorldStatePersistence, previous: AtomicJSONWorldStatePersistence) {
        self.current = current
        self.previous = previous
    }

    func load() throws -> WorldState? {
        if FileManager.default.fileExists(atPath: current.fileURL.path) {
            return try current.load()
        }
        return try previous.load()
    }

    func save(_ state: WorldState) throws {
        try current.save(state)
    }
}

enum LivingWorldBootstrapError: LocalizedError {
    case bundledCanaryMissing
    case invalidPackage([WorldPackageError])
    case invalidMotionResource(id: String, kind: String, path: String)
    case invalidMarbleCabin(String)

    /// 界面只留**一句人话**；校验明细、资源 id/kind/path、舱体失败原话全部进日志。
    static let diagnosticLog = Logger(subsystem: "ai.gmgn.radio", category: "LivingWorldBootstrap")

    static func badPackage(_ findings: [WorldPackageError]) -> LivingWorldBootstrapError {
        diagnosticLog.error(
            "生活舱包校验失败：\(findings.map(String.init(describing:)).joined(separator: " | "), privacy: .public)"
        )
        return .invalidPackage(findings)
    }

    static func badMotionResource(id: String, kind: String, path: String) -> LivingWorldBootstrapError {
        diagnosticLog.error(
            "动作资源不匹配：id=\(id, privacy: .public) kind=\(kind, privacy: .public) path=\(path, privacy: .public)"
        )
        return .invalidMotionResource(id: id, kind: kind, path: path)
    }

    static func badCabin(_ message: String) -> LivingWorldBootstrapError {
        diagnosticLog.error("生活舱加载失败：\(message, privacy: .public)")
        return .invalidMarbleCabin(message)
    }

    var errorDescription: String? {
        switch self {
        case .bundledCanaryMissing:
            "没找到生活舱空间，请重新安装应用。"
        case .invalidPackage:
            "生活舱空间不完整，请重新安装应用。"
        case .invalidMotionResource:
            "动作资源读不了，请重新安装应用。"
        case .invalidMarbleCabin:
            "生活舱加载失败，请重新打开。"
        }
    }
}

enum LivingWorldBootstrap {
    static let fallbackWalkingSpeed: Float = 1.2
    /// PMX/VMD locomotion compatibility. The stride contract is *measured* on
    /// the shipped target rig (na_2b_0414 standard PMX, world-normalised to
    /// 1.7 m): stance-drift regression of the installed
    /// `gmgn.motion.bones.walk-loop-pmx` VMD evaluated with the runtime
    /// MMDSceneKit deformation model gives 0.72–0.78 m/s at rate 1
    /// (cadence ≈ 86 steps/min), not a hand-picked constant. See
    /// `tools/test-walking-adaptation.swift` and the measurement evidence in
    /// `tools/motion/measure_walk_loop_pmx.py`.
    static let bonesWalkCompatibility = StageMotionLocomotion(
        strideSpeed: 0.75,
        playbackRate: 1,
        inPlace: true
    )
    static let canaryDirectoryName = "living-pod-v1"
    static let marbleCabinDirectoryName = "marble-living-cabin"
    /// The world the app boots into when no Marble world was saved: the local
    /// bundled living pod, which needs no network download to render.
    static let defaultWorldID = LivingPodScene.worldID
    static let installedLivingMotionIDs: Set<String> = [
        MotionPackageStore.iluvSlapBassVRMID,
        "gmgn.motion.bones.idle-loop-pmx",
        "gmgn.motion.bones.idle-loop-vrm",
        "gmgn.motion.bones.jumping-jacks-vrm",
        "gmgn.motion.bones.hold-display-pmx",
        "gmgn.motion.bones.hold-display-vrm",
        "gmgn.motion.bones.chair-sit-loop-pmx",
        "gmgn.motion.bones.chair-sit-loop-vrm",
        "gmgn.motion.bones.cross-legged-loop-pmx",
        "gmgn.motion.bones.cross-legged-loop-vrm",
        "gmgn.motion.bones.kneeling-loop-pmx",
        "gmgn.motion.bones.kneeling-loop-vrm",
        "gmgn.motion.bones.walk-loop-pmx",
        "gmgn.motion.bones.walk-loop-vrm",
        "gmgn.motion.bones.coffee-button-pmx",
        "gmgn.motion.bones.arpg.interact-button-mid-vrm",
        "gmgn.motion.bones.arpg.interact-button-mid-pmx",
        "gmgn.motion.bones.arpg.pickup-standing-vrm",
        "gmgn.motion.bones.arpg.pickup-standing-pmx",
        "gmgn.motion.device.jukebox-low-button-pmx",
        "gmgn.motion.device.jukebox-low-button-vrm",
    ]

    static func loadBundledCanary(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        preferMarble: Bool = true
    ) throws -> BundledLivingWorldPackage {
        let preferredURL = bundle.resourceURL.flatMap {
            bundledManifestURL(resourceRoot: $0, fileManager: fileManager, preferMarble: preferMarble)
        }
        let candidates = [
            bundle.url(
                forResource: "world",
                withExtension: "json",
                subdirectory: "Worlds/\(canaryDirectoryName)"
            ),
            bundle.url(
                forResource: "world",
                withExtension: "json",
                subdirectory: canaryDirectoryName
            ),
            bundle.resourceURL?
                .appendingPathComponent("Worlds", isDirectory: true)
                .appendingPathComponent(canaryDirectoryName, isDirectory: true)
                .appendingPathComponent("world.json"),
            bundle.resourceURL?
                .appendingPathComponent(canaryDirectoryName, isDirectory: true)
                .appendingPathComponent("world.json"),
        ]
        guard let manifestURL = preferredURL ?? candidates.compactMap({ $0 }).first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) else {
            throw LivingWorldBootstrapError.bundledCanaryMissing
        }

        let decoder = JSONDecoder()
        let manifest = try decoder.decode(
            WorldManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let packageRoot = manifestURL.deletingLastPathComponent()
        let findings = WorldPackageValidator().validate(
            manifest,
            packageRoot: packageRoot
        )
        guard findings.isEmpty else {
            throw LivingWorldBootstrapError.badPackage(findings)
        }
        return BundledLivingWorldPackage(
            manifest: manifest,
            packageRoot: packageRoot
        )
    }

    static func bundledManifestURL(
        resourceRoot: URL,
        fileManager: FileManager = .default,
        preferMarble: Bool = true
    ) -> URL? {
        let directories = preferMarble ? [marbleCabinDirectoryName, canaryDirectoryName] : [canaryDirectoryName]
        for directory in directories {
            for prefix in ["Worlds/", ""] {
                let root = resourceRoot.appendingPathComponent(prefix + directory)
                // An adopted but broken package must produce a load error.
                if fileManager.fileExists(atPath: root.path) {
                    return root.appendingPathComponent("world.json")
                }
            }
        }
        return nil
    }

    static func loadMarbleCabin(
        package: BundledLivingWorldPackage,
        fileManager: FileManager = .default
    ) throws -> BundledMarbleLivingCabin? {
        guard package.packageRoot.lastPathComponent == marbleCabinDirectoryName else { return nil }
        let document = try JSONDecoder().decode(
            MarbleLivingCabinDocument.self,
            from: Data(contentsOf: package.packageRoot.appendingPathComponent("marble.json"))
        )
        guard document.world.id == package.manifest.worldID else {
            throw LivingWorldBootstrapError.badCabin("环境编号与空间规则编号不一致。")
        }
        let splatURL = package.packageRoot.appendingPathComponent("scene-500k.spz")
        let colliderURL = package.packageRoot.appendingPathComponent("collider.glb")
        for url in [splatURL, colliderURL] {
            guard fileManager.fileExists(atPath: url.path) else {
                throw LivingWorldBootstrapError.badCabin("缺少 \(url.lastPathComponent)")
            }
        }
        let spawn = package.manifest.spawn
        let rotation = spawn.rotation
        let spawnYaw = atan2(2 * (rotation.w * rotation.y + rotation.x * rotation.z),
                             1 - 2 * (rotation.y * rotation.y + rotation.z * rotation.z))
        let presentation = MarbleLivingCabinPresentation(
            worldID: document.world.id,
            camera: SpatialCameraState(position: document.camera.position.value,
                                       yaw: document.camera.yaw, pitch: document.camera.pitch),
            avatarPlacement: StageAvatarPlacement(
                position: SIMD3(spawn.position.x, spawn.position.y, spawn.position.z),
                scale: 1, yaw: spawnYaw
            ),
            jukeboxPosition: document.jukebox.position.value,
            jukeboxYaw: document.jukebox.yaw,
            sceneFraming: MarbleSceneFraming(
                groundedOrigin: document.framing.origin.value,
                uniformScale: document.framing.scale,
                minimum: document.framing.minimum.value,
                maximum: document.framing.maximum.value
            )
        )
        // This adopted export was measured against the SPZ reader's RDF frame.
        // Keep the correction local: older API worlds retain their own convention.
        let world = MarbleWorld(
            id: document.world.id,
            name: document.world.name.isEmpty ? package.manifest.displayName : document.world.name,
            model: document.world.model,
            thumbnailURL: document.world.thumbnailURL,
            colliderURL: document.world.colliderURL,
            colliderSourceCoordinates: .worldLabsOpenCV,
            semantics: document.world.semantics,
            splatFallbacks: document.world.splatFallbacks
        )
        return BundledMarbleLivingCabin(world: world, presentation: presentation,
                                       splatURL: splatURL, colliderURL: colliderURL)
    }

    /// Maps a semantic package version onto a single safe directory component.
    ///
    /// Only `[0-9A-Za-z._-+]` survive; anything else (path separators,
    /// whitespace, control characters) becomes `_`. A version that collapses
    /// to an empty or traversal component (``, `.`, `..`) is replaced with
    /// `_`, and a leading dot is made visible so the directory never hides.
    static func sanitizedPackageVersionDirectory(_ packageVersion: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-+")
        )
        var result = ""
        for scalar in packageVersion.unicodeScalars {
            if allowedCharacters.contains(scalar) {
                result.append(Character(scalar))
            } else {
                result.append("_")
            }
        }
        if result.isEmpty || result == "." || result == ".." {
            return "_"
        }
        while result.hasPrefix(".") {
            result = "_" + result.dropFirst()
        }
        return result
    }

    static func stateFileURL(
        packageID: String,
        packageVersion: String,
        fileManager: FileManager = .default,
        applicationSupportBase: URL? = nil
    ) throws -> URL {
        let base: URL
        if let applicationSupportBase {
            base = applicationSupportBase
        } else {
            base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        return base
            .appendingPathComponent(
                ProductIdentity.bundleIdentifier,
                isDirectory: true
            )
            .appendingPathComponent("LivingWorld", isDirectory: true)
            .appendingPathComponent(packageID, isDirectory: true)
            .appendingPathComponent(
                sanitizedPackageVersionDirectory(packageVersion),
                isDirectory: true
            )
            .appendingPathComponent("state.json")
    }

    static func statePersistence(
        manifest: WorldManifest,
        fileManager: FileManager = .default,
        applicationSupportBase: URL? = nil
    ) throws -> any WorldStatePersisting {
        let current = AtomicJSONWorldStatePersistence(fileURL: try stateFileURL(
            packageID: manifest.packageID,
            packageVersion: manifest.packageVersion,
            fileManager: fileManager,
            applicationSupportBase: applicationSupportBase
        ))
        guard manifest.packageID == "marble-living-cabin",
              manifest.worldID == "84503420-3010-4944-8fde-2f383cd08ebe",
              manifest.packageVersion == "1.2.0"
        else { return current }
        return LivingCabinVersion12Persistence(
            current: current,
            previous: AtomicJSONWorldStatePersistence(fileURL: try stateFileURL(
                packageID: manifest.packageID,
                packageVersion: "1.1.0",
                fileManager: fileManager,
                applicationSupportBase: applicationSupportBase
            ))
        )
    }

    /// Builds the only motion allow-list available to living activities.
    /// Resource IDs are the motion IDs referenced by phase contracts.
    static func approvedMotions(
        resources: [WorldResource],
        packageRoot: URL,
        supplementalMotions: [String: StageMotionAsset] = [:]
    ) throws -> [String: StageMotionAsset] {
        func permitsSource(_ id: String) -> Bool {
            id.hasPrefix("gmgn.motion.bones.")
                || id == "gmgn.motion.ardy-backflip"
                || id == MotionPackageStore.iluvSlapBassID
                || id == MotionPackageStore.iluvSlapBassVRMID
                || id == "gmgn.motion.device.jukebox-low-button-pmx"
                || id == "gmgn.motion.device.jukebox-low-button-vrm"
        }
        // Keep the explicit music alias, but do not let an old world package
        // or supplemental entry restore a retired non-BONES resident motion.
        var result = supplementalMotions.filter { permitsSource($0.value.id) }
        for resource in resources {
            guard permitsSource(resource.id) else { continue }
            let format: StageMotionFormat
            let expectedExtension: String
            switch resource.kind {
            case "motion.vrma":
                format = .vrma
                expectedExtension = "vrma"
            case "motion.vmd":
                format = .vmd
                expectedExtension = "vmd"
            default:
                continue
            }

            let url = packageRoot.appendingPathComponent(resource.path)
                .standardizedFileURL
            guard url.pathExtension.lowercased() == expectedExtension else {
                throw LivingWorldBootstrapError.badMotionResource(
                    id: resource.id,
                    kind: resource.kind,
                    path: resource.path
                )
            }
            result[resource.id] = StageMotionAsset(
                id: resource.id,
                name: resource.id,
                format: format,
                url: url
            )
        }
        return result
    }

    /// Keeps downloaded motions opt-in for semantic world activities. A user
    /// selected dance cannot accidentally become the walk or sit animation.
    static func approvedInstalledMotions(
        _ motions: [StageMotionAsset]
    ) -> [String: StageMotionAsset] {
        Dictionary(
            uniqueKeysWithValues: motions.compactMap { motion in
                if let performance = ResidentPerformanceMotionPolicy.approvedMotion(motion) {
                    return (performance.id, performance)
                }
                guard installedLivingMotionIDs.contains(motion.id) else {
                    return nil
                }
                let normalized: StageMotionAsset
                if motion.id.hasPrefix("gmgn.motion.bones.walk-loop-") {
                    normalized = motion.applyingLocomotionFallback(
                        bonesWalkCompatibility
                    )
                } else {
                    normalized = motion
                }
                return (motion.id, normalized)
            }
        )
    }

    static func walkingSpeed(
        approvedMotions: [String: StageMotionAsset],
        avatarFormat: StageAvatarFormat? = nil
    ) -> Float {
        guard let avatarFormat else { return fallbackWalkingSpeed }
        let id = "gmgn.motion.bones.walk-loop-\(avatarFormat.rawValue)"
        let format: StageMotionFormat = avatarFormat == .pmx ? .vmd : .vrma
        guard let motion = approvedMotions[id],
              motion.format == format, motion.url != nil,
              motion.loop, motion.inPlace == true,
              let strideSpeed = motion.strideSpeed
        else { return fallbackWalkingSpeed }
        return strideSpeed * motion.playbackRate
    }

    static func collisionCapsule(worldID: String) -> WorldCapsule {
        switch worldID {
        case "world-labs-example-warm-kitchen":
            WorldCapsule(radius: 0.12, height: 0.9)
        default:
            WorldCapsule(radius: 0.2, height: 1.8)
        }
    }

    /// 世界包里**一件**道具的 `prop.procedural` 声明。读不出/非法 = `nil`（绝不猜）。
    static func proceduralDeclaration(
        id: String,
        in package: BundledLivingWorldPackage,
        fileManager: FileManager = .default
    ) -> WorldProceduralPropDeclaration? {
        guard let resource = package.manifest.resources.first(where: { $0.id == id }),
              resource.kind == "prop.procedural" else { return nil }
        let url = package.packageRoot.appendingPathComponent(resource.path)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let declaration = try? JSONDecoder().decode(
                  WorldProceduralPropDeclaration.self, from: data
              ),
              declaration.objectID == id
        else { return nil }
        return declaration
    }

    /// 世界包里 `prop.procedural` 道具的**功能点来源**（声明 + 种子摆放）。
    ///
    /// 读不出 / 非法 = 这件道具没有功能点（跳过），**绝不猜坐标**。装载期由
    /// `WorldPackageValidator` 的 `missingFunctionPointDeclaration` 拦下
    /// "活动绑了一件声明不出来的道具"，所以这里静默跳过不会造成"活动悄悄没有锚点"。
    ///
    /// 排序固定：注册表的派生顺序必须确定（同一份包 ⇒ 同一份锚点）。
    static func propFunctionSources(
        in package: BundledLivingWorldPackage,
        fileManager: FileManager = .default
    ) -> [WorldPropFunctionSource] {
        package.manifest.resources
            .filter { $0.kind == "prop.procedural" }
            .sorted { $0.id < $1.id }
            .compactMap { resource -> WorldPropFunctionSource? in
                proceduralDeclaration(id: resource.id, in: package, fileManager: fileManager)?
                    .functionSource
            }
    }

    /// 迁移导入要读的**只读预像**候选（按优先级）。与 `statePersistence` 的读取
    /// 回退口径一致：`marble-living-cabin` 1.2 优先、1.1 兜底，其余包只有自己那一版。
    ///
    /// 它只在两个时刻被读：一次性导入权威、以及权威不可达时的只读降级。
    /// **任何路径都不会写它**（写入口见 `LegacyWorldStatePreImage.save`）。
    static func preImageCandidateURLs(
        manifest: WorldManifest,
        fileManager: FileManager = .default,
        applicationSupportBase: URL? = nil
    ) throws -> [URL] {
        let current = try stateFileURL(
            packageID: manifest.packageID,
            packageVersion: manifest.packageVersion,
            fileManager: fileManager,
            applicationSupportBase: applicationSupportBase
        )
        guard manifest.packageID == "marble-living-cabin",
              manifest.worldID == "84503420-3010-4944-8fde-2f383cd08ebe",
              manifest.packageVersion == "1.2.0"
        else { return [current] }
        return [current, try stateFileURL(
            packageID: manifest.packageID,
            packageVersion: "1.1.0",
            fileManager: fileManager,
            applicationSupportBase: applicationSupportBase
        )]
    }

    @MainActor
    static func makeContext(
        package: BundledLivingWorldPackage,
        walkingSpeed: Float? = nil,
        fileManager: FileManager = .default,
        applicationSupportBase: URL? = nil,
        initialCollisionWorld: (any WorldCollisionQuerying)? = nil
    ) throws -> WorldAgentContext {
        // 权威边界（docs/plans/2026-10-02-rust-world-authority-and-mcp.md）：
        // `gmgn-taskd` 是**唯一**写世界状态的进程；`state.json` 降级成只读预像
        // （一次性导入 + 出事回滚）。Swift 侧不再有世界状态持久化路径。
        let archive = try statePersistence(
            manifest: package.manifest,
            fileManager: fileManager,
            applicationSupportBase: applicationSupportBase
        )
        let preImage = LegacyWorldStatePreImage(
            archive: archive,
            candidateURLs: try preImageCandidateURLs(
                manifest: package.manifest,
                fileManager: fileManager,
                applicationSupportBase: applicationSupportBase
            )
        )
        let endpoint = WorldAuthorityEndpoint(applicationSupportBase: applicationSupportBase)
        let persistence = AuthorityWorldStatePersistence(
            manifest: package.manifest,
            preImage: preImage,
            endpointFile: endpoint.endpointFile,
            helperPath: endpoint.helperPath
        )
        // 许愿机的视觉放置与取物/出货点也来自声明：App 里不再有第二份数字。
        WishMachineScene.install(
            proceduralDeclaration(id: WishMachineScene.propID, in: package, fileManager: fileManager)
        )
        let context = try WorldAgentContext(
            manifest: package.manifest,
            persistence: persistence,
            walkingSpeed: walkingSpeed ?? fallbackWalkingSpeed,
            capsule: collisionCapsule(worldID: package.manifest.worldID),
            propFunctionSources: propFunctionSources(in: package, fileManager: fileManager),
            initialCollisionWorld: initialCollisionWorld
        )
        // 事件通道（推送）：权威一变就推进本地投影的 `basedOnRevision`。
        // 渲染路径仍然只读内存里的投影，**永不同步 RPC**（设计 §4.1）。
        persistence.startEventSubscription()
        return context
    }
}
