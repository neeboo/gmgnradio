import Foundation

/// Keeps accepted activities alive across ordinary replies, but lets explicit
/// cancellation stop only the executor request started by this resident loop.
@MainActor
final class ResidentActivityOwnership {
    private weak var context: WorldAgentContext?
    private var requestID: String?

    var hasActiveActivity: Bool {
        guard let context, let requestID else { return false }
        return context.currentActivityRequestID == requestID
    }

    func claim(context: WorldAgentContext, requestID: String) {
        self.context = context
        self.requestID = requestID
    }

    func stopOwnedActivity() throws {
        let ownedContext = context
        let ownedRequestID = requestID
        context = nil
        requestID = nil
        guard let ownedContext, let ownedRequestID,
              ownedContext.currentActivityRequestID == ownedRequestID else { return }
        try ownedContext.stopActivity(reason: "居民操作已停止")
    }
}
