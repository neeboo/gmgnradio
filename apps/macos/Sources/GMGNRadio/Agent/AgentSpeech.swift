import AppKit
import Observation

// MARK: - Status

/// 轻量语音状态：只记录最近一次朗读失败，不影响聊天文字。
@MainActor
@Observable
final class AgentSpeechStatusStore {
    static let shared = AgentSpeechStatusStore()

    var lastErrorMessage: String?
}

// MARK: - Protocol

@MainActor
protocol SpeechSynthesizing: AnyObject {
    /// 开始朗读；返回是否成功启动。失败只应记录状态，不应影响聊天结果。
    @discardableResult
    func speak(_ text: String) -> Bool

    func stopSpeaking()
}

// MARK: - macOS implementation

/// 基于 NSSpeechSynthesizer 的本地语音合成。
@MainActor
final class MacSpeechSynthesizer: NSObject, SpeechSynthesizing {
    private let synthesizer = NSSpeechSynthesizer()
    private let statusStore: AgentSpeechStatusStore

    init(statusStore: AgentSpeechStatusStore = .shared) {
        self.statusStore = statusStore
        super.init()
        synthesizer.delegate = self
    }

    @discardableResult
    func speak(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            return false
        }
        return synthesizer.startSpeaking(trimmed)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking()
    }
}

extension MacSpeechSynthesizer: NSSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ sender: NSSpeechSynthesizer,
        didFinishSpeaking finishedSpeaking: Bool
    ) {
        guard !finishedSpeaking else { return }
        Task { @MainActor in
            AgentSpeechStatusStore.shared.lastErrorMessage =
                "语音朗读失败，请检查系统语音设置；文字回复不受影响。"
        }
    }
}

// MARK: - Announcer

/// Agent 回复完成后的自动朗读入口；朗读失败绝不影响文字回复。
@MainActor
final class AgentSpeechAnnouncer {
    private let synthesizer: any SpeechSynthesizing
    private let statusStore: AgentSpeechStatusStore

    var isEnabled: Bool

    init(
        synthesizer: any SpeechSynthesizing,
        isEnabled: Bool = true,
        statusStore: AgentSpeechStatusStore = .shared
    ) {
        self.synthesizer = synthesizer
        self.isEnabled = isEnabled
        self.statusStore = statusStore
    }

    func announce(_ text: String) {
        guard isEnabled else { return }
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return }
        if !synthesizer.speak(trimmed) {
            statusStore.lastErrorMessage =
                "语音朗读启动失败；文字回复不受影响。"
        }
    }
}
