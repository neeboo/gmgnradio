import Foundation

/// Native asynchronous transport only. Unity owns measured physics; Rust owns decisions.
@MainActor final class UnityWorldPhysicsClient {
    struct Identity: Codable, Equatable, Sendable {
        let worldID: String
        let hostSessionID: String
        let layoutRevision: UInt64
        let physicsGeneration: UInt64
    }
    struct Point: Codable, Equatable, Sendable { let x: Float; let y: Float; let z: Float }
    struct Probe: Codable, Equatable, Sendable { let key: String; let position: Point; let from: Point? }
    struct Measurement: Codable, Sendable {
        let key: String; let position: Point; let grounded: Point?; let canTraverse: Bool
        let occupiable: Bool
        let groundHit: Bool; let groundNormal: Point?; let colliderID: String?
    }
    enum Failure: Error { case unavailable, invalidReceipt, timedOut, cancelled }
    private struct Pending {
        let id: UUID; let identity: Identity; let probes: [Probe]
        let continuation: CheckedContinuation<[Measurement], Error>
        let timeout: Task<Void, Never>
        let payload: Data
    }
    private var pending: Pending?
    private var registration: (id:UUID,world:String,host:String,layout:UInt64,payload:Data,continuation:CheckedContinuation<Identity,Error>,timeout:Task<Void,Never>)?
    private var closed = false
    private(set) var registeredIdentity: Identity?
    func register(worldID:String,hostSessionID:String,layoutRevision:UInt64) async throws -> Identity {
        guard !closed, pending == nil, registration == nil, !worldID.isEmpty, !hostSessionID.isEmpty else {throw Failure.unavailable}
        try Task.checkCancellation()
        let id=UUID();let payload=try JSONSerialization.data(withJSONObject:["mode":"register","requestID":id.uuidString,"worldID":worldID,"hostSessionID":hostSessionID,"layoutRevision":layoutRevision])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout=Task { [weak self] in
                    try? await Task.sleep(nanoseconds:5_000_000_000)
                    guard !Task.isCancelled else {return};self?.failRegistration(id,Failure.timedOut)
                }
                registration=(id,worldID,hostSessionID,layoutRevision,payload,continuation,timeout)
                if Task.isCancelled {failRegistration(id,Failure.cancelled)}
            }
        } onCancel: { [weak self] in Task { @MainActor in self?.failRegistration(id,Failure.cancelled) } }
    }
    func measure(identity: Identity, probes: [Probe], capsuleRadius: Float, capsuleHeight: Float) async throws -> [Measurement] {
        guard !closed, pending == nil, registration == nil, registeredIdentity == identity, identity.physicsGeneration > 0, !probes.isEmpty, probes.count <= 1025,
              !identity.worldID.isEmpty, !identity.hostSessionID.isEmpty,
              identity.worldID.utf8.count <= 256, identity.hostSessionID.utf8.count <= 256,
              Set(probes.map(\.key)).count == probes.count, capsuleRadius.isFinite, capsuleHeight.isFinite,
              capsuleRadius > 0, capsuleHeight >= 2*capsuleRadius else { throw Failure.unavailable }
        try Task.checkCancellation()
        let id = UUID()
        let encoder = JSONEncoder()
        var payload = try JSONSerialization.jsonObject(with: encoder.encode(identity)) as! [String: Any]
        payload["requestID"] = id.uuidString; payload["probes"] = try JSONSerialization.jsonObject(with: encoder.encode(probes))
        payload["capsuleRadius"] = capsuleRadius; payload["capsuleHeight"] = capsuleHeight
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }; self?.fail(id, Failure.timedOut)
                }
                pending = Pending(id:id, identity:identity, probes:probes, continuation:continuation, timeout:timeout, payload:data)
                if Task.isCancelled { fail(id, Failure.cancelled) }
            }
        } onCancel: { [weak self] in Task { @MainActor in self?.fail(id, Failure.cancelled) } }
    }
    func snapshot() -> [String: Any] {
        if let registration {return (try? JSONSerialization.jsonObject(with:registration.payload)) as? [String:Any] ?? [:]}
        guard let pending else { return [:] }
        return (try? JSONSerialization.jsonObject(with: pending.payload)) as? [String:Any] ?? [:]
    }
    func accept(_ value: [String:Any]) -> Bool {
        if let registration, value["requestID"] as? String == registration.id.uuidString {
            guard value["worldID"] as? String == registration.world, value["hostSessionID"] as? String == registration.host,
                  let bytes=try? JSONSerialization.data(withJSONObject:value),let identity=try? JSONDecoder().decode(Identity.self,from:bytes),
                  identity.layoutRevision == registration.layout else {return false}
            guard value["status"] as? String == "registered", identity.physicsGeneration > 0 else {failRegistration(registration.id,Failure.unavailable);return true}
            self.registration=nil;registeredIdentity=identity;registration.timeout.cancel();registration.continuation.resume(returning:identity);return true
        }
        guard let pending, value["requestID"] as? String == pending.id.uuidString,
              let data = try? JSONSerialization.data(withJSONObject:value),
              let identity = try? JSONDecoder().decode(Identity.self,from:data), identity == pending.identity else { return false }
        guard value["status"] as? String == "completed", let raw = value["measurements"],
              let bytes = try? JSONSerialization.data(withJSONObject:raw),
              let result = try? JSONDecoder().decode([Measurement].self,from:bytes), result.count == pending.probes.count,
              zip(result,pending.probes).allSatisfy({ fact, probe in
                  guard fact.key == probe.key, fact.position == probe.position else { return false }
                  if let p = fact.grounded {
                      guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
                            p.x == probe.position.x, p.z == probe.position.z else { return false }
                  }
                  if let p = fact.groundNormal {
                      guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return false }
                  }
                  return fact.groundHit || (fact.grounded == nil && !fact.occupiable && !fact.canTraverse)
              })
        else { fail(pending.id,Failure.invalidReceipt); return true }
        self.pending=nil; pending.timeout.cancel(); pending.continuation.resume(returning:result); return true
    }
    private func fail(_ id: UUID, _ error: Error) {
        guard let pending, pending.id == id else { return }
        self.pending=nil; pending.timeout.cancel(); pending.continuation.resume(throwing:error)
    }
    private func failRegistration(_ id:UUID,_ error:Error) {
        guard let registration,registration.id==id else {return}
        self.registration=nil;registration.timeout.cancel();registration.continuation.resume(throwing:error)
    }
    func close() { closed=true; registeredIdentity=nil; if let pending { fail(pending.id,Failure.unavailable) };if let registration {failRegistration(registration.id,Failure.unavailable)} }
}
