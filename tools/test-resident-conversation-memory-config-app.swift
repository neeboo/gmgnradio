// 居民长期记忆 App 配置/后台状态呈现的离线行为核对（issue #2/#3 回归）。
//
// 从真实 GMGNRadioApp.swift 提取（非重写）applyResidentMemoryConfigurationIfNeeded /
// refreshResidentMemoryConfigurationIfNeeded / presentResidentMemoryBackgroundStatus /
// showResidentMemoryNotice / flushResidentMemoryNoticeIfNeeded 五个生产方法体，放进
// fixture App 类后与真实 ResidentStateClient/ResidentMemoryClient/ResidentConversationMemory/
// ResidentMemoryConfiguration 一起编译运行（CPU Swift6，受控 fake transport，
// 不接 daemon/真实服务/UserDefaults）。因此方法体用到的 status/orchestration/
// 配置真实声明与签名都被原样类型检查。覆盖：
//   - 类型回归：residentConversationMemory 在 App 是非 Optional lazy，fixture 的
//     App 也以真实的非 Optional ResidentConversationMemory 属性镜像——若生产代码
//     退回 `guard let memory = residentConversationMemory`，本文件将编译失败，
//     不可能用 Optional stub 掩盖类型错误；
//   - configured=true 且 orchestration.failed：轮询呈现后台失败 + 稳定错误码，
//     不重复 configure、不每轮刷屏；恢复（idle/running）后清理旧提示一次；
//   - orchestration.unconfigured：可见「暂不可用、内容仍在易失缓冲」安全文案；
//   - 启动时聊天表面全 nil + environmentIncomplete=true：提示缓存但不显示，表面
//     可用后 flush 补显示一次、不再每 5s 重复刷屏；
//   - 缺显式环境配置与 daemon 重启（configured 丢失）后按环境变量重配的行为；
//   - 缺配置后仍搭 30 秒节流继续轮询（不再永久停查）；in-flight 防重，force
//     也不得绕过；
//   - daemon 侧被外部配好（configured=true）后，可见行为断言：nil orchestration /
//     idle / pending / running 时聊天表面最后一行不再是「缺少显式配置」，允许一条
//     只表示配置已恢复/已就绪的状态行（不代表写入完成）；failed/unconfigured 时
//     最后一行必须仍是对应故障状态，绝不被恢复/成功文案覆盖；真实 30 秒节流到点
//     后的下一轮轮询保持去重；不重复 configure、不刷屏；
//   - 恢复发生在聊天表面建立之前：flush 补显示时绝不把过期缺配置文案重新显示。
//   - configure 抛错留下的「长期记忆后台配置失败」也是配置故障：daemon 之后被
//     外部配好（configured=true 且后台 idle/nil）时必须清掉过期提示、换成只表示
//     配置已恢复的状态行；failed/unconfigured 仍优先，绝不被恢复文案覆盖；
//   - await 期间换空间/换绑代次（scope + residentMemoryBindingGeneration）：旧
//     memory_status/configure 结果（failed、成功、抛错）绝不提交到新空间的
//     configured 摘要、后台提示或缓存；configure 悬挂时取消同样不提交；受控
//     transport 可挂起，在真实交错点切换后才放行。
//   - configure 抛错后 daemon 直接被外部配好（orchestration 缺省 nil 或直接
//     failed）的最短路径：过期配置失败提示被清掉、真实后台失败仍最后呈现；
//   - memory_status 悬挂后仅换 scope（代次不变，旧返回 idle）或仅换代次
//     （scope 不变，旧返回 failed）：新世界预设的 configured/提示/noticeShown/
//     backgroundIssue 绝不被旧返回清掉或覆盖；status 悬挂取消/抛错亦不改新状态；
//   - 第二个 embedding configure 悬挂后过期或取消：绝不提交「已就绪」、不重试；
//   - 受控 transport 可按第几次同名调用挂起；waitForSuspension 超时必须显式
//     check 判负，交错未命中绝不静默变绿。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appSourceURL = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift")
let source = try String(contentsOf: appSourceURL, encoding: .utf8)

func declaration(_ signature: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound else {
        print("FAIL: missing declaration \(signature)")
        exit(1)
    }
    guard let open = source[start...].firstIndex(of: "{") else {
        print("FAIL: unterminated declaration \(signature)")
        exit(1)
    }
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    print("FAIL: unbalanced braces in \(signature)")
    exit(1)
}

let applyConfig = declaration("private func applyResidentMemoryConfigurationIfNeeded() async {")
let presentBackground = declaration("private func presentResidentMemoryBackgroundStatus(")
let showNotice = declaration("private func showResidentMemoryNotice(")
let flushNotice = declaration("private func flushResidentMemoryNoticeIfNeeded()")
// refresh 的 30 秒节流 + in-flight 防重也必须以真实方法体参与行为核对（不重写）：
// 首次缺 env 后是否仍轮询、force 是否绕过 in-flight，都由真实代码决定。
let refreshConfig = declaration("private func refreshResidentMemoryConfigurationIfNeeded(force: Bool = false) {")

// 类型回归的结构性核对：residentConversationMemory 是非 Optional lazy；fixture 的
// App 以同名真实类型 let 镜像，apply 体内任何 guard-let 都会编译失败。
guard source.contains("private lazy var residentConversationMemory: ResidentConversationMemory = {"),
      !source.contains("private var residentConversationMemory: ResidentConversationMemory?") else {
    print("FAIL: residentConversationMemory must stay a non-Optional lazy property in production")
    exit(1)
}
guard !applyConfig.contains("guard let memory = residentConversationMemory"),
      applyConfig.contains("let memory = residentConversationMemory") else {
    print("FAIL: apply must not optional-bind the non-Optional residentConversationMemory")
    exit(1)
}
guard applyConfig.contains("presentResidentMemoryBackgroundStatus(status.orchestration)"),
      presentBackground.contains("case .failed:"),
      presentBackground.contains("case .unconfigured:"),
      presentBackground.contains("orchestration.lastError"),
      showNotice.contains("residentMemoryConfigurationNoticeShown"),
      flushNotice.contains("residentMemoryConfigurationNoticeShown") else {
    print("FAIL: configured-true path must surface orchestration and defer shown-flag dedup")
    exit(1)
}

func publicized(_ body: String) -> String {
    body.replacingOccurrences(of: "private func ", with: "func ")
}

let harness = #"""
import Foundation

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

// MARK: - 真实 memory_status fixture JSON

func statusFixture(
    compaction: Bool, embedding: Bool,
    orchestration: ResidentStateJSON? = nil
) -> [String: ResidentStateJSON] {
    var response: [String: ResidentStateJSON] = [
        "configured": .object([
            "compaction": .bool(compaction),
            "embedding": .bool(embedding),
        ]),
        "memory": .null,
        "pendingTurns": .number(0),
    ]
    if let orchestration { response["orchestration"] = orchestration }
    return response
}

