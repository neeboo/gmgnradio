import Foundation
// Protocol acceptance only. Supplied DTO receipts are not PhysX measurements.
@main struct PhysicsClientChecks {
    @MainActor static func main() async throws {
        let client=UnityWorldPhysicsClient()
        let identity=UnityWorldPhysicsClient.Identity(worldID:"private",hostSessionID:"host",layoutRevision:7,physicsGeneration:9)
        let point=UnityWorldPhysicsClient.Point(x:1,y:0,z:2)
        let probe=UnityWorldPhysicsClient.Probe(key:"anchor",position:point,from:nil)
        let registration=Task {try await client.register(worldID:"private",hostSessionID:"host",layoutRevision:7)}
        for _ in 0..<100 {if !client.snapshot().isEmpty {break};await Task.yield()}
        var ready=client.snapshot();ready["status"]="registered";ready["physicsGeneration"]=9
        precondition(client.accept(ready));let actualIdentity=try await registration.value;precondition(actualIdentity == identity)
        let task=Task {try await client.measure(identity:identity,probes:[probe],capsuleRadius:0.2,capsuleHeight:1.7)}
        for _ in 0..<100 { if !client.snapshot().isEmpty {break};await Task.yield() }
        var reply=client.snapshot();precondition(reply["requestID"] != nil)
        reply["status"]="completed"
        reply["measurements"]=[["key":"anchor","position":["x":1,"y":0,"z":2],"grounded":NSNull(),"occupiable":false,"canTraverse":false,"groundHit":false,"groundNormal":NSNull(),"colliderID":NSNull()]]
        var stale=reply;stale["layoutRevision"]=8
        precondition(!client.accept(stale));precondition(client.accept(reply))
        let measured=try await task.value;precondition(measured.count==1 && !measured[0].canTraverse)
        precondition(!client.accept(reply))
        let cancel=Task {try await client.measure(identity:identity,probes:[probe],capsuleRadius:0.2,capsuleHeight:1.7)}
        for _ in 0..<100 {if !client.snapshot().isEmpty {break};await Task.yield()}
        cancel.cancel()
        do {_=try await cancel.value;fatalError("cancelled probe returned facts")} catch {}
        precondition(client.snapshot().isEmpty)
        client.close()
        print("PASS Unity physics typed transport: strict identity, no late/repeated receipt, cancellation, unavailable ground; protocol-only, no PhysX run")
    }
}
