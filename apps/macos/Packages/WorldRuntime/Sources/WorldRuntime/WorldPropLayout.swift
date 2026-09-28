import Foundation

/// Created only by the trusted claim bridge; assetID is an opaque registry key, never a path.
public struct WorldGeneratedProp: Codable, Equatable, Sendable {
    public let objectID: String
    public let sourceWishID: String
    public let assetID: String
    public let displayName: String
    public let size: WorldVector3
    public let sourceHeight: Float
    public init(objectID: String, sourceWishID: String, assetID: String, displayName: String, size: WorldVector3, sourceHeight: Float) {
        self.objectID = objectID; self.sourceWishID = sourceWishID; self.assetID = assetID
        self.displayName = displayName; self.size = size; self.sourceHeight = sourceHeight
    }
    public var isValid: Bool {
        [objectID, sourceWishID, assetID, displayName].allSatisfy { !$0.isEmpty && $0.count <= 256 }
            && [size.x, size.y, size.z, sourceHeight].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 100 }
            && (size.y/sourceHeight).isFinite && size.y/sourceHeight > 0
    }
}

public struct WorldPropPlacement: Codable, Equatable, Sendable {
    public let surfaceID: String
    public let position: WorldVector3
    public let yaw: Float
    public init(surfaceID: String, position: WorldVector3, yaw: Float) {
        self.surfaceID = surfaceID; self.position = position; self.yaw = yaw
    }
}

public enum WorldPropHand: String, Codable, Equatable, Sendable {
    case rightHand
}

/// A resident-specific grip in final, metre-scaled prop space.
public struct WorldPropGripCalibration: Codable, Equatable, Sendable {
    public let avatarAssetID: String
    public let hand: WorldPropHand
    public let normalizedGrip: WorldVector3
    public let localOffset: WorldVector3
    public let localRotation: WorldQuaternion

    public init(
        avatarAssetID: String,
        hand: WorldPropHand,
        normalizedGrip: WorldVector3,
        localOffset: WorldVector3,
        localRotation: WorldQuaternion
    ) {
        self.avatarAssetID = avatarAssetID
        self.hand = hand
        self.normalizedGrip = normalizedGrip
        self.localOffset = localOffset
        self.localRotation = localRotation
    }

    public var isValid: Bool {
        guard !avatarAssetID.isEmpty, avatarAssetID.count <= 256 else { return false }
        let grip = [normalizedGrip.x, normalizedGrip.y, normalizedGrip.z]
        guard grip.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return false }
        let offset = [localOffset.x, localOffset.y, localOffset.z]
        guard offset.allSatisfy({ $0.isFinite && abs($0) <= 2 }) else { return false }
        let rotation = [localRotation.x, localRotation.y, localRotation.z, localRotation.w]
        guard rotation.allSatisfy(\.isFinite) else { return false }
        let lengthSquared = rotation.reduce(Float.zero) { $0 + $1 * $1 }
        return lengthSquared.isFinite && abs(lengthSquared - 1) <= 0.01
    }
}

public struct WorldHeldProp: Codable, Equatable, Sendable {
    public let objectID: String
    public let avatarAssetID: String
    public let hand: WorldPropHand
    public var returnState: WorldObjectState

    public init(
        objectID: String,
        avatarAssetID: String,
        hand: WorldPropHand,
        returnState: WorldObjectState
    ) {
        self.objectID = objectID
        self.avatarAssetID = avatarAssetID
        self.hand = hand
        self.returnState = returnState
    }
}

public enum WorldPropLayoutCommand: Codable, Equatable, Sendable {
    case register(WorldGeneratedProp)
    case place(objectID: String, placement: WorldPropPlacement)
    case withdraw(objectID: String)
    case hold(objectID: String, avatarAssetID: String, calibration: WorldPropGripCalibration)
    case adjustGrip(objectID: String, avatarAssetID: String, calibration: WorldPropGripCalibration)
    case returnHeld(objectID: String, avatarAssetID: String)
    case enableCapability(objectID: String, templateID: String)
    case undo
}

public enum WorldPropLayoutError: Error, Equatable, Sendable {
    case staleRevision(submitted: UInt64, current: UInt64)
    case requestConflict
    case invalidObject
    case invalidPlacement
    case nothingToUndo
    case heldPropAlreadyExists(objectID: String)
    case objectIsHeld(objectID: String)
    case heldPropMismatch
    case activeActivityConflict(activityID: String)
    case invalidGripCalibration
    case unsupportedCapability(templateID: String)
}

public struct WorldPropLayoutUndo: Codable, Equatable, Sendable {
    public let objectID: String
    public let previous: WorldObjectState
    public let previousHeldProp: WorldHeldProp?

    public init(objectID: String, previous: WorldObjectState, previousHeldProp: WorldHeldProp? = nil) {
        self.objectID = objectID
        self.previous = previous
        self.previousHeldProp = previousHeldProp
    }
}

public extension WorldObjectState {
    var generatedProp: WorldGeneratedProp? {
        guard let json = metadata["gmgn.generated-prop.v1"], let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(WorldGeneratedProp.self, from: data), value.isValid else { return nil }
        return value
    }
    var supportSurfaceID: String? { metadata["gmgn.support-surface.v1"] }
    var gripCalibration: WorldPropGripCalibration? {
        guard let json = metadata["gmgn.prop-grip.v1"], let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(WorldPropGripCalibration.self, from: data), value.isValid else { return nil }
        return value
    }
    var generatedCollisionVolume: WorldCollisionVolume? {
        guard isEnabled, let prop = generatedProp else { return nil }
        let p = transform.position
        return WorldCollisionVolume(id: prop.objectID, center: .init(x: p.x,y: p.y + prop.size.y/2,z: p.z),
            halfExtents: .init(x: prop.size.x/2,y: prop.size.y/2,z: prop.size.z/2), rotation: transform.rotation, isBlocking: true)
    }
}

