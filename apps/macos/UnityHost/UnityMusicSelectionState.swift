/// Playback queue changes only after a prepared candidate was accepted by the
/// actual host. A failed/cancelled request never advances the visible queue.
struct UnityMusicSelectionState<Item> {
    struct Ticket { let generation: UInt64; let queue: [Item]; let index: Int }
    private(set) var queue: [Item] = []
    private(set) var index = 0
    private var generation: UInt64 = 0
    mutating func begin(queue: [Item], index: Int) -> Ticket? {
        guard queue.indices.contains(index) else { return nil }
        generation &+= 1
        return Ticket(generation: generation, queue: queue, index: index)
    }
    mutating func commit(_ ticket: Ticket, accepted: Bool) -> Bool {
        guard accepted, ticket.generation == generation else { return false }
        queue = ticket.queue; index = ticket.index; return true
    }
    func isCurrent(_ ticket: Ticket) -> Bool { ticket.generation == generation }
    mutating func clear() { generation &+= 1; queue = []; index = 0 }
}

enum UnityMusicPageBoundary {
    static func isValid(offset: Int, expectedOffset: Int, returnedCount: Int, total: Int) -> Bool {
        offset == expectedOffset && offset >= 0 && returnedCount >= 0 && total >= 0
            && returnedCount <= Int.max - offset
            && (returnedCount == 0 || offset + returnedCount <= total)
    }
}

enum UnityMusicTrackSelection {
    /// A supplied identity must match the requested slot. Unknown tracks never
    /// silently resume another song; ambiguous IDs require an explicit slot.
    static func resolve(ids: [String], trackID: String?, slotIndex: Int?) -> Int? {
        if let index = slotIndex {
            guard ids.indices.contains(index), trackID == nil || ids[index] == trackID else { return nil }
            return index
        }
        guard let id = trackID else { return nil }
        let matches = ids.indices.filter { ids[$0] == id }
        return matches.count == 1 ? matches[0] : nil
    }
}
