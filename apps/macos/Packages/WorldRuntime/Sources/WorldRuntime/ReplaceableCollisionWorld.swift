import Foundation

public final class ReplaceableCollisionWorld: WorldCollisionQuerying,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var current: any WorldCollisionQuerying

    public init(initial: any WorldCollisionQuerying) {
        current = initial
    }

    public func replace(with collisionWorld: any WorldCollisionQuerying) {
        lock.withLock { current = collisionWorld }
    }

    public func canOccupy(
        _ capsule: WorldCapsule,
        at position: SIMD3<Float>
    ) -> Bool {
        lock.withLock { current.canOccupy(capsule, at: position) }
    }

    public func groundHeight(at position: SIMD3<Float>) -> Float? {
        lock.withLock { current.groundHeight(at: position) }
    }

    public func canTraverse(
        _ capsule: WorldCapsule,
        from start: SIMD3<Float>,
        to destination: SIMD3<Float>,
        maximumStepHeight: Float
    ) -> Bool {
        lock.withLock {
            current.canTraverse(
                capsule,
                from: start,
                to: destination,
                maximumStepHeight: maximumStepHeight
            )
        }
    }
}
