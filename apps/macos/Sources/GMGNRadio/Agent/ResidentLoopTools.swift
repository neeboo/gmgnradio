import Foundation
import CoreFoundation

/// A lease scoped to one model turn. Intent control never bypasses world tools or commits
/// resource/activity facts. In particular, `completed` is only the resident's plan status.
@MainActor
final class ResidentLoopTools {
    static let names: Set<String> = ["read_resident_state", "update_resident_intent"]
    static let schemas: [[String: Any]] = [
        [
            "name": "read_resident_state",
            "description": "读取当前居民意图、等待状态、最近环境事件及人类引导的交付状态。意图是模型计划，不是经过工具确认的世界事实。交付未确认的人类信息不得自动重复执行。",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
        ],
        [
            "name": "update_resident_intent",
            "description": "记录当前意图和进展，或安排等待。摘要需保留未完成用户委托；completed 只代表意图结束，实际行动仍须依赖正式工具结果。已被用户停止的意图需本轮人类明确要求恢复、替换或结束，并设置 resume_paused_intent=true 才能更新；普通问候不恢复旧意图。成功更新后可无文字结束本轮。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "summary": ["type": "string", "minLength": 1, "maxLength": 2000],
                    "status": ["type": "string", "enum": ["active", "waiting_user", "waiting_event", "completed"]],
                    "wake_after_seconds": ["type": "number", "minimum": 1, "maximum": 86400],
                    "resume_paused_intent": ["type": "boolean", "description": "默认 false。仅本轮人类明确要求恢复、替换或结束已暂停意图时设为 true。"],
                ],
                "required": ["summary", "status"], "additionalProperties": false,
            ],
        ],
    ]

    private let loop: ResidentAgentLoop
    private let runID: UUID

    init(loop: ResidentAgentLoop, runID: UUID) {
        self.loop = loop
        self.runID = runID
    }

    var allowsSilentCompletion: Bool { loop.allowsSilentCompletion(runID: runID) }

    func handle(name: String, argumentsJSON: Data) -> (data: Data, isError: Bool) {
        guard loop.isCurrent(runID: runID) else { return failure("stale_resident_run", "本轮居民思考已结束或被停止") }
        guard Self.names.contains(name) else { return failure("tool_not_allowed", "未开放这个居民工具") }
        guard let arguments = (try? JSONSerialization.jsonObject(with: argumentsJSON)) as? [String: Any] else {
            return failure("invalid_arguments", "参数需要是 JSON 对象")
        }
        if name == "read_resident_state" {
            guard arguments.isEmpty else { return failure("invalid_arguments", "读取居民状态无需参数") }
        } else {
            guard Set(arguments.keys).isSubset(of: ["summary", "status", "wake_after_seconds", "resume_paused_intent"]),
                  let summary = arguments["summary"] as? String,
                  let rawStatus = arguments["status"] as? String,
                  let status = ResidentAgentLoop.IntentStatus(rawValue: rawStatus) else {
                return failure("invalid_arguments", "请提供合法的意图摘要和状态")
            }
            var delay: Double?
            var resumePausedIntent = false
            if let rawResume = arguments["resume_paused_intent"] {
                guard let number = rawResume as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    return failure("invalid_arguments", "恢复暂停意图标记需为布尔值")
                }
                resumePausedIntent = number.boolValue
            }
            if let rawDelay = arguments["wake_after_seconds"] {
                guard let number = rawDelay as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID() else {
                    return failure("invalid_arguments", "唤醒时间需为秒数")
                }
                delay = number.doubleValue
            }
            do { try loop.updateIntent(summary: summary, status: status, wakeAfterSeconds: delay, runID: runID, resumePausedIntent: resumePausedIntent) }
            catch { return failure("invalid_intent", error.localizedDescription) }
        }
        struct Response: Encodable {
            let ok = true
            let intentIsVerifiedWorldFact = false
            let residentState: ResidentAgentLoop.Snapshot
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = (try? encoder.encode(Response(residentState: loop.snapshot))) ?? Data("{}".utf8)
        return (data, false)
    }

    private func failure(_ code: String, _ message: String) -> (data: Data, isError: Bool) {
        let object: [String: Any] = ["ok": false, "error": ["code": code, "message": message]]
        return ((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8), true)
    }
}
