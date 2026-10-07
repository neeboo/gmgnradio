import Foundation
import WorldRuntime
@testable import UnityMediaHost

private let identityMatrix: [Float] = [
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
]

private func point(_ x: Float, _ y: Float = 0, _ z: Float) -> WorldVector3 {
    WorldVector3(x: x, y: y, z: z)
}

private func transform(_ position: WorldVector3) -> WorldTransform {
    WorldTransform(
        position: position,
        rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
        scale: WorldVector3(x: 1, y: 1, z: 1)
    )
}

private let manifest = WorldManifest(
    schemaVersion: 1,
    packageID: "fixture.coordinate-movement",
    packageVersion: "1",
    worldID: "fixture.coordinate-movement",
    displayName: "Coordinate movement fixture",
    calibration: WorldCalibration(visualToGameplay: identityMatrix, metersPerUnit: 1),
    spawn: transform(point(0, 0, 0)),
    collisionVolumes: [],
    waypoints: [
        WorldWaypoint(id: "wp.spawn", position: point(0, 0, 0), arrivalRadius: 0.02, enabled: true),
        WorldWaypoint(id: "wp.detour", position: point(0, 0, 2), arrivalRadius: 0.02, enabled: true),
        WorldWaypoint(id: "wp.exit", position: point(2, 0, 2), arrivalRadius: 0.02, enabled: true),
    ],
    routes: [
        WorldRoute(
            id: "route.detour",
            waypointIDs: ["wp.spawn", "wp.detour", "wp.exit"],
            bidirectional: true,
            enabled: true
        ),
    ],
    activities: [],
    cameras: [],
    capabilities: [],
    resources: []
)

private final class PersistenceSpy: WorldStatePersisting, @unchecked Sendable {
    private(set) var saved: [WorldState] = []

    func load() throws -> WorldState? { nil }
    func save(_ state: WorldState) throws { saved.append(state) }
}

private enum CollisionMode {
    case floor
    case missingTargetGround
    case occupiedTarget
    case blocked
    case detour
}

private struct FixtureCollisionWorld: WorldCollisionQuerying {
    let mode: CollisionMode

    private func isTarget(_ position: SIMD3<Float>) -> Bool {
        abs(position.x - 2) < 0.001 && abs(position.z) < 0.001
    }

    func groundHeight(at position: SIMD3<Float>) -> Float? {
        mode == .missingTargetGround && isTarget(position) ? nil : 0
    }

    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool {
        !(mode == .occupiedTarget && isTarget(position))
    }

    func canTraverse(
        _ capsule: WorldCapsule,
        from start: SIMD3<Float>,
        to destination: SIMD3<Float>,
        maximumStepHeight: Float
    ) -> Bool {
        let stationary = hypot(start.x - destination.x, start.z - destination.z) < 0.001
        switch mode {
        case .blocked:
            return stationary
        case .detour:
            // The direct spawn -> target leg is closed. The authored route via
            // (0, 2) and (2, 2), plus its final leg to the target, stays open.
            return stationary || !(abs(start.x) < 0.001 && abs(start.z) < 0.001 && isTarget(destination))
        case .floor, .missingTargetGround, .occupiedTarget:
            return true
        }
    }
}

@MainActor
private var failures = 0

@MainActor
private func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func isAt(_ position: WorldVector3, _ expected: WorldVector3, tolerance: Float = 0.001) -> Bool {
    abs(position.x - expected.x) <= tolerance
        && abs(position.y - expected.y) <= tolerance
        && abs(position.z - expected.z) <= tolerance
}

@MainActor
private func makeContext(
    _ mode: CollisionMode,
    persistence: PersistenceSpy = PersistenceSpy()
) throws -> (WorldAgentContext, PersistenceSpy) {
    (
        try WorldAgentContext(
            manifest: manifest,
            persistence: persistence,
            walkingSpeed: 4,
            initialCollisionWorld: FixtureCollisionWorld(mode: mode)
        ),
        persistence
    )
}

