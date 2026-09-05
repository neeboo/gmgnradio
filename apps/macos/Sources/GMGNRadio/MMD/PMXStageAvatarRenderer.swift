import Foundation
import Metal
@preconcurrency import MMDSceneKit
import QuartzCore
@preconcurrency import SceneKit
import simd
import os

enum PMXWorldPropFactory {
    static func coffeeMachine() -> SCNNode {
        let root = SCNNode()
        root.name = "gmgn-coffee-machine"

        let dark = material(
            diffuse: NSColor(calibratedWhite: 0.075, alpha: 1),
            metalness: 0.72,
            roughness: 0.28
        )
        let steel = material(
            diffuse: NSColor(calibratedWhite: 0.72, alpha: 1),
            metalness: 0.9,
            roughness: 0.2
        )

        let body = node(
            name: "body",
            geometry: SCNBox(width: 0.24, height: 0.28, length: 0.18, chamferRadius: 0.025),
            material: dark,
            position: SIMD3<Float>(0, 0.16, 0)
        )
        root.addChildNode(body)

        let face = node(
            name: "control-face",
            geometry: SCNBox(width: 0.18, height: 0.075, length: 0.012, chamferRadius: 0.008),
            material: steel,
            position: SIMD3<Float>(0, 0.225, -0.096)
        )
        root.addChildNode(face)

        let button = node(
            name: "brew-button",
            geometry: SCNCylinder(radius: 0.014, height: 0.012),
            material: material(
                diffuse: NSColor(calibratedRed: 0.12, green: 0.82, blue: 0.92, alpha: 1),
                metalness: 0.15,
                roughness: 0.2
            ),
            position: SIMD3<Float>(0.055, 0.225, -0.105),
            eulerAngles: SIMD3<Float>(.pi / 2, 0, 0)
        )
        root.addChildNode(button)

        let nozzle = node(
            name: "nozzle",
            geometry: SCNCylinder(radius: 0.011, height: 0.085),
            material: steel,
            position: SIMD3<Float>(0, 0.13, -0.13)
        )
        root.addChildNode(nozzle)

        let tray = node(
            name: "drip-tray",
            geometry: SCNBox(width: 0.17, height: 0.018, length: 0.13, chamferRadius: 0.009),
            material: steel,
            position: SIMD3<Float>(0, 0.02, -0.055)
        )
        root.addChildNode(tray)
        return root
    }

    static func coffeeCup() -> SCNNode {
        let root = SCNNode()
        root.name = PMXWarmKitchenCoffeeCup.nodeName

        let ceramic = material(
            diffuse: NSColor(calibratedWhite: 0.93, alpha: 1),
            metalness: 0.05,
            roughness: 0.35
        )
        let coffee = material(
            diffuse: NSColor(calibratedRed: 0.21, green: 0.11, blue: 0.06, alpha: 1),
            metalness: 0.05,
            roughness: 0.25
        )

        let body = node(
            name: "cup-body",
            geometry: SCNCylinder(radius: 0.032, height: 0.075),
            material: ceramic,
            position: SIMD3<Float>(0, 0.0375, 0)
        )
        root.addChildNode(body)

        let rim = node(
            name: "cup-rim",
            geometry: SCNTorus(ringRadius: 0.032, pipeRadius: 0.0045),
            material: ceramic,
            position: SIMD3<Float>(0, 0.075, 0)
        )
        root.addChildNode(rim)

        let surface = node(
            name: "cup-coffee",
            geometry: SCNCylinder(radius: 0.028, height: 0.002),
            material: coffee,
            position: SIMD3<Float>(0, 0.071, 0)
        )
        root.addChildNode(surface)

        let handle = node(
            name: "cup-handle",
            geometry: SCNTorus(ringRadius: 0.017, pipeRadius: 0.004),
            material: ceramic,
            position: SIMD3<Float>(-0.04, 0.04, 0),
            eulerAngles: SIMD3<Float>(.pi / 2, 0, 0)
        )
        root.addChildNode(handle)
        return root
    }

    private static func node(
        name: String,
        geometry: SCNGeometry,
        material: SCNMaterial,
        position: SIMD3<Float>,
        eulerAngles: SIMD3<Float> = .zero
    ) -> SCNNode {
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = name
        node.simdPosition = position
        node.simdEulerAngles = eulerAngles
        node.castsShadow = true
        return node
    }

    private static func material(
        diffuse: NSColor,
        metalness: CGFloat,
        roughness: CGFloat
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = diffuse
        material.metalness.contents = metalness
        material.roughness.contents = roughness
        material.lightingModel = .physicallyBased
        return material
    }
}

enum PMXWarmKitchenCoffeeMachine {
    static let worldID = "world-labs-example-warm-kitchen"
    static let scenePosition = SIMD3<Float>(0.68, 0.5135225, -1.28)
    static let interactionPosition = SIMD3<Float>(0.38, 0, -1.28)
    static let sceneScale: Float = 0.6739059
    static let sceneYaw: Float = .pi / 2
    static let interactionYaw: Float = .pi / 2
    static let countertopSurfaceY: Float = 0.5209355

    static var frontDirection: SIMD3<Float> {
        simd_act(
            simd_quatf(angle: sceneYaw, axis: SIMD3<Float>(0, 1, 0)),
            SIMD3<Float>(0, 0, -1)
        )
    }

    static func shouldDisplay(worldID: String?, drawsWorld: Bool) -> Bool {
        drawsWorld && worldID == self.worldID
    }
}

enum PMXWarmKitchenCoffeeCup {
    static let nodeName = "gmgn-coffee-cup"
    static let motionID =
        "gmgn.motion.generated.a-person-naturally-picks-up-a-coffee-cup-76b63e0f"
    /// The sip choreography reaches for the cup with the left hand; the raw
    /// 2B rig hides the same wrist behind an exporter bone index.
    private static let wristBoneNameCandidates = ["左手首", "bone013"]
    private static let normalizedAvatarHeight: Float = 1.7

    static func shouldDisplay(motionID: String?) -> Bool {
        motionID == self.motionID
    }

    static func wristBone(in model: SCNNode) -> SCNNode? {
        for name in wristBoneNameCandidates {
            if let node = model.childNode(withName: name, recursively: true) {
                return node
            }
        }
        return nil
    }

    /// Rigs author at varying unit scales; a meter-sized cup must grow with
    /// the model so it stays hand-sized on every character.
    static func attachmentScale(modelHeight: Float) -> Float {
        let height = modelHeight.isFinite && modelHeight > 0
            ? modelHeight
            : normalizedAvatarHeight
        return height / normalizedAvatarHeight
    }
}

/// The avatar's built-in local world: a low-poly cosmic living pod assembled
/// from SceneKit primitives only (no downloads, textures, or Marble SPZ).
/// The room factory is pure presentation — collisions, waypoints and activity
/// anchors stay in the world manifest — and every zone keeps a stable,
/// recursively findable node name so it can later be swapped for a GLB.
enum LivingPodScene {
    static let worldID = "gmgn-living-pod-v1"

    /// The pod is the bundled local space; downloaded Marble worlds are not.
    static func isLocalWorld(_ worldID: String?) -> Bool {
        worldID == Self.worldID
    }

    // MARK: - Shared gameplay/presentation calibration
    //
    // The pod renders in the same metre space its world manifest describes, so
    // these numbers mirror apps/macos/Resources/Worlds/living-pod-v1/world.json
    // and feed `SpatialWorldCalibration.resolve` for camera and avatar startup.

    /// Top of the deck slab (`hull-floor`), the walkable ground plane.
    static let floorTopY: Float = 0.12
    /// Front-deck spawn in front of the room's open side.
    static let spawnPosition = SIMD3<Float>(0, floorTopY, 1.1)
    /// Yaw heading of the authored spawn quaternion (w 0.944, y 0.329).
    static let spawnYaw: Float = 0.67
    /// Establishing camera on the front apron, looking into the pod.
    static let presentationCameraPosition = SIMD3<Float>(0, 1.35, 3.05)

    /// The pod renders only while the full stage draws a world, and only when
    /// that world is the local living pod. Live Cam never draws the cabin.
    static func shouldDisplay(worldID: String?, drawsWorld: Bool) -> Bool {
        drawsWorld && isLocalWorld(worldID)
    }

    // MARK: - Room factory

    /// Builds an open-front stage cabin named `gmgn-living-pod-room`. Dark gray
    /// hull with warm amber living lights and sparse cyan equipment lights; the
    /// floor center stays clear so an avatar can stand at the origin.
    static func makeRoomNode() -> SCNNode {
        let room = SCNNode()
        room.name = "gmgn-living-pod-room"
        appendHull(to: room)
        room.addChildNode(makeSleepPod())
        room.addChildNode(makeWorkbenchConsole())
        room.addChildNode(makeJukebox())
        room.addChildNode(makeCoffeeMachine())
        room.addChildNode(makeViewport())
        room.addChildNode(makeAirlock())
        return room
    }

    /// Standalone metre-scale device. The origin is the centre of its bottom
    /// face and its controls face -X, so a world package can place it directly.
    static func makeIndependentJukebox() -> SCNNode {
        let jukebox = makeJukebox()
        let authoredBase = SIMD3<Float>(1.18, floorTopY, 0.3)
        for child in jukebox.childNodes {
            child.simdPosition -= authoredBase
        }
        return jukebox
    }

    // MARK: - Hull

    private static func appendHull(to room: SCNNode) {
        let hull = material(
            diffuse: NSColor(calibratedWhite: 0.16, alpha: 1),
            metalness: 0.6,
            roughness: 0.55
        )
        let trim = material(
            diffuse: NSColor(calibratedWhite: 0.07, alpha: 1),
            metalness: 0.5,
            roughness: 0.7
        )
        let deck = material(
            diffuse: NSColor(calibratedWhite: 0.13, alpha: 1),
            metalness: 0.5,
            roughness: 0.65
        )
        let amberLight = material(
            diffuse: NSColor(calibratedRed: 1, green: 0.62, blue: 0.22, alpha: 1),
            metalness: 0,
            roughness: 0.3,
            emissive: NSColor(calibratedRed: 1, green: 0.5, blue: 0.12, alpha: 1)
        )

        // Floor slab; the front half forms an open stage apron.
        room.addChildNode(node(
            name: "hull-floor",
            geometry: SCNBox(width: 3.6, height: 0.12, length: 3.6, chamferRadius: 0.02),
            material: deck,
            position: SIMD3<Float>(0, 0.06, 0)
        ))
        // Left and right walls run from the back wall to the open front.
        let sideSigns: [Float] = [-1, 1]
        for sign in sideSigns {
            let sideName = sign < 0 ? "hull-wall-left" : "hull-wall-right"
            room.addChildNode(node(
                name: sideName,
                geometry: SCNBox(width: 0.14, height: 2.2, length: 3.3, chamferRadius: 0.01),
                material: hull,
                position: SIMD3<Float>(sign * 1.57, 1.22, -0.15)
            ))
        }
        // Back wall split around the center airlock opening.
        room.addChildNode(node(
            name: "hull-wall-back-left",
            geometry: SCNBox(width: 1.2, height: 2.2, length: 0.14, chamferRadius: 0.01),
            material: hull,
            position: SIMD3<Float>(-1.1, 1.22, -1.57)
        ))
        room.addChildNode(node(
            name: "hull-wall-back-right",
            geometry: SCNBox(width: 1.2, height: 2.2, length: 0.14, chamferRadius: 0.01),
            material: hull,
            position: SIMD3<Float>(1.1, 1.22, -1.57)
        ))
        // Structural ribs carry the warm living lights above the cabin.
        let ribs: [(name: String, z: Float)] = [
            ("rib-back", -1.15),
            ("rib-mid", -0.35),
        ]
        for rib in ribs {
            room.addChildNode(node(
                name: rib.name,
                geometry: SCNBox(width: 3.0, height: 0.14, length: 0.16, chamferRadius: 0.03),
                material: hull,
                position: SIMD3<Float>(0, 2.39, rib.z)
            ))
            room.addChildNode(node(
                name: "\(rib.name)-amber-light",
                geometry: SCNBox(width: 2.7, height: 0.02, length: 0.1, chamferRadius: 0.01),
                material: amberLight,
                position: SIMD3<Float>(0, 2.3, rib.z)
            ))
        }
        // Wall-top trim band completes the low-poly shell.
        room.addChildNode(node(
            name: "hull-trim",
            geometry: SCNBox(width: 3.44, height: 0.06, length: 0.06, chamferRadius: 0.02),
            material: trim,
            position: SIMD3<Float>(0, 2.29, -0.35)
        ))
    }

    // MARK: - Sleep pod (back-left)

    private static func makeSleepPod() -> SCNNode {
        let root = SCNNode()
        root.name = "sleep-pod"

        let hull = material(
            diffuse: NSColor(calibratedWhite: 0.16, alpha: 1),
            metalness: 0.55,
            roughness: 0.55
        )
        let trim = material(
            diffuse: NSColor(calibratedWhite: 0.07, alpha: 1),
            metalness: 0.5,
            roughness: 0.7
        )
        let bedding = material(
            diffuse: NSColor(calibratedRed: 0.42, green: 0.43, blue: 0.47, alpha: 1),
            metalness: 0.05,
            roughness: 0.85
        )
        let amberLight = material(
            diffuse: NSColor(calibratedRed: 1, green: 0.62, blue: 0.22, alpha: 1),
            metalness: 0,
            roughness: 0.3,
            emissive: NSColor(calibratedRed: 1, green: 0.5, blue: 0.12, alpha: 1)
        )

        root.addChildNode(node(
            name: "bed-base",
            geometry: SCNBox(width: 1.0, height: 0.2, length: 0.66, chamferRadius: 0.02),
            material: hull,
            position: SIMD3<Float>(-1.0, 0.22, -1.15)
        ))
        root.addChildNode(node(
            name: "mattress",
            geometry: SCNBox(width: 0.9, height: 0.12, length: 0.56, chamferRadius: 0.04),
            material: bedding,
            position: SIMD3<Float>(-1.0, 0.38, -1.15)
        ))
        root.addChildNode(node(
            name: "pillow",
            geometry: SCNBox(width: 0.4, height: 0.09, length: 0.34, chamferRadius: 0.04),
            material: bedding,
            position: SIMD3<Float>(-1.26, 0.48, -1.08)
        ))
        root.addChildNode(node(
            name: "headboard",
            geometry: SCNBox(width: 1.0, height: 0.5, length: 0.08, chamferRadius: 0.02),
            material: trim,
            position: SIMD3<Float>(-1.0, 0.6, -1.44)
        ))
        root.addChildNode(node(
            name: "alcove-side",
            geometry: SCNBox(width: 0.08, height: 0.8, length: 0.72, chamferRadius: 0.01),
            material: hull,
            position: SIMD3<Float>(-1.46, 0.62, -1.08)
        ))
        root.addChildNode(node(
            name: "night-light",
            geometry: SCNBox(width: 0.05, height: 0.05, length: 0.04, chamferRadius: 0.01),
            material: amberLight,
            position: SIMD3<Float>(-1.42, 0.88, -0.9)
        ))
        root.addChildNode(node(
            name: "headboard-light",
            geometry: SCNBox(width: 0.8, height: 0.02, length: 0.03, chamferRadius: 0.01),
            material: amberLight,
            position: SIMD3<Float>(-1.0, 0.87, -1.4)
        ))
        return root
    }

