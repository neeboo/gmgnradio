import Foundation

// Context contract stub; the projection gate is the actual production bridge.
// This verifies rejection behavior, not Unity rendered-frame acceptance.
struct TestPosition: Codable { var x: Float = 1; var y: Float = 0; var z: Float = 2 }
struct TestTransform: Codable { var position = TestPosition() }
enum TestPhase: String, Codable { case approach, enter, loop }
struct TestActivity: Codable { var id = "music.listen"; var phase = TestPhase.loop }
struct TestSnapshot: Codable { var activeActivity: TestActivity? = TestActivity() }
struct TestSeat { var objectID = "sofa"; var contactPoint = TestPosition() }
@MainActor final class WorldAgentContext {
    struct Manifest { var worldID = "world" }
    struct State { var agentTransform = TestTransform(); var revision: UInt64 = 1; var activeActivity: TestActivity? = TestActivity() }
    struct Contract { var motionIDs: [String] = []; var durationSeconds: Double? = nil }
    struct Definition { func contract(for phase: TestPhase) -> Contract? { nil } }
    struct Catalog { func definition(id: String) -> Definition? { nil } }
    var activityCatalog = Catalog()
    var activeSeatProjection: TestSeat?
    var runningActivity: TestActivity? { activeActivitySnapshot }
    var activeActivitySnapshot: TestActivity? { storedSnapshot.activeActivity }
    var waitsForRenderedActivityCompletion: (() -> Bool)?
    var manifest = Manifest(), state = State()
    private var storedSnapshot = TestSnapshot()
    var snapshotReads = 0
    var snapshot: TestSnapshot {
        get { snapshotReads += 1; return storedSnapshot }
        set { storedSnapshot = newValue }
    }
    var currentActivityRequestID: String? = "request"
    var ticking = false
    var stopCheckpoint: Bool?
    func startTicking() { ticking = true }
    func stopTicking(checkpoint: Bool = true) { ticking = false; stopCheckpoint = checkpoint }
}
@main struct ActivityBridgeRegression {
    @MainActor static func main() async throws {
        let context = WorldAgentContext(), bridge = UnityActivityBridge(context: context)
        _ = bridge.snapshot()
        precondition(context.snapshotReads == 1, "One activity projection must read the full snapshot only once")
        context.snapshotReads = 0
        var frame: [String: Any] = ["worldID": "world", "requestID": "request", "phase": "loop", "position": [1.0, 0.0, 2.0]]
        precondition(!bridge.hasRenderedLoop(activityID: "music.listen"))
        frame["worldID"] = "other"; precondition(!bridge.acknowledgeProjection(frame))
        frame["worldID"] = "world"; frame["requestID"] = "stale"
        precondition(!bridge.acknowledgeProjection(frame))
        frame["requestID"] = "request"; frame["position"] = [10.0, 0.0, 2.0]
        precondition(!bridge.acknowledgeProjection(frame))
        frame["position"] = [1.0, 0.0, 2.0]; frame["phase"] = "approach"
        precondition(!bridge.acknowledgeProjection(frame))
        frame["phase"] = "loop"; precondition(bridge.acknowledgeProjection(frame))
        precondition(bridge.hasRenderedLoop(activityID: "music.listen"))
        precondition(context.snapshotReads == 0, "Receipt and loop gates must not build navigation snapshots")
        bridge.motionProjection = { (true, ["id": "walk", "loop": true]) }
        precondition(!bridge.acknowledgeProjection(frame))
        frame["motionID"] = "walk"; frame["motionReady"] = true
        precondition(!bridge.acknowledgeProjection(frame))
        frame["motionPlaying"] = true; precondition(bridge.acknowledgeProjection(frame))
        context.snapshot.activeActivity?.phase = .enter
        frame["phase"] = "enter"
        bridge.motionProjection = { (true, ["id": "operate", "loop": false]) }
        bridge.contactProjection = { [1, 0, 2] }
        bridge.contactObjectProjection = { "prop.jukebox" }
        frame["motionID"] = "operate"
        var completed = 0
        bridge.onFiniteMotionCompleted = { request, phase in
            precondition(request == "request" && phase == "enter"); completed += 1
        }
        frame["motionCompleted"] = false
        precondition(bridge.acknowledgeProjection(frame) && completed == 0)
        frame["motionCompleted"] = true; frame["motionPlaying"] = true
        precondition(bridge.acknowledgeProjection(frame) && completed == 0)
        frame["motionPlaying"] = false
        precondition(bridge.acknowledgeProjection(frame) && completed == 1,
                     "Completed finite operation must advance its matching phase")
        precondition(bridge.snapshot()["contactConfirmedObjectID"] == nil,
                     "Finite completion never invents hand contact")
        precondition(bridge.acknowledgeProjection(frame) && completed == 1,
                     "Repeated completion must not advance twice")
        var staleCompletion = frame
        staleCompletion["requestID"] = "previous-request"
        precondition(!bridge.acknowledgeProjection(staleCompletion) && completed == 1,
                     "Stale completion must not advance the current activity")
        context.snapshot.activeActivity?.phase = .loop; frame["phase"] = "loop"
        bridge.motionProjection = nil
        bridge.contactProjection = { [1, 0, 2] }
        bridge.contactObjectProjection = { "prop.jukebox" }
        precondition(bridge.acknowledgeProjection(frame) && !bridge.hasRenderedLoop(activityID: "music.listen"))
        precondition(bridge.snapshot()["contactConfirmedObjectID"] == nil)
        frame["contactReady"] = true; frame["contactPosition"] = [1.1349, 0, 2]
        precondition(bridge.acknowledgeProjection(frame) && !bridge.hasRenderedLoop(activityID: "music.listen"))
        precondition(bridge.snapshot()["contactConfirmedObjectID"] == nil)
        frame["contactPosition"] = [1.09, 0, 2]
        precondition(bridge.acknowledgeProjection(frame))
        precondition(bridge.snapshot()["contactConfirmedObjectID"] as? String == "prop.jukebox")
        bridge.contactProjection = nil
        context.currentActivityRequestID = "replacement"
        precondition(bridge.snapshot()["contactConfirmedObjectID"] == nil)
        precondition(!bridge.hasRenderedLoop(activityID: "music.listen"))
        do {
            try await bridge.waitForRenderedLoop(activityID: "music.listen", requestID: "request", timeout: 0)
            fatalError("Replaced request must not authorize playback")
        } catch is CancellationError { }
        context.currentActivityRequestID = "request"; context.state.agentTransform.position.x = 2
        precondition(!bridge.hasRenderedLoop(activityID: "music.listen"))
        do {
            try await bridge.waitForRenderedLoop(activityID: "music.listen", requestID: "request", timeout: 0)
            fatalError("Missing rendered frame must time out")
        } catch UnityActivityBridge.ProjectionError.notRendered { }
        // Collection requires the current rendered loop, never hand contact.
        let collection = WorldAgentContext()
        collection.snapshot.activeActivity?.id = "wish_machine.collect"
        let collectionBridge = UnityActivityBridge(context: collection)
        var collectionFrame: [String: Any] = ["worldID": "world", "requestID": "request",
            "phase": "loop", "position": [1.0, 0.0, 2.0], "contactReady": false]
        precondition(!collectionBridge.hasRenderedLoop(activityID: "wish_machine.collect"))
        precondition(collectionBridge.acknowledgeProjection(collectionFrame))
        precondition(collectionBridge.hasRenderedLoop(activityID: "wish_machine.collect"))
        collection.currentActivityRequestID = "next"
        precondition(!collectionBridge.hasRenderedLoop(activityID: "wish_machine.collect"))
        collectionFrame["requestID"] = "stale"
        precondition(!collectionBridge.acknowledgeProjection(collectionFrame))
        collectionBridge.close()
        bridge.start(); precondition(context.ticking)
        bridge.close(); precondition(!context.ticking && context.stopCheckpoint == false)
        precondition(!bridge.acknowledgeProjection(frame))
        let seated = WorldAgentContext()
        seated.activeSeatProjection = TestSeat()
        let seatBridge = UnityActivityBridge(context: seated)
        var seatFrame: [String: Any] = ["worldID": "world", "requestID": "request",
            "phase": "loop", "position": [1.0,0.0,2.0], "seatObjectID": "sofa",
            "seatReady": false, "seatPosition": [1.0,0.0,2.0]]
        precondition(!seatBridge.acknowledgeProjection(seatFrame))
        seatFrame["seatReady"] = true; seatFrame["seatObjectID"] = "old-sofa"
        precondition(!seatBridge.acknowledgeProjection(seatFrame))
        seatFrame["seatObjectID"] = "sofa"; seatFrame["seatPosition"] = [0.0,0.0,0.0]
        precondition(!seatBridge.acknowledgeProjection(seatFrame))
        seatFrame["seatPosition"] = [1.0,0.0,2.0]
        precondition(seatBridge.acknowledgeProjection(seatFrame))
        seatBridge.close()
        print("Unity activity projection rejection and calibrated seat receipt regression passed")
    }
}
