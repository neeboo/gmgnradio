import Foundation

// MARK: - 值类型

/// `memory_configure` 的 provider 类别（合同 §3.1）。压缩与嵌入彼此独立配置：
/// 缺失其一就显式 unavailable，绝不静默降级。
enum ResidentMemoryProviderKind: String, Codable, Sendable {
    case compaction
    case embedding
}

/// `memory_turn` / `memory_pending` 的发言方（合同 §2.3/§3.5）。只接受
/// user/agent；CC 侧保证只投喂真实用户文字与已成功送达的回复。
enum ResidentMemoryRole: String, Codable, Sendable {
    case user
    case agent
}

/// 快照条目类别（合同 §2.1）：facts 段 ∈ fact|preference；notes 段 ∈
/// relationship|experience。读取侧解析遇到白名单外的类别即畸形响应。
enum ResidentMemoryCategory: String, Codable, Sendable {
    case fact
    case preference
    case relationship
    case experience
}

/// `memory_query` 结果条目的归属段（合同 §3.4）。
enum ResidentMemorySection: String, Codable, Sendable {
    case facts
    case notes
}

/// `memory_query` 的三态结果（合同 §3.4，编排合同增补的 memory_recall 复用
/// 同一组 status）。`unconfigured`/`empty` 时 CC 一律不注入记忆即可，不回退词法
/// 哈希。
enum ResidentMemoryQueryStatus: String, Codable, Sendable {
    case ok
    case empty
    case unconfigured
}

/// 快照/状态摘要里的向量元数据（合同 §2.1 `embedding` 子对象）。
/// `model`/`dimensions` 以 provider 首次响应为准并落库；后续批次不一致时
/// daemon 报 `embedding_dimension_mismatch`，客户端原样透传。
struct ResidentMemoryEmbedding: Equatable, Sendable, Codable {
    let model: String
    let dimensions: UInt64
}

/// 一条事实或笔记（合同 §2.1 sections 条目）。
///
/// `observedAt`/`grounding` 可选：缺省时 daemon 在 JSON 里省略该字段（编码端
/// 合成 Codable 同样省略 nil 可选字段）；显式 null 与缺省等价。notes 段的
/// grounding 必填是 daemon 写侧确定性校验（`compaction_rejected`），读取侧
/// 按可选字段宽容解码，不重复写侧语义。
struct ResidentMemoryEntry: Equatable, Sendable, Codable {
    let id: String
    let category: ResidentMemoryCategory
    let text: String
    let observedAt: String?
    let grounding: String?
}

/// 快照双段（合同 §2.1 `sections`）。两段都是数组；facts 只收长期成立内容，
/// notes 是画像/关系/经验内部笔记。
struct ResidentMemorySections: Equatable, Sendable, Codable {
    let facts: [ResidentMemoryEntry]
    let notes: [ResidentMemoryEntry]
}

/// 完整记忆快照（合同 §2.1，`memory_read` 回复全文）。`schemaVersion` 恒为 1
/// （本冻结版本）；`revision` 是成功提交计数；`vectorGeneration` 单调自增，
/// 快照与向量同代；`processedWatermark`/`nextWatermark` 是 turn 水位。
struct ResidentMemorySnapshot: Equatable, Sendable, Codable {
    let schemaVersion: UInt64
    let revision: UInt64
    let vectorGeneration: UInt64
    let processedWatermark: UInt64
    let nextWatermark: UInt64
    let embedding: ResidentMemoryEmbedding
    let sections: ResidentMemorySections
}

/// `memory_status` 的 `configured` 摘要（合同 §3.2）。
struct ResidentMemoryConfigured: Equatable, Sendable, Codable {
    let compaction: Bool
    let embedding: Bool
}

/// `memory_status` 摘要里的条目计数（合同 §3.2 `entryCounts`）。
struct ResidentMemoryCounts: Equatable, Sendable, Codable {
    let facts: UInt64
    let notes: UInt64
}

/// `memory_status` 摘要里的快照元数据（无 sections，用 entryCounts 概览）。
struct ResidentMemoryStatusMemory: Equatable, Sendable, Codable {
    let schemaVersion: UInt64
    let revision: UInt64
    let vectorGeneration: UInt64
    let processedWatermark: UInt64
    let nextWatermark: UInt64
    let embedding: ResidentMemoryEmbedding
    let entryCounts: ResidentMemoryCounts
}

