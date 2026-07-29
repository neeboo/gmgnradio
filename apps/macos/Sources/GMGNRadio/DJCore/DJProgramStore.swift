import Observation

enum DJProgramStatus: Equatable, Sendable {
    case idle
    case planning
    case ready
    case failed(String)
}

@MainActor
@Observable
final class DJProgramStore {
    static let shared = DJProgramStore()

    private(set) var status: DJProgramStatus = .idle
    private(set) var plan: ProgramPlan?

    func beginPlanning() {
        status = .planning
    }

    func publish(_ plan: ProgramPlan) {
        self.plan = plan
        status = .ready
    }

    func fail(_ message: String) {
        status = .failed(message)
    }
}
