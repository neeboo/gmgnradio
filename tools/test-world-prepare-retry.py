#!/usr/bin/env python3
"""Compile and execute production Swift receipt/watchdog/retry functions with stubs.

No app, renderer, audio, network, or user state is opened. Only the retry delay
is shortened; the production retry limit and extracted function bodies remain
unchanged (apart from access control so the harness can call them).
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "apps/macos/UnityHost/UnityMediaHost.swift"


def declaration(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1].replace("private func", "func", 1)
    raise AssertionError(f"Unbalanced production declaration: {signature}")


STUBS = r'''
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { print("FAIL: \(message)"); exit(1) }
}
struct Manifest { var worldID = "w1" }
struct BundledLivingWorldPackage { var manifest = Manifest() }
struct WorldState: Codable, Equatable { var worldID = "w1" }
enum WorldAuthorityError: Error { case noAuthorityRecord }
final class Closable { func close() {} }
@MainActor final class World {
    func nativePropFacts(identity: String) async throws -> Bool { true }
    func command(_ value: [String: Any]) -> Bool { true }
}
@MainActor final class UnityWorldSessionComposition {
    enum CompositionError: Error { case authorityReadBehind }
    struct Context { var state = WorldState() }
    var context = Context()
    init() {}
    init(applicationSupportBase: URL, selectedWorldID: String,
         validatedPackage: BundledLivingWorldPackage,
         nativePropFacts: @escaping (String) async throws -> Bool,
         nativePhysicsClient: Int) throws {}
    func close() {}
}
@MainActor final class Library {
    var completions = 0
    func completeSelection(revision: UInt64, worldID: String, success: Bool) -> Bool {
        completions += 1
        return true
    }
    func package(for id: String) -> BundledLivingWorldPackage? { .init() }
}
@MainActor final class Harness {
    var closed = false
    var worldSelection: [String: Any] = [:]
    var pendingWorldPackage: BundledLivingWorldPackage?
    var worldSelectionTask: Task<Void, Never>?
    var prepareWatchdogTask: Task<Void, Never>?
    var startupSpaceRetryTask: Task<Void, Never>?
    var startupSpaceAttempts = 0
    var starts = 0
    var worldSession: UnityWorldSessionComposition?
    let spaceLibrary = Library()
    let root = URL(fileURLWithPath: "/unused-test-root")
    let world = World()
    let worldPhysics = 0
    var residentAutonomy: Closable?
    var devicePlacement: Closable?
    var generationConfiguration: Closable?
    var wishOutputPreview: Closable?
    static let startupSpaceRetryDelay = Duration.milliseconds(1)
    func startExistingWorldSession() {
        starts += 1
        worldSelection["phase"] = "starting"
    }
    func installWorldSession(_ session: UnityWorldSessionComposition, selectedWorldID: String) {
        worldSession = session
    }
    func prepare(_ revision: UInt64 = 7) {
        pendingWorldPackage = .init()
        worldSelection = ["revision": revision, "worldID": "w1", "phase": "prepare"]
    }
    func receipt(_ revision: UInt64 = 7, worldID: String = "w1",
                 code: String = "world_prepare_timeout") -> [String: Any] {
        ["revision": revision, "worldID": worldID, "success": false,
         "code": code, "message": "renderer timeout"]
    }
'''

TESTS = r'''
}
@main struct Run {
    @MainActor static func main() async {
        let timeout = Harness()
        timeout.prepare()
        timeout.schedulePrepareWatchdog(id: "w1", revision: 7)
        let cancelledWatchdog = timeout.prepareWatchdogTask!
        require(timeout.completeWorldSelection(timeout.receipt()), "current timeout must be accepted")
        require(timeout.worldSelection["code"] as? String == "world_prepare_timeout", "preserve renderer code")
        require(timeout.worldSelection["message"] as? String == "renderer timeout", "preserve renderer message")
        require(timeout.worldSelection["phase"] as? String == "failed", "failure remains observable until retry")
        require(timeout.pendingWorldPackage == nil, "release failed prepare transaction")
        require(!timeout.completeWorldSelection(timeout.receipt()), "duplicate receipt must be rejected")
        require(timeout.startupSpaceAttempts == 1, "timeout schedules exactly one retry")
        await cancelledWatchdog.value
        await timeout.startupSpaceRetryTask?.value
        require(timeout.starts == 1 && timeout.spaceLibrary.completions == 1, "one timeout starts one transaction")

        let existing = Harness()
        existing.prepare()
        existing.worldSession = .init()
        let session = existing.worldSession
        require(existing.completeWorldSelection(existing.receipt()), "switch failure still accepted")
        require(existing.startupSpaceAttempts == 0 && existing.startupSpaceRetryTask == nil,
                "existing session must never schedule startup retry")
        require(existing.worldSession === session, "existing session is retained")

        let rejected = Harness()
        rejected.prepare()
        require(rejected.completeWorldSelection(rejected.receipt(code: "world_prepare_rejected")), "named rejection accepted")
        require(rejected.startupSpaceAttempts == 0 && rejected.startupSpaceRetryTask == nil,
                "deterministic renderer rejection must not retry")
        for code in ["world_prepare_failed", "world_renderer_prepare_failed", "new_renderer_failure"] {
            let retryable = Harness()
            retryable.prepare()
            require(retryable.completeWorldSelection(retryable.receipt(code: code)), "load failure accepted")
            await retryable.startupSpaceRetryTask?.value
            require(retryable.startupSpaceAttempts == 1 && retryable.starts == 1,
                    "retryable load failure schedules one transaction")
        }
        let unnamed = Harness()
        unnamed.prepare()
        var unnamedReceipt = unnamed.receipt()
        unnamedReceipt.removeValue(forKey: "code")
        require(unnamed.completeWorldSelection(unnamedReceipt), "unnamed failure accepted")
        require(unnamed.worldSelection["code"] as? String == "world_renderer_prepare_failed", "unnamed failure remains named")
        await unnamed.startupSpaceRetryTask?.value
        require(unnamed.starts == 1, "unnamed failure retries once")

        let stale = Harness()
        stale.prepare(8)
        stale.schedulePrepareWatchdog(id: "w1", revision: 8)
        require(!stale.completeWorldSelection(stale.receipt(7)), "old revision rejected")
        require(!stale.completeWorldSelection(stale.receipt(8, worldID: "other")), "other world rejected")
        require(stale.startupSpaceAttempts == 0 && stale.spaceLibrary.completions == 0, "stale receipt has no effects")
        require(stale.prepareWatchdogTask?.isCancelled == false, "stale receipt must not cancel current watchdog")
        require(stale.worldSelection["phase"] as? String == "prepare", "current prepare retained")
        stale.prepareWatchdogTask?.cancel()
        await stale.prepareWatchdogTask?.value
        require(stale.worldSelection["phase"] as? String == "prepare", "cancelled watchdog cannot fail current prepare")

        let watchdog = Harness()
        watchdog.prepare()
        watchdog.schedulePrepareWatchdog(id: "w1", revision: 7)
        let oldWatchdog = watchdog.prepareWatchdogTask!
        watchdog.schedulePrepareWatchdog(id: "w1", revision: 7)
        await oldWatchdog.value
        require(watchdog.worldSelection["phase"] as? String == "prepare", "replaced watchdog cannot wake and fail same revision")
        require(watchdog.startupSpaceAttempts == 0, "cancelled watchdog cannot consume retry budget")
        watchdog.prepareWatchdogTask?.cancel()
        await watchdog.prepareWatchdogTask?.value

        let bounded = Harness()
        for revision in 1...Harness.startupSpaceAttemptLimit + 1 {
            bounded.prepare(UInt64(revision))
            require(bounded.completeWorldSelection(bounded.receipt(UInt64(revision))), "each current timeout accepted")
            await bounded.startupSpaceRetryTask?.value
        }
        require(bounded.startupSpaceAttempts == Harness.startupSpaceAttemptLimit, "retry budget never exceeded")
        require(bounded.starts == Harness.startupSpaceAttemptLimit, "no transaction beyond retry budget")
        require(bounded.worldSelection["phase"] as? String == "failed", "exhausted budget stays failed")

        let replaced = Harness()
        require(replaced.scheduleStartupSpaceRetry(failureCode: "world_prepare_timeout"), "first retry scheduled")
        let oldRetry = replaced.startupSpaceRetryTask!
        require(replaced.scheduleStartupSpaceRetry(failureCode: "world_prepare_timeout"), "replacement retry scheduled")
        await oldRetry.value
        await replaced.startupSpaceRetryTask?.value
        require(replaced.starts == 1, "cancelled retry cannot start a second transaction")

        let recovered = Harness()
        recovered.prepare()
        require(recovered.completeWorldSelection(recovered.receipt()), "startup timeout accepted")
        recovered.worldSession = .init()
        await recovered.startupSpaceRetryTask?.value
        require(recovered.starts == 0, "session established during delay suppresses retry")

        let busy = Harness()
        busy.prepare()
        require(busy.completeWorldSelection(busy.receipt()), "startup timeout accepted")
        busy.prepare(8)
        await busy.startupSpaceRetryTask?.value
        require(busy.starts == 0, "new prepare during delay owns selection")

        let closed = Harness()
        closed.prepare()
        require(closed.completeWorldSelection(closed.receipt()), "startup timeout accepted")
        closed.closed = true
        await closed.startupSpaceRetryTask?.value
        require(closed.starts == 0, "closed host cannot retry")
        print("PASS: production Swift timeout retries, active session, duplicate/stale receipts, bounded attempts, cancellation, and delayed ownership")
    }
}
'''


def main() -> None:
    source = SOURCE.read_text()
    constants = []
    for name in ["startupSpaceAttemptLimit", "prepareWatchdogDelay"]:
        match = re.search(rf"private static let {name} = [^\n]+", source)
        assert match, f"Missing production constant: {name}"
        constants.append(match.group().replace("private ", "", 1))
    functions = [declaration(source, f"private func {name}(") for name in [
        "schedulePrepareWatchdog", "scheduleStartupSpaceRetry", "completeWorldSelection",
        "retryStartupSpaceOrPublishFailure", "publishStartupSpaceFailure"]]
    functions.append(declaration(source, "static func startupSpaceFailureIsRetryable("))
    with tempfile.TemporaryDirectory(prefix="gmgn-world-retry-") as directory:
        directory = Path(directory)
        swift = directory / "RetryHarness.swift"
        binary = directory / "retry-harness"
        swift.write_text(STUBS + "\n".join(constants + functions) + TESTS)
        subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
