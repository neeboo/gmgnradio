// Test-only daemon substitute. Every HTTP request is intercepted by the caller's URLProtocol.
// Generation HTTP is mocked; control authority runs in an isolated real Rust process.
import Foundation
import CryptoKit
import Darwin

@MainActor
final class WishMachineDaemonFixture: PropTaskDaemonConnecting, PropTaskControlConnecting {
    var onEvent: ((PropTaskDaemonEvent) -> Void)?
    var onSnapshot: ((PropTaskDaemonSnapshot) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private(set) var jobs: [PropGenerationRecord] = []
    private(set) var contexts: [UUID: PropTaskContext] = [:]
    var rejectSubmit = false
    var rejectedControlMethods: Set<String> = []
    let controlGate = WishFixtureControlGate()
    private var sequence: UInt64 = 0
    private let directory: URL
    private let session: URLSession
    private var client: PropGenerationClient?
    private var active: Set<UUID> = []
    private var readable = true
    private let controls: WishFixtureControlService
    private static var controlServices: [String: WishFixtureWeakControlService] = [:]

    init(directory: URL, session: URLSession) {
        self.directory = directory
        self.session = session
        // Sibling generation fixtures share one authority DB, just as production stores do.
        let root = directory.deletingLastPathComponent().appendingPathComponent("WishControlService")
        if let shared = Self.controlServices[root.path]?.value { controls = shared }
        else {
            let shared = WishFixtureControlService(root: root)
            controls = shared
            Self.controlServices[root.path] = WishFixtureWeakControlService(shared)
        }
        let file = directory.appendingPathComponent("tasks.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { jobs = try JSONDecoder().decode([PropGenerationRecord].self, from: Data(contentsOf: file)) }
            catch { readable = false }
        }
        let contextFile=directory.appendingPathComponent("task-contexts.json")
        if FileManager.default.fileExists(atPath:contextFile.path) {
            do {contexts=try JSONDecoder().decode([UUID:PropTaskContext].self,from:Data(contentsOf:contextFile))}
            catch {readable=false}
        }
    }

    func controlRequest(method: String, params: [String: Any]) throws -> [String: Any] {
        try controls.startIfNeeded()
        if let owner = params["ownerID"] as? String,
           controls.rejectedOwners.contains(owner), method != "wish_control_read" {
            throw PropTaskDaemonError.requestRejectedWith(code: "fixture_control_write_rejected")
        }
        do {
            let result = try controls.request(method: method, params: params)
            if let owner = params["ownerID"] as? String {
                var identity = params
                identity["expectedRevision"] = result["revision"]
                controls.identities[owner] = identity
            }
            return result
        }
        catch {
            // Private fixture diagnostics contain only the method/error, never archive contents.
            FileHandle.standardError.write(Data("FAIL[fixture control]: \(method): \(error.localizedDescription)\n".utf8))
            throw error
        }
    }
    func prepareCollectionFixture() throws {
        try controls.startIfNeeded()
        let world="world",host="fixture-native-world"
        let read=try controls.request(method:"world_activity_read",params:["worldID":world,"hostSessionID":host])
        if let activity=read["activity"] as? [String:Any],let run=activity["run"] as? [String:Any],run["phase"] as? String == "loop" {return}
        let pose:[String:Any]=["x":0,"y":0,"z":0]
        let snapshot=try controls.request(method:"world_snapshot",params:["worldID":world,"includeState":true])
        if snapshot["record"] is NSNull {
            _ = try controls.request(method:"world_commit",params:["worldID":world,"requestID":"collect-fixture-seed",
                "expectedRevision":0,"ops":[["op":"replaceState","state":["worldID":world,"revision":0,"worldTime":1000,
                    "objectStates":[:],"agentTransform":["position":pose]]]]])
        }
        let phases=["approach","enter","loop","exit","interrupt","failed"].map { ["phase":$0,"motionIDs":[],"requiredAnchorIDs":[],"propIDs":[]] as [String:Any] }
        let definition:[String:Any]=["id":"wish_machine.collect","displayName":"Fixture collection",
            "activity":["type":"interact","anchorID":"fixture.collect"],"interruptible":true,"cooldownSeconds":0,"phases":phases]
        _ = try controls.request(method:"world_activity_bind_catalog",params:["worldID":world,"hostSessionID":host,
            "requestID":"collect-fixture-bind","definitions":[definition]])
        let current=try controls.request(method:"world_snapshot",params:["worldID":world,"includeState":true])
        let record=current["record"] as! [String:Any]
        let started=try controls.request(method:"world_activity_start",params:["worldID":world,"hostSessionID":host,
            "requestID":"collect-fixture-start","expectedRevision":record["recordRevision"]!,"checkpoint":record["state"]!,
            "definitionID":"wish_machine.collect","priority":0,"waitsForRenderedCompletion":true,
            "path":["destinationID":"fixture.collect","waypointIDs":[],"points":[pose],"totalLength":0,"arrivalTolerance":0.1]])
        let approachRun=(started["activity"] as! [String:Any])["run"] as! [String:Any]
        let approachRecord=(started["snapshot"] as! [String:Any])["record"] as! [String:Any]
        // Arrival is measured from the unchanged real checkpoint; the fixture
        // starts at this anchor and does not teleport or force a phase.
        let arrival=try controls.request(method:"world_activity_receipt",params:["worldID":world,"hostSessionID":host,
            "requestID":"collect-fixture-native-arrived","expectedRevision":approachRecord["recordRevision"]!,"checkpoint":approachRecord["state"]!,
            "runRequestID":approachRun["requestID"]!,"generation":approachRun["generation"]!,"phaseGeneration":approachRun["phaseGeneration"]!,
            "phase":approachRun["phase"]!,"kind":"arrived"])
        let run=(arrival["activity"] as! [String:Any])["run"] as! [String:Any]
        let entered=(arrival["snapshot"] as! [String:Any])["record"] as! [String:Any]
        _ = try controls.request(method:"world_activity_receipt",params:["worldID":world,"hostSessionID":host,
            "requestID":"collect-fixture-native-clip","expectedRevision":entered["recordRevision"]!,"checkpoint":entered["state"]!,
            "runRequestID":run["requestID"]!,"generation":run["generation"]!,"phaseGeneration":run["phaseGeneration"]!,
            "phase":run["phase"]!,"kind":"clipCompleted"])
    }
    func bindCollectionFixture(_ evidence:WishMachineClaimEvidence,job:WishMachineJob)->WishMachineClaimEvidence {
        var evidence=evidence
        guard let read=try? controls.request(method:"world_activity_read",params:["worldID":job.worldID,"hostSessionID":"fixture-native-world"]),
              let activity=read["activity"] as? [String:Any],let run=activity["run"] as? [String:Any] else {return evidence}
        evidence.activityRequestID=run["requestID"] as? String
        evidence.activityGeneration=(run["generation"] as? NSNumber)?.uint64Value
        evidence.phaseGeneration=(run["phaseGeneration"] as? NSNumber)?.uint64Value
        evidence.activityHostSessionID=run["hostSessionID"] as? String
        evidence.objectID=job.objectID
        return evidence
    }

    static func archive(directory: URL) throws -> Data {
        let owner = fixtureWishOwnerID(directory)
        guard let service = controlServices.values.compactMap(\.value).first(where: { $0.identities[owner] != nil }),
              let identity = service.identities[owner] else { throw PropTaskDaemonError.unavailable }
        let receipt = try service.request(method: "wish_control_read", params: ["ownerID": owner,
            "hostSessionID": identity["hostSessionID"]!, "expectedRevision": identity["expectedRevision"]!])
        return try JSONSerialization.data(withJSONObject: receipt["archive"]!)
    }

    static func rejectWrites(directory: URL, rejected: Bool) throws {
        let owner = fixtureWishOwnerID(directory)
        guard let service = controlServices.values.compactMap(\.value).first(where: { $0.identities[owner] != nil }) else {
            throw PropTaskDaemonError.unavailable
        }
        if rejected { service.rejectedOwners.insert(owner) } else { service.rejectedOwners.remove(owner) }
    }

    static func replaceArchive(directory: URL, data: Data) throws {
        let owner = fixtureWishOwnerID(directory)
        guard let service = controlServices.values.compactMap(\.value).first(where: { $0.identities[owner] != nil }) else {
            throw PropTaskDaemonError.unavailable
        }
        _ = try JSONSerialization.jsonObject(with: data)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        // Explicit private restart/crash fixture injection; never a production operation.
        try service.executeFixtureSQL("UPDATE wish_control_documents SET payload=CAST(X'\(hex)' AS TEXT),revision=revision+1 WHERE owner='\(owner)';")
    }

    static func publishEvent(directory: URL, event: WishMachineEvent, consumed: Bool) throws {
        let owner = fixtureWishOwnerID(directory)
        guard let service = controlServices.values.compactMap(\.value).first(where: { $0.identities[owner] != nil }) else {
            throw PropTaskDaemonError.unavailable
        }
        let archive = try JSONSerialization.jsonObject(with: self.archive(directory: directory)) as! [String: Any]
        let job = (archive["jobs"] as? [[String: Any]])?.first(where: {
            ($0["id"] as? String)?.lowercased() == event.wishID.uuidString.lowercased()
        })
        let taskID = job?["jobID"] as? String ?? event.wishID.uuidString
        _ = try service.request(method: "publish_message", params: ["id": event.id.uuidString,
            "taskId": taskID, "worldID": event.worldID, "residentScope": event.residentScope,
            "kind": "wish." + event.kind.rawValue,
            "payload": ["wish_id": event.wishID.uuidString, "object_id": event.objectID]])
        if consumed {
            _ = try service.request(method: "ack_message", params: ["id": event.id.uuidString,
                "worldID": event.worldID, "residentScope": event.residentScope, "consumer": "agent"])
        }
    }

    // Positive resume cases require an actual current scheduler human claim,
    // rather than merely inventing a UUID in the Swift tool session.
    static func claimHuman(directory: URL, authorizationID: UUID, worldID: String, residentScope: String) throws {
        let owner = fixtureWishOwnerID(directory)
        guard let service = controlServices.values.compactMap(\.value).first(where: { $0.identities[owner] != nil }),
              let hostSession = service.identities[owner]?["hostSessionID"] as? String else {
            throw PropTaskDaemonError.unavailable
        }
        let scope: [String: Any] = ["worldID": worldID, "residentScope": residentScope]
        func rpc(_ method: String, _ values: [String: Any]) throws -> [String: Any] {
            try service.request(method: method, params: scope.merging(values) { _, new in new })
        }
        let before = try rpc("agent_loop_read", [:])
        for event in before["events"] as? [[String: Any]] ?? [] where event["state"] as? String == "claimed" {
            _ = try rpc("agent_loop_complete", ["eventID": event["eventID"]!, "runID": event["runID"]!,
                "hostSessionID": event["hostSessionID"]!, "status": "completed", "receipt": ["fixtureHumanTurnCompleted": true]])
        }
        _ = try rpc("agent_loop_configure", ["hostSessionID": hostSession, "hourlyLimit": 6,
            "minimumWakeIntervalSeconds": 1, "backgroundEnabled": true, "available": true, "humanTurn": true])
        let event = "human-" + UUID().uuidString, message = "message-" + UUID().uuidString
        _ = try rpc("agent_loop_enqueue", ["eventID": event, "intentID": "fixture-resume",
            "kind": "human", "intentState": "waiting_user", "messageIDs": [message],
            "inputRefs": [message: "private-fixture-input-" + message], "command": ["type": "resident_human_turn"]])
        let receipt = try rpc("agent_loop_claim", ["eventID": event, "runID": authorizationID.uuidString,
            "hostSessionID": hostSession, "nowMillis": Int64(Date().timeIntervalSince1970 * 1000)])
        guard receipt["claimed"] as? Bool == true else { throw PropTaskDaemonError.unavailable }
    }

    func serviceRequest(method: String, params: [String: Any]) throws -> [String: Any] {
        try controls.startIfNeeded()
        return try controls.request(method: method, params: params)
    }

    func asyncControlRequest(method: String, data: Data) async throws -> Data {
        try controls.startIfNeeded()
        await controlGate.wait(method: method)
        guard let params = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let descriptor = try JSONSerialization.jsonObject(with: Data(contentsOf: controls.root.appendingPathComponent("taskd.endpoint.json"))) as? [String: Any],
              let address = descriptor["address"] as? String, let token = descriptor["token"] as? String,
              let url = URL(string: "http://\(address)/rpc") else { throw PropTaskDaemonError.invalidFrame }
        if rejectedControlMethods.contains(method)
            || (params["ownerID"] as? String).map({ controls.rejectedOwners.contains($0) }) == true {
            throw PropTaskDaemonError.requestRejectedWith(code: "fixture_control_write_rejected")
        }
        let id = UUID().uuidString
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(id, forHTTPHeaderField: "X-GMGN-Client-ID")
        let (bytes, _) = try await URLSession.shared.data(for: request)
        guard let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              envelope["id"] as? String == id else { throw PropTaskDaemonError.invalidFrame }
        if let error = envelope["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "fixture_rpc_failure"
            FileHandle.standardError.write(Data("FAIL[fixture async control]: \(method): \(code)\n".utf8))
            throw PropTaskDaemonError.requestRejectedWith(code: code)
        }
        guard let result = envelope["result"] as? [String: Any] else { throw PropTaskDaemonError.invalidFrame }
        if let owner = params["ownerID"] as? String {
            var identity = params; identity["expectedRevision"] = result["revision"]
            controls.identities[owner] = identity
        }
        return try JSONSerialization.data(withJSONObject: result)
    }

    func controlRequest(method: String, params: Data) async throws -> Data {
        try await asyncControlRequest(method: method, data: params)
    }

    func configure(endpoint: URL, token: String) async throws {
        guard readable else { throw PropGenerationError.historyUnavailable }
        client = try PropGenerationClient(endpoint: endpoint, token: token, session: session)
        onSnapshot?(.init(jobs: jobs, sequence: sequence))
    }

    func clearConfiguration() { client = nil }
    func disconnect() { /* A client's disappearance does not cancel accepted work. */ }

    func submit(id: UUID, endpoint: URL, name: String, png: Data, source: PropGenerationSource,
                heightMeters: Double) async throws -> PropGenerationRecord {
        try await submit(id: id, endpoint: endpoint, name: name, png: png, source: source,
            heightMeters: heightMeters, context: nil)
    }

    func submit(id: UUID, endpoint: URL, name: String, png: Data, source: PropGenerationSource,
                heightMeters: Double, context: PropTaskContext?) async throws -> PropGenerationRecord {
        guard readable, let client else { throw PropGenerationError.missingToken }
        if rejectSubmit { throw PropGenerationError.invalidResponse }
        if let context { contexts[id] = context }
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        if let known = jobs.first(where: { $0.id == id }) {
            guard known.endpoint == endpoint, known.imageSHA256 == digest, known.name == name,
                  known.source == source, known.heightMeters == heightMeters else { throw PropGenerationError.invalidInput }
            return known
        }
        try PropGenerationClient.validateInput(png: png, name: name, source: source, heightMeters: heightMeters)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(id.uuidString + ".png")
        try png.write(to: path, options: .atomic)
        let record = PropGenerationRecord(id: id, name: name, endpoint: endpoint, imagePath: path.path,
            imageSHA256: digest, heightMeters: heightMeters, source: source, idempotencyKey: id.uuidString,
            // The intercepted fixture provider owns this submit immediately.
            // Publish its in-flight leaf state so the separate real control
            // daemon does not schedule this mock job with no real credentials.
            backendStage: "submitting", cancelRequested: false)
        jobs.append(record)
        try publish(id)
        startSubmit(id, client: client)
        return record // Durable local queue acceptance, never waits for fixture HTTP response.
    }

    func retry(id: UUID) async throws -> PropGenerationRecord {
        guard let client, let index = jobs.firstIndex(where: { $0.id == id }) else { throw PropGenerationError.missingTask }
        if jobs[index].receipt == nil {
            jobs[index].backendStage = "submitting"
            jobs[index].lastError = nil
            try publish(id)
            startSubmit(id, client: client)
        } else if jobs[index].receipt?.state == .completed && jobs[index].localModelPath == nil {
            await advance(id, client: client)
        }
        return jobs.first { $0.id == id }!
    }

    func cancel(id: UUID) async throws -> PropGenerationRecord {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { throw PropGenerationError.missingTask }
        jobs[index].cancelRequested = true
        if jobs[index].receipt == nil && !active.contains(id) { jobs[index].backendStage = "cancelled" }
        else { jobs[index].backendStage = "cancel_requested" }
        try publish(id)
        if let client, jobs[index].receipt != nil { await advance(id, client: client) }
        return jobs.first { $0.id == id }!
    }

    func snapshot() async throws -> PropTaskDaemonSnapshot {
        guard readable else { throw PropGenerationError.historyUnavailable }
        // The fake daemon runs one deterministic backend cycle before answering the local snapshot.
        if let client {
            for id in jobs.map(\.id) where !active.contains(id) { await advance(id, client: client) }
        }
        return .init(jobs: jobs, sequence: sequence)
    }

    /// Explicit fake-backend push, used to prove a completed task reaches the app without a model read.
    func pushBackendChanges() async {
        guard let client else { return }
        for id in jobs.map(\.id) where !active.contains(id) { await advance(id, client: client) }
    }

    private func startSubmit(_ id: UUID, client: PropGenerationClient) {
        guard active.insert(id).inserted else { return }
        Task { @MainActor [self] in
            defer { active.remove(id) }
            guard let record = jobs.first(where: { $0.id == id }) else { return }
            do {
                let receipt = try await client.submit(png: Data(contentsOf: URL(fileURLWithPath: record.imagePath)),
                    name: record.name, source: record.source, heightMeters: record.heightMeters,
                    idempotencyKey: record.idempotencyKey)
                try update(id, receipt: receipt)
            } catch {
                guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
                jobs[index].backendStage = "submission_uncertain"
                // 与真实守护进程逐字一致：传输失败（含提交响应丢失）在 provider 层映射为
                // `network_unavailable`（services/gmgn-taskd/src/provider.rs:45），调度器此后
                // 不再自动重发 `submission_uncertain`（daemon.rs:770/:787）。宿主据此区分
                // "网络类未知结果"（可在恢复后确认）与"真实被拒/未授权"（绝不重发）。
                jobs[index].lastError = "network_unavailable"
                try? publish(id)
            }
            if let current = jobs.first(where: { $0.id == id }),
               current.cancelRequested == true || current.receipt?.state == .completed {
                await advance(id, client: client)
            }
        }
    }

    private func advance(_ id: UUID, client: PropGenerationClient) async {
        guard let record = jobs.first(where: { $0.id == id }), let receipt = record.receipt else { return }
        do {
            if !receipt.state.isTerminal {
                let refreshed: PropGenerationReceipt
                if record.cancelRequested == true && receipt.state != .cancelRequested {
                    refreshed = try await client.cancel(id: receipt.id)
                } else { refreshed = try await client.status(id: receipt.id) }
                try update(id, receipt: refreshed)
            }
            guard let index = jobs.firstIndex(where: { $0.id == id }),
                  let completed = jobs[index].receipt, completed.state == .completed,
                  jobs[index].localModelPath == nil else { return }
            let bytes = try await client.download(completed)
            let path = directory.appendingPathComponent(id.uuidString + ".glb")
            try bytes.write(to: path, options: .atomic)
            jobs[index].localModelPath = path.path
            jobs[index].backendStage = "ready"
            jobs[index].lastError = nil
            try publish(id)
        } catch {
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[index].lastError = "fixture backend observation/download failed"
            try? publish(id)
        }
    }

    private func update(_ id: UUID, receipt: PropGenerationReceipt) throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].receipt = receipt
        jobs[index].lastError = nil
        switch receipt.state {
        case .completed: jobs[index].backendStage = jobs[index].localModelPath == nil ? "downloading" : "ready"
        case .failed: jobs[index].backendStage = "failed"
        case .cancelled: jobs[index].backendStage = "cancelled"
        case .interrupted: jobs[index].backendStage = "interrupted"
        case .cancelRequested: jobs[index].backendStage = "cancel_requested"
        default: jobs[index].backendStage = "running"
        }
        try publish(id)
    }

    private func publish(_ id: UUID) throws {
        guard readable, let index = jobs.firstIndex(where: { $0.id == id }) else { throw PropGenerationError.historyUnavailable }
        // Explicit fake-provider facts are seeded into the private real store. Claim checks
        // still deserialize that row and validate the actual private-root GLB bytes/hash.
        try controls.startIfNeeded()
        if let path = jobs[index].localModelPath {
            let destination = controls.root.appendingPathComponent(id.uuidString + ".glb")
            if path != destination.path {
                try Data(contentsOf: URL(fileURLWithPath: path)).write(to: destination, options: .atomic)
                jobs[index].localModelPath = destination.path
            }
        }
        let record = jobs[index]
        var core = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        if let context = contexts[id] {
            core["context"] = ["worldID": context.worldID, "residentScope": context.residentScope]
        }
        let stored = try JSONSerialization.data(withJSONObject: ["job": core, "attempted": true])
        try controls.executeFixtureSQL("INSERT INTO jobs(id,data) VALUES('\(id.uuidString)',CAST(X'\(stored.map { String(format: "%02x", $0) }.joined())' AS TEXT)) ON CONFLICT(id) DO UPDATE SET data=excluded.data;")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs).write(to: directory.appendingPathComponent("tasks.json"), options: .atomic)
        // Preserve the original native submit's scope across fixture-store restart.
        // The production Stored row already persists it; replacing that row with
        // a context-free mock snapshot would erase real authority evidence.
        try JSONEncoder().encode(contexts).write(to:directory.appendingPathComponent("task-contexts.json"),options:.atomic)
        sequence += 1
        onEvent?(.init(sequence: sequence, job: record))
    }
}

