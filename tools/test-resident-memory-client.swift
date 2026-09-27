// ResidentMemoryClient 与 docs/plans/2026-09-08-voicemem-rust-contract.md 的
// 直接核对（完全离线：StubTransport 只记录请求并回放 fixture，绝不启动
// taskd/宿主，不读数据库）。覆盖 memory_configure/status/read/query/turn/
// pending/compact 七个冻结方法的请求形状与严格响应解析：nested scope 两维度、
// memory:null 与快照/状态摘要可选字段、不合法响应一律 invalidResponse（绝不把
// 坏数据当空记忆/伪成功）、daemon error 原样透传、unconfigured、pending、
// compact replay/watermark、值类型 Codable 往返（nil 可选字段编码时省略）。
// 另核对编排合同（2026-09-08-voicemem-rust-orchestration.md）增补：memory_
// recall / memory_ingest 的请求形状与严格响应解析、memory_status 可选
// orchestration 字段（旧 fixture 缺省该键仍兼容）。
import Foundation
import Darwin

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-resident-memory-client-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let harness = #"""
import Foundation
import Darwin

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

enum StubError: Error { case exhausted }

/// 完全离线的传输层：按序回放预设响应并记录每次请求。畸形响应用例只校验
/// 客户端解析，不声称自己是 daemon；daemon 错误用 thrownError 模拟。
@MainActor final class StubTransport: ResidentStateTransport, @unchecked Sendable {
    var responses: [[String: ResidentStateJSON]]
    var recorded: [(method: String, params: [String: ResidentStateJSON])] = []
    var thrownError: Error?
    init(_ responses: [[String: ResidentStateJSON]]) { self.responses = responses }
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        recorded.append((method, params))
        if let thrownError { throw thrownError }
        guard !responses.isEmpty else { throw StubError.exhausted }
        return responses.removeFirst()
    }
}

func scope(_ world: String = "world-a", _ resident: String = "resident-a") -> ResidentStateScope {
    ResidentStateScope(worldID: world, residentScope: resident)
}

// MARK: - fixture 构造器

func entryObject(id: String, category: String, text: String,
                 observedAt: ResidentStateJSON? = nil,
                 grounding: ResidentStateJSON? = nil) -> ResidentStateJSON {
    var object: [String: ResidentStateJSON] = ["id": .string(id), "category": .string(category), "text": .string(text)]
    if let observedAt { object["observedAt"] = observedAt }
    if let grounding { object["grounding"] = grounding }
    return .object(object)
}

func snapshotJSON(schemaVersion: Double = 1, revision: Double = 3, vectorGeneration: Double = 3,
                  processedWatermark: Double = 12, nextWatermark: Double = 15,
                  embedding: ResidentStateJSON = .object(["model": .string("text-embed"), "dimensions": .number(384)]),
                  facts: [ResidentStateJSON] = [], notes: [ResidentStateJSON] = []) -> ResidentStateJSON {
    .object([
        "schemaVersion": .number(schemaVersion),
        "revision": .number(revision),
        "vectorGeneration": .number(vectorGeneration),
        "processedWatermark": .number(processedWatermark),
        "nextWatermark": .number(nextWatermark),
        "embedding": embedding,
        "sections": .object(["facts": .array(facts), "notes": .array(notes)]),
    ])
}

func statusMemoryJSON(revision: Double = 3, vectorGeneration: Double = 3,
                      processedWatermark: Double = 12, nextWatermark: Double = 15,
                      model: String = "text-embed", dimensions: Double = 384,
                      facts: Double = 2, notes: Double = 1) -> ResidentStateJSON {
    .object([
        "schemaVersion": .number(1),
        "revision": .number(revision),
        "vectorGeneration": .number(vectorGeneration),
        "processedWatermark": .number(processedWatermark),
        "nextWatermark": .number(nextWatermark),
        "embedding": .object(["model": .string(model), "dimensions": .number(dimensions)]),
        "entryCounts": .object(["facts": .number(facts), "notes": .number(notes)]),
    ])
}

func statusJSON(compaction: Bool = true, embedding: Bool = true,
                memory: ResidentStateJSON = .null, pendingTurns: Double = 0) -> [String: ResidentStateJSON] {
    [
        "configured": .object(["compaction": .bool(compaction), "embedding": .bool(embedding)]),
        "memory": memory,
        "pendingTurns": .number(pendingTurns),
    ]
}

func hitJSON(section: String, id: String, text: String, distance: Double,
             observedAt: ResidentStateJSON? = nil) -> ResidentStateJSON {
    var object: [String: ResidentStateJSON] = [
        "section": .string(section), "id": .string(id), "text": .string(text), "distance": .number(distance),
    ]
    if let observedAt { object["observedAt"] = observedAt }
    return .object(object)
}

func queryJSON(status: String, hits: [ResidentStateJSON] = []) -> [String: ResidentStateJSON] {
    ["status": .string(status), "results": .array(hits)]
}

func pendingTurnJSON(turnID: String, watermark: Double, role: String, text: String,
                     interrupted: Bool) -> ResidentStateJSON {
    .object(["turnID": .string(turnID), "watermark": .number(watermark), "role": .string(role),
             "text": .string(text), "interrupted": .bool(interrupted)])
}

func turnResultJSON(accepted: Bool = true, turnID: String = "turn-uuid",
                    watermark: Double = 1, pendingTurns: Double = 2) -> [String: ResidentStateJSON] {
    ["accepted": .bool(accepted), "turnID": .string(turnID), "watermark": .number(watermark),
     "pendingTurns": .number(pendingTurns)]
}

func compactResultJSON(revision: Double, vectorGeneration: Double, replayed: Bool,
                       processedWatermark: Double, pendingTurns: Double) -> [String: ResidentStateJSON] {
    ["revision": .number(revision), "vectorGeneration": .number(vectorGeneration),
     "replayed": .bool(replayed), "processedWatermark": .number(processedWatermark),
     "pendingTurns": .number(pendingTurns)]
}