/// `memory_status` 的可选 `orchestration` 附加字段（编排合同增补）：Rust 后台
/// 整理的状态概览。旧 daemon/旧 fixture 缺省该键或显式 null → nil（向后兼容，
/// 旧客户端本就忽略附加字段）；`lastError` 是稳定错误码或 null，不含敏感详情。
struct ResidentMemoryOrchestration: Equatable, Sendable, Codable {
    let state: ResidentMemoryConsolidation
    let lastError: String?
}

/// `memory_status` 回复（合同 §3.2）。`memory:null` 表示该 scope 尚无快照
/// （不是错误）；`pendingTurns` 独立于快照存在；`orchestration` 是编排合同
/// 增补的可选字段，缺省/显式 null → nil，不破坏旧响应解析。
struct ResidentMemoryStatus: Equatable, Sendable, Codable {
    let configured: ResidentMemoryConfigured
    let memory: ResidentMemoryStatusMemory?
    let pendingTurns: UInt64
    let orchestration: ResidentMemoryOrchestration?
}

/// `memory_pending` 里的一条易失 turn（合同 §3.6）。只用于拼「本会话尚未入库」
/// 的即时上下文，禁止缓存为长期记忆。
struct ResidentMemoryPendingTurn: Equatable, Sendable, Codable {
    let turnID: String
    let watermark: UInt64
    let role: ResidentMemoryRole
    let text: String
    let interrupted: Bool
}

/// `memory_turn` 回复（合同 §3.5）。`accepted` 恒为 true；daemon 侧校验失败
/// 走错误码，不会返回 accepted:false。
struct ResidentMemoryTurnResult: Equatable, Sendable, Codable {
    let accepted: Bool
    let turnID: String
    let watermark: UInt64
    let pendingTurns: UInt64
}

/// `memory_query` 的一条命中（合同 §3.4）。`distance` 为 cosine 距离（升序），
/// 只含拼 prompt 用的 text/id 类数据，不作为工具指令。
struct ResidentMemoryQueryHit: Equatable, Sendable, Codable {
    let section: ResidentMemorySection
    let id: String
    let text: String
    let observedAt: String?
    let distance: Double
}

/// `memory_query` 回复（合同 §3.4）。非 `ok` 状态下冻结为 `results: []`。
struct ResidentMemoryQueryResult: Equatable, Sendable, Codable {
    let status: ResidentMemoryQueryStatus
    let results: [ResidentMemoryQueryHit]
}

/// `memory_compact` 回复（合同 §3.7）。`replayed:true` 表示同一
/// `(scope, requestID)` 幂等回放，未重复压缩、未推进 revision。
struct ResidentMemoryCompactResult: Equatable, Sendable, Codable {
    let revision: UInt64
    let vectorGeneration: UInt64
    let replayed: Bool
    let processedWatermark: UInt64
    let pendingTurns: UInt64
}

/// 发言来源（编排合同增补 `memory_ingest`）：`voice` 表示真实语音转写来源，
/// 只证明来源是语音，不代表完成了声纹/情绪识别；缺省 `text`。
enum ResidentMemorySource: String, Codable, Sendable {
    case text
    case voice
}

/// 后台整理/编排状态（编排合同增补）：`memory_ingest` 回复的 `consolidation`
/// 与 `memory_status` 的 `orchestration.state` 共用同一组取值。`pending` 表示
/// 已交付回合进入易失缓冲、等待后台整理；`running` 表示整理进行中；
/// `failed`/`unconfigured` 表示失败/缺 provider 但内容仍在易失缓冲。读取侧
/// 遇到白名单外的取值即畸形响应。
enum ResidentMemoryConsolidation: String, Codable, Sendable {
    case idle
    case pending
    case running
    case unconfigured
    case failed
}

