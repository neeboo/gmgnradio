//
//  RetryBackoff.swift
//  GMGNRadio
//
//  全仓**唯一**的退避与重试预算定义。以前退避参数散在六处各写各的：
//    · 找参考图 30 秒冷却（`ResidentWishReferenceTools.cooldownInterval`）
//    · 宿主工具桥瞬时错误退避（`ResidentDSHHostToolsBridge` 的 accept 循环）
//    · 世界权威断线退避重连（`WorldAuthorityClient` 的订阅线程）
//    · 生成结果未明的自动确认（`WishMachineCoordinator`）
//    · 摆放试算的主线程尝试上限（`ResidentPropEditorState`）
//    · 点唱机一次尝试的总时限与轮询间隔（`ResidentActivityOutcome`）
//  现在它们都读 `RetryBackoffSite.<该处>.policy`；**判据语义各自保留**
//  （权威重连仍从投影游标续；点唱机的 45 秒冷却仍来自世界活动声明，那是数据不是策略）。
//
//  三条硬性质（门禁 `tools/test-resident-loop-retry.swift` 逐条注入验证）：
//    1. 连续失败等待**递增**（`growth > 1` 且 `delay` 单调不减）；
//    2. 带**抖动**，而且抖动只向上加 —— 实际等待绝不比名义值短，因此不可能比改动前的冷却更松；
//    3. 有**上限**：次数上限 + 总时长上限 + 单跳封顶；等待用 `Task.sleep`/`Thread.sleep`，
//       绝不忙转（忙转 = 0 等待，这里连 `baseDelay` 都是正的）。
//
//  另含居民自主 iterate 的账本 `ResidentRetryLedger`：把「失败」当成一次尝试，不是终点。
//  同一个失败连续两次 ⇒ 必须换招；预算用尽才把问题交给用户，且只有**一句人话**。
//  需要人类确认的动作（`human_guidance_required`）照旧必须问用户，绝不被"自主"绕过。
//
//  本文件自包含（Foundation + os），可被 `tools/*` 离线 swiftc 直接编译运行。

import Foundation
import os

// MARK: - 单处策略

/// 一条退避策略。`delay(afterFailure:)` 是第 n 次失败之后的**名义**等待；
/// `delay(afterFailure:jitterUnit:)` 在名义值上**只向上**加抖动，仍然封顶。
public struct RetryBackoffPolicy: Sendable, Equatable {
    /// 连续失败的最大尝试数；达到即「预算用尽」。
    public let maximumAttempts: Int
    /// 从第一次失败算起的总时长上限（秒）；达到即「预算用尽」。
    public let maximumDuration: TimeInterval
    /// 第一次失败之后的名义等待（秒）。
    public let baseDelay: TimeInterval
    /// 每多一次失败，名义等待乘以的增长因子（≥ 1）。
    public let growth: Double
    /// 单跳名义等待的封顶（秒）。
    public let maximumDelay: TimeInterval
    /// 抖动幅度：占 `maximumDelay` 的比例（0…1）。
    public let jitterFraction: Double

    public init(
        maximumAttempts: Int,
        maximumDuration: TimeInterval,
        baseDelay: TimeInterval,
        growth: Double,
        maximumDelay: TimeInterval,
        jitterFraction: Double
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.maximumDuration = max(0, maximumDuration)
        self.baseDelay = max(0, baseDelay)
        self.growth = max(1, growth)
        self.maximumDelay = max(self.baseDelay, maximumDelay)
        self.jitterFraction = min(max(jitterFraction, 0), 1)
    }

    /// 名义等待：单调不减、封顶。`attempt` 从 1 起（第 1 次失败之后）。
    public func delay(afterFailure attempt: Int) -> TimeInterval {
        let step = max(0, min(attempt, maximumAttempts) - 1)
        return min(baseDelay * pow(growth, Double(step)), maximumDelay)
    }

    /// 实际等待：名义值 + 只向上的抖动，仍然封顶。
    public func delay(afterFailure attempt: Int, jitterUnit: Double) -> TimeInterval {
        let nominal = delay(afterFailure: attempt)
        guard nominal > 0, jitterFraction > 0 else { return nominal }
        let unit = min(max(jitterUnit, 0), 1)
        return nominal + maximumDelay * jitterFraction * unit
    }

    public func duration(afterFailure attempt: Int, jitterUnit: Double) -> Duration {
        .seconds(delay(afterFailure: attempt, jitterUnit: jitterUnit))
    }

    /// 预算是否用尽：次数上限或总时长上限，任一达到即用尽。
    public func isExhausted(attempts: Int, elapsed: TimeInterval) -> Bool {
        attempts >= maximumAttempts || elapsed >= maximumDuration
    }
}

