// Run from repository root. No app, GPU, network or user settings are opened.
//
// 需求：**启动默认进「空间」，而不是「播放器」。**
//
// 产品里"播放器"是 Unity 的初始呈现面（点阵 + 歌词），"空间"是世界呈现面；
// 启动时由 `UnityMediaHost.startExistingWorldSession()` 那一次世界进入事务决定。
// 这个事务以前有三种"一次失败就整场会话留在播放器"的结局，而且这三种都不是
// 用户偏好：权威还没起来（unavailable）、权威里还没有这个世界（record missing）、
// 载入期间世界状态前进（activation failed）。
//
// 这里钉住的就是"默认"这条语义：
//   1. 启动仍然在 init 里无条件请求空间（不是可选行为）；
//   2. 没有用户空间状态（权威无记录）时，一次性导入只读预像后**继续进空间**；
//   3. 启动失败不会被当成用户偏好，而是按常量预算**有界重试**；
//   4. 预算用尽时仍然给出真实失败（红字 + 日志），不静默假装成功、不无限重试。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let hostURL = root.appendingPathComponent("apps/macos/UnityHost/UnityMediaHost.swift")
let host = try String(contentsOf: hostURL, encoding: .utf8)

func fail(_ reason: String) -> Never {
    print("FAIL: \(reason)")
    exit(1)
}
func require(_ value: Bool, _ reason: String) {
    if !value { fail(reason) }
}
/// 取一段声明的花括号正文（与 `tools/test-stage-control-actions.swift` 同一口径）。
func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else {
        fail("missing production declaration: \(signature)")
    }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fail("unbalanced declaration: \(signature)")
}
/// 去掉注释，避免注释里的词满足断言。
func code(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard let comment = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<comment.lowerBound])
    }.joined(separator: "\n")
}

let source = code(host)
let startup = declaration("private func startExistingWorldSession() {", in: source)
let activate = declaration("private func completeWorldSelection(", in: source)
let retry = declaration("private func scheduleStartupSpaceRetry(", in: source)
let seed = declaration("private func importDefaultSpaceRecord(", in: source)

// 1. 启动请求空间是 init 的默认行为，不是可选开关。
let initBody = declaration("init(root: URL, defaults suppliedDefaults: UserDefaults)", in: source)
require(initBody.contains("startExistingWorldSession()"),
        "启动必须无条件请求默认空间（init 里的 startExistingWorldSession()）")

// 2. 没有用户空间状态（权威无记录）时：一次性导入只读预像 → 重新读回 → 继续进空间。
guard let missing = startup.range(of: "world_authority_record_missing") else {
    fail("启动读取必须仍然区分 record_missing 这种失败")
}
let seedCall = startup.range(of: "importDefaultSpaceRecord(package: package, endpoint: endpoint)")
require(seedCall != nil, "权威没有记录时必须先做一次性默认空间导入，而不是直接退回播放器")
require(seedCall!.lowerBound < missing.lowerBound, "导入必须发生在判定 record_missing 之前")
guard let reseed = startup.range(of: "if record == nil, importDefaultSpaceRecord("),
      let reread = startup.range(of: "record = try await Task.detached", range: reseed.upperBound..<startup.endIndex) else {
    fail("导入之后必须重新读回权威记录，才能继续 prepare/activate")
}
require(reread.lowerBound > reseed.upperBound, "导入后必须重新读取记录")
// 只读、不覆盖、不凭空造世界：走的是既有的 AuthorityWorldStatePersistence 一次性导入。
require(seed.contains("AuthorityWorldStatePersistence(manifest: package.manifest"),
        "默认空间导入必须复用既有的一次性只读预像导入")
require(seed.contains("LegacyWorldStatePreImage(archive: archive, candidateURLs: candidates)"),
        "默认空间导入必须走只读预像（不写第二份真相）")