/// `memory_recall` 回复（编排合同增补）：Rust 已按双路配额检索、去重并做有界
/// 融合，Swift 不做任何双路排序或二次融合。`facts`/`notes` 数组使用旧
/// memory_query hit 形状（数组内元素 section 分别恒为 facts/notes）；
/// `context` 是融合后的有界纯文本（Rust 限 ≤8000 字符），Swift 只解码并把它
/// 当数据使用。status=ok/empty/unconfigured；无快照时 revision/
/// vectorGeneration 为 0。
struct ResidentMemoryRecallResult: Equatable, Sendable, Codable {
    let status: ResidentMemoryQueryStatus
    let revision: UInt64
    let vectorGeneration: UInt64
    let facts: [ResidentMemoryQueryHit]
    let notes: [ResidentMemoryQueryHit]
    let context: String
    let pendingTurns: UInt64
}

/// `memory_ingest` 回复（编排合同增补）：`accepted:true` 只代表已交付回合成对
/// 进入该 scope 的易失缓冲，**绝不代表 durable 落库**——落库由 Rust 后台整理
/// 完成，客户端不得冒充长期保存。`replayed:true` 表示同一 `(scope, requestID)`
/// 幂等回放，未重复入队；缺 provider 时仍 accepted=true 且
/// consolidation=unconfigured，内容保留在易失缓冲。
struct ResidentMemoryIngestResult: Equatable, Sendable, Codable {
    let accepted: Bool
    let replayed: Bool
    let pendingTurns: UInt64
    let consolidation: ResidentMemoryConsolidation
}

// MARK: - 客户端

/// gmgn-taskd VoiceMem 记忆方法的类型化 Swift 客户端。
///
/// 合同（docs/plans/2026-09-08-voicemem-rust-contract.md，冻结 + 编排合同
/// docs/plans/2026-09-08-voicemem-rust-orchestration.md 增补 memory_recall/
/// memory_ingest 与 memory_status 可选 orchestration 字段）只在本文件实现；
/// scope 一律复用 `ResidentStateScope` 内嵌对象（两个维度都参与隔离）；
/// revision / vectorGeneration / processedWatermark / nextWatermark / facts /
/// notes / 可选 grounding·observedAt 均保留为类型化字段。
///
/// 错误语义：transport 抛出的 daemon `error.code` 原样透传（复用
/// `ResidentStateError.daemon`）；本客户端只负责把回复严格解码——只有显式
/// `memory:null` 才算"无记忆"，缺字段/坏类型/坏枚举一律抛
/// `ResidentStateError.invalidResponse`，绝不把坏数据填成空记忆伪成功。
///
/// 凭据卫生：`memoryConfigure` 的 token 只作为请求参数转发，不落任何属性、
/// 不写盘、不打日志（daemon 侧同样不落盘/不进日志，重启需重配）。
@MainActor
final class ResidentMemoryClient {
    private let transport: ResidentStateTransport

    init(transport: ResidentStateTransport) {
        self.transport = transport
    }

    private func scopeParams(_ scope: ResidentStateScope) -> [String: ResidentStateJSON] {
        ["scope": scope.nestedParam]
    }

    // MARK: - 七个冻结方法

    /// `memory_configure`（合同 §3.1）：配置压缩/嵌入 provider，daemon 内存
    /// 保存、永不落盘。结果恒为 `{"configured": true}`；不是 true 即畸形响应。
    func memoryConfigure(kind: ResidentMemoryProviderKind, endpoint: String,
                         token: String, model: String? = nil) async throws {
        var params: [String: ResidentStateJSON] = [
            "kind": .string(kind.rawValue),
            "endpoint": .string(endpoint),
            "token": .string(token),
        ]
        if let model { params["model"] = .string(model) }
        let response = try await transport.call(method: "memory_configure", params: params)
        guard response["configured"]?.boolValue == true else { throw ResidentStateError.invalidResponse }
    }

