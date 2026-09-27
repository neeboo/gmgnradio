import Foundation
import Combine

/// A projection of one persisted wish; dialog activity does not own its lifetime.
/// `promptExpiresAt` hides a terminal task's on-site prompt after its 30-second
/// window: the anchor lives in the shared inbox store, so refreshes, window
/// reopenings and restarts never extend it. History and the unread badge are
/// unaffected — expiry only hides the prompt.
struct WishMachineTaskPresentation: Identifiable, Equatable {
    let id: UUID
    let title: String
    let status: String
    let detail: String?
    let isTerminal: Bool
    var promptExpiresAt: Date? = nil
}

@MainActor
final class WishMachineTaskPresentationStore: ObservableObject {
    @Published private(set) var tasks: [WishMachineTaskPresentation] = []

    func update(_ tasks: [WishMachineTaskPresentation]) {
        guard self.tasks != tasks else { return }
        self.tasks = tasks
    }
}