    // MARK: - Workbench console (back-right)

    private static func makeWorkbenchConsole() -> SCNNode {
        let root = SCNNode()
        root.name = "workbench-console"

        let hull = material(
            diffuse: NSColor(calibratedWhite: 0.16, alpha: 1),
            metalness: 0.55,
            roughness: 0.55
        )
        let trim = material(
            diffuse: NSColor(calibratedWhite: 0.07, alpha: 1),
            metalness: 0.5,
            roughness: 0.7
        )
        let steel = material(
            diffuse: NSColor(calibratedWhite: 0.72, alpha: 1),
            metalness: 0.9,
            roughness: 0.3
        )
        let cyanEquipment = material(
            diffuse: NSColor(calibratedRed: 0.05, green: 0.85, blue: 0.95, alpha: 1),
            metalness: 0,
            roughness: 0.3,
            emissive: NSColor(calibratedRed: 0, green: 0.75, blue: 0.9, alpha: 1)
        )

        // Desk and pedestal against the back-right wall.
        root.addChildNode(node(
            name: "desk-top",
            geometry: SCNBox(width: 1.0, height: 0.06, length: 0.5, chamferRadius: 0.01),
            material: hull,
            position: SIMD3<Float>(0.95, 0.78, -1.18)
        ))
        root.addChildNode(node(
            name: "pedestal",
            geometry: SCNBox(width: 0.35, height: 0.63, length: 0.44, chamferRadius: 0.01),
            material: trim,
            position: SIMD3<Float>(1.28, 0.435, -1.18)
        ))
        // Monitor faces the operator at the center of the room.
        root.addChildNode(node(
            name: "monitor-base",
            geometry: SCNBox(width: 0.28, height: 0.04, length: 0.14, chamferRadius: 0.01),
            material: steel,
            position: SIMD3<Float>(0.95, 0.83, -1.39)
        ))
        root.addChildNode(node(
            name: "monitor-neck",
            geometry: SCNBox(width: 0.06, height: 0.12, length: 0.06, chamferRadius: 0.01),
            material: steel,
            position: SIMD3<Float>(0.95, 0.87, -1.39)
        ))
        root.addChildNode(node(
            name: "monitor",
            geometry: SCNBox(width: 0.92, height: 0.5, length: 0.06, chamferRadius: 0.01),
            material: trim,
            position: SIMD3<Float>(0.95, 1.15, -1.39)
        ))
        root.addChildNode(node(
            name: "monitor-screen",
            geometry: SCNBox(width: 0.84, height: 0.4, length: 0.02, chamferRadius: 0.005),
            material: cyanEquipment,
            position: SIMD3<Float>(0.95, 1.15, -1.375)
        ))
        root.addChildNode(node(
            name: "keyboard",
            geometry: SCNBox(width: 0.4, height: 0.02, length: 0.13, chamferRadius: 0.005),
            material: steel,
            position: SIMD3<Float>(0.95, 0.82, -1.05)
        ))
        root.addChildNode(node(
            name: "chair-seat",
            geometry: SCNCylinder(radius: 0.27, height: 0.1),
            material: hull,
            position: SIMD3<Float>(0.95, 0.17, -0.75)
        ))
        root.addChildNode(node(
            name: "console-status",
            geometry: SCNBox(width: 0.05, height: 0.05, length: 0.02, chamferRadius: 0.01),
            material: cyanEquipment,
            position: SIMD3<Float>(0.62, 0.835, -0.92)
        ))
        return root
    }

    // MARK: - Jukebox (right side)

    private static func makeJukebox() -> SCNNode {
        let root = SCNNode()
        root.name = "jukebox"

        let hull = material(
            diffuse: NSColor(calibratedWhite: 0.16, alpha: 1),
            metalness: 0.55,
            roughness: 0.55
        )
        let trim = material(
            diffuse: NSColor(calibratedWhite: 0.07, alpha: 1),
            metalness: 0.5,
            roughness: 0.7
        )
        let steel = material(
            diffuse: NSColor(calibratedWhite: 0.72, alpha: 1),
            metalness: 0.9,
            roughness: 0.3
        )
        let amberLight = material(
            diffuse: NSColor(calibratedRed: 1, green: 0.62, blue: 0.22, alpha: 1),
            metalness: 0,
            roughness: 0.3,
            emissive: NSColor(calibratedRed: 1, green: 0.5, blue: 0.12, alpha: 1)
        )

        root.addChildNode(node(
            name: "plinth",
            geometry: SCNBox(width: 0.5, height: 0.1, length: 0.42, chamferRadius: 0.02),
            material: trim,
            position: SIMD3<Float>(1.18, 0.17, 0.3)
        ))
        root.addChildNode(node(
            name: "body",
            geometry: SCNBox(width: 0.44, height: 1.06, length: 0.36, chamferRadius: 0.03),
            material: hull,
            position: SIMD3<Float>(1.18, 0.75, 0.3)
        ))
        root.addChildNode(node(
            name: "top-cap",
            geometry: SCNBox(width: 0.38, height: 0.05, length: 0.3, chamferRadius: 0.02),
            material: steel,
            position: SIMD3<Float>(1.18, 1.305, 0.3)
        ))
        root.addChildNode(node(
            name: "top-light",
            geometry: SCNCylinder(radius: 0.11, height: 0.02),
            material: amberLight,
            position: SIMD3<Float>(1.18, 1.34, 0.3)
        ))
        root.addChildNode(node(
            name: "fascia",
            geometry: SCNBox(width: 0.03, height: 0.88, length: 0.3, chamferRadius: 0.01),
            material: trim,
            position: SIMD3<Float>(0.945, 0.75, 0.3)
        ))
        root.addChildNode(node(
            name: "dial",
            geometry: SCNCylinder(radius: 0.085, height: 0.03),
            material: amberLight,
            position: SIMD3<Float>(0.94, 0.9, 0.3),
            eulerAngles: SIMD3<Float>(0, 0, .pi / 2)
        ))
        let equalizerBars: [(height: CGFloat, z: Float)] = [
            (0.24, 0.17),
            (0.3, 0.3),
            (0.2, 0.43),
        ]
        for (index, bar) in equalizerBars.enumerated() {
            root.addChildNode(node(
                name: "equalizer-bar-\(index)",
                geometry: SCNBox(width: 0.015, height: bar.height, length: 0.05, chamferRadius: 0.007),
                material: amberLight,
                position: SIMD3<Float>(0.94, 0.44, bar.z)
            ))
        }
        return root
    }

    // MARK: - Coffee machine (left side, on a small counter)

    private static func makeCoffeeMachine() -> SCNNode {
        let root = SCNNode()
        root.name = "coffee-machine"

        let hull = material(
            diffuse: NSColor(calibratedWhite: 0.16, alpha: 1),
            metalness: 0.55,
            roughness: 0.55
        )
        let trim = material(
            diffuse: NSColor(calibratedWhite: 0.07, alpha: 1),
            metalness: 0.5,
            roughness: 0.7
        )
        let steel = material(
            diffuse: NSColor(calibratedWhite: 0.72, alpha: 1),
            metalness: 0.9,
            roughness: 0.3
        )
        let cyanEquipment = material(
            diffuse: NSColor(calibratedRed: 0.05, green: 0.85, blue: 0.95, alpha: 1),
            metalness: 0,
            roughness: 0.3,
            emissive: NSColor(calibratedRed: 0, green: 0.75, blue: 0.9, alpha: 1)
        )

        root.addChildNode(node(
            name: "counter-top",
            geometry: SCNBox(width: 0.42, height: 0.05, length: 0.95, chamferRadius: 0.01),
            material: hull,
            position: SIMD3<Float>(-1.27, 0.625, 0.72)
        ))
        root.addChildNode(node(
            name: "cabinet",
            geometry: SCNBox(width: 0.3, height: 0.48, length: 0.75, chamferRadius: 0.01),
            material: trim,
            position: SIMD3<Float>(-1.35, 0.36, 0.72)
        ))
        root.addChildNode(node(
            name: "machine-body",
            geometry: SCNBox(width: 0.22, height: 0.3, length: 0.24, chamferRadius: 0.025),
            material: hull,
            position: SIMD3<Float>(-1.19, 0.8, 0.72)
        ))
        root.addChildNode(node(
            name: "machine-face",
            geometry: SCNBox(width: 0.02, height: 0.2, length: 0.18, chamferRadius: 0.008),
            material: steel,
            position: SIMD3<Float>(-1.075, 0.8, 0.72)
        ))
        root.addChildNode(node(
            name: "brew-button",
            geometry: SCNBox(width: 0.02, height: 0.03, length: 0.03, chamferRadius: 0.008),
            material: cyanEquipment,
            position: SIMD3<Float>(-1.068, 0.88, 0.78)
        ))
        root.addChildNode(node(
            name: "nozzle",
            geometry: SCNCylinder(radius: 0.012, height: 0.09),
            material: steel,
            position: SIMD3<Float>(-1.12, 0.7, 0.5)
        ))
        root.addChildNode(node(
            name: "drip-tray",
            geometry: SCNBox(width: 0.13, height: 0.02, length: 0.15, chamferRadius: 0.009),
            material: steel,
            position: SIMD3<Float>(-1.12, 0.66, 0.5)
        ))
        root.addChildNode(node(
            name: "cup",
            geometry: SCNCylinder(radius: 0.025, height: 0.06),
            material: steel,
            position: SIMD3<Float>(-1.0, 0.68, 0.4)
        ))
        return root
    }

    // MARK: - Viewport (port wall, looking out at the stars)

    private static func makeViewport() -> SCNNode {
        let root = SCNNode()
        root.name = "viewport"

        let trim = material(
            diffuse: NSColor(calibratedWhite: 0.07, alpha: 1),
            metalness: 0.5,
            roughness: 0.7
        )
        let glass = material(
            diffuse: NSColor(calibratedRed: 0.02, green: 0.08, blue: 0.16, alpha: 1),
            metalness: 0.2,
            roughness: 0.2,
            emissive: NSColor(calibratedRed: 0.04, green: 0.2, blue: 0.5, alpha: 1)
        )
        let cyanEquipment = material(
            diffuse: NSColor(calibratedRed: 0.05, green: 0.85, blue: 0.95, alpha: 1),
            metalness: 0,
            roughness: 0.3,
            emissive: NSColor(calibratedRed: 0, green: 0.75, blue: 0.9, alpha: 1)
        )

        root.addChildNode(node(
            name: "frame",
            geometry: SCNBox(width: 0.12, height: 1.1, length: 1.5, chamferRadius: 0.02),
            material: trim,
            position: SIMD3<Float>(-1.44, 1.35, -0.1)
        ))
        root.addChildNode(node(
            name: "glass",
            geometry: SCNBox(width: 0.03, height: 0.9, length: 1.28, chamferRadius: 0.01),
            material: glass,
            position: SIMD3<Float>(-1.415, 1.35, -0.1)
        ))
        root.addChildNode(node(
            name: "sill",
            geometry: SCNBox(width: 0.24, height: 0.05, length: 1.5, chamferRadius: 0.02),
            material: trim,
            position: SIMD3<Float>(-1.31, 0.775, -0.1)
        ))
        root.addChildNode(node(
            name: "rim-light",
            geometry: SCNBox(width: 0.05, height: 0.05, length: 1.36, chamferRadius: 0.02),
            material: cyanEquipment,
            position: SIMD3<Float>(-1.39, 1.92, -0.1)
        ))
        root.addChildNode(node(
            name: "status-lamp",
            geometry: SCNBox(width: 0.06, height: 0.06, length: 0.03, chamferRadius: 0.01),
            material: cyanEquipment,
            position: SIMD3<Float>(-1.39, 1.0, 0.62)
        ))
        return root
    }

    // MARK: - Airlock (rear bulkhead)

    private static func makeAirlock() -> SCNNode {
        let root = SCNNode()
        root.name = "airlock"

        let trim = material(
            diffuse: NSColor(calibratedWhite: 0.07, alpha: 1),
            metalness: 0.5,
            roughness: 0.7
        )
        let steel = material(
            diffuse: NSColor(calibratedWhite: 0.66, alpha: 1),
            metalness: 0.9,
            roughness: 0.3
        )
        let cyanEquipment = material(
            diffuse: NSColor(calibratedRed: 0.05, green: 0.85, blue: 0.95, alpha: 1),
            metalness: 0,
            roughness: 0.3,
            emissive: NSColor(calibratedRed: 0, green: 0.75, blue: 0.9, alpha: 1)
        )

        root.addChildNode(node(
            name: "housing",
            geometry: SCNBox(width: 1.0, height: 2.2, length: 0.14, chamferRadius: 0.02),
            material: trim,
            position: SIMD3<Float>(0, 1.22, -1.57)
        ))
        root.addChildNode(node(
            name: "hatch",
            geometry: SCNCylinder(radius: 0.34, height: 0.07),
            material: steel,
            position: SIMD3<Float>(0, 1.22, -1.49),
            eulerAngles: SIMD3<Float>(.pi / 2, 0, 0)
        ))
        root.addChildNode(node(
            name: "hatch-seal",
            geometry: SCNTorus(ringRadius: 0.34, pipeRadius: 0.02),
            material: trim,
            position: SIMD3<Float>(0, 1.22, -1.485),
            eulerAngles: SIMD3<Float>(.pi / 2, 0, 0)
        ))
        root.addChildNode(node(
            name: "hatch-window",
            geometry: SCNCylinder(radius: 0.07, height: 0.02),
            material: cyanEquipment,
            position: SIMD3<Float>(0, 1.34, -1.46),
            eulerAngles: SIMD3<Float>(.pi / 2, 0, 0)
        ))
        root.addChildNode(node(
            name: "handle",
            geometry: SCNBox(width: 0.03, height: 0.26, length: 0.06, chamferRadius: 0.01),
            material: steel,
            position: SIMD3<Float>(0.17, 1.24, -1.45)
        ))
        root.addChildNode(node(
            name: "status-light-top",
            geometry: SCNBox(width: 0.04, height: 0.04, length: 0.02, chamferRadius: 0.008),
            material: cyanEquipment,
            position: SIMD3<Float>(0.4, 1.5, -1.49)
        ))
        root.addChildNode(node(
            name: "status-light-bottom",
            geometry: SCNBox(width: 0.04, height: 0.04, length: 0.02, chamferRadius: 0.008),
            material: cyanEquipment,
            position: SIMD3<Float>(0.4, 1.34, -1.49)
        ))
        return root
    }

