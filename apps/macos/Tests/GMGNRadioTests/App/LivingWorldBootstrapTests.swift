import Foundation
import Testing
import WorldRuntime
@testable import GMGNRadio

@Suite
struct LivingWorldBootstrapTests {
    @Test
    func warmKitchenUsesAvatarSizedCollisionCapsule() {
        #expect(
            LivingWorldBootstrap.collisionCapsule(
                worldID: "world-labs-example-warm-kitchen"
            ) == WorldCapsule(radius: 0.12, height: 0.9)
        )
    }

    @Test
    func worldMotionResourcesBecomeTheApprovedActivityAllowList() throws {
        let root = URL(filePath: "/tmp/world-motion-fixture", directoryHint: .isDirectory)
        let resources = [
            WorldResource(
                id: "walk.forward",
                path: "motions/walk.vrma",
                sha256: String(repeating: "0", count: 64),
                kind: "motion.vrma"
            ),
            WorldResource(
                id: "dance.stage",
                path: "motions/dance.vmd",
                sha256: String(repeating: "1", count: 64),
                kind: "motion.vmd"
            ),
            WorldResource(
                id: "world.visual",
                path: "scene.spz",
                sha256: String(repeating: "2", count: 64),
                kind: "spz"
            ),
        ]

        let approved = try LivingWorldBootstrap.approvedMotions(
            resources: resources,
            packageRoot: root
        )

        #expect(Set(approved.keys) == ["walk.forward", "dance.stage"])
        #expect(approved["walk.forward"]?.format == .vrma)
        #expect(approved["walk.forward"]?.url == root.appendingPathComponent(
            "motions/walk.vrma"
        ))
        #expect(approved["dance.stage"]?.format == .vmd)
    }

    @Test
    func mismatchedMotionExtensionIsRejected() {
        let resource = WorldResource(
            id: "walk.forward",
            path: "motions/walk.vmd",
            sha256: String(repeating: "0", count: 64),
            kind: "motion.vrma"
        )

        #expect(throws: LivingWorldBootstrapError.self) {
            _ = try LivingWorldBootstrap.approvedMotions(
                resources: [resource],
                packageRoot: URL(filePath: "/tmp/world-motion-fixture")
            )
        }
    }

    @Test
    func explicitCanaryMotionAliasFillsAMissingWorldResource() throws {
        let slapBass = StageMotionAsset(
            id: MotionPackageStore.iluvSlapBassID,
            name: "I Love Slap Bass",
            format: .vmd,
            url: URL(filePath: "/tmp/slap-bass.vmd")
        )

        let approved = try LivingWorldBootstrap.approvedMotions(
            resources: [],
            packageRoot: URL(filePath: "/tmp/world-motion-fixture"),
            supplementalMotions: ["listen.music": slapBass]
        )

        #expect(approved["listen.music"] == slapBass)
        #expect(approved["walk.forward"] == nil)
        #expect(approved["sit.chair"] == nil)
    }

    @Test
    func onlyKnownDownloadedLivingMotionsEnterTheActivityAllowList() {
        let walkPMX = StageMotionAsset(
            id: "gmgn.motion.bones.walk-loop-pmx",
            name: "BONES Walk PMX",
            format: .vmd,
            url: URL(filePath: "/tmp/walk.vmd")
        )
        let walkVRM = StageMotionAsset(
            id: "gmgn.motion.bones.walk-loop-vrm",
            name: "BONES Walk VRM",
            format: .vrma,
            url: URL(filePath: "/tmp/walk.vrma")
        )
        let coffeeButton = StageMotionAsset(
            id: "gmgn.motion.bones.coffee-button-pmx",
            name: "BONES Coffee Button PMX",
            format: .vmd,
            url: URL(filePath: "/tmp/coffee-button.vmd")
        )
        let unrelatedDance = StageMotionAsset(
            id: "motion.user.dance",
            name: "User Dance",
            format: .vmd,
            url: URL(filePath: "/tmp/dance.vmd")
        )

        let approved = LivingWorldBootstrap.approvedInstalledMotions(
            [walkPMX, unrelatedDance, walkVRM, coffeeButton]
        )

        #expect(Set(approved.keys) == [walkPMX.id, walkVRM.id, coffeeButton.id])
        #expect(approved[walkPMX.id]?.url == walkPMX.url)
        #expect(approved[walkVRM.id]?.url == walkVRM.url)
        #expect(approved[coffeeButton.id] == coffeeButton)
    }

    @Test
    func ardyWalkUsesItsLocomotionContractInsteadOfAGlobalSpeed() {
        let walk = StageMotionAsset(
            id: "gmgn.motion.ardy-walk-loop-pmx",
            name: "ARDY Walk",
            format: .vmd,
            url: URL(filePath: "/tmp/ardy-walk.vmd")
        )

        let approved = LivingWorldBootstrap.approvedInstalledMotions([walk])
        let normalized = approved[walk.id]

        #expect(normalized?.strideSpeed == 0.45)
        #expect(normalized?.playbackRate == 4)
        #expect(normalized?.inPlace == true)
        #expect(LivingWorldBootstrap.walkingSpeed(approvedMotions: approved) == 0.45)
    }

    @Test
    func bonesWalkIsThePreferredLivingWorldLocomotion() {
        let bones = StageMotionAsset(
            id: "gmgn.motion.bones.walk-loop-pmx",
            name: "BONES Walk",
            format: .vmd,
            url: URL(filePath: "/tmp/bones-walk.vmd")
        )
        let ardy = StageMotionAsset(
            id: "gmgn.motion.ardy-walk-loop-pmx",
            name: "ARDY Walk",
            format: .vmd,
            url: URL(filePath: "/tmp/ardy-walk.vmd")
        )

        let approved = LivingWorldBootstrap.approvedInstalledMotions([ardy, bones])
        let normalizedBones = approved[bones.id]

        #expect(normalizedBones?.strideSpeed == 0.45)
        #expect(normalizedBones?.playbackRate == 1)
        #expect(normalizedBones?.inPlace == true)
        #expect(LivingWorldBootstrap.walkingSpeed(approvedMotions: approved) == 0.45)
    }
}

