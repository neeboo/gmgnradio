import Foundation

enum RealtimeVoiceSetupError: LocalizedError {
    case microphoneDenied
    case providerUnavailable
    /// 系统权限弹窗仍未被回答（有界等待结束），不是连接或图片能力故障。
    case microphoneAuthorizationPending

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "没有麦克风权限，请在系统设置里允许 gmgn radio 使用麦克风。"
        case .providerUnavailable:
            "这个实时语音服务尚未接通。"
        case .microphoneAuthorizationPending:
            "还在等待系统权限弹窗：请点「允许」后再点一次麦克风；"
                + "若没有看到弹窗，请在系统设置里允许 gmgn radio 使用麦克风。"
        }
    }
}

/// 麦克风授权的可注入纯逻辑闸门（2026-09-22 P0-4）。
///
/// 根因：`AVCaptureDevice.requestAccess` 没有超时、不响应 `Task` 取消，系统弹窗
/// 未回答时它的 continuation 永不恢复。旧实现把它直接 `await` 在语音连接任务里，
/// 于是 12 秒连接超时取消连接任务后，`enqueueResidentVoiceShutdown` 里的
/// `await connectingTask.value` 永远不落地，`residentVoiceShutdownTask` 从不清零，
/// 下一次连接被 `await previousShutdown?.value` 挡住，重试实际失效。
///
/// 本闸门把系统授权收敛成**有界、可取消、可复用**的结果，不靠延长超时：
/// - 已授权 / 已拒绝：立即返回，不再触碰系统请求；
/// - 首次未决定：只在真正发起系统请求时回调 `onSystemPrompt`，最多等待 `deadline`；
///   等待被取消或超时都立即返回，但系统请求**继续存在**；
/// - 迟到的系统结果写入缓存，下一次 `resolve` 直接复用，绝不弹第二次。
/// 绝不吞掉结果：无论用户先/后回答，闸门都记住答案。
@MainActor
final class MicrophoneAuthorizationGate {
    enum Status: Equatable {
        case notDetermined
        case authorized
        case denied
    }

    enum Outcome: Equatable {
        case authorized
        case denied
        /// 有界等待结束但系统弹窗仍未回答；request 仍在等待迟到结果。
        case awaitingSystemPrompt
        /// 等待方被取消（用户取消录音 / 新请求取代）；request 仍在等待迟到结果。
        case cancelled
    }

    private let currentStatus: @MainActor () -> Status
    private let requestAccess: @MainActor () async -> Bool
    private var requestTask: Task<Void, Never>?
    private var settled: Outcome?
    private var waiters: [UUID: CheckedContinuation<Outcome, Never>] = [:]

    init(
        status: @escaping @MainActor () -> Status,
        requestAccess: @escaping @MainActor () async -> Bool
    ) {
        self.currentStatus = status
        self.requestAccess = requestAccess
    }

    /// 是否还有一次系统授权请求在等用户回答（只读诊断，不触发请求）。
    var hasPendingSystemRequest: Bool { requestTask != nil }

    /// 有界等待一次授权结论。`onSystemPrompt` 只在**本次真正发起**系统请求时调用一次。
    func resolve(
        deadline: Duration,
        onSystemPrompt: @MainActor () -> Void = {}
    ) async -> Outcome {
        switch currentStatus() {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            break
        }
        // 迟到的系统答案：即便系统状态尚未回流也直接复用，绝不二次弹窗。
        if let settled { return settled }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                waiters[token] = continuation
                startSystemRequestIfNeeded(onSystemPrompt: onSystemPrompt)
                if Task.isCancelled {
                    finishWaiter(token, with: .cancelled)
                    return
                }
                Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: deadline) } catch { return }
                    self?.finishWaiter(token, with: .awaitingSystemPrompt)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishWaiter(token, with: .cancelled)
            }
        }
    }

    /// 连接链路共用的分类：授权成功静默通过，其余各自映射到固定用户文案。
    func resolveOrFail(
        deadline: Duration,
        onSystemPrompt: @MainActor () -> Void = {}
    ) async throws {
        switch await resolve(deadline: deadline, onSystemPrompt: onSystemPrompt) {
        case .authorized: return
        case .cancelled: throw CancellationError()
        case .denied: throw RealtimeVoiceSetupError.microphoneDenied
        case .awaitingSystemPrompt: throw RealtimeVoiceSetupError.microphoneAuthorizationPending
        }
    }

    private func startSystemRequestIfNeeded(onSystemPrompt: @MainActor () -> Void) {
        guard requestTask == nil else { return }
        onSystemPrompt()
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await self.requestAccess()
            self.settle(granted ? .authorized : .denied)
        }
    }

    private func settle(_ outcome: Outcome) {
        requestTask = nil
        settled = outcome
        let pending = waiters
        waiters.removeAll()
        for (_, continuation) in pending {
            continuation.resume(returning: outcome)
        }
    }

    private func finishWaiter(_ token: UUID, with outcome: Outcome) {
        guard let continuation = waiters.removeValue(forKey: token) else { return }
        continuation.resume(returning: outcome)
    }
}
