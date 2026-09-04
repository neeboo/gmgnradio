import Foundation
import Testing
import WorldRuntime
@testable import GMGNRadio

@Suite
struct LivingWorldBootstrapTests {
    @Test
    func bundledLivingWorldDefaultsToTheLocalLivingPod() {
        #expect(LivingWorldBootstrap.canaryDirectoryName == "living-pod-v1")
        #expect(LivingWorldBootstrap.defaultWorldID == LivingPodScene.worldID)
    }

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

    // MARK: - living-pod-v1 bundled package

    @Test
    func livingPodPackageValidatesAndShipsTheExpectedIdentity() throws {
        let manifest = try Self.livingPodManifest()
        #expect(manifest.packageID == "living-pod-v1")
        #expect(manifest.packageVersion == "1.0.0")
        #expect(manifest.worldID == LivingPodScene.worldID)
        #expect(manifest.resources.isEmpty)
        #expect(manifest.cameras.count == 2)
        #expect(
            Set(manifest.activities.map(\.id))
                == Set(manifest.activityDefinitions.map(\.id))
        )
        #expect(
            manifest.capabilities.isSuperset(
                of: manifest.activities.map {
                    WorldCapability.activity($0.id)
                }
            )
        )
        #expect(
            manifest.capabilities.isSuperset(
                of: manifest.cameras.map {
                    WorldCapability.camera($0.id)
                }
            )
        )
        _ = try ActivityCatalog(manifest: manifest)
    }

    @Test
    func livingPodActivitiesExposeChineseNamesAndApprovedMotionsOnly() throws {
        let manifest = try Self.livingPodManifest()
        let approvedMotionIDs = LivingWorldBootstrap.installedLivingMotionIDs
            .union(["listen.music"])
        let definitionsByID = Dictionary(
            uniqueKeysWithValues: manifest.activityDefinitions.map { ($0.id, $0) }
        )

        for anchor in manifest.activities {
            let definition = try #require(
                definitionsByID[anchor.id],
                "activity \(anchor.id) has no definition"
            )
            let displayName = try #require(
                definition.displayName,
                "activity \(anchor.id) has no Chinese display name"
            )
            #expect(!displayName.isEmpty)

            #expect(Set(definition.phases.map(\.phase)) == Set(LifeActivityPhase.allCases))
            #expect(
                Set(definition.phases.map(\.phase)).count == 6,
                "activity \(anchor.id) must not duplicate phases"
            )

            let referencedMotions = definition.phases.flatMap(\.motionIDs)
                + [anchor.motionID].compactMap { $0 }
            let unexpected = Set(referencedMotions).subtracting(approvedMotionIDs)
            #expect(
                unexpected.isEmpty,
                "activity \(anchor.id) references unapproved motions: \(unexpected.sorted())"
            )
        }
    }

    @Test
    func livingPodBlocksItsAuthoredWallsAndFurniture() throws {
        let manifest = try Self.livingPodManifest()
        let collision = CollisionVolumeWorld(manifest: manifest)
        let capsule = WorldCapsule(radius: 0.2, height: 1.8)

        // The pod stands on the deck (y = floor top 0.12). Authored furniture
        // and hull centers must reject the character capsule.
        let occupiedCenters: [SIMD3<Float>] = [
            SIMD3(-1.0, 0.12, -1.15),   // bunk
            SIMD3(0.95, 0.12, -1.18),   // workbench console
            SIMD3(1.18, 0.12, 0.3),     // jukebox
            SIMD3(-1.27, 0.12, 0.72),   // coffee counter
            SIMD3(-1.35, 0.12, -0.1),   // viewport wall
            SIMD3(0, 0.12, -1.57),      // rear airlock bulkhead
        ]
        for position in occupiedCenters {
            #expect(
                !collision.canOccupy(capsule, at: position),
                "The character capsule can still enter living-pod geometry at \(position)"
            )
        }

        let walkableCenters: [SIMD3<Float>] = [
            SIMD3(0, 0.12, 1.1),     // spawn
            SIMD3(0, 0.12, 0.2),     // center
            SIMD3(-0.95, 0.12, -0.5), // bunk rest stand
            SIMD3(0.15, 0.12, -0.6),  // console stand
            SIMD3(0.62, 0.12, 0.3),   // jukebox stand
            SIMD3(-0.72, 0.12, 0.72), // coffee stand
            SIMD3(-0.9, 0.12, -0.1),  // viewport stand
            SIMD3(0, 0.12, -1.1),     // airlock stand
        ]
        for position in walkableCenters {
            #expect(
                collision.canOccupy(capsule, at: position),
                "An authored living-pod activity entry is trapped at \(position)"
            )
        }
    }

    @Test
    func livingPodRoutesEveryActivityEntryFromSpawnWithoutPenetration() throws {
        let manifest = try Self.livingPodManifest()
        let router = WaypointNavigationGraph(manifest: manifest)
        let collision = CollisionVolumeWorld(manifest: manifest)
        let capsule = WorldCapsule(radius: 0.2, height: 1.8)
        let spawn = Self.simd(manifest.spawn.position)
        let anchorsByEntry = Dictionary(
            uniqueKeysWithValues: manifest.activities.map {
                ($0.entryWaypointID, $0)
            }
        )
        #expect(Set(anchorsByEntry.keys) == Set(manifest.waypoints.map(\.id)))

        for anchor in manifest.activities.sorted(by: { $0.id < $1.id }) {
            let path = try router.route(
                from: spawn,
                to: anchor.entryWaypointID
            )
            if anchor.entryWaypointID != "wp.spawn" {
                #expect(
                    !path.waypointIDs.isEmpty,
                    "No movement path to \(anchor.id)"
                )
            }
            var cursor = spawn
            for waypoint in path.points {
                let destination = Self.simd(waypoint)
                #expect(
                    collision.canTraverse(
                        capsule,
                        from: cursor,
                        to: destination,
                        maximumStepHeight: 0.3
                    ),
                    "Blocked segment while routing to \(anchor.id)"
                )
                cursor = destination
            }

            let anchorPosition = Self.simd(anchor.transform.position)
            #expect(
                simdDistance(cursor, anchorPosition) <= 0.08,
                "Entry transform is outside the 8 cm tolerance for \(anchor.id)"
            )
            let ground = try #require(
                collision.groundHeight(at: anchorPosition)
            )
            #expect(
                abs(anchorPosition.y - ground) <= 0.03,
                "Feet are outside the 3 cm ground tolerance for \(anchor.id)"
            )
            #expect(
                collision.canOccupy(capsule, at: anchorPosition),
                "Anchor intersects blocking geometry for \(anchor.id)"
            )
        }

        // Every authored anchor has a corresponding stand occupied above; also
        // make sure the anchors agree with their entries so the world context
        // activity executor can park the avatar at the anchor.
        for anchor in manifest.activities {
            let entry = try #require(
                manifest.waypoints.first(where: { $0.id == anchor.entryWaypointID })
            )
            let distance = simdDistance(
                Self.simd(anchor.transform.position),
                Self.simd(entry.position)
            )
            #expect(
                distance <= 0.08,
                "Activity \(anchor.id) transform is \(distance)m from its entry waypoint"
            )
        }
    }

    private static func simd(_ value: WorldVector3) -> SIMD3<Float> {
        SIMD3(value.x, value.y, value.z)
    }

    private static func livingPodManifest() throws -> WorldManifest {
        let sourceFile = URL(filePath: #filePath)
            .deletingLastPathComponent()
        let manifestURL = sourceFile
            .appendingPathComponent("../../../Resources", isDirectory: true)
            .appendingPathComponent("Worlds", isDirectory: true)
            .appendingPathComponent("living-pod-v1", isDirectory: true)
            .appendingPathComponent("world.json")
            .standardizedFileURL
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(
            WorldManifest.self,
            from: data
        )
        let findings = WorldPackageValidator().validate(
            manifest,
            packageRoot: manifestURL.deletingLastPathComponent()
        )
        #expect(
            findings.isEmpty,
            "living-pod-v1 package findings: \(findings)"
        )
        return manifest
    }
}

private func simdDistance(
    _ lhs: SIMD3<Float>,
    _ rhs: SIMD3<Float>
) -> Float {
    let delta = lhs - rhs
    return sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
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