    // MARK: - SceneKit helpers (same idiom as PMXWorldPropFactory)

    private static func node(
        name: String,
        geometry: SCNGeometry,
        material: SCNMaterial,
        position: SIMD3<Float>,
        eulerAngles: SIMD3<Float> = .zero
    ) -> SCNNode {
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = name
        node.simdPosition = position
        node.simdEulerAngles = eulerAngles
        node.castsShadow = true
        return node
    }

    private static func material(
        diffuse: NSColor,
        metalness: CGFloat,
        roughness: CGFloat,
        emissive: NSColor? = nil
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = diffuse
        material.metalness.contents = metalness
        material.roughness.contents = roughness
        material.lightingModel = .physicallyBased
        if let emissive {
            material.emission.contents = emissive
        }
        return material
    }
}

private final class PMXDecodedModelBox: @unchecked Sendable {
    let model: MMDNode

    init(_ model: MMDNode) {
        self.model = model
    }
}

private final class PMXDecodedMotionBox: @unchecked Sendable {
    let motion: CAAnimationGroup

    init(_ motion: CAAnimationGroup) {
        self.motion = motion
    }
}

private enum PMXAssetDecoding {
    static func model(from url: URL) throws -> PMXDecodedModelBox {
        let fileName = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw PMXStageAvatarRenderer.LoadError.cannotReadModel(
                fileName: fileName
            )
        }
        guard MMDFileType.detect(in: data) == .pmx else {
            throw PMXStageAvatarRenderer.LoadError.invalidModel(
                fileName: fileName
            )
        }
        guard
            let source = MMDSceneSource(url: url),
            source.fileType == .pmx,
            let model = source.getModel()
        else {
            throw PMXStageAvatarRenderer.LoadError.invalidModel(
                fileName: fileName
            )
        }
        return PMXDecodedModelBox(model)
    }

    static func motion(from url: URL) throws -> PMXDecodedMotionBox {
        let fileName = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw PMXStageAvatarRenderer.LoadError.cannotReadMotion(
                fileName: fileName
            )
        }
        guard MMDFileType.detect(in: data) == .vmd else {
            throw PMXStageAvatarRenderer.LoadError.invalidMotion(
                fileName: fileName
            )
        }
        guard
            let source = MMDSceneSource(url: url),
            source.fileType == .vmd,
            let motion = source.getMotion()
        else {
            throw PMXStageAvatarRenderer.LoadError.invalidMotion(
                fileName: fileName
            )
        }
        return PMXDecodedMotionBox(motion)
    }
}

public struct PMXAvatarBounds: Equatable, Sendable {
    public let minimum: SIMD3<Float>
    public let maximum: SIMD3<Float>

    public init(minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public var center: SIMD3<Float> {
        (minimum + maximum) * 0.5
    }

    public var size: SIMD3<Float> {
        maximum - minimum
    }
}

enum PMXAnimatedGrounding {
    static func localOffsetY(
        restFootReferenceY: Float,
        animatedFootReferenceY: Float
    ) -> Float {
        guard restFootReferenceY.isFinite,
              animatedFootReferenceY.isFinite
        else {
            return 0
        }
        return restFootReferenceY - animatedFootReferenceY
    }
}

enum PMXFullStageGroundingPolicy {
    /// Root-locked choreography already owns the body's vertical pose. Feeding
    /// an asynchronously sampled presentation-tree sole height back into the
    /// next frame translates the whole model and can make it alternate above
    /// and below its authored world Y. Dynamic compensation is only valid when
    /// root motion is intentionally enabled.
    static func offset(
        rootMotionEnabled: Bool,
        animatedOffset: Float
    ) -> Float {
        guard rootMotionEnabled, animatedOffset.isFinite else { return 0 }
        return animatedOffset
    }
}

enum PMXBoneRotationRetargeting {
    static func hierarchyAwareOrientation(
        sourceDelta: simd_quatf,
        parentSourceToTargetBasis: simd_quatf,
        sourceToTargetBasis: simd_quatf,
        targetRestOrientation: simd_quatf
    ) -> simd_quatf {
        simd_normalize(
            parentSourceToTargetBasis
                * sourceDelta
                * sourceToTargetBasis.inverse
                * targetRestOrientation
        )
    }

    static func orientation(
        sourceDelta: simd_quatf,
        sourceRestDirection: SIMD3<Float>,
        sourceSecondaryDirection: SIMD3<Float>? = nil,
        targetRestOrientation: simd_quatf,
        targetChildDirection: SIMD3<Float>,
        targetRestSecondaryDirection: SIMD3<Float>? = nil,
        requiresSecondaryFrame: Bool = false
    ) -> simd_quatf {
        let targetRest = normalized(
            targetRestOrientation,
            fallback: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        )
        let delta = normalized(
            sourceDelta,
            fallback: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        )
        let targetRestDirection = targetRest.act(targetChildDirection)
        guard isUsable(sourceRestDirection),
              isUsable(targetRestDirection)
        else {
            return simd_normalize(targetRest * delta)
        }

        let sourceToTargetBasis: simd_quatf
        if let sourceSecondaryDirection,
           let targetRestSecondaryDirection,
           let sourceFrame = orthonormalFrame(
               primary: sourceRestDirection,
               secondary: sourceSecondaryDirection
           ),
           let targetFrame = orthonormalFrame(
               primary: targetRestDirection,
               secondary: targetRestSecondaryDirection
           )
        {
            sourceToTargetBasis = simd_quatf(
                targetFrame * sourceFrame.transpose
            )
        } else if requiresSecondaryFrame {
            return targetRest
        } else {
            sourceToTargetBasis = simd_quatf(
                from: simd_normalize(sourceRestDirection),
                to: simd_normalize(targetRestDirection)
            )
        }
        let retargetedDelta = sourceToTargetBasis
            * delta
            * sourceToTargetBasis.inverse
        return simd_normalize(retargetedDelta * targetRest)
    }

    private static func normalized(
        _ quaternion: simd_quatf,
        fallback: simd_quatf
    ) -> simd_quatf {
        let vector = quaternion.vector
        guard vector.x.isFinite,
              vector.y.isFinite,
              vector.z.isFinite,
              vector.w.isFinite,
              simd_length_squared(vector) > 0.000001
        else {
            return fallback
        }
        return simd_normalize(quaternion)
    }

    private static func isUsable(_ direction: SIMD3<Float>) -> Bool {
        direction.x.isFinite
            && direction.y.isFinite
            && direction.z.isFinite
            && simd_length_squared(direction) > 0.000001
    }

    private static func orthonormalFrame(
        primary: SIMD3<Float>,
        secondary: SIMD3<Float>
    ) -> simd_float3x3? {
        guard isUsable(primary), isUsable(secondary) else { return nil }
        let x = simd_normalize(primary)
        let rejected = secondary - simd_dot(secondary, x) * x
        guard isUsable(rejected) else { return nil }
        let z = simd_normalize(rejected)
        let y = simd_normalize(simd_cross(z, x))
        guard isUsable(y) else { return nil }
        return simd_float3x3(columns: (x, y, z))
    }
}

@MainActor
struct PMXSoleProbe {
    struct Influence {
        let bone: SCNNode
        let localPosition: SIMD3<Float>
        let weight: Float
    }

    let influences: [Influence]
}

struct PMXGeometrySourceReader {
    private let data: Data
    let vectorCount: Int
    let usesFloatComponents: Bool
    let componentsPerVector: Int
    let bytesPerComponent: Int
    let dataOffset: Int
    let dataStride: Int

    init(source: SCNGeometrySource) {
        data = source.data
        vectorCount = source.vectorCount
        usesFloatComponents = source.usesFloatComponents
        componentsPerVector = source.componentsPerVector
        bytesPerComponent = source.bytesPerComponent
        dataOffset = source.dataOffset
        dataStride = source.dataStride
    }

    func vector3(at index: Int) -> SIMD3<Float>? {
        guard componentsPerVector >= 3,
              let x = floatComponent(vector: index, component: 0),
              let y = floatComponent(vector: index, component: 1),
              let z = floatComponent(vector: index, component: 2)
        else {
            return nil
        }
        return SIMD3<Float>(x, y, z)
    }

    func floatComponent(vector: Int, component: Int) -> Float? {
        guard usesFloatComponents,
              bytesPerComponent == MemoryLayout<Float>.size,
              let offset = componentOffset(
                  vector: vector,
                  component: component
              ),
              offset + MemoryLayout<UInt32>.size <= data.count
        else {
            return nil
        }
        return data.withUnsafeBytes { buffer in
            let raw = buffer.loadUnaligned(
                fromByteOffset: offset,
                as: UInt32.self
            )
            return Float(bitPattern: UInt32(littleEndian: raw))
        }
    }

    func unsignedComponent(vector: Int, component: Int) -> Int? {
        guard !usesFloatComponents,
              let offset = componentOffset(
                  vector: vector,
                  component: component
              ),
              offset + bytesPerComponent <= data.count
        else {
            return nil
        }
        return data.withUnsafeBytes { buffer -> Int? in
            switch bytesPerComponent {
            case 1:
                return Int(buffer[offset])
            case 2:
                let raw = buffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt16.self
                )
                return Int(UInt16(littleEndian: raw))
            case 4:
                let raw = buffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt32.self
                )
                return Int(UInt32(littleEndian: raw))
            default:
                return nil
            }
        }
    }

    private func componentOffset(vector: Int, component: Int) -> Int? {
        guard vector >= 0,
              vector < vectorCount,
              component >= 0,
              component < componentsPerVector
        else {
            return nil
        }
        return dataOffset
            + vector * dataStride
            + component * bytesPerComponent
    }
}

@MainActor
enum PMXSoleGrounding {
    static func isFootBoneName(_ name: String?) -> Bool {
        guard let name else { return false }
        let normalized = name
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        if normalized.contains("足首") || normalized.contains("つま先")
            || normalized.contains("ankle") || normalized.contains("toe")
        {
            return true
        }
        return ["bone017", "bone018", "bone021", "bone022"]
            .contains(normalized)
    }

    static func referenceY(
        probes: [PMXSoleProbe],
        in model: MMDNode,
        usesPresentationTree: Bool
    ) -> Float? {
        guard !probes.isEmpty else {
            return nil
        }
        let modelSpace: SCNNode = usesPresentationTree
            ? model.presentation
            : model
        let values = probes.compactMap { probe -> Float? in
            var position = SIMD3<Float>.zero
            var totalWeight: Float = 0
            for influence in probe.influences where influence.weight > 0 {
                let bone: SCNNode = usesPresentationTree
                    ? influence.bone.presentation
                    : influence.bone
                let transformed = bone.simdConvertPosition(
                    influence.localPosition,
                    to: modelSpace
                )
                guard transformed.x.isFinite,
                      transformed.y.isFinite,
                      transformed.z.isFinite
                else {
                    continue
                }
                position += transformed * influence.weight
                totalWeight += influence.weight
            }
            guard totalWeight > 0 else {
                return nil
            }
            return (position / totalWeight).y
        }
        return values.min()
    }

    static func makeProbes(
        in model: MMDNode,
        bounds: PMXAvatarBounds?
    ) -> [PMXSoleProbe] {
        let height = max(bounds?.size.y ?? 1, 0.001)
        let soleBand = max(height * 0.005, 0.001)
        var result: [PMXSoleProbe] = []

        model.enumerateHierarchy { node, _ in
            guard let skinner = node.skinner,
                  let geometry = skinner.baseGeometry,
                  let vertexSource = geometry.sources(for: .vertex).first
            else {
                return
            }
            let weightsSource = skinner.boneWeights
            let indicesSource = skinner.boneIndices
            let vertexReader = PMXGeometrySourceReader(
                source: vertexSource
            )
            let weightsReader = PMXGeometrySourceReader(
                source: weightsSource
            )
            let indicesReader = PMXGeometrySourceReader(
                source: indicesSource
            )
            let count = min(
                vertexReader.vectorCount,
                weightsReader.vectorCount,
                indicesReader.vectorCount
            )
            guard count > 0 else {
                return
            }

            var modelPositions = [SIMD3<Float>]()
            modelPositions.reserveCapacity(count)
            var minimumY = Float.greatestFiniteMagnitude
            var footVertexIndices = Set<Int>()
            for index in 0 ..< count {
                guard let localPosition = vertexReader.vector3(
                    at: index
                ) else {
                    modelPositions.append(
                        SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                    )
                    continue
                }
                let modelPosition = node.simdConvertPosition(
                    localPosition,
                    to: model
                )
                modelPositions.append(modelPosition)
                minimumY = min(minimumY, modelPosition.y)

                let componentCount = min(
                    weightsReader.componentsPerVector,
                    indicesReader.componentsPerVector
                )
                for component in 0 ..< componentCount {
                    guard let weight = weightsReader.floatComponent(
                        vector: index,
                        component: component
                    ), weight > 0.05,
                    let boneIndex = indicesReader.unsignedComponent(
                        vector: index,
                        component: component
                    ), boneIndex < skinner.bones.count,
                    isFootBoneName(skinner.bones[boneIndex].name)
                    else {
                        continue
                    }
                    footVertexIndices.insert(index)
                    break
                }
            }
            guard minimumY.isFinite else {
                return
            }

            let footMinimumY = footVertexIndices
                .map { modelPositions[$0].y }
                .filter(\.isFinite)
                .min()
            let selectedMinimumY = footMinimumY ?? minimumY

            for index in 0 ..< count
            where (footVertexIndices.isEmpty || footVertexIndices.contains(index))
                && modelPositions[index].y <= selectedMinimumY + soleBand {
                let modelPosition = modelPositions[index]
                var influences: [PMXSoleProbe.Influence] = []
                let componentCount = min(
                    weightsReader.componentsPerVector,
                    indicesReader.componentsPerVector
                )
                for component in 0 ..< componentCount {
                    guard let weight = weightsReader.floatComponent(
                        vector: index,
                        component: component
                    ), weight > 0.001,
                    let boneIndex = indicesReader.unsignedComponent(
                        vector: index,
                        component: component
                    ), boneIndex < skinner.bones.count
                    else {
                        continue
                    }
                    let bone = skinner.bones[boneIndex]
                    influences.append(
                        PMXSoleProbe.Influence(
                            bone: bone,
                            localPosition: bone.simdConvertPosition(
                                modelPosition,
                                from: model
                            ),
                            weight: weight
                        )
                    )
                }
                if !influences.isEmpty {
                    result.append(PMXSoleProbe(influences: influences))
                }
            }
        }

        let maximumProbeCount = 96
        guard result.count > maximumProbeCount else {
            return result
        }
        let stride = max(result.count / maximumProbeCount, 1)
        return Swift.stride(from: 0, to: result.count, by: stride)
            .prefix(maximumProbeCount)
            .map { result[$0] }
    }
}