/// 抖动源。生产用 `uniform`；门禁注入一个固定值，让等待可复现。
public struct RetryJitter: Sendable {
    public var unit: @Sendable () -> Double

    public init(unit: @escaping @Sendable () -> Double) {
        self.unit = unit
    }

    public static let uniform = RetryJitter { Double.random(in: 0...1) }

    public static func fixed(_ value: Double) -> RetryJitter {
        RetryJitter { value }
    }
}

// MARK: - 六处退避（只有这一份定义）

/// 六处退避的**唯一**参数来源。每一处的第一跳都不短于改动前的既有冷却/退避，
/// 之后递增、加抖动、封顶 —— 因此这次统一**只可能更严，不可能更松**。
public enum RetryBackoffSite: String, CaseIterable, Sendable {
    /// 找参考图：连不上 / 没配时不再反复撞墙。
    /// 既有语义：第一跳 30 秒（改动前就是 30 秒冷却）。
    case referenceSearch
    /// 宿主工具桥 accept 的瞬时错误（EMFILE 等）：退避后继续，绝不忙转。
    /// 既有语义：第一跳 50 毫秒。
    case hostToolBridge
    /// 世界权威断线重连。既有语义：**从投影游标续**（游标是语义，不搬进策略）。
    /// 既有语义：第一跳 1 秒。
    case authorityReconnect
    /// 生成结果未明的自动确认。既有语义：**复用原幂等身份**，绝不新建生成；
    /// 同一任务最多自动确认 3 次、两次之间至少 30 秒。
    case generationConfirmation
    /// 摆放试算的主线程尝试上限。既有语义：只问候选落点，**不含等待**（这是预算不是退避）。
    /// 既有语义：上限 32 个候选。
    case propPlacement
    /// 点唱机一次尝试的总时限与轮询间隔。既有语义：世界活动声明的冷却（点唱机 45 秒）
    /// 是**数据**，仍由世界定义决定，不搬进策略。
    /// 既有语义：总时限 180 秒、轮询 50 毫秒。
    case jukeboxActivity
    /// 居民自己 iterate 的重试预算（同一个失败两次就换招；三次是上限）。
    case residentIteration

    public var policy: RetryBackoffPolicy {
        switch self {
        case .referenceSearch:
            RetryBackoffPolicy(maximumAttempts: 6, maximumDuration: 900,
                               baseDelay: 30, growth: 2, maximumDelay: 300, jitterFraction: 0.2)
        case .hostToolBridge:
            RetryBackoffPolicy(maximumAttempts: 8, maximumDuration: 120,
                               baseDelay: 0.05, growth: 2, maximumDelay: 2, jitterFraction: 0.25)
        case .authorityReconnect:
            RetryBackoffPolicy(maximumAttempts: 12, maximumDuration: 900,
                               baseDelay: 1, growth: 2, maximumDelay: 30, jitterFraction: 0.2)
        case .generationConfirmation:
            RetryBackoffPolicy(maximumAttempts: 3, maximumDuration: 900,
                               baseDelay: 30, growth: 2, maximumDelay: 240, jitterFraction: 0.2)
        case .propPlacement:
            RetryBackoffPolicy(maximumAttempts: 32, maximumDuration: 2,
                               baseDelay: 0, growth: 1, maximumDelay: 0, jitterFraction: 0)
        case .jukeboxActivity:
            RetryBackoffPolicy(maximumAttempts: 1, maximumDuration: 180,
                               baseDelay: 0.05, growth: 1, maximumDelay: 0.05, jitterFraction: 0)
        case .residentIteration:
            RetryBackoffPolicy(maximumAttempts: 3, maximumDuration: 600,
                               baseDelay: 2, growth: 2, maximumDelay: 30, jitterFraction: 0.25)
        }
    }
}

// MARK: - 居民自主 iterate 的账本

/// 只进日志的细节出口（工具名 / 错误码 / 次数 / 时长）。用户看到的永远只有一句人话。
enum ResidentRetryLog {
    private static let log = Logger(subsystem: "ai.gmgn.radio", category: "ResidentRetry")

    static func emit(_ message: String) {
        log.notice("\(message, privacy: .public)")
    }
}

