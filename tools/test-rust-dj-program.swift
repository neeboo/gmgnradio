import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
func read(_ path: String) throws -> String { try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8) }
let planner = try read("DJCore/ProgramPlanner.swift")
let planTypes = String(planner[..<planner.range(of: "enum ProgramPlannerError:")!.lowerBound])
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-dj-private-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: scratch) }
let harness = #"""
import Foundation
\#(try String(contentsOf: root.appendingPathComponent("tools/fixtures/MusicStorageRPCFixture.swift"), encoding: .utf8))
\#(planTypes)
\#(try read("DJCore/AgentShowProposal.swift"))
var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    guard condition else { print("FAIL: \(message)"); exit(1) }
}
func track(_ id: String, artist: String, playable: Bool = true) -> MusicCandidate {
    MusicCandidate(id: id, canonicalID: nil, providerID: .local, source: .localLibrary,
        title: id, artist: artist, album: "Album", duration: 240, isPlayable: playable,
        matchScore: 0.8, userAffinity: 0.6, energy: 0.5, moodTags: ["calm"], genres: [], releaseYear: 2024)
}
@main struct Main {
    @MainActor static func main() async throws {
        let backend = MusicStorageRPCFixture()
        let client = RustMusicProgramClient(call: backend.call)
        let store = DJProgramStore(client: client)
        let brief = ProgramBrief(id: UUID().uuidString, targetDuration: 1200, moodTags: ["calm"], energyArc: [0.3,0.8,0.2], conversationMode: .quiet, immediateUserInstruction: "少说点", blockedTrackIDs: ["blocked"])
        let facts = [track("one", artist: "A"),track("two",artist:"B"),track("three",artist:"C"),track("four",artist:"D"),track("five",artist:"E"),track("blocked",artist:"F"),track("broken",artist:"G",playable:false)]
        let plan = try await client.plan(brief: brief, discoveryCandidates: facts, libraryCandidates: facts, hostPrompt: "", executable: nil)
        check(plan.slots.count == 5, "real Rust fallback selects five unique playable tracks")
        check(Set(plan.slots.map(\.track.id)).count == 5 && !plan.slots.contains(where: { ["blocked","broken"].contains($0.track.id) }), "merge dedupe and exclusion are authoritative")
        check(plan.slots.filter(\.hostHint.shouldTalkBefore).count <= 1, "quiet host policy is preserved")
        try await store.publish(plan)
        check(store.plan == plan && store.status == .ready, "publish is actual authority read-confirmed")
        try await store.activateSlot(at: 2)
        check(store.activeSlot?.track == plan.slots[2].track, "actual activation projects exact slot")
        let read = try await client.read()
        check(read.plan == store.plan && read.activeSlotIndex == 2, "same SQLite read confirms projection")
        let fresh = DJProgramStore(client: RustMusicProgramClient(call: backend.call))
        try await fresh.restoreLatest()
        check(fresh.plan == plan && fresh.activeSlotIndex == 2, "new native projection restores durable actual plan")
        // Read again because the independent restore changed the shared revision.
        try await store.refreshRecentPrograms()
        let draftBrief = ProgramBrief(id: UUID().uuidString, targetDuration: 1200, moodTags: [], energyArc: [], conversationMode: .ambient)
        let draft = try await client.plan(brief: draftBrief, discoveryCandidates: Array(facts.prefix(5)), libraryCandidates: [], hostPrompt: "")
        try await store.publishDraft(draft)
        check(store.plan == plan && store.pendingPlan == draft, "draft does not replace active program")
        let taken = try await store.takePendingPlan()
        check(taken == draft && store.pendingPlan == nil, "pending consumption is authority-owned")
        try await store.refreshRecentPrograms()
        check(store.pendingPlan == nil, "read cannot resurrect consumed pending projection")
        let changed = try await store.revise(activeSlotIndex: 2, proposal: draft, mode: .replanUpcoming)
        check(Array(changed.slots.prefix(3)) == Array(plan.slots.prefix(3)), "revision retains already-played and current slots")
        try await store.publish(changed)
        try await store.activateSlot(at: 2)
        check(store.plan == changed, "same serialized authority client can publish after revision without stale CAS")
        let fabricated = ProgramPlan(brief: ProgramBrief(id: UUID().uuidString, targetDuration: 0, moodTags: [], energyArc: [], conversationMode: .ambient), slots: [], revision: 1, generatedAt: Date(), replanAfterTrackCount: 1)
        do { try await store.publish(fabricated); check(false, "native candidate plan cannot authorize publish") }
        catch { check(store.plan == changed, "failed publish preserves read-confirmed state") }
        let before = try await client.read()
        do { _ = try await backend.call("music_dj_command", ["op": .string("activate_slot"), "expectedRevision": .number(Double(before.revision - 1)), "index": .number(0)]); check(false, "stale revision must reject") }
        catch { check(true, "stale revision rejects") }
        check(try await client.read().activeSlotIndex == 2, "rejected CAS has no durable side effect")
        print("PASS: \(checks) actual Rust DJ/private Swift projection checks")
    }
}
"""#
let input = scratch.appendingPathComponent("main.swift")
try harness.write(to: input, atomically: true, encoding: .utf8)
let files = ["MusicSources/MusicSource.swift", "MusicSources/MusicStorageClient.swift", "MusicSources/SyncedMusicLibraryStore.swift", "DJCore/DJProgramStore.swift", "DJCore/RustMusicProgramClient.swift", "MusicKnowledge/TrackKnowledge.swift", "MusicKnowledge/CandidatePoolBuilder.swift", "Domain/PlaybackContext.swift"]
func run(_ path: String, _ arguments: [String]) throws -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
    try p.run(); p.waitUntilExit(); return p.terminationStatus
}
let output = scratch.appendingPathComponent("test")
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library"] + files.map { sources.appendingPathComponent($0).path } + [input.path,"-o",output.path])
guard compiled == 0 else { exit(compiled) }
exit(try run(output.path, []))