    /// `memory_status`（合同 §3.2）：只读、无副作用。`memory:null` → nil。
    func memoryStatus(scope: ResidentStateScope) async throws -> ResidentMemoryStatus {
        let response = try await transport.call(method: "memory_status", params: scopeParams(scope))
        let configured = try requireObject(response["configured"])
        let compaction = try requireBool(configured["compaction"])
        let embedding = try requireBool(configured["embedding"])
        // memory 键缺失即畸形；显式 null 才是"该 scope 尚无快照"。
        guard let memoryValue = response["memory"] else { throw ResidentStateError.invalidResponse }
        let memory: ResidentMemoryStatusMemory?
        if case .null = memoryValue {
            memory = nil
        } else {
            memory = try decodeStatusMemory(memoryValue)
        }
        let pendingTurns = try strictUInt64(response["pendingTurns"])
        // orchestration 是编排合同增补的可选字段：缺省（旧 daemon/fixture）或
        // 显式 null → nil；出现但形状错误 → 畸形响应。
        var orchestration: ResidentMemoryOrchestration?
        if let orchestrationValue = response["orchestration"] {
            if case .null = orchestrationValue {
                orchestration = nil
            } else {
                orchestration = try decodeOrchestration(orchestrationValue)
            }
        }
        return ResidentMemoryStatus(configured: ResidentMemoryConfigured(
            compaction: compaction, embedding: embedding), memory: memory,
            pendingTurns: pendingTurns, orchestration: orchestration)
    }

    /// `memory_read`（合同 §3.3）：返回当前唯一一版快照全文（含 sections）。
    /// 显式 `memory:null` → nil；快照对象无法解码 → 显式错误，不是"空记忆"。
    func memoryRead(scope: ResidentStateScope) async throws -> ResidentMemorySnapshot? {
        let response = try await transport.call(method: "memory_read", params: scopeParams(scope))
        guard let memoryValue = response["memory"] else { throw ResidentStateError.invalidResponse }
        if case .null = memoryValue { return nil }
        return try decodeSnapshot(memoryValue)
    }

    /// `memory_query`（合同 §3.4）：本 scope、当前代向量 cosine 升序检索。
    /// `topK` 1—20（daemon 默认 8，越界报 `invalid_topk`）。
    func memoryQuery(scope: ResidentStateScope, query: String,
                     topK: Int = 8) async throws -> ResidentMemoryQueryResult {
        var params = scopeParams(scope)
        params["query"] = .string(query)
        params["topK"] = .number(Double(topK))
        let response = try await transport.call(method: "memory_query", params: params)
        guard let statusRaw = response["status"]?.stringValue,
              let status = ResidentMemoryQueryStatus(rawValue: statusRaw) else {
            throw ResidentStateError.invalidResponse
        }
        guard case let .array(items) = response["results"] else { throw ResidentStateError.invalidResponse }
        // §3.4：empty/unconfigured 冻结为 results:[]；带命中即畸形响应。
        guard status == .ok || items.isEmpty else { throw ResidentStateError.invalidResponse }
        let results = try items.map(decodeQueryHit)
        return ResidentMemoryQueryResult(status: status, results: results)
    }

    /// `memory_turn`（合同 §3.5）：把真实用户文字/已送达回复追加进 scope 的
    /// 易失 pending 缓冲。`interrupted` 只作渲染标记（默认 false，显式携带）。
    func memoryTurn(scope: ResidentStateScope, role: ResidentMemoryRole, text: String,
                    interrupted: Bool = false) async throws -> ResidentMemoryTurnResult {
        var params = scopeParams(scope)
        params["role"] = .string(role.rawValue)
        params["text"] = .string(text)
        params["interrupted"] = .bool(interrupted)
        let response = try await transport.call(method: "memory_turn", params: params)
        guard response["accepted"]?.boolValue == true else { throw ResidentStateError.invalidResponse }
        let turnID = try requireString(response["turnID"])
        let watermark = try strictUInt64(response["watermark"])
        let pendingTurns = try strictUInt64(response["pendingTurns"])
        return ResidentMemoryTurnResult(accepted: true, turnID: turnID,
                                        watermark: watermark, pendingTurns: pendingTurns)
    }

    /// `memory_pending`（合同 §3.6）：按 watermark 升序返回该 scope 的易失
    /// pending turns（daemon 排序，客户端不重排）。只作即时上下文，不代表已持久。
    func memoryPending(scope: ResidentStateScope) async throws -> [ResidentMemoryPendingTurn] {
        let response = try await transport.call(method: "memory_pending", params: scopeParams(scope))
        guard case let .array(items) = response["turns"] else { throw ResidentStateError.invalidResponse }
        return try items.map(decodePendingTurn)
    }