func orchestrationFixture(state: String, lastError: String?) -> ResidentStateJSON {
    var object: [String: ResidentStateJSON] = ["state": .string(state)]
    if let lastError {
        object["lastError"] = .string(lastError)
    } else {
        object["lastError"] = .null
    }
    return .object(object)
}

/// 受控记忆 transport（与 adapter fixture 同形）：memory_status 按队列逐次
/// 返回 fixture；memory_configure 记录调用并回 configured:true。不接 daemon。
final class StatusTransportStub: ResidentStateTransport, @unchecked Sendable {
    private(set) var recorded: [(method: String, params: [String: ResidentStateJSON])] = []
    var statusResponses: [[String: ResidentStateJSON]] = []
    var lastStatus = statusFixture(compaction: false, embedding: false)
    /// 可控 memory_configure 抛错：置真后每次 configure 都在 transport 层抛
    /// daemon 错误（真实 transport 失败的形状），用于核对 configure 抛错留下
    /// 的「配置失败」提示是否会被后续外部恢复清掉。
    var configureThrows = false

    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        recorded.append((method, params))
        switch method {
        case "memory_status":
            if !statusResponses.isEmpty { return statusResponses.removeFirst() }
            return lastStatus
        case "memory_configure":
            if configureThrows { throw ResidentStateError.daemon("memory_configure_unavailable") }
            return ["configured": .bool(true)]
        default:
            throw ResidentStateError.daemon("unsupported_fixture_method")
        }
    }

    var configureCalls: [[String: ResidentStateJSON]] {
        recorded.filter { $0.method == "memory_configure" }.map(\.params)
    }

    var statusCount: Int { recorded.filter { $0.method == "memory_status" }.count }
}

/// 可挂起的受控记忆 transport：把指定 method 的调用挂在 continuation 上，直到
/// 测试显式放行。用于「await 期间换空间/换代次」与「configure 悬挂时取消」的
/// 真实交错核对（不接 daemon、不复制生产逻辑）。放行后按 `outcome` 返回或抛出。
/// 挂起可按 method（`suspendedMethods`，命中一次）或按第几次同名调用
/// （`suspendOnCallIndex`，1-based，用于精确挂住第二个 memory_configure），
/// 命中一次后即清除，后续同名调用立即返回。
@MainActor
final class SuspendingStatusTransport: ResidentStateTransport, @unchecked Sendable {
    private(set) var recorded: [(method: String, params: [String: ResidentStateJSON])] = []
    /// 需要挂起的 method；命中一次后移除，后续同名调用立即返回。
    var suspendedMethods: Set<String> = []
    /// 按「第几次同名调用」挂起（1-based），与 suspendedMethods 取并集。
    var suspendOnCallIndex: [String: Int] = [:]
    /// 放行后本次调用的结果（nil → 走 defaultResponse）。
    var outcome: Result<[String: ResidentStateJSON], Error>?
    /// 未挂起时 memory_status 的默认响应。
    var lastStatus = statusFixture(compaction: false, embedding: false)
    /// 已进入挂起的调用次数（测试据此确认交错点已到）。
    private(set) var suspendedCount = 0
    private var methodCallCounts: [String: Int] = [:]
    private var pendingResume: CheckedContinuation<Void, Never>?
    /// resume() 早于真正挂起时置真：下一次挂起点直接跳过等待，避免交错未命中时
    /// 测试永久挂死；交错是否命中由 waitForSuspension 的显式 check 判负。
    private var resumeRequested = false

    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        recorded.append((method, params))
        methodCallCounts[method, default: 0] += 1
        let indexHit = suspendOnCallIndex[method] == methodCallCounts[method]
        if suspendedMethods.contains(method) || indexHit {
            suspendedMethods.remove(method)
            suspendOnCallIndex[method] = nil
            suspendedCount += 1
            if resumeRequested {
                resumeRequested = false
            } else {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    pendingResume = continuation
                }
            }
            if let outcome {
                self.outcome = nil
                return try outcome.get()
            }
        }
        return try defaultResponse(method: method)
    }

    func resume() {
        if let continuation = pendingResume {
            pendingResume = nil
            continuation.resume()
        } else {
            resumeRequested = true
        }
    }

    func defaultResponse(method: String) throws -> [String: ResidentStateJSON] {
        switch method {
        case "memory_status": return lastStatus
        case "memory_configure": return ["configured": .bool(true)]
        default: throw ResidentStateError.daemon("unsupported_fixture_method")
        }
    }

    var configureCallCount: Int { recorded.filter { $0.method == "memory_configure" }.count }
}

/// 等一次被挂起的 transport 调用真正开始（MainActor 上协作让步，不真实等待）。
/// 返回是否真的命中了挂起点：调用方必须显式 check，绝不能在没命中交错时静默
/// 继续而让断言空跑成绿。
@discardableResult
@MainActor func waitForSuspension(_ transport: SuspendingStatusTransport) async -> Bool {
    for _ in 0..<10_000 {
        if transport.suspendedCount > 0 { return true }
        await Task.yield()
    }
    return false
}

@MainActor
final class FakeSurface {
    private(set) var statuses: [String] = []
    func showChatStatus(_ text: String) { statuses.append(text) }
    func showResidentChatStatus(_ text: String) { statuses.append(text) }
}

/// fixture 的 App：以真实的非 Optional ResidentConversationMemory 镜像生产属性
/// （绝不 stub 成 Optional 掩盖类型错误）；其余状态属性与方法体保持同名同形。
struct LoggerStub {
    func notice(_ message: String) {}
    func error(_ message: String) {}
    func warning(_ message: String) {}
}

@MainActor
final class App {
    let residentConversationMemory: ResidentConversationMemory
    let livingWorldLogger = LoggerStub()
    var liveCamWindowController: FakeSurface?
    var stageWindowController: FakeSurface?
    var residentMemoryConfigured: (compaction: Bool, embedding: Bool)?
    var residentMemoryConfigurationAttemptAt: Date?
    var residentMemoryConfigurationInFlight = false
    var residentMemoryEnvironmentIncomplete = false
    var residentMemoryConfigurationNotice: String?
    var residentMemoryConfigurationNoticeShown = false
    var residentMemoryBackgroundIssueShown = false
    var scopeForTest = ResidentStateScope(worldID: "cabin", residentScope: "resident")
    /// 镜像生产 residentMemoryBindingGeneration：换绑/换空间时推进，apply 在
    /// await 之后必须核对代次，旧结果不得落到新空间。
    var residentMemoryBindingGeneration = UUID()

    init(memory: ResidentConversationMemory) {
        residentConversationMemory = memory
    }

    /// 只读 scope stub（真实方法内部依赖世界上下文，属宿主而非本文件范围）。
    func currentResidentMemoryScope() -> ResidentStateScope { scopeForTest }

    \#(publicized(applyConfig))
    \#(publicized(refreshConfig))
    \#(publicized(presentBackground))
    \#(publicized(showNotice))
    \#(publicized(flushNotice))
}

// MARK: - 场景

