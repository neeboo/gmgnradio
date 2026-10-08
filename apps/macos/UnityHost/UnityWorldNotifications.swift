import Foundation

/// Called after the shared coordinator/world projection changes. It consumes
/// existing ownership rows, never infers completion from provider success.
@MainActor
final class UnityWorldNotifications {
    private let worldID: String
    private let residentScope: String
    private let inbox: UnityInboxBridge
    private var feed = WishMachineTaskMessageFeed()
    private var closed = false
    private var syncing = false
    private var subscribed = false
    private var agentMessages: [UUID: PropTaskMessage] = [:]
    private var queued = Set<UUID>()
    private var consumed = Set<UUID>()
    private var pendingDurableWrites = Set<UUID>()
    private var acknowledged = Set<UUID>()
    /// Installed only by the selected world's actual resident-loop owner.
    var onAgentEvent: (@MainActor (ResidentAgentLoop.Event, Bool) -> Bool)?

    init(worldID: String, residentScope: String, inbox: UnityInboxBridge) {
        self.worldID = worldID; self.residentScope = residentScope; self.inbox = inbox
    }

    /// Original task message builder owns wording, identities and failure rules.
    /// The caller must supply rows from its unique authoritative world context.
    func synchronize(rows: [OwnershipRow], tasks: [WishMachineTaskPresentation],
                     coordinator: WishMachineCoordinator, store: PropGenerationStore,
                     outputIsRendered: (String) -> Bool) async throws -> Bool {
        guard !closed, !syncing else { return false }
        syncing = true
        defer { syncing = false }
        try await coordinator.waitUntilReady()
        guard !closed else { return false }
        // Current ownership facts must reach the human inbox even when the
        // independent agent subscription or acknowledgement is unavailable.
        let scopedJobIDs = Set(coordinator.residentJobs(worldID: worldID, residentScope: residentScope).map(\.id))
        let scopedRows = rows.filter { row in row.key.jobID.map(scopedJobIDs.contains) ?? false }
        feed.sync(scopedRows.map { .init(row: $0, promptExpiresAt: nil) }, now: Date())
        let byID = Dictionary(scopedRows.map { ($0.key.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let terminal = Dictionary(tasks.map { ($0.id.uuidString, $0.isTerminal) }, uniquingKeysWith: { first, _ in first })
        let deliveries = feed.messages.compactMap { message -> ResidentSystemDelivery? in
            guard let row = byID[message.taskID], let jobID = row.key.jobID else { return nil }
            return .init(eventID: message.id, taskID: jobID.uuidString, kind: "wish.task",
                title: message.text, status: row.statusText, detail: row.reasonText ?? "",
                terminal: terminal[jobID.uuidString] ?? false)
        }
        if !deliveries.isEmpty, !(try await inbox.deliver(deliveries)) { return false }
        guard !closed else { return false }
        if !subscribed {
            try await store.subscribeMessages(consumer: "agent", worldID: worldID, residentScope: residentScope)
            guard !closed else {
                store.unsubscribeMessages(consumer: "agent", worldID: worldID, residentScope: residentScope)
                return false
            }
            subscribed = true
        }
        for event in coordinator.unpublishedEvents(worldID: worldID, residentScope: residentScope) {
            try Task.checkCancellation()
            guard !closed else { return false }
            guard let job = coordinator.residentJobs(worldID: worldID, residentScope: residentScope)
                .first(where: { $0.id == event.wishID }), let taskID = job.jobID,
                store.jobs.contains(where: { $0.id == taskID }) else { continue }
            if event.kind == .outputReady && !outputIsRendered(event.objectID) { continue }
            var payload: [String: PropTaskJSON] = ["wish_id": .string(event.wishID.uuidString),
                "object_id": .string(event.objectID), "state": .string(event.kind.rawValue),
                "compute_may_continue": .bool(event.computeMayContinue)]
            if let value = event.stage { payload["stage"] = .string(value.rawValue) }
            if let value = event.remoteState { payload["remote_state"] = .string(value.rawValue) }
            if let value = event.message { payload["message"] = .string(value) }
            if let value = event.cancelRequested { payload["cancel_requested"] = .bool(value) }
            if let value = event.failureSource { payload["failure_source"] = .string(value) }
            if let value = event.autoContinuationPaused { payload["auto_continuation_paused"] = .bool(value) }
            if let value = event.continuationResumeAuthorizationID { payload["resume_authorization_id"] = .string(value.uuidString) }
            let receipt = try await store.publishMessage(id: event.id, taskId: taskID,
                worldID: worldID, residentScope: residentScope,
                kind: "wish." + event.kind.rawValue, payload: payload)
            guard receipt.id == event.id, receipt.taskId == taskID,
                  receipt.worldID == worldID, receipt.residentScope == residentScope,
                  receipt.kind == "wish." + event.kind.rawValue, receipt.payload == payload else {
                throw PropTaskDaemonError.invalidFrame
            }
            try await coordinator.markEventPublished(id: event.id)
        }
        guard !closed else { return false }
        // A replay after a process restart is already consumed when its local
        // coordinator receipt committed, even if the daemon ACK never arrived.
        for message in agentMessages.values where coordinator.isEventAcknowledged(
            id: message.id, worldID: worldID, residentScope: residentScope) {
            consumed.insert(message.id)
        }
        try await acknowledgeConsumed(store: store, coordinator: coordinator)
        let jobs = coordinator.residentJobs(worldID: worldID, residentScope: residentScope)
        let automatic = Set(coordinator.automaticContinuationEvents(worldID: worldID, residentScope: residentScope).map(\.id))
        for message in agentMessages.values.sorted(by: { $0.sequence < $1.sequence }) {
            guard !queued.contains(message.id), !consumed.contains(message.id),
                  let job = jobs.first(where: { $0.jobID == message.taskId }),
                  let record = store.jobs.first(where: { $0.id == message.taskId }),
                  record.context?.worldID == worldID, record.context?.residentScope == residentScope,
                  case let .string(wishID)? = message.payload["wish_id"], wishID == job.id.uuidString,
                  case let .string(objectID)? = message.payload["object_id"], objectID == job.objectID else { continue }
            if message.kind == "wish.outputReady" && job.stage != .claimed && !outputIsRendered(job.objectID) { continue }
            var payload = message.payload
            payload["name"] = .string(job.name)
            payload["auto_continuation_paused"] = .bool(job.autoContinuationPaused == true)
            let data = try JSONEncoder().encode(payload)
            let event = ResidentAgentLoop.Event(id: "wish." + message.id.uuidString,
                kind: message.kind + "." + message.taskId.uuidString + "." + message.id.uuidString,
                summary: String(decoding: data, as: UTF8.self))
            // Only the current Rust receipt grants continuation. A native task
            // kind or a resume-looking payload cannot manufacture that grant.
            let continuation = automatic.contains(message.id)
            if onAgentEvent?(event, continuation) == true { queued.insert(message.id) }
        }
        return true
    }

    func receive(consumer: String, message: PropTaskMessage) -> Bool {
        guard !closed, consumer == "agent", message.worldID == worldID, message.residentScope == residentScope,
              message.kind.hasPrefix("wish."), !acknowledged.contains(message.id) else { return false }
        if consumed.contains(message.id) { return true } // Retry only the failed ACK, never the turn.
        agentMessages[message.id] = message
        return true
    }

    /// Queueing, displaying and beginning a turn never acknowledge a fact.
    /// Only the actual conversation owner's successful turn calls this.
    func didConsume(_ events: [ResidentAgentLoop.Event], coordinator: WishMachineCoordinator) throws {
        guard !closed else { return }
        let ids = Set(events.map(\.id))
        let completed = queued.filter { ids.contains("wish." + $0.uuidString) }
        // The model already completed all these events. Receipt failure must
        // never release their admission and repeat successful side effects.
        consumed.formUnion(completed)
        pendingDurableWrites.formUnion(completed)
        // Only the async durable flush may acknowledge either authority. Keep
        // these consumed facts out of agent admission while ACKs are retried.
    }

    func didNotConsume(_ events: [ResidentAgentLoop.Event]) {
        guard !closed else { return }
        let ids = Set(events.map(\.id))
        queued = queued.filter { consumed.contains($0) || !ids.contains("wish." + $0.uuidString) }
    }

    func snapshot() -> [String: Any] {
        ["status": closed ? "closed" : (onAgentEvent == nil ? "agent_not_bound" : (subscribed ? "subscribed" : "not_subscribed")),
         "consumer": "agent", "worldID": worldID, "residentScope": residentScope,
         "pending": agentMessages.count, "queuedForAgent": queued.count,
         "pendingDurableWrites": pendingDurableWrites.count,
         "awaitingAcknowledgement": consumed.count, "acknowledged": acknowledged.count]
    }

    private func acknowledgeConsumed(store: PropGenerationStore, coordinator: WishMachineCoordinator) async throws {
        for id in consumed {
            try Task.checkCancellation()
            guard !closed else { return }
            if !coordinator.isEventAcknowledged(id: id, worldID: worldID, residentScope: residentScope) {
                try await coordinator.acknowledgeEvent(id: id, worldID: worldID, residentScope: residentScope)
            }
            try await store.acknowledgeMessage(id: id, consumer: "agent", worldID: worldID, residentScope: residentScope)
            pendingDurableWrites.remove(id)
            agentMessages.removeValue(forKey: id)
            queued.remove(id)
            consumed.remove(id)
            acknowledged.insert(id)
        }
    }

    func close(store: PropGenerationStore) {
        closed = true
        store.unsubscribeMessages(consumer: "agent", worldID: worldID, residentScope: residentScope)
        onAgentEvent = nil
        agentMessages.removeAll(); queued.removeAll(); consumed.removeAll(); acknowledged.removeAll(); pendingDurableWrites.removeAll()
    }
}
