import Foundation
import WorldRuntime

struct FlatActivityFloor: WorldCollisionQuerying {
    func groundHeight(at position: SIMD3<Float>) -> Float? { 0 }
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool { true }
}
struct EmptyActivityPreImage: WorldStatePersisting {
    func load() throws -> WorldState? { nil }
    func save(_ state: WorldState) throws { fatalError("Legacy writes are forbidden") }
}
final class SwitchingActivityFloor: WorldCollisionQuerying, @unchecked Sendable {
    var closed = false
    func groundHeight(at position: SIMD3<Float>) -> Float? { 0 }
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool { !closed }
}
@main struct WorldActivityClientAcceptance {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Provide isolated endpoint file") }
        let transport = TaskdHTTPAuthorityClient(endpointFile: CommandLine.arguments[1], helperPath: "",
            allowsLaunching: false, timeout: 1)
        var calls = 0
        let client = RustWorldActivityClient { method, input in
            calls += 1
            return try transport.call(method: method, params: input)
        }
        let url = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin/world.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["waypoints"] = [
            ["id":"a","position":["x":0,"y":0,"z":0],"arrivalRadius":0.1,"enabled":true],
            ["id":"b","position":["x":2,"y":0,"z":0],"arrivalRadius":0.1,"enabled":true]
        ]
        json["routes"] = [["id":"fixture","waypointIDs":["a","b"],"enabled":true,"bidirectional":true]]
        var spawn = json["spawn"] as! [String: Any]
        spawn["position"] = ["x":0,"y":0,"z":0]
        json["spawn"] = spawn
        json["collisionVolumes"] = []
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: JSONSerialization.data(withJSONObject: json))
        let routePersistence = AuthorityWorldStatePersistence(manifest:manifest,
            preImage:LegacyWorldStatePreImage(archive:EmptyActivityPreImage(),candidateURLs:[]),
            endpointFile:CommandLine.arguments[1],helperPath:"",allowsLaunching:false)
        let floor = SwitchingActivityFloor()
        let context = try WorldAgentContext(manifest: manifest, persistence:routePersistence, walkingSpeed: 1,
            initialCollisionWorld: floor, rustWorldActivity: client)
        let initialCalls = calls
        let route = try context.move(to: "b")
        precondition(route.waypointIDs == ["b"] && route.totalLength == 2)
        precondition(abs(route.arrivalTolerance - 0.1) < 0.001)
        let plannedCalls = calls
        precondition(plannedCalls - initialCalls == 4, "One entry probe, one edge probe, one Rust route receipt, one Rust movement lease")
        for _ in 0..<40 { try context.tick(deltaTime: 0.1) }
        precondition(calls == plannedCalls + 1, "40 frames emit only one terminal arrival receipt, never frame RPCs")
        precondition(context.currentMovementRequestID == nil && abs(context.state.agentTransform.position.x - 2) < 0.001)
        let arrived = try context.planRoute(to: "b")
        precondition(arrived.points.isEmpty && calls == plannedCalls + 2)
        do {
            _ = try client.route(manifest: manifest, start: WorldVector3(x:0,y:0,z:0), destinationID:"b",
                canTraverse: { _,_ in false })
            fatalError("Native blocked evidence must reject Rust route")
        } catch WorldAuthorityError.daemon(let code) {
            precondition(code == "world_activity_unreachable")
        }
        let failing = RustWorldActivityClient { _,_ in throw NSError(domain:"isolated",code:1) }
        do {
            let failingContext = try WorldAgentContext(manifest:manifest, initialCollisionWorld:FlatActivityFloor(), rustWorldActivity:failing)
            _ = try failingContext.move(to:"b"); fatalError("No Swift route fallback")
        } catch { }
        _ = try context.move(to:WorldVector3(x:3,y:0,z:0),requestID:"coordinate-native",
            expectedRevision:context.state.revision)
        precondition(context.currentMovementRequestID == "coordinate-native")
        for _ in 0..<20 { try context.tick(deltaTime:0.1) }
        precondition(abs(context.state.agentTransform.position.x - 3) < 0.001 && context.currentMovementRequestID == nil)
        _ = try context.move(to:"a")
        try context.tick(deltaTime:0.1)
        floor.closed = true
        try context.tick(deltaTime:0.1)
        precondition(context.currentMovementRequestID == nil && client.movement == nil,
            "Native block fact and Rust bounded replan failure stop the actual movement")
        let blockedCalls = calls
        for _ in 0..<10 { try context.tick(deltaTime:0.1) }
        precondition(calls == blockedCalls,"Stopped idle frames cannot retry a blocked navigation command")
        floor.closed = false
        json["worldID"] = "phase-fixture"
        json["activities"] = [["id":"seat","action":"sit","entryWaypointID":"b","transform":spawn,
            "motionID":"fixture-motion","propIDs":[],"interruptible":true],
            ["id":"home.walk","action":"walk","entryWaypointID":"a","transform":spawn,
             "propIDs":[],"interruptible":true]]
        json["activityDefinitions"] = []
        let phaseManifest = try JSONDecoder().decode(WorldManifest.self, from: JSONSerialization.data(withJSONObject:json))
        let persistence = AuthorityWorldStatePersistence(manifest:phaseManifest,
            preImage:LegacyWorldStatePreImage(archive:EmptyActivityPreImage(),candidateURLs:[]),
            endpointFile:CommandLine.arguments[1],helperPath:"",allowsLaunching:false)
        let phaseClient = RustWorldActivityClient { try transport.call(method:$0,params:$1) }
        let phase = try WorldAgentContext(manifest:phaseManifest,persistence:persistence,walkingSpeed:1,
            initialCollisionWorld:FlatActivityFloor(),rustWorldActivity:phaseClient)
        var phaseFacts: [WorldEvent] = []
        phase.onRustEventsPublished = { phaseFacts.append(contentsOf:$0) }
        phase.waitsForRenderedActivityCompletion = { true }
        try phase.startActivity(id:"seat")
        precondition(phaseFacts.count == 1 && phaseFacts[0].kind == .activityStarted(activityID:"seat"))
        let requestID = phase.currentActivityRequestID!
        precondition(phase.runningActivity?.phase == .approach)
        let run = phaseClient.running!
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let checkpoint = try JSONSerialization.jsonObject(with:encoder.encode(phase.state))
        for (badID,badPhase) in [("forged","approach"),(requestID,"loop")] {
            do {
                _ = try transport.call(method:"world_activity_receipt",params:["worldID":phaseManifest.worldID,
                    "hostSessionID":phaseClient.hostSessionID,"requestID":UUID().uuidString,
                    "expectedRevision":persistence.lastAppliedRevision,"checkpoint":checkpoint,
                    "runRequestID":badID,"generation":run.generation,"phaseGeneration":run.phaseGeneration,
                    "phase":badPhase,"kind":"clipCompleted"])
                fatalError("Unmatched identity/phase must never advance")
            } catch WorldAuthorityError.daemon(let code) { precondition(code == "world_activity_stale_receipt") }
        }
        let elapsed = phase.state.activeActivity!.elapsedActiveTime
        try phase.tick(deltaTime:0.1)
        precondition(phase.state.activeActivity!.elapsedActiveTime == elapsed, "Native frame cannot write Rust-owned activity elapsed")
        for _ in 0..<25 { try phase.tick(deltaTime:0.1) }
        precondition(phase.runningActivity?.phase == .enter)
        try phase.completeActivityPlayback(requestID:"old",phase:.enter)
        precondition(phase.runningActivity?.phase == .enter)
        try phase.completeActivityPlayback(requestID:requestID,phase:.enter)
        precondition(phase.runningActivity?.phase == .loop)
        try phase.completeActivityPlayback(requestID:requestID,phase:.loop)
        precondition(phase.runningActivity?.phase == .loop)
        try phase.stopActivity()
        precondition(phase.currentActivityRequestID == nil && phase.state.activeActivity == nil)
        precondition(phaseFacts.count == 2 && phaseFacts[1].kind == .activityCancelled(activityID:"seat",reason:nil))
        precondition(phaseFacts[1].sequence > phaseFacts[0].sequence,
            "Lifecycle observations consume persisted fact sequence, not native frame sequence")
        let persisted = try persistence.readSnapshot()
        precondition(persisted?.activeActivity == nil)
        try phase.startActivity(id:"home.walk")
        let patrolID = phase.currentActivityRequestID!
        var targets = Set<String>()
        for _ in 0..<80 {
            try phase.tick(deltaTime:0.1)
            if case let .walk(destinationID)? = phase.runningActivity?.activity { targets.insert(destinationID) }
        }
        precondition(targets.count == 2 && phase.currentActivityRequestID == patrolID,
            "Rust patrol target selection keeps one actual request over multiple physical legs")
        try phase.stopActivity()
        // Exercise the actual Swift metadata consumer and default Foundation
        // embedded Date decoder against the Rust transaction projection.
        var usageWorld = phase.state
        usageWorld.worldID = "usage-native-fixture"
        usageWorld.activeActivity = nil
        usageWorld.objectStates["generated"] = WorldObjectState(transform:usageWorld.agentTransform,metadata:[
            "gmgn.generated-prop.v1":"{\"objectID\":\"generated\",\"size\":{\"x\":1,\"y\":1,\"z\":1}}",
            "gmgn.prop-capability.v1":"{\"objectID\":\"generated\",\"templateID\":\"coffee.brew\"}",
            "note":"preserve user note"])
        let usageAuthority = WorldAuthorityClient(worldID:usageWorld.worldID,endpointFile:CommandLine.arguments[1],
            helperPath:"",allowsLaunching:false)
        _ = try usageAuthority.commit(state:usageWorld,expectedRevision:0,intent:["fixture":"usage"])
        let usageClient = RustWorldActivityClient { try transport.call(method:$0,params:$1) }
        _ = try usageClient.bindCatalog(worldID:usageWorld.worldID,definitions:phase.activityCatalog.definitions,
            usageBindings:["seat":["objectID":"generated","templateID":"coffee.brew"]])
        let usageStart = try usageClient.start(world:usageWorld,expectedRevision:usageAuthority.snapshot()!.recordRevision,
            definitionID:"seat",capsuleRadius:0.3,waitsForRenderedCompletion:true,
            measureApproach:{ .init(key:$0.key,position:$0.position,grounded:$0.position,canTraverse:true) },
            canTraverse:{ _,_ in true })
        let runningUsage = usageStart.snapshot!.record!.state.objectStates["generated"]!.propUsage!
        precondition(runningUsage.status == .running && runningUsage.activityRequestID == usageClient.running!.requestID)
        precondition(abs(runningUsage.updatedAt.timeIntervalSince(usageWorld.worldTime)) < 0.001)
        var forgedUsage = usageStart.snapshot!.record!.state
        forgedUsage.objectStates["generated"]!.metadata.removeValue(forKey:"gmgn.prop-usage.v1")
        do {
            _ = try usageAuthority.commit(state:forgedUsage,expectedRevision:usageStart.snapshot!.record!.recordRevision,
                intent:["fixture":"forged-usage-clear"])
            fatalError("Ordinary state writer cleared Rust usage")
        } catch WorldAuthorityError.daemon(let code) { precondition(code == "world_activity_owned_projection") }
        let forgedObject = try JSONSerialization.jsonObject(with:JSONEncoder().encode(forgedUsage.objectStates["generated"]!))
        do {
            _ = try transport.call(method:"world_commit",params:["worldID":usageWorld.worldID,
                "requestID":UUID().uuidString,"expectedRevision":usageStart.snapshot!.record!.recordRevision,
                "producer":"world.activity","ops":[["op":"upsertObject","objectID":"generated","object":forgedObject]]])
            fatalError("Producer text granted forged object usage authority")
        } catch WorldAuthorityError.daemon(let code) { precondition(code == "world_activity_owned_projection") }
        let usageStop = try usageClient.receipt(world:usageStart.snapshot!.record!.state,
            expectedRevision:usageStart.snapshot!.record!.recordRevision,run:usageClient.running!,kind:"stopped",stop:true)
        precondition(usageStop.snapshot!.record!.state.objectStates["generated"]!.propUsage!.status == .stopped)
        precondition(usageStop.snapshot!.record!.state.objectStates["generated"]!.metadata["note"] == "preserve user note")
        for elapsed in [0.0,1.0,0.125] {
            json["worldID"] = "clock-fixture-\(elapsed)"
            let clockManifest = try JSONDecoder().decode(WorldManifest.self,from:JSONSerialization.data(withJSONObject:json))
            var seed = WorldSimulation(manifest:clockManifest,startedAt:Date()).state
            seed.activeActivity = WorldActivityState(activityID:"legacy-unknown",status:.running,
                startedAt:seed.worldTime,elapsedActiveTime:elapsed)
            let seedClient = WorldAuthorityClient(worldID:clockManifest.worldID,endpointFile:CommandLine.arguments[1],
                helperPath:"",allowsLaunching:false)
            _ = try seedClient.commit(state:seed,expectedRevision:0,intent:["fixture":"clock-roundtrip"])
            let clockPersistence = AuthorityWorldStatePersistence(manifest:clockManifest,
                preImage:LegacyWorldStatePreImage(archive:EmptyActivityPreImage(),candidateURLs:[]),
                endpointFile:CommandLine.arguments[1],helperPath:"",allowsLaunching:false)
            let clockClient = RustWorldActivityClient { try transport.call(method:$0,params:$1) }
            let clockContext = try WorldAgentContext(manifest:clockManifest,persistence:clockPersistence,
                initialCollisionWorld:FlatActivityFloor(),rustWorldActivity:clockClient)
            precondition(clockContext.currentActivityRequestID == nil && clockContext.runningActivity == nil,
                "Legacy snapshot must not manufacture a rendered arrival/completion")
            try clockContext.tick(deltaTime:0.2)
            clockContext.stopTicking()
            let roundtrip = try clockPersistence.readSnapshot()
            precondition(roundtrip?.activeActivity?.elapsedActiveTime == elapsed,
                "0/1/fractional clock projection survives actual Swift context checkpoint gate")
            var forged = clockContext.state; forged.activeActivity?.activityID = "forged"
            do { try clockPersistence.save(forged); fatalError("Unauthorized identity writer accepted") }
            catch WorldAuthorityError.daemon(let code) { precondition(code == "world_activity_owned_projection") }
            forged = clockContext.state; forged.activeActivity?.elapsedActiveTime += 0.1
            do { try clockPersistence.save(forged); fatalError("Unauthorized elapsed writer accepted") }
            catch WorldAuthorityError.daemon(let code) { precondition(code == "world_activity_owned_projection") }
            try clockContext.stopActivity()
            precondition(clockContext.state.activeActivity == nil)
        }
        print("PASS: real RPC -> production Context movement/phase; boundary-only RPC; real native pose; stale phase/ID rejected; no fallback; 0/1/fractional Swift clock checkpoints; unknown recovery; generated usage Swift consumer; persisted lifecycle events; ordinary state/object usage forgeries rejected")
    }
}
