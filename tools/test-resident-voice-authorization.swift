// 首次语音授权的纯逻辑回归（无麦克风 / 无网络 / 无宿主 App）：
//   1) 抽取生产 `MicrophoneAuthorizationGate`（可注入状态与系统请求）；
//   2) 抽取生产 `disconnectRealtimeVoice`，验证连接任务被取消后
//      shutdown 一定落地（旧实现会挂住，见 docs/plans/evidence）。
// 覆盖：已授权 / 已拒绝 / 允许 / 拒绝 / 迟到结果 / 取消 / 重试 / 超时后重试。
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")

func declaration(_ signature: String, _ text: String) -> String {
    guard let start = text.range(of: signature)?.lowerBound,
          let opening = text[start...].firstIndex(of: "{") else {
        print("FAIL: missing production behavior \(signature)")
        exit(1)
    }
    var depth = 0
    for index in text[opening...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    fatalError("unterminated declaration")
}

let app = try String(contentsOf: sources.appendingPathComponent("App/GMGNRadioApp.swift"), encoding: .utf8)
let gate = "@MainActor\n" + declaration("final class MicrophoneAuthorizationGate", app)
let setupError = declaration("enum RealtimeVoiceSetupError", app)
let shutdown = declaration("func disconnectRealtimeVoice()", app)

let harness = #"""
import Foundation

\#(setupError)

\#(gate)

enum VoiceState: Equatable { case disconnected, connecting, listening, failed(String) }

@MainActor protocol RealtimeDJSession: AnyObject {
    func cancel()
    func setMicrophoneCaptureEnabled(_ enabled: Bool) async throws
    func setMicrophoneTransmissionEnabled(_ enabled: Bool) async throws
    func disconnect() async
}

@MainActor final class Session: RealtimeDJSession {
    var trace: [String] = []
    var beforeDisconnect: (() -> Void)?
    var suspendDisconnect = false
    var disconnectGate: CheckedContinuation<Void, Never>?
    func cancel() { trace.append("disconnect") }
    func setMicrophoneCaptureEnabled(_ enabled: Bool) async throws { trace.append("capture:\(enabled)") }
    func setMicrophoneTransmissionEnabled(_ enabled: Bool) async throws { trace.append("transmit:\(enabled)") }
    func disconnect() async {
        trace.append("disconnect")
        beforeDisconnect?()
        if suspendDisconnect { await withCheckedContinuation { disconnectGate = $0 } }
    }
}

@MainActor final class StatusBox {
    var value: MicrophoneAuthorizationGate.Status
    init(_ value: MicrophoneAuthorizationGate.Status) { self.value = value }
}

@MainActor final class RequestController {
    var calls = 0
    var continuation: CheckedContinuation<Bool, Never>?
    var status: StatusBox
    init(status: StatusBox) { self.status = status }
    func request() async -> Bool {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func answer(_ granted: Bool) {
        status.value = granted ? .authorized : .denied
        continuation?.resume(returning: granted)
        continuation = nil
    }
}

@MainActor final class Flag { var value = false }
struct RealtimeDJAudioLevel: Sendable { let peak: Double }
@MainActor final class Capture { func cancel() async {} }
@MainActor final class Announcer { func stop() {} }
@MainActor final class Panel { func setVoiceLevel<T: BinaryFloatingPoint>(_ level: T) {} }

@MainActor final class App {
    var residentVoiceRequestID: UUID?
    var residentVoiceAcceptsFinal = true
    var residentVoiceSession: (any RealtimeDJSession)?
    var residentVoiceShutdownTask: Task<Void, Never>?
    var residentVoiceShutdownGeneration: UInt64 = 0
    var realtimeVoiceConnectionTask: Task<Void, Never>?
    var realtimeVoiceTimeoutTask: Task<Void, Never>?
    var residentVoiceEventTask: Task<Void, Never>?
    var residentVoiceCommitTask: Task<Void, Never>?
    var residentVoiceAudioTask: Task<Void, Never>?
    var residentVoiceAudioContinuation: AsyncStream<(Data, RealtimeDJAudioLevel)>.Continuation?
    var residentVoiceDidCommit = false
    var residentVoiceCapture: Capture?
    let agentSpeechAnnouncer = Announcer()
    var orbWindowController: Panel? = Panel()
    var stageWindowController: Panel? = Panel()
    var state = VoiceState.disconnected
    var statuses: [String] = []
    var prompts = 0
    var lastError: Error?
    func setRealtimeVoiceState(_ value: VoiceState) { state = value }
    func showResidentVoiceStatus(_ text: String) { statuses.append(text) }

    \#(shutdown)

    @discardableResult
    private func clearResidentVoiceShutdown(generation: UInt64) -> Bool {
        guard residentVoiceShutdownGeneration == generation else { return false }
        residentVoiceShutdownTask = nil
        return true
    }

}

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ label: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(label)") }
}

@MainActor func wait(for task: Task<Void, Never>, timeout: Duration = .seconds(3)) async -> Bool {
    let flag = Flag()
    let observer = Task { @MainActor in await task.value; flag.value = true }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !flag.value, clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    if !flag.value { observer.cancel() }
    return flag.value
}

@main struct Main {
    @MainActor static func main() async {
        // 第 1 组：状态快速路径，不发起系统请求。
        do {
            let status = StatusBox(.authorized)
            let controller = RequestController(status: status)
            let gate = MicrophoneAuthorizationGate(status: { status.value }, requestAccess: { await controller.request() })
            let outcome = await gate.resolve(deadline: .seconds(5))
            check(outcome == .authorized, "already-authorized resolves without a system request")
            check(controller.calls == 0, "already-authorized never calls requestAccess")
        }
        do {
            let status = StatusBox(.denied)
            let controller = RequestController(status: status)
            let gate = MicrophoneAuthorizationGate(status: { status.value }, requestAccess: { await controller.request() })
            let outcome = await gate.resolve(deadline: .seconds(5))
            check(outcome == .denied, "already-denied resolves as denied")
            check(controller.calls == 0, "already-denied never calls requestAccess")
        }

        // 第 2 组：首次未决定 + 允许 / 拒绝。
        for granted in [true, false] {
            let status = StatusBox(.notDetermined)
            let controller = RequestController(status: status)
            let gate = MicrophoneAuthorizationGate(status: { status.value }, requestAccess: { await controller.request() })
            let prompts = Flag()
            let task = Task { @MainActor in
                await gate.resolve(deadline: .seconds(5), onSystemPrompt: { prompts.value = true })
            }
            while controller.calls == 0 { await Task.yield() }
            check(prompts.value, "system prompt is announced exactly when the request starts")
            check(controller.calls == 1, "first undetermined resolve issues one system request")
            controller.answer(granted)
            let outcome = await task.value
            check(outcome == (granted ? .authorized : .denied), "grant/deny maps to authorized/denied")
            let again = await gate.resolve(deadline: .seconds(5))
            check(again == (granted ? .authorized : .denied), "settled result is reused on retry")
            check(controller.calls == 1, "retry never issues a second system request")
        }

        // 第 3 组：迟到结果 —— 超时后系统才回答，缓存后重试直接成功。
        do {
            let status = StatusBox(.notDetermined)
            let controller = RequestController(status: status)
            let gate = MicrophoneAuthorizationGate(status: { status.value }, requestAccess: { await controller.request() })
            let first = await gate.resolve(deadline: .milliseconds(40))
            check(first == .awaitingSystemPrompt, "unanswered system prompt returns a bounded waiting outcome")
            check(controller.calls == 1, "waiting outcome keeps the single in-flight system request")
            controller.answer(true)
            for _ in 0..<50 { await Task.yield() }
            let retry = await gate.resolve(deadline: .seconds(5))
            check(retry == .authorized, "late system grant is honoured on retry")
            check(controller.calls == 1, "late system grant does not re-prompt")
        }

        // 第 4 组：取消 —— 立即返回 cancelled，系统请求与迟到结果都保留。
        do {
            let status = StatusBox(.notDetermined)
            let controller = RequestController(status: status)
            let gate = MicrophoneAuthorizationGate(status: { status.value }, requestAccess: { await controller.request() })
            let task = Task { @MainActor in await gate.resolve(deadline: .seconds(30)) }
            while controller.calls == 0 { await Task.yield() }
            task.cancel()
            let outcome = await task.value
            check(outcome == .cancelled, "cancelling the waiter resolves it immediately")
            controller.answer(true)
            for _ in 0..<50 { await Task.yield() }
            let retry = await gate.resolve(deadline: .seconds(5))
            check(retry == .authorized, "cancelled waiter still reuses the late system grant")
            check(controller.calls == 1, "cancel + retry never re-prompts")
        }

        // 第 5 组：resolveOrFail 分类文案。
        do {
            let status = StatusBox(.denied)
            let controller = RequestController(status: status)
            let gate = MicrophoneAuthorizationGate(status: { status.value }, requestAccess: { await controller.request() })
            var denied = false
            do { try await gate.resolveOrFail(deadline: .seconds(5)) }
            catch RealtimeVoiceSetupError.microphoneDenied { denied = true }
            catch { }
            check(denied, "denied outcome maps to the permission user message")
        }
        do {
            let status = StatusBox(.notDetermined)
            let controller = RequestController(status: status)
            let gate = MicrophoneAuthorizationGate(status: { status.value }, requestAccess: { await controller.request() })
            var pending = false
            do { try await gate.resolveOrFail(deadline: .milliseconds(40)) }
            catch RealtimeVoiceSetupError.microphoneAuthorizationPending { pending = true }
            catch { }
            check(pending, "unanswered system prompt maps to the waiting user message, not an image/network error")
            controller.answer(true)
        }
        do {
            let status = StatusBox(.notDetermined)
            let controller = RequestController(status: status)
            let gate = MicrophoneAuthorizationGate(status: { status.value }, requestAccess: { await controller.request() })
            let task = Task { @MainActor in
                do { try await gate.resolveOrFail(deadline: .seconds(30)) }
                catch is CancellationError { return "cancelled" }
                catch { return "error" }
                return "granted"
            }
            while controller.calls == 0 { await Task.yield() }
            task.cancel()
            let value = await task.value
            check(value == "cancelled", "cancelled authorization is not reported as a failure")
            controller.answer(true)
        }

        // 第 6 组：Rust 会话关闭与设备 shutdown 在连接取消后必须落地。
        do {
            let app = App()
            let session = Session()
            let status = StatusBox(.notDetermined)
            let controller = RequestController(status: status)
            let gate = MicrophoneAuthorizationGate(status: { status.value }, requestAccess: { await controller.request() })
            let requestID = UUID()
            app.residentVoiceRequestID = requestID
            app.residentVoiceSession = session
            app.realtimeVoiceConnectionTask = Task { @MainActor in
                do {
                    try await gate.resolveOrFail(deadline: .seconds(30)) {
                        app.prompts += 1
                    }
                } catch {
                    app.lastError = error
                }
            }
            while controller.calls == 0 { await Task.yield() }
            check(app.prompts == 1, "connect path announces the system prompt once")
            // 用户在弹窗上还没回答时点「取消/重试」。
            app.disconnectRealtimeVoice()
            guard let shutdown = app.residentVoiceShutdownTask else {
                print("FAIL: disconnect did not enqueue a shutdown task"); exit(1)
            }
            let landed = await wait(for: shutdown)
            check(landed, "voice shutdown lands after cancelling a pending authorization wait")
            check(app.residentVoiceShutdownTask == nil, "landed shutdown is cleared so retry starts clean")
            check(session.trace.contains("disconnect"), "landed shutdown still closes the microphone session")
            controller.answer(true)
            for _ in 0..<50 { await Task.yield() }
            // 迟到授权后重试立即成功，且没有第二次系统弹窗。
            let retryID = UUID()
            app.residentVoiceRequestID = retryID
            var retryFailed = false
            do { try await gate.resolveOrFail(deadline: .seconds(5)) }
            catch { retryFailed = true }
            check(!retryFailed, "retry after cancel succeeds once the late grant is cached")
            check(controller.calls == 1, "retry after cancel reuses the in-flight system request")
        }

        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) microphone authorization checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-voice-authorization-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Authorization.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let process = Process()
let executable = temporary.appendingPathComponent("authorization-test")
process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
process.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", program.path, "-o", executable.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
let test = Process()
test.executableURL = executable
try test.run()
test.waitUntilExit()
exit(test.terminationStatus)
