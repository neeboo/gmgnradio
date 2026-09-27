import Foundation

/// 统一状态合同的 JSON 值树（数据，不是可执行指令）。
enum ResidentStateJSON: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: ResidentStateJSON]), array([ResidentStateJSON]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: ResidentStateJSON].self) { self = .object(v) }
        else { self = .array(try value.decode([ResidentStateJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
}

/// gmgn-taskd 统一状态合同的类型化 Swift 客户端。
/// 合同（docs/plans/2026-09-08-resident-storage-contract.md，冻结）：
/// scope={worldID,residentScope} 一律内嵌对象；revision 是成功提交的计数；
/// event_read / message_read 只有 scope / after / limit（message 另有 consumer），
/// 没有 base64 cursor；nextCursor 恒为非负整数水位——本页有数据 = 本页最后一条
/// sequence，无数据 = 本次入参 after。daemon 拒绝时以 error.code 原样透传。
///
/// 解析规则：record:null 才是"无记录"；record 缺字段、event/message item 缺
/// sequence/id/kind/payload、nextCursor 缺失或非整数、message_ack 未回
/// acknowledged=true 都是畸形响应，一律抛 invalidResponse——绝不填 null/空值
/// 制造伪成功。
@MainActor
protocol ResidentStateTransport: AnyObject, Sendable {
    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON]
}

enum ResidentStateDomain: String, Sendable {
    case resident, world, wish, inbox, conversation
}

struct ResidentStateScope: Hashable, Codable, Sendable {
    let worldID: String
    let residentScope: String

    /// 合同：scope 是统一内嵌对象，不是顶层平铺字段。
    var nestedParam: ResidentStateJSON {
        .object(["worldID": .string(worldID), "residentScope": .string(residentScope)])
    }
}

struct ResidentStateFact: Equatable, Sendable {
    let id: String
    let kind: String
    let payload: [String: ResidentStateJSON]

    var object: [String: ResidentStateJSON] {
        ["id": .string(id), "kind": .string(kind), "payload": .object(payload)]
    }
}

struct ResidentStateCommittedFact: Equatable, Sendable {
    let sequence: UInt64
    let id: String
    let kind: String
    let payload: [String: ResidentStateJSON]
}

enum ResidentStateError: LocalizedError, Equatable {
    case daemon(String)
    case invalidResponse
    /// 已落库的居民快照无法解码（旧格式或损坏）——读取侧可见失败，不注入状态。
    case unreadableArchive

    var errorDescription: String? {
        switch self {
        case let .daemon(code): "统一状态后台拒绝了请求（\(code)）。"
        case .invalidResponse: "统一状态后台返回了无法识别的数据。"
        case .unreadableArchive: "已保存的居民快照无法解码（可能是旧格式或已损坏）；未注入任何状态。"
        }
    }
}

@MainActor
final class ResidentStateClient {
    private let transport: ResidentStateTransport

    init(transport: ResidentStateTransport) {
        self.transport = transport
    }

    private func scopeParams(_ scope: ResidentStateScope) -> [String: ResidentStateJSON] {
        ["scope": scope.nestedParam]
    }

    /// 仅接受"非负整数 JSON 数值"。用 UInt64(exactly:) 转换，避免
    /// Double(UInt64.max)（= 2^64）之类舍入后 UInt64(...) 直接 trap。
    func strictUInt64(_ value: ResidentStateJSON?) throws -> UInt64 {
        guard case let .number(number) = value ?? .null, number.isFinite,
              number.rounded(.down) == number, number >= 0,
              let integer = UInt64(exactly: number) else {
            throw ResidentStateError.invalidResponse
        }
        return integer
    }

    func requireObject(_ value: ResidentStateJSON?) throws -> [String: ResidentStateJSON] {
        guard case let .object(object) = value else { throw ResidentStateError.invalidResponse }
        return object
    }

    func stateRead(scope: ResidentStateScope, domain: ResidentStateDomain,
                   key: String) async throws -> (revision: UInt64, value: [String: ResidentStateJSON])? {
        var params = scopeParams(scope)
        params["domain"] = .string(domain.rawValue)
        params["key"] = .string(key)
        let response = try await transport.call(method: "state_read", params: params)
        // record 缺失即畸形响应；record:null 才是"无记录"。
        guard let record = response["record"] else { throw ResidentStateError.invalidResponse }
        if case .null = record { return nil }
        guard case let .object(recordObject) = record else { throw ResidentStateError.invalidResponse }
        guard let revisionJSON = recordObject["revision"] else { throw ResidentStateError.invalidResponse }
        let revision = try strictUInt64(revisionJSON)
        guard case let .object(value)? = recordObject["value"] else { throw ResidentStateError.invalidResponse }
        return (revision: revision, value: value)
    }

    func stateCommit(scope: ResidentStateScope, domain: ResidentStateDomain, key: String,
                     expectedRevision: UInt64, requestID: String, value: [String: ResidentStateJSON],
                     events: [ResidentStateFact] = [],
                     messages: [ResidentStateFact] = []) async throws -> (revision: UInt64, replayed: Bool) {
        var params = scopeParams(scope)
        params["domain"] = .string(domain.rawValue)
        params["key"] = .string(key)
        params["expectedRevision"] = .number(Double(expectedRevision))
        params["requestID"] = .string(requestID)
        params["value"] = .object(value)
        if !events.isEmpty { params["events"] = .array(events.map { .object($0.object) }) }
        if !messages.isEmpty { params["messages"] = .array(messages.map { .object($0.object) }) }
        let response = try await transport.call(method: "state_commit", params: params)
        // result 恒为 {revision, replayed}；缺任一字段都是畸形响应。
        let revision = try strictUInt64(response["revision"])
        guard let replayed = response["replayed"]?.boolValue else { throw ResidentStateError.invalidResponse }
        return (revision: revision, replayed: replayed)
    }

    func eventRead(scope: ResidentStateScope, after: UInt64,
                   limit: Int) async throws -> (events: [ResidentStateCommittedFact], nextCursor: UInt64) {
        var params = scopeParams(scope)
        params["after"] = .number(Double(after))
        params["limit"] = .number(Double(limit))
        let response = try await transport.call(method: "event_read", params: params)
        guard case let .array(entries) = response["events"] else { throw ResidentStateError.invalidResponse }
        let facts = try factList(entries)
        let nextCursor = try strictUInt64(response["nextCursor"])
        return (facts, nextCursor: nextCursor)
    }

    func messageRead(scope: ResidentStateScope, consumer: String, after: UInt64 = 0,
                     limit: Int = 100) async throws -> (messages: [ResidentStateCommittedFact], nextCursor: UInt64) {
        var params = scopeParams(scope)
        params["consumer"] = .string(consumer)
        params["limit"] = .number(Double(limit))
        params["after"] = .number(Double(after))
        let response = try await transport.call(method: "message_read", params: params)
        guard case let .array(entries) = response["messages"] else { throw ResidentStateError.invalidResponse }
        let facts = try factList(entries)
        let nextCursor = try strictUInt64(response["nextCursor"])
        return (facts, nextCursor: nextCursor)
    }

    func messageAck(scope: ResidentStateScope, consumer: String, id: String) async throws {
        var params = scopeParams(scope)
        params["consumer"] = .string(consumer)
        params["id"] = .string(id)
        let response = try await transport.call(method: "message_ack", params: params)
        // 成功应答必须是 acknowledged:true；缺失/非 true 一律拒绝，不吞成成功。
        guard response["acknowledged"]?.boolValue == true else { throw ResidentStateError.invalidResponse }
    }

    private func factList(_ entries: [ResidentStateJSON]) throws -> [ResidentStateCommittedFact] {
        return try entries.map { entry in
            guard case let .object(object) = entry else { throw ResidentStateError.invalidResponse }
            let sequence = try strictUInt64(object["sequence"])
            guard case let .string(id) = object["id"] else { throw ResidentStateError.invalidResponse }
            guard case let .string(kind) = object["kind"] else { throw ResidentStateError.invalidResponse }
            guard case let .object(payload)? = object["payload"] else { throw ResidentStateError.invalidResponse }
            return ResidentStateCommittedFact(sequence: sequence, id: id, kind: kind, payload: payload)
        }
    }

    // MARK: - [String: Any] 桥接（仅宿主接线/测试用）

    static func plain(_ value: [String: ResidentStateJSON]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, item) in value {
            switch item {
            case .string(let v): result[key] = v
            case .number(let v): result[key] = v
            case .bool(let v): result[key] = v
            case .null: result[key] = NSNull()
            case .object(let v): result[key] = Self.plain(v)
            case .array(let v): result[key] = v.map { Self.plainValue($0) }
            }
        }
        return result
    }

    static func plainValue(_ item: ResidentStateJSON) -> Any {
        switch item {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .null: return NSNull()
        case .object(let v): return Self.plain(v)
        case .array(let v): return v.map { Self.plainValue($0) }
        }
    }

    /// JSONSerialization 的 NSNumber 会把 1/0 桥接成 Bool（as? Bool 对
    /// __NSCFNumber(1) 成功），所以必须先按 CFBoolean 区分真布尔，再按数值处理，
    /// 避免 revision=1 / nextCursor=0 这类整数被误转成 bool。
    static func json(_ object: [String: Any]) -> [String: ResidentStateJSON] {
        var result: [String: ResidentStateJSON] = [:]
        for (key, value) in object {
            result[key] = Self.jsonValue(value)
        }
        return result
    }

    static func jsonValue(_ value: Any) -> ResidentStateJSON {
        switch value {
        case let v as String: return .string(v)
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return .bool(v.boolValue) }
            return .number(v.doubleValue)
        case let v as [String: Any]: return .object(Self.json(v))
        case let v as [Any]: return .array(v.map { Self.jsonValue($0) })
        default: return .null
        }
    }
}

extension ResidentStateJSON {
    var objectValue: [String: ResidentStateJSON]? {
        if case let .object(object) = self { return object }
        return nil
    }
    var doubleValue: Double? {
        if case let .number(number) = self { return number }
        return nil
    }
    var boolValue: Bool? {
        if case let .bool(bool) = self { return bool }
        return nil
    }
    var stringValue: String? {
        if case let .string(string) = self { return string }
        return nil
    }
}
