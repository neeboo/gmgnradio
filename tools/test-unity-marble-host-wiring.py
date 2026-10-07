#!/usr/bin/env python3
"""Execute Host capability/foreground spatial slices without App or authority access."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
host = (repo/"apps/macos/UnityHost/UnityMediaHost.swift").read_text()
method = "    private func setSpatialEnvironment" + host.split("    private func setSpatialEnvironment",1)[1].split("    private func completeWorldSelection",1)[0]
capability = host.split('            case "world.runtime.capabilities":',1)[1].split('            case "world.attachment.ready":',1)[0]
errors = "enum UnityMarbleError" + (repo/"apps/macos/UnityHost/UnityMarbleWorldBridge.swift").read_text().split("enum UnityMarbleError",1)[1].split("/// Explicit commands",1)[0]
assert 'marble: marbleWorlds' in host
assert 'UnityMarblePackageBuilder.registeredRoots(root: root)' in host
assert 'case _ where UnityMarbleWorldBridge.supportedCommands.contains(op): return spaceLibrary.settingsCommand(value)' in host
assert '+ UnityMarbleWorldBridge.supportedCommands' in host
assert 'private var marbleRuntimeReady = false' in host

program = 'import Foundation\n' + errors + '''
enum SpatialScenePreset { case djHouse }
enum SpatialWeather { case rain }
enum UnitySpatialPresentationBridge { enum PresentationError: Error { case busy, hidden } }
struct Package { struct Manifest { let worldID: String }; let manifest: Manifest }
struct Session { struct Context { struct State { let worldID: String }; var state: State }; var context: Context }
@MainActor final class Marble {
    var fail = false, calls = 0
    func activatePreset(_ preset: SpatialScenePreset) async throws -> Package {
        calls += 1
        if fail { throw UnityMarbleError.identityMissing }
        return Package(manifest: .init(worldID: "generated"))
    }
}
@MainActor final class Weather {
    var calls = 0, visibilityCalls = 0, hidden = false
    func confirmVisible() async throws { visibilityCalls += 1; if hidden { throw UnitySpatialPresentationBridge.PresentationError.hidden } }
    func setWeather(_ weather: SpatialWeather) async throws { calls += 1 }
}
@MainActor final class Library {
    var revision: UInt64 = 0
    var savedSelectionID: String?
    var rejected = false, failedReceipts = 0
    var onSelect: (() -> Void)?
    var snapshot: [String: Any] { ["selectionRevision": revision] }
    func settingsCommand(_ value: [String: Any]) -> Bool {
        if rejected { return false }; revision += 1; onSelect?(); return true
    }
    func completeSelection(revision: UInt64, worldID: String, success: Bool) -> Bool { if !success { failedReceipts += 1 }; return true }
}
@MainActor final class Host {
    var closed = false, marbleRuntimeReady = false, spatialSceneTransitionInProgress = false
    var spatialSceneSelectionRevision: UInt64?
    let marbleWorlds = Marble(), spatialPresentation = Weather(), spaceLibrary = Library()
    var worldSession: Session? = Session(context: .init(state: .init(worldID: "original")))
    var pendingWorldPackage: Package?
    var worldSelectionTask: Task<Void, Never>?
    var worldSelection: [String: Any] = [:]
    func ack(_ value: [String: Any]) -> Bool {''' + capability + '''}
    func perform(scene: SpatialScenePreset?, weather: SpatialWeather?) async throws { try await setSpatialEnvironment(scene: scene, weather: weather) }
''' + method + '''
}
@main struct Test {
    @MainActor static func main() async throws {
        let host = Host()
        precondition(!host.marbleRuntimeReady)
        for invalid: Any in [true, false, 2.5, 1, "2", NSNull()] {
            precondition(!host.ack(["marbleSPZVersion": invalid]))
            precondition(!host.marbleRuntimeReady)
        }
        precondition(host.ack(["marbleSPZVersion": 2]) && host.marbleRuntimeReady)
        precondition(host.ack(["marbleSPZVersion": 0]) && !host.marbleRuntimeReady)
        host.closed = true
        precondition(!host.ack(["marbleSPZVersion": 2]) && !host.marbleRuntimeReady)
        host.closed = false
        host.spaceLibrary.onSelect = {
            host.pendingWorldPackage = Package(manifest: .init(worldID: "generated"))
            host.worldSelectionTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(15))
                host.worldSelection = ["revision": UInt64(0), "worldID": "generated", "phase": "activate"]
                try? await Task.sleep(for: .milliseconds(15))
                host.worldSelection = ["revision": UInt64(1), "worldID": "generated", "phase": "activate"]
                try? await Task.sleep(for: .milliseconds(15))
                host.worldSession = Session(context: .init(state: .init(worldID: "generated")))
                try? await Task.sleep(for: .milliseconds(15))
                host.spaceLibrary.savedSelectionID = "generated"; host.pendingWorldPackage = nil
            }
        }
        let activation = Task { @MainActor in try await host.perform(scene: .djHouse, weather: .rain) }
        try await Task.sleep(for: .milliseconds(25))
        precondition(host.spatialPresentation.calls == 0, "stale/partial selection must not apply weather")
        try await activation.value
        precondition(host.worldSession?.context.state.worldID == "generated" && host.spaceLibrary.savedSelectionID == "generated")
        precondition(host.spatialPresentation.calls == 1)
        precondition(host.spatialPresentation.visibilityCalls == 2 && !host.spatialSceneTransitionInProgress)
        let hidden = Host(); hidden.spatialPresentation.hidden = true
        do { try await hidden.perform(scene: .djHouse, weather: .rain); preconditionFailure("hidden space started generation") }
        catch UnitySpatialPresentationBridge.PresentationError.hidden {}
        precondition(hidden.marbleWorlds.calls == 0 && hidden.spatialPresentation.calls == 0)
        let hiddenWeather = Host(); hiddenWeather.spatialPresentation.hidden = true
        do { try await hiddenWeather.perform(scene: nil, weather: .rain); preconditionFailure("hidden space wrote weather") }
        catch UnitySpatialPresentationBridge.PresentationError.hidden {}
        precondition(hiddenWeather.marbleWorlds.calls == 0 && hiddenWeather.spatialPresentation.calls == 0)
        let sameWorld = Host()
        sameWorld.worldSession = Session(context: .init(state: .init(worldID: "generated")))
        try await sameWorld.perform(scene: .djHouse, weather: nil)
        precondition(sameWorld.spatialPresentation.visibilityCalls == 2 && sameWorld.spatialPresentation.calls == 0)
        precondition(sameWorld.spaceLibrary.revision == 0, "same world must not start a new selection")
        let failed = Host()
        failed.marbleWorlds.fail = true
        do { try await failed.perform(scene: .djHouse, weather: .rain); preconditionFailure("generation error swallowed") }
        catch UnityMarbleError.identityMissing {}
        precondition(failed.worldSession?.context.state.worldID == "original" && failed.spatialPresentation.calls == 0)
        let rejected = Host(); rejected.spaceLibrary.rejected = true
        do { try await rejected.perform(scene: .djHouse, weather: .rain); preconditionFailure("selection rejection swallowed") }
        catch UnityMarbleError.selectionRejected {}
        precondition(rejected.worldSession?.context.state.worldID == "original" && rejected.spatialPresentation.calls == 0)
        let cancelled = Host()
        cancelled.spaceLibrary.onSelect = { cancelled.pendingWorldPackage = Package(manifest: .init(worldID: "generated")) }
        let waiting = Task { @MainActor in try await cancelled.perform(scene: .djHouse, weather: .rain) }
        try await Task.sleep(for: .milliseconds(20)); waiting.cancel()
        do { try await waiting.value; preconditionFailure("cancelled spatial request succeeded") }
        catch is CancellationError {}
        precondition(cancelled.pendingWorldPackage == nil && cancelled.spaceLibrary.failedReceipts == 1)
        precondition(cancelled.worldSession?.context.state.worldID == "original" && cancelled.spatialPresentation.calls == 0)
        print("PASS strict C# capability ack, actual selection revision/current-world/persisted-choice wait, visibility preflight/no hidden paid or weather calls, two same-world scene visibility receipts, weather sequencing, error preservation and cancellation; Host production slices only, no UI or authority")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="gmgn-marble-host-wiring-") as directory:
    source = Path(directory)/"test.swift"; source.write_text(program)
    executable = Path(directory)/"test"
    subprocess.run(["swiftc","-swift-version","6","-parse-as-library",str(source),"-o",str(executable)],check=True)
    subprocess.run([str(executable)],check=True)
