import Foundation
import WorldRuntime

@main struct ActivityClientAcceptance {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Provide isolated taskd endpoint path") }
        let transport = TaskdHTTPAuthorityClient(endpointFile: CommandLine.arguments[1], helperPath: "",
            allowsLaunching: false, timeout: 1)
        var calls = 0
        let client = RustActivityCatalogClient { method, params in
            calls += 1
            return try transport.call(method: method, params: params)
        }
        let transform = WorldTransform(position: WorldVector3(x: 0, y: 0, z: 0),
            rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1), scale: WorldVector3(x: 1, y: 1, z: 1))
        let manifest = WorldManifest(schemaVersion: 1, packageID: "isolated", packageVersion: "1",
            worldID: "isolated", displayName: "fixture",
            calibration: WorldCalibration(visualToGameplay: [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1], metersPerUnit: 1),
            spawn: transform, collisionVolumes: [], waypoints: [], routes: [],
            activities: [WorldActivityAnchor(id: "music.listen", action: "listen_music", entryWaypointID: "entry",
                transform: transform, motionID: "existing-motion", propIDs: ["fixture"], interruptible: true)],
            cameras: [], capabilities: [], resources: [])
        let catalog = try client.manifest(manifest)
        precondition(catalog.definition(id: "music.listen")?.activity == .listenMusic(anchorID: "music.listen"))
        precondition(catalog.definition(id: "music.listen")?.contract(for: .loop)?.motionIDs == ["existing-motion"])
        let seat = try client.seat(activityID: "prop.seat.fixture", objectID: "fixture", displayName: "沙发")
        precondition(seat.activity == .sit(anchorID: "prop.seat.fixture"))
        precondition(seat.contract(for: .enter)?.durationSeconds == 0.2)
        precondition(seat.contract(for: .loop)?.motionIDs == ["gmgn.motion.bones.chair-sit-loop-pmx", "gmgn.motion.bones.chair-sit-loop-vrm"])
        let baselineCalls = calls
        for _ in 0..<100 {
            _ = try client.seat(activityID: "prop.seat.fixture", objectID: "fixture", displayName: "沙发")
        }
        precondition(calls == baselineCalls, "Identical repeated discoveries must not perform HTTP")
        let authored = LifeActivityDefinition(id: seat.id, activity: .idle, phases: LifeActivityPhase.allCases.map {
            ActivityPhaseContract(phase: $0)
        }, interruptible: true, cooldownSeconds: 0)
        let merged = try client.merge(authored: [authored], dynamic: [seat])
        precondition(merged.definitions == [seat], "Rust override must survive Swift Codable consumption")
        let mergedCalls = calls
        for _ in 0..<100 { _ = try client.merge(authored: [authored], dynamic: [seat]) }
        precondition(calls == mergedCalls)
        do {
            _ = try client.merge(authored: [], dynamic: [seat, seat])
            fatalError("Duplicate activity must be rejected by Rust")
        } catch WorldAuthorityError.daemon(let code) {
            precondition(code == "activity_duplicate_id")
        }
        _ = try client.merge(authored: [authored], dynamic: [seat])
        print("PASS: isolated real RPC -> Swift manifest/seat/merge decode, dynamic override, duplicate rejection, 200 cache hits")
    }
}
