import Foundation
import WorldRuntime

struct BundledLivingWorldPackage: Sendable {
    let manifest: WorldManifest
    let packageRoot: URL
}

enum LivingWorldBootstrapError: LocalizedError {
    case bundledCanaryMissing
    case invalidPackage([WorldPackageError])
    case invalidMotionResource(id: String, kind: String, path: String)

    var errorDescription: String? {
        switch self {
        case .bundledCanaryMissing:
            "应用内没有找到生活舱示例空间。"
        case let .invalidPackage(findings):
            "生活舱示例空间校验失败：\(findings.map(String.init(describing:)).joined(separator: ", "))"
        case let .invalidMotionResource(id, kind, path):
            "生活空间动作资源格式不匹配：id=\(id)，kind=\(kind)，path=\(path)"
        }
    }
}

enum LivingWorldBootstrap {
    static let fallbackWalkingSpeed: Float = 1.2
    static let ardyWalkCompatibility = StageMotionLocomotion(
        strideSpeed: 0.45,
        playbackRate: 4,
        inPlace: true
    )
    static let bonesWalkCompatibility = StageMotionLocomotion(
        strideSpeed: 0.45,
        playbackRate: 1,
        inPlace: true
    )
    static let canaryDirectoryName = "living-pod-v1"
    /// The world the app boots into when no Marble world was saved: the local
    /// bundled living pod, which needs no network download to render.
    static let defaultWorldID = LivingPodScene.worldID
    static let installedLivingMotionIDs: Set<String> = [
        "gmgn.motion.bones.chair-sit-loop-pmx",
        "gmgn.motion.bones.chair-sit-loop-vrm",
        "gmgn.motion.bones.cross-legged-loop-pmx",
        "gmgn.motion.bones.cross-legged-loop-vrm",
        "gmgn.motion.bones.kneeling-loop-pmx",
        "gmgn.motion.bones.kneeling-loop-vrm",
        "gmgn.motion.bones.walk-loop-pmx",
        "gmgn.motion.bones.walk-loop-vrm",
        "gmgn.motion.bones.coffee-button-pmx",
        "gmgn.motion.ardy-walk-loop-pmx",
        "gmgn.motion.ardy-walk-loop-vrm",
        "gmgn.motion.generated.a-person-naturally-picks-up-a-coffee-cup-76b63e0f",
    ]

    static func loadBundledCanary(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> BundledLivingWorldPackage {
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
        guard let manifestURL = candidates.compactMap({ $0 }).first(where: {
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
            throw LivingWorldBootstrapError.invalidPackage(findings)
        }
        return BundledLivingWorldPackage(
            manifest: manifest,
            packageRoot: packageRoot
        )
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

    /// Builds the only motion allow-list available to living activities.
    /// Resource IDs are the motion IDs referenced by phase contracts.
    static func approvedMotions(
        resources: [WorldResource],
        packageRoot: URL,
        supplementalMotions: [String: StageMotionAsset] = [:]
    ) throws -> [String: StageMotionAsset] {
        var result = supplementalMotions
        for resource in resources {
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
                throw LivingWorldBootstrapError.invalidMotionResource(
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
                guard installedLivingMotionIDs.contains(motion.id) else {
                    return nil
                }
                let normalized: StageMotionAsset
                if motion.id.hasPrefix("gmgn.motion.bones.walk-loop-") {
                    normalized = motion.applyingLocomotionFallback(
                        bonesWalkCompatibility
                    )
                } else if motion.id.hasPrefix("gmgn.motion.ardy-walk-loop-") {
                    normalized = motion.applyingLocomotionFallback(
                        ardyWalkCompatibility
                    )
                } else {
                    normalized = motion
                }
                return (motion.id, normalized)
            }
        )
    }

    static func walkingSpeed(
        approvedMotions: [String: StageMotionAsset]
    ) -> Float {
        let requestedWalkIDs = [
            "gmgn.motion.bones.walk-loop-pmx",
            "gmgn.motion.bones.walk-loop-vrm",
            "gmgn.motion.ardy-walk-loop-pmx",
            "gmgn.motion.ardy-walk-loop-vrm",
            "walk.forward",
        ]
        return requestedWalkIDs.lazy
            .compactMap { approvedMotions[$0]?.strideSpeed }
            .first ?? fallbackWalkingSpeed
    }

    static func collisionCapsule(worldID: String) -> WorldCapsule {
        switch worldID {
        case "world-labs-example-warm-kitchen":
            WorldCapsule(radius: 0.12, height: 0.9)
        default:
            WorldCapsule(radius: 0.2, height: 1.8)
        }
    }

    @MainActor
    static func makeContext(
        package: BundledLivingWorldPackage,
        walkingSpeed: Float? = nil,
        fileManager: FileManager = .default,
        applicationSupportBase: URL? = nil
    ) throws -> WorldAgentContext {
        let persistence = AtomicJSONWorldStatePersistence(
            fileURL: try stateFileURL(
                packageID: package.manifest.packageID,
                packageVersion: package.manifest.packageVersion,
                fileManager: fileManager,
                applicationSupportBase: applicationSupportBase
            )
        )
        return try WorldAgentContext(
            manifest: package.manifest,
            persistence: persistence,
            walkingSpeed: walkingSpeed ?? fallbackWalkingSpeed,
            capsule: collisionCapsule(worldID: package.manifest.worldID)
        )
    }
}