/// 把「失败」当成一次尝试：同一个失败连续两次必须换招；预算用尽才交给用户。
///
/// 签名 = 工具名 + 错误码（同一件事的同一个失败）。判据是**连续两次同一个签名**，
/// 不是「同一个工具失败两次」：换了参数、换了落点、换了挂点、换了措辞导致错误码变了，
/// 就是换招了，照常继续。
public struct ResidentRetryLedger: Sendable {
    public enum Verdict: Equatable, Sendable {
        /// 第一次失败：同一个办法可以再试一次。
        case retrySameApproach
        /// 同一个失败已经连续两次：必须换招（不许原地第三次重试同样的事）。
        case changeApproach(String)
        /// 结构上不可能靠重试解决：第一次就具名说明，不空转（不占预算）。
        case structural(String)
        /// 需要人类确认的动作：照旧必须问用户，绝不被"自主"绕过（不占预算）。
        case needsHuman
        /// 预算用尽才交给用户，且只有一句人话。
        case handOff(String)
    }

    /// 必须由人类确认的动作错误码：不重试、不计预算、不换措辞再撞。
    public static let humanRequiredCodes: Set<String> = [
        "human_guidance_required",
        "delegation_violation",
    ]

    /// 结构上不可能靠重试解决的错误码：第一次就具名说明。
    /// （资产确实缺文件、网络出口被挡、功能没装、根本不支持、没有权限。）
    public static let structuralCodes: Set<String> = [
        "asset_missing", "missing_asset", "file_missing", "missing_file",
        "not_installed", "tool_unavailable",
        "unsupported", "unsupported_playback_source", "playback_source_unsupported",
        "network_egress_blocked", "egress_blocked", "blocked_by_policy",
        "permission_denied", "unauthorized",
    ]

    /// 交给用户的那**一句人话**：现在是什么情况 + 需要你做什么。
    /// 不许出现字段名、编号、路径、内部术语；细节只在 `ResidentRetryLog` 里。
    public static let handoffText = "这件事我试了几次都没做成，需要你拿个主意。"

    /// 同一个失败连续两次之后给模型换招的指令（换参数/换落点/换挂点/换措辞/先做前置动作）。
    public static let changeApproachText = "同一个办法已经失败两次，换一种做法再试，不要原样重来。"

    private var attempts = 0
    private var startedAt: Date?
    private var streak: [String: Int] = [:]
    private var triedSignatures: [String] = []

    public init() {}

    public var attemptCount: Int { attempts }

    /// 这条失败之后该怎么走。`date` 可注入，门禁里用固定时钟验证预算。
    public mutating func noteFailure(tool: String, code: String, at date: Date = Date()) -> Verdict {
        let normalized = code.isEmpty ? "unknown" : code
        let signature = Self.signature(tool: tool, code: normalized)

        if Self.humanRequiredCodes.contains(normalized) {
            ResidentRetryLog.emit("retry 需要人类确认，不自动重试：\(signature)")
            return .needsHuman
        }
        if let named = Self.structuralReason(normalized) {
            ResidentRetryLog.emit("retry 结构失败，第一次就具名：\(signature)")
            return .structural(named)
        }

        attempts += 1
        if startedAt == nil { startedAt = date }
        if !triedSignatures.contains(signature) { triedSignatures.append(signature) }
        streak[signature, default: 0] += 1
        let sameCount = streak[signature] ?? 1
        let elapsed = startedAt.map { date.timeIntervalSince($0) } ?? 0
        let policy = RetryBackoffSite.residentIteration.policy

        if policy.isExhausted(attempts: attempts, elapsed: elapsed) {
            ResidentRetryLog.emit(
                "retry 预算用尽：已试 \(attempts) 次 / \(Int(elapsed)) 秒 / \(triedSignatures.count) 种写法"
            )
            return .handOff(Self.handoffText)
        }
        if sameCount >= 2 {
            ResidentRetryLog.emit("retry 同一个失败连续两次：\(signature)，要求换招")
            return .changeApproach(Self.changeApproachText)
        }
        return .retrySameApproach
    }

    /// 任何一次成功都清空账本：这是一个新起点，不是旧失败的延续。
    public mutating func noteSuccess() {
        attempts = 0
        startedAt = nil
        streak.removeAll()
        triedSignatures.removeAll()
    }

    public static func signature(tool: String, code: String) -> String {
        "\(tool)#\(code.isEmpty ? "unknown" : code)"
    }

    /// 结构化失败的**具名**说法（第一次就给，不浪费预算）。
    public static func structuralReason(_ code: String) -> String? {
        switch code {
        case "asset_missing", "missing_asset", "file_missing", "missing_file":
            "缺了需要的文件，重试也没用。"
        case "not_installed", "tool_unavailable":
            "这个功能还没装好，重试也没用。"
        case "unsupported", "unsupported_playback_source", "playback_source_unsupported":
            "这件东西现在不支持这么做，重试也没用。"
        case "network_egress_blocked", "egress_blocked", "blocked_by_policy":
            "网络出口被挡住了，重试也没用。"
        case "permission_denied", "unauthorized":
            "没有这个权限，重试也没用。"
        default:
            nil
        }
    }
}