struct PMXRenderTimeline: Equatable, Sendable {
    let maximumStep: TimeInterval
    private(set) var elapsed: TimeInterval = 0
    private var previousTimestamp: TimeInterval?

    init(maximumStep: TimeInterval = 1.0 / 20.0) {
        self.maximumStep = maximumStep
    }

    mutating func advance(to timestamp: TimeInterval) -> TimeInterval {
        guard timestamp.isFinite else {
            return elapsed
        }
        guard let previousTimestamp else {
            self.previousTimestamp = timestamp
            return elapsed
        }
        self.previousTimestamp = timestamp
        let delta = timestamp - previousTimestamp
        guard delta > 0 else {
            return elapsed
        }
        elapsed += min(delta, maximumStep)
        return elapsed
    }

    mutating func restartAnimationClock() {
        elapsed = 0
        previousTimestamp = nil
    }
}

struct PMXOneShotMotionPlayback: Equatable, Sendable {
    let url: URL
    let finishTime: TimeInterval
    private(set) var didFinish = false

    static func begin(
        url: URL,
        duration: TimeInterval,
        currentTime: TimeInterval,
        repeats: Bool
    ) -> Self? {
        guard !repeats, duration.isFinite, duration > 0 else { return nil }
        return Self(url: url, finishTime: currentTime + duration)
    }

    mutating func finishIfNeeded(at time: TimeInterval) -> URL? {
        guard !didFinish, time >= finishTime else { return nil }
        didFinish = true
        return url
    }
}

struct PMXMotionPlaybackReport: Equatable, Sendable {
    let boneName: String
    let maximumRotationDelta: Float
}

struct PMXMotionPlaybackProbe: Equatable, Sendable {
    let boneName: String
    let reportAfter: TimeInterval
    private var firstTime: TimeInterval?
    private var firstOrientation: simd_quatf?
    private var maximumRotationDelta: Float = 0
    private var didReport = false

    init(boneName: String, reportAfter: TimeInterval = 0.45) {
        self.boneName = boneName
        self.reportAfter = reportAfter
    }

    mutating func record(
        time: TimeInterval,
        orientation: simd_quatf
    ) -> PMXMotionPlaybackReport? {
        let vector = orientation.vector
        guard !didReport,
              vector.x.isFinite,
              vector.y.isFinite,
              vector.z.isFinite,
              vector.w.isFinite
        else {
            return nil
        }
        guard let firstTime, let firstOrientation else {
            self.firstTime = time
            self.firstOrientation = orientation
            return nil
        }
        let dot = min(abs(simd_dot(
            simd_normalize(firstOrientation).vector,
            simd_normalize(orientation).vector
        )), 1)
        maximumRotationDelta = max(
            maximumRotationDelta,
            2 * acos(dot)
        )
        guard time - firstTime >= reportAfter else { return nil }
        didReport = true
        return PMXMotionPlaybackReport(
            boneName: boneName,
            maximumRotationDelta: maximumRotationDelta
        )
    }
}

enum PMXLightingProfile: Equatable, Sendable {
    case neutralDesktop
    case warmInterior
}

enum PMXAvatarLightingPolicy {
    static func resolve(
        renderProfile: LiveCamRenderProfile,
        worldLighting: PMXLightingProfile?
    ) -> PMXLightingProfile {
        switch renderProfile {
        case .liveCam:
            .neutralDesktop
        case .fullStage:
            worldLighting ?? .neutralDesktop
        }
    }
}