actor WishFixtureControlGate {
    private var methods: Set<String> = []
    private var pending: [CheckedContinuation<Void, Never>] = []
    var blockedCount: Int { pending.count }
    func hold(_ method: String) { methods.insert(method) }
    func wait(method: String) async {
        guard methods.contains(method) else { return }
        await withCheckedContinuation { pending.append($0) }
    }
    func release() {
        methods.removeAll()
        let waiters = pending; pending.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// Owns only a child launched by this fixture and a private test directory.
/// No production helper, application support directory, credentials or audio are accessed.
private final class WishFixtureWeakControlService {
    weak var value: WishFixtureControlService?
    init(_ value: WishFixtureControlService) { self.value = value }
}

private final class WishFixtureRPCReply: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()
    private var error: Error?
    func receive(_ value: Data) { lock.lock(); data.append(value); lock.unlock() }
    func finish(_ value: Error?) { lock.lock(); error = value; lock.unlock(); done.signal() }
    func result() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let error { throw error }
        return data
    }
}

private final class WishFixtureControlService {
    private(set) var root: URL
    var identities: [String: [String: Any]] = [:]
    var rejectedOwners: Set<String> = []
    private var child: Process?
    init(root: URL) { self.root = root.resolvingSymlinksInPath() }
    func executeFixtureSQL(_ sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", root.appendingPathComponent("tasks.sqlite3").path, ".timeout 2000", sql]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe(); process.standardError = errors
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            FileHandle.standardError.write(errors.fileHandleForReading.readDataToEndOfFile())
            throw PropTaskDaemonError.requestRejectedWith(code: "fixture_seed_failed")
        }
    }
    func request(method: String, params: [String: Any]) throws -> [String: Any] {
        let descriptor = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("taskd.endpoint.json"))) as! [String: Any]
        let id = UUID().uuidString
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        var request = URLRequest(url: URL(string: "http://\(descriptor["address"] as! String)/rpc")!, timeoutInterval: 2)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(descriptor["token"] as! String)", forHTTPHeaderField: "Authorization")
        request.setValue(id, forHTTPHeaderField: "X-GMGN-Client-ID")
        let reply = WishFixtureRPCReply()
        let transport = TaskdHTTPTransport(streaming: false, maximumBytes: 16 * 1024 * 1024,
            receive: { reply.receive($0) }, completion: { reply.finish($0) })
        transport.start(request); defer { transport.cancel() }
        guard reply.done.wait(timeout: .now() + 2) == .success else { throw PropTaskDaemonError.timedOut }
        let envelope = try JSONSerialization.jsonObject(with: reply.result()) as! [String: Any]
        guard envelope["id"] as? String == id else { throw PropTaskDaemonError.invalidFrame }
        if let error = envelope["error"] as? [String: Any] {
            throw PropTaskDaemonError.requestRejectedWith(code: error["code"] as? String ?? "fixture_rpc_failure")
        }
        guard let result = envelope["result"] as? [String: Any] else { throw PropTaskDaemonError.invalidFrame }
        return result
    }
    func startIfNeeded() throws {
        if let child, child.isRunning { return }
        let binary = ProcessInfo.processInfo.environment["TASKD_BIN"]
            ?? FileManager.default.currentDirectoryPath + "/target/debug/gmgn-taskd"
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw PropTaskDaemonError.helperMissing
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let resolved = realpath(root.path, nil) else { throw PropTaskDaemonError.unavailable }
        root = URL(fileURLWithPath: String(cString: resolved))
        free(resolved)
        let endpoint = root.appendingPathComponent("taskd.endpoint.json")
        let process = Process()
        let diagnostic = Pipe()
        // A fixture assertion can abort Swift without deinit. Supervise this one private
        // child so it also exits when its owning test PID disappears.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
        "$1" --root "$2" --endpoint-file "$3" --concurrency 1 &
        daemon_pid=$!
        watcher_pid=
        trap 'kill "$daemon_pid" 2>/dev/null; if [ -n "$watcher_pid" ]; then kill "$watcher_pid" 2>/dev/null; fi' TERM INT EXIT
        (while kill -0 "$4" 2>/dev/null; do sleep 1; done; kill "$daemon_pid" 2>/dev/null) &
        watcher_pid=$!
        wait "$daemon_pid"
        result=$?
        exit "$result"
        """, "wish-fixture-supervisor", binary, root.path, endpoint.path, String(getpid())]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = diagnostic
        try process.run()
        child = process
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            if let bytes = try? Data(contentsOf: endpoint),
               let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               value["version"] as? Int == 2 { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        let failure = diagnostic.fileHandleForReading.readDataToEndOfFile()
        FileHandle.standardError.write(Data("FAIL[fixture startup] \(root.path): \(String(decoding: failure.prefix(4096), as: UTF8.self))\n".utf8))
        child = nil
        throw PropTaskDaemonError.unavailable
    }
    deinit {
        if let child, child.isRunning { child.terminate(); child.waitUntilExit() }
    }
}

private func fixtureWishOwnerID(_ directory: URL) -> String {
    SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
}

@MainActor func fixtureWishArchive(directory: URL) throws -> Data {
    try WishMachineDaemonFixture.archive(directory: directory)
}

@MainActor func fixtureWishRejectControlWrites(directory: URL, rejected: Bool) throws {
    try WishMachineDaemonFixture.rejectWrites(directory: directory, rejected: rejected)
}

@MainActor func fixtureWishReplaceArchive(directory: URL, data: Data) throws {
    try WishMachineDaemonFixture.replaceArchive(directory: directory, data: data)
}

@MainActor func fixtureWishPublishEvent(directory: URL, event: WishMachineEvent, consumed: Bool = false) throws {
    try WishMachineDaemonFixture.publishEvent(directory: directory, event: event, consumed: consumed)
}

@MainActor func fixtureWishClaimHuman(directory: URL, authorizationID: UUID, worldID: String = "world", residentScope: String = "resident") throws {
    try WishMachineDaemonFixture.claimHuman(directory: directory, authorizationID: authorizationID,
        worldID: worldID, residentScope: residentScope)
}

@MainActor
func fixtureWishStore(directory: URL, session: URLSession, daemonClient: WishMachineDaemonFixture? = nil) -> PropGenerationStore {
    let daemon = daemonClient ?? WishMachineDaemonFixture(directory: directory, session: session)
    let store = PropGenerationStore(directory: directory, session: session, daemonClient: daemon)
    fixtureWishDaemons[ObjectIdentifier(store)] = WishFixtureWeakDaemon(daemon)
    return store
}

private final class WishFixtureWeakDaemon {
    weak var value: WishMachineDaemonFixture?
    init(_ value: WishMachineDaemonFixture) { self.value = value }
}

@MainActor private var fixtureWishDaemons: [ObjectIdentifier: WishFixtureWeakDaemon] = [:]

@MainActor
func fixtureWishCoordinator(store: PropGenerationStore, directory: URL? = nil,
    archiveFileManager: FileManager = .default, wishControlCall: WishMachineCoordinator.ControlCall? = nil,
    wishControlHostSessionID: String = UUID().uuidString,
    canClaim: @escaping @MainActor (WishMachineJob) -> WishMachineClaimEvidence?) async throws -> WishMachineCoordinator {
    let daemon = fixtureWishDaemons[ObjectIdentifier(store)]?.value
    let call: WishMachineCoordinator.ControlCall?
    if let wishControlCall { call = wishControlCall }
    else if let daemon { call = { method, bytes in try await daemon.asyncControlRequest(method: method, data: bytes) } }
    else { call = nil } // Explicit real-daemon fixtures keep the production transport.
    let coordinator = WishMachineCoordinator(store: store, directory: directory,
        archiveFileManager: archiveFileManager, wishControlCall: call,
        wishControlHostSessionID: wishControlHostSessionID, canClaim: {job in
            guard let evidence=canClaim(job) else {return nil}
            if ProcessInfo.processInfo.environment["GMGN_WISH_COLLECTION_FIXTURE"] == "1",let daemon {
                return daemon.bindCollectionFixture(evidence,job:job)
            }
            return evidence
        })
    if ProcessInfo.processInfo.environment["GMGN_WISH_COLLECTION_FIXTURE"] == "1",let daemon {
        try daemon.prepareCollectionFixture()
    }
    do { try await coordinator.waitUntilReady() }
    catch {
        // Negative archive tests inspect the actual failed projection. No archive is fabricated.
        guard !coordinator.isReadable, coordinator.errorMessage != nil else { throw error }
    }
    return coordinator
}
