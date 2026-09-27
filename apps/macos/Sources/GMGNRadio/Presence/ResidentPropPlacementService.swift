import Foundation
import WorldRuntime

struct ResidentPropSupportSurface: Equatable, Sendable {
    let id: String
    let center: WorldVector3
    let halfExtents: WorldVector3
    let yaw: Float
    let excludedCollisionID: String?
}

enum ResidentPropPlacementError: Error, Equatable, LocalizedError {
    case inactiveContext, environmentNotReady, unknownSurface, outsideSurface, collision(String), blockedRoute(String)
    case avatarUnavailable, avatarChanged, attachmentUnsupported(String), propTooLarge(String), activityActive, notHeld
    var errorDescription: String? {
        switch self {
        case .inactiveContext: "当前空间或编辑操作已结束。"
        case .environmentNotReady: "空间碰撞数据尚未准备好，请稍后再摆放。"
        case .unknownSurface: "请选择可用的地面或展示台。"
        case .outsideSurface: "物件超出了支撑面的范围。"
        case .collision(let name): "这里会碰到居民或物件：\(name)。"
        case .blockedRoute(let name): "这里会挡住活动入口或通道：\(name)。"
        case .avatarUnavailable: "当前没有可用于手持展示的居民。"
        case .avatarChanged: "居民已经更换，这次手持操作没有保存。"
        case .attachmentUnsupported(let reason): reason
        case .propTooLarge(let name): "\(name) 最长边超过 45 厘米，只能摆放，暂时不能拿在手里。"
        case .activityActive: "居民正在进行正式活动，请先停止活动再拿起物件。"
        case .notHeld: "这个物件当前没有拿在手里。"
        }
    }
}

@MainActor
final class ResidentPropPlacementService {
    let context: WorldAgentContext
    let surfaces: [ResidentPropSupportSurface]
    private let prepare: (WorldGeneratedProp) throws -> Void
    private let isCurrent: () -> Bool
    private let validateEnvironment: (WorldCollisionVolume, Float) throws -> Void
    private let currentAvatarAssetID: () -> String?
    private let makeGripCalibration: (WorldGeneratedProp, String) throws -> WorldPropGripCalibration
    init(context: WorldAgentContext, surfaces: [ResidentPropSupportSurface],
         prepare: @escaping (WorldGeneratedProp) throws -> Void = { _ in },
         isCurrent: @escaping () -> Bool = { true },
         validateEnvironment: @escaping (WorldCollisionVolume, Float) throws -> Void = { _,_ in throw ResidentPropPlacementError.environmentNotReady },
         currentAvatarAssetID: @escaping () -> String? = { nil },
         makeGripCalibration: @escaping (WorldGeneratedProp, String) throws -> WorldPropGripCalibration = { _,_ in
             throw ResidentPropPlacementError.attachmentUnsupported("当前居民还没有右手展示适配。")
         }) {
        self.context = context; self.surfaces = surfaces; self.prepare = prepare; self.isCurrent = isCurrent
        self.validateEnvironment = validateEnvironment
        self.currentAvatarAssetID = currentAvatarAssetID
        self.makeGripCalibration = makeGripCalibration
    }

    func holdCommand(objectID: String) throws -> WorldPropLayoutCommand {
        guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
        guard context.state.activeActivity == nil else { throw ResidentPropPlacementError.activityActive }
        guard let avatarID = currentAvatarAssetID() else { throw ResidentPropPlacementError.avatarUnavailable }
        guard let prop = context.state.objectStates[objectID]?.generatedProp else { throw WorldPropLayoutError.invalidObject }
        guard context.state.heldProp == nil else {
            throw ResidentPropPlacementError.attachmentUnsupported("居民一次只能拿一件物件，请先放回手里的物件。")
        }
        guard max(prop.size.x, max(prop.size.y, prop.size.z)) <= 0.45 else {
            throw ResidentPropPlacementError.propTooLarge(prop.displayName)
        }
        return .hold(objectID: objectID, avatarAssetID: avatarID,
                     calibration: try makeGripCalibration(prop, avatarID))
    }

    func holdEligibility(objectID: String) -> String? {
        do { _ = try holdCommand(objectID: objectID); return nil }
        catch { return error.localizedDescription }
    }

