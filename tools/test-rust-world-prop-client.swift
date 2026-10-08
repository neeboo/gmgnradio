import Foundation

/// Private HTTP contract test, not a substitute for the SQLite authorization tests.
@main struct PropClientFixture {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("private endpoint required") }
        let client = RustWorldPropClient(endpointFile:URL(fileURLWithPath:CommandLine.arguments[1]))
        let identity = RustWorldPropClient.Identity(worldID:"fixture-world",residentScope:"fixture-scope",hostSessionID:"fixture-host")
        let snapshot = try await client.snapshot(identity)
        let object = try JSONSerialization.jsonObject(with:snapshot) as! [String:Any]
        precondition(object["record"] != nil)
        let read = try await client.read(identity)
        precondition(!read.isEmpty)
        let facts = Data("{\"rawFixtureFact\":true}".utf8)
        let observation = try await client.observe(identity,expectedRevision:7,layoutRevision:3,facts:facts)
        precondition(observation.geometryID == "fixture-geometry")
        _ = try await client.surfaces(identity,geometryID:observation.geometryID)
        let command = Data("{\"op\":\"place\",\"objectID\":\"prop\",\"position\":[1,0,2],\"yaw\":0,\"surfaceID\":\"grid.layer.0\"}".utf8)
        _ = try await client.preview(identity,expectedRevision:7,layoutRevision:3,geometryID:observation.geometryID,command:command)
        let authority = RustWorldPropClient.AgentAuthority(identity:identity,runID:"fixture-run",callID:"fixture-call",operationID:"fixture-operation")
        _ = try await client.command(authority,expectedRevision:7,layoutRevision:3,geometryID:observation.geometryID,requestID:"fixture-request")
        let intent = try await client.uiIntent(identity,expectedRevision:7,layoutRevision:3,command:command)
        _ = try await client.uiCommand(identity,intent:intent,expectedRevision:7,layoutRevision:3,geometryID:observation.geometryID,requestID:"fixture-ui")
        let bad = RustWorldPropClient.AgentAuthority(identity:identity,runID:"fixture-run",callID:"fixture-call",operationID:"wrong")
        do {
            _ = try await client.command(bad,expectedRevision:7,layoutRevision:3,geometryID:observation.geometryID,requestID:"fixture-reject")
            fatalError("bad authority must retain daemon rejection")
        } catch RustWorldPropError.rejected(let code) { precondition(code == "world_prop_unauthorized") }
        let mesh = Data("[[[0,0,0],[1,0,0],[0,1,0]]]".utf8)
        let blob = "sha256:" + String(repeating:"b",count:64)
        do {
            _ = try await client.register(identity,wishID:"fixture-wish",expectedRevision:7,layoutRevision:3,
                requestID:"original-register-request",blobRef:blob,triangles:mesh,rebase:false)
            fatalError("lost response must remain unknown")
        } catch RustWorldPropError.executionUnknown { }
        let reconciled = try await client.register(identity,wishID:"fixture-wish",expectedRevision:999,layoutRevision:999,
            requestID:"must-not-send-new-request",blobRef:blob,triangles:mesh,rebase:true)
        let registered = try JSONSerialization.jsonObject(with:reconciled) as! [String:Any]
        precondition(registered["prop"] != nil)
        print("PASS: production async prop HTTP DTOs, no agent candidate/permission flags, UI capability, strict daemon rejection")
        print("PASS: lost registration response reconciles original request receipt without new-version dispatch")
    }
}
