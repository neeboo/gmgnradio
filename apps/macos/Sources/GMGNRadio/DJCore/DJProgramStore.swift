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
    private(set) var activeSlotIndex: Int?

    var activeSlot: ProgramSlot? {
        guard
            let activeSlotIndex,
            let slots = plan?.slots,
            slots.indices.contains(activeSlotIndex)
        else {
            return nil
        }
        return slots[activeSlotIndex]
    }

    func beginPlanning() {
        status = .planning
    }

    func publish(_ plan: ProgramPlan) {
        self.plan = plan
        activeSlotIndex = nil
        status = .ready
    }

    func activateSlot(at index: Int) {
        guard let slots = plan?.slots, slots.indices.contains(index) else {
            activeSlotIndex = nil
            return
        }
        activeSlotIndex = index
    }

    func fail(_ message: String) {
        status = .failed(message)
    }
}
