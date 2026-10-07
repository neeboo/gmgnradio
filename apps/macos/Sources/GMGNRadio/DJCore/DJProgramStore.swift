import Foundation
import Observation

enum DJProgramStatus: Equatable, Sendable {
    case idle
    case planning
    case ready
    case failed(String)
}

struct SavedDJProgram: Codable, Equatable, Sendable {
    let plan: ProgramPlan
    let activeSlotIndex: Int?
    let updatedAt: Date
}

enum DJProgramEditMode {
    case replanUpcoming
    case insertNext
}

enum DJProgramEditor {
    static func revise(
        current: ProgramPlan,
        activeSlotIndex: Int,
        proposal: ProgramPlan,
        mode: DJProgramEditMode,
        generatedAt: Date = Date()
    ) -> ProgramPlan {
        guard !current.slots.isEmpty else {
            return ProgramPlan(
                brief: current.brief,
                slots: unique(proposal.slots),
                revision: current.revision + 1,
                generatedAt: generatedAt,
                replanAfterTrackCount: proposal.replanAfterTrackCount,
                title: proposal.title ?? current.title,
                direction: proposal.direction ?? current.direction
            )
        }

        let activeIndex = min(
            max(activeSlotIndex, 0),
            current.slots.count - 1
        )
        let played = Array(current.slots.prefix(activeIndex + 1))
        let playedTrackIDs = Set(played.map(\.track.id))
        let proposalSlots = unique(proposal.slots).filter {
            !playedTrackIDs.contains($0.track.id)
        }

        let upcoming: [ProgramSlot]
        let title: String?
        let direction: String?
        let replanAfterTrackCount: Int
        switch mode {
        case .replanUpcoming:
            upcoming = proposalSlots
            title = proposal.title ?? current.title
            direction = proposal.direction ?? current.direction
            replanAfterTrackCount = proposal.replanAfterTrackCount
        case .insertNext:
            let inserted = Array(proposalSlots.prefix(1))
            let insertedTrackIDs = Set(inserted.map(\.track.id))
            let existingUpcoming = current.slots
                .dropFirst(activeIndex + 1)
                .filter {
                    !insertedTrackIDs.contains($0.track.id)
                }
            upcoming = inserted + existingUpcoming
            title = current.title
            direction = current.direction
            replanAfterTrackCount = current.replanAfterTrackCount
        }

        return ProgramPlan(
            brief: current.brief,
            slots: played + upcoming,
            revision: current.revision + 1,
            generatedAt: generatedAt,
            replanAfterTrackCount: replanAfterTrackCount,
            title: title,
            direction: direction
        )
    }

    private static func unique(
        _ slots: [ProgramSlot]
    ) -> [ProgramSlot] {
        var seenTrackIDs = Set<String>()
        return slots.filter {
            seenTrackIDs.insert($0.track.id).inserted
        }
    }
}

@MainActor
final class DJProgramArchive {
    private let storage: MusicStorageClient

    static func live() -> DJProgramArchive {
        DJProgramArchive(storage: .shared)
    }

    init(storage: MusicStorageClient) {
        self.storage = storage
    }

    func save(
        plan: ProgramPlan,
        activeSlotIndex: Int?,
        updatedAt: Date = Date(),
        pending: Bool = false
    ) async throws {
        try await storage.save(SavedDJProgram(plan: plan, activeSlotIndex: activeSlotIndex, updatedAt: updatedAt), pending: pending)
    }

    func latest() async throws -> SavedDJProgram? {
        try await recent().first
    }

    func recent() async throws -> [SavedDJProgram] {
        try await snapshot().programs
    }

    func snapshot() async throws -> MusicStorageClient.Programs {
        let snapshot = try await storage.programs()
        return .init(programs: snapshot.programs.sorted { $0.updatedAt > $1.updatedAt }, pendingIDs: snapshot.pendingIDs)
    }
}

@MainActor
@Observable
final class DJProgramStore {
    static let shared = DJProgramStore(archive: .live())

