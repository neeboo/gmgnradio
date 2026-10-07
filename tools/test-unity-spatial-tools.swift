import Foundation
@testable import UnityMediaHost

@MainActor final class SpatialFixtureState {
    var current = true, takeover = true, started = false, finished = false
    var environmentCalls = 0, cameraCalls = 0
    var mode = "success"
}
enum SpatialFixtureError: Error { case rejected }
@main struct SpatialToolsRegression {
    @MainActor static func main() async throws {
        let state = SpatialFixtureState()
        var hooks = UnityMusicRadioActions.Hooks(
            playback: { .init(track: nil, queue: [], index: nil, position: 0, isPlaying: false) },
            command: { _ in preconditionFailure("Unrelated playback") },
            search: { _, _ in [] },
            list: { _, _, _ in preconditionFailure("Unrelated library") },
            read: { _, _, _ in preconditionFailure("Unrelated library") },
            prepare: { _, _ in preconditionFailure("Unrelated library") })
        let unavailable = UnityMusicRadioActions(hooks: hooks)
        precondition(unavailable.snapshot(takeoverEnabled: true).capabilities.allSatisfy { !ResidentMusicToolBridge.spatialNames.contains($0.name) })
        hooks.spatialEnvironment = { scene, weather in
            state.environmentCalls += 1
            state.started = true
            if state.mode == "cancel" { try? await Task.sleep(for: .milliseconds(80)) }
            else { try await Task.sleep(for: .milliseconds(5)) }
            if ["transition", "failed-transition", "weather-stale", "cancel"].contains(state.mode) { state.current = false }
            if state.mode == "reject" || state.mode == "failed-transition" { throw SpatialFixtureError.rejected }
            state.finished = true
        }
        hooks.spatialCamera = { _, _ in
            state.cameraCalls += 1
            try await Task.sleep(for: .milliseconds(5))
            if state.mode == "camera-stale" { state.current = false }
            if state.mode == "reject" { throw SpatialFixtureError.rejected }
            state.finished = true
        }
        let actions = UnityMusicRadioActions(hooks: hooks)
        let bridge = ResidentMusicToolBridge(actions: actions, isCurrent: { state.current },
            exportedNames: ResidentMusicToolBridge.spatialNames,
            permitsWorldTransitionResult: true, takeoverEnabled: { state.takeover })
        let tools = bridge.tools
        precondition(Set(tools.map(\.name)) == ResidentMusicToolBridge.spatialNames)
        let environment = tools.first { $0.name == "set_spatial_environment" }!
        let camera = tools.first { $0.name == "move_spatial_camera" }!
        precondition(camera.validate(["direction": "left", "distance": NSNumber(value: 1.5)]))
        precondition(!camera.validate(["direction": "left", "distance": true]))
        precondition(!camera.validate(["direction": "left", "distance": NSNumber(value: Double.nan)]))
        precondition(!camera.validate(["direction": "left", "distance": NSNumber(value: Double.infinity)]))
        func json(_ result: RealtimeDJToolResult) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: result.resultJSON) as! [String: Any]
        }
        func reset(_ mode: String) { state.current = true; state.mode = mode; state.started = false; state.finished = false }
        let success = await camera.handle("camera-success", Data(#"{"direction":"left","distance":1.5}"#.utf8))
        precondition(!success.isError && state.finished && state.cameraCalls == 1)
        reset("reject")
        let rejected = await camera.handle("camera-reject", Data(#"{"direction":"left","distance":1.5}"#.utf8))
        precondition(rejected.isError && !state.finished)
        reset("success"); state.takeover = false
        let denied = await environment.handle("disabled", Data(#"{"weather":"rain"}"#.utf8))
        precondition(denied.isError && state.environmentCalls == 0)
        state.takeover = true
        reset("transition")
        let changed = await environment.handle("changed", Data(#"{"scene":"dj_house"}"#.utf8))
        let payload = try json(changed)
        precondition(!changed.isError && payload["worldChanged"] as? Bool == true && payload["instruction"] is String)
        let subsequent = await camera.handle("old-lease", Data(#"{"direction":"right"}"#.utf8))
        precondition(subsequent.isError)
        reset("failed-transition")
        let failedChange = await environment.handle("failed-change", Data(#"{"scene":"dj_house"}"#.utf8))
        precondition(failedChange.isError)
        reset("weather-stale")
        let weather = await environment.handle("weather-stale", Data(#"{"weather":"rain"}"#.utf8))
        precondition(weather.isError)
        reset("camera-stale")
        let staleCamera = await camera.handle("camera-stale", Data(#"{"direction":"right"}"#.utf8))
        precondition(staleCamera.isError)
        reset("cancel")
        let cancelled = Task { @MainActor in await environment.handle("cancelled-transition", Data(#"{"scene":"dj_house"}"#.utf8)) }
        while !state.started { await Task.yield() }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        precondition(cancelledResult.isError)
        reset("transition")
        let strict = ResidentMusicToolBridge(actions: actions, isCurrent: { state.current }, exportedNames: ResidentMusicToolBridge.spatialNames)
        let strictResult = await strict.tools.first { $0.name == "set_spatial_environment" }!.handle("strict", Data(#"{"scene":"dj_house"}"#.utf8))
        precondition(strictResult.isError)
        print("PASS: real spatial dispatcher exports; finite number validation; awaited success/rejection; dynamic takeover; nil hooks not advertised; applied scene transition result ends old lease; failed/weather/camera/cancel stale calls reject")
    }
}