@Suite
struct LivingWorldStateVersioningTests {
    @Test
    func stateFileURLSeparatesStateByPackageVersion() throws {
        let base = URL(
            filePath: "/tmp/world-state-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let v1 = try LivingWorldBootstrap.stateFileURL(
            packageID: "warm-kitchen-canary",
            packageVersion: "1.1.0",
            applicationSupportBase: base
        )
        let v2 = try LivingWorldBootstrap.stateFileURL(
            packageID: "warm-kitchen-canary",
            packageVersion: "1.2.0",
            applicationSupportBase: base
        )

        #expect(v1 != v2)
        #expect(v1.lastPathComponent == "state.json")
        #expect(v1.deletingLastPathComponent().lastPathComponent == "1.1.0")
        #expect(v2.deletingLastPathComponent().lastPathComponent == "1.2.0")
        #expect(v1.path.hasPrefix(base.path + "/"))
        #expect(v2.path.hasPrefix(base.path + "/"))
    }

    @Test
    func stateFileURLSanitizesUnsafeVersionComponents() throws {
        let base = URL(
            filePath: "/tmp/world-state-sanitized-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let unsafeVersions = [
            "",
            ".",
            "..",
            "../1.2.0",
            "1.2.0/..",
            "1.2.0\\..",
            "1.2.0 ..",
            "1.2.0\nrc",
        ]
        for version in unsafeVersions {
            let url = try LivingWorldBootstrap.stateFileURL(
                packageID: "warm-kitchen-canary",
                packageVersion: version,
                applicationSupportBase: base
            )
            let component = url.deletingLastPathComponent().lastPathComponent
            #expect(!component.isEmpty)
            #expect(component != ".")
            #expect(component != "..")
            #expect(!component.contains("/"))
            #expect(!component.contains("\\"))
            #expect(url.path.hasPrefix(base.path + "/"))
        }
    }

