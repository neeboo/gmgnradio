// Compile the real AI-program entrypoint with suspended planning/preparation boundaries.
import Foundation
let appSource = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", encoding: .utf8)
func method(_ signature: String) -> String {
    let start = appSource.range(of: signature)!.lowerBound
    let body = appSource[start...].range(of: #"\)\s*(?:async\s*)?(?:throws\s*)?\{"#, options: .regularExpression)!
    let opening = appSource.index(before: body.upperBound)
    var depth = 0
    for index in appSource[opening...].indices {
        if appSource[index] == "{" { depth += 1 }
        if appSource[index] == "}" { depth -= 1 }
        if depth == 0 { return String(appSource[start...index]) }
    }
    fatalError("unterminated method")
}
let source = #"""
import Foundation
import os
struct ProgramPlan { let id: String }
struct Track { var id = "track"; var title = "track" }
struct Slot { var track = Track() }
struct PreparedProgramPlayback { var slot = Slot() }
enum ProgramPlaybackQueueError: Error { case noPlayableSlots(failedTrackIDs: [String]) }
enum Failure: Error { case expected }
enum State { case thinking, failed }
final class Orb { var state: State?; func setState(_ value: State) { state = value } }
final class Store {
    var plan: ProgramPlan?; var failures = 0
    func beginPlanning() {}
    func publish(_ value: ProgramPlan) { plan = value }
    func fail(_ message: String) { failures += 1 }
}
@MainActor final class Runtime {
    var loads = 0
    var gate: CheckedContinuation<Void, Error>?
}
struct PlaybackPreflight { let preparer: MusicRuntimePlaybackPreparer }
struct MusicRuntimePlaybackPreparer { let runtime: Runtime }
@MainActor final class ProgramPlaybackQueue {
    var current: PreparedProgramPlayback?
    var failedTrackIDs: [String] = []
    var loads = 0
    var replacements = 0
    let runtime: Runtime
    init(preflight: PlaybackPreflight, lockedCapacity: Int = 2) { runtime = preflight.preparer.runtime }
    func load(_ plan: ProgramPlan) async throws {
        loads += 1; runtime.loads += 1
        try await withCheckedThrowingContinuation { runtime.gate = $0 }
        current = PreparedProgramPlayback()
    }
    func replaceCurrentAfterFailure() async -> PreparedProgramPlayback? { replacements += 1; return nil }
}
@MainActor final class App {
    var musicSelectionGeneration: UInt64 = 0
    var orbWindowController: Orb? = Orb()
    var activeProgram: ProgramPlan?
    let programStore = Store()
    let musicRuntime = Runtime()
    lazy var programPlaybackQueue = ProgramPlaybackQueue(preflight: PlaybackPreflight(preparer: MusicRuntimePlaybackPreparer(runtime: musicRuntime)))
    var planGate: CheckedContinuation<ProgramPlan, Error>?
    var playGate: CheckedContinuation<Void, Error>?
    var plays = 0
    var errors = 0
    func updateStageProgramNavigation() {}
    func presentProgramError(_ error: Error) { errors += 1 }
    func makeAIProgramPlan(immediateUserInstruction: String?) async throws -> ProgramPlan {
        try await withCheckedThrowingContinuation { planGate = $0 }
    }
    func playPreparedWithFallback(_ prepared: PreparedProgramPlayback,
        requestOpening: Bool = true, allowFallback: Bool = true,
        isCurrentSelection: @MainActor () -> Bool = { true },
        onSelectionCommitted: @MainActor () -> Void = {}) async throws {
        plays += 1
        // Real playback advances its own selection generation before asynchronous work.
        musicSelectionGeneration &+= 2
        onSelectionCommitted()
        try await withCheckedThrowingContinuation { playGate = $0 }
    }
    \#(method("private func startAIProgram("))
    func start() { startAIProgram(immediateUserInstruction: nil) }
    func replace() {
        musicSelectionGeneration &+= 1
        activeProgram = ProgramPlan(id: "newer")
        programStore.publish(activeProgram!)
    }
}
@MainActor final class FallbackApp {
    let playbackLogger = Logger(subsystem: "test", category: "selection")
    var generation = 0
    var programPlaybackQueue = ProgramPlaybackQueue(preflight: PlaybackPreflight(preparer: MusicRuntimePlaybackPreparer(runtime: Runtime())))
    var gate: CheckedContinuation<Void, Error>?
    func playPrepared(_ prepared: PreparedProgramPlayback, requestOpening: Bool = true,
        isCurrentSelection: @MainActor () -> Bool = { true },
        onSelectionCommitted: @MainActor () -> Void = {}) async throws {
        generation += 1; onSelectionCommitted()
        try await withCheckedThrowingContinuation { gate = $0 }
    }
    \#(method("private func playPreparedWithFallback("))
    func run() async throws {
        var owned = generation
        try await playPreparedWithFallback(PreparedProgramPlayback(),
            isCurrentSelection: { self.generation == owned },
            onSelectionCommitted: { owned = self.generation })
    }
}
@main struct Test {
    @MainActor static func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }
    @MainActor static func main() async {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        for fails in [false, true] {
            let app = App(); app.start(); await settle()
            app.replace()
            if fails { app.planGate?.resume(throwing: Failure.expected) }
            else { app.planGate?.resume(returning: ProgramPlan(id: "old")) }
            await settle()
            check(app.activeProgram?.id == "newer" && app.programStore.plan?.id == "newer", "late planner result cannot replace newer prepared plan")
            check(app.errors == 0 && app.programStore.failures == 0, "late planner failure cannot overwrite newer UI")
            if app.musicRuntime.gate != nil { app.musicRuntime.gate?.resume(throwing: Failure.expected); await settle() }
        }
        let preparing = App(); let originalQueue = preparing.programPlaybackQueue
        preparing.start(); await settle()
        preparing.planGate?.resume(returning: ProgramPlan(id: "old")); await settle()
        check(originalQueue.loads == 0 && preparing.programPlaybackQueue === originalQueue, "planning prepares privately without mutating official queue")
        preparing.replace()
        preparing.musicRuntime.gate?.resume(); await settle()
        check(preparing.activeProgram?.id == "newer" && preparing.plays == 0, "late preparation cannot publish or play")
        preparing.playGate?.resume(throwing: Failure.expected); await settle()

        for takeover in [false, true] {
            let app = App(); app.start(); await settle()
            app.planGate?.resume(returning: ProgramPlan(id: "own")); await settle()
            app.musicRuntime.gate?.resume(); await settle()
            check(app.plays == 1 && app.activeProgram?.id == "own", "current planning and preparation publish normally")
            if takeover { app.replace() }
            app.playGate?.resume(throwing: Failure.expected); await settle()
            if takeover {
                check(app.activeProgram?.id == "newer" && app.errors == 0, "late playback error preserves newer selection")
            } else {
                check(app.errors == 1 && app.programStore.failures == 1, "own playback generation increments do not hide valid failure")
            }
        }
        let fallback = FallbackApp()
        let operation = Task { @MainActor in try await fallback.run() }
        await settle()
        let newerQueue = ProgramPlaybackQueue(preflight: PlaybackPreflight(preparer: MusicRuntimePlaybackPreparer(runtime: Runtime())))
        fallback.programPlaybackQueue = newerQueue
        fallback.generation += 1
        fallback.gate?.resume(throwing: Failure.expected)
        do { try await operation.value; check(false, "superseded playback must cancel") }
        catch is CancellationError {} catch { check(false, "superseded playback returned ordinary failure") }
        check(newerQueue.replacements == 0, "real fallback must not replace a newer queue after late failure")
        print("\(failures == 0 ? "PASS" : "FAIL"): AI program selection ownership; \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-ai-selection-\(UUID())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: dir) }
let file = dir.appendingPathComponent("Test.swift")
try source.write(to: file, atomically: true, encoding: .utf8)
func run(_ path: String, _ args: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let output = dir.appendingPathComponent("test").path
let status = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library", file.path, "-o", output])
guard status == 0 else { exit(status) }
exit(try run(output, []))
