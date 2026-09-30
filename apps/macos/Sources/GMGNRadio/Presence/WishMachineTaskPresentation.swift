import Foundation
import Combine

/// A projection of one persisted wish; dialog activity does not own its lifetime.
/// `promptExpiresAt` hides a terminal task's on-site prompt after its 30-second
/// window: the anchor lives in the shared inbox store, so refreshes, window
/// reopenings and restarts never extend it. History and the unread badge are
/// unaffected — expiry only hides the prompt.
///
/// `autoContinuationPaused` is the **task-level** automatic-continuation stop.
/// It is separate from the loop's run stop (`ResidentAgentLoop.Snapshot`): a
/// stopped task must be visible in the panel, and one explicit human action
/// (the row's resume control → the host's resume) clears it — the user must
/// never have to guess a sentence that makes the model call a resume tool.
struct WishMachineTaskPresentation: Identifiable, Equatable {
    let id: UUID
    let title: String
    let status: String
    let detail: String?
    let isTerminal: Bool
    var autoContinuationPaused: Bool = false
    var promptExpiresAt: Date? = nil
}

@MainActor
final class WishMachineTaskPresentationStore: ObservableObject {
    @Published private(set) var tasks: [WishMachineTaskPresentation] = []
    /// 面板上唯一的"恢复"动作：按任务编号请求宿主恢复该任务的自动续办。
    /// 由宿主接线（不是模型工具），所以解除不依赖任何措辞。
    var onResumeAutomaticContinuation: ((UUID) -> Void)?

    func update(_ tasks: [WishMachineTaskPresentation]) {
        guard self.tasks != tasks else { return }
        self.tasks = tasks
    }
}
