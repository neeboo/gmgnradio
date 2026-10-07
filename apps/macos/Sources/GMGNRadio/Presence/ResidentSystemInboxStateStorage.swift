import Foundation

/// 收件箱的统一状态合同存储适配（gmgn-taskd `state_read`/`state_commit`，
/// domain=inbox）。scope={worldID,residentScope} 下每个空间一条记录
/// （key=entries），CAS revision 与内容版本 requestID 在此持有：
///
/// - 每次保存都真实提交（合同：revision 是成功提交的计数）；CAS 冲突如实
///   抛出，绝不静默重读覆盖他人写入；
/// - 同一内容的重试复用同一 requestID：不确定结果可被后台幂等回放（同 ID
///   同内容），不重复推进 revision；内容一变即换新 ID；
/// - `request_id_conflict` 时作废缓存键并如实抛出，由调用方呈现；
/// - 失败一律抛给调用方，绝不在后台吞掉，也不做后台自动重试。
@MainActor
final class ResidentSystemInboxStateStorage {
    static let domainKey = "entries"

    private struct Attempt: Equatable {
        let fingerprint: String
        let requestID: String
    }

    private let client: ResidentStateClient
    private var revisions: [ResidentStateScope: UInt64] = [:]
    private var lastAttempts: [ResidentStateScope: Attempt] = [:]

    init(client: ResidentStateClient) {
        self.client = client
    }

    /// Agent reads must not recalibrate a writer's CAS revision or retry identity.
    func readOnly(scope: ResidentStateScope) async throws -> [ResidentSystemInboxEntry]? {
        guard let record = try await client.stateRead(scope: scope, domain: .inbox, key: Self.domainKey) else { return nil }
        return try Self.decodeEntries(record.value)
    }

    /// 读取已保存的收件箱条目；无记录返回 nil（不是错误）。恢复同时校准该
    /// 作用域的 CAS revision，使后续提交基于最新版本。记录损坏/畸形时如实
    /// 抛出，不注入任何条目。
    func restore(scope: ResidentStateScope) async throws -> [ResidentSystemInboxEntry]? {
        let record = try await client.stateRead(scope: scope, domain: .inbox, key: Self.domainKey)
        guard let record else {
            revisions[scope] = 0
            lastAttempts[scope] = nil
            return nil
        }
        let entries = try Self.decodeEntries(record.value)
        revisions[scope] = record.revision
        lastAttempts[scope] = nil
        return entries
    }

    func persist(scope: ResidentStateScope, entries: [ResidentSystemInboxEntry], messages: [ResidentStateFact] = []) async throws {
        let value = try Self.stateValue(entries)
        var attemptValue = value
        if !messages.isEmpty { attemptValue["messages"] = .array(messages.map { .object($0.object) }) }
        let fingerprint = try Self.fingerprint(attemptValue)
        let requestID: String
        if let last = lastAttempts[scope], last.fingerprint == fingerprint {
            requestID = last.requestID
        } else {
            requestID = UUID().uuidString
            lastAttempts[scope] = Attempt(fingerprint: fingerprint, requestID: requestID)
        }
        do {
            let result = try await client.stateCommit(scope: scope, domain: .inbox,
                key: Self.domainKey, expectedRevision: revisions[scope] ?? 0,
                requestID: requestID, value: value, messages: messages)
            // 回放返回的是该 requestID 当初的 revision，可能低于已知值
            // （他人已推进）；已知值只来自成功回执/读取，恒 ≤ 实际值，取
            // max 保证记账单调不回退。
            revisions[scope] = max(revisions[scope] ?? 0, result.revision)
        } catch let error as ResidentStateError {
            if error == .daemon("request_id_conflict") { lastAttempts[scope] = nil }
            throw error
        }
    }

    // MARK: - 可靠 Codable JSON 路径（不经 [String: Any]/NSNumber 桥接）

    static func stateValue(_ entries: [ResidentSystemInboxEntry]) throws -> [String: ResidentStateJSON] {
        let encoder = JSONEncoder()
        // 秒级双精度时间戳：提示窗锚点要求原时间戳逐字节保留（iso8601 会丢亚秒）。
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(entries) }
        catch { throw ResidentStateError.unreadableArchive }
        guard let tree = try? JSONDecoder().decode(ResidentStateJSON.self, from: data),
              case let .array(list) = tree else {
            throw ResidentStateError.unreadableArchive
        }
        return ["entries": .array(list)]
    }

    static func decodeEntries(_ value: [String: ResidentStateJSON]) throws -> [ResidentSystemInboxEntry] {
        guard case let .array(list)? = value["entries"] else { throw ResidentStateError.unreadableArchive }
        let data: Data
        do { data = try JSONEncoder().encode(ResidentStateJSON.array(list)) }
        catch { throw ResidentStateError.unreadableArchive }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do { return try decoder.decode([ResidentSystemInboxEntry].self, from: data) }
        catch { throw ResidentStateError.unreadableArchive }
    }

    /// 内容指纹：键排序后的规范 JSON 文本。同一编码器保证同一内容同指纹，
    /// 用于"内容已落库则跳过提交"与 requestID 内容版本配对。
    static func fingerprint(_ value: [String: ResidentStateJSON]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ResidentStateJSON.object(value))
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 旧 JSON 归档的一次性只读导入

    /// 解码旧版 ResidentSystemInbox.json 归档（默认日期编码）。文件不存在或
    /// 已损坏返回 nil——迁移只读：绝不改写、绝不删除旧文件。
    static func legacyArchive(at url: URL) -> ResidentSystemInboxArchive? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ResidentSystemInboxArchive.self, from: data)
    }

    static func legacyEntries(from archive: ResidentSystemInboxArchive,
                              worldID: String, residentScope: String) -> [ResidentSystemInboxEntry] {
        archive.buckets
            .first { $0.scope == ResidentSystemInboxScope(worldID: worldID, residentScope: residentScope) }?
            .entries.sorted { $0.updatedAt > $1.updatedAt } ?? []
    }
}