@MainActor func scenarioConfiguredFailed() async {
    let transport = StatusTransportStub()
    transport.lastStatus = statusFixture(
        compaction: true, embedding: true,
        orchestration: orchestrationFixture(state: "failed", lastError: "memory_consolidation_failed")
    )
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    app.stageWindowController = FakeSurface()
    await app.applyResidentMemoryConfigurationIfNeeded()
    let live = app.liveCamWindowController!
    check(live.statuses.last?.contains("后台整理失败") == true,
          "configured+orchestration.failed surfaces the background failure")
    check(live.statuses.last?.contains("memory_consolidation_failed") == true,
          "failure notice shows the stable error code")
    check(live.statuses.last?.contains("易失缓冲") == true,
          "failure notice keeps the pending-volatile explanation (not durable)")
    check(app.residentMemoryConfigured?.compaction == true && app.residentMemoryConfigured?.embedding == true,
          "configured summary is kept")
    check(transport.configureCalls.isEmpty, "already-configured daemon is never re-configured")
    let shown = live.statuses.count
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.count == shown, "the same background failure is not re-shown each poll")
}

@MainActor func scenarioRecovery() async {
    let transport = StatusTransportStub()
    transport.statusResponses = [
        statusFixture(compaction: true, embedding: true,
                      orchestration: orchestrationFixture(state: "failed", lastError: "embedding_error")),
        statusFixture(compaction: true, embedding: true,
                      orchestration: orchestrationFixture(state: "idle", lastError: nil)),
        statusFixture(compaction: true, embedding: true,
                      orchestration: orchestrationFixture(state: "running", lastError: nil)),
    ]
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.last?.contains("后台整理失败") == true, "recovery scenario starts from a visible failure")
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.last?.contains("已恢复") == true,
          "recovery to healthy clears the old failure prompt once")
    let shown = live.statuses.count
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.count == shown, "steady healthy state stays silent after the recovery line")
    check(app.residentMemoryBackgroundIssueShown == false, "issue flag is cleared after recovery")
}

@MainActor func scenarioUnconfigured() async {
    let transport = StatusTransportStub()
    transport.lastStatus = statusFixture(
        compaction: true, embedding: true,
        orchestration: orchestrationFixture(state: "unconfigured", lastError: nil)
    )
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.last?.contains("暂不可用") == true,
          "orchestration.unconfigured is visible while daemon is configured")
    check(live.statuses.last?.contains("易失缓冲") == true,
          "unconfigured notice keeps the pending-volatile wording")
    check(transport.configureCalls.isEmpty, "unconfigured-with-configured summary never re-configures")
}

@MainActor func scenarioMissingEnvLateSurface() async {
    // 该场景以无 GMGN_MEMORY_* 环境运行：configured=false + env 缺失 → 缺配置提示
    // 只缓存不显示；聊天表面稍后出现时 flush 补显示一次，不永久不可见、不刷屏。
    let transport = StatusTransportStub()
    transport.lastStatus = statusFixture(compaction: false, embedding: false)
    let app = App(memory: ResidentConversationMemory(transport: transport))
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(app.residentMemoryEnvironmentIncomplete == true,
          "missing env marks the environment incomplete and stops re-querying")
    check(app.liveCamWindowController == nil && app.stageWindowController == nil,
          "no chat surface exists during startup check")
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    check(live.statuses.isEmpty, "notice is not shown before any surface exists")
    app.flushResidentMemoryNoticeIfNeeded()
    check(live.statuses.last?.contains("缺少显式配置") == true,
          "surface that appears later finally sees the missing-config notice")
    let shown = live.statuses.count
    app.flushResidentMemoryNoticeIfNeeded()
    check(live.statuses.count == shown,
          "the delayed notice is flushed exactly once, never every 5 s")
    check(transport.configureCalls.isEmpty, "missing env never attempts provider configuration")
}

@MainActor func scenarioMissingEnvSurfacePresent() async {
    let transport = StatusTransportStub()
    transport.lastStatus = statusFixture(compaction: false, embedding: false)
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.last?.contains("缺少显式配置") == true,
          "missing env with a live surface shows the notice immediately")
    let shown = live.statuses.count
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.count == shown, "identical missing-config notice is not re-shown")
    check(transport.configureCalls.isEmpty, "missing env never attempts provider configuration")
}

@MainActor func scenarioDaemonRestartReconfigure() async {
    // env 完整场景：daemon 重启后 configured=false → 按显式环境重配；已配置则不再
    // 重配；恢复后不残留失败提示。
    let transport = StatusTransportStub()
    transport.statusResponses = [
        statusFixture(compaction: false, embedding: false),
        statusFixture(compaction: true, embedding: true,
                      orchestration: orchestrationFixture(state: "idle", lastError: nil)),
        statusFixture(compaction: false, embedding: false),   // 模拟 daemon 重启丢失配置
        statusFixture(compaction: true, embedding: true,
                      orchestration: orchestrationFixture(state: "running", lastError: nil)),
    ]
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(transport.configureCalls.count == 2, "daemon restart with lost config re-configures both providers")
    let kinds = transport.configureCalls.compactMap { $0["kind"]?.stringValue }
    check(kinds == ["compaction", "embedding"], "re-configuration order is compaction then embedding")
    check(live.statuses.last?.contains("已就绪") == true, "successful configuration shows the ready notice")
    check(app.residentMemoryEnvironmentIncomplete == false, "complete env never sets the incomplete flag")
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(transport.configureCalls.count == 2, "configured daemon is not re-configured every poll")
    check(live.statuses.last?.contains("失败") == false, "healthy poll leaves no failure text")
    let shownBeforeRestart = live.statuses.count
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(transport.configureCalls.count == 4, "a second daemon restart is re-configured again")
    check(app.residentMemoryConfigured?.compaction == true && app.residentMemoryConfigured?.embedding == true,
          "configured summary reflects the re-configuration")
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.count == shownBeforeRestart,
          "already-shown ready line and healthy state stay silent afterwards")
}