    /// `memory_compact`（合同 §3.7）：语义压缩 + 向量化的持久提交点。可能耗时，
    /// CC 不得放在延迟敏感回复路径内同步调用。`requestID` 幂等；提供
    /// `expectedVectorGeneration` 则必须等于当前代，否则 `memory_conflict`。
    func memoryCompact(scope: ResidentStateScope, requestID: String,
                       expectedVectorGeneration: UInt64? = nil) async throws -> ResidentMemoryCompactResult {
        var params = scopeParams(scope)
        params["requestID"] = .string(requestID)
        if let expectedVectorGeneration {
            params["expectedVectorGeneration"] = .number(Double(expectedVectorGeneration))
        }
        let response = try await transport.call(method: "memory_compact", params: params)
        let revision = try strictUInt64(response["revision"])
        let vectorGeneration = try strictUInt64(response["vectorGeneration"])
        let replayed = try requireBool(response["replayed"])
        let processedWatermark = try strictUInt64(response["processedWatermark"])
        let pendingTurns = try strictUInt64(response["pendingTurns"])
        return ResidentMemoryCompactResult(revision: revision, vectorGeneration: vectorGeneration,
                                           replayed: replayed, processedWatermark: processedWatermark,
                                           pendingTurns: pendingTurns)
    }

    // MARK: - 双路检索与交付写入（编排合同增补）

    /// `memory_recall`（编排合同增补）：一次 embedding、双路检索与 Rust 有界
    /// 融合。`freshSession` 由调用方显式决定（全新会话 true / 原生续聊 false），
    /// 缺省 false；factLimit/noteLimit 缺省 6/4。本方法只严格解码——facts/notes
    /// 逐条校验旧 hit 形状与归属段、status/revision/context/pendingTurns 齐全；
    /// Swift 不做双路排序或二次融合。
    func memoryRecall(scope: ResidentStateScope, query: String, freshSession: Bool = false,
                      factLimit: Int = 6, noteLimit: Int = 4) async throws -> ResidentMemoryRecallResult {
        var params = scopeParams(scope)
        params["query"] = .string(query)
        params["freshSession"] = .bool(freshSession)
        params["factLimit"] = .number(Double(factLimit))
        params["noteLimit"] = .number(Double(noteLimit))
        let response = try await transport.call(method: "memory_recall", params: params)
        guard let statusRaw = response["status"]?.stringValue,
              let status = ResidentMemoryQueryStatus(rawValue: statusRaw) else {
            throw ResidentStateError.invalidResponse
        }
        let revision = try strictUInt64(response["revision"])
        let vectorGeneration = try strictUInt64(response["vectorGeneration"])
        guard case let .array(factValues) = response["facts"] else { throw ResidentStateError.invalidResponse }
        guard case let .array(noteValues) = response["notes"] else { throw ResidentStateError.invalidResponse }
        let facts = try factValues.map { try decodeRecallHit($0, expectedSection: .facts) }
        let notes = try noteValues.map { try decodeRecallHit($0, expectedSection: .notes) }
        let context = try requireString(response["context"])
        let pendingTurns = try strictUInt64(response["pendingTurns"])
        return ResidentMemoryRecallResult(status: status, revision: revision,
                                          vectorGeneration: vectorGeneration, facts: facts,
                                          notes: notes, context: context, pendingTurns: pendingTurns)
    }

