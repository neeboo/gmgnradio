import AppKit
import SceneKit
import WorldRuntime

/// Metre-scale independent prop. The front/output faces -Z; origin is the foot.
///
/// **坐标一律来自世界包里的 `prop.procedural` 声明**（`wish-machine.json`）：
/// 这里不再有第二份数字。没有装声明就没有坐标 —— 机器不出现，取物点与出货口也不存在
/// （fail-closed），而不是退回到一组"看起来对"的常量。
enum WishMachineScene {
    enum State: String, Equatable, Sendable { case idle, generating, ready, failed }
    static let worldID = "84503420-3010-4944-8fde-2f383cd08ebe"
    static let propID = "wish_machine.device"
    static let activityID = "wish_machine.collect"
    /// Presentation-only enlargement. Formal position, collision size and
    /// pickup/output coordinates stay in the authored metre-space contract.
    static let visualScale: Float = 1.3

    /// 世界包装入的声明。装一次，只读。`nonisolated(unsafe)`：写入只发生在世界装载
    /// （主线程）那一刻，之后所有读者都只读它。
    nonisolated(unsafe) private(set) static var declaration: WorldProceduralPropDeclaration?

    static func install(_ declaration: WorldProceduralPropDeclaration?) {
        Self.declaration = declaration
    }

    static var position: SIMD3<Float> {
        guard let seed = declaration?.seedPosition else { return .zero }
        return SIMD3(seed.x, seed.y, seed.z)
    }

    static var size: SIMD3<Float> {
        guard let size = declaration?.size else { return .zero }
        return SIMD3(size.x, size.y, size.z)
    }

    /// 一个功能点的**世界**坐标 = 局部声明 × 种子摆放（与运行时注册表同一套算式）。
    /// 没有声明、或声明里没有这个角色 ⇒ `nil`。
    static func functionPoint(_ role: String) -> SIMD3<Float>? {
        guard let declaration,
              let point = declaration.functionPointDeclaration?.point(role: role) else { return nil }
        let world = WorldPropAnchorRegistry.worldPosition(
            of: point.position, placedAt: declaration.seedPosition, yaw: declaration.seedYaw
        )
        return SIMD3(world.x, world.y, world.z)
    }

    /// 居民取物的落点（`pickup` 站立功能点）。
    static var pickupPosition: SIMD3<Float>? { functionPoint("pickup") }

    /// 生成物件的出货点（`outlet` 发射功能点），局部高度 = 托盘面 + 25 cm。
    static var outletPosition: SIMD3<Float>? { functionPoint("outlet") }

    static func shouldDisplay(worldID: String?, drawsWorld: Bool) -> Bool {
        drawsWorld && worldID == Self.worldID && declaration != nil
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
        // 出货口来自声明的 `outlet` 功能点（局部 → 视觉子树的局部偏移）。
        outputAnchor.simdPosition = (outletPosition ?? position) - position
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
