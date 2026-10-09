import Foundation

/// Explicit migration seam; never installed by default. Rust authorizes background
/// and human model turns, not completion of world actions emitted by those turns.
@MainActor
final class RustResidentSchedulerClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct Claim: Decodable, Sendable {
        let claimed: Bool
        let eventID: String?
        let runID: String?
        let hostSessionID: String?
    }
    struct Ticket: Sendable {
        let eventID: String
        let runID: UUID
        let hostSessionID: String
    }
    struct SteeringInput: Sendable {
        let ticket: Ticket
        let messageID: String
        let inputSHA256: String
        let text: String
        var inputRef: [String: Any] {
            ["submissionID": messageID, "inputSHA256": inputSHA256, "imageReferences": [String]()]
        }
    }
    let worldID: String
    let residentScope: String
    let hostSessionID: String
    private let call: Call
    private var queuedEventID: String?

    init(worldID: String, residentScope: String, hostSessionID: String = UUID().uuidString,
         call: @escaping Call) {
        self.worldID = worldID; self.residentScope = residentScope
        self.hostSessionID = hostSessionID; self.call = call
    }

    private func request(_ method: String, _ values: [String: Any]) async throws -> Data {
        var values = values
        values["worldID"] = worldID; values["residentScope"] = residentScope
        let input = try JSONSerialization.data(withJSONObject: values)
        let call = self.call
        return try await Task.detached { try call(method, input) }.value
    }

    func claim(eventID: String, configuration: [String: Any], opportunity: [String: Any],
               nowMillis: Int64) async throws -> Ticket? {
        var configuration = configuration
        configuration["hostSessionID"] = hostSessionID
        _ = try await request("agent_loop_configure", configuration)
        var opportunity = opportunity
        opportunity["eventID"] = eventID
        opportunity["command"] = ["type": "resident_model_turn"]
        let enqueued = try await request("agent_loop_enqueue", opportunity)
        guard let reply = try JSONSerialization.jsonObject(with: enqueued) as? [String: Any],
              reply["enqueued"] as? Bool == true,
              let effectiveEventID = reply["eventID"] as? String, !effectiveEventID.isEmpty else {
            throw ClientError.receiptMismatch
        }
        if let old = queuedEventID, old != effectiveEventID {
            _ = try await request("agent_loop_cancel", ["eventID": old])
        }
        queuedEventID = effectiveEventID
        let runID = UUID()
        let data = try await request("agent_loop_claim", ["runID": runID.uuidString,
            "hostSessionID": hostSessionID, "nowMillis": nowMillis, "eventID": effectiveEventID])
        let claim = try JSONDecoder().decode(Claim.self, from: data)
        guard claim.claimed else { return nil }
        guard claim.eventID == effectiveEventID, claim.runID == runID.uuidString,
              claim.hostSessionID == hostSessionID else {
            // A different pending event is not this host's execution input.
            throw ClientError.receiptMismatch
        }
        return Ticket(eventID: effectiveEventID, runID: runID, hostSessionID: hostSessionID)
    }

    enum ClientError: Error { case receiptMismatch }

    func claimHuman(eventID: String, messageIDs: [String], inputRefs: [String: Any],
                    configuration: [String: Any], nowMillis: Int64) async throws -> Ticket? {
        var configuration = configuration
        configuration["hostSessionID"] = hostSessionID
        configuration["humanTurn"] = true
        _ = try await request("agent_loop_configure", configuration)
        _ = try await request("agent_loop_enqueue", ["eventID": eventID, "intentID": "human-batch",
            "kind": "human", "intentState": "active", "messageIDs": messageIDs,
            "inputRefs": inputRefs, "command": ["type": "resident_human_turn", "messageIDs": messageIDs]])
        let id = UUID()
        let data = try await request("agent_loop_claim", ["runID": id.uuidString,
            "hostSessionID": hostSessionID, "nowMillis": nowMillis, "eventID": eventID])
        let claim = try JSONDecoder().decode(Claim.self, from: data)
        guard claim.claimed else { return nil }
        guard claim.eventID == eventID, claim.runID == id.uuidString, claim.hostSessionID == hostSessionID else {
            throw ClientError.receiptMismatch
        }
        return Ticket(eventID: eventID, runID: id, hostSessionID: hostSessionID)
    }

    /// 领取被拒时的**只读**取证：`agent_loop_read` 是既有路由（只读、无副作用），
    /// 不新增任何 daemon 路由。读不到就退化成"未知"——绝不因为诊断失败而丢掉
    /// "已经被拒"这个事实本身。
    func humanClaimRefusalEvidence(eventID: String) async -> ResidentHumanClaimEvidence {
        var evidence = ResidentHumanClaimEvidence()
        evidence.ourEventID = eventID
        guard let data = try? await request("agent_loop_read", [:]),
              let object = try? JSONSerialization.jsonObject(with: data),
              let value = object as? [String: Any] else { return evidence }
        if let config = value["config"] as? [String: Any] {
            if let available = config["available"] as? Bool { evidence.available = available }
            if let editing = config["editing"] as? Bool { evidence.editing = editing }
        }
        for event in (value["events"] as? [[String: Any]]) ?? [] {
            residentHumanClaimEvidenceFoldingEvent(&evidence,
                eventID: event["eventID"] as? String,
                state: event["state"] as? String,
                kind: (event["payload"] as? [String: Any])?["kind"] as? String)
        }
        return evidence
    }

    func cancelPending(eventID: String) async throws {
        _ = try await request("agent_loop_cancel", ["eventID": eventID])
    }

    private struct SteeringAdmission: Decodable { let admitted: Bool; let delivery: String }
    func admitSteering(_ ticket: Ticket, messageID: String, inputRef: Any) async throws -> (Bool, ResidentSteeringDelivery) {
        let data = try await request("agent_loop_steer_admit", ["eventID": ticket.eventID,
            "runID": ticket.runID.uuidString, "hostSessionID": ticket.hostSessionID,
            "messageID": messageID, "inputRef": inputRef])
        let result = try JSONDecoder().decode(SteeringAdmission.self, from: data)
        let delivery: ResidentSteeringDelivery
        switch result.delivery {
        case "delivered": delivery = .delivered
        case "not_delivered": delivery = .notDelivered
        default: delivery = .unknown
        }
        return (result.admitted, delivery)
    }
    func finishSteering(_ ticket: Ticket, messageID: String, delivery: ResidentSteeringDelivery) async throws {
        let wire = delivery == .notDelivered ? "not_delivered" : delivery.rawValue
        _ = try await request("agent_loop_steer_finish", ["eventID": ticket.eventID,
            "runID": ticket.runID.uuidString, "hostSessionID": ticket.hostSessionID,
            "messageID": messageID, "delivery": wire,
            "receipt": ["providerDelivery": wire]])
    }

    func requestCancellation(_ ticket: Ticket) async throws {
        _ = try await request("agent_loop_cancel", ["eventID": ticket.eventID])
    }

    enum FinishReceipt: Sendable { case terminal, cancellationRequested }

    /// Only call after the invocation has returned, or before it ever started.
    @discardableResult
    func finish(_ ticket: Ticket, outcome: String, invocationStarted: Bool, cancellationConfirmed: Bool = false) async throws -> FinishReceipt {
        if outcome == "cancelled", invocationStarted, !cancellationConfirmed {
            // A local CancellationError cannot confirm remote side effects stopped.
            try await requestCancellation(ticket)
            // A separate trusted native termination receipt may already have
            // confirmed this exact execution. A cancel request is not that receipt.
            let data = try await request("agent_loop_read", [:])
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = value["events"] as? [[String: Any]],
                  events.contains(where: {
                      $0["eventID"] as? String == ticket.eventID
                          && ($0["runID"] as? String).flatMap(UUID.init(uuidString:)) == ticket.runID
                          && $0["hostSessionID"] as? String == ticket.hostSessionID
                          && $0["state"] as? String == "cancelled"
                          && $0["receipt"] as? [String: Any] != nil
                  }) else { return .cancellationRequested }
            if queuedEventID == ticket.eventID { queuedEventID = nil }
            return .terminal
        }
        var values: [String: Any] = ["eventID": ticket.eventID, "runID": ticket.runID.uuidString,
            "hostSessionID": ticket.hostSessionID,
            "receipt": ["kind": "resident_model_turn", "invocationReturned": invocationStarted,
                        "executionNotStarted": !invocationStarted,
                        "invocationStarted": invocationStarted, "outcome": outcome]]
        let method: String
        if outcome == "cancelled" { method = "agent_loop_confirm_cancel" }
        else { method = "agent_loop_complete"; values["status"] = outcome }
        let data = try await request(method, values)
        guard let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              receipt["accepted"] as? Bool == true else { throw ClientError.receiptMismatch }
        if queuedEventID == ticket.eventID { queuedEventID = nil }
        return .terminal
    }
}