// 预像的真实位置是产品身份 `ai.gmgn.radio`：RenderHost 模块编译进来的
// `ProductIdentity` 是 fixture 身份（`ai.gmgn.gpui-probe.render-host`），
// 只按它找会永远找不到预像（实测：Unity 产品把 stateFileURL 解析成
// `…/ai.gmgn.gpui-probe.render-host/LivingWorld/marble-living-cabin/1.2.2/state.json`，
// 生产机上只有 `ai.gmgn.radio/.../1.2.0/state.json`）。
require(seed.contains("Self.legacyProductPreImageURLs(package: package.manifest, base: root)"),
        "默认空间导入必须按产品身份 ai.gmgn.radio 再找一遍预像")
require(source.contains("static let legacyProductIdentity = \"ai.gmgn.radio\""),
        "预像的产品身份必须是具名常量 ai.gmgn.radio")
let legacyHelper = declaration("static func legacyProductPreImageURLs(", in: source)
require(legacyHelper.contains("\"LivingWorld\""), "产品身份下的预像路径必须仍是 LivingWorld/<packageID>/<version>/state.json")
require(legacyHelper.contains("sanitizedPackageVersionDirectory(package.packageVersion)"),
        "必须优先当前包版本的 state.json")
require(legacyHelper.contains("contentModificationDate"), "其余版本必须按时间从新到旧，而不是猜版本号")
require(legacyHelper.contains("var seen = Set<String>()"), "候选路径必须去重")

// 3. 启动失败 = 默认路径的有界重试，而不是"用户偏好播放器"。
require(retry.contains("worldSession == nil"), "只有还没有任何世界会话的启动路径才重试")
require(retry.contains("startupSpaceAttempts < Self.startupSpaceAttemptLimit"), "重试必须有常量预算")
require(retry.contains("Task.sleep(for: Self.startupSpaceRetryDelay)"), "重试必须有间隔")
require(retry.contains("self.startExistingWorldSession()"), "重试必须重跑同一个启动事务")
guard let limitLine = source.range(of: "private static let startupSpaceAttemptLimit") else {
    fail("重试预算必须是具名常量")
}
let limitLineEnd = source[limitLine.lowerBound...].firstIndex(of: "\n") ?? source.endIndex
let limitText = String(source[limitLine.lowerBound..<limitLineEnd])
guard let digits = limitText.split(separator: "=").last?.trimmingCharacters(in: .whitespaces),
      let limitValue = Int(digits) else {
    fail("重试预算必须是整数字面量：\(limitText)")
}
require(limitValue >= 1 && limitValue <= 6, "重试预算必须在 1...6 的有界范围内，实际 \(limitValue)")
// 启动读取失败后先排重试，再落失败投影（红字 + 日志）。
guard let schedule = startup.range(of: "if scheduleStartupSpaceRetry(failureCode: failureCode) { return }"),
      let failedPhase = startup.range(of: "\"phase\": \"failed\", \"code\": failureCode") else {
    fail("启动失败路径必须同时保留有界重试与真实失败投影")
}
require(schedule.lowerBound < failedPhase.lowerBound, "必须先把重试排上，再决定是否对外报失败")
require(startup.contains("NSLog(\"[UnityMediaHost] space startup unavailable: %@; audio/chat retained\""),
        "预算用尽后必须仍然如实报失败（日志）")

// 4. 载入期间权威前进（activation failed）同样属于启动竞态，不留在播放器。
guard let activateFailure = activate.range(of: "world_authority_activation_failed") else {
    fail("激活失败必须仍然具名")
}
let activateRetry = activate.range(of: "retryStartupSpaceOrPublishFailure(\"world_authority_activation_failed\")")
require(activateRetry != nil, "载入期间状态前进时必须按启动竞态有界重试")
require(activateRetry!.lowerBound > activateFailure.lowerBound, "重试必须挂在真实的激活失败分支上")
require(activate.contains("if worldSession == nil {"), "显式切换世界（已有会话）不进入启动重试")
let failureHandler = declaration("private func retryStartupSpaceOrPublishFailure(", in: source)
require(failureHandler.contains("if scheduleStartupSpaceRetry(failureCode: failureCode) { return true }"),
        "失败处理必须调用原有的有界重试")
require(failureHandler.contains("publishStartupSpaceFailure(failureCode)"),
        "重试耗尽后必须发布真实失败")

print("PASS: launch default is the space (one-time default-space import + bounded startup retry, honest failure preserved)")
