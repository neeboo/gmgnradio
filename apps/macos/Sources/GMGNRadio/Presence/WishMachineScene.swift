import AppKit
import SceneKit

/// Metre-scale independent prop. The front/output faces -Z; origin is the foot.
enum WishMachineScene {
    enum State: String, Equatable, Sendable { case idle, generating, ready, failed }
    static let worldID = "84503420-3010-4944-8fde-2f383cd08ebe"
    static let propID = "wish_machine.device"
    static let activityID = "wish_machine.collect"
    static let pickupWaypointID = "wish_machine.pickup"
    static let position = SIMD3<Float>(0.8, -0.018, -2.6)
    static let size = SIMD3<Float>(0.9, 0.5, 0.8)
    static let pickupPosition = SIMD3<Float>(0.8, -0.037016094, -3.55)
    /// Bottom alignment for a generated item, 25 cm above the tray surface.
    static let outletPosition = SIMD3<Float>(0.8, 0.732, -2.6)
    /// Presentation-only enlargement. Formal position, collision size and
    /// pickup/output coordinates stay in the authored metre-space contract.
    static let visualScale: Float = 1.3

    static func shouldDisplay(worldID: String?, drawsWorld: Bool) -> Bool {
        drawsWorld && worldID == Self.worldID
    }

    /// Restores the independent machine when a retained props renderer loses
    /// its node, and keeps it dormant outside the bundled living cabin.
    @MainActor static func reconcileMachineNode(
        in propsRoot: SCNNode,
        worldID: String?,
        drawsWorld: Bool
    ) -> SCNNode? {
        let existing = propsRoot.childNode(
            withName: propID,
            recursively: false
        )
        guard shouldDisplay(worldID: worldID, drawsWorld: drawsWorld) else {
            existing?.isHidden = true
            return nil
        }
        let machine = existing ?? makeMachineNode()
        if machine.parent !== propsRoot {
            propsRoot.addChildNode(machine)
        }
        machine.isHidden = false
        return machine
    }

    @MainActor static func makeMachineNode() -> SCNNode {
        let root = SCNNode()
        root.name = propID
        root.simdPosition = position
        let visuals = SCNNode()
        visuals.name = "wish_machine.visuals"
        visuals.simdScale = SIMD3<Float>(repeating: visualScale)
        root.addChildNode(visuals)
        let shell = material(NSColor(calibratedWhite: 0.78, alpha: 1), metalness: 0.45)
        let dark = material(NSColor(calibratedWhite: 0.035, alpha: 1), metalness: 0.35)
        let tray = material(NSColor(calibratedWhite: 0.54, alpha: 1), metalness: 0.65)
        let outline = material(.systemCyan)
        outline.emission.contents = NSColor.systemCyan
        outline.emission.intensity = 1.8
        // Open fabrication tray: no cabinet, rear wall or lid around the item.
        visuals.addChildNode(box("wish_machine.base", size: SIMD3(0.9,0.12,0.8), at: SIMD3(0,0.06,0), material: dark))
        visuals.addChildNode(box("wish_machine.pedestal", size: SIMD3(0.62,0.3,0.52), at: SIMD3(0,0.27,0), material: shell))
        visuals.addChildNode(box("wish_machine.outlet", size: SIMD3(0.9,0.08,0.8), at: SIMD3(0,0.46,0), material: tray))
        let status = box("wish_machine.status", size: SIMD3(0.78,0.032,0.022), at: SIMD3(0,0.46,-0.412), material: material(.systemCyan))
        status.geometry?.firstMaterial?.emission.intensity = 2.4
        visuals.addChildNode(status)
        visuals.addChildNode(box("wish_machine.rim.left", size: SIMD3(0.025,0.025,0.78), at: SIMD3(-0.445,0.50,0), material: outline))
        visuals.addChildNode(box("wish_machine.rim.right", size: SIMD3(0.025,0.025,0.78), at: SIMD3(0.445,0.50,0), material: outline))
        let outputAnchor = SCNNode()
        outputAnchor.name = "wish_machine.output_anchor"
        outputAnchor.simdPosition = outletPosition - position
        root.addChildNode(outputAnchor)
        let label = SCNText(string: "WISH", extrusionDepth: 0.1)
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.flatness = 0.5
        label.materials = [dark]
        let labelNode = SCNNode(geometry: label)
        labelNode.name = "wish_machine.label"
        labelNode.simdScale = SIMD3(repeating: 0.011)
        labelNode.simdEulerAngles = SIMD3(0,Float.pi,0)
        labelNode.simdPosition = SIMD3(0.14,0.25,-0.267)
        visuals.addChildNode(labelNode)
        update(root, state: .idle)
        return root
    }

    @MainActor static func update(_ root: SCNNode, state: State) {
        let color: NSColor
        switch state {
        case .idle: color = .systemCyan
        case .generating: color = .systemOrange
        case .ready: color = .systemGreen
        case .failed: color = .systemRed
        }
        let light = root.childNode(withName: "wish_machine.status", recursively: true)?.geometry?.firstMaterial
        guard (light?.emission.contents as? NSColor) != color else { return }
        light?.diffuse.contents = color
        light?.emission.contents = color
    }

    @MainActor private static func material(_ color: NSColor, metalness: CGFloat = 0) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = metalness
        material.roughness.contents = 0.45
        return material
    }

    @MainActor private static func box(_ name: String, size: SIMD3<Float>, at p: SIMD3<Float>, material: SCNMaterial) -> SCNNode {
        let geometry = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0.015)
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = name
        node.simdPosition = p
        return node
    }
}
