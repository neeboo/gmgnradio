import Foundation
import Combine
/// Observation/projection adapter. SQLite owns plans, fact-ID dedupe and FIFO.
@MainActor final class ResidentMemoryStore: ObservableObject {
    static let maximumGroundedEvents = 24
    static let maximumPendingFacts = 200
    static let planKey = "plan"
    struct Snapshot: Equatable, Sendable { var intent: ResidentAgentLoop.Intent?; var intentPausedByUser: Bool; var groundedEvents: [ResidentAgentLoop.Event] }
    struct PlanValue: Codable, Equatable, Sendable { var intent: ResidentAgentLoop.Intent?; var intentPausedByUser: Bool; var groundedEvents: [ResidentAgentLoop.Event] }
    @Published private(set) var persistenceError: String?
    var onPersistenceError: ((String) -> Void)?
    private let authority: RustResidentIntentClient
    private var observations: [(ResidentStateScope, [ResidentAgentLoop.Event])] = []
    private var drainTask: Task<Void, Never>?
    init(client: ResidentStateClient, clock: @escaping () -> Date = Date.init) { authority = RustResidentIntentClient(client: client) }
    func bind(scope: ResidentStateScope) { }
    // Compatibility presentation arguments cannot overwrite Rust intent state.
    func save(scope: ResidentStateScope, intent: ResidentAgentLoop.Intent?, intentPausedByUser: Bool, groundedEvents: [ResidentAgentLoop.Event]) {
        observations.append((scope, groundedEvents)); guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }; defer { self.drainTask = nil }
            do {
                var lastScope = scope
                while true {
                    while !self.observations.isEmpty {
                        let observation = self.observations[0]
                        try await self.authority.enqueue(scope: observation.0, events: observation.1)
                        self.observations.removeFirst(); lastScope = observation.0
                    }
                    while try await self.authority.drain(scope: lastScope) { }
                    if self.observations.isEmpty { break }
                }
                self.persistenceError = nil
            } catch { self.report(error) }
        }
    }
    func restore(scope: ResidentStateScope) async throws -> Snapshot? {
        guard let value = try await authority.restore(scope: scope) else { return nil }
        return Snapshot(intent: value.intent, intentPausedByUser: value.intentPausedByUser, groundedEvents: value.groundedEvents)
    }
    func update(scope: ResidentStateScope, runID: UUID, hostSessionID: String, summary: String, status: ResidentAgentLoop.IntentStatus, wakeAfterSeconds: Double?, resumePausedIntent: Bool, plan: ResidentAgentLoop.IntentPlanRevision?, now: Date) async throws -> PlanValue {
        try await authority.update(scope: scope, runID: runID, hostSessionID: hostSessionID, summary: summary, status: status, wakeAfterSeconds: wakeAfterSeconds, resumePausedIntent: resumePausedIntent, plan: plan, now: now)
    }
    func pause(scope: ResidentStateScope, action: String) async throws -> PlanValue { try await authority.pause(scope: scope, action: action) }
    private func report(_ error: Error) { let message = "居民安排未能保存：\(error.localizedDescription)；未确认持久成功，等待下次显式操作。"; persistenceError = message; onPersistenceError?(message) }
    static func stateValue(_ plan: PlanValue) throws -> [String: ResidentStateJSON] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let tree = try JSONDecoder().decode(ResidentStateJSON.self, from: encoder.encode(plan)); guard case let .object(value) = tree else { throw ResidentStateError.unreadableArchive }; return value
    }
    static func decodePlan(_ value: [String: ResidentStateJSON]) throws -> PlanValue {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(PlanValue.self, from: JSONEncoder().encode(ResidentStateJSON.object(value))) } catch { throw ResidentStateError.unreadableArchive }
    }
}