extension WorldPropLayoutError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .staleRevision(_, current): "物件状态已经变化，请按版本 \(current) 重试。"
        case .requestConflict: "物件请求与已经处理的请求冲突。"
        case .invalidObject: "物件不存在或物件资料无效。"
        case .invalidPlacement: "物件摆放位置无效。"
        case .nothingToUndo: "没有可撤销的物件操作。"
        case let .heldPropAlreadyExists(objectID): "居民已经手持物件 \(objectID)。"
        case let .objectIsHeld(objectID): "物件 \(objectID) 正在手持中，请先放回。"
        case .heldPropMismatch: "手持物件或居民已经变化，请重新查看后再操作。"
        case let .activeActivityConflict(activityID): "居民正在进行活动 \(activityID)，暂时不能手持物件。"
        case .invalidGripCalibration: "物件握持位置或旋转无效。"
        case let .unsupportedCapability(templateID): "该物件不支持使用能力 \(templateID)，当前仅支持 coffee.brew 冲泡模板。"
        }
    }
}

/// Placement-only triangle/box test. Callers cache the local triangles for authored support regions.
/// This deliberately does not share the character controller's step-over behavior.
public enum WorldPropMeshClearance {
    /// 允许"贴地"判定放宽多少米：低于/等于 `supportHeight + restingTolerance` 的三角形
    /// 视为与承托面接触，不当作插进物件。
    ///
    /// 这个值只对**手工摆平的承托面**无所谓（0.1 毫米足够）；但真实舱体的地面是生成
    /// 出来的起伏网格，footprint 里总有比锚点高几毫米的三角形，于是同一块地面上一件
    /// 0.35×0.57 m 的物件只有 3% 的格子能放（90° 时 1%）。要不要放宽、放宽到多少是
    /// **产品取舍**：放得越宽，物件越可能肉眼可见地陷进地面。所以这里把它做成显式
    /// 参数（默认仍是原来的 0.1 毫米），让"如果放宽到 N 毫米会怎样"可以被实测，
    /// 而不是靠猜。
    public static let restingTolerance: Float = 0.0001

    public static func canPlace(_ box: WorldCollisionVolume, supportHeight: Float,
                                triangles: [WorldTriangle],
                                restingTolerance: Float = WorldPropMeshClearance.restingTolerance) -> Bool {
        let q=box.rotation, h=SIMD3(box.halfExtents.x,box.halfExtents.y,box.halfExtents.z)
        let center=SIMD3(box.center.x,box.center.y,box.center.z)
        guard [h.x,h.y,h.z].allSatisfy({ $0.isFinite && $0>0 }),
              [center.x,center.y,center.z,supportHeight,q.x,q.y,q.z,q.w].allSatisfy(\.isFinite),
              abs(q.x)<0.0001,abs(q.z)<0.0001 else { return false }
        let yaw=atan2(2*q.w*q.y,1-2*q.y*q.y),c=cos(yaw),s=sin(yaw)
        let ex=abs(c)*h.x+abs(s)*h.z,ez=abs(s)*h.x+abs(c)*h.z
        func local(_ p:SIMD3<Float>)->SIMD3<Float> {
            let d=p-center
            return SIMD3(c*d.x-s*d.z,d.y,s*d.x+c*d.z)
        }
        func cross(_ a:SIMD3<Float>,_ b:SIMD3<Float>)->SIMD3<Float> {
            SIMD3(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x)
        }
        func dot(_ a:SIMD3<Float>,_ b:SIMD3<Float>)->Float { a.x*b.x+a.y*b.y+a.z*b.z }
        let basis:[SIMD3<Float>]=[SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(0,0,1)]
        for t in triangles {
            let vertices=[t.first,t.second,t.third]
            guard vertices.allSatisfy({ [$0.x,$0.y,$0.z].allSatisfy(\.isFinite) }) else { return false }
            let minX=min(t.first.x,min(t.second.x,t.third.x)),maxX=max(t.first.x,max(t.second.x,t.third.x))
            let minY=min(t.first.y,min(t.second.y,t.third.y)),maxY=max(t.first.y,max(t.second.y,t.third.y))
            let minZ=min(t.first.z,min(t.second.z,t.third.z)),maxZ=max(t.first.z,max(t.second.z,t.third.z))
            // Permit contact with the authored support, never skip a triangle crossing into the item.
            if maxY <= supportHeight+restingTolerance || minY >= center.y+h.y || maxY <= center.y-h.y
                || maxX < center.x-ex || minX > center.x+ex || maxZ < center.z-ez || minZ > center.z+ez { continue }
            let points=vertices.map(local)
            let edges=[points[1]-points[0],points[2]-points[1],points[0]-points[2]]
            let axes=basis + [cross(edges[0],edges[1])] + edges.flatMap { edge in basis.map { cross(edge,$0) } }
            var separated=false
            for axis in axes {
                let length=sqrt(dot(axis,axis))
                if length < 0.0000001 { continue }
                let unit=axis/length
                let p=points.map { dot($0,unit) }
                let r=h.x*abs(unit.x)+h.y*abs(unit.y)+h.z*abs(unit.z)
                if p.min()! >= r-0.000001 || p.max()! <= -r+0.000001 { separated=true;break }
            }
            if !separated { return false }
        }
        return true
    }
}