/// refresh 真实方法体是 fire-and-forget Task：等它跑完（in-flight 落回 false）再断言。
/// 用 1ms 级让步，不制造真实 30 秒等待（节流窗口由 fixture 前移 attemptAt 模拟）。
@MainActor func settle(_ app: App) async {
    for _ in 0..<200 {
        if !app.residentMemoryConfigurationInFlight { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// 结构性核对：refresh 不能因 env 不完整而永久停查；节流与 in-flight 防重必须保留。
/// 恢复后的可见行为由 external-config-recovery / external-recovery-before-surface
/// 两个场景断言，不再绑死生产实现里的某一行赋值。
@MainActor func scenarioRefreshContract() async {
    check(!\#(refreshConfig.contains("!residentMemoryEnvironmentIncomplete")),
          "refresh must not permanently stop polling when the environment is incomplete")
    check(\#(refreshConfig.contains("!residentMemoryConfigurationInFlight")),
          "refresh must keep the in-flight guard so a forced call cannot run concurrently")
    check(\#(refreshConfig.contains("timeIntervalSince(last) < 30")),
          "refresh must keep the 30s throttle so polling never floods the daemon")
}

@MainActor func scenarioMissingEnvKeepsPolling() async {
    let transport = StatusTransportStub()
    transport.statusResponses = [
        statusFixture(compaction: false, embedding: false),
        statusFixture(compaction: false, embedding: false),
    ]
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    app.refreshResidentMemoryConfigurationIfNeeded(force: true)
    await settle(app)
    check(transport.statusCount == 1, "the first forced poll reads memory_status once")
    check(app.residentMemoryEnvironmentIncomplete == true,
          "missing env marks the environment incomplete")
    check(live.statuses.last?.contains("缺少显式配置") == true,
          "missing env shows the missing-config notice once")
    // 节流窗口内（attemptAt 刚被 refresh 写入）：不重复查询、不刷屏。
    app.refreshResidentMemoryConfigurationIfNeeded()
    await settle(app)
    check(transport.statusCount == 1, "a poll inside the 30s throttle window does not re-query")
    // fixture 前移 attemptAt 到 31 秒前（真实等待 30 秒被禁止）：缺 env 后仍应轮询，
    // 才能感知外部后来把 provider 配好。缺陷版本会在这里永久停查。
    app.residentMemoryConfigurationAttemptAt = Date(timeIntervalSinceNow: -31)
    app.refreshResidentMemoryConfigurationIfNeeded()
    await settle(app)
    check(transport.statusCount == 2,
          "polling continues after an incomplete environment once the throttle elapses")
    check(app.residentMemoryEnvironmentIncomplete == true,
          "still-missing env keeps the incomplete marker (no false recovery)")
    check(live.statuses.filter { $0.contains("缺少显式配置") }.count == 1,
          "the unchanged missing-config notice is never re-shown")
    check(transport.configureCalls.isEmpty, "missing env never attempts provider configuration")
}

/// daemon 被外部配好（configured=true）而本进程仍缺显式 env：聊天表面最后一行必须
/// 反映当前配置，而不是停留在过期「缺少显式配置」；failed/unconfigured 的最后一行
/// 必须仍是对应故障状态，绝不被恢复/成功文案覆盖。
@MainActor func externalRecoveryCase(orchestrationState: String?, label: String) async {
    let orchestration = orchestrationState.map {
        orchestrationFixture(state: $0,
                             lastError: $0 == "failed" ? "memory_consolidation_failed" : nil)
    }
    let missing = statusFixture(compaction: false, embedding: false)
    let recovered = statusFixture(compaction: true, embedding: true, orchestration: orchestration)
    let transport = StatusTransportStub()
    // 第三次同恢复态：验证真实 30 秒节流到点后的下一轮轮询不刷屏。
    transport.statusResponses = [missing, recovered, recovered]
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    app.refreshResidentMemoryConfigurationIfNeeded(force: true)
    await settle(app)
    check(app.residentMemoryEnvironmentIncomplete == true,
          "\(label): first missing-env poll marks the environment incomplete")
    check(live.statuses.last?.contains("缺少显式配置") == true,
          "\(label): first missing-env poll shows the missing-config notice")
    app.residentMemoryConfigurationAttemptAt = Date(timeIntervalSinceNow: -31)
    app.refreshResidentMemoryConfigurationIfNeeded()
    await settle(app)
    check(transport.statusCount == 2,
          "\(label): polling continues past the incomplete state once throttled")
    check(app.residentMemoryEnvironmentIncomplete == false,
          "\(label): external daemon configuration clears the incomplete marker")
    check(app.residentMemoryConfigurationNotice?.contains("缺少显式配置") != true,
          "\(label): external daemon configuration drops the stale missing-config notice")
    check(transport.configureCalls.isEmpty,
          "\(label): external recovery never re-configures providers")
    check(live.statuses.filter { $0.contains("缺少显式配置") }.count == 1,
          "\(label): recovered state never re-shows the missing-config notice")
    // 可见行为：surface 最后一行必须换掉过期缺配置文案。
    check(live.statuses.last?.contains("缺少显式配置") != true,
          "\(label): the missing-config notice is no longer the last visible status")
    if orchestrationState == "failed" {
        check(live.statuses.last?.contains("后台整理失败") == true,
              "\(label): background failure stays last and is never covered by a success line")
    } else if orchestrationState == "unconfigured" {
        check(live.statuses.last?.contains("暂不可用") == true,
              "\(label): unconfigured provider stays last and is never covered by a success line")
    } else {
        check(live.statuses.last?.contains("已恢复") == true || live.statuses.last?.contains("已就绪") == true,
              "\(label): healthy external recovery shows a config-recovered/ready line (config only, not write completion)")
    }
    // 真实 30 秒节流到点后的下一轮轮询：去重，不刷屏。
    let shown = live.statuses.count
    app.residentMemoryConfigurationAttemptAt = Date(timeIntervalSinceNow: -31)
    app.refreshResidentMemoryConfigurationIfNeeded()
    await settle(app)
    check(transport.statusCount == 3,
          "\(label): a real 30s-interval poll queries memory_status again")
    check(live.statuses.count == shown,
          "\(label): real 30s-interval polling stays deduped")
    // 节流窗口内的稳态：不重复查询、不再写状态行（不刷屏）。
    app.refreshResidentMemoryConfigurationIfNeeded()
    await settle(app)
    check(transport.statusCount == 3, "\(label): a poll inside the throttle window does not re-query")
    check(live.statuses.count == shown, "\(label): steady state never floods the chat surface")
}

/// 恢复发生在聊天表面建立之前：缓存的旧缺配置提示必须被替换，flush 补显示时绝不
/// 能把过期缺配置文案重新显示出来。
@MainActor func scenarioExternalRecoveryBeforeSurface() async {
    let transport = StatusTransportStub()
    transport.statusResponses = [
        statusFixture(compaction: false, embedding: false),
        statusFixture(compaction: true, embedding: true,
                      orchestration: orchestrationFixture(state: "idle", lastError: nil)),
    ]
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.refreshResidentMemoryConfigurationIfNeeded(force: true)
    await settle(app)
    check(app.liveCamWindowController == nil && app.stageWindowController == nil,
          "startup recovery scenario has no chat surface yet")
    check(app.residentMemoryConfigurationNotice?.contains("缺少显式配置") == true,
          "missing env caches the missing-config notice while no surface exists")
    check(transport.statusCount == 1, "the no-surface poll reads memory_status once")
    app.residentMemoryConfigurationAttemptAt = Date(timeIntervalSinceNow: -31)
    app.refreshResidentMemoryConfigurationIfNeeded()
    await settle(app)
    check(transport.statusCount == 2,
          "throttle-elapsed poll detects the external recovery without a surface")
    check(app.residentMemoryEnvironmentIncomplete == false,
          "external recovery clears the incomplete marker even without a surface")
    check(app.residentMemoryConfigurationNotice?.contains("缺少显式配置") != true,
          "external recovery drops the cached missing-config notice without a surface")
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    app.flushResidentMemoryNoticeIfNeeded()
    check(!live.statuses.contains { $0.contains("缺少显式配置") },
          "flush after external recovery never shows the stale missing-config notice")
    if let last = live.statuses.last {
        check(last.contains("已恢复") || last.contains("已就绪"),
              "flush shows the recovered config state instead of the stale warning")
    }
    let shown = live.statuses.count
    app.flushResidentMemoryNoticeIfNeeded()
    check(live.statuses.count == shown, "the flushed recovery notice is shown exactly once")
    check(transport.configureCalls.isEmpty, "external recovery never re-configures providers")
}

@MainActor func scenarioRefreshInFlightDedup() async {
    let transport = StatusTransportStub()
    transport.lastStatus = statusFixture(compaction: false, embedding: false)
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    // 模拟一次配置核对仍在进行：force 只跳过 30 秒节流，绝不绕过 in-flight 防重。
    app.residentMemoryConfigurationInFlight = true
    app.refreshResidentMemoryConfigurationIfNeeded(force: true)
    check(transport.statusCount == 0, "force never bypasses the in-flight guard")
    check(app.residentMemoryConfigurationInFlight == true,
          "a blocked force call leaves the running poll's flag untouched")
    app.residentMemoryConfigurationInFlight = false
    app.refreshResidentMemoryConfigurationIfNeeded(force: true)
    await settle(app)
    check(transport.statusCount == 1, "once the running poll finishes a forced check runs again")
    check(app.residentMemoryConfigurationInFlight == false,
          "the completed poll clears the in-flight flag")
}

/// issue #1 回归：memory.configure 抛错留下的「长期记忆后台配置失败」同样属于
/// 配置故障。daemon 之后被外部配好（configured=true 且后台 idle/nil）时，这条
/// 过期提示必须被清掉并换成只表示配置已恢复的状态行；背景整理 failed/
/// unconfigured 仍必须优先，绝不被「已恢复」文案覆盖。
@MainActor func scenarioConfigureFailureExternalRecovery() async {
    let transport = StatusTransportStub()
    transport.configureThrows = true
    transport.lastStatus = statusFixture(compaction: false, embedding: false)
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.last?.contains("长期记忆后台配置失败") == true,
          "a throwing memory_configure surfaces the configuration-failure notice")
    check(transport.configureCalls.count == 1,
          "the failed configure attempt is recorded once (compaction)")

    // 外部把两个 provider 都配好且后台健康：过期的配置失败提示必须被换掉。
    transport.configureThrows = false
    transport.lastStatus = statusFixture(
        compaction: true, embedding: true,
        orchestration: orchestrationFixture(state: "idle", lastError: nil))
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.last?.contains("已恢复") == true,
          "external healthy recovery replaces the stale configure-failure notice")
    check(live.statuses.last?.contains("长期记忆后台配置失败") == false,
          "the stale configure-failure notice is no longer the last visible status")
    check(app.residentMemoryConfigurationNotice?.contains("长期记忆后台配置失败") != true,
          "the stale configure-failure notice is dropped from the notice cache")
    let shown = live.statuses.count
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.count == shown,
          "steady healthy state stays silent after the configure-failure recovery")

    // 再制造一次 configure 失败，随后后台整理失败：故障状态必须优先于「已恢复」。
    transport.configureThrows = true
    transport.lastStatus = statusFixture(compaction: false, embedding: false)
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.last?.contains("长期记忆后台配置失败") == true,
          "a second throwing configure surfaces the configuration-failure notice again")
    transport.configureThrows = false
    transport.lastStatus = statusFixture(
        compaction: true, embedding: true,
        orchestration: orchestrationFixture(state: "failed", lastError: "memory_consolidation_failed"))
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.last?.contains("后台整理失败") == true,
          "background failure stays last after the stale configure failure is cleared")
    check(live.statuses.last?.contains("已恢复") == false,
          "a background failure is never covered by the config-recovered line")

    // unconfigured 同样优先。
    transport.lastStatus = statusFixture(
        compaction: true, embedding: true,
        orchestration: orchestrationFixture(state: "unconfigured", lastError: nil))
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.last?.contains("暂不可用") == true,
          "unconfigured provider stays last after the stale configure failure is cleared")
    check(live.statuses.last?.contains("已恢复") == false,
          "unconfigured is never covered by the config-recovered line")
}

