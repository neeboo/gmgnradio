import Foundation

// ResidentMemoryConfiguration.swift — VoiceMem 双路 provider 的运行时显式配置
//
// 合同：docs/plans/2026-09-08-voicemem-rust-orchestration.md（冻结）。
// 程序运行时由宿主从显式环境变量读取（GMGN_MEMORY_COMPACTION_* /
// GMGN_MEMORY_EMBEDDING_*），与既有服务配置模式一致：
// - 本类型只做只读解析，不触发钥匙串/security、不写 UserDefaults、不打日志；
// - token 只作为 memory_configure 的请求参数转发给 daemon（daemon 内存保存、
//   不落盘、不进日志），本类型绝不把 token 存进属性、磁盘或日志；
// - compaction/embedding 各自独立配置：任一 provider 的 endpoint 或 token
//   缺失/为空即视为该 provider 未配置（缺配置是明确可见状态，聊天不受影响）；
// - model 可选；trim 后为空视为未提供。

/// 从显式环境变量解析出的两个 provider 配置（可选：各自独立缺失）。
struct ResidentMemoryEnvironmentConfiguration: Equatable, Sendable {
    struct Provider: Equatable, Sendable {
        let endpoint: String
        let token: String
        let model: String?
    }

    let compaction: Provider?
    let embedding: Provider?

    /// 两个 provider 都齐备才算完整配置。
    var isComplete: Bool { compaction != nil && embedding != nil }

    /// 只读解析环境变量；值 trim 后为空视为缺失。
    static func read(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ResidentMemoryEnvironmentConfiguration {
        func provider(_ base: String) -> Provider? {
            guard let endpoint = trimmed(environment["\(base)_ENDPOINT"]),
                  let token = trimmed(environment["\(base)_TOKEN"]) else { return nil }
            return Provider(
                endpoint: endpoint,
                token: token,
                model: trimmed(environment["\(base)_MODEL"])
            )
        }
        return ResidentMemoryEnvironmentConfiguration(
            compaction: provider("GMGN_MEMORY_COMPACTION"),
            embedding: provider("GMGN_MEMORY_EMBEDDING")
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
