import Foundation

/// A route returned by a world-specific navigation adapter.
///
/// `waypointIDs` and `points` omit the waypoint the actor is already standing
/// on. This lets an executor consume every point as a future movement target.
public struct WorldPath: Codable, Equatable, Sendable {
    public let destinationID: String
    public let waypointIDs: [String]
    public let points: [WorldVector3]
    public let totalLength: Float
    public let arrivalTolerance: Float

    public var hasArrived: Bool {
        waypointIDs.isEmpty
    }

    public init(
        destinationID: String,
        waypointIDs: [String],
        points: [WorldVector3],
        totalLength: Float,
        arrivalTolerance: Float
    ) {
        self.destinationID = destinationID
        self.waypointIDs = waypointIDs
        self.points = points
        self.totalLength = totalLength
        self.arrivalTolerance = arrivalTolerance
    }
}

public enum WorldNavigationError: Error, Equatable, Sendable {
    case unknownAnchor(anchorID: String)
    case disabledAnchor(anchorID: String)
    case noEnabledWaypoint
    case unreachable(destinationID: String)
}

/// Replaceable seam for the authored waypoint graph used by the first world.
/// A future `RecastNavigationRouter` can implement the same contract.
public protocol WorldNavigationRouting: Sendable {
    func route(
        from position: SIMD3<Float>,
        to anchorID: String
    ) throws -> WorldPath

    /// 让调用方把**运行时可达性**注入路径规划。
    ///
    /// 物件摆放之后成为障碍，而导航图是在烘焙时建好的。图不会为此重建：它在提议路径上
    /// 逐段调用这个闭包，发现受阻的有向边就记下来并改道（惰性重规划）。所以"居民绕过
    /// 家具"不需要重烘焙，只需要把碰撞世界接进来。
    func route(
        from position: SIMD3<Float>,
        to anchorID: String,
        canTraverse: (SIMD3<Float>, SIMD3<Float>) -> Bool
    ) throws -> WorldPath
}

/// A vertical character capsule whose `position` is interpreted as its feet.
public struct WorldCapsule: Codable, Equatable, Sendable {
    public let radius: Float
    public let height: Float

    public init(radius: Float, height: Float) {
        self.radius = radius
        self.height = height
    }

    public var isValid: Bool {
        radius.isFinite
            && height.isFinite
            && radius > 0
            && height >= radius * 2
    }
}

/// Replaceable seam for the authored oriented boxes used by the first world.
/// A future `JoltCollisionWorld` can implement the same contract.
public protocol WorldCollisionQuerying: Sendable {
    func canOccupy(
        _ capsule: WorldCapsule,
        at position: SIMD3<Float>
    ) -> Bool

    func groundHeight(at position: SIMD3<Float>) -> Float?

    func canTraverse(
        _ capsule: WorldCapsule,
        from start: SIMD3<Float>,
        to destination: SIMD3<Float>,
        maximumStepHeight: Float
    ) -> Bool
}

public extension WorldCollisionQuerying {
    func canTraverse(
        _ capsule: WorldCapsule,
        from start: SIMD3<Float>,
        to destination: SIMD3<Float>,
        maximumStepHeight: Float
    ) -> Bool {
        guard capsule.isValid,
              maximumStepHeight.isFinite, maximumStepHeight >= 0,
              start.x.isFinite, start.y.isFinite, start.z.isFinite,
              destination.x.isFinite,
              destination.y.isFinite,
              destination.z.isFinite,
              let startGround = groundHeight(at: start),
              let destinationGround = groundHeight(at: destination),
              abs(destinationGround - startGround) <= maximumStepHeight + 0.0001
        else {
            return false
        }

        let groundedStart = SIMD3(start.x, startGround, start.z)
        guard canOccupy(capsule, at: groundedStart) else {
            return false
        }

        let distance = worldDistance(start, destination)
        let rawStepCount = ceil(distance / capsule.radius)
        guard rawStepCount.isFinite, rawStepCount <= Float(Int.max) else {
            return false
        }

        let stepCount = max(1, Int(rawStepCount))
        var previousGround = startGround
        for step in 1 ... stepCount {
            let progress = Float(step) / Float(stepCount)
            let sample = start + (destination - start) * progress
            guard let sampleGround = groundHeight(at: sample),
                  abs(sampleGround - previousGround) <= maximumStepHeight + 0.0001
            else {
                return false
            }

            let groundedSample = SIMD3(sample.x, sampleGround, sample.z)
            if !canOccupy(capsule, at: groundedSample) {
                // A capsule meets a legal step's vertical face before its
                // center reaches the higher surface. Lift it to that surface
                // for the sweep rather than treating the riser as a wall.
                let clearanceGround = max(
                    sampleGround,
                    max(startGround, destinationGround)
                )
                let liftedSample = SIMD3(sample.x, clearanceGround, sample.z)
                guard clearanceGround - sampleGround <= maximumStepHeight + 0.0001,
                      canOccupy(capsule, at: liftedSample)
                else {
                    return false
                }
            }
            previousGround = sampleGround
        }
        return true
    }
}

extension WorldVector3 {
    var simd3: SIMD3<Float> {
        SIMD3(x, y, z)
    }

    init(_ value: SIMD3<Float>) {
        self.init(x: value.x, y: value.y, z: value.z)
    }
}

func worldDistance(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
    let delta = lhs - rhs
    return sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
}