/// issue #2 回归：memory_status await 期间换空间、换绑代次后，旧 scope 的结果
/// （failed/成功）绝不能在 await 之后落到新空间：不提交 configured 摘要、不呈现
/// 旧后台故障、不缓存提示。
@MainActor func scenarioScopeSwitchDuringStatusAwait() async {
    let transport = SuspendingStatusTransport()
    transport.suspendedMethods = ["memory_status"]
    transport.outcome = .success(statusFixture(
        compaction: true, embedding: true,
        orchestration: orchestrationFixture(state: "failed", lastError: "old_scope_consolidation_failed")))
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    let task = Task { await app.applyResidentMemoryConfigurationIfNeeded() }
    check(await waitForSuspension(transport),
          "scope-switch-status: the memory_status interleaving point was actually reached")
    // await 期间换空间：scope 与绑定代次都变。
    app.scopeForTest = ResidentStateScope(worldID: "other-cabin", residentScope: "resident")
    app.residentMemoryBindingGeneration = UUID()
    transport.resume()
    await task.value
    check(app.residentMemoryConfigured == nil,
          "a status result from the old scope never commits the new scope's configured summary")
    check(live.statuses.isEmpty,
          "the old scope's failed orchestration is never presented on the new scope's surface")
    check(app.residentMemoryConfigurationNotice == nil,
          "the old scope's result never caches a notice for the new scope")
    check(transport.recorded.count == 1, "the stale status poll is not retried by the same apply")
}

/// issue #2 回归：第一个 memory_configure await 期间换空间/代次后，不得继续第二个
/// provider configure，也不得提交「已就绪」状态。
@MainActor func scenarioScopeSwitchDuringConfigureAwait() async {
    let transport = SuspendingStatusTransport()
    transport.lastStatus = statusFixture(compaction: false, embedding: false)
    transport.suspendedMethods = ["memory_configure"]
    transport.outcome = .success(["configured": .bool(true)])
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    let task = Task { await app.applyResidentMemoryConfigurationIfNeeded() }
    check(await waitForSuspension(transport),
          "scope-switch-configure: the configure interleaving point was actually reached")
    app.scopeForTest = ResidentStateScope(worldID: "other-cabin", residentScope: "resident")
    app.residentMemoryBindingGeneration = UUID()
    transport.resume()
    await task.value
    check(transport.configureCallCount == 1,
          "a scope switch during the first configure await never runs the second provider configure")
    check(!(app.residentMemoryConfigured?.compaction == true && app.residentMemoryConfigured?.embedding == true),
          "a stale configure result never commits the configured summary")
    check(live.statuses.contains { $0.contains("已就绪") } == false,
          "a stale configure result never shows the ready notice")
}

