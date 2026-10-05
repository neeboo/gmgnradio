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