// ===========================================================================
// 人类轮次「领取被拒」的**具名**判定（纯函数：只用标准库、无 I/O）。
//
// 为什么需要这一块：`agent_loop_claim` 被拒时只回 `{"claimed":false}`，**不带任何
// code 字段**（services/gmgn-taskd/src/agent_scheduler.rs 的 `agent_loop_claim`
// 分支：`if blocked || executing { json!({"claimed":false}) }`）。所以"被什么挡住"
// 只能由宿主用自己的只读快照算出来：既有路由 `agent_loop_read` 返回 config +
// events，`humanClaimRefusalEvidence` 把它读成下面这份证据。
//
// 单独立块、并保持自包含的理由：`tools/test-resident-human-claim-refusal.swift`
// 逐字抽这一段单独编译，再注入"改回旧行为"的变体要求变红。块内不要引用本文件
// 其它类型、不要 import。
// >>> resident-human-claim-refusal
/// 领取被拒时的只读证据：全部来自 `agent_loop_read`，一个字都不猜。
struct ResidentHumanClaimEvidence: Equatable {
    /// 本批事件 id（只用于把权威行折进证据，不是判定依据）。
    var ourEventID = ""
    /// 权威 config 里的可用性/装修标记：缺省按"可用"算 —— 宁可说"不知道"，
    /// 也不凭空误报"被挡住了"。
    var available = true
    var editing = false
    /// `state ∈ {claimed, cancel_requested}`：真正在飞、会挡住**所有**领取的回合。
    var executing = 0
    /// `state == 'unknown'`：遗留未确认回合。daemon 侧已把它从"在飞"里剔除
    /// （与 `agent_dsh_stale_unconfirmed_tools` 同款收窄），它**不再挡领取**，
    /// 只作为"这里曾经卡住"的旁证带上。
    var staleUnconfirmed = 0
    /// 本批 eventID 在权威里的状态；nil = 权威里没有这一行。
    var ourEventState: String?
    /// 别的 human 事件仍 pending：daemon 的领取循环对 human 是 `break`，
    /// 这一条会挡住本批。
    var otherPendingHuman = 0
}

