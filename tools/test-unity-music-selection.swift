import Foundation

@main struct MusicSelectionRegression {
    static func main() {
        precondition(UnityMusicTrackSelection.resolve(ids: ["a", "b"], trackID: "b", slotIndex: nil) == 1)
        precondition(UnityMusicTrackSelection.resolve(ids: ["a", "b"], trackID: nil, slotIndex: 1) == 1)
        precondition(UnityMusicTrackSelection.resolve(ids: ["a", "b"], trackID: "a", slotIndex: 1) == nil)
        precondition(UnityMusicTrackSelection.resolve(ids: ["a", "b"], trackID: "missing", slotIndex: nil) == nil)
        precondition(UnityMusicTrackSelection.resolve(ids: ["a", "a"], trackID: "a", slotIndex: nil) == nil)
        precondition(UnityMusicTrackSelection.resolve(ids: ["a", "a"], trackID: "a", slotIndex: 1) == 1)
        precondition(UnityMusicTrackSelection.resolve(ids: ["a"], trackID: nil, slotIndex: -1) == nil)
        var state = UnityMusicSelectionState<String>()
        let large = (0..<1940).map { "track-\($0)" }
        let first = state.begin(queue: large, index: 4)!
        precondition(state.queue.isEmpty && state.index == 0)
        precondition(state.commit(first, accepted: true))
        precondition(state.queue.count == 1940 && state.index == 4)
        let next = state.begin(queue: state.queue, index: 5)!
        precondition(state.index == 4)
        precondition(!state.commit(next, accepted: false))
        precondition(state.index == 4 && state.queue == large)
        let replacement = state.begin(queue: ["other-a", "other-b"], index: 1)!
        precondition(!state.commit(replacement, accepted: false))
        precondition(state.queue == large && state.index == 4)
        let stale = state.begin(queue: large, index: 8)!
        let current = state.begin(queue: large, index: 9)!
        precondition(!state.commit(stale, accepted: true))
        precondition(state.commit(current, accepted: true) && state.index == 9)
        let cancelled = state.begin(queue: large, index: 10)!
        state.clear()
        precondition(!state.commit(cancelled, accepted: true) && state.queue.isEmpty)
        precondition(state.begin(queue: large, index: -1) == nil)
        precondition(state.begin(queue: large, index: large.count) == nil)
        precondition(UnityMusicPageBoundary.isValid(offset: 200, expectedOffset: 200, returnedCount: 200, total: 1940))
        precondition(UnityMusicPageBoundary.isValid(offset: 1800, expectedOffset: 1800, returnedCount: 140, total: 1940))
        precondition(UnityMusicPageBoundary.isValid(offset: 1940, expectedOffset: 1940, returnedCount: 0, total: 1940))
        precondition(!UnityMusicPageBoundary.isValid(offset: 0, expectedOffset: 200, returnedCount: 200, total: 1940))
        precondition(!UnityMusicPageBoundary.isValid(offset: 1800, expectedOffset: 1800, returnedCount: 200, total: 1940))
        precondition(!UnityMusicPageBoundary.isValid(offset: Int.max, expectedOffset: Int.max, returnedCount: 1, total: Int.max))
        print("PASS 1940-track transaction: pending/failed load/replaced playlist/stale/cancel/bounds preserve committed queue")
        print("PASS page boundaries: contiguous/full/final/empty accepted; wrong offset/overflow/over-total rejected")
    }
}