    /// `memory_ingest`（编排合同增补）：只接受调用方确认真实交付的成对
    /// userText/agentReply（宿主 prompt、工具结果、图片、被打断/未播完的回复
    /// 不得传入）。requestID 幂等；source=text/voice（缺省 text）；observedAt
    /// 可选、≤32 字符。返回 accepted 只代表进入易失缓冲，不是 durable 落库。
    func memoryIngest(scope: ResidentStateScope, requestID: String, userText: String,
                      agentReply: String, source: ResidentMemorySource = .text,
                      observedAt: String? = nil) async throws -> ResidentMemoryIngestResult {
        var params = scopeParams(scope)
        params["requestID"] = .string(requestID)
        params["userText"] = .string(userText)
        params["agentReply"] = .string(agentReply)
        params["source"] = .string(source.rawValue)
        if let observedAt { params["observedAt"] = .string(observedAt) }
        let response = try await transport.call(method: "memory_ingest", params: params)
        guard response["accepted"]?.boolValue == true else { throw ResidentStateError.invalidResponse }
        let replayed = try requireBool(response["replayed"])
        let pendingTurns = try strictUInt64(response["pendingTurns"])
        guard let consolidationRaw = response["consolidation"]?.stringValue,
              let consolidation = ResidentMemoryConsolidation(rawValue: consolidationRaw) else {
            throw ResidentStateError.invalidResponse
        }
        return ResidentMemoryIngestResult(accepted: true, replayed: replayed,
                                          pendingTurns: pendingTurns, consolidation: consolidation)
    }

    // MARK: - 严格解码助手

    private func requireObject(_ value: ResidentStateJSON?) throws -> [String: ResidentStateJSON] {
        guard case let .object(object) = value else { throw ResidentStateError.invalidResponse }
        return object
    }

    /// 只接受"非负整数 JSON 数值"（同 ResidentStateClient.strictUInt64：用
    /// UInt64(exactly:) 避免 Double 舍入后 trap）。
    private func strictUInt64(_ value: ResidentStateJSON?) throws -> UInt64 {
        guard case let .number(number) = value ?? .null, number.isFinite,
              number.rounded(.down) == number, number >= 0,
              let integer = UInt64(exactly: number) else {
            throw ResidentStateError.invalidResponse
        }
        return integer
    }

    private func requireString(_ value: ResidentStateJSON?) throws -> String {
        guard case let .string(string) = value else { throw ResidentStateError.invalidResponse }
        return string
    }

    private func requireBool(_ value: ResidentStateJSON?) throws -> Bool {
        guard case let .bool(bool) = value else { throw ResidentStateError.invalidResponse }
        return bool
    }

    /// 可选字符串：字段缺省或显式 null → nil；出现但非字符串 → 畸形。
    private func optionalString(_ value: ResidentStateJSON?) throws -> String? {
        guard let value else { return nil }
        if case .null = value { return nil }
        guard case let .string(string) = value else { throw ResidentStateError.invalidResponse }
        return string
    }

    private func decodeSnapshot(_ value: ResidentStateJSON) throws -> ResidentMemorySnapshot {
        let object = try requireObject(value)
        let schemaVersion = try strictUInt64(object["schemaVersion"])
        let revision = try strictUInt64(object["revision"])
        let vectorGeneration = try strictUInt64(object["vectorGeneration"])
        let processedWatermark = try strictUInt64(object["processedWatermark"])
        let nextWatermark = try strictUInt64(object["nextWatermark"])
        let embedding = try decodeEmbedding(object["embedding"])
        let sections = try decodeSections(object["sections"])
        return ResidentMemorySnapshot(schemaVersion: schemaVersion, revision: revision,
                                      vectorGeneration: vectorGeneration,
                                      processedWatermark: processedWatermark,
                                      nextWatermark: nextWatermark, embedding: embedding,
                                      sections: sections)
    }

    private func decodeEmbedding(_ value: ResidentStateJSON?) throws -> ResidentMemoryEmbedding {
        let object = try requireObject(value)
        let model = try requireString(object["model"])
        let dimensions = try strictUInt64(object["dimensions"])
        return ResidentMemoryEmbedding(model: model, dimensions: dimensions)
    }

    private func decodeSections(_ value: ResidentStateJSON?) throws -> ResidentMemorySections {
        let object = try requireObject(value)
        let facts = try decodeEntries(object["facts"])
        let notes = try decodeEntries(object["notes"])
        return ResidentMemorySections(facts: facts, notes: notes)
    }

    private func decodeEntries(_ value: ResidentStateJSON?) throws -> [ResidentMemoryEntry] {
        guard case let .array(items) = value else { throw ResidentStateError.invalidResponse }
        return try items.map(decodeEntry)
    }

