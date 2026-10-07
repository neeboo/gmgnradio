import Foundation

/// Durable inbox delivery and agent consumption are separate from human read state.
@MainActor
final class UnityResidentInboxAgent {
    enum ConsumptionError: LocalizedError {
        case inboxNotRead
        var errorDescription: String? { "居民尚未在本轮读取待处理收件箱消息。" }
    }
    static let consumer = "agent"
    private struct Pending {
        let message: ResidentStateCommittedFact
        let taskKey: String
        var readRuns: Set<UUID> = []
        var completed = false
        var failures = 0
        var nextAttemptAt: Date?
        var failedRuns: Set<UUID> = []
    }
    private let client: ResidentStateClient
    private let scope: ResidentStateScope
    private let submit: (ResidentAgentLoop.Event) -> Bool
    private let now: () -> Date
    private var pending: [String: Pending] = [:]
    private var ticker: Task<Void, Never>?
    private var closed = false
    private var refreshing = false
    private var lastError: String?

    init(client: ResidentStateClient, scope: ResidentStateScope,
         now: @escaping () -> Date = Date.init,
         submit: @escaping (ResidentAgentLoop.Event) -> Bool) {
        self.client = client; self.scope = scope; self.now = now; self.submit = submit
    }

    func start() {
        guard !closed, ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.closed else { return }
                do { try await self.refresh() }
                catch { self.lastError = error.localizedDescription }
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
            }
        }
    }

    func refresh() async throws {
        guard !closed, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        // Retry accepted failures even when a later stream read is unavailable.
        for id in Array(pending.keys) {
            guard let item = pending[id], let due = item.nextAttemptAt, due <= now() else { continue }
            if item.completed { try await acknowledge(id) }
            else { submitPending(id) }
            guard !closed, !Task.isCancelled else { return }
        }
        // Start from zero each poll: unaccepted and failed deliveries must remain retryable.
        var cursor: UInt64 = 0
        repeat {
            let page = try await client.messageRead(scope: scope, consumer: Self.consumer,
                                                    after: cursor, limit: 100)
            guard !closed, !Task.isCancelled else { return }
            for message in page.messages where message.kind == "system_inbox" {
                guard let id = UUID(uuidString: message.id),
                      case let .string(eventID)? = message.payload["eventID"],
                      UUID(uuidString: eventID) == id,
                      case let .string(taskKey)? = message.payload["taskKey"],
                      taskKey == "agent-message:" + id.uuidString else { continue }
                let messageID = id.uuidString
                if let existing = pending[messageID] {
                    if existing.completed && existing.nextAttemptAt == nil { try await acknowledge(messageID) }
                    guard !closed, !Task.isCancelled else { return }
                    continue
                }
                pending[messageID] = Pending(message: message, taskKey: taskKey)
                submitPending(messageID)
            }
            guard page.nextCursor > cursor, !page.messages.isEmpty else { break }
            cursor = page.nextCursor
        } while !closed
        lastError = nil
    }

    /// Called only after the agent read tool has returned these actual entries.
    func noteRead(entries: [ResidentSystemInboxEntry], runID: UUID) {
        guard !closed else { return }
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastEventID)?.uuidString,
                  var item = pending[id], item.taskKey == entry.taskKey else { continue }
            item.readRuns.insert(runID)
            pending[id] = item
        }
    }

    func complete(events: [ResidentAgentLoop.Event], runID: UUID) async throws {
        guard !closed else { return }
        var unread = false
        for event in events where event.kind == "system_inbox" {
            guard var item = pending[event.id], item.readRuns.contains(runID) else {
                // The run failure callback schedules another delivery.
                unread = true
                continue
            }
            item.completed = true
            pending[event.id] = item
            do { try await acknowledge(event.id) }
            catch { lastError = error.localizedDescription }
            guard !closed else { return }
        }
        if unread { throw ConsumptionError.inboxNotRead }
    }

    func failed(events: [ResidentAgentLoop.Event], runID: UUID) {
        guard !closed else { return }
        for event in events where event.kind == "system_inbox" {
            guard var item = pending[event.id], !item.completed,
                  item.failedRuns.insert(runID).inserted else { continue }
            item.failures += 1
            let delays: [TimeInterval] = [5, 15, 30, 60]
            item.nextAttemptAt = now().addingTimeInterval(delays[min(item.failures - 1, 3)])
            item.readRuns.removeAll()
            pending[event.id] = item
        }
        // Reads from an unrelated foreground run never prove consumption in another run.
        for id in Array(pending.keys) { pending[id]?.readRuns.remove(runID) }
    }

    private func acknowledge(_ id: String) async throws {
        guard !closed else { return }
        do { try await client.messageAck(scope: scope, consumer: Self.consumer, id: id) }
        catch {
            pending[id]?.nextAttemptAt = now().addingTimeInterval(5)
            throw error
        }
        guard !closed else { return }
        pending.removeValue(forKey: id)
    }

    private func submitPending(_ id: String) {
        guard !closed, var item = pending[id], !item.completed else { return }
        let event = ResidentAgentLoop.Event(id: id, kind: "system_inbox",
            summary: "收件箱有待处理消息（taskKey=\(item.taskKey)）。调用 read_system_inbox 读取消息内容，然后按消息要求反馈或执行。")
        item.nextAttemptAt = submit(event) ? nil : now().addingTimeInterval(5)
        pending[id] = item
    }

    func snapshot() -> [String: Any] {
        var value: [String: Any] = ["status": closed ? "closed" : (lastError == nil ? "ready" : "failed"),
         "pendingCount": pending.count,
         "awaitingAckCount": pending.values.filter { $0.completed }.count,
         "retryCount": pending.values.reduce(0) { $0 + $1.failures }]
        if let next = pending.values.compactMap({ $0.nextAttemptAt }).min() {
            value["nextRetryAt"] = ISO8601DateFormatter().string(from: next)
        }
        return value
    }

    func close() {
        closed = true
        ticker?.cancel(); ticker = nil
        pending.removeAll()
    }
}