    private(set) var status: DJProgramStatus = .idle
    private(set) var plan: ProgramPlan?
    private(set) var pendingPlan: ProgramPlan?
    private(set) var activeSlotIndex: Int?
    private(set) var recentPrograms: [SavedDJProgram] = []
    private let archive: DJProgramArchive?
    private var persistence: Task<Void, Error>?
    private(set) var isLoaded = false
    private var pendingIDs = Set<String>()

    init(archive: DJProgramArchive? = nil) {
        self.archive = archive
    }

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
        if pendingPlan?.brief.id == plan.brief.id {
            pendingPlan = nil
        }
        activeSlotIndex = nil
        status = .ready
        persist()
    }

    func publishDraft(_ plan: ProgramPlan) {
        pendingPlan = plan
        status = .ready
        let saved = SavedDJProgram(
            plan: plan,
            activeSlotIndex: nil,
            updatedAt: Date()
        )
        recentPrograms.removeAll {
            $0.plan.brief.id == plan.brief.id
        }
        recentPrograms.insert(saved, at: 0)
        enqueue(saved, pending: true)
    }

    @discardableResult
    func takePendingPlan() -> ProgramPlan? {
        defer { pendingPlan = nil }
        return pendingPlan
    }

    func activateSlot(at index: Int) {
        guard let slots = plan?.slots, slots.indices.contains(index) else {
            activeSlotIndex = nil
            persist()
            return
        }
        activeSlotIndex = index
        persist()
    }

    @discardableResult
    func selectProgram(id: String) -> ProgramPlan? {
        guard let saved = recentPrograms.first(where: {
            $0.plan.brief.id == id
        }) else {
            return nil
        }
        plan = saved.plan
        if pendingPlan?.brief.id == saved.plan.brief.id {
            pendingPlan = nil
        }
        activeSlotIndex = nil
        status = .ready
        return saved.plan
    }

    func restoreLatest() async {
        do { try await refreshRecentPrograms() }
        catch { fail("节目存储读取失败：\(error.localizedDescription)"); return }
        guard let saved = recentPrograms.first(where: { !pendingIDs.contains($0.plan.brief.id) }) else {
            return
        }
        plan = saved.plan
        if
            let index = saved.activeSlotIndex,
            saved.plan.slots.indices.contains(index)
        {
            activeSlotIndex = index
        } else {
            activeSlotIndex = nil
        }
        status = .ready
    }

    func fail(_ message: String) {
        status = .failed(message)
    }

    private func persist() {
        guard let plan else {
            return
        }
        let saved = SavedDJProgram(
            plan: plan,
            activeSlotIndex: activeSlotIndex,
            updatedAt: Date()
        )
        recentPrograms.removeAll {
            $0.plan.brief.id == plan.brief.id
        }
        recentPrograms.insert(saved, at: 0)
        guard archive != nil else {
            return
        }
        enqueue(saved, pending: false)
    }

    func refreshRecentPrograms() async throws {
        do { try await flush() } catch { persistence = nil }
        guard let archive else { isLoaded = true; return }
        let snapshot = try await archive.snapshot()
        recentPrograms = snapshot.programs
        pendingIDs = Set(snapshot.pendingIDs)
        pendingPlan = snapshot.programs.first { snapshot.pendingIDs.contains($0.plan.brief.id) }?.plan
        isLoaded = true
    }

    func flush() async throws { try await persistence?.value }

    private func enqueue(_ saved: SavedDJProgram, pending: Bool) {
        guard let archive else { return }
        let previous = persistence
        persistence = Task { [weak self] in
            // A failed prior write remains visible but does not prevent retrying newer state.
            do { try await previous?.value } catch { }
            do {
                try await archive.save(plan: saved.plan, activeSlotIndex: saved.activeSlotIndex,
                                       updatedAt: saved.updatedAt, pending: pending)
            } catch {
                self?.fail("节目保存失败：\(error.localizedDescription)")
                throw error
            }
        }
    }
}
