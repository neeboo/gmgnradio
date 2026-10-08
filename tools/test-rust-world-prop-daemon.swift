import Foundation

/// Compiled with the production actor and HTTP transport. No replacement server.
@main struct WorldPropDaemonFixture {
    static func object(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func main() async throws {
        let fixture = try object(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let client = RustWorldPropClient(endpointFile: URL(fileURLWithPath: CommandLine.arguments[1]))
        let identity = RustWorldPropClient.Identity(worldID: fixture["worldID"] as! String,
            residentScope: "private-prop-scope", hostSessionID: "private-prop-host")
        for blob in fixture["blobs"] as! [[String: String]] {
            try await client.putBlob(localPath: blob["path"]!, sha256: blob["hash"]!)
        }
        let facts = try JSONSerialization.data(withJSONObject: fixture["facts"]!)
        func versions() async throws -> (UInt64, UInt64, [String: Any]) {
            let record = try object(await client.snapshot(identity))["record"] as! [String: Any]
            let state = record["state"] as! [String: Any]
            return ((record["recordRevision"] as! NSNumber).uint64Value,
                (state["layoutRevision"] as! NSNumber).uint64Value, state)
        }
        func perform(_ command: [String: Any], request: String) async throws -> [String: Any] {
            let (revision, layout, _) = try await versions()
            let geometry = try await client.observe(identity, expectedRevision: revision, layoutRevision: layout, facts: facts)
            let bytes = try JSONSerialization.data(withJSONObject: command)
            let intent = try await client.uiIntent(identity, expectedRevision: revision, layoutRevision: layout, command: bytes)
            if request == "private-place" {
                let forged = RustWorldPropClient.UIIntent(intentID:intent.intentID, capability:UUID().uuidString, expiresAtMS:intent.expiresAtMS)
                do {
                    _ = try await client.uiCommand(identity, intent:forged, expectedRevision:revision,
                        layoutRevision:layout,geometryID:geometry.geometryID,requestID:"negative-ui-capability")
                    fatalError("wrong capability accepted")
                } catch RustWorldPropError.rejected(let code) {precondition(code=="world_prop_unauthorized")}
                let foreign = RustWorldPropClient.Identity(worldID:identity.worldID,residentScope:identity.residentScope,hostSessionID:"foreign-host")
                do {
                    _ = try await client.uiCommand(foreign, intent:intent, expectedRevision:revision,
                        layoutRevision:layout,geometryID:geometry.geometryID,requestID:"negative-ui-host")
                    fatalError("foreign host accepted")
                } catch RustWorldPropError.rejected(let code) {precondition(code=="world_prop_unauthorized")}
            }
            let result = try object(await client.uiCommand(identity, intent: intent, expectedRevision: revision,
                layoutRevision: layout, geometryID: geometry.geometryID, requestID: request))
            let replay = try object(await client.uiCommand(identity, intent: intent, expectedRevision: revision,
                layoutRevision: layout, geometryID: geometry.geometryID, requestID: request))
            precondition(replay["replayed"] as? Bool == true)
            let receipt = try object(await client.registrationReceipt(identity, requestID: request))
            precondition(receipt["found"] as? Bool == true)
            let (nextRevision, nextLayout, _) = try await versions()
            do {
                _ = try await client.uiCommand(identity, intent:intent, expectedRevision:nextRevision,
                    layoutRevision:nextLayout,geometryID:geometry.geometryID,requestID:request+"-reuse")
                fatalError("one-use intent reused")
            } catch RustWorldPropError.rejected(let code) {precondition(code=="world_prop_unauthorized")}
            return result
        }
        let (revision, layout, _) = try await versions()
        let observed = try await client.observe(identity, expectedRevision: revision, layoutRevision: layout, facts: facts)
        let surfaces = try object(await client.surfaces(identity, geometryID: observed.geometryID))["surfaces"] as! [[String: Any]]
        precondition(!surfaces.isEmpty)
        let place: [String: Any] = ["op":"place", "objectID":"private-prop", "position":[0.65,0,0.1], "yaw":0,
            "surfaceID":surfaces[0]["surfaceID"]!]
        let preview = try object(await client.preview(identity, expectedRevision: revision, layoutRevision: layout,
            geometryID: observed.geometryID, command: JSONSerialization.data(withJSONObject: place)))
        precondition(preview["canPlace"] as? Bool == true, "preview: \(preview)")
        let agent = RustWorldPropClient.AgentAuthority(identity: identity, runID:"not-claimed",callID:"no-call",operationID:"no-operation")
        do {
            _ = try await client.command(agent, expectedRevision: revision, layoutRevision: layout,
                geometryID: observed.geometryID, requestID:"negative-agent")
            fatalError("unclaimed agent must not mutate")
        } catch RustWorldPropError.rejected(let code) { precondition(code == "world_prop_unauthorized") }
        do {
            let mesh = ((fixture["facts"] as! [String:Any])["objects"] as! [String:[String:Any]])["private-prop"]!
            _ = try await client.register(identity, wishID: fixture["wishID"] as! String, expectedRevision: revision,
                layoutRevision: layout, requestID:"negative-register", blobRef: fixture["propHash"] as! String,
                triangles: JSONSerialization.data(withJSONObject: mesh["triangles"]!), rebase:false)
            fatalError("unclaimed wish must not register")
        } catch RustWorldPropError.rejected(let code) { precondition(code == "world_prop_unauthorized") }
        _ = try await perform(place, request:"private-place")
        _ = try await perform(["op":"hold","objectID":"private-prop","slot":"rightHand"], request:"private-hold")
        let held = try await versions().2
        precondition((held["heldProp"] as? [String:Any])?["objectID"] as? String == "private-prop")
        _ = try await perform(["op":"dropHeld","objectID":"private-prop"], request:"private-drop")
        let dropped = try await versions().2
        precondition(dropped["heldProp"] is NSNull)
        let item = (dropped["objectStates"] as! [String:Any])["private-prop"] as! [String:Any]
        precondition(item["isEnabled"] as? Bool == true)
        let position = (item["transform"] as! [String:Any])["position"] as! [String:NSNumber]
        precondition(hypot(position["x"]!.doubleValue, position["z"]!.doubleValue) <= 0.6)
        _ = try await perform(["op":"hold","objectID":"private-prop"], request:"private-hold-again")
        _ = try await perform(["op":"returnHeld","objectID":"private-prop"], request:"private-return")
        let inventory = try object(await client.read(identity))["objects"] as! [[String:Any]]
        precondition(inventory.count == 1 && inventory[0]["status"] as? String == "placed")
        print("PASS production Swift→real Rust: verified GLBs/measured native facts/surfaces/preview/UI place→hold→nearby drop→return/exact-request replay/receipt readback")
        print("PASS negative unclaimed agent and unclaimed wish registration; no fabricated execution grants")
    }
}