    func adjustGripCommand(objectID: String, localOffset: WorldVector3,
                           localRotation: WorldQuaternion) throws -> WorldPropLayoutCommand {
        guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
        guard let avatarID = currentAvatarAssetID() else { throw ResidentPropPlacementError.avatarUnavailable }
        guard let held = context.state.heldProp, held.objectID == objectID else { throw ResidentPropPlacementError.notHeld }
        guard held.avatarAssetID == avatarID else { throw ResidentPropPlacementError.avatarChanged }
        guard let item = context.state.objectStates[objectID], let existing = item.gripCalibration,
              existing.avatarAssetID == avatarID, existing.hand == .rightHand else {
            throw ResidentPropPlacementError.attachmentUnsupported("这个物件还没有当前居民的右手握点。")
        }
        return .adjustGrip(objectID: objectID, avatarAssetID: avatarID,
            calibration: .init(avatarAssetID: avatarID, hand: .rightHand,
                normalizedGrip: existing.normalizedGrip, localOffset: localOffset, localRotation: localRotation))
    }

    func returnHeldCommand(objectID: String) throws -> WorldPropLayoutCommand {
        guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
        guard let avatarID = currentAvatarAssetID() else { throw ResidentPropPlacementError.avatarUnavailable }
        guard let held = context.state.heldProp, held.objectID == objectID else { throw ResidentPropPlacementError.notHeld }
        guard held.avatarAssetID == avatarID else { throw ResidentPropPlacementError.avatarChanged }
        return .returnHeld(objectID: objectID, avatarAssetID: avatarID)
    }

    func preview(objectID: String, placement: WorldPropPlacement) throws -> WorldObjectState {
        guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
        var candidate = WorldSimulation(restoring: context.state)
        try candidate.applyPropLayout(.place(objectID: objectID, placement: placement),
            expectedLayoutRevision: context.state.layoutRevision, requestID: "preview.\(UUID())")
        try validate(candidate.state)
        return candidate.state.objectStates[objectID]!
    }

    @discardableResult
    func commit(_ command: WorldPropLayoutCommand, expectedLayoutRevision: UInt64, requestID: String) throws -> WorldState {
        guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
        try validateAttachmentAuthorization(command)
        return try context.commitPropLayout(command, expectedLayoutRevision: expectedLayoutRevision, requestID: requestID) { state in
            try validate(state)
            for item in state.objectStates.values where item.isEnabled || state.heldProp?.objectID == item.generatedProp?.objectID {
                if let prop = item.generatedProp { try prepare(prop) }
            }
            guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
            try validateAttachmentAuthorization(command)
        }
    }

    private func validateAttachmentAuthorization(_ command: WorldPropLayoutCommand) throws {
        let submittedAvatarID: String?
        switch command {
        case .hold(_, let avatarAssetID, _), .adjustGrip(_, let avatarAssetID, _), .returnHeld(_, let avatarAssetID):
            submittedAvatarID = avatarAssetID
        case .register, .place, .withdraw, .undo, .enableCapability:
            submittedAvatarID = nil
        }
        if let submittedAvatarID {
            guard currentAvatarAssetID() == submittedAvatarID else { throw ResidentPropPlacementError.avatarChanged }
        }
    }