/// issue #2 回归：configure 在 await 期间换空间后抛错，旧错误不得提交「配置失败」
/// 提示或缓存到新空间。
@MainActor func scenarioScopeSwitchDuringConfigureThrow() async {
    let transport = SuspendingStatusTransport()
    transport.lastStatus = statusFixture(compaction: false, embedding: false)
    transport.suspendedMethods = ["memory_configure"]
    transport.outcome = .failure(ResidentStateError.daemon("memory_configure_rejected"))
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    let task = Task { await app.applyResidentMemoryConfigurationIfNeeded() }
    check(await waitForSuspension(transport),
          "scope-switch-configure-throw: the configure interleaving point was actually reached")
    app.scopeForTest = ResidentStateScope(worldID: "other-cabin", residentScope: "resident")
    app.residentMemoryBindingGeneration = UUID()
    transport.resume()
    await task.value
    check(transport.configureCallCount == 1,
          "a stale configure failure never retries the second provider configure")
    check(live.statuses.contains { $0.contains("长期记忆后台配置失败") } == false,
          "a configure failure that lands after a scope switch never shows a stale failure notice")
    check(app.residentMemoryConfigurationNotice == nil,
          "a stale configure failure never caches a notice for the new scope")
}

/// issue #2 回归：configure 悬挂时任务被取消：不得继续第二个 configure、不得提交
/// 已就绪/失败 UI 状态。
@MainActor func scenarioConfigureCancellation() async {
    let transport = SuspendingStatusTransport()
    transport.lastStatus = statusFixture(compaction: false, embedding: false)
    transport.suspendedMethods = ["memory_configure"]
    transport.outcome = .success(["configured": .bool(true)])
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    let task = Task { await app.applyResidentMemoryConfigurationIfNeeded() }
    check(await waitForSuspension(transport),
          "configure-cancellation: the configure interleaving point was actually reached")
    task.cancel()
    transport.resume()
    await task.value
    check(transport.configureCallCount == 1,
          "cancellation during a hanging configure never runs the second provider configure")
    check(!(app.residentMemoryConfigured?.compaction == true && app.residentMemoryConfigured?.embedding == true),
          "a cancelled configure never commits the configured summary")
    check(live.statuses.contains { $0.contains("已就绪") || $0.contains("长期记忆后台配置失败") } == false,
          "a cancelled configure never shows a ready or failure notice")
}

// MARK: - issue #1/#2 审阅缺口收口

/// issue #1 回归最短路径：memory_configure 抛错后，daemon 直接被外部配好，且该
/// daemon 不返回 orchestration（nil）。过期的「长期记忆后台配置失败」必须被清掉，
/// 换成只表示配置已恢复的状态行；此前的恢复场景都先经过中间 idle 或二次失败，
/// 这里专门核对「抛错 → 直接 nil」不被遗漏。
@MainActor func scenarioConfigureFailureDirectNilRecovery() async {
    let transport = StatusTransportStub()
    transport.configureThrows = true
    transport.lastStatus = statusFixture(compaction: false, embedding: false)
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.last?.contains("长期记忆后台配置失败") == true,
          "direct-nil: a throwing configure surfaces the configuration-failure notice")
    check(app.residentMemoryConfigurationNotice?.contains("长期记忆后台配置失败") == true,
          "direct-nil: the configure-failure notice is cached before recovery")
    // 外部直接配好、旧 daemon 不带 orchestration 字段：must clear the stale fault.
    transport.configureThrows = false
    transport.lastStatus = statusFixture(compaction: true, embedding: true)
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(app.residentMemoryConfigurationNotice?.contains("长期记忆后台配置失败") != true,
          "direct-nil: the stale configure-failure notice is dropped without an intermediate idle")
    check(live.statuses.last?.contains("已恢复") == true,
          "direct-nil: external recovery without orchestration shows the recovery line")
    check(live.statuses.last?.contains("长期记忆后台配置失败") == false,
          "direct-nil: the stale configure-failure line is no longer last")
    check(app.residentMemoryBackgroundIssueShown == false,
          "direct-nil: nil orchestration leaves no background-issue flag behind")
    let shown = live.statuses.count
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.count == shown,
          "direct-nil: steady healthy state stays silent after direct recovery")
}

/// issue #1 回归最短路径：memory_configure 抛错后，外部直接进入后台整理 failed
/// （不先经过 idle 恢复、也不再来一次抛错）。旧配置失败提示必须被清掉，但真实
/// 后台失败必须最后呈现，绝不被「已恢复」文案覆盖。
@MainActor func scenarioConfigureFailureDirectFailed() async {
    let transport = StatusTransportStub()
    transport.configureThrows = true
    transport.lastStatus = statusFixture(compaction: false, embedding: false)
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.last?.contains("长期记忆后台配置失败") == true,
          "direct-failed: a throwing configure surfaces the configuration-failure notice")
    transport.configureThrows = false
    transport.lastStatus = statusFixture(
        compaction: true, embedding: true,
        orchestration: orchestrationFixture(state: "failed", lastError: "direct_recovery_failed"))
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.last?.contains("后台整理失败") == true,
          "direct-failed: background failure stays last after the stale configure failure is cleared")
    check(live.statuses.last?.contains("direct_recovery_failed") == true,
          "direct-failed: the real background error code is visible")
    check(live.statuses.last?.contains("已恢复") == false,
          "direct-failed: a background failure is never covered by the config-recovered line")
    check(live.statuses.last?.contains("长期记忆后台配置失败") == false,
          "direct-failed: the stale configure-failure line is replaced by the real background failure")
    check(app.residentMemoryBackgroundIssueShown == true,
          "direct-failed: the failed orchestration raises the background-issue flag")
    let shown = live.statuses.count
    await app.applyResidentMemoryConfigurationIfNeeded()
    check(live.statuses.count == shown,
          "direct-failed: the same background failure is not re-shown every poll")
}

/// 预设「新世界」的可见状态：旧 scope/代次的迟到结果若被错误提交，最容易表现为
/// 把这些非 nil 值清空或覆盖。旧测试初始全 nil，检测不出「旧返回清掉了新值」。
@MainActor func presetNewWorldState(_ app: App) {
    app.residentMemoryConfigured = (false, false)
    app.residentMemoryConfigurationNotice = "新世界提示：旧结果不得覆盖"
    app.residentMemoryConfigurationNoticeShown = true
    app.residentMemoryBackgroundIssueShown = true
    app.residentMemoryEnvironmentIncomplete = false
}

@MainActor func assertNewWorldStateIntact(_ app: App, _ live: FakeSurface, _ label: String) {
    check(app.residentMemoryConfigured?.compaction == false && app.residentMemoryConfigured?.embedding == false,
          "\(label): the stale result never overwrites the new scope's configured summary")
    check(app.residentMemoryConfigurationNotice == "新世界提示：旧结果不得覆盖",
          "\(label): the stale result never overwrites the new scope's notice")
    check(app.residentMemoryConfigurationNoticeShown == true,
          "\(label): the stale result never resets the new scope's shown flag")
    check(app.residentMemoryBackgroundIssueShown == true,
          "\(label): the stale result never clears the new scope's background-issue flag")
    check(live.statuses.isEmpty,
          "\(label): the stale result is never presented on the new scope's surface")
}

