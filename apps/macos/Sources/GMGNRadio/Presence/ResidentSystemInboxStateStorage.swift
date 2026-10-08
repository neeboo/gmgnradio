import Foundation

/// Thin inbox command/confirmed projection adapter. No whole-entry-array writer.
@MainActor
final class ResidentSystemInboxStateStorage {
    let client: RustInboxClient
    init(client: RustInboxClient) { self.client = client }
    private func inboxScope(_ scope: ResidentStateScope) -> ResidentSystemInboxScope {
        .init(worldID: scope.worldID, residentScope: scope.residentScope)
    }
    func readOnly(scope: ResidentStateScope) async throws -> [ResidentSystemInboxEntry]? {
        let result = try await client.read(scope: inboxScope(scope))
        return result.revision == 0 ? nil : result.entries
    }
    func restore(scope: ResidentStateScope) async throws -> [ResidentSystemInboxEntry]? {
        try await readOnly(scope: scope)
    }
    func deliver(scope: ResidentStateScope, deliveries: [ResidentSystemDelivery]) async throws -> RustInboxClient.Snapshot {
        try await client.deliver(deliveries, scope: inboxScope(scope))
    }
    func post(scope: ResidentStateScope, id: UUID, title: String, detail: String) async throws -> RustInboxClient.Snapshot {
        try await client.post(messageID: id.uuidString, title: title, detail: detail, scope: inboxScope(scope))
    }
    func markRead(scope: ResidentStateScope, taskKey: String, expectedEventID: String) async throws -> RustInboxClient.Snapshot {
        try await client.markRead(taskKey: taskKey, expectedEventID: expectedEventID, scope: inboxScope(scope))
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
