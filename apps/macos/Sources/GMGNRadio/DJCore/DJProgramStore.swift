import Foundation
import Observation

enum DJProgramStatus: Equatable, Sendable { case idle, planning, ready, failed(String) }
struct SavedDJProgram: Codable, Equatable, Sendable {
    let plan: ProgramPlan
    let activeSlotIndex: Int?
    let updatedAt: Date
}
enum DJProgramEditMode { case replanUpcoming, insertNext }

@MainActor enum DJProgramEditor {
    static func revise(current: ProgramPlan, activeSlotIndex: Int, proposal: ProgramPlan,
                       mode: DJProgramEditMode, generatedAt: Date = Date(),
                       client: RustMusicProgramClient? = nil) async throws -> ProgramPlan {
        let view = try await (client ?? RustMusicProgramClient()).command("revise", programID: current.brief.id,
            index: activeSlotIndex, proposalID: proposal.brief.id,
            mode: mode == .replanUpcoming ? "replanUpcoming" : "insertNext")
        guard let plan = view.selectedPlan else { throw PropTaskDaemonError.invalidFrame }
        return plan
    }
}

/// Legacy import/read compatibility; native code cannot commit candidate plans.
@MainActor final class DJProgramArchive {
    private let storage: MusicStorageClient
    static func live() -> DJProgramArchive { DJProgramArchive(storage: .shared) }
    init(storage: MusicStorageClient) { self.storage = storage }
    func save(plan: ProgramPlan, activeSlotIndex: Int?, updatedAt: Date = Date(), pending: Bool = false) async throws {
        throw PropTaskDaemonError.invalidFrame
    }
    func latest() async throws -> SavedDJProgram? { try await recent().first }
    func recent() async throws -> [SavedDJProgram] { try await snapshot().programs }
    func snapshot() async throws -> MusicStorageClient.Programs {
        let snapshot = try await storage.programs()
        return .init(programs: snapshot.programs.sorted { $0.updatedAt > $1.updatedAt }, pendingIDs: snapshot.pendingIDs)
    }
    func importLegacy() async throws { try await storage.importLegacy() }
}

@MainActor @Observable final class DJProgramStore {
    static let shared = DJProgramStore(archive: .live())
    private(set) var status: DJProgramStatus = .idle
    private(set) var plan: ProgramPlan?
    private(set) var pendingPlan: ProgramPlan?
    private(set) var activeSlotIndex: Int?
    private(set) var recentPrograms: [SavedDJProgram] = []
    private(set) var isLoaded = false
    private let archive: DJProgramArchive?
    private let client: RustMusicProgramClient
    private var projectedRevision: UInt64?
    init(archive: DJProgramArchive? = nil, client: RustMusicProgramClient? = nil) {
        self.archive = archive; self.client = client ?? RustMusicProgramClient()
    }
    var activeSlot: ProgramSlot? {
        guard let activeSlotIndex, let slots = plan?.slots, slots.indices.contains(activeSlotIndex) else { return nil }
        return slots[activeSlotIndex]
    }
    func beginPlanning() { status = .planning }
    func fail(_ message: String) { status = .failed(message) }
    private func project(_ view: RustMusicProgramClient.View) {
        guard projectedRevision == nil || view.revision >= projectedRevision! else { return }
        projectedRevision = view.revision
        plan = view.plan; pendingPlan = view.pendingPlan; activeSlotIndex = view.activeSlotIndex
        recentPrograms = view.programs; isLoaded = true; status = .ready
    }
    private func mutate(_ op: String, programID: String? = nil, index: Int? = nil) async throws -> RustMusicProgramClient.View {
        do { let view = try await client.command(op, programID: programID, index: index); project(view); return view }
        catch { fail("节目状态更新失败：\(error.localizedDescription)"); throw error }
    }
    func publish(_ plan: ProgramPlan) async throws { _ = try await mutate("publish", programID: plan.brief.id) }
    func publishDraft(_ plan: ProgramPlan) async throws { _ = try await mutate("draft", programID: plan.brief.id) }
    func revise(activeSlotIndex: Int, proposal: ProgramPlan, mode: DJProgramEditMode) async throws -> ProgramPlan {
        guard let plan else { throw PropTaskDaemonError.invalidFrame }
        return try await DJProgramEditor.revise(current: plan, activeSlotIndex: activeSlotIndex, proposal: proposal, mode: mode, client: client)
    }
    @discardableResult func takePendingPlan() async throws -> ProgramPlan? { try await mutate("take_pending").selectedPlan }
    func activateSlot(at index: Int) async throws { _ = try await mutate("activate_slot", index: index) }
    @discardableResult func selectProgram(id: String) async throws -> ProgramPlan? { try await mutate("select", programID: id).selectedPlan }
    func restoreLatest() async throws {
        try await refreshRecentPrograms()
        _ = try await mutate("restore_latest")
    }
    func refreshRecentPrograms() async throws {
        do { try await archive?.importLegacy(); project(try await client.read()) }
        catch { fail("节目存储读取失败：\(error.localizedDescription)"); throw error }
    }
    func flush() async throws { try await client.flush() }
}