@MainActor
private func assertRejectedWithoutStarting(
    _ label: String,
    mode: CollisionMode,
    position: WorldVector3,
    expectedError: (Error) -> Bool,
    revision: ((UInt64) -> UInt64)? = nil
) throws {
    let (context, persistence) = try makeContext(mode)
    let before = context.state
    let saveCount = persistence.saved.count
    do {
        _ = try context.move(
            to: position,
            requestID: "request.\(label)",
            expectedRevision: revision?(before.revision) ?? before.revision
        )
        check(false, "\(label) is rejected")
    } catch {
        check(expectedError(error), "\(label) returns its admission error")
    }
    check(context.currentMovementRequestID == nil, "\(label) does not start walking")
    check(context.snapshot.movement == nil, "\(label) leaves no movement projection")
    check(context.state == before, "\(label) leaves authority state unchanged")
    check(persistence.saved.count == saveCount, "\(label) does not persist a control change")
}

@MainActor
private func tickToCompletion(_ context: WorldAgentContext) throws {
    for _ in 0..<80 where context.currentMovementRequestID != nil {
        try context.tick(deltaTime: 0.1)
    }
}

@main
private struct CoordinateMovementTests {
    @MainActor
    static func main() throws {
        try assertRejectedWithoutStarting(
            "missing ground",
            mode: .missingTargetGround,
            position: point(2, 0, 0),
            expectedError: { if case WorldCoordinateMovementError.missingGround = $0 { true } else { false } }
        )
        try assertRejectedWithoutStarting(
            "floating input",
            mode: .floor,
            position: point(2, 0.051, 0),
            expectedError: { if case WorldCoordinateMovementError.offGround = $0 { true } else { false } }
        )
        try assertRejectedWithoutStarting(
            "occupied capsule",
            mode: .occupiedTarget,
            position: point(2, 0, 0),
            expectedError: { if case WorldCoordinateMovementError.occupied = $0 { true } else { false } }
        )
        try assertRejectedWithoutStarting(
            "blocked path",
            mode: .blocked,
            position: point(2, 0, 0),
            expectedError: { if case WorldCoordinateMovementError.blocked = $0 { true } else { false } }
        )
        try assertRejectedWithoutStarting(
            "stale CAS",
            mode: .floor,
            position: point(2, 0, 0),
            expectedError: {
                if case let WorldSimulationError.staleRevision(submitted, current) = $0 {
                    return submitted == current + 1
                }
                return false
            },
            revision: { $0 + 1 }
        )

        let directRequest = "request.direct"
        let directTarget = point(2, 0, 0)
        let (direct, directPersistence) = try makeContext(.floor)
        let directPath = try direct.move(
            to: point(2, 0.05, 0),
            requestID: directRequest,
            expectedRevision: direct.state.revision
        )
        check(directPath.points == [directTarget], "5 cm tolerance resolves to the exact measured ground")
        check(direct.currentMovementRequestID == directRequest, "valid direct move starts with caller request identity")
        try tickToCompletion(direct)
        check(isAt(direct.state.agentTransform.position, directTarget), "direct move reaches exact grounded target")
        check(direct.currentMovementRequestID == nil && direct.snapshot.movement == nil, "direct walking ends")
        check(direct.events.contains {
            if case .movementCompleted(requestID: directRequest, destinationID: "coordinate.\(directRequest)") = $0.kind {
                return true
            }
            return false
        }, "direct move records the matching request outcome")
        check(
            directPersistence.saved.last.map { isAt($0.agentTransform.position, directTarget) } == true,
            "direct final position is durable"
        )

        let detourRequest = "request.detour"
        let detourTarget = point(2, 0, 0)
        let (detour, detourPersistence) = try makeContext(.detour)
        let detourPath = try detour.move(
            to: detourTarget,
            requestID: detourRequest,
            expectedRevision: detour.state.revision
        )
        check(detourPath.points.last == detourTarget, "detour preserves the requested grounded endpoint")
        check(detourPath.points.contains { $0.z > 1.9 }, "blocked direct leg uses an authored waypoint detour")
        try tickToCompletion(detour)
        check(isAt(detour.state.agentTransform.position, detourTarget), "detour reaches exact grounded target")
        check(detour.currentMovementRequestID == nil && detour.snapshot.movement == nil, "detour walking ends")
        check(detour.events.contains {
            if case .movementCompleted(requestID: detourRequest, destinationID: "coordinate.\(detourRequest)") = $0.kind {
                return true
            }
            return false
        }, "detour records the matching request outcome")
        check(
            detourPersistence.saved.last.map { isAt($0.agentTransform.position, detourTarget) } == true,
            "detour final position is durable"
        )

        print("\(failures == 0 ? "PASS" : "FAIL"): coordinate movement behavior, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