    @MainActor
    @Test
    func makeContextRestoresStateFromItsOwnPackageVersionDirectory() throws {
        let manifest = Self.minimalManifest(packageVersion: "1.2.0")
        let package = BundledLivingWorldPackage(
            manifest: manifest,
            packageRoot: URL(filePath: "/tmp/world-root-\(UUID().uuidString)")
        )
        let base = URL(
            filePath: "/tmp/world-state-context-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )

        let v1URL = try LivingWorldBootstrap.stateFileURL(
            packageID: manifest.packageID,
            packageVersion: "1.1.0",
            applicationSupportBase: base
        )
        let v2URL = try LivingWorldBootstrap.stateFileURL(
            packageID: manifest.packageID,
            packageVersion: "1.2.0",
            applicationSupportBase: base
        )
        let identity = WorldQuaternion(x: 0, y: 0, z: 0, w: 1)
        let unit = WorldVector3(x: 1, y: 1, z: 1)
        let staleTransform = WorldTransform(
            position: WorldVector3(x: 1.1, y: 0, z: 1.1),
            rotation: identity,
            scale: unit
        )
        let currentTransform = WorldTransform(
            position: WorldVector3(x: 1.2, y: 0, z: 1.2),
            rotation: identity,
            scale: unit
        )
        try AtomicJSONWorldStatePersistence(fileURL: v1URL).save(
            WorldState(
                revision: 1,
                worldID: manifest.worldID,
                worldTime: Date(timeIntervalSince1970: 100),
                lastObservedWallTime: Date(timeIntervalSince1970: 100),
                weather: .clear,
                agentTransform: staleTransform
            )
        )
        try AtomicJSONWorldStatePersistence(fileURL: v2URL).save(
            WorldState(
                revision: 2,
                worldID: manifest.worldID,
                worldTime: Date(timeIntervalSince1970: 200),
                lastObservedWallTime: Date(timeIntervalSince1970: 200),
                weather: .clear,
                agentTransform: currentTransform
            )
        )

        let context = try LivingWorldBootstrap.makeContext(
            package: package,
            fileManager: .default,
            applicationSupportBase: base
        )

        // The 1.2.0 bundle must restore the 1.2.0 state, never the stale
        // 1.1.0 state stored under the sibling version directory.
        #expect(context.state.agentTransform == currentTransform)
        #expect(context.state.agentTransform != staleTransform)
        #expect(context.state.worldID == manifest.worldID)
    }

    private static func minimalManifest(packageVersion: String) -> WorldManifest {
        let identity = WorldQuaternion(x: 0, y: 0, z: 0, w: 1)
        let unit = WorldVector3(x: 1, y: 1, z: 1)
        let transform = WorldTransform(
            position: WorldVector3(x: 0, y: 0, z: 0),
            rotation: identity,
            scale: unit
        )
        let phases = LifeActivityPhase.allCases.map {
            ActivityPhaseContract(phase: $0)
        }
        return WorldManifest(
            schemaVersion: 1,
            packageID: "warm-kitchen-canary",
            packageVersion: packageVersion,
            worldID: "world-labs-example-warm-kitchen",
            displayName: "Warm Kitchen",
            calibration: WorldCalibration(
                visualToGameplay: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                metersPerUnit: 1
            ),
            spawn: transform,
            collisionVolumes: [],
            waypoints: [
                WorldWaypoint(
                    id: "wp.spawn",
                    position: transform.position,
                    arrivalRadius: 0.2,
                    enabled: true
                ),
            ],
            routes: [],
            activities: [
                WorldActivityAnchor(
                    id: "home.idle",
                    action: "idle",
                    entryWaypointID: "wp.spawn",
                    transform: transform,
                    motionID: "idle.natural",
                    propIDs: [],
                    interruptible: true
                ),
            ],
            activityDefinitions: [
                LifeActivityDefinition(
                    id: "home.idle",
                    activity: .idle,
                    phases: phases,
                    interruptible: true,
                    cooldownSeconds: 0
                ),
            ],
            cameras: [],
            capabilities: [.activity("home.idle")],
            resources: []
        )
    }
}
