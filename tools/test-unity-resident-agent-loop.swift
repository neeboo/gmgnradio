import Foundation

// Only world presentation and preference storage are doubles. The bridge and
// ResidentAgentLoop scheduler under test are the exact production sources.
@MainActor final class WorldAgentContext {
    struct Position { var x: Double = 0; var y: Double = 0; var z: Double = 0 }
    struct Transform { var position = Position() }
    struct Phase { let rawValue = "loop" }
    struct Activity { let id = "activity.test"; let phase = Phase() }
    struct Snapshot { let worldID = "world.test"; let agentTransform = Transform(); var activeActivity: Activity? }
    var snapshot = Snapshot()
    struct Held { let objectID: String }
    struct State { var heldProp: Held? }
    var state = State()
}
struct ResidentPreferences {
    let defaults: UserDefaults
    var backgroundTurnsPerHour: Int { defaults.object(forKey: "budget") == nil ? 6 : defaults.integer(forKey: "budget") }
}
@MainActor final class Probe {
    var calls = 0
    var cancellations = 0
    var replies: [String] = []
    var input: ResidentAgentLoop.Input?
    var pending: CheckedContinuation<String, Error>?
    func run(_ input: ResidentAgentLoop.Input) async throws -> String {
        calls += 1; self.input = input
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func cancel() { cancellations += 1; pending?.resume(throwing: CancellationError()); pending = nil }
    func finish() { pending?.resume(returning: "visible background reply"); pending = nil }
}
@main struct Tests {
    @MainActor static func settle() async { for _ in 0..<40 { await Task.yield() } }
    @MainActor static func main() async {
        let suite = "gmgn.unity.autonomy.test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            guard condition else { print("FAIL: \(label)"); exit(1) }
        }
        let probe = Probe()
        let context = WorldAgentContext()
        context.state.heldProp = .init(objectID: "prop.verified-held")
        var available = true
        let bridge = UnityResidentAgentLoopBridge(context: context, defaults: defaults,
            available: { available }, run: { try await probe.run($0) }, cancelRun: { probe.cancel() },
            onReply: { probe.replies.append($0) })
        bridge.start(); await settle()
        check(probe.calls == 1, "default-enabled starts one real scheduler callback")
        let tools = bridge.tools(runID: probe.input!.runID)
        func heldID() throws -> String? {
            let result = tools.handle(name: "read_resident_state", argumentsJSON: Data("{}".utf8))
            check(!result.isError, "active background lease can read actual state")
            let json = try JSONSerialization.jsonObject(with: result.data) as! [String: Any]
            return (json["self_state"] as? [String: Any])?["held_prop_id"] as? String
        }
        do {
            check(try heldID() == "prop.verified-held", "held prop reaches resident tool instead of constant nil")
            context.state.heldProp = nil
            check(try heldID() == nil, "release reaches the same tool lease without stale held state")
        } catch { print("FAIL: state response decoding: \(error)"); exit(1) }
        check(probe.input?.isBackground == true && probe.input?.userMessages.isEmpty == true,
              "background never acquires human input authorization")
        bridge.humanTurnWillBegin(); await settle()
        check(probe.cancellations == 1 && !bridge.loop.snapshot.isRunning, "human turn interrupts background lease")
        bridge.refresh(); await settle()
        check(probe.calls == 1, "human interaction excludes concurrent background sends")
        bridge.humanTurnDidFinish()
        check(bridge.loop.snapshot.backgroundEnabled, "human completion restores enabled scheduling")
        bridge.pauseByUser()
        check(probe.cancellations == 1, "pausing idle autonomy does not cancel host-owned human conversation")
        check(!defaults.bool(forKey: UnityResidentAgentLoopBridge.enabledKey), "pause persists actual preference")
        bridge.resumeByUser()
        check(defaults.bool(forKey: UnityResidentAgentLoopBridge.enabledKey)
            && !bridge.loop.snapshot.isAutonomyPausedByUser, "explicit resume restores stopped loop")
        bridge.setEditing(true)
        check(!bridge.loop.snapshot.backgroundEnabled, "editing pauses autonomous work")
        bridge.setEditing(false)
        available = false; bridge.refresh()
        check(bridge.snapshot()["status"] as? String == "backend_or_world_unavailable", "missing backend remains explicit")
        check(!bridge.loop.snapshot.backgroundEnabled, "missing backend cannot launch fabricated work")
        available = true; defaults.set(0, forKey: "budget"); bridge.refresh()
        check(bridge.loop.snapshot.backgroundTurnsPerHour == 0, "saved zero budget reaches actual loop")
        bridge.close(); bridge.start(); bridge.refresh()
        check(bridge.loop.snapshot.isInvalidated && bridge.snapshot()["status"] as? String == "closed", "close invalidates permanently")
        let second = Probe()
        defaults.set(6, forKey: "budget")
        let delivered = UnityResidentAgentLoopBridge(context: WorldAgentContext(), defaults: defaults,
            available: { true }, run: { try await second.run($0) }, cancelRun: { second.cancel() },
            onReply: { second.replies.append($0) })
        delivered.start(); await settle(); second.finish(); await settle()
        check(second.replies == ["visible background reply"], "actual loop completion emits one speech/display hook")
        delivered.close()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let wishProbe = Probe()
        let wishes = UnityResidentAgentLoopBridge(context: WorldAgentContext(), defaults: defaults,
            now: { clock }, available: { true }, run: { try await wishProbe.run($0) },
            cancelRun: { wishProbe.cancel() }, onReply: { wishProbe.replies.append($0) })
        wishes.start(); await settle(); wishProbe.finish(); await settle()
        defaults.set(false, forKey: UnityResidentAgentLoopBridge.enabledKey)
        wishes.refresh()
        clock = clock.addingTimeInterval(61)
        let completion = ResidentAgentLoop.Event(id: "wish.completion", kind: "wish.outputReady", summary: "verified output")
        wishes.humanTurnWillBegin()
        check(wishes.receiveWish(completion, continuation: true), "origin completion admitted while human owns conversation")
        await settle()
        check(wishProbe.calls == 1, "completion cannot launch concurrently with human turn")
        wishes.humanTurnDidFinish(); await settle()
        check(wishProbe.calls == 2 && wishProbe.input?.events.contains(completion) == true,
              "human completion wakes actual callback with durable wish event")
        wishes.humanTurnWillBegin(); await settle()
        check(wishProbe.cancellations == 1 && !wishes.loop.snapshot.isRunning,
              "human interaction cancels an active task continuation too")
        wishes.setEditing(true); wishes.humanTurnDidFinish(); clock = clock.addingTimeInterval(61)
        wishes.refresh(); await settle()
        check(wishProbe.calls == 2, "editing excludes queued continuation callback")
        wishes.setEditing(false); await settle()
        _ = wishes.receiveWish(completion, continuation: true); await settle()
        check(wishProbe.calls == 3, "leaving editing preserves and retries canceled completion")
        wishProbe.finish(); await settle(); clock = clock.addingTimeInterval(61)
        _ = wishes.receiveWish(completion, continuation: true); await settle()
        check(wishProbe.calls == 3, "consumed continuation identity cannot launch a second turn")
        wishes.pauseByUser()
        _ = wishes.receiveWish(.init(id: "wish.stopped", kind: "wish.failed", summary: "failure"), continuation: true)
        await settle()
        check(wishProbe.calls == 3 && wishes.loop.snapshot.isStopped, "wish cannot revoke user stop")
        wishes.resumeByUser(); await settle()
        if wishProbe.pending != nil { wishProbe.finish(); await settle() }
        defaults.set(0, forKey: "budget"); clock = clock.addingTimeInterval(61)
        let beforeZero = wishProbe.calls
        _ = wishes.receiveWish(.init(id: "wish.zero", kind: "wish.outputReady", summary: "ready"), continuation: true)
        await settle()
        check(wishProbe.calls == beforeZero, "zero budget blocks task continuation")
        wishes.close()
        print("PASS: \(checks) Unity autonomous-loop behavior checks")
    }
}