/// issue #2 回归：仅换 scope、绑定代次保持不变时，悬挂返回的 idle + configured
/// 旧结果绝不提交。新世界的 configured/提示/noticeShown/backgroundIssue 全部预设为
/// 非 nil，旧返回一旦落地就会被直接看出来（clean 掉或覆盖）。
@MainActor func scenarioStatusStaleScopeOnlyChangeReturnsIdle() async {
    let transport = SuspendingStatusTransport()
    transport.suspendedMethods = ["memory_status"]
    transport.outcome = .success(statusFixture(
        compaction: true, embedding: true,
        orchestration: orchestrationFixture(state: "idle", lastError: nil)))
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    presetNewWorldState(app)
    let task = Task { await app.applyResidentMemoryConfigurationIfNeeded() }
    check(await waitForSuspension(transport),
          "scope-only-idle: the memory_status interleaving point was actually reached")
    // 仅换 scope，代次不变：旧结果（idle + configured）绝不能提交。
    app.scopeForTest = ResidentStateScope(worldID: "other-cabin", residentScope: "resident")
    transport.resume()
    await task.value
    assertNewWorldStateIntact(app, live, "scope-only-idle")
    check(transport.recorded.count == 1,
          "scope-only-idle: the stale status poll is not retried by the same apply")
    check(transport.configureCallCount == 0,
          "scope-only-idle: the stale status result never triggers provider configuration")
}

/// issue #2 回归：仅推进绑定代次、scope 保持不变时，悬挂返回的 failed 旧结果绝不
/// 提交。新世界预设同 scope-only 场景，旧 failed 一旦落地会改写提示并清掉标记。
@MainActor func scenarioStatusStaleGenerationOnlyChangeReturnsFailed() async {
    let transport = SuspendingStatusTransport()
    transport.suspendedMethods = ["memory_status"]
    transport.outcome = .success(statusFixture(
        compaction: true, embedding: true,
        orchestration: orchestrationFixture(state: "failed", lastError: "old_generation_failed")))
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    presetNewWorldState(app)
    let task = Task { await app.applyResidentMemoryConfigurationIfNeeded() }
    check(await waitForSuspension(transport),
          "generation-only-failed: the memory_status interleaving point was actually reached")
    // 仅推进代次，scope 保持不变：旧 failed 结果绝不能提交。
    app.residentMemoryBindingGeneration = UUID()
    transport.resume()
    await task.value
    assertNewWorldStateIntact(app, live, "generation-only-failed")
    check(transport.recorded.count == 1,
          "generation-only-failed: the stale status poll is not retried by the same apply")
    check(transport.configureCallCount == 0,
          "generation-only-failed: the stale status result never triggers provider configuration")
}

/// issue #2/#3 回归：第一个 provider（compaction）成功、第二个（embedding）
/// configure 悬挂期间换空间/代次，旧结果过期：绝不提交「已就绪」，也不重试。
/// 受控 transport 按「第 2 次 memory_configure 调用」精确挂起，制造真实交错。
@MainActor func scenarioEmbeddingConfigureStaleExpire() async {
    let transport = SuspendingStatusTransport()
    transport.lastStatus = statusFixture(compaction: false, embedding: false)
    transport.suspendOnCallIndex = ["memory_configure": 2]
    transport.outcome = .success(["configured": .bool(true)])
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    presetNewWorldState(app)
    let task = Task { await app.applyResidentMemoryConfigurationIfNeeded() }
    check(await waitForSuspension(transport),
          "embedding-expire: the second configure interleaving point was actually reached")
    app.scopeForTest = ResidentStateScope(worldID: "other-cabin", residentScope: "resident")
    app.residentMemoryBindingGeneration = UUID()
    transport.resume()
    await task.value
    check(transport.configureCallCount == 2,
          "embedding-expire: a stale second configure is never retried")
    check(!(app.residentMemoryConfigured?.compaction == true && app.residentMemoryConfigured?.embedding == true),
          "embedding-expire: a stale embedding configure never commits the configured summary")
    check(live.statuses.contains { $0.contains("已就绪") } == false,
          "embedding-expire: a stale embedding configure never shows the ready notice")
    assertNewWorldStateIntact(app, live, "embedding-expire")
}

/// issue #2/#3 回归：第二个 embedding configure 悬挂期间任务被取消：绝不提交
/// 「已就绪」/失败，也不重试第二个 provider。
@MainActor func scenarioEmbeddingConfigureStaleCancel() async {
    let transport = SuspendingStatusTransport()
    transport.lastStatus = statusFixture(compaction: false, embedding: false)
    transport.suspendOnCallIndex = ["memory_configure": 2]
    transport.outcome = .success(["configured": .bool(true)])
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    presetNewWorldState(app)
    let task = Task { await app.applyResidentMemoryConfigurationIfNeeded() }
    check(await waitForSuspension(transport),
          "embedding-cancel: the second configure interleaving point was actually reached")
    task.cancel()
    transport.resume()
    await task.value
    check(transport.configureCallCount == 2,
          "embedding-cancel: cancellation during the second configure never retries it")
    check(!(app.residentMemoryConfigured?.compaction == true && app.residentMemoryConfigured?.embedding == true),
          "embedding-cancel: a cancelled embedding configure never commits the configured summary")
    check(live.statuses.contains { $0.contains("已就绪") || $0.contains("长期记忆后台配置失败") } == false,
          "embedding-cancel: a cancelled embedding configure shows neither ready nor failure")
    assertNewWorldStateIntact(app, live, "embedding-cancel")
}

/// issue #2 回归：memory_status 悬挂期间任务被取消：迟到结果绝不改写新世界的
/// configured/提示/noticeShown/backgroundIssue。
@MainActor func scenarioStatusCancellationLeavesNewState() async {
    let transport = SuspendingStatusTransport()
    transport.suspendedMethods = ["memory_status"]
    transport.outcome = .success(statusFixture(
        compaction: true, embedding: true,
        orchestration: orchestrationFixture(state: "idle", lastError: nil)))
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    presetNewWorldState(app)
    let task = Task { await app.applyResidentMemoryConfigurationIfNeeded() }
    check(await waitForSuspension(transport),
          "status-cancel: the memory_status interleaving point was actually reached")
    task.cancel()
    transport.resume()
    await task.value
    assertNewWorldStateIntact(app, live, "status-cancel")
    check(transport.recorded.count == 1,
          "status-cancel: a cancelled status poll is not retried by the same apply")
    check(transport.configureCallCount == 0,
          "status-cancel: a cancelled status poll never triggers provider configuration")
}

