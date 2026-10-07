import Foundation

// Fixtures replace only planner/player dependencies. Store, editor and bridge are production sources.
enum ConversationMode: String, Codable { case ambient }
struct ProgramBrief: Codable, Equatable {
    let id: String
    let targetDuration: Double
    let moodTags: [String]
    let energyArc: [Double]
    let conversationMode: ConversationMode
    let immediateUserInstruction: String?
}
struct Track: Codable, Equatable {
    let id: String
    var title: String { id }
    var artist: String { "fixture" }
    var duration: Double { 180 }
}
struct ProgramSlot: Codable, Equatable { let track: Track }
struct ProgramPlan: Codable, Equatable {
    let brief: ProgramBrief
    let slots: [ProgramSlot]
    let revision: Int
    let generatedAt: Date
    let replanAfterTrackCount: Int
    let title: String?
    let direction: String?
}
struct DJAgentPreferences {}
struct MusicPlaylistSnapshot: Codable, Equatable { }
struct CodexTrackRankingAgent { static func live(preferences: DJAgentPreferences) throws -> Self { Self() } }
@MainActor final class MusicRuntime {
    func makeProgramPlan(brief: ProgramBrief, agent: CodexTrackRankingAgent) async throws -> ProgramPlan { fatalError("Fixture must not invoke live planner") }
}
func plan(_ id: String, _ tracks: [String]) -> ProgramPlan {
    .init(brief: .init(id: id, targetDuration: 1800, moodTags: [], energyArc: [], conversationMode: .ambient, immediateUserInstruction: nil), slots: tracks.map { .init(track: .init(id: $0)) }, revision: 1, generatedAt: Date(), replanAfterTrackCount: 5, title: id, direction: nil)
}
enum FixtureFailure: Error { case playback }
@main struct Test {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unity-dj-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0, activations = 0, failActivation = true
        var notifications: [String] = [], revisedTracks: [String] = []
        let backend = MusicStorageRPCFixture()
        let bridge = UnityDJProgramBridge(archiveRoot: root, hooks: .init(plan: { instruction in
            calls += 1
            if instruction == "stale" { try? await Task.sleep(for: .milliseconds(50)); return plan("stale", ["stale"]) }
            return plan("proposal", ["inserted"])
        }, activate: { proposal in
            activations += 1
            if failActivation { throw FixtureFailure.playback }
            return 0
        }, replaceUpcoming: { revised, index in
            precondition(index == 0)
            revisedTracks = revised.slots.map { $0.track.id }
        }, notify: { notifications.append($0) }), storage: backend.client)
        try bridge.replan(immediateInstruction: "draft")
        for _ in 0..<20 where bridge.store.pendingPlan == nil { await Task.yield() }
        precondition(bridge.store.pendingPlan?.brief.id == "proposal")
        precondition(bridge.store.plan == nil && activations == 0)
        do { try await bridge.activate(); preconditionFailure("Failed player must not publish") } catch FixtureFailure.playback {}
        precondition(bridge.store.pendingPlan != nil && bridge.store.plan == nil)
        failActivation = false
        try await bridge.activate()
        precondition(bridge.store.pendingPlan == nil && bridge.store.activeSlotIndex == 0)
        bridge.store.publish(plan("current", ["playing", "later"]))
        bridge.activateSlot(at: 0)
        try bridge.insert(immediateInstruction: "insert")
        for _ in 0..<30 where revisedTracks.isEmpty { await Task.yield() }
        precondition(revisedTracks == ["playing", "inserted", "later"])
        precondition(bridge.store.activeSlot?.track.id == "playing" && activations == 2)
        try bridge.replan(immediateInstruction: "stale")
        await Task.yield()
        try bridge.replan(immediateInstruction: "new")
        try await Task.sleep(for: .milliseconds(80))
        precondition(bridge.store.pendingPlan?.brief.id == "proposal")
        precondition(!notifications.contains { $0.contains("stale，") })
        bridge.shutdown()
        bridge.store.activateSlot(at: 1)
        try await bridge.store.flush()
        var restoreCalls = 0
        var rejectHistory = true
        var historySelections: [Int] = []
        let reopened = UnityDJProgramBridge(archiveRoot: root, hooks: .init(
            plan: { _ in preconditionFailure("Restore must not plan") },
            activate: { _ in preconditionFailure("Restore must not autoplay") },
            replaceUpcoming: { _, _ in }, notify: { _ in }, restore: { saved, index in
                restoreCalls += 1
                precondition(saved.brief.id == "current" && index == 1)
                return index
            }, selectHistorical: { saved, index in
                precondition(saved.brief.id == "current")
                if rejectHistory { throw FixtureFailure.playback }
                historySelections.append(index)
                return index
            }), storage: backend.client)
        precondition(reopened.activePlaybackPlan == nil)
        let restored = try await reopened.restoreSavedPlayback()
        precondition(restored && restoreCalls == 1 && reopened.activePlaybackPlan?.brief.id == "current")
        let repeated = try await reopened.restoreSavedPlayback()
        precondition(!repeated && restoreCalls == 1)
        let programs = reopened.historySnapshot["programs"] as! [[String: Any]]
        precondition(JSONSerialization.isValidJSONObject(reopened.historySnapshot))
        precondition(programs.contains { $0["id"] as? String == "current" && $0["count"] as? Int == 3 })
        do { try await reopened.selectProgram(id: "current", slotIndex: 0); preconditionFailure("Rejected history player changed store") } catch FixtureFailure.playback {}
        precondition(reopened.store.activeSlotIndex == 1 && historySelections.isEmpty)
        rejectHistory = false
        try await reopened.selectProgram(id: "current", slotIndex: 2)
        precondition(reopened.store.activeSlotIndex == 2 && historySelections == [2])
        do { try await reopened.selectProgram(id: "current", slotIndex: 99); preconditionFailure("Invalid slot accepted") } catch UnityDJProgramBridge.Failure.noPreparedProgram {}
        reopened.releasePlayback()
        precondition(reopened.activePlaybackPlan == nil)
        do { try bridge.replan(immediateInstruction: nil); preconditionFailure("Closed bridge accepted plan") } catch UnityDJProgramBridge.Failure.closed {}
        precondition(calls >= 3)
        print("PASS: draft does not switch; failed activation retains pending; confirmed activation; insertion preserves current; stale result rejected; shutdown blocks planning")
    }
}