/// 期望抛 invalidResponse；抛其他错误也算失败。
@MainActor func expectInvalid(_ operation: @escaping @MainActor () async throws -> Void, _ message: String) async {
    do {
        try await operation()
        check(false, message)
    } catch ResidentStateError.invalidResponse {
        check(true, message)
    } catch {
        check(false, "\(message) (threw \(error))")
    }
}

/// 期望 transport 的 daemon 错误原样透传且 code 保留。
@MainActor func expectDaemonCode(_ expected: String, _ message: String,
                                 _ operation: @escaping @MainActor () async throws -> Void) async {
    do {
        try await operation()
        check(false, message)
    } catch ResidentStateError.daemon(let code) {
        check(code == expected, "\(message) (code \(code))")
    } catch {
        check(false, "\(message) (threw \(error))")
    }
}

@MainActor func run() async throws {
    // MARK: - 1. 七个方法的请求形状与 nested scope
    do {
        let sequence = StubTransport([
            ["configured": .bool(true)],
            statusJSON(),
            ["memory": .null],
            queryJSON(status: "ok"),
            turnResultJSON(),
            ["turns": .array([])],
            compactResultJSON(revision: 4, vectorGeneration: 4, replayed: false,
                              processedWatermark: 12, pendingTurns: 3),
        ])
        let client = ResidentMemoryClient(transport: sequence)
        try await client.memoryConfigure(kind: .embedding, endpoint: "http://127.0.0.1:4711",
                                         token: "configure-secret-token", model: "text-embed")
        _ = try await client.memoryStatus(scope: scope("w-1", "r-2"))
        _ = try await client.memoryRead(scope: scope("w-1", "r-2"))
        _ = try await client.memoryQuery(scope: scope("w-1", "r-2"), query: "居民偏好")
        _ = try await client.memoryTurn(scope: scope("w-1", "r-2"), role: .user, text: "今天想听爵士")
        _ = try await client.memoryPending(scope: scope("w-1", "r-2"))
        _ = try await client.memoryCompact(scope: scope("w-1", "r-2"), requestID: "compact-1")
        check(sequence.recorded.count == 7, "one transport call per memory method")

        let configureParams = sequence.recorded[0].params
        check(sequence.recorded[0].method == "memory_configure", "memory_configure wire method name")
        check(configureParams["kind"]?.stringValue == "embedding", "memory_configure carries kind")
        check(configureParams["endpoint"]?.stringValue == "http://127.0.0.1:4711", "memory_configure carries endpoint")
        check(configureParams["token"]?.stringValue == "configure-secret-token", "memory_configure carries token in params only")
        check(configureParams["model"]?.stringValue == "text-embed", "memory_configure carries model when provided")
        check(configureParams["scope"] == nil, "memory_configure has no scope")

        for index in 1...6 {
            let method = sequence.recorded[index].method
            let params = sequence.recorded[index].params
            check(params["worldID"] == nil && params["residentScope"] == nil,
                  "\(method) keeps scope nested, no top-level dimension leak")
            guard let scopeValue = params["scope"], case let .object(scopeJSON) = scopeValue else {
                check(false, "\(method) carries a nested scope object")
                continue
            }
            check(scopeJSON["worldID"]?.stringValue == "w-1" && scopeJSON["residentScope"]?.stringValue == "r-2",
                  "\(method) keeps both scope dimensions")
        }
        let expectedMethods = ["memory_status", "memory_read", "memory_query", "memory_turn", "memory_pending", "memory_compact"]
        for (offset, expected) in expectedMethods.enumerated() {
            check(sequence.recorded[offset + 1].method == expected, "wire method name \(expected)")
        }
        let queryParams = sequence.recorded[3].params
        check(queryParams["query"]?.stringValue == "居民偏好" && queryParams["topK"]?.doubleValue == 8,
              "memory_query carries query and default topK 8")
        let turnParams = sequence.recorded[4].params
        check(turnParams["role"]?.stringValue == "user" && turnParams["text"]?.stringValue == "今天想听爵士",
              "memory_turn carries role and text")
        check(turnParams["interrupted"]?.boolValue == false, "memory_turn carries interrupted default false")
        let compactParams = sequence.recorded[6].params
        check(compactParams["requestID"]?.stringValue == "compact-1", "memory_compact carries requestID")
        check(compactParams["expectedVectorGeneration"] == nil,
              "memory_compact omits expectedVectorGeneration when not provided")
    }

    // 2. 可选入参省略/携带：model、expectedVectorGeneration、topK、interrupted。
    do {
        let b = StubTransport([
            ["configured": .bool(true)],
            compactResultJSON(revision: 5, vectorGeneration: 5, replayed: false,
                              processedWatermark: 20, pendingTurns: 1),
            queryJSON(status: "empty"),
            turnResultJSON(turnID: "turn-uuid", watermark: 9, pendingTurns: 4),
        ])
        let client = ResidentMemoryClient(transport: b)
        try await client.memoryConfigure(kind: .compaction, endpoint: "http://127.0.0.1:9", token: "second-token")
        _ = try await client.memoryCompact(scope: scope(), requestID: "compact-2", expectedVectorGeneration: 7)
        _ = try await client.memoryQuery(scope: scope(), query: "q", topK: 3)
        _ = try await client.memoryTurn(scope: scope(), role: .agent, text: "好的", interrupted: true)
        check(b.recorded[0].params["model"] == nil, "memory_configure omits model when not provided")
        check(b.recorded[0].params["kind"]?.stringValue == "compaction", "compaction kind is encoded")
        check(b.recorded[1].params["expectedVectorGeneration"]?.doubleValue == 7,
              "memory_compact carries expectedVectorGeneration when provided")
        check(b.recorded[2].params["topK"]?.doubleValue == 3, "memory_query carries explicit topK")
        check(b.recorded[3].params["interrupted"]?.boolValue == true && b.recorded[3].params["role"]?.stringValue == "agent",
              "memory_turn carries interrupted true and agent role")
    }

    // MARK: - 3. daemon error 原样透传（每方法一个代表性 code）
    await expectDaemonCode("invalid_memory_configure", "memory_configure daemon error passes through") {
        let t = StubTransport([])
        t.thrownError = ResidentStateError.daemon("invalid_memory_configure")
        try await ResidentMemoryClient(transport: t).memoryConfigure(kind: .embedding, endpoint: "http://127.0.0.1:1", token: "tok")
    }
    await expectDaemonCode("invalid_scope", "memory_status daemon error passes through") {
        let t = StubTransport([])
        t.thrownError = ResidentStateError.daemon("invalid_scope")
        _ = try await ResidentMemoryClient(transport: t).memoryStatus(scope: scope())
    }
    await expectDaemonCode("memory_snapshot_too_large", "memory_read daemon error passes through") {
        let t = StubTransport([])
        t.thrownError = ResidentStateError.daemon("memory_snapshot_too_large")
        _ = try await ResidentMemoryClient(transport: t).memoryRead(scope: scope())
    }
    await expectDaemonCode("embedding_dimension_mismatch", "memory_query daemon error passes through") {
        let t = StubTransport([])
        t.thrownError = ResidentStateError.daemon("embedding_dimension_mismatch")
        _ = try await ResidentMemoryClient(transport: t).memoryQuery(scope: scope(), query: "q")
    }
    await expectDaemonCode("invalid_turn_text", "memory_turn daemon error passes through") {
        let t = StubTransport([])
        t.thrownError = ResidentStateError.daemon("invalid_turn_text")
        _ = try await ResidentMemoryClient(transport: t).memoryTurn(scope: scope(), role: .user, text: "x")
    }
    await expectDaemonCode("invalid_memory_pending", "memory_pending daemon error passes through") {
        let t = StubTransport([])
        t.thrownError = ResidentStateError.daemon("invalid_memory_pending")
        _ = try await ResidentMemoryClient(transport: t).memoryPending(scope: scope())
    }
    await expectDaemonCode("memory_request_conflict", "memory_compact daemon error passes through") {
        let t = StubTransport([])
        t.thrownError = ResidentStateError.daemon("memory_request_conflict")
        _ = try await ResidentMemoryClient(transport: t).memoryCompact(scope: scope(), requestID: "c")
    }
    // 缺配置 = daemon 显式 unavailable，客户端只透传，绝不伪造成功。
    await expectDaemonCode("compaction_unavailable", "compaction_unavailable passes through") {
        let t = StubTransport([])
        t.thrownError = ResidentStateError.daemon("compaction_unavailable")
        _ = try await ResidentMemoryClient(transport: t).memoryCompact(scope: scope(), requestID: "c")
    }
    await expectDaemonCode("embedding_unavailable", "embedding_unavailable passes through") {
        let t = StubTransport([])
        t.thrownError = ResidentStateError.daemon("embedding_unavailable")
        _ = try await ResidentMemoryClient(transport: t).memoryQuery(scope: scope(), query: "q")
    }

    // MARK: - 4. memory_read：完整快照、memory:null、坏数据显式拒绝
    do {
        let snapshotResponse: [String: ResidentStateJSON] = ["memory": snapshotJSON(
            revision: 5, vectorGeneration: 5, processedWatermark: 21, nextWatermark: 24,
            facts: [
                entryObject(id: "f-1", category: "fact", text: "居民喜欢爵士",
                            observedAt: .string("2026-09-08"), grounding: .string("turn:7")),
                entryObject(id: "f-2", category: "preference", text: "偏好安静环境"),
            ],
            notes: [
                entryObject(id: "n-1", category: "relationship", text: "对女儿语气更柔和", grounding: .string("turn:11")),
                entryObject(id: "n-2", category: "experience", text: "雨天提及旧居会沉默",
                            observedAt: .string("2026-09-08"), grounding: .string("turn:14")),
            ])]
        let snapshot = try await ResidentMemoryClient(transport: StubTransport([snapshotResponse])).memoryRead(scope: scope())
        let expected = ResidentMemorySnapshot(
            schemaVersion: 1, revision: 5, vectorGeneration: 5,
            processedWatermark: 21, nextWatermark: 24,
            embedding: ResidentMemoryEmbedding(model: "text-embed", dimensions: 384),
            sections: ResidentMemorySections(
                facts: [
                    ResidentMemoryEntry(id: "f-1", category: .fact, text: "居民喜欢爵士",
                                        observedAt: "2026-09-08", grounding: "turn:7"),
                    ResidentMemoryEntry(id: "f-2", category: .preference, text: "偏好安静环境",
                                        observedAt: nil, grounding: nil),
                ],
                notes: [
                    ResidentMemoryEntry(id: "n-1", category: .relationship, text: "对女儿语气更柔和",
                                        observedAt: nil, grounding: "turn:11"),
                    ResidentMemoryEntry(id: "n-2", category: .experience, text: "雨天提及旧居会沉默",
                                        observedAt: "2026-09-08", grounding: "turn:14"),
                ]))
        if let snapshot {
            check(snapshot == expected, "memory_read decodes every snapshot field (revision/vectorGeneration/watermarks/embedding/sections)")
        } else {
            check(false, "full snapshot should decode to a value, not nil")
        }
    }
    do {
        let snapshot = try await ResidentMemoryClient(transport: StubTransport([["memory": .null]])).memoryRead(scope: scope())
        check(snapshot == nil, "memory_read with memory:null returns nil (no snapshot is not an error)")
    }
    do {
        // observedAt 显式 null 与缺省等价；grounding 缺失则为 nil。
        let snapshotResponse: [String: ResidentStateJSON] = ["memory": snapshotJSON(facts: [
            entryObject(id: "f-3", category: "fact", text: "null 日期", observedAt: .null),
        ])]
        let snapshot = try await ResidentMemoryClient(transport: StubTransport([snapshotResponse])).memoryRead(scope: scope())
        check(snapshot?.sections.facts.first?.observedAt == nil && snapshot?.sections.facts.first?.grounding == nil,
              "explicit null optional fields decode as nil")
    }
    await expectInvalid({ _ = try await ResidentMemoryClient(transport: StubTransport([[:]])).memoryRead(scope: scope()) },
                        "memory_read without a memory key is rejected (null is the only no-memory form)")
    do {
        var broken = snapshotJSON(facts: []).objectValue!
        broken.removeValue(forKey: "nextWatermark")
        _ = try await ResidentMemoryClient(transport: StubTransport([["memory": .object(broken)]])).memoryRead(scope: scope())
        check(false, "snapshot missing nextWatermark must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "snapshot missing nextWatermark is rejected")
    } catch {
        check(false, "snapshot missing nextWatermark must throw invalidResponse (got \(error))")
    }
    do {
        var snapshot = snapshotJSON(facts: []).objectValue!
        if case var .object(sections) = snapshot["sections"]! {
            sections.removeValue(forKey: "notes")
            snapshot["sections"] = .object(sections)
        }
        _ = try await ResidentMemoryClient(transport: StubTransport([["memory": .object(snapshot)]])).memoryRead(scope: scope())
        check(false, "snapshot missing sections.notes must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "snapshot missing sections.notes is rejected")
    } catch {
        check(false, "snapshot missing sections.notes must throw invalidResponse (got \(error))")
    }
    do {
        var entry = entryObject(id: "f-1", category: "fact", text: "x").objectValue!
        entry.removeValue(forKey: "text")
        let broken = snapshotJSON(facts: [.object(entry)])
        _ = try await ResidentMemoryClient(transport: StubTransport([["memory": broken]])).memoryRead(scope: scope())
        check(false, "entry missing text must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "entry missing text is rejected")
    } catch {
        check(false, "entry missing text must throw invalidResponse (got \(error))")
    }
    do {
        var response = statusJSON()
        response.removeValue(forKey: "configured")
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryStatus(scope: scope())
        check(false, "status without configured must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "status missing configured is rejected")
    } catch {
        check(false, "status missing configured must throw invalidResponse (got \(error))")
    }
    do {
        var response = statusJSON()
        response.removeValue(forKey: "memory")
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryStatus(scope: scope())
        check(false, "status without a memory key must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "status missing memory key is rejected (null is the only no-memory form)")
    } catch {
        check(false, "status missing memory must throw invalidResponse (got \(error))")
    }
    do {
        var response = statusJSON(memory: statusMemoryJSON())
        if case var .object(configured) = response["configured"]! {
            configured.removeValue(forKey: "embedding")
            response["configured"] = .object(configured)
        }
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryStatus(scope: scope())
        check(false, "configured missing embedding must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "configured missing embedding is rejected")
    } catch {
        check(false, "configured missing embedding must throw invalidResponse (got \(error))")
    }
    do {
        var response = statusJSON(memory: statusMemoryJSON())
        response["pendingTurns"] = .string("5")
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryStatus(scope: scope())
        check(false, "status pendingTurns of wrong type must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "status pendingTurns of wrong type is rejected")
    } catch {
        check(false, "status pendingTurns wrong type must throw invalidResponse (got \(error))")
    }
    do {
        var response = queryJSON(status: "ok")
        response.removeValue(forKey: "status")
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryQuery(scope: scope(), query: "q")
        check(false, "query without status must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "query missing status is rejected")
    } catch {
        check(false, "query missing status must throw invalidResponse (got \(error))")
    }
    do {
        var response = queryJSON(status: "ok")
        response.removeValue(forKey: "results")
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryQuery(scope: scope(), query: "q")
        check(false, "query without results must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "query missing results is rejected")
    } catch {
        check(false, "query missing results must throw invalidResponse (got \(error))")
    }
    do {
        var response = turnResultJSON()
        response.removeValue(forKey: "turnID")
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryTurn(scope: scope(), role: .user, text: "x")
        check(false, "turn without turnID must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "turn missing turnID is rejected")
    } catch {
        check(false, "turn missing turnID must throw invalidResponse (got \(error))")
    }
    do {
        var response = turnResultJSON()
        response.removeValue(forKey: "pendingTurns")
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryTurn(scope: scope(), role: .user, text: "x")
        check(false, "turn without pendingTurns must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "turn missing pendingTurns is rejected")
    } catch {
        check(false, "turn missing pendingTurns must throw invalidResponse (got \(error))")
    }

    // MARK: - 8. memory_pending：升序 turns 与逐字段解析
    do {
        let response: [String: ResidentStateJSON] = ["turns": .array([
            pendingTurnJSON(turnID: "t-1", watermark: 12, role: "user", text: "第一次", interrupted: false),
            pendingTurnJSON(turnID: "t-2", watermark: 13, role: "agent", text: "回复", interrupted: true),
            pendingTurnJSON(turnID: "t-3", watermark: 4_000_000_000, role: "user", text: "大水位", interrupted: false),
        ])]
        let turns = try await ResidentMemoryClient(transport: StubTransport([response])).memoryPending(scope: scope())
        check(turns.count == 3 && turns.map(\.watermark) == [12, 13, 4_000_000_000],
              "memory_pending keeps daemon-ordered watermarks (incl. > 32-bit)")
        if turns.count == 3 {
            check(turns[0].turnID == "t-1" && turns[0].role == .user && turns[0].text == "第一次" && turns[0].interrupted == false,
                  "pending turn parses turnID/role/text/interrupted")
            check(turns[1].role == .agent && turns[1].interrupted == true, "pending agent/interrupted parses")
        }
        let empty = try await ResidentMemoryClient(transport: StubTransport([["turns": .array([])]])).memoryPending(scope: scope())
        check(empty.isEmpty, "memory_pending empty list parses")
    }
    do {
        _ = try await ResidentMemoryClient(transport: StubTransport([[:]])).memoryPending(scope: scope())
        check(false, "pending without turns must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "pending missing turns is rejected")
    } catch {
        check(false, "pending missing turns must throw invalidResponse (got \(error))")
    }
    do {
        var turn = pendingTurnJSON(turnID: "t", watermark: 1, role: "user", text: "x", interrupted: false).objectValue!
        turn.removeValue(forKey: "interrupted")
        _ = try await ResidentMemoryClient(transport: StubTransport([["turns": .array([.object(turn)])]])).memoryPending(scope: scope())
        check(false, "pending turn missing interrupted must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "pending turn missing interrupted is rejected")
    } catch {
        check(false, "pending turn missing interrupted must throw invalidResponse (got \(error))")
    }
    do {
        var response = compactResultJSON(revision: 1, vectorGeneration: 1, replayed: false, processedWatermark: 1, pendingTurns: 0)
        response.removeValue(forKey: "replayed")
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryCompact(scope: scope(), requestID: "c")
        check(false, "compact without replayed must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "compact missing replayed is rejected")
    } catch {
        check(false, "compact missing replayed must throw invalidResponse (got \(error))")
    }
    do {
        var response = compactResultJSON(revision: 1, vectorGeneration: 1, replayed: false, processedWatermark: 1, pendingTurns: 0)
        response.removeValue(forKey: "vectorGeneration")
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryCompact(scope: scope(), requestID: "c")
        check(false, "compact without vectorGeneration must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "compact missing vectorGeneration is rejected")
    } catch {
        check(false, "compact missing vectorGeneration must throw invalidResponse (got \(error))")
    }

    // MARK: - 10. memory_configure 成功应答与坏应答
    do {
        try await ResidentMemoryClient(transport: StubTransport([["configured": .bool(true)]]))
            .memoryConfigure(kind: .compaction, endpoint: "http://127.0.0.1:9", token: "t")
        check(true, "memory_configure configured:true returns cleanly")
    } catch {
        check(false, "memory_configure configured:true should not throw (got \(error))")
    }
    await expectInvalid({ _ = try await ResidentMemoryClient(transport: StubTransport([[:]]))
        .memoryConfigure(kind: .compaction, endpoint: "http://127.0.0.1:9", token: "t") },
        "memory_configure without configured is rejected")
    await expectInvalid({ _ = try await ResidentMemoryClient(transport: StubTransport([["configured": .bool(false)]]))
        .memoryConfigure(kind: .compaction, endpoint: "http://127.0.0.1:9", token: "t") },
        "memory_configure configured:false is rejected, never a silent success")

    // MARK: - 11. 值类型 Codable：往返一致；nil 可选字段编码时省略
    do {
        let snapshot = ResidentMemorySnapshot(
            schemaVersion: 1, revision: 3, vectorGeneration: 3,
            processedWatermark: 12, nextWatermark: 15,
            embedding: ResidentMemoryEmbedding(model: "text-embed", dimensions: 384),
            sections: ResidentMemorySections(
                facts: [
                    ResidentMemoryEntry(id: "f-1", category: .fact, text: "居民喜欢爵士",
                                        observedAt: nil, grounding: "turn:7"),
                ],
                notes: [
                    ResidentMemoryEntry(id: "n-1", category: .experience, text: "雨天会沉默",
                                        observedAt: "2026-09-08", grounding: "turn:14"),
                ]))
        let data = try JSONEncoder().encode(snapshot)
        let roundTrip = try JSONDecoder().decode(ResidentMemorySnapshot.self, from: data)
        check(roundTrip == snapshot, "snapshot value type round-trips through Codable")
        if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sections = root["sections"] as? [String: Any],
           let facts = sections["facts"] as? [[String: Any]],
           let firstFact = facts.first {
            check(firstFact["observedAt"] == nil, "nil observedAt is omitted on encode (optional fields stay absent)")
            check(firstFact["grounding"] as? String == "turn:7", "present grounding survives encode")
        } else {
            check(false, "encoded snapshot JSON has expected shape")
        }
        let status = ResidentMemoryStatus(configured: ResidentMemoryConfigured(compaction: true, embedding: false),
                                          memory: nil, pendingTurns: 3, orchestration: nil)
        let statusData = try JSONEncoder().encode(status)
        check(try JSONDecoder().decode(ResidentMemoryStatus.self, from: statusData) == status,
              "status value type round-trips through Codable (memory nil encodes as absent/null)")
    }

    // MARK: - 12. memory_status 可选 orchestration：旧 fixture 缺省兼容 + 新字段解析
    do {
        // 旧 fixture 不带 orchestration 键：必须照常解码且 orchestration == nil。
        let status = try await ResidentMemoryClient(transport: StubTransport([statusJSON(pendingTurns: 3)]))
            .memoryStatus(scope: scope())
        check(status.orchestration == nil, "status without orchestration key decodes with orchestration nil (old fixture compatible)")
        check(status.pendingTurns == 3, "status fields unchanged when orchestration absent")
    }
    do {
        var response = statusJSON(pendingTurns: 2)
        response["orchestration"] = .object(["state": .string("running"), "lastError": .null])
        let status = try await ResidentMemoryClient(transport: StubTransport([response])).memoryStatus(scope: scope())
        check(status.orchestration == ResidentMemoryOrchestration(state: .running, lastError: nil),
              "status orchestration state decodes with explicit null lastError")
        check(status.pendingTurns == 2 && status.configured.embedding, "status keeps decoding with orchestration present")
    }
    do {
        var response = statusJSON(memory: statusMemoryJSON())
        response["orchestration"] = .object(["state": .string("failed"), "lastError": .string("consolidation_failed")])
        let status = try await ResidentMemoryClient(transport: StubTransport([response])).memoryStatus(scope: scope())
        check(status.orchestration?.state == .failed && status.orchestration?.lastError == "consolidation_failed",
              "status orchestration failed + lastError is visible (typed, not swallowed)")
    }
    do {
        var response = statusJSON()
        response["orchestration"] = .object(["state": .string("unconfigured")])
        let status = try await ResidentMemoryClient(transport: StubTransport([response])).memoryStatus(scope: scope())
        check(status.orchestration?.state == .unconfigured && status.orchestration?.lastError == nil,
              "status orchestration unconfigured is visible, lastError absent decodes nil")
    }
    do {
        var response = statusJSON()
        response["orchestration"] = .object(["lastError": .string("no-state")])
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryStatus(scope: scope())
        check(false, "orchestration without state must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "orchestration missing state is rejected")
    } catch {
        check(false, "orchestration missing state must throw invalidResponse (got \(error))")
    }
    do {
        var response = statusJSON()
        response["orchestration"] = .object(["state": .string("defragging")])
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryStatus(scope: scope())
        check(false, "orchestration with unknown state must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "orchestration unknown state is rejected")
    } catch {
        check(false, "orchestration unknown state must throw invalidResponse (got \(error))")
    }
    do {
        var response = statusJSON()
        response["orchestration"] = .object(["state": .string("idle"), "lastError": .number(5)])
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryStatus(scope: scope())
        check(false, "orchestration lastError of wrong type must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "orchestration lastError of wrong type is rejected")
    } catch {
        check(false, "orchestration lastError wrong type must throw invalidResponse (got \(error))")
    }
    do {
        var response = statusJSON()
        response["orchestration"] = .array([])
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryStatus(scope: scope())
        check(false, "orchestration of wrong shape must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "orchestration of wrong shape is rejected")
    } catch {
        check(false, "orchestration wrong shape must throw invalidResponse (got \(error))")
    }

    // MARK: - 13. memory_recall：请求形状 / 双路 hit 解析 / 严格错误
    do {
        let response: [String: ResidentStateJSON] = [
            "status": .string("ok"), "revision": .number(4), "vectorGeneration": .number(4),
            "facts": .array([
                hitJSON(section: "facts", id: "f-1", text: "喜欢爵士", distance: 0.1,
                        observedAt: .string("2026-09-08")),
                hitJSON(section: "facts", id: "f-2", text: "偏好安静", distance: 0.2),
            ]),
            "notes": .array([
                hitJSON(section: "notes", id: "n-1", text: "雨天提旧居会沉默", distance: 0.3,
                        observedAt: .string("2026-09-08")),
            ]),
            "context": .string("有界融合文本：喜欢爵士……"), "pendingTurns": .number(2),
        ]
        let recall = try await ResidentMemoryClient(transport: StubTransport([response]))
            .memoryRecall(scope: scope("w-1", "r-2"), query: "居民偏好", freshSession: true,
                          factLimit: 8, noteLimit: 3)
        let expected = ResidentMemoryRecallResult(
            status: .ok, revision: 4, vectorGeneration: 4,
            facts: [
                ResidentMemoryQueryHit(section: .facts, id: "f-1", text: "喜欢爵士",
                                       observedAt: "2026-09-08", distance: 0.1),
                ResidentMemoryQueryHit(section: .facts, id: "f-2", text: "偏好安静",
                                       observedAt: nil, distance: 0.2),
            ],
            notes: [
                ResidentMemoryQueryHit(section: .notes, id: "n-1", text: "雨天提旧居会沉默",
                                       observedAt: "2026-09-08", distance: 0.3),
            ],
            context: "有界融合文本：喜欢爵士……", pendingTurns: 2)
        check(recall == expected, "memory_recall decodes status/revision/vectorGeneration/facts/notes/context/pendingTurns")
    }
    do {
        let t = StubTransport([[
            "status": .string("empty"), "revision": .number(0), "vectorGeneration": .number(0),
            "facts": .array([]), "notes": .array([]), "context": .string(""), "pendingTurns": .number(0),
        ]])
        let recall = try await ResidentMemoryClient(transport: t).memoryRecall(scope: scope(), query: "q")
        check(recall.status == .empty && recall.context.isEmpty && recall.facts.isEmpty && recall.notes.isEmpty,
              "memory_recall empty status with empty context/arrays parses")
        check(t.recorded[0].params["freshSession"]?.boolValue == false,
              "memory_recall defaults freshSession to false on the wire")
    }
    do {
        // 默认 freshSession=false、factLimit=6、noteLimit=4；缺省逐字段发送。
        let t = StubTransport([[
            "status": .string("unconfigured"), "revision": .number(0), "vectorGeneration": .number(0),
            "facts": .array([]), "notes": .array([]),
            "context": .string("freshSession 恢复段仍可用"), "pendingTurns": .number(1),
        ]])
        let recall = try await ResidentMemoryClient(transport: t)
            .memoryRecall(scope: scope("w-9", "r-9"), query: "q", freshSession: true)
        check(recall.status == .unconfigured && recall.context == "freshSession 恢复段仍可用",
              "unconfigured recall still returns freshSession restore context (not treated as no-memory)")
        check(t.recorded[0].method == "memory_recall", "memory_recall wire method name")
        let params = t.recorded[0].params
        if let scopeValue = params["scope"], case let .object(scopeJSON) = scopeValue {
            check(scopeJSON["worldID"]?.stringValue == "w-9" && scopeJSON["residentScope"]?.stringValue == "r-9",
                  "memory_recall keeps both scope dimensions nested")
        } else {
            check(false, "memory_recall keeps nested scope")
        }
        check(params["query"]?.stringValue == "q", "memory_recall carries query")
        check(params["freshSession"]?.boolValue == true, "memory_recall carries explicit freshSession")
        check(params["factLimit"]?.doubleValue == 6 && params["noteLimit"]?.doubleValue == 4,
              "memory_recall default factLimit 6 / noteLimit 4")
    }
    do {
        // 显式 factLimit/noteLimit/freshSession=false 都被带上。
        let t = StubTransport([[
            "status": .string("ok"), "revision": .number(1), "vectorGeneration": .number(1),
            "facts": .array([]), "notes": .array([]), "context": .string("c"), "pendingTurns": .number(0),
        ]])
        _ = try await ResidentMemoryClient(transport: t)
            .memoryRecall(scope: scope(), query: "q", freshSession: false, factLimit: 12, noteLimit: 8)
        let params = t.recorded[0].params
        check(params["freshSession"]?.boolValue == false, "memory_recall carries freshSession false explicitly")
        check(params["factLimit"]?.doubleValue == 12 && params["noteLimit"]?.doubleValue == 8,
              "memory_recall carries explicit factLimit/noteLimit")
    }
    do {
        var response: [String: ResidentStateJSON] = [
            "status": .string("ok"), "revision": .number(1), "vectorGeneration": .number(1),
            "facts": .array([]), "notes": .array([]), "context": .string("c"), "pendingTurns": .number(0),
        ]
        response.removeValue(forKey: "status")
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryRecall(scope: scope(), query: "q")
        check(false, "memory_recall without status must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "memory_recall missing status is rejected")
    } catch {
        check(false, "memory_recall missing status must throw invalidResponse (got \(error))")
    }
    do {
        var response: [String: ResidentStateJSON] = [
            "status": .string("ok"), "revision": .number(1), "vectorGeneration": .number(1),
            "facts": .array([]), "notes": .array([]), "context": .string("c"), "pendingTurns": .number(0),
        ]
        response.removeValue(forKey: "context")
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryRecall(scope: scope(), query: "q")
        check(false, "memory_recall without context must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "memory_recall missing context is rejected")
    } catch {
        check(false, "memory_recall missing context must throw invalidResponse (got \(error))")
    }
    do {
        var response: [String: ResidentStateJSON] = [
            "status": .string("ok"), "revision": .number(1), "vectorGeneration": .number(1),
            "facts": .array([]), "notes": .array([]), "context": .string("c"), "pendingTurns": .number(0),
        ]
        response.removeValue(forKey: "pendingTurns")
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryRecall(scope: scope(), query: "q")
        check(false, "memory_recall without pendingTurns must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "memory_recall missing pendingTurns is rejected")
    } catch {
        check(false, "memory_recall missing pendingTurns must throw invalidResponse (got \(error))")
    }
    do {
        // facts 数组里出现 section=notes 的条目 = 归属段错位，畸形响应。
        let response: [String: ResidentStateJSON] = [
            "status": .string("ok"), "revision": .number(1), "vectorGeneration": .number(1),
            "facts": .array([hitJSON(section: "notes", id: "x", text: "错位", distance: 0.5)]),
            "notes": .array([]), "context": .string("c"), "pendingTurns": .number(0),
        ]
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryRecall(scope: scope(), query: "q")
        check(false, "memory_recall hit with wrong section inside facts must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "memory_recall facts[] entry must declare section=facts")
    } catch {
        check(false, "memory_recall wrong-section hit must throw invalidResponse (got \(error))")
    }
    do {
        var hit = hitJSON(section: "facts", id: "x", text: "缺距离", distance: 0.1).objectValue!
        hit.removeValue(forKey: "distance")
        let response: [String: ResidentStateJSON] = [
            "status": .string("ok"), "revision": .number(1), "vectorGeneration": .number(1),
            "facts": .array([.object(hit)]), "notes": .array([]),
            "context": .string("c"), "pendingTurns": .number(0),
        ]
        _ = try await ResidentMemoryClient(transport: StubTransport([response])).memoryRecall(scope: scope(), query: "q")
        check(false, "memory_recall hit missing distance must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "memory_recall hit missing distance is rejected")
    } catch {
        check(false, "memory_recall hit missing distance must throw invalidResponse (got \(error))")
    }
    // 请求形状错误/其它 daemon 错误原样透传。
    await expectDaemonCode("invalid_memory_recall", "memory_recall daemon error passes through") {
        let t = StubTransport([])
        t.thrownError = ResidentStateError.daemon("invalid_memory_recall")
        _ = try await ResidentMemoryClient(transport: t).memoryRecall(scope: scope(), query: "q")
    }

    // MARK: - 14. memory_ingest：请求形状 / accepted 语义 / 严格错误
    do {
        let response: [String: ResidentStateJSON] = [
            "accepted": .bool(true), "replayed": .bool(false),
            "pendingTurns": .number(4), "consolidation": .string("pending"),
        ]
        let result = try await ResidentMemoryClient(transport: StubTransport([response]))
            .memoryIngest(scope: scope("w-1", "r-2"), requestID: "uuid-1",
                          userText: "今天想听爵士", agentReply: "好的，来一首。",
                          source: .voice, observedAt: "2026-09-08T11:00:00+08:00")
        let expected = ResidentMemoryIngestResult(accepted: true, replayed: false,
                                                  pendingTurns: 4, consolidation: .pending)
        check(result == expected, "memory_ingest decodes accepted/replayed/pendingTurns/consolidation")
    }
    do {
        let t = StubTransport([[
            "accepted": .bool(true), "replayed": .bool(true),
            "pendingTurns": .number(7), "consolidation": .string("running"),
        ]])
        let result = try await ResidentMemoryClient(transport: t)
            .memoryIngest(scope: scope("w-5", "r-6"), requestID: "uuid-2",
                          userText: "u", agentReply: "a")
        check(result.replayed && result.consolidation == .running,
              "memory_ingest replay and running consolidation decode")
        check(t.recorded[0].method == "memory_ingest", "memory_ingest wire method name")
        let params = t.recorded[0].params
        if let scopeValue = params["scope"], case let .object(scopeJSON) = scopeValue {
            check(scopeJSON["worldID"]?.stringValue == "w-5" && scopeJSON["residentScope"]?.stringValue == "r-6",
                  "memory_ingest keeps both scope dimensions nested")
        } else {
            check(false, "memory_ingest keeps nested scope")
        }
        check(params["requestID"]?.stringValue == "uuid-2", "memory_ingest carries requestID")
        check(params["userText"]?.stringValue == "u" && params["agentReply"]?.stringValue == "a",
              "memory_ingest carries userText/agentReply")
        check(params["source"]?.stringValue == "text", "memory_ingest defaults source to text")
        check(params["observedAt"] == nil, "memory_ingest omits observedAt when not provided")
    }
    do {
        let t = StubTransport([[
            "accepted": .bool(true), "replayed": .bool(false),
            "pendingTurns": .number(1), "consolidation": .string("unconfigured"),
        ]])
        let result = try await ResidentMemoryClient(transport: t)
            .memoryIngest(scope: scope(), requestID: "uuid-3", userText: "u", agentReply: "a",
                          source: .voice)
        check(result.consolidation == .unconfigured,
              "memory_ingest accepted + consolidation unconfigured decodes (provider missing is visible)")
        check(t.recorded[0].params["source"]?.stringValue == "voice",
              "memory_ingest carries source voice when provided")
    }
    do {
        var response: [String: ResidentStateJSON] = [
            "accepted": .bool(true), "replayed": .bool(false),
            "pendingTurns": .number(1), "consolidation": .string("idle"),
        ]
        response["consolidation"] = .string("finished-forever")
        _ = try await ResidentMemoryClient(transport: StubTransport([response]))
            .memoryIngest(scope: scope(), requestID: "uuid-4", userText: "u", agentReply: "a")
        check(false, "memory_ingest unknown consolidation must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "memory_ingest unknown consolidation is rejected")
    } catch {
        check(false, "memory_ingest unknown consolidation must throw invalidResponse (got \(error))")
    }
    do {
        var response: [String: ResidentStateJSON] = [
            "accepted": .bool(true), "replayed": .bool(false),
            "pendingTurns": .number(1), "consolidation": .string("idle"),
        ]
        response.removeValue(forKey: "replayed")
        _ = try await ResidentMemoryClient(transport: StubTransport([response]))
            .memoryIngest(scope: scope(), requestID: "uuid-5", userText: "u", agentReply: "a")
        check(false, "memory_ingest without replayed must be rejected")
    } catch ResidentStateError.invalidResponse {
        check(true, "memory_ingest missing replayed is rejected")
    } catch {
        check(false, "memory_ingest missing replayed must throw invalidResponse (got \(error))")
    }
    await expectInvalid({
        _ = try await ResidentMemoryClient(transport: StubTransport([["accepted": .bool(false)]]))
            .memoryIngest(scope: scope(), requestID: "uuid-6", userText: "u", agentReply: "a")
    }, "memory_ingest accepted:false is rejected, never a silent success")
    await expectInvalid({
        _ = try await ResidentMemoryClient(transport: StubTransport([[:]]))
            .memoryIngest(scope: scope(), requestID: "uuid-7", userText: "u", agentReply: "a")
    }, "memory_ingest without accepted is rejected")
    await expectDaemonCode("invalid_memory_ingest", "memory_ingest daemon error passes through") {
        let t = StubTransport([])
        t.thrownError = ResidentStateError.daemon("invalid_memory_ingest")
        _ = try await ResidentMemoryClient(transport: t)
            .memoryIngest(scope: scope(), requestID: "uuid-8", userText: "u", agentReply: "a")
    }
    await expectDaemonCode("memory_request_conflict", "memory_ingest conflict passes through") {
        let t = StubTransport([])
        t.thrownError = ResidentStateError.daemon("memory_request_conflict")
        _ = try await ResidentMemoryClient(transport: t)
            .memoryIngest(scope: scope(), requestID: "uuid-9", userText: "不同内容", agentReply: "a")
    }

    // MARK: - 15. 新值类型 Codable 往返（nil 可选编码省略）
    do {
        let recall = ResidentMemoryRecallResult(
            status: .unconfigured, revision: 0, vectorGeneration: 0,
            facts: [ResidentMemoryQueryHit(section: .facts, id: "f", text: "t",
                                           observedAt: nil, distance: 0.0)],
            notes: [], context: "c", pendingTurns: 0)
        let data = try JSONEncoder().encode(recall)
        check(try JSONDecoder().decode(ResidentMemoryRecallResult.self, from: data) == recall,
              "memory_recall result value type round-trips through Codable")
        if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let facts = root["facts"] as? [[String: Any]], let first = facts.first {
            check(first["observedAt"] == nil, "recall hit nil observedAt is omitted on encode")
        } else {
            check(false, "encoded recall JSON has expected shape")
        }
        let ingest = ResidentMemoryIngestResult(accepted: true, replayed: false,
                                                pendingTurns: 2, consolidation: .pending)
        let ingestData = try JSONEncoder().encode(ingest)
        check(try JSONDecoder().decode(ResidentMemoryIngestResult.self, from: ingestData) == ingest,
              "memory_ingest result value type round-trips through Codable")
        let orchestration = ResidentMemoryOrchestration(state: .failed, lastError: "consolidation_failed")
        let orchData = try JSONEncoder().encode(orchestration)
        check(try JSONDecoder().decode(ResidentMemoryOrchestration.self, from: orchData) == orchestration,
              "orchestration value type round-trips through Codable")
    }

    print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident memory client checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

@main struct Tests {
    @MainActor static func main() async {
        do {
            try await run()
        } catch {
            failures += 1; checks += 1
            print("FAIL: unexpected error: \(error)")
            print("FAIL: \(checks) resident memory client checks, \(failures) failures")
            exit(1)
        }
    }
}
"""#

let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-swift-version", "6", "-j1", "-parse-as-library", "-warnings-as-errors",
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentMemoryClient.swift").path,
    main.path, "-o", binary.path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
exit(test.terminationStatus)