    private func validate(_ state: WorldState) throws {
        var placed = state.objectStates.compactMap { id, item -> (String, WorldObjectState, WorldCollisionVolume)? in
            guard let volume = item.generatedCollisionVolume else { return nil }
            return (id,item,volume)
        }
        if let held = state.heldProp, held.returnState.isEnabled,
           let volume = held.returnState.generatedCollisionVolume {
            placed.append((held.objectID, held.returnState, volume))
        }
        for (id,item,box) in placed {
            guard item.generatedProp?.objectID == id else { throw WorldPropLayoutError.invalidObject }
            guard let surface = surfaces.first(where: { $0.id == item.supportSurfaceID }) else { throw ResidentPropPlacementError.unknownSurface }
            guard abs(item.transform.position.y - surface.center.y) < 0.005 else { throw ResidentPropPlacementError.outsideSurface }
            let yaw = atan2(2*(box.rotation.w*box.rotation.y),1-2*box.rotation.y*box.rotation.y)
            for x in [-box.halfExtents.x,box.halfExtents.x] {
                for z in [-box.halfExtents.z,box.halfExtents.z] {
                    let wx = box.center.x + cos(yaw)*x + sin(yaw)*z - surface.center.x
                    let wz = box.center.z - sin(yaw)*x + cos(yaw)*z - surface.center.z
                    let lx = cos(surface.yaw)*wx-sin(surface.yaw)*wz
                    let lz = sin(surface.yaw)*wx+cos(surface.yaw)*wz
                    guard abs(lx) <= surface.halfExtents.x+0.0001, abs(lz) <= surface.halfExtents.z+0.0001 else { throw ResidentPropPlacementError.outsideSurface }
                }
            }
            for other in context.manifest.collisionVolumes where other.isBlocking && other.id != surface.excludedCollisionID {
                if Self.overlap(box,other) { throw ResidentPropPlacementError.collision(other.id) }
            }
            guard context.hasEnvironmentClearance(for: box) else { throw ResidentPropPlacementError.collision("环境") }
            try validateEnvironment(box,surface.center.y)
            for (otherID,_,other) in placed where otherID != id {
                if Self.overlap(box,other) { throw ResidentPropPlacementError.collision(otherID) }
            }
        }
        let obstacles = CollisionVolumeWorld(volumes: placed.map(\.2))
        let capsule = WorldCapsule(radius: 0.25,height: 1.8)
        func clear(_ p: WorldVector3, radius: Float = 0.25) -> Bool {
            obstacles.canOccupy(.init(radius: max(0.25,radius),height: max(1.8,2*radius)),at: SIMD3(p.x,p.y,p.z))
        }
        guard clear(state.agentTransform.position) else { throw ResidentPropPlacementError.collision("居民") }
        for point in context.manifest.waypoints where point.enabled {
            guard clear(point.position,radius: point.arrivalRadius) else { throw ResidentPropPlacementError.blockedRoute(point.id) }
        }
        for activity in context.manifest.activities {
            guard clear(activity.transform.position) else { throw ResidentPropPlacementError.blockedRoute(activity.id) }
        }
        let points = Dictionary(uniqueKeysWithValues: context.manifest.waypoints.map { ($0.id,$0.position) })
        for route in context.manifest.routes where route.enabled {
            for pair in zip(route.waypointIDs,route.waypointIDs.dropFirst()) {
                guard let a=points[pair.0], let b=points[pair.1] else { continue }
                let dx=Double(b.x)-Double(a.x),dy=Double(b.y)-Double(a.y),dz=Double(b.z)-Double(a.z)
                let stepCount=ceil(sqrt(dx*dx+dy*dy+dz*dz)/0.1)
                guard stepCount.isFinite, stepCount <= 10_000 else { throw ResidentPropPlacementError.blockedRoute(route.id) }
                let start=SIMD3(a.x,a.y,a.z),end=SIMD3(b.x,b.y,b.z),d=end-start
                let steps=max(1,Int(stepCount))
                for i in 0...steps where !obstacles.canOccupy(capsule,at:start+d*(Float(i)/Float(steps))) {
                    throw ResidentPropPlacementError.blockedRoute(route.id)
                }
            }
        }
    }

    // Exact separating-axis footprint test for the authored yaw-only placement boxes.
    private static func overlap(_ a: WorldCollisionVolume,_ b: WorldCollisionVolume) -> Bool {
        guard abs(a.center.y-b.center.y) < a.halfExtents.y+b.halfExtents.y-0.0001 else { return false }
        func axes(_ q: WorldQuaternion)->[(Float,Float)] {
            let yaw=atan2(2*(q.w*q.y+q.x*q.z),1-2*(q.y*q.y+q.z*q.z))
            return [(cos(yaw),-sin(yaw)),(sin(yaw),cos(yaw))]
        }
        let aa=axes(a.rotation),bb=axes(b.rotation)
        for axis in aa+bb {
            let distance=abs((a.center.x-b.center.x)*axis.0+(a.center.z-b.center.z)*axis.1)
            func radius(_ box:WorldCollisionVolume,_ axes:[(Float,Float)])->Float {
                abs(axis.0*axes[0].0+axis.1*axes[0].1)*box.halfExtents.x + abs(axis.0*axes[1].0+axis.1*axes[1].1)*box.halfExtents.z
            }
            if distance >= radius(a,aa)+radius(b,bb)-0.0001 { return false }
        }
        return true
    }
}