/// 具名结论：`code` 是稳定机读码（与 daemon / `agent_dsh` 的命名同族），
/// `waiting` 是能直接给用户看的「在等什么」。
struct ResidentHumanClaimRefusal: Equatable {
    let code: String
    let waiting: String

    /// 还在等：消息没丢、也没失败 —— 界面用它替代沉默。
    func waitingNotice(attempts: Int) -> String {
        "\(waiting)；消息仍在队列里，正在自动重试（第 \(attempts) 次）"
    }

    /// 超时：给出具名失败，并说清消息还在不在、还能怎么办。
    func namedFailure(waitedSeconds: Int, attempts: Int) -> String {
        "消息还没送达：\(waiting)（码 \(code)）；已连续等待 \(waitedSeconds) 秒、重试 \(attempts) 次。"
            + "消息仍在队列里，会继续重试；你也可以再发一条。"
    }
}

/// 把 `agent_loop_read` 的一行事件折进证据（纯函数 ⇒ 可逐字注入回归）。
func residentHumanClaimEvidenceFoldingEvent(_ evidence: inout ResidentHumanClaimEvidence,
                                            eventID: String?, state: String?, kind: String?) {
    guard let state else { return }
    switch state {
    case "claimed", "cancel_requested": evidence.executing += 1
    case "unknown": evidence.staleUnconfirmed += 1
    default: break
    }
    guard let eventID else { return }
    if eventID == evidence.ourEventID {
        evidence.ourEventState = state
    } else if state == "pending", kind == "human" {
        evidence.otherPendingHuman += 1
    }
}

/// 判定顺序 = daemon 的挡人顺序：先 config 的 blocked，再"在飞"，最后才是本批事件本身。
func residentHumanClaimRefusal(_ evidence: ResidentHumanClaimEvidence) -> ResidentHumanClaimRefusal {
    if !evidence.available {
        return ResidentHumanClaimRefusal(code: "agent_loop_unavailable", waiting: "空间服务当前不可用")
    }
    if evidence.editing {
        return ResidentHumanClaimRefusal(code: "agent_loop_editing", waiting: "正在装修，居民轮次暂不领取")
    }
    if evidence.executing > 0 {
        return ResidentHumanClaimRefusal(code: "agent_loop_turn_in_flight",
            waiting: "上一轮尚未结算（还有 \(evidence.executing) 个回合在进行中）")
    }
    if evidence.ourEventState == "unknown" {
        return ResidentHumanClaimRefusal(code: "agent_loop_stale_unconfirmed_turns",
            waiting: "这批消息被记为未确认，不能重复发送")
    }
    if evidence.otherPendingHuman > 0 {
        return ResidentHumanClaimRefusal(code: "agent_loop_prior_human_event_pending",
            waiting: "队列里还有 \(evidence.otherPendingHuman) 条更早的消息没有结算")
    }
    if let state = evidence.ourEventState, state != "pending" {
        return ResidentHumanClaimRefusal(code: "agent_loop_event_not_pending",
            waiting: "这批消息还在等上一次领取的结果，没有重复发送")
    }
    if evidence.ourEventState == nil {
        return ResidentHumanClaimRefusal(code: "agent_loop_event_missing",
            waiting: "空间服务里找不到这批消息的记录")
    }
    return ResidentHumanClaimRefusal(code: "agent_loop_claim_refused", waiting: "上一轮尚未结算")
}

/// 连续被拒多久之后必须给出**具名失败**（秒）：超过它就不再只是沉默重试。
let residentHumanClaimNamedFailureSeconds: Double = 15
/// 具名失败与具名日志的最小重复间隔（秒）：可见，但不每秒刷屏。
let residentHumanClaimReportIntervalSeconds: Double = 30
// <<< resident-human-claim-refusal
