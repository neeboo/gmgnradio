import Foundation

/// 统一状态合同的共享 socket 运输适配（App 居民接线）：
/// class（协议要求 AnyObject）。两个方向的值树转换各是一行抛错式
/// Codable 往返——真实 JSON 语义（0/1/bool/null/string/array/nested）
/// 由两个枚举自带的 Codable 保留，失败即抛，绝不转 dictionary 或用
/// null 顶替；daemon 错误码（revision_conflict 等）映射为
/// ResidentStateError.daemon 原样透传。
@MainActor
final class ResidentTaskDaemonStateTransport: ResidentStateTransport {
    let client: PropTaskDaemonClient

    init(client: PropTaskDaemonClient) { self.client = client }

    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        var outbound: [String: PropTaskJSON] = [:]
        for (key, item) in params {
            outbound[key] = try ResidentTaskDaemonStateTransport.propTaskJSON(item)
        }
        do {
            let response = try await client.call(method: method, params: outbound)
            var inbound: [String: ResidentStateJSON] = [:]
            for (key, item) in response {
                inbound[key] = try ResidentTaskDaemonStateTransport.residentStateJSON(item)
            }
            return inbound
        } catch let error as PropTaskDaemonError {
            if case .requestRejectedWith(let code) = error { throw ResidentStateError.daemon(code) }
            throw error
        }
    }

    static func propTaskJSON(_ value: ResidentStateJSON) throws -> PropTaskJSON {
        try JSONDecoder().decode(PropTaskJSON.self, from: JSONEncoder().encode(value))
    }

    static func residentStateJSON(_ value: PropTaskJSON) throws -> ResidentStateJSON {
        try JSONDecoder().decode(ResidentStateJSON.self, from: JSONEncoder().encode(value))
    }
}
