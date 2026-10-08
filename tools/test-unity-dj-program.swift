import Foundation
let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = repository.appendingPathComponent("apps/macos/Sources/GMGNRadio")
func read(_ file: String) throws -> String { try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8) }
let planner = try read("DJCore/ProgramPlanner.swift")
let planTypes = String(planner[..<planner.range(of: "enum ProgramPlannerError:")!.lowerBound])
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-unity-dj-private-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: scratch) }
let harness = #"""
import Foundation
\#(try String(contentsOf: repository.appendingPathComponent("tools/fixtures/MusicStorageRPCFixture.swift"), encoding: .utf8))
\#(planTypes)
\#(try read("DJCore/AgentShowProposal.swift"))
struct DJAgentPreferences {}
struct CodexTrackRankingAgent { static func live(preferences: DJAgentPreferences) throws -> Self { Self() } }
@MainActor final class MusicRuntime {
    func dailyProgramBrief(instruction: String?) async throws -> ProgramBrief { fatalError("Fixture must not invoke live planner") }
    func makeProgramPlan(brief: ProgramBrief, agent: CodexTrackRankingAgent) async throws -> ProgramPlan { fatalError("Fixture must not invoke live planner") }
}
@MainActor func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
}
@MainActor final class OwnedPrograms {
    let backend = MusicStorageRPCFixture()
    lazy var client = RustMusicProgramClient(call: backend.call)
    lazy var library = SyncedMusicLibraryStore(storage: backend.client)
    private var plans: [String: ProgramPlan] = [:]
    func plan(_ id: String, _ tracks: [String]) async throws -> ProgramPlan {
        if let existing = plans[id] { return existing }
        let facts = tracks.map { MusicCandidate(id: $0, canonicalID: nil, providerID: .local, source: .localLibrary, title: $0, artist: "fixture", album: nil, duration: 180, isPlayable: true, matchScore: 1, userAffinity: 0.5, energy: 0.5, moodTags: [], genres: [], releaseYear: nil) }
        library.merge(playlists: [MusicPlaylistSnapshot(id: id, providerID: .local, name: id, artworkURL: nil, tracks: facts, totalTrackCount: facts.count)])
        try await library.flush()
        let plan = try await client.playlistPlan(playlistID: id)
        plans[id] = plan
        return plan
    }
}
enum FixtureFailure: Error { case playback }
@main struct Test {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unity-dj-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0, activations = 0, failActivation = true
        var notifications: [String] = [], revisedTracks: [String] = []
        let fixture = OwnedPrograms()
        let backend = fixture.backend
        let client = fixture.client
        let bridge = UnityDJProgramBridge(archiveRoot: root, hooks: .init(plan: { instruction in
            calls += 1
            if instruction == "stale" { try? await Task.sleep(for: .milliseconds(50)); return try await fixture.plan("stale", ["stale"]) }
            return try await fixture.plan("proposal", ["inserted"])
        }, activate: { proposal in
            activations += 1
            if failActivation { throw FixtureFailure.playback }
            return 0
        }, replaceUpcoming: { revised, index in
            precondition(index == 0)
            revisedTracks = revised.slots.map { $0.track.id }
        }, notify: { notifications.append($0) }), storage: backend.client, programClient: client)
        try bridge.replan(immediateInstruction: "draft")
        try await waitUntil { bridge.store.pendingPlan != nil }
        precondition(bridge.store.pendingPlan?.brief.id == "proposal")
        precondition(bridge.store.plan == nil && activations == 0)
        do { try await bridge.activate(); preconditionFailure("Failed player must not publish") } catch FixtureFailure.playback {}
        precondition(bridge.store.pendingPlan != nil && bridge.store.plan == nil)
        failActivation = false
        try await bridge.activate()
        precondition(bridge.store.pendingPlan == nil && bridge.store.activeSlotIndex == 0)
        try await bridge.store.publish(fixture.plan("current", ["playing", "later"]))
        try await bridge.activateSlot(at: 0)
        try bridge.insert(immediateInstruction: "insert")
        try await waitUntil { !revisedTracks.isEmpty }
        precondition(revisedTracks == ["playing", "inserted", "later"])
        precondition(bridge.store.activeSlot?.track.id == "playing" && activations == 2)
        try bridge.replan(immediateInstruction: "stale")
        await Task.yield()
        try bridge.replan(immediateInstruction: "new")
        try await waitUntil { bridge.store.pendingPlan != nil }
        try await Task.sleep(for: .milliseconds(80))
        precondition(bridge.store.pendingPlan?.brief.id == "proposal")
        precondition(!notifications.contains { $0.contains("stale，") })
        bridge.shutdown()
        try await bridge.store.activateSlot(at: 1)
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
            }), storage: backend.client, programClient: RustMusicProgramClient(call: backend.call))
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
"""#
let input = scratch.appendingPathComponent("main.swift")
try harness.write(to: input, atomically: true, encoding: .utf8)
let files = ["MusicSources/MusicSource.swift", "MusicSources/MusicStorageClient.swift", "MusicSources/SyncedMusicLibraryStore.swift", "DJCore/DJProgramStore.swift", "DJCore/RustMusicProgramClient.swift", "MusicKnowledge/TrackKnowledge.swift", "MusicKnowledge/CandidatePoolBuilder.swift", "Domain/PlaybackContext.swift"]
func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
    try p.run(); p.waitUntilExit(); return p.terminationStatus
}
let output = scratch.appendingPathComponent("test")
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library"] + files.map { sources.appendingPathComponent($0).path } + [repository.appendingPathComponent("apps/macos/UnityHost/UnityDJProgramBridge.swift").path, input.path, "-o", output.path])
guard compiled == 0 else { exit(compiled) }
exit(try run(output.path, []))
