import Foundation
import WorldRuntime

/// Synchronous leaves expose only already measured facts. Missing facts never imply a floor.
final class UnityWorldPhysicsProvider: WorldCollisionQuerying, @unchecked Sendable {
    private let client: UnityWorldPhysicsClient
    private let worldID: String
    private let lock=NSLock()
    private var grounds: [String:Float]=[:]
    private var occupancy: [String:Bool]=[:]
    private var traversal: [String:Bool]=[:]
    private var registered: UnityWorldPhysicsClient.Identity?
    @MainActor private var busy=false
    @MainActor init(client:UnityWorldPhysicsClient,worldID:String) {self.client=client;self.worldID=worldID}
    private func key(_ p: SIMD3<Float>) -> String { "\(p.x.bitPattern):\(p.y.bitPattern):\(p.z.bitPattern)" }
    private func vector(_ p: WorldVector3) -> SIMD3<Float> { SIMD3(p.x,p.y,p.z) }
    private func shape(_ radius:Float,_ height:Float)->String {"\(radius.bitPattern):\(height.bitPattern)"}
    func groundHeight(at position:SIMD3<Float>)->Float? {
        lock.lock();defer{lock.unlock()};return grounds[key(position)]
    }
    func canOccupy(_ capsule:WorldCapsule,at position:SIMD3<Float>)->Bool {
        lock.lock();defer{lock.unlock()};return occupancy[shape(capsule.radius,capsule.height)+key(position)] ?? false
    }
    func canTraverse(_ capsule:WorldCapsule,from start:SIMD3<Float>,to end:SIMD3<Float>,maximumStepHeight:Float)->Bool {
        lock.lock();defer{lock.unlock()};return traversal[shape(capsule.radius,capsule.height)+key(start)+">"+key(end)] ?? false
    }
    @MainActor func measure(_ request:WorldAgentContext.NativePhysicsRequest) async throws -> [RustPropCapabilityClient.Measurement] {
        guard request.worldID==worldID else {throw UnityWorldPhysicsClient.Failure.unavailable}
        let deadline=ProcessInfo.processInfo.systemUptime+5
        while busy {
            try Task.checkCancellation();guard ProcessInfo.processInfo.systemUptime<deadline else {throw UnityWorldPhysicsClient.Failure.timedOut}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        busy=true;defer{busy=false}
        let identity=try await client.register(worldID:request.worldID,hostSessionID:request.hostSessionID,layoutRevision:request.layoutRevision)
        lock.withLock {
            if registered != identity {grounds=[:];occupancy=[:];traversal=[:];registered=identity}
        }
        var result:[RustPropCapabilityClient.Measurement]=[]
        for offset in stride(from:0,to:request.probes.count,by:1025) {
            let probes=Array(request.probes[offset..<min(offset+1025,request.probes.count)])
            let measured=try await client.measure(identity:identity,probes:probes.map {
                .init(key:$0.key,position:.init(x:$0.position.x,y:$0.position.y,z:$0.position.z),
                    from:$0.from.map{.init(x:$0.x,y:$0.y,z:$0.z)})
            },capsuleRadius:request.capsuleRadius,capsuleHeight:request.capsuleHeight)
            try Task.checkCancellation()
            guard client.registeredIdentity==identity else {throw UnityWorldPhysicsClient.Failure.invalidReceipt}
            for (probe,fact) in zip(probes,measured) {
                let grounded=fact.grounded.map{WorldVector3(x:$0.x,y:$0.y,z:$0.z)}
                lock.withLock {
                    if let grounded {
                        grounds[key(vector(probe.position))]=grounded.y
                        grounds[key(vector(grounded))]=grounded.y
                        occupancy[shape(request.capsuleRadius,request.capsuleHeight)+key(vector(grounded))]=fact.occupiable
                        if let from=probe.from {traversal[shape(request.capsuleRadius,request.capsuleHeight)+key(vector(from))+">"+key(vector(grounded))]=fact.canTraverse}
                    }
                }
                result.append(.init(key:probe.key,position:probe.position,grounded:fact.occupiable ? grounded:nil,canTraverse:fact.canTraverse))
            }
        }
        return result
    }
}
