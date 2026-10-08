import Foundation
import CryptoKit
import WorldRuntime

@main struct ActivityPrepareAcceptance {
    @MainActor static func main() async throws {
        let transform: [String: Any] = ["position":["x":0,"y":0,"z":0],"rotation":["x":0,"y":0,"z":0,"w":1],"scale":["x":1,"y":1,"z":1]]
        let raw: [String: Any] = ["worldID":"private-prepare","revision":0,"layoutRevision":7,"worldTime":1000,
            "lastObservedWallTime":1000,"weather":"clear","completedGoals":[:],"agentTransform":transform,"objectStates":[:]]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let world = try decoder.decode(WorldState.self, from:JSONSerialization.data(withJSONObject:raw))
        if CommandLine.arguments.count == 2 {
            let transport=TaskdHTTPAuthorityClient(endpointFile:CommandLine.arguments[1],helperPath:"",allowsLaunching:false,timeout:5)
            let bytes=try JSONSerialization.data(withJSONObject:raw,options:[.sortedKeys])
            _ = try transport.call(method:"world_import",params:["worldID":world.worldID,"requestID":"private-import",
                "packageID":"private-authored","packageVersion":"1","stateJson":String(decoding:bytes,as:UTF8.self),
                "stateSha256":SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()])
            var dispatched:[String:Any]=[:]
            let actual=RustWorldActivityClient { method,input in
                if method == "world_activity_start" { dispatched=input }
                return try transport.call(method:method,params:input)
            }
            let phases=["approach","enter","loop","exit","interrupt","failed"].map { ["phase":$0,"requiredAnchorIDs":[],"motionIDs":[],"propIDs":[]] as [String:Any] }
            let definition:[String:Any] = ["id":"private-action","displayName":"Private activity","activity":["type":"interact","anchorID":"target"],"interruptible":true,"cooldownSeconds":0,"phases":phases]
            var tiltedAnchor=transform; tiltedAnchor["rotation"]=["x":0.5,"y":0.5,"z":0.5,"w":0.5]
            _ = try transport.call(method:"world_activity_bind_catalog",params:["worldID":world.worldID,"hostSessionID":actual.hostSessionID,"requestID":"private-bind",
                "definitions":[definition],"waypoints":[["id":"origin","position":["x":0,"y":0,"z":0],"arrivalRadius":0.1,"enabled":true],
                    ["id":"target","position":["x":1,"y":0,"z":0],"arrivalRadius":0.1,"enabled":true]],
                "routes":[["id":"route","enabled":true,"bidirectional":true,"waypointIDs":["origin","target"]]],
                "authoredActivities":[["id":"private-action","entryWaypointID":"target","transform":tiltedAnchor]]])
            let result = try actual.start(world:world,expectedRevision:1,definitionID:"private-action",capsuleRadius:0.3,
                waitsForRenderedCompletion:true,measureApproach:{ _ in fatalError("Authored anchor requested dynamic physics") },
                canTraverse:{ _,_ in true })
            precondition(result.activity.run?.path.destinationID == "target" && result.activity.run?.path.points.last?.x == 1)
            precondition(abs(result.activity.run!.targetYaw! - .pi/2) < 0.000001 && dispatched["path"] == nil && dispatched["targetYaw"] == nil)
            for field in ["path","targetYaw"] {
                var invalid=dispatched; invalid["requestID"]=UUID().uuidString; invalid[field]=0
                do { _ = try transport.call(method:"world_activity_start",params:invalid); fatalError("Host plan accepted") } catch { }
            }
            let replay=try transport.call(method:"world_activity_start",params:dispatched)
            precondition((replay["activity"] as? [String:Any])?["generation"] as? Int == Int(result.activity.generation))
            var capRaw=raw; capRaw["worldID"]="private-capability"
            var propTransform=transform; propTransform["position"]=["x":1,"y":0,"z":0]
            let generated=try JSONSerialization.data(withJSONObject:["objectID":"machine","size":["x":0.4,"y":0.7,"z":0.4]])
            capRaw["objectStates"]=["machine":["isEnabled":true,"transform":propTransform,"metadata":[
                "gmgn.generated-prop.v1":String(decoding:generated,as:UTF8.self),
                "gmgn.prop-capability.v1":"{\"objectID\":\"machine\",\"templateID\":\"coffee.brew\"}"]]]
            let capBytes=try JSONSerialization.data(withJSONObject:capRaw,options:[.sortedKeys])
            _ = try transport.call(method:"world_import",params:["worldID":"private-capability","requestID":"cap-import",
                "packageID":"private-cap","packageVersion":"1","stateJson":String(decoding:capBytes,as:UTF8.self),
                "stateSha256":SHA256.hash(data:capBytes).map{String(format:"%02x",$0)}.joined()])
            let capWorld=try decoder.decode(WorldState.self,from:capBytes)
            let waypoints:[[String:Any]] = [["id":"origin","position":["x":0,"y":0,"z":0],"arrivalRadius":0.1,"enabled":true]]
            let capPlan=try transport.call(method:"world_prop_capability_plan",params:["worldID":capWorld.worldID,
                "hostSessionID":actual.hostSessionID,"objectID":"machine","kind":"capability","expectedLayoutRevision":7,
                "capsuleRadius":0.3,"waypoints":waypoints])
            _ = try transport.call(method:"world_activity_bind_catalog",params:["worldID":capWorld.worldID,"hostSessionID":actual.hostSessionID,
                "requestID":"cap-bind","definitions":[capPlan["definition"]!],"waypoints":waypoints,"routes":[],"authoredActivities":[],
                "usageBindings":["coffee.brew@machine":["objectID":"machine","templateID":"coffee.brew"]]])
            var capPrepare:[String:Any] = ["worldID":capWorld.worldID,"hostSessionID":actual.hostSessionID,"expectedRevision":1,
                "expectedLayoutRevision":7,"checkpoint":capRaw,"definitionID":"coffee.brew@machine","capsuleRadius":0.3,"traversal":[]]
            let pending=try transport.call(method:"world_activity_prepare",params:capPrepare)
            let pendingProbes=pending["probes"] as! [[String:Any]]
            let facts=pendingProbes.map { ["key":$0["key"]!,"position":$0["position"]!,"grounded":$0["position"]!,"canTraverse":true] as [String:Any] }
            capPrepare["approachPhysics"]=["geometryID":"wrong-geometry","physics":facts]
            do { _ = try transport.call(method:"world_activity_prepare",params:capPrepare); fatalError("Wrong native geometry accepted") } catch { }
            let capStart=try actual.start(world:capWorld,expectedRevision:1,definitionID:"coffee.brew@machine",capsuleRadius:0.3,
                waitsForRenderedCompletion:true,measureApproach:{.init(key:$0.key,position:$0.position,grounded:$0.position,canTraverse:true)},canTraverse:{_,_ in true})
            let capRun=capStart.activity.run!
            precondition(capRun.definition.id == "coffee.brew@machine")
            guard var capState=capStart.snapshot?.record?.state,let capRevision=capStart.snapshot?.record?.recordRevision else { fatalError("Missing actual snapshot") }
            do { _ = try actual.receipt(world:capState,expectedRevision:capRevision,run:capRun,kind:"arrived"); fatalError("Distant arrival accepted") } catch { }
            // Private native movement boundary: report the measured terminal pose,
            // never assert that the real renderer or an animation ran here.
            capState.agentTransform=WorldTransform(position:capRun.target,rotation:capState.agentTransform.rotation,
                scale:capState.agentTransform.scale)
            _ = try actual.receipt(world:capState,expectedRevision:capRevision,run:capRun,kind:"arrived")
            var asyncRaw=raw; asyncRaw["worldID"]="private-async-physics"
            let asyncBytes=try JSONSerialization.data(withJSONObject:asyncRaw,options:[.sortedKeys])
            _ = try transport.call(method:"world_import",params:["worldID":"private-async-physics","requestID":"async-import",
                "packageID":"private-async","packageVersion":"1","stateJson":String(decoding:asyncBytes,as:UTF8.self),
                "stateSha256":SHA256.hash(data:asyncBytes).map{String(format:"%02x",$0)}.joined()])
            let asyncWorld=try decoder.decode(WorldState.self,from:asyncBytes)
            let asyncClient=RustWorldActivityClient { try transport.call(method:$0,params:$1) }
            _ = try transport.call(method:"world_activity_bind_catalog",params:["worldID":asyncWorld.worldID,"hostSessionID":asyncClient.hostSessionID,
                "requestID":"async-bind","definitions":[definition],"waypoints":[["id":"origin","position":["x":0,"y":0,"z":0],"arrivalRadius":0.1,"enabled":true],
                    ["id":"target","position":["x":1,"y":0,"z":0],"arrivalRadius":0.1,"enabled":true]],
                "routes":[["id":"route","enabled":true,"bidirectional":true,"waypointIDs":["origin","target"]]],
                "authoredActivities":[["id":"private-action","entryWaypointID":"target","transform":tiltedAnchor]]])
            let background=RustPropCapabilityClient(endpointFile:CommandLine.arguments[1],helperPath:"")
            let asyncStart=try await asyncClient.startMeasured(world:asyncWorld,expectedRevision:1,definitionID:"private-action",capsuleRadius:0.3,
                waitsForRenderedCompletion:true,transport:background,measure:{ probes in
                    await Task.yield()
                    return probes.map { .init(key:$0.key,position:$0.position,grounded:$0.position,canTraverse:true) }
                })
            precondition(asyncStart.activity.run?.path.destinationID == "target" && abs(asyncStart.activity.run!.targetYaw! - .pi/2) < 0.000001)
            var unavailableMeasurements=0
            do {
                _ = try await asyncClient.startMeasured(world:asyncStart.snapshot!.record!.state,
                    expectedRevision:asyncStart.snapshot!.record!.recordRevision,definitionID:"private-action",capsuleRadius:0.3,
                    waitsForRenderedCompletion:true,transport:background,measure:{ _ in
                        unavailableMeasurements += 1
                        throw RustPropCapabilityClient.Failure.unavailable
                    })
                fatalError("Unavailable async physics fell back to native CPU")
            } catch { precondition(unavailableMeasurements == 1) }
            print("PASS actual daemon activity consumer: authored path/facing, canonical capability raw physics/start/arrival, wrong geometry/distant arrival/host-plan rejection and exact replay")
            return
        }
        var count=0, started=false, measured=0
        let client = RustWorldActivityClient { method,input in
            precondition(input["path"] == nil && input["targetYaw"] == nil)
            precondition(input["expectedLayoutRevision"] as? UInt64 == 7)
            if method == "world_activity_start" {
                precondition(count == 3 && measured == 1)
                precondition(input["planSHA256"] as? String == String(repeating:"a",count:64))
                precondition((input["traversal"] as? [[String:Any]])?.first?["canTraverse"] as? Bool == true)
                started=true
                return ["activity":["generation":0,"hostSessionID":input["hostSessionID"]!,"run":NSNull()]]
            }
            precondition(method == "world_activity_prepare")
            count += 1
            switch count {
            case 1: return ["stage":"approach","geometryID":"geometry","probes":[["key":"stand","position":["x":1,"y":0,"z":0]]]]
            case 2:
                let physics=input["approachPhysics"] as! [String:Any]
                precondition(physics["geometryID"] as? String == "geometry")
                return ["stage":"route","probes":[["key":"edge","from":["x":0,"y":0,"z":0],"to":["x":1,"y":0,"z":0]]]]
            default: return ["stage":"ready","planSHA256":String(repeating:"a",count:64),"preparedAtMS":1234]
            }
        }
        _ = try client.start(world:world,expectedRevision:2,definitionID:"private-action",capsuleRadius:0.3,
            waitsForRenderedCompletion:true,measureApproach:{ probe in
                measured += 1; return .init(key:probe.key,position:probe.position,grounded:probe.position,canTraverse:true)
            },canTraverse:{ from,to in precondition(from.x == 0 && to.x == 1); return true })
        precondition(started)
        var forbiddenStart=false
        let duplicate = RustWorldActivityClient { method,_ in
            if method == "world_activity_start" { forbiddenStart=true }
            return ["stage":"route","probes":[["key":"edge","from":["x":0,"y":0,"z":0],"to":["x":1,"y":0,"z":0]]]]
        }
        do {
            _ = try duplicate.start(world:world,expectedRevision:2,definitionID:"private-action",capsuleRadius:0.3,
                waitsForRenderedCompletion:false,measureApproach:{ _ in fatalError("Unexpected approach") },canTraverse:{_,_ in true})
            fatalError("Repeated probe accepted")
        } catch { precondition(!forbiddenStart) }
        print("PASS production activity prepare client: raw approach and traversal proofs, opaque confirmed digest start, duplicate probe failclosed; no device/UI/audio")
    }
}
