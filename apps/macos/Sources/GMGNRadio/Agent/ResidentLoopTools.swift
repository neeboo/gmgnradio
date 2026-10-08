import Foundation
import CoreFoundation

private enum ControlFlow: Error {
    case invalidPlanField(String)
}

/// A lease scoped to one model turn. Intent control never bypasses world tools or commits
/// resource/activity facts. In particular, `completed` is only the resident's plan status.
/// 宿主注入的居民自身真实状态（来自 WorldAgentContext / StageAvatarRuntime）。
/// 数据由宿主在每次工具调用时快照，模型不能从记忆生成或修改它。
struct ResidentSelfState: Codable, Equatable, Sendable {
    var space: String?
    var position: [Double]?
    var yawDegrees: Double?
    var avatarFormat: String?
    var activityID: String?
    var activityPhase: String?
    var heldPropID: String?
}

@MainActor
final class ResidentLoopTools {
    static let names: Set<String> = ["read_resident_state", "update_resident_intent"]
    static let schemas: [[String: Any]] = [
        [
            "name": "read_resident_state",
            "description": "读取居民自身真实状态（所在空间、坐标朝向、当前角色、活动阶段、手持物件）、当前意图与计划步骤、推进条件、最近环境事件及人类引导的交付状态。意图是模型计划，不是经过工具确认的世界事实；自身状态是宿主注入的真实快照。交付未确认的人类信息不得自动重复执行。随附的模型轮次统计（modelTurnsStarted/backgroundModelTurnsStarted/failedModelTurns/cancelledModelTurns/backgroundTurnsInLastHour/backgroundTurnsPerHour）只表示本循环实例会话内真正发起、失败与取消的模型轮次，不是 HTTP 请求数、Token 用量或计费数据；统计随该 ResidentAgentLoop 实例存活，不跨重启、也不跨实例重建保留；后台预算由宿主在运行时设置，不写入记忆或其他持久存储。",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
        ],
        [
            "name": "update_resident_intent",
            "description": "记录当前意图、计划步骤和推进条件，或安排等待。摘要需保留未完成用户委托；completed 只代表意图结束，实际行动仍须依赖正式工具结果。current_step 只能引用当前可用活动与对象，执行仍通过正式工具；advance_when 写明等待什么事实。已被用户停止的意图需本轮人类明确要求恢复、替换或结束，并设置 resume_paused_intent=true 才能更新；普通问候不恢复旧意图。成功更新后可无文字结束本轮。省略的计划字段保持原值，传空字符串清除。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "summary": ["type": "string", "minLength": 1, "maxLength": 2000],
                    "status": ["type": "string", "enum": ["active", "waiting_user", "waiting_event", "completed"]],
                    "wake_after_seconds": ["type": "number", "description": "等待多少秒后自动醒来。允许范围 1–86400 秒（含两端），超出范围或不是有限数字会被拒绝，需要重新给一个范围内的秒数。"],
                    "resume_paused_intent": ["type": "boolean", "description": "默认 false。仅本轮人类明确要求恢复、替换或结束已暂停意图时设为 true。"],
                    "goal": ["type": "string", "maxLength": 500, "description": "稳定目标；省略保持原值，空串清除。"],
                    "current_step": ["type": "string", "maxLength": 500, "description": "下一步要执行或验证的具体安排，只能引用当前可用活动与对象；省略保持原值，空串清除。"],
                    "next_steps": ["type": "array", "items": ["type": "string"], "maxItems": 8, "description": "之后的候选步骤；省略保持原值，空数组清除。"],
                    "advance_when": ["type": "string", "maxLength": 500, "description": "推进条件：等待什么事实或事件；省略保持原值，空串清除。"],
                    "adjust_reason": ["type": "string", "maxLength": 500, "description": "本次修订的原因，须引用正式工具结果或观察。"],
                ],
                "required": ["summary", "status"], "additionalProperties": false,
            ],
        ],
    ]

    private let loop: ResidentAgentLoop
    private let runID: UUID
    private let selfState: () -> ResidentSelfState?

    init(loop: ResidentAgentLoop, runID: UUID,
         selfState: @escaping () -> ResidentSelfState? = { nil }) {
        self.loop = loop
        self.runID = runID
        self.selfState = selfState
    }

    var allowsSilentCompletion: Bool { loop.allowsSilentCompletion(runID: runID) }

    func handle(name: String, argumentsJSON: Data) async -> (data: Data, isError: Bool) {
        guard loop.isCurrent(runID: runID) else { return failure("stale_resident_run", "本轮居民思考已结束或被停止") }
        guard Self.names.contains(name) else { return failure("tool_not_allowed", "未开放这个居民工具") }
        guard let arguments = (try? JSONSerialization.jsonObject(with: argumentsJSON)) as? [String: Any] else {
            return failure("invalid_arguments", "参数需要是 JSON 对象")
        }
        if name == "read_resident_state" {
            guard arguments.isEmpty else { return failure("invalid_arguments", "读取居民状态无需参数") }
        } else {
            var delay: Double?
            if let rawDelay = arguments["wake_after_seconds"] {
                guard let number = rawDelay as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID() else {
                    return failure("invalid_arguments", "唤醒时间需为秒数")
                }
                delay = number.doubleValue
            }
            var resumePausedIntent = false
            if let rawResume = arguments["resume_paused_intent"] {
                guard let number = rawResume as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    return failure("invalid_arguments", "恢复暂停意图标记需为布尔值")
                }
                resumePausedIntent = number.boolValue
            }
            let planKeys = ["goal", "current_step", "next_steps", "advance_when", "adjust_reason"]
            guard Set(arguments.keys).isSubset(of: ["summary", "status", "wake_after_seconds", "resume_paused_intent"] + planKeys),
                  let summary = arguments["summary"] as? String,
                  let rawStatus = arguments["status"] as? String,
                  let status = ResidentAgentLoop.IntentStatus(rawValue: rawStatus) else {
                return failure("invalid_arguments", "请提供合法的意图摘要和状态")
            }
            func planTextOptional(_ key: String) throws -> String?? {
                guard let raw = arguments[key] else { return nil }
                guard let text = raw as? String, text.count <= 500 else {
                    throw ControlFlow.invalidPlanField(key)
                }
                return .some(text)
            }
            var nextSteps: [String]??
            if let raw = arguments["next_steps"] {
                guard let entries = raw as? [Any], entries.count <= 8,
                      let texts = entries.compactMap({ $0 as? String }) as [String]?, texts.count == entries.count,
                      texts.allSatisfy({ $0.count <= 500 }) else {
                    return failure("invalid_arguments", "next_steps 需为最多 8 条、每条 500 字符以内的字符串数组")
                }
                nextSteps = .some(texts)
            } else { nextSteps = nil }
            do {
                func planText(_ key: String) throws -> String? {
                    // nil = 保持原值；.some(nil) = 清除；.some(.some(text)) = 设置。
                    let optional = try planTextOptional(key)
                    return optional ?? nil
                }
                let plan = ResidentAgentLoop.IntentPlanRevision(
                    goal: try planText("goal"),
                    currentStep: try planText("current_step"),
                    nextSteps: nextSteps.flatMap { $0 },
                    advanceWhen: try planText("advance_when"),
                    adjustReason: try planText("adjust_reason"),
                    source: nil)
                try await loop.updateIntent(summary: summary, status: status, wakeAfterSeconds: delay,
                    runID: runID, resumePausedIntent: resumePausedIntent, plan: plan)
            } catch ControlFlow.invalidPlanField(let key) {
                return failure("invalid_arguments", "\(key) 需为 500 字符以内的字符串")
            } catch { return failure("invalid_intent", error.localizedDescription) }
        }
        struct Response: Encodable {
            let ok = true
            let intentIsVerifiedWorldFact = false
            let selfState: ResidentSelfState?
            let residentState: ResidentAgentLoop.Snapshot
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = (try? encoder.encode(Response(selfState: selfState(), residentState: loop.snapshot))) ?? Data("{}".utf8)
        return (data, false)
    }

    private func failure(_ code: String, _ message: String) -> (data: Data, isError: Bool) {
        let object: [String: Any] = ["ok": false, "error": ["code": code, "message": message]]
        return ((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8), true)
    }
}