@MainActor
public final class PMXStageAvatarRenderer {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.gmgn.radio",
        category: "PMXStageAvatarRenderer"
    )
    public struct Configuration: Equatable, Sendable {
        public var rootMotionEnabled: Bool

        public init(rootMotionEnabled: Bool = false) {
            self.rootMotionEnabled = rootMotionEnabled
        }

        public static let `default` = Configuration()
    }

    public enum Compatibility: Equatable, Sendable {
        case compatible
        case incompatible(reason: String)
    }

    public enum MotionLoadFailurePolicy: Equatable, Sendable {
        case preserveCurrentMotion
    }

    public struct CameraConfiguration: Sendable {
        public let worldTransform: simd_float4x4
        public let projectionTransform: simd_float4x4
    }

    public enum LoadError: Error, Equatable, LocalizedError, Sendable {
        case unsupportedModel(fileName: String)
        case modelOutsideResourceRoot(fileName: String)
        case cannotReadModel(fileName: String)
        case invalidModel(fileName: String)
        case unsupportedMotion(fileName: String)
        case cannotReadMotion(fileName: String)
        case invalidMotion(fileName: String)
        case modelNotLoaded

        public var errorDescription: String? {
            switch self {
            case let .unsupportedModel(fileName):
                String(
                    format: NSLocalizedString(
                        "无法加载“%@”：请选择 .pmx 模型。",
                        comment: "Unsupported PMX model file"
                    ),
                    fileName
                )
            case let .modelOutsideResourceRoot(fileName):
                String(
                    format: NSLocalizedString(
                        "无法加载 PMX 模型“%@”：模型必须位于角色资源目录中。",
                        comment: "PMX model outside its resource root"
                    ),
                    fileName
                )
            case let .cannotReadModel(fileName):
                String(
                    format: NSLocalizedString(
                        "无法读取 PMX 模型“%@”。",
                        comment: "Unreadable PMX model file"
                    ),
                    fileName
                )
            case let .invalidModel(fileName):
                String(
                    format: NSLocalizedString(
                        "PMX 模型“%@”格式无效。",
                        comment: "Invalid PMX model file"
                    ),
                    fileName
                )
            case let .unsupportedMotion(fileName):
                String(
                    format: NSLocalizedString(
                        "无法加载“%@”：PMX 模型目前只支持 .vmd 动作。",
                        comment: "Unsupported PMX motion file"
                    ),
                    fileName
                )
            case let .cannotReadMotion(fileName):
                String(
                    format: NSLocalizedString(
                        "无法读取 VMD 动作“%@”。",
                        comment: "Unreadable VMD motion file"
                    ),
                    fileName
                )
            case let .invalidMotion(fileName):
                String(
                    format: NSLocalizedString(
                        "VMD 动作“%@”格式无效。",
                        comment: "Invalid VMD motion file"
                    ),
                    fileName
                )
            case .modelNotLoaded:
                NSLocalizedString(
                    "请先加载 PMX 模型，再加载动作。",
                    comment: "A PMX model is required before loading motion"
                )
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .unsupportedModel, .invalidModel:
                NSLocalizedString(
                    "请重新选择有效的 PMX 2.0 或 2.1 模型。",
                    comment: "PMX model recovery suggestion"
                )
            case .modelOutsideResourceRoot:
                NSLocalizedString(
                    "请把模型及其贴图放在同一个角色资源目录中，再重新选择。",
                    comment: "PMX resource root recovery suggestion"
                )
            case .cannotReadModel, .cannotReadMotion:
                NSLocalizedString(
                    "请确认文件仍在原位置，并且当前用户有读取权限。",
                    comment: "Unreadable MMD file recovery suggestion"
                )
            case .unsupportedMotion, .invalidMotion:
                NSLocalizedString(
                    "请重新选择有效的 VMD 动作。",
                    comment: "VMD motion recovery suggestion"
                )
            case .modelNotLoaded:
                nil
            }
        }
    }

    public private(set) var localBounds: PMXAvatarBounds?
    public private(set) var loadedModelURL: URL?
    public private(set) var loadedMotionURL: URL?
    public private(set) var isUsingNaturalIdle = false
    public private(set) var localGroundingOffsetY: Float = 0
    public private(set) var animatedRootOffset = SIMD3<Float>.zero
    public var onMotionFinished: (@MainActor (URL) -> Void)?

    public static let motionLoadFailurePolicy: MotionLoadFailurePolicy =
        .preserveCurrentMotion

    public var rootMotionEnabled: Bool {
        configuration.rootMotionEnabled
    }

    private static let motionKey = "gmgn.pmx.vmd-motion"
    private static let naturalIdleKey = "gmgn.pmx.natural-idle"
    private static let naturalIdleDuration: TimeInterval = 4.8
    private static let raw2BLeftFootIKTargetName =
        "gmgn_raw2b_left_foot_ik"
    private static let raw2BRightFootIKTargetName =
        "gmgn_raw2b_right_foot_ik"
    private static let raw2BGrooveName = "gmgn_raw2b_groove"
    private static let standardMMDLegLength: Float = 9.4
    private static let rootBoneNames: Set<String> = [
        "root",
        "master",
        "center",
        "motherbone",
        "センター",
        "全ての親",
        "全親",
    ]
    private static let trackingRootBoneNames = [
        "センター",
        "center",
        "bone000",
        "全ての親",
        "root",
        "master",
        "motherbone",
        "全親",
        "bone4094",
    ]

    private let sceneRenderer: SCNRenderer
    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private let modelContainerNode = SCNNode()
    private let worldPropContainerNode = SCNNode()
    private let ambientLightNode = SCNNode()
    private let keyLightNode = SCNNode()
    private let fillLightNode = SCNNode()
    private var configuration: Configuration
    private var modelNode: MMDNode?
    private var modelRestTransform = matrix_identity_float4x4
    private weak var trackingRootBone: SCNNode?
    private var trackingRootRestPosition = SIMD3<Float>.zero
    public private(set) var restFootReferenceY: Float?
    private var soleProbes: [PMXSoleProbe] = []
    private var renderTimeline = PMXRenderTimeline()
    private var oneShotMotionPlayback: PMXOneShotMotionPlayback?
    private var motionPlaybackProbe: PMXMotionPlaybackProbe?
    private weak var motionPlaybackProbeBone: SCNNode?
    private weak var coffeeCupNode: SCNNode?
    public private(set) var isCoffeeCupVisible = false

    public init(
        device: MTLDevice,
        configuration: Configuration = .default
    ) {
        self.configuration = configuration
        sceneRenderer = SCNRenderer(device: device, options: nil)

        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = false
        cameraNode.name = "gmgn-pmx-camera"
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        modelContainerNode.name = "gmgn-pmx-model-container"
        scene.rootNode.addChildNode(modelContainerNode)

        worldPropContainerNode.name = "gmgn-pmx-world-props"
        let coffeeMachine = PMXWorldPropFactory.coffeeMachine()
        // Scene-root props already share the manifest's absolute world space.
        // Avatar activities are the only placements converted relative to spawn.
        coffeeMachine.simdScale = SIMD3(repeating: PMXWarmKitchenCoffeeMachine.sceneScale)
        coffeeMachine.simdPosition = PMXWarmKitchenCoffeeMachine.scenePosition
        coffeeMachine.simdEulerAngles.y = PMXWarmKitchenCoffeeMachine.sceneYaw
        worldPropContainerNode.addChildNode(coffeeMachine)
        worldPropContainerNode.isHidden = true
        scene.rootNode.addChildNode(worldPropContainerNode)

        ambientLightNode.name = "gmgn-pmx-ambient-light"
        ambientLightNode.light = SCNLight()
        ambientLightNode.light?.type = .ambient
        scene.rootNode.addChildNode(ambientLightNode)

        keyLightNode.name = "gmgn-pmx-key-light"
        keyLightNode.light = SCNLight()
        keyLightNode.light?.type = .directional
        keyLightNode.simdEulerAngles = SIMD3<Float>(-0.72, 0.48, 0)
        scene.rootNode.addChildNode(keyLightNode)

        fillLightNode.name = "gmgn-pmx-fill-light"
        fillLightNode.light = SCNLight()
        fillLightNode.light?.type = .directional
        fillLightNode.simdEulerAngles = SIMD3<Float>(-0.28, -0.86, 0)
        scene.rootNode.addChildNode(fillLightNode)

        scene.background.contents = NSColor.clear
        scene.physicsWorld.timeStep = 1.0 / 60.0
        sceneRenderer.scene = scene
        sceneRenderer.pointOfView = cameraNode
        sceneRenderer.autoenablesDefaultLighting = false
        sceneRenderer.isPlaying = true
        setLightingProfile(.neutralDesktop)
    }

    func setLightingProfile(_ profile: PMXLightingProfile) {
        switch profile {
        case .neutralDesktop:
            ambientLightNode.light?.intensity = 105
            ambientLightNode.light?.color = NSColor(
                calibratedRed: 0.72,
                green: 0.76,
                blue: 0.84,
                alpha: 1
            )
            keyLightNode.light?.intensity = 820
            keyLightNode.light?.color = NSColor(
                calibratedRed: 1,
                green: 0.95,
                blue: 0.90,
                alpha: 1
            )
            fillLightNode.light?.intensity = 210
            fillLightNode.light?.color = NSColor(
                calibratedRed: 0.42,
                green: 0.64,
                blue: 1,
                alpha: 1
            )
        case .warmInterior:
            ambientLightNode.light?.intensity = 125
            ambientLightNode.light?.color = NSColor(
                calibratedRed: 0.90,
                green: 0.69,
                blue: 0.48,
                alpha: 1
            )
            keyLightNode.light?.intensity = 880
            keyLightNode.light?.color = NSColor(
                calibratedRed: 1,
                green: 0.78,
                blue: 0.56,
                alpha: 1
            )
            fillLightNode.light?.intensity = 240
            fillLightNode.light?.color = NSColor(
                calibratedRed: 0.46,
                green: 0.58,
                blue: 0.82,
                alpha: 1
            )
        }
    }

    func setCoffeeMachineVisible(_ isVisible: Bool) {
        let isHidden = !isVisible
        guard worldPropContainerNode.isHidden != isHidden else { return }
        worldPropContainerNode.isHidden = isHidden
    }

    var isCoffeeMachineVisible: Bool {
        !worldPropContainerNode.isHidden
    }

    func setCoffeeCupVisible(_ isVisible: Bool) {
        guard isCoffeeCupVisible != isVisible else { return }
        isCoffeeCupVisible = isVisible
        coffeeCupNode?.isHidden = !isVisible
    }

    /// The cup parents itself to the animated wrist bone the first time it is
    /// requested with a model on stage, so it rides the hand in every render
    /// profile without per-frame transform work.
    private func updateCoffeeCupAttachment() {
        guard isCoffeeCupVisible, let modelNode else { return }
        guard coffeeCupNode == nil else { return }
        guard let wrist = PMXWarmKitchenCoffeeCup.wristBone(in: modelNode)
        else {
            return
        }
        let cup = PMXWorldPropFactory.coffeeCup()
        cup.simdScale = SIMD3(
            repeating: PMXWarmKitchenCoffeeCup.attachmentScale(
                modelHeight: localBounds?.size.y ?? 0
            )
        )
        cup.isHidden = !isCoffeeCupVisible
        wrist.addChildNode(cup)
        coffeeCupNode = cup
    }

    public static func compatibility(
        modelURL: URL,
        motionURL: URL?
    ) -> Compatibility {
        guard modelURL.pathExtension.lowercased() == "pmx" else {
            return .incompatible(
                reason: NSLocalizedString(
                    "PMX 渲染器只能加载 .pmx 模型。",
                    comment: "PMX renderer model compatibility"
                )
            )
        }
        guard let motionURL else {
            return .compatible
        }
        guard motionURL.pathExtension.lowercased() == "vmd" else {
            return .incompatible(
                reason: NSLocalizedString(
                    "PMX 模型目前只支持 .vmd 动作。",
                    comment: "PMX renderer motion compatibility"
                )
            )
        }
        return .compatible
    }

    public static func isModelURL(
        _ modelURL: URL,
        containedIn resourceRootURL: URL
    ) -> Bool {
        let modelComponents = canonicalFileURL(modelURL).pathComponents
        let rootComponents = canonicalFileURL(resourceRootURL).pathComponents
        guard modelComponents.count > rootComponents.count else {
            return false
        }
        return modelComponents.prefix(rootComponents.count)
            .elementsEqual(rootComponents)
    }

    public static func configureSharedStagePass(
        _ descriptor: MTLRenderPassDescriptor
    ) {
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.depthAttachment.loadAction = .load
        descriptor.depthAttachment.storeAction = .store
        if descriptor.stencilAttachment.texture != nil {
            descriptor.stencilAttachment.loadAction = .load
            descriptor.stencilAttachment.storeAction = .store
        }
    }

    public static func cameraConfiguration(
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4
    ) -> CameraConfiguration {
        CameraConfiguration(
            worldTransform: viewMatrix.inverse,
            projectionTransform: projectionMatrix
        )
    }

    public static func motionByApplyingRootLock(
        to motion: CAAnimationGroup
    ) -> CAAnimationGroup {
        guard let copy = motion.copy() as? CAAnimationGroup else {
            return motion
        }
        copy.animations = motion.animations?.compactMap(rootLockedCopy)
        return copy
    }

    /// Navigation owns horizontal world travel. In-place locomotion keeps the
    /// authored vertical bounce and all bone rotations, while removing only
    /// root X/Z translation so a looping clip cannot pull the avatar away from
    /// its waypoint and snap it back at the loop boundary.
    public static func motionByApplyingHorizontalRootLock(
        to motion: CAAnimationGroup
    ) -> CAAnimationGroup {
        guard let copy = motion.copy() as? CAAnimationGroup else {
            return motion
        }
        copy.animations = motion.animations?.compactMap(
            horizontalRootLockedCopy
        )
        return copy
    }

    public static func motionByRemovingSceneTracks(
        from motion: CAAnimationGroup
    ) -> CAAnimationGroup {
        guard let copy = motion.copy() as? CAAnimationGroup else {
            return motion
        }
        copy.animations = motion.animations?.compactMap(modelTrackCopy)
        return copy
    }

    public static func motionByRemovingMorphTracks(
        from motion: CAAnimationGroup
    ) -> CAAnimationGroup {
        guard let copy = motion.copy() as? CAAnimationGroup else {
            return motion
        }
        copy.animations = motion.animations?.compactMap(morphSafeCopy)
        return copy
    }

    @discardableResult
    public static func attachMotion(
        _ motion: CAAnimationGroup,
        to model: MMDNode,
        key: String,
        rootMotionEnabled: Bool,
        inPlace: Bool = false,
        repeats: Bool = true,
        retargetsGeneratedHumanoidMotion: Bool = false
    ) -> TimeInterval {
        let prepared = preparedMotion(
            motion,
            for: model,
            rootMotionEnabled: rootMotionEnabled,
            inPlace: inPlace,
            retargetsGeneratedHumanoidMotion: retargetsGeneratedHumanoidMotion
        )
        prepared.repeatCount = repeats ? .infinity : 0
        prepared.fillMode = .forwards
        prepared.isRemovedOnCompletion = false
        model.removeAnimation(forKey: key, blendOutDuration: 0)
        model.prepareAnimation(prepared, forKey: key)
        model.playPreparedAnimation(forKey: key)
        return prepared.duration
    }

    static func preparedMotion(
        _ motion: CAAnimationGroup,
        for model: MMDNode,
        rootMotionEnabled: Bool,
        inPlace: Bool = false,
        retargetsGeneratedHumanoidMotion: Bool = false
    ) -> CAAnimationGroup {
        let modelOnlyMotion = motionByRemovingSceneTracks(from: motion)
        let renderSafeMotion = model.geometryMorpher == nil
            ? motionByRemovingMorphTracks(from: modelOnlyMotion)
            : modelOnlyMotion
        let placementSafeMotion = inPlace
            ? motionByApplyingHorizontalRootLock(to: renderSafeMotion)
            : renderSafeMotion
        if PMXMaterialCompatibility.isRaw2BModel(model) {
            configureRaw2BGroove(in: model)
            configureRaw2BFootIK(in: model)
            return motionByRetargetingIfNeeded(placementSafeMotion, to: model)
        }
        if retargetsGeneratedHumanoidMotion,
           let retargeted = generatedHumanoidAnimationCopy(
               placementSafeMotion,
               to: model
           ) as? CAAnimationGroup
        {
            return retargeted
        }
        // Preserve every authored root translation axis. The model's world
        // placement remains on its container, while VMD root motion plays in
        // the model's local space on top of that placement.
        return placementSafeMotion
    }

    public static func naturalIdleMotion(
        for model: MMDNode
    ) -> CAAnimationGroup {
        if PMXMaterialCompatibility.isRaw2BModel(model) {
            return raw2BNaturalIdleMotion(for: model)
        }
        var tracks: [CAAnimation] = []
        if let leftArm = firstBone(
            in: model,
            named: ["左腕", "左上腕", "leftarm", "leftupperarm"]
        ) {
            tracks.append(
                naturalIdleTrack(
                    for: leftArm,
                    relaxationAngle: -0.72,
                    breathingAngle: 0.014,
                    axis: SIMD3<Float>(0, 0, 1)
                )
            )
        }
        if let rightArm = firstBone(
            in: model,
            named: ["右腕", "右上腕", "rightarm", "rightupperarm"]
        ) {
            tracks.append(
                naturalIdleTrack(
                    for: rightArm,
                    relaxationAngle: 0.72,
                    breathingAngle: -0.014,
                    axis: SIMD3<Float>(0, 0, 1)
                )
            )
        }
        if let chest = firstBone(
            in: model,
            named: [
                "上半身2",
                "上半身",
                "胸",
                "upperbody2",
                "upperbody",
                "chest",
                "spine",
            ]
        ) {
            tracks.append(
                naturalIdleTrack(
                    for: chest,
                    relaxationAngle: -0.008,
                    breathingAngle: 0.018,
                    axis: SIMD3<Float>(1, 0, 0)
                )
            )
        }
        if let head = firstBone(
            in: model,
            named: ["頭", "head"]
        ) {
            tracks.append(
                naturalIdleTrack(
                    for: head,
                    relaxationAngle: 0,
                    breathingAngle: 0.018,
                    axis: SIMD3<Float>(0, 0, 1)
                )
            )
        }

        let group = CAAnimationGroup()
        group.animations = tracks
        group.duration = naturalIdleDuration
        group.repeatCount = .infinity
        group.usesSceneTimeBase = false
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        return group
    }

    private static func raw2BNaturalIdleMotion(
        for model: MMDNode
    ) -> CAAnimationGroup {
        let group = CAAnimationGroup()
        // The anonymous 2B rig has exporter-specific bone axes. Its safe idle
        // is the authored PMX bind pose; generic rotations deform the complete
        // child chain before any user-selected motion begins.
        group.animations = []
        group.duration = naturalIdleDuration
        group.repeatCount = .infinity
        group.usesSceneTimeBase = false
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        return group
    }

    public static func attachNaturalIdle(
        to model: MMDNode,
        key: String
    ) {
        let idle = naturalIdleMotion(for: model)
        model.removeAnimation(forKey: key, blendOutDuration: 0)
        model.prepareAnimation(idle, forKey: key)
        model.playPreparedAnimation(forKey: key)
    }

    static func attachPhysicsBehaviors(
        of model: MMDNode,
        to scene: SCNScene
    ) {
        model.addPhysicsBehavior(scene: scene)
    }

    static func detachPhysicsBehaviors(
        of model: MMDNode,
        from scene: SCNScene
    ) {
        model.removePhysicsBehavior(scene: scene)
    }

    public func loadModel(
        from url: URL,
        resourceRootURL: URL? = nil
    ) throws {
        try validateModelRequest(url, resourceRootURL: resourceRootURL)
        let decoded = try PMXAssetDecoding.model(from: url)
        installModel(decoded.model, from: url)
    }

    public func loadModel(
        from url: URL,
        resourceRootURL: URL? = nil
    ) async throws {
        try Task.checkCancellation()
        try validateModelRequest(url, resourceRootURL: resourceRootURL)
        // MMDSceneKit builds a SceneKit graph while decoding. That graph must
        // be created and consumed on the same actor: moving it out of an actor
        // executor later corrupts morph, skinning and material state in Metal.
        let decoded = try PMXAssetDecoding.model(from: url)
        try Task.checkCancellation()
        installModel(decoded.model, from: url)
    }

    public func loadMotion(
        from url: URL,
        repeats: Bool = true,
        playbackRate: Float = 1,
        inPlace: Bool = false
    ) throws {
        guard let modelNode else {
            throw LoadError.modelNotLoaded
        }
        try validateMotionRequest(url)
        let decoded = try PMXAssetDecoding.motion(from: url)
        installMotion(
            decoded.motion,
            on: modelNode,
            from: url,
            repeats: repeats,
            playbackRate: playbackRate,
            inPlace: inPlace
        )
    }

    public func loadMotion(
        from url: URL,
        repeats: Bool = true,
        playbackRate: Float = 1,
        inPlace: Bool = false
    ) async throws {
        try Task.checkCancellation()
        guard let targetModel = modelNode else {
            throw LoadError.modelNotLoaded
        }
        try validateMotionRequest(url)
        let decoded = try PMXAssetDecoding.motion(from: url)
        try Task.checkCancellation()
        guard modelNode === targetModel else {
            throw CancellationError()
        }
        installMotion(
            decoded.motion,
            on: targetModel,
            from: url,
            repeats: repeats,
            playbackRate: playbackRate,
            inPlace: inPlace
        )
    }

    private func validateModelRequest(
        _ url: URL,
        resourceRootURL: URL?
    ) throws {
        let fileName = url.lastPathComponent
        guard url.pathExtension.lowercased() == "pmx" else {
            throw LoadError.unsupportedModel(fileName: fileName)
        }
        if let resourceRootURL,
           !Self.isModelURL(url, containedIn: resourceRootURL)
        {
            throw LoadError.modelOutsideResourceRoot(fileName: fileName)
        }
    }

    private func installModel(_ model: MMDNode, from url: URL) {
        if let modelNode {
            Self.detachPhysicsBehaviors(of: modelNode, from: scene)
        }
        modelNode?.removeFromParentNode()
        PMXMaterialCompatibility.prepareForCurrentSceneKit(in: model)
        model.removeAnimation(forKey: Self.motionKey, blendOutDuration: 0)
        model.removeAnimation(
            forKey: Self.naturalIdleKey,
            blendOutDuration: 0
        )
        model.simdTransform = matrix_identity_float4x4
        modelContainerNode.simdTransform = matrix_identity_float4x4
        modelContainerNode.addChildNode(model)
        // MMDSceneKit currently reduces PMX 6DoF spring constraints to
        // unconstrained SceneKit ball joints. Once gravity starts, skirt and
        // cape bones leave their authored pose and expose the deliberately
        // unmodelled body beneath the clothes. Keep PMX models fully driven by
        // their skinning and VMD animation until the original spring limits
        // can be represented faithfully.
        Self.detachPhysicsBehaviors(of: model, from: scene)
        modelNode = model
        modelRestTransform = model.simdTransform
        coffeeCupNode = nil
        localBounds = Self.bounds(of: model)
        soleProbes = PMXSoleGrounding.makeProbes(
            in: model,
            bounds: localBounds
        )
        restFootReferenceY = PMXSoleGrounding.referenceY(
            probes: soleProbes,
            in: model,
            usesPresentationTree: false
        ) ?? Self.footReferenceY(
            in: model,
            usesPresentationTree: false
        )
        localGroundingOffsetY = 0
        trackingRootBone = Self.trackingRootBone(in: model)
        trackingRootRestPosition = trackingRootBone?.simdConvertPosition(
            .zero,
            to: model
        ) ?? .zero
        animatedRootOffset = .zero
        loadedModelURL = url
        loadedMotionURL = nil
        installNaturalIdle(on: model)
    }

    private func validateMotionRequest(_ url: URL) throws {
        let fileName = url.lastPathComponent
        guard url.pathExtension.lowercased() == "vmd" else {
            throw LoadError.unsupportedMotion(fileName: fileName)
        }
    }

    private func installMotion(
        _ motion: CAAnimationGroup,
        on modelNode: MMDNode,
        from url: URL,
        repeats: Bool,
        playbackRate: Float,
        inPlace: Bool
    ) {
        // SceneKit animation players use this renderer's local scene clock.
        // A motion attached after the avatar has already been rendered must
        // start at local time zero; otherwise the new player is immediately
        // evaluated at the old scene age and can remain at its rest frame.
        renderTimeline.restartAnimationClock()
        sceneRenderer.sceneTime = 0
        modelNode.removeAnimation(
            forKey: Self.naturalIdleKey,
            blendOutDuration: 0
        )
        let duration = Self.attachMotion(
            motion,
            to: modelNode,
            key: Self.motionKey,
            rootMotionEnabled: configuration.rootMotionEnabled,
            inPlace: inPlace,
            repeats: repeats,
            retargetsGeneratedHumanoidMotion: url.pathComponents.contains {
                $0.hasPrefix("gmgn.motion.")
            }
        )
        let speed = min(max(playbackRate, 0.01), 8)
        modelNode.animationPlayer(forKey: Self.motionKey)?.speed = CGFloat(speed)
        oneShotMotionPlayback = PMXOneShotMotionPlayback.begin(
            url: url,
            duration: duration / Double(speed),
            currentTime: renderTimeline.elapsed,
            repeats: repeats
        )
        loadedMotionURL = url
        isUsingNaturalIdle = false
        let probeBone = ["左ひざ", "右ひざ", "左腕", "右腕"].lazy
            .compactMap { modelNode.childNode(withName: $0, recursively: true) }
            .first
        motionPlaybackProbeBone = probeBone
        motionPlaybackProbe = probeBone?.name.map {
            PMXMotionPlaybackProbe(boneName: $0)
        }
        let playerInstalled = modelNode.animationPlayer(
            forKey: Self.motionKey
        ) != nil
        Self.log.notice(
            "Installed motion file=\(url.lastPathComponent, privacy: .public) duration=\(duration, privacy: .public) speed=\(speed, privacy: .public) repeats=\(repeats, privacy: .public) inPlace=\(inPlace, privacy: .public) player=\(playerInstalled, privacy: .public)"
        )
    }

    public func clearMotion() {
        modelNode?.removeAnimation(forKey: Self.motionKey, blendOutDuration: 0)
        loadedMotionURL = nil
        oneShotMotionPlayback = nil
        localGroundingOffsetY = 0
        renderTimeline.restartAnimationClock()
        sceneRenderer.sceneTime = 0
        if let modelNode {
            installNaturalIdle(on: modelNode)
        } else {
            isUsingNaturalIdle = false
        }
    }

    public func encode(
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4,
        modelTransform: simd_float4x4 = matrix_identity_float4x4,
        time: TimeInterval,
        diagnosticProfile: String? = nil
    ) {
        guard let modelNode else {
            return
        }
        let viewportSize: (width: Int, height: Int)
        if let colorTexture = renderPassDescriptor.colorAttachments[0].texture {
            viewportSize = (colorTexture.width, colorTexture.height)
        } else if let depthTexture = renderPassDescriptor.depthAttachment.texture {
            viewportSize = (depthTexture.width, depthTexture.height)
        } else {
            return
        }
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return
        }

        modelContainerNode.simdTransform = modelTransform
        if !configuration.rootMotionEnabled {
            modelNode.simdTransform = modelRestTransform
        }
        let camera = Self.cameraConfiguration(
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix
        )
        cameraNode.simdTransform = camera.worldTransform
        cameraNode.camera?.projectionTransform = SCNMatrix4(
            camera.projectionTransform
        )
        let localTime = renderTimeline.advance(to: time)
        sceneRenderer.sceneTime = localTime
        updateRaw2BFootIKTargets()
        updateCoffeeCupAttachment()
        sceneRenderer.render(
            atTime: localTime,
            viewport: CGRect(
                x: 0,
                y: 0,
                width: viewportSize.width,
                height: viewportSize.height
            ),
            commandBuffer: commandBuffer,
            passDescriptor: renderPassDescriptor
        )
        if let diagnosticProfile {
            // Compare the authored node values with SceneKit's evaluated tree
            // after this render; a profile switch must update both together.
            let containerScale = String(describing: modelContainerNode.simdScale)
            let containerPosition = String(describing: modelContainerNode.simdPosition)
            let containerPresentationScale = String(describing: modelContainerNode.presentation.simdScale)
            let containerPresentationPosition = String(describing: modelContainerNode.presentation.simdPosition)
            let modelScale = String(describing: modelNode.simdScale)
            let modelPosition = String(describing: modelNode.simdPosition)
            let modelPresentationScale = String(describing: modelNode.presentation.simdScale)
            let modelPresentationPosition = String(describing: modelNode.presentation.simdPosition)
            let cameraPosition = String(describing: cameraNode.simdPosition)
            let cameraPresentationPosition = String(describing: cameraNode.presentation.simdPosition)
            Self.log.notice(
                "PMX frame transforms profile=\(diagnosticProfile, privacy: .public) sceneTime=\(localTime, privacy: .public) containerScale=\(containerScale, privacy: .public) containerPosition=\(containerPosition, privacy: .public) containerPresentationScale=\(containerPresentationScale, privacy: .public) containerPresentationPosition=\(containerPresentationPosition, privacy: .public) modelScale=\(modelScale, privacy: .public) modelPosition=\(modelPosition, privacy: .public) modelPresentationScale=\(modelPresentationScale, privacy: .public) modelPresentationPosition=\(modelPresentationPosition, privacy: .public) cameraPosition=\(cameraPosition, privacy: .public) cameraPresentationPosition=\(cameraPresentationPosition, privacy: .public)"
            )
        }
        if let bone = motionPlaybackProbeBone,
           let report = motionPlaybackProbe?.record(
               time: localTime,
               orientation: bone.presentation.simdOrientation
           )
        {
            let moving = report.maximumRotationDelta > 0.02
            Self.log.notice(
                "Observed motion bone=\(report.boneName, privacy: .public) rotationDelta=\(report.maximumRotationDelta, privacy: .public) moving=\(moving, privacy: .public)"
            )
        }
        updateAnimatedRootOffset()
        updateAnimatedGroundingOffset()
        if let completedURL = oneShotMotionPlayback?.finishIfNeeded(
            at: localTime
        ) {
            clearMotion()
            onMotionFinished?(completedURL)
        }
    }

    private func updateAnimatedRootOffset() {
        guard let modelNode,
              let trackingRootBone
        else {
            animatedRootOffset = .zero
            return
        }
        let current = trackingRootBone.presentation.simdConvertPosition(
            .zero,
            to: modelNode.presentation
        )
        let offset = current - trackingRootRestPosition
        guard offset.x.isFinite,
              offset.y.isFinite,
              offset.z.isFinite
        else {
            animatedRootOffset = .zero
            return
        }
        animatedRootOffset = offset
    }

    private static func trackingRootBone(in model: MMDNode) -> SCNNode? {
        for name in trackingRootBoneNames {
            if let node = model.childNode(withName: name, recursively: true) {
                return node
            }
        }
        return nil
    }

    private func updateAnimatedGroundingOffset() {
        guard let modelNode,
              let restFootReferenceY,
              let animatedFootReferenceY = PMXSoleGrounding.referenceY(
                  probes: soleProbes,
                  in: modelNode,
                  usesPresentationTree: true
              ) ?? Self.footReferenceY(
                  in: modelNode,
                  usesPresentationTree: true
              )
        else {
            localGroundingOffsetY = 0
            return
        }
        localGroundingOffsetY = PMXAnimatedGrounding.localOffsetY(
            restFootReferenceY: restFootReferenceY,
            animatedFootReferenceY: animatedFootReferenceY
        )
    }

    private static func footReferenceY(
        in model: MMDNode,
        usesPresentationTree: Bool
    ) -> Float? {
        let names = [
            "bone017", "bone018", "bone021", "bone022",
            "右足首", "右つま先", "左足首", "左つま先",
        ]
        let modelSpace: SCNNode = usesPresentationTree
            ? model.presentation
            : model
        let values = names.compactMap { name -> Float? in
            guard let node = model.childNode(
                withName: name,
                recursively: true
            ) else {
                return nil
            }
            let source: SCNNode = usesPresentationTree
                ? node.presentation
                : node
            let value = source.simdConvertPosition(.zero, to: modelSpace).y
            return value.isFinite ? value : nil
        }
        return values.min()
    }

    private static func rootLockedCopy(
        _ animation: CAAnimation
    ) -> CAAnimation? {
        if let keyframe = animation as? CAKeyframeAnimation,
           isRootTranslationKeyPath(keyframe.keyPath)
        {
            return nil
        }
        if let group = animation as? CAAnimationGroup,
           let copy = group.copy() as? CAAnimationGroup
        {
            copy.animations = group.animations?.compactMap(rootLockedCopy)
            return copy
        }
        return animation.copy() as? CAAnimation
    }

    private static func horizontalRootLockedCopy(
        _ animation: CAAnimation
    ) -> CAAnimation? {
        if let keyframe = animation as? CAKeyframeAnimation,
           isHorizontalRootTranslationKeyPath(keyframe.keyPath)
        {
            return nil
        }
        if let group = animation as? CAAnimationGroup,
           let copy = group.copy() as? CAAnimationGroup
        {
            copy.animations = group.animations?.compactMap(
                horizontalRootLockedCopy
            )
            return copy
        }
        return animation.copy() as? CAAnimation
    }

    private func installNaturalIdle(on model: MMDNode) {
        Self.attachNaturalIdle(to: model, key: Self.naturalIdleKey)
        isUsingNaturalIdle = true
    }

    private static func firstBone(
        in model: MMDNode,
        named candidateNames: [String]
    ) -> SCNNode? {
        for name in candidateNames {
            if let exactMatch = model.childNode(withName: name, recursively: true) {
                return exactMatch
            }
        }
        let lowercaseNames = Set(candidateNames.map { $0.lowercased() })
        var match: SCNNode?
        model.enumerateHierarchy { node, stop in
            guard let name = node.name?.lowercased() else { return }
            if lowercaseNames.contains(name) {
                match = node
                stop.pointee = true
            }
        }
        return match
    }

    private static func naturalIdleTrack(
        for bone: SCNNode,
        relaxationAngle: Float,
        breathingAngle: Float,
        axis: SIMD3<Float>
    ) -> CAKeyframeAnimation {
        let restOrientation = bone.simdOrientation
        let angles = [
            relaxationAngle - breathingAngle,
            relaxationAngle + breathingAngle,
            relaxationAngle - breathingAngle,
        ]
        let values = angles.map { angle -> NSValue in
            let orientation = restOrientation
                * simd_quatf(angle: angle, axis: axis)
            return NSValue(
                scnVector4: SCNVector4(
                    orientation.vector.x,
                    orientation.vector.y,
                    orientation.vector.z,
                    orientation.vector.w
                )
            )
        }
        let track = CAKeyframeAnimation(
            keyPath: "/\(bone.name ?? "").transform.quaternion"
        )
        track.values = values
        track.keyTimes = [0, 0.5, 1]
        track.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        track.duration = naturalIdleDuration
        track.usesSceneTimeBase = false
        track.isRemovedOnCompletion = false
        track.fillMode = .forwards
        return track
    }

    private static func canonicalFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func modelTrackCopy(
        _ animation: CAAnimation
    ) -> CAAnimation? {
        if let keyframe = animation as? CAKeyframeAnimation,
           isSceneTrackKeyPath(keyframe.keyPath)
        {
            return nil
        }
        if let group = animation as? CAAnimationGroup,
           let copy = group.copy() as? CAAnimationGroup
        {
            copy.animations = group.animations?.compactMap(modelTrackCopy)
            return copy
        }
        return animation.copy() as? CAAnimation
    }

    private static func morphSafeCopy(
        _ animation: CAAnimation
    ) -> CAAnimation? {
        if let keyframe = animation as? CAKeyframeAnimation,
           keyframe.keyPath?.hasPrefix("morpher.") == true
        {
            return nil
        }
        if let group = animation as? CAAnimationGroup,
           let copy = group.copy() as? CAAnimationGroup
        {
            copy.animations = group.animations?.compactMap(morphSafeCopy)
            return copy
        }
        return animation.copy() as? CAAnimation
    }

    private static let raw2BBoneMap: [String: String] = [
        "全ての親": "bone4094",
        "センター": "bone000",
        "グルーブ": raw2BGrooveName,
        "上半身": "bone001",
        "上半身2": "bone002",
        "首": "bone004",
        "頭": "bone005",
        "左肩": "bone010",
        "左腕": "bone011",
        "左ひじ": "bone012",
        "左手首": "bone013",
        "右肩": "bone006",
        "右腕": "bone007",
        "右ひじ": "bone008",
        "右手首": "bone009",
        "下半身": "bone014",
        "左足": "bone019",
        "左ひざ": "bone020",
        "左足首": "bone021",
        "左つま先": "bone022",
        "右足": "bone015",
        "右ひざ": "bone016",
        "右足首": "bone017",
        "右つま先": "bone018",
        "左足ＩＫ": raw2BLeftFootIKTargetName,
        "左足IK": raw2BLeftFootIKTargetName,
        "右足ＩＫ": raw2BRightFootIKTargetName,
        "右足IK": raw2BRightFootIKTargetName,
        "左腕捩": "bone2561",
        "左手捩": "bone2592",
        "右腕捩": "bone2560",
        "右手捩": "bone2576",
        "左親指０": "bone512",
        "左親指１": "bone513",
        "左親指２": "bone514",
        "左人指１": "bone515",
        "左人指２": "bone516",
        "左人指３": "bone517",
        "左人指先": "bone518",
        "左中指１": "bone519",
        "左中指２": "bone520",
        "左中指３": "bone521",
        "左中指先": "bone522",
        "左薬指１": "bone523",
        "左薬指２": "bone524",
        "左薬指３": "bone525",
        "左薬指先": "bone526",
        "左小指１": "bone527",
        "左小指２": "bone528",
        "左小指３": "bone529",
        "左小指先": "bone530",
        "右親指０": "bone256",
        "右親指１": "bone257",
        "右親指２": "bone258",
        "右人指１": "bone259",
        "右人指２": "bone260",
        "右人指３": "bone261",
        "右人指先": "bone262",
        "右中指１": "bone263",
        "右中指２": "bone264",
        "右中指３": "bone265",
        "右中指先": "bone266",
        "右薬指１": "bone267",
        "右薬指２": "bone268",
        "右薬指３": "bone269",
        "右薬指先": "bone270",
        "右小指１": "bone271",
        "右小指２": "bone272",
        "右小指３": "bone273",
        "右小指先": "bone274",
    ]

    private struct Raw2BBindDirection {
        let targetChildName: String?
        let targetDirection: SIMD3<Float>?
        let sourceDirection: SIMD3<Float>

        init(
            targetChildName: String,
            sourceDirection: SIMD3<Float>
        ) {
            self.targetChildName = targetChildName
            targetDirection = nil
            self.sourceDirection = sourceDirection
        }

        init(
            targetDirection: SIMD3<Float>,
            sourceDirection: SIMD3<Float>
        ) {
            targetChildName = nil
            self.targetDirection = targetDirection
            self.sourceDirection = sourceDirection
        }
    }

    private static let raw2BBindDirections: [String: Raw2BBindDirection] = [
        "上半身": .init(
            targetChildName: "bone002",
            sourceDirection: SIMD3<Float>(0, 1.3732, 0)
        ),
        "上半身2": .init(
            targetChildName: "bone004",
            sourceDirection: SIMD3<Float>(0, 2.5352, 0)
        ),
        "首": .init(
            targetChildName: "bone005",
            sourceDirection: SIMD3<Float>(0, 0.7394, 0)
        ),
        "左肩": .init(
            targetChildName: "bone011",
            sourceDirection: SIMD3<Float>(0.7371, 0.0192, 0.0072)
        ),
        "左腕": .init(
            targetChildName: "bone012",
            sourceDirection: SIMD3<Float>(3.0679, -2.3537, -0.049)
        ),
        "左ひじ": .init(
            targetChildName: "bone013",
            sourceDirection: SIMD3<Float>(1.9423, -1.4841, -0.099)
        ),
        "右肩": .init(
            targetChildName: "bone007",
            sourceDirection: SIMD3<Float>(-0.6389, 0.0041, -0.0138)
        ),
        "右腕": .init(
            targetChildName: "bone008",
            sourceDirection: SIMD3<Float>(-2.5098, -1.8939, 0.0948)
        ),
        "右ひじ": .init(
            targetChildName: "bone009",
            sourceDirection: SIMD3<Float>(-2.3748, -1.7654, -0.0591)
        ),
        "左足": .init(
            targetChildName: "bone020",
            sourceDirection: SIMD3<Float>(-0.0003, -4.7931, 0)
        ),
        "左ひざ": .init(
            targetChildName: "bone021",
            sourceDirection: SIMD3<Float>(0.00003, -4.5727, 0)
        ),
        "右足": .init(
            targetChildName: "bone016",
            sourceDirection: SIMD3<Float>(0.0003, -4.7931, 0)
        ),
        "右ひざ": .init(
            targetChildName: "bone017",
            sourceDirection: SIMD3<Float>(-0.00003, -4.5727, 0)
        ),
        "左親指０": .init(
            targetChildName: "bone513",
            sourceDirection: SIMD3<Float>(0.2130, -0.2510, 0.2332)
        ),
        "左親指１": .init(
            targetChildName: "bone514",
            sourceDirection: SIMD3<Float>(0.2368, -0.2117, 0.1342)
        ),
        "左親指２": .init(
            targetDirection: SIMD3<Float>(2.0508, 1.4740, 0.6177),
            sourceDirection: SIMD3<Float>(0.2368, -0.2117, 0.1342)
        ),
        "左人指１": .init(
            targetChildName: "bone516",
            sourceDirection: SIMD3<Float>(0.3440, -0.2399, -0.0072)
        ),
        "左人指２": .init(
            targetChildName: "bone517",
            sourceDirection: SIMD3<Float>(0.2484, -0.1602, 0.0008)
        ),
        "左人指３": .init(
            targetChildName: "bone518",
            sourceDirection: SIMD3<Float>(0.2484, -0.1602, 0.0008)
        ),
        "左中指１": .init(
            targetChildName: "bone520",
            sourceDirection: SIMD3<Float>(0.3646, -0.2474, -0.0350)
        ),
        "左中指２": .init(
            targetChildName: "bone521",
            sourceDirection: SIMD3<Float>(0.2707, -0.1799, -0.0029)
        ),
        "左中指３": .init(
            targetChildName: "bone522",
            sourceDirection: SIMD3<Float>(0.2707, -0.1799, -0.0029)
        ),
        "左薬指１": .init(
            targetChildName: "bone524",
            sourceDirection: SIMD3<Float>(0.3403, -0.2262, -0.0339)
        ),
        "左薬指２": .init(
            targetChildName: "bone525",
            sourceDirection: SIMD3<Float>(0.2464, -0.1665, -0.0001)
        ),
        "左薬指３": .init(
            targetChildName: "bone526",
            sourceDirection: SIMD3<Float>(0.2464, -0.1665, -0.0001)
        ),
        "左小指１": .init(
            targetChildName: "bone528",
            sourceDirection: SIMD3<Float>(0.2498, -0.1655, -0.0238)
        ),
        "左小指２": .init(
            targetChildName: "bone529",
            sourceDirection: SIMD3<Float>(0.1825, -0.1542, -0.0269)
        ),
        "左小指３": .init(
            targetChildName: "bone530",
            sourceDirection: SIMD3<Float>(0.1825, -0.1542, -0.0269)
        ),
        "右親指０": .init(
            targetChildName: "bone257",
            sourceDirection: SIMD3<Float>(-0.2130, -0.2510, 0.2332)
        ),
        "右親指１": .init(
            targetChildName: "bone258",
            sourceDirection: SIMD3<Float>(-0.2368, -0.2117, 0.1342)
        ),
        "右親指２": .init(
            targetDirection: SIMD3<Float>(-2.0509, 1.4740, 0.6177),
            sourceDirection: SIMD3<Float>(-0.2368, -0.2117, 0.1342)
        ),
        "右人指１": .init(
            targetChildName: "bone260",
            sourceDirection: SIMD3<Float>(-0.3440, -0.2399, -0.0072)
        ),
        "右人指２": .init(
            targetChildName: "bone261",
            sourceDirection: SIMD3<Float>(-0.2484, -0.1602, 0.0008)
        ),
        "右人指３": .init(
            targetChildName: "bone262",
            sourceDirection: SIMD3<Float>(-0.2484, -0.1602, 0.0008)
        ),
        "右中指１": .init(
            targetChildName: "bone264",
            sourceDirection: SIMD3<Float>(-0.3646, -0.2474, -0.0350)
        ),
        "右中指２": .init(
            targetChildName: "bone265",
            sourceDirection: SIMD3<Float>(-0.2707, -0.1799, -0.0029)
        ),
        "右中指３": .init(
            targetChildName: "bone266",
            sourceDirection: SIMD3<Float>(-0.2707, -0.1799, -0.0029)
        ),
        "右薬指１": .init(
            targetChildName: "bone268",
            sourceDirection: SIMD3<Float>(-0.3403, -0.2262, -0.0339)
        ),
        "右薬指２": .init(
            targetChildName: "bone269",
            sourceDirection: SIMD3<Float>(-0.2464, -0.1665, -0.0001)
        ),
        "右薬指３": .init(
            targetChildName: "bone270",
            sourceDirection: SIMD3<Float>(-0.2464, -0.1665, -0.0001)
        ),
        "右小指１": .init(
            targetChildName: "bone272",
            sourceDirection: SIMD3<Float>(-0.2498, -0.1655, -0.0238)
        ),
        "右小指２": .init(
            targetChildName: "bone273",
            sourceDirection: SIMD3<Float>(-0.1825, -0.1542, -0.0269)
        ),
        "右小指３": .init(
            targetChildName: "bone274",
            sourceDirection: SIMD3<Float>(-0.1825, -0.1542, -0.0269)
        ),
    ]

    private static let generatedHumanoidBindDirections: [String: SIMD3<Float>] = [
        "上半身": SIMD3<Float>(0, 0.08, 0),
        "上半身2": SIMD3<Float>(0, 0.12, 0),
        "首": SIMD3<Float>(0, 0.13, 0),
        "左肩": SIMD3<Float>(0.06, 0, 0),
        "左腕": SIMD3<Float>(0.24, 0, 0),
        "左ひじ": SIMD3<Float>(0.22, 0, 0),
        "右肩": SIMD3<Float>(-0.06, 0, 0),
        "右腕": SIMD3<Float>(-0.24, 0, 0),
        "右ひじ": SIMD3<Float>(-0.22, 0, 0),
        "左足": SIMD3<Float>(0, -0.38, 0),
        "左ひざ": SIMD3<Float>(0, -0.42, 0),
        "右足": SIMD3<Float>(0, -0.38, 0),
        "右ひざ": SIMD3<Float>(0, -0.42, 0),
    ]

    private static let generatedHumanoidChildNames: [String: [String]] = [
        "上半身": ["上半身2", "上半身b"],
        "上半身2": ["首"],
        "首": ["頭"],
        "左肩": ["左腕"],
        "左腕": ["左ひじ"],
        "左ひじ": ["左手首"],
        "右肩": ["右腕"],
        "右腕": ["右ひじ"],
        "右ひじ": ["右手首"],
        "左足": ["左ひざ"],
        "左ひざ": ["左足首"],
        "右足": ["右ひざ"],
        "右ひざ": ["右足首"],
    ]

    private static let generatedHumanoidRetargetParents: [String: String] = [
        "上半身2": "上半身",
        "首": "上半身2",
        "左肩": "上半身2",
        "左腕": "左肩",
        "左ひじ": "左腕",
        "右肩": "上半身2",
        "右腕": "右肩",
        "右ひじ": "右腕",
        "左ひざ": "左足",
        "右ひざ": "右足",
    ]

    private static func generatedHumanoidAnimationCopy(
        _ animation: CAAnimation,
        to model: MMDNode
    ) -> CAAnimation? {
        let sourceToTargetBases = generatedHumanoidBindDirections.reduce(
            into: [String: simd_quatf]()
        ) { bases, entry in
            guard let targetBone = model.childNode(
                      withName: entry.key,
                      recursively: true
                  ),
                  let targetChild = generatedHumanoidChildNames[entry.key]?
                      .lazy
                      .compactMap({ childName in
                          model.childNode(withName: childName, recursively: true)
                      })
                      .first
            else { return }
            let targetDirection = targetBone.simdOrientation.act(
                targetBone.simdConvertPosition(.zero, from: targetChild)
            )
            guard simd_length_squared(entry.value) > 0.000001,
                  simd_length_squared(targetDirection) > 0.000001
            else { return }
            bases[entry.key] = simd_quatf(
                from: simd_normalize(entry.value),
                to: simd_normalize(targetDirection)
            )
        }
        return generatedHumanoidAnimationCopy(
            animation,
            to: model,
            sourceToTargetBases: sourceToTargetBases
        )
    }

    private static func generatedHumanoidAnimationCopy(
        _ animation: CAAnimation,
        to model: MMDNode,
        sourceToTargetBases: [String: simd_quatf]
    ) -> CAAnimation? {
        if let keyframe = animation as? CAKeyframeAnimation,
           let keyPath = keyframe.keyPath,
           keyPath.hasSuffix(".transform.quaternion"),
           keyPath.first == "/"
        {
            let separator = keyPath.firstIndex(of: ".") ?? keyPath.endIndex
            let name = String(
                keyPath[keyPath.index(after: keyPath.startIndex) ..< separator]
            )
            guard let sourceToTargetBasis = sourceToTargetBases[name],
                  let targetBone = model.childNode(
                      withName: name,
                      recursively: true
                  ),
                  let targetChild = generatedHumanoidChildNames[name]?
                      .lazy
                      .compactMap({ childName in
                          model.childNode(withName: childName, recursively: true)
                      })
                      .first,
                  let copy = keyframe.copy() as? CAKeyframeAnimation
            else {
                return keyframe.copy() as? CAAnimation
            }
            _ = targetChild
            let parentBasis = generatedHumanoidRetargetParents[name]
                .flatMap { sourceToTargetBases[$0] }
                ?? simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            var previousOrientation: simd_quatf?
            copy.values = keyframe.values?.map { value in
                guard let value = value as? NSValue else { return value }
                let vector = value.scnVector4Value
                let sourceDelta = simd_quatf(vector: SIMD4<Float>(
                    Float(vector.x), Float(vector.y),
                    Float(vector.z), Float(vector.w)
                ))
                var orientation = PMXBoneRotationRetargeting
                    .hierarchyAwareOrientation(
                    sourceDelta: sourceDelta,
                    parentSourceToTargetBasis: parentBasis,
                    sourceToTargetBasis: sourceToTargetBasis,
                    targetRestOrientation: targetBone.simdOrientation,
                )
                if let previousOrientation,
                   simd_dot(previousOrientation.vector, orientation.vector) < 0
                {
                    orientation = simd_quatf(vector: -orientation.vector)
                }
                previousOrientation = orientation
                return NSValue(scnVector4: SCNVector4(
                    orientation.vector.x, orientation.vector.y,
                    orientation.vector.z, orientation.vector.w
                ))
            }
            return copy
        }
        if let group = animation as? CAAnimationGroup,
           let copy = group.copy() as? CAAnimationGroup
        {
            copy.animations = group.animations?.compactMap {
                generatedHumanoidAnimationCopy(
                    $0,
                    to: model,
                    sourceToTargetBases: sourceToTargetBases
                )
            }
            return copy
        }
        return animation.copy() as? CAAnimation
    }

    private static func motionByRetargetingIfNeeded(
        _ motion: CAAnimationGroup,
        to model: MMDNode
    ) -> CAAnimationGroup {
        guard PMXMaterialCompatibility.isRaw2BModel(model),
              let copy = raw2BAnimationCopy(
                  motion,
                  to: model
              ) as? CAAnimationGroup
        else {
            return motion
        }
        return copy
    }

    private static func raw2BSourceFingerHingeAxis(
        for sourceBoneName: String
    ) -> SIMD3<Float>? {
        if sourceBoneName.contains("指") {
            return SIMD3<Float>(0, 0, 1)
        }
        return nil
    }

    private static func raw2BTargetFingerHingeAxis(
        for sourceBoneName: String,
        in model: MMDNode,
        relativeTo targetParent: SCNNode
    ) -> SIMD3<Float>? {
        let isLeft = sourceBoneName.hasPrefix("左")
        let isRight = sourceBoneName.hasPrefix("右")
        guard sourceBoneName.contains("指"), isLeft || isRight else {
            return nil
        }
        let wristName = isLeft ? "bone013" : "bone009"
        let indexName = isLeft ? "bone515" : "bone259"
        let pinkyName = isLeft ? "bone527" : "bone271"
        guard let wrist = model.childNode(
            withName: wristName,
            recursively: true
        ), let index = model.childNode(
            withName: indexName,
            recursively: true
        ), let pinky = model.childNode(
            withName: pinkyName,
            recursively: true
        ) else {
            return nil
        }

        let wristPosition = model.simdConvertPosition(.zero, from: wrist)
        let indexPosition = model.simdConvertPosition(.zero, from: index)
        let pinkyPosition = model.simdConvertPosition(.zero, from: pinky)
        let modelAcross = indexPosition - pinkyPosition
        guard simd_length_squared(modelAcross) > 0.000001 else {
            return nil
        }
        let origin = targetParent.simdConvertPosition(
            wristPosition,
            from: model
        )
        let tip = targetParent.simdConvertPosition(
            wristPosition + simd_normalize(modelAcross),
            from: model
        )
        let hinge = tip - origin
        guard simd_length_squared(hinge) > 0.000001 else { return nil }
        return simd_normalize(hinge)
    }

    private static func raw2BAnimationCopy(
        _ animation: CAAnimation,
        to model: MMDNode
    ) -> CAAnimation? {
        if let keyframe = animation as? CAKeyframeAnimation,
           let keyPath = keyframe.keyPath
        {
            // Compatibility removes this model's malformed morpher. Passing
            // any VMD morph track to MMDSceneKit after that removal makes its
            // converter force-unwrap the missing Geometry/morpher pair.
            guard !keyPath.hasPrefix("morpher.") else {
                return nil
            }
            guard keyPath.first == "/" else {
                return nil
            }
            let separator = keyPath.firstIndex(of: ".") ?? keyPath.endIndex
            let sourceName = String(keyPath[keyPath.index(after: keyPath.startIndex) ..< separator])
            guard let targetName = raw2BBoneMap[sourceName],
                  let copy = keyframe.copy() as? CAKeyframeAnimation
            else {
                return nil
            }
            copy.keyPath = "/\(targetName)\(keyPath[separator...])"
            sanitizeRaw2BKeyTimes(copy)
            if keyPath.contains(".transform.translation.") {
                let scale = raw2BTranslationScale(for: model)
                copy.values = keyframe.values?.map { value in
                    if let value = value as? Float {
                        return value * scale
                    }
                    if let value = value as? NSNumber {
                        return value.floatValue * scale
                    }
                    return value
                }
            }
            if keyPath.hasSuffix(".transform.quaternion"),
               let targetBone = model.childNode(
                   withName: targetName,
                   recursively: true
               )
            {
                var previousOrientation: simd_quatf?
                copy.values = keyframe.values?.map { value in
                    guard let value = value as? NSValue else {
                        return value
                    }
                    let vector = value.scnVector4Value
                    let delta = simd_quatf(
                        vector: SIMD4<Float>(
                            Float(vector.x),
                            Float(vector.y),
                            Float(vector.z),
                            Float(vector.w)
                        )
                    )
                    let targetRest = targetBone.simdOrientation
                    // The raw 2B rig uses anonymous bone names but keeps the
                    // same MMD parent-space quaternion convention. Preserve
                    // its authored bind orientation and remap names only.
                    // Rebuilding a basis from one child direction changes the
                    // rotation plane and can twist arms, legs, and fingers.
                    let orientation = simd_normalize(targetRest * delta)
                    var continuousOrientation = orientation
                    if let previousOrientation,
                       simd_dot(
                           previousOrientation.vector,
                           continuousOrientation.vector
                       ) < 0
                    {
                        continuousOrientation = simd_quatf(
                            vector: -continuousOrientation.vector
                        )
                    }
                    previousOrientation = continuousOrientation
                    return NSValue(
                        scnVector4: SCNVector4(
                            continuousOrientation.vector.x,
                            continuousOrientation.vector.y,
                            continuousOrientation.vector.z,
                            continuousOrientation.vector.w
                        )
                    )
                }
            }
            return copy
        }
        if let group = animation as? CAAnimationGroup,
           let copy = group.copy() as? CAAnimationGroup
        {
            copy.animations = group.animations?.compactMap {
                raw2BAnimationCopy($0, to: model)
            }
            return copy
        }
        return animation.copy() as? CAAnimation
    }

    private static func sanitizeRaw2BKeyTimes(
        _ keyframe: CAKeyframeAnimation
    ) {
        let valueCount = keyframe.values?.count ?? 0
        guard valueCount > 0 else {
            keyframe.keyTimes = nil
            return
        }
        if valueCount == 1 {
            keyframe.keyTimes = [0]
            return
        }
        guard let keyTimes = keyframe.keyTimes,
              keyTimes.count == valueCount
        else {
            return
        }
        let denominator = Double(valueCount - 1)
        keyframe.keyTimes = keyTimes.enumerated().map { index, value in
            value.doubleValue.isFinite
                ? value
                : NSNumber(value: Double(index) / denominator)
        }
    }

    private static func motionByApplyingRaw2BInPlaceLock(
        to motion: CAAnimationGroup
    ) -> CAAnimationGroup {
        guard let copy = motion.copy() as? CAAnimationGroup else {
            return motion
        }
        copy.animations = motion.animations?.compactMap(
            raw2BInPlaceLockedCopy
        )
        return copy
    }

    private static func raw2BInPlaceLockedCopy(
        _ animation: CAAnimation
    ) -> CAAnimation? {
        if let keyframe = animation as? CAKeyframeAnimation,
           shouldRemoveRaw2BRootTrack(keyframe.keyPath)
        {
            return nil
        }
        if let group = animation as? CAAnimationGroup,
           let copy = group.copy() as? CAAnimationGroup
        {
            copy.animations = group.animations?.compactMap(
                raw2BInPlaceLockedCopy
            )
            return copy
        }
        return animation.copy() as? CAAnimation
    }

    private static func shouldRemoveRaw2BRootTrack(
        _ keyPath: String?
    ) -> Bool {
        guard let keyPath,
              keyPath.contains(".transform.translation.")
        else {
            return false
        }
        if keyPath.hasPrefix("/全ての親.")
            || keyPath.hasPrefix("/全親.")
        {
            return true
        }
        let isBodyRoot = keyPath.hasPrefix("/センター.")
            || keyPath.hasPrefix("/グルーブ.")
        guard isBodyRoot else { return false }
        // Keep ARDY's authored vertical motion so jumps can leave the floor.
        // Horizontal travel remains owned by WorldRuntime.
        return !keyPath.hasSuffix(".y")
    }

    private static func configureRaw2BGroove(in model: MMDNode) {
        guard model.childNode(
            withName: raw2BGrooveName,
            recursively: true
        ) == nil,
        let center = model.childNode(
            withName: "bone000",
            recursively: true
        ), let parent = center.parent
        else {
            return
        }

        let groove = SCNNode()
        groove.name = raw2BGrooveName
        groove.simdTransform = matrix_identity_float4x4
        center.removeFromParentNode()
        parent.addChildNode(groove)
        groove.addChildNode(center)
    }

    private static func configureRaw2BFootIK(in model: MMDNode) {
        configureRaw2BFootIK(
            in: model,
            upperLegName: "bone019",
            ankleName: "bone021",
            targetName: raw2BLeftFootIKTargetName
        )
        configureRaw2BFootIK(
            in: model,
            upperLegName: "bone015",
            ankleName: "bone017",
            targetName: raw2BRightFootIKTargetName
        )
    }

    private static func configureRaw2BFootIK(
        in model: MMDNode,
        upperLegName: String,
        ankleName: String,
        targetName: String
    ) {
        guard let upperLeg = model.childNode(
            withName: upperLegName,
            recursively: true
        ), let ankle = model.childNode(
            withName: ankleName,
            recursively: true
        ) else {
            return
        }

        let target: SCNNode
        if let existing = model.childNode(
            withName: targetName,
            recursively: false
        ) {
            target = existing
        } else {
            target = SCNNode()
            target.name = targetName
            target.simdPosition = ankle.simdConvertPosition(.zero, to: model)
            model.addChildNode(target)
        }

        let existingConstraints = ankle.constraints ?? []
        guard !existingConstraints.contains(where: { $0 is SCNIKConstraint })
        else {
            return
        }
        let constraint = SCNIKConstraint(chainRootNode: upperLeg)
        let targetPosition = target.simdWorldPosition
        constraint.targetPosition = SCNVector3(
            targetPosition.x,
            targetPosition.y,
            targetPosition.z
        )
        ankle.constraints = [constraint] + existingConstraints
    }

    private static func raw2BTranslationScale(for model: MMDNode) -> Float {
        let legPairs = [
            ("bone019", "bone021"),
            ("bone015", "bone017"),
        ]
        let lengths = legPairs.compactMap { upperName, ankleName -> Float? in
            guard let upper = model.childNode(
                withName: upperName,
                recursively: true
            ), let ankle = model.childNode(
                withName: ankleName,
                recursively: true
            ) else {
                return nil
            }
            let upperPosition = upper.simdConvertPosition(.zero, to: model)
            let anklePosition = ankle.simdConvertPosition(.zero, to: model)
            let length = simd_distance(upperPosition, anklePosition)
            return length.isFinite && length > 0 ? length : nil
        }
        guard !lengths.isEmpty else {
            return 1
        }
        let averageLength = lengths.reduce(0, +) / Float(lengths.count)
        return min(max(averageLength / standardMMDLegLength, 0.1), 100)
    }

    private func updateRaw2BFootIKTargets() {
        guard let modelNode,
              PMXMaterialCompatibility.isRaw2BModel(modelNode)
        else {
            return
        }
        Self.updateRaw2BFootIKTarget(
            in: modelNode,
            ankleName: "bone021",
            targetName: Self.raw2BLeftFootIKTargetName
        )
        Self.updateRaw2BFootIKTarget(
            in: modelNode,
            ankleName: "bone017",
            targetName: Self.raw2BRightFootIKTargetName
        )
    }

    private static func updateRaw2BFootIKTarget(
        in model: MMDNode,
        ankleName: String,
        targetName: String
    ) {
        guard let ankle = model.childNode(
            withName: ankleName,
            recursively: true
        ), let target = model.childNode(
            withName: targetName,
            recursively: false
        ), let constraint = ankle.constraints?
            .compactMap({ $0 as? SCNIKConstraint })
            .first
        else {
            return
        }
        let targetPosition = target.presentation.simdWorldPosition
        constraint.targetPosition = SCNVector3(
            targetPosition.x,
            targetPosition.y,
            targetPosition.z
        )
    }

    private static func isRootTranslationKeyPath(_ keyPath: String?) -> Bool {
        guard
            let keyPath,
            keyPath.contains(".translation."),
            keyPath.first == "/"
        else {
            return false
        }
        let boneName = keyPath
            .dropFirst()
            .split(separator: ".", maxSplits: 1)
            .first
            .map(String.init)?
            .lowercased()
        guard let boneName else {
            return false
        }
        return rootBoneNames.contains(boneName)
    }

    private static func isHorizontalRootTranslationKeyPath(
        _ keyPath: String?
    ) -> Bool {
        guard isRootTranslationKeyPath(keyPath), let keyPath else {
            return false
        }
        return keyPath.hasSuffix(".x") || keyPath.hasSuffix(".z")
    }

    private static func isSceneTrackKeyPath(_ keyPath: String?) -> Bool {
        guard let keyPath else {
            return false
        }
        if keyPath.hasPrefix("/MMDCamera") {
            return true
        }
        return keyPath.hasPrefix("camera.")
            || keyPath.hasPrefix("light.")
            || keyPath.hasPrefix("transform.")
            || keyPath == "????"
    }

    private static func bounds(of node: SCNNode) -> PMXAvatarBounds? {
        var resultMinimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var resultMaximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var foundGeometry = false

        node.enumerateHierarchy { child, _ in
            guard child.geometry != nil else {
                return
            }
            foundGeometry = true
            let box = child.boundingBox
            for x in [Float(box.min.x), Float(box.max.x)] {
                for y in [Float(box.min.y), Float(box.max.y)] {
                    for z in [Float(box.min.z), Float(box.max.z)] {
                        let point = child.simdConvertPosition(
                            SIMD3<Float>(x, y, z),
                            to: node
                        )
                        resultMinimum = simd_min(resultMinimum, point)
                        resultMaximum = simd_max(resultMaximum, point)
                    }
                }
            }
        }
        guard foundGeometry else {
            return nil
        }
        return PMXAvatarBounds(minimum: resultMinimum, maximum: resultMaximum)
    }
}
