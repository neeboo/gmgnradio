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
    private struct Storage: Codable {
        var version = 1
        var programs: [SavedDJProgram] = []
    }

    private let fileURL: URL
    private let capacity: Int
    private let fileManager: FileManager

    init(
        fileURL: URL,
        capacity: Int = 20,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
        self.fileManager = fileManager
    }

    static func live() -> DJProgramArchive {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return DJProgramArchive(
            fileURL: applicationSupport
                .appendingPathComponent("ai.gmgn.radio", isDirectory: true)
                .appendingPathComponent("programs.json")
        )
    }

    func save(
        plan: ProgramPlan,
        activeSlotIndex: Int?,
        updatedAt: Date = Date()
    ) throws {
        var storage = try readStorage()
        storage.programs.removeAll {
            $0.plan.brief.id == plan.brief.id
        }
        storage.programs.append(
            SavedDJProgram(
                plan: plan,
                activeSlotIndex: activeSlotIndex,
                updatedAt: updatedAt
            )
        )
        storage.programs.sort { $0.updatedAt > $1.updatedAt }
        storage.programs = Array(storage.programs.prefix(capacity))
        try write(storage)
    }

    func latest() throws -> SavedDJProgram? {
        try recent().first
    }

    func recent() throws -> [SavedDJProgram] {
        try readStorage().programs.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func readStorage() throws -> Storage {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return Storage()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            Storage.self,
            from: Data(contentsOf: fileURL)
        )
    }

    private func write(_ storage: Storage) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(storage).write(to: fileURL, options: .atomic)
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

    func restoreLatest() {
        refreshRecentPrograms()
        guard let saved = recentPrograms.first else {
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
        guard let archive else {
            return
        }
        try? archive.save(
            plan: saved.plan,
            activeSlotIndex: saved.activeSlotIndex,
            updatedAt: saved.updatedAt
        )
        refreshRecentPrograms()
    }

    private func refreshRecentPrograms() {
        guard let archive, let saved = try? archive.recent() else {
            return
        }
        if let pendingPlan {
            let draft = SavedDJProgram(
                plan: pendingPlan,
                activeSlotIndex: nil,
                updatedAt: pendingPlan.generatedAt
            )
            recentPrograms = [draft] + saved.filter {
                $0.plan.brief.id != pendingPlan.brief.id
            }
        } else {
            recentPrograms = saved
        }
    }
}