    private func decodeEntry(_ value: ResidentStateJSON) throws -> ResidentMemoryEntry {
        let object = try requireObject(value)
        let id = try requireString(object["id"])
        let categoryRaw = try requireString(object["category"])
        guard let category = ResidentMemoryCategory(rawValue: categoryRaw) else {
            throw ResidentStateError.invalidResponse
        }
        let text = try requireString(object["text"])
        let observedAt = try optionalString(object["observedAt"])
        let grounding = try optionalString(object["grounding"])
        return ResidentMemoryEntry(id: id, category: category, text: text,
                                   observedAt: observedAt, grounding: grounding)
    }

    private func decodeStatusMemory(_ value: ResidentStateJSON) throws -> ResidentMemoryStatusMemory {
        let object = try requireObject(value)
        let schemaVersion = try strictUInt64(object["schemaVersion"])
        let revision = try strictUInt64(object["revision"])
        let vectorGeneration = try strictUInt64(object["vectorGeneration"])
        let processedWatermark = try strictUInt64(object["processedWatermark"])
        let nextWatermark = try strictUInt64(object["nextWatermark"])
        let embedding = try decodeEmbedding(object["embedding"])
        let countsObject = try requireObject(object["entryCounts"])
        let facts = try strictUInt64(countsObject["facts"])
        let notes = try strictUInt64(countsObject["notes"])
        return ResidentMemoryStatusMemory(schemaVersion: schemaVersion, revision: revision,
                                          vectorGeneration: vectorGeneration,
                                          processedWatermark: processedWatermark,
                                          nextWatermark: nextWatermark, embedding: embedding,
                                          entryCounts: ResidentMemoryCounts(facts: facts, notes: notes))
    }

    private func decodePendingTurn(_ value: ResidentStateJSON) throws -> ResidentMemoryPendingTurn {
        let object = try requireObject(value)
        let turnID = try requireString(object["turnID"])
        let watermark = try strictUInt64(object["watermark"])
        let roleRaw = try requireString(object["role"])
        guard let role = ResidentMemoryRole(rawValue: roleRaw) else { throw ResidentStateError.invalidResponse }
        let text = try requireString(object["text"])
        let interrupted = try requireBool(object["interrupted"])
        return ResidentMemoryPendingTurn(turnID: turnID, watermark: watermark, role: role,
                                         text: text, interrupted: interrupted)
    }

    private func decodeQueryHit(_ value: ResidentStateJSON) throws -> ResidentMemoryQueryHit {
        let object = try requireObject(value)
        let sectionRaw = try requireString(object["section"])
        guard let section = ResidentMemorySection(rawValue: sectionRaw) else {
            throw ResidentStateError.invalidResponse
        }
        let id = try requireString(object["id"])
        let text = try requireString(object["text"])
        let observedAt = try optionalString(object["observedAt"])
        guard case let .number(distance) = object["distance"] else { throw ResidentStateError.invalidResponse }
        return ResidentMemoryQueryHit(section: section, id: id, text: text,
                                      observedAt: observedAt, distance: distance)
    }

    /// memory_recall 的 facts/notes 条目：复用旧 memory_query hit 形状，并额外
    /// 校验条目归属段必须与所在数组一致（facts 数组内 section=facts、notes
    /// 数组内 section=notes），不一致即畸形响应。
    private func decodeRecallHit(_ value: ResidentStateJSON,
                                 expectedSection: ResidentMemorySection) throws -> ResidentMemoryQueryHit {
        let hit = try decodeQueryHit(value)
        guard hit.section == expectedSection else { throw ResidentStateError.invalidResponse }
        return hit
    }

    /// memory_status 的可选 orchestration 对象（编排合同增补）：state 必须落在
    /// 编排状态白名单，lastError 为可选字符串（缺省/显式 null → nil，其它类型
    /// 畸形）。
    private func decodeOrchestration(_ value: ResidentStateJSON) throws -> ResidentMemoryOrchestration {
        let object = try requireObject(value)
        guard let stateRaw = object["state"]?.stringValue,
              let state = ResidentMemoryConsolidation(rawValue: stateRaw) else {
            throw ResidentStateError.invalidResponse
        }
        let lastError = try optionalString(object["lastError"])
        return ResidentMemoryOrchestration(state: state, lastError: lastError)
    }
}