/// issue #2 回归：memory_status 悬挂后抛错：失败路径绝不改写新世界的状态，也不
/// 误当成缺配置/触发 provider 配置。
@MainActor func scenarioStatusThrowLeavesNewState() async {
    let transport = SuspendingStatusTransport()
    transport.suspendedMethods = ["memory_status"]
    transport.outcome = .failure(ResidentStateError.daemon("memory_status_unavailable"))
    let app = App(memory: ResidentConversationMemory(transport: transport))
    app.liveCamWindowController = FakeSurface()
    let live = app.liveCamWindowController!
    presetNewWorldState(app)
    let task = Task { await app.applyResidentMemoryConfigurationIfNeeded() }
    check(await waitForSuspension(transport),
          "status-throw: the memory_status interleaving point was actually reached")
    transport.resume()
    await task.value
    assertNewWorldStateIntact(app, live, "status-throw")
    check(transport.recorded.count == 1,
          "status-throw: a failed status read is not retried by the same apply")
    check(transport.configureCallCount == 0,
          "status-throw: a failed status read never attempts provider configuration")
}

@main struct Test {
    @MainActor static func main() async {
        let scenario = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "configured-failed"
        switch scenario {
        case "configured-failed": await scenarioConfiguredFailed()
        case "recovery": await scenarioRecovery()
        case "unconfigured": await scenarioUnconfigured()
        case "missing-env-late-surface": await scenarioMissingEnvLateSurface()
        case "missing-env-surface-present": await scenarioMissingEnvSurfacePresent()
        case "daemon-restart-reconfigure": await scenarioDaemonRestartReconfigure()
        case "refresh-contract": await scenarioRefreshContract()
        case "missing-env-keeps-polling": await scenarioMissingEnvKeepsPolling()
        case "refresh-inflight-dedup": await scenarioRefreshInFlightDedup()
        case "external-config-recovery":
            await externalRecoveryCase(orchestrationState: nil, label: "nil-orchestration")
            await externalRecoveryCase(orchestrationState: "idle", label: "idle")
            await externalRecoveryCase(orchestrationState: "pending", label: "pending")
            await externalRecoveryCase(orchestrationState: "running", label: "running")
            await externalRecoveryCase(orchestrationState: "failed", label: "failed")
            await externalRecoveryCase(orchestrationState: "unconfigured", label: "unconfigured")
        case "external-recovery-before-surface": await scenarioExternalRecoveryBeforeSurface()
        case "configure-failure-external-recovery": await scenarioConfigureFailureExternalRecovery()
        case "scope-switch-during-status": await scenarioScopeSwitchDuringStatusAwait()
        case "scope-switch-during-configure": await scenarioScopeSwitchDuringConfigureAwait()
        case "scope-switch-configure-throw": await scenarioScopeSwitchDuringConfigureThrow()
        case "configure-cancellation": await scenarioConfigureCancellation()
        case "configure-failure-direct-nil": await scenarioConfigureFailureDirectNilRecovery()
        case "configure-failure-direct-failed": await scenarioConfigureFailureDirectFailed()
        case "status-stale-scope-only-idle": await scenarioStatusStaleScopeOnlyChangeReturnsIdle()
        case "status-stale-generation-only-failed": await scenarioStatusStaleGenerationOnlyChangeReturnsFailed()
        case "embedding-configure-stale-expire": await scenarioEmbeddingConfigureStaleExpire()
        case "embedding-configure-stale-cancel": await scenarioEmbeddingConfigureStaleCancel()
        case "status-cancel-leaves-new-state": await scenarioStatusCancellationLeavesNewState()
        case "status-throw-leaves-new-state": await scenarioStatusThrowLeavesNewState()
        default:
            failures += 1
            checks += 1
            print("FAIL: unknown scenario \(scenario)")
        }
        print("\(failures == 0 ? "PASS" : "FAIL"): \(scenario): \(checks) config-app checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

// 编译（含真实 Agent 记忆文件，-warnings-as-errors）+ 逐场景受控运行：环境完整
// 场景注入 GMGN_MEMORY_*，缺环境场景剔除全部 GMGN_MEMORY_*，绝不接触真实
// daemon/UserDefaults/服务。
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-conv-memory-config-app-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let file = work.appendingPathComponent("Test.swift")
try harness.write(to: file, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("check").path
func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
let baseEnvironment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GMGN_MEMORY_") }
let completeEnvironment = baseEnvironment.merging([
    "GMGN_MEMORY_COMPACTION_ENDPOINT": "http://127.0.0.1:1/v1",
    "GMGN_MEMORY_COMPACTION_TOKEN": "compaction-fixture-token",
    "GMGN_MEMORY_EMBEDDING_ENDPOINT": "http://127.0.0.1:1/v1",
    "GMGN_MEMORY_EMBEDDING_TOKEN": "embedding-fixture-token",
]) { _, new in new }

let realFiles = [
    "ResidentStateClient", "ResidentMemoryClient", "ResidentConversationMemory",
    "ResidentMemoryConfiguration",
].map {
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/\($0).swift").path
}
let compiled = try run("/usr/bin/swiftc",
    ["-swift-version", "6", "-j1", "-parse-as-library", "-warnings-as-errors"] + realFiles +
    [file.path, "-o", binary])
guard compiled == 0 else { exit(compiled) }

let scenarios: [(name: String, environment: [String: String])] = [
    ("configured-failed", completeEnvironment),
    ("recovery", completeEnvironment),
    ("unconfigured", completeEnvironment),
    ("missing-env-late-surface", baseEnvironment),
    ("missing-env-surface-present", baseEnvironment),
    ("daemon-restart-reconfigure", completeEnvironment),
    ("refresh-contract", baseEnvironment),
    ("missing-env-keeps-polling", baseEnvironment),
    ("refresh-inflight-dedup", baseEnvironment),
    ("external-config-recovery", baseEnvironment),
    ("external-recovery-before-surface", baseEnvironment),
    ("configure-failure-external-recovery", completeEnvironment),
    ("scope-switch-during-status", completeEnvironment),
    ("scope-switch-during-configure", completeEnvironment),
    ("scope-switch-configure-throw", completeEnvironment),
    ("configure-cancellation", completeEnvironment),
    ("configure-failure-direct-nil", completeEnvironment),
    ("configure-failure-direct-failed", completeEnvironment),
    ("status-stale-scope-only-idle", completeEnvironment),
    ("status-stale-generation-only-failed", completeEnvironment),
    ("embedding-configure-stale-expire", completeEnvironment),
    ("embedding-configure-stale-cancel", completeEnvironment),
    ("status-cancel-leaves-new-state", completeEnvironment),
    ("status-throw-leaves-new-state", completeEnvironment),
]
// 可选：只跑命令行点名的场景（用于隔离镜像里的定向 mutation RED 证明）；
// 不带参数时跑全部，保持既有行为。
let requestedScenarios = Set(CommandLine.arguments.dropFirst())
let selectedScenarios = requestedScenarios.isEmpty
    ? scenarios
    : scenarios.filter { requestedScenarios.contains($0.name) }
var failed = 0
for scenario in selectedScenarios {
    let status = try run(binary, [scenario.name], environment: scenario.environment)
    if status != 0 { failed += 1 }
}
exit(failed == 0 ? 0 : 1)
