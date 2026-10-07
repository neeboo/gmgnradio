import Foundation

// Compile with the production UnityWorldNotifications.swift. These doubles
// isolate routing/consumption policy; Rust HTTP durability is tested separately.
enum PropTaskJSON: Codable, Equatable { case string(String), bool(Bool) }
enum PropTaskDaemonError: Error { case invalidFrame }
struct PropTaskMessage { let id: UUID; let taskId: UUID; var worldID: String; let residentScope: String; let kind: String; let payload: [String: PropTaskJSON]; let sequence: Int }
struct ResidentAgentLoop { struct Event: Equatable { let id: String; let kind: String; let summary: String } }
struct OwnershipRow { struct Key { let jobID: UUID?; let identifier: String }; let key: Key; let statusText: String; let reasonText: String? }
struct WishMachineTaskPresentation { let id: UUID; let isTerminal: Bool }
struct WishMachineTaskMessageFeed {
    struct Input { let row: OwnershipRow; let promptExpiresAt: Date? }
    struct Message { let id: UUID; let taskID: String; let text: String }
    var messages: [Message] = []
    mutating func sync(_ rows: [Input], now: Date) {
        messages = rows.map { .init(id: UUID(), taskID: $0.row.key.identifier, text: $0.row.statusText) }
    }
}
struct ResidentSystemDelivery { let eventID: UUID; let taskID: String; let kind: String; let title: String; let status: String; let detail: String; let terminal: Bool }
@MainActor final class UnityInboxBridge {
    var delivered: [String: ResidentSystemDelivery] = [:]
    func deliver(_ messages: [ResidentSystemDelivery]) async throws -> Bool {
        for message in messages { delivered[message.taskID] = message }
        return true
    }
}
enum Stage: String { case outputReady, claimed }
struct Job { let id: UUID; let jobID: UUID?; let objectID: String; let name: String; var stage: Stage; var autoContinuationPaused: Bool? }
struct WishEvent {
    let id: UUID; let wishID: UUID; let objectID: String; let kind: Stage
    let computeMayContinue = false; let stage: Stage? = nil; let remoteState: Stage? = nil
    let message: String? = nil; let cancelRequested: Bool? = nil; let failureSource: String? = nil
    let autoContinuationPaused: Bool? = nil; let continuationResumeAuthorizationID: UUID? = nil
}
@MainActor final class WishMachineCoordinator {
    var jobs: [Job] = []; var events: [WishEvent] = []; var acked: [UUID] = []; var published: [UUID] = []; var failPersist = false; var failPersistAfter: Int? = nil
    func residentJobs(worldID: String, residentScope: String) -> [Job] { jobs }
    func unpublishedEvents(worldID: String, residentScope: String) -> [WishEvent] { [] }
    func automaticContinuationEvents(worldID: String, residentScope: String) -> [WishEvent] { events }
    func markEventPublished(id: UUID) throws { published.append(id) }
    func acknowledgeEvent(id: UUID, worldID: String, residentScope: String) throws {
        guard worldID == "world.origin", residentScope == "resident.origin", events.contains(where: { $0.id == id }), !failPersist else { throw PropTaskDaemonError.invalidFrame }
        if let failPersistAfter, acked.count >= failPersistAfter && !acked.contains(id) { throw PropTaskDaemonError.invalidFrame }
        if !acked.contains(id) { acked.append(id) }
    }
    func isEventAcknowledged(id: UUID, worldID: String, residentScope: String) -> Bool {
        worldID == "world.origin" && residentScope == "resident.origin" && acked.contains(id)
    }
}
@MainActor final class PropGenerationStore {
    struct Context { let worldID: String; let residentScope: String }
    struct Record { let id: UUID; var context: Context? }
    var jobs: [Record] = []; var subscriptions = 0; var unsubscribed = 0; var acked: [UUID] = []; var failAck = false
    var failSubscribe = false
    func subscribeMessages(consumer: String, worldID: String, residentScope: String) async throws {
        if failSubscribe { throw PropTaskDaemonError.invalidFrame }
        subscriptions += 1
    }
    func unsubscribeMessages(consumer: String, worldID: String, residentScope: String) { unsubscribed += 1 }
    func publishMessage(id: UUID, taskId: UUID, worldID: String, residentScope: String, kind: String, payload: [String: PropTaskJSON]) async throws -> PropTaskMessage { .init(id: id, taskId: taskId, worldID: worldID, residentScope: residentScope, kind: kind, payload: payload, sequence: 1) }
    func acknowledgeMessage(id: UUID, consumer: String, worldID: String, residentScope: String) async throws {
        if failAck { throw PropTaskDaemonError.invalidFrame }; acked.append(id)
    }
}
@main struct Tests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) { checks += 1; if !condition { print("FAIL: \(label)"); exit(1) } }
        let coordinator = WishMachineCoordinator(), store = PropGenerationStore()
        let ownershipInbox = UnityInboxBridge(), offlineStore = PropGenerationStore()
        let ownershipNotices = UnityWorldNotifications(worldID: "world.origin", residentScope: "resident.origin", inbox: ownershipInbox)
        let notifications = UnityWorldNotifications(worldID: "world.origin", residentScope: "resident.origin", inbox: UnityInboxBridge())
        let wishID = UUID(), taskID = UUID(), messageID = UUID()
        coordinator.jobs = [.init(id: wishID, jobID: taskID, objectID: "prop.output", name: "花盆", stage: .outputReady)]
        offlineStore.failSubscribe = true
        let rowKey = OwnershipRow.Key(jobID: wishID, identifier: wishID.uuidString)
        do {
            _ = try await ownershipNotices.synchronize(rows: [.init(key: rowKey, statusText: "已领取，入库尚未保存", reasonText: "入库回执尚未确认")], tasks: [.init(id: wishID, isTerminal: false)], coordinator: coordinator, store: offlineStore, outputIsRendered: { _ in false })
        } catch {}
        check(ownershipInbox.delivered[wishID.uuidString]?.status == "已领取，入库尚未保存", "unconfirmed ownership remains truthful when agent offline")
        do {
            _ = try await ownershipNotices.synchronize(rows: [.init(key: rowKey, statusText: "已入库", reasonText: nil)], tasks: [.init(id: wishID, isTerminal: true)], coordinator: coordinator, store: offlineStore, outputIsRendered: { _ in false })
        } catch {}
        check(ownershipInbox.delivered[wishID.uuidString]?.status == "已入库" && ownershipInbox.delivered[wishID.uuidString]?.terminal == true && ownershipInbox.delivered[wishID.uuidString]?.detail == "", "confirmed ownership replaces old failure despite unavailable agent subscription")
        coordinator.events = [.init(id: messageID, wishID: wishID, objectID: "prop.output", kind: .outputReady)]
        store.jobs = [.init(id: taskID, context: .init(worldID: "world.origin", residentScope: "resident.origin"))]
        var received: [(ResidentAgentLoop.Event, Bool)] = []
        notifications.onAgentEvent = { received.append(($0, $1)); return true }
        let message = PropTaskMessage(id: messageID, taskId: taskID, worldID: "world.origin", residentScope: "resident.origin", kind: "wish.outputReady", payload: ["wish_id": .string(wishID.uuidString), "object_id": .string("prop.output")], sequence: 1)
        check(!notifications.receive(consumer: "ui", message: message), "UI consumer cannot masquerade as resident consumption")
        var foreign = message; foreign.worldID = "world.foreign"
        check(!notifications.receive(consumer: "agent", message: foreign), "cross-world durable fact rejected")
        check(notifications.receive(consumer: "agent", message: message), "origin agent message accepted")
        _ = try await notifications.synchronize(rows: [], tasks: [], coordinator: coordinator, store: store, outputIsRendered: { _ in false })
        check(received.isEmpty && store.acked.isEmpty, "provider output alone cannot wake or ACK before world readback")
        store.jobs[0].context = nil
        _ = try await notifications.synchronize(rows: [], tasks: [], coordinator: coordinator, store: store, outputIsRendered: { _ in true })
        check(received.isEmpty, "missing persisted origin context never invents a resident")
        store.jobs[0].context = .init(worldID: "world.origin", residentScope: "resident.origin")
        _ = try await notifications.synchronize(rows: [], tasks: [], coordinator: coordinator, store: store, outputIsRendered: { _ in true })
        check(received.count == 1 && received[0].1, "verified origin output grants exactly one continuation")
        check(received[0].0.summary.contains("花盆"), "resident gets task identity and result facts")
        check(store.acked.isEmpty && coordinator.acked.isEmpty, "queued task is not yet consumed or acknowledged")
        _ = notifications.receive(consumer: "agent", message: message)
        _ = try await notifications.synchronize(rows: [], tasks: [], coordinator: coordinator, store: store, outputIsRendered: { _ in true })
        check(received.count == 1, "duplicate durable delivery never duplicates pending turn")
        // A failed/cancelled conversation never calls didConsume.
        check(notifications.snapshot()["awaitingAcknowledgement"] as? Int == 0, "unsuccessful conversation leaves durable message unacknowledged")
        notifications.didNotConsume([received[0].0])
        _ = try await notifications.synchronize(rows: [], tasks: [], coordinator: coordinator, store: store, outputIsRendered: { _ in true })
        check(received.count == 2 && store.acked.isEmpty, "failed conversation releases admission for bounded scheduler retry")
        coordinator.failPersist = true
        do { try notifications.didConsume([received[0].0], coordinator: coordinator); check(false, "persist failure must surface") } catch {}
        check(coordinator.acked.isEmpty && notifications.snapshot()["awaitingAcknowledgement"] as? Int == 1, "persist failure retains completed model receipt for retry")
        notifications.didNotConsume([received[0].0])
        do { _ = try await notifications.synchronize(rows: [], tasks: [], coordinator: coordinator, store: store, outputIsRendered: { _ in true }); check(false, "unpersisted receipt must surface") } catch {}
        check(received.count == 2 && store.acked.isEmpty, "failed receipt cannot release completed turn or ACK daemon")
        coordinator.failPersist = false
        try notifications.didConsume([received[0].0], coordinator: coordinator); store.failAck = true
        do { _ = try await notifications.synchronize(rows: [], tasks: [], coordinator: coordinator, store: store, outputIsRendered: { _ in true }); check(false, "failed ACK must surface") } catch {}
        check(notifications.snapshot()["awaitingAcknowledgement"] as? Int == 1 && coordinator.acked == [messageID], "failed daemon ACK preserves durable consumed fact for retry")
        let restarted = UnityWorldNotifications(worldID: "world.origin", residentScope: "resident.origin", inbox: UnityInboxBridge())
        restarted.onAgentEvent = { received.append(($0, $1)); return true }
        check(restarted.receive(consumer: "agent", message: message), "restart accepts daemon replay for reconciliation")
        do { _ = try await restarted.synchronize(rows: [], tasks: [], coordinator: coordinator, store: store, outputIsRendered: { _ in true }); check(false, "restart ACK failure surfaces") } catch {}
        check(received.count == 2, "restart after consumption before daemon ACK never reruns model turn")
        store.failAck = false
        _ = try await notifications.synchronize(rows: [], tasks: [], coordinator: coordinator, store: store, outputIsRendered: { _ in true })
        check(store.acked == [messageID] && coordinator.acked == [messageID], "successful actual conversation ACKs both durable owners")
        check(!notifications.receive(consumer: "agent", message: message), "acknowledged replay cannot schedule again")
        check(store.subscriptions == 2, "one origin-scoped agent subscription per owner")
        notifications.close(store: store)
        check(store.unsubscribed == 1 && !notifications.receive(consumer: "agent", message: message), "world close unbinds origin consumer permanently")
        let batchCoordinator = WishMachineCoordinator(), batchStore = PropGenerationStore()
        batchCoordinator.jobs = coordinator.jobs; batchStore.jobs = store.jobs
        let batch = UnityWorldNotifications(worldID: "world.origin", residentScope: "resident.origin", inbox: UnityInboxBridge())
        var batchEvents: [ResidentAgentLoop.Event] = []
        batch.onAgentEvent = { event, _ in batchEvents.append(event); return true }
        for sequence in 1...3 {
            let id = UUID()
            batchCoordinator.events.append(.init(id: id, wishID: wishID, objectID: "prop.output", kind: .outputReady))
            _ = batch.receive(consumer: "agent", message: .init(id: id, taskId: taskID, worldID: "world.origin", residentScope: "resident.origin", kind: "wish.outputReady", payload: message.payload, sequence: sequence))
        }
        _ = try await batch.synchronize(rows: [], tasks: [], coordinator: batchCoordinator, store: batchStore, outputIsRendered: { _ in true })
        batchCoordinator.failPersistAfter = 1
        do { try batch.didConsume(batchEvents, coordinator: batchCoordinator); check(false, "partial batch persist failure surfaces") } catch {}
        batch.didNotConsume(batchEvents)
        do { _ = try await batch.synchronize(rows: [], tasks: [], coordinator: batchCoordinator, store: batchStore, outputIsRendered: { _ in true }) } catch {}
        check(batchCoordinator.acked.count == 1 && batchEvents.count == 3, "partial receipt batch never reruns completed tail events")
        check(batchStore.acked.allSatisfy(batchCoordinator.acked.contains), "only committed receipt can ACK daemon")
        check(batch.snapshot()["pendingDurableWrites"] as? Int == 2, "diagnostics expose unconfirmed durable receipt writes")
        print("PASS: \(checks) production Unity wish notification policy checks (transport/UI doubles)")
    }
}
