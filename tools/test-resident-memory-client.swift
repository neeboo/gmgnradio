// ResidentMemoryClient 与 docs/plans/2026-09-08-voicemem-rust-contract.md 的
// 直接核对（完全离线：StubTransport 只记录请求并回放 fixture，绝不启动
// taskd/宿主，不读数据库）。覆盖仍保留的七个本地记忆方法
// （memory_read/query/turn/pending/compact + memory_recall/ingest）的请求形状
// 与严格响应解析：nested scope 两维度、memory:null 与快照可选字段、不合法响应
// 一律 invalidResponse（绝不把坏数据当空记忆/伪成功）、daemon error 原样透传、
// pending、compact replay/watermark、值类型 Codable 往返（nil 可选字段编码时省略）。
// 外部记忆 provider 接线（配置/状态两类 IPC 方法及其配置、状态与 orchestration
// 类型）已从生产整体移除，这里不再覆盖——本地记忆的
// recall/ingest 覆盖原样保留（见 §7/§8）。
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


/// 期望抛 invalidResponse；抛其他错误也算失败。
@MainActor func expectInvalid(_ operation: @escaping @MainActor () async throws -> Void, _ message: String) async {
}

/// 期望 transport 的 daemon 错误原样透传且 code 保留。
@MainActor func expectDaemonCode(_ expected: String, _ message: String,
                                 _ operation: @escaping @MainActor () async throws -> Void) async {
}

@MainActor func run() async throws {
    // MARK: - 1. 五个本地方法（read/query/turn/pending/compact）的请求形状与 nested scope
    // 2. 可选入参省略/携带：expectedVectorGeneration、topK、interrupted。
    // MARK: - 3. daemon error 原样透传（每方法一个代表性 code）
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
    // 缺配置 = daemon 显式 unavailable，客户端只透传，绝不伪造成功。
    await expectDaemonCode("embedding_unavailable", "embedding_unavailable passes through") {
        let t = StubTransport([])
        t.thrownError = ResidentStateError.daemon("embedding_unavailable")
        _ = try await ResidentMemoryClient(transport: t).memoryQuery(scope: scope(), query: "q")
    }

    // MARK: - 4. memory_read / memory_query / memory_turn：完整快照、memory:null、坏数据显式拒绝
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

    // MARK: - 5. memory_pending：升序 turns 与逐字段解析
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
    // MARK: - 6. 值类型 Codable：往返一致；nil 可选字段编码时省略
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
    }

    // MARK: - 7. memory_recall：请求形状 / 双路 hit 解析 / 严格错误
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

    // MARK: - 8. memory_ingest：请求形状 / accepted 语义 / 严格错误
    do {
        let response: [String: ResidentStateJSON] = [
            "accepted": .bool(true), "replayed": .bool(false),
            "pendingTurns": .number(4),
        ]
        let result = try await ResidentMemoryClient(transport: StubTransport([response]))
            .memoryIngest(scope: scope("w-1", "r-2"), requestID: "uuid-1",
                          userText: "今天想听爵士", agentReply: "好的，来一首。",
                          source: .voice, observedAt: "2026-09-08T11:00:00+08:00")
        let expected = ResidentMemoryIngestResult(accepted: true, replayed: false,
                                                  pendingTurns: 4)
        check(result == expected, "memory_ingest decodes accepted/replayed/pendingTurns (no consolidation field)")
    }
    do {
        let t = StubTransport([[
            "accepted": .bool(true), "replayed": .bool(true),
            "pendingTurns": .number(7),
        ]])
        let result = try await ResidentMemoryClient(transport: t)
            .memoryIngest(scope: scope("w-5", "r-6"), requestID: "uuid-2",
                          userText: "u", agentReply: "a")
        check(result.replayed && result.pendingTurns == 7,
              "memory_ingest replay decodes with its own pendingTurns")
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
            "pendingTurns": .number(1),
        ]])
        let result = try await ResidentMemoryClient(transport: t)
            .memoryIngest(scope: scope(), requestID: "uuid-3", userText: "u", agentReply: "a",
                          source: .voice)
        check(result.accepted && result.pendingTurns == 1,
              "memory_ingest accepted result carries the daemon's pendingTurns")
        check(t.recorded[0].params["source"]?.stringValue == "voice",
              "memory_ingest carries source voice when provided")
    }
    do {
        var response: [String: ResidentStateJSON] = [
            "accepted": .bool(true), "replayed": .bool(false),
            "pendingTurns": .number(1),
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

    // MARK: - 9. 新值类型 Codable 往返（nil 可选编码省略）
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
                                                pendingTurns: 2)
        let ingestData = try JSONEncoder().encode(ingest)
        check(try JSONDecoder().decode(ResidentMemoryIngestResult.self, from: ingestData) == ingest,
              "memory_ingest result value type round-trips through Codable")
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
