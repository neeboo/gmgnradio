import Foundation
import WorldRuntime

// Presentation-only values; the production receipt gate and WorldWeather are real.
enum SpatialWeather: String { case clear, rain, thunderstorm }
enum SpatialCameraCommandDirection: String { case forward, backward, left, right, reset }

@main struct SpatialPresentationRegression {
    @MainActor static func request(_ bridge: UnitySpatialPresentationBridge) async -> [String: Any] {
        for _ in 0..<200 {
            if let request = bridge.snapshot()["request"] as? [String: Any] { return request }
            await Task.yield()
        }
        preconditionFailure("request not published")
    }
    @MainActor static func receipt(_ request: [String: Any], readback: [String: Any]) -> [String: Any] {
        ["op": "spatial.presentation.receipt", "id": request["id"]!, "worldID": request["worldID"]!,
         "operation": request["operation"]!, "applied": true, "readback": readback]
    }
    @MainActor static func main() async throws {
        var world: String? = "world-a"
        var writes: [WorldWeather] = []
        let bridge = UnitySpatialPresentationBridge(currentWorldID: { world }, changeWeather: { writes.append($0) })
        bridge.observeWorldWeather(worldID: "world-a", value: .cloudy)
        precondition(bridge.snapshot()["weather"] as? String == "clear")
        let visibility = Task { try await bridge.confirmVisible() }
        let visibilityRequest = await request(bridge)
        precondition(visibilityRequest["operation"] as? String == "visibility" && writes.isEmpty)
        var visibilityFrame: [String: Any] = ["renderedFrame": 5, "normalWorldVisible": true,
            "camera": ["position": ["x": 1, "y": 2, "z": 3],
                       "rotation": ["x": 0, "y": 0, "z": 0, "w": 1], "fieldOfViewDegrees": 66]]
        visibilityFrame["normalWorldVisible"] = false
        precondition(!bridge.command(receipt(visibilityRequest, readback: visibilityFrame)) && writes.isEmpty)
        visibilityFrame["normalWorldVisible"] = true
        precondition(bridge.command(receipt(visibilityRequest, readback: visibilityFrame)))
        try await visibility.value
        precondition(writes.isEmpty, "normal visibility confirmation is read-only")
        let storm = Task { try await bridge.setWeather(.thunderstorm) }
        let stormRequest = await request(bridge)
        precondition(writes == [.rain] && bridge.snapshot()["status"] as? String == "pending")
        bridge.observeWorldWeather(worldID: "world-a", value: .rain)
        precondition(bridge.snapshot()["weather"] as? String == "thunderstorm", "same base preserves local thunderstorm")
        var stormFrame: [String: Any] = ["renderedFrame": 7, "normalWorldVisible": true,
            "weather": "thunderstorm", "overlayVisible": true, "passive": true]
        var wrong = receipt(stormRequest, readback: stormFrame)
        wrong["id"] = "stale"; precondition(!bridge.command(wrong))
        wrong = receipt(stormRequest, readback: stormFrame); wrong["worldID"] = "world-b"
        precondition(!bridge.command(wrong))
        stormFrame["renderedFrame"] = 0
        precondition(!bridge.command(receipt(stormRequest, readback: stormFrame)), "queued/unrendered weather cannot succeed")
        stormFrame["renderedFrame"] = 7; stormFrame["passive"] = false
        precondition(!bridge.command(receipt(stormRequest, readback: stormFrame)), "weather must not intercept pointer input")
        stormFrame["passive"] = true
        precondition(bridge.command(receipt(stormRequest, readback: stormFrame)))
        try await storm.value
        precondition(!bridge.command(receipt(stormRequest, readback: stormFrame)), "receipt cannot be replayed")
        bridge.observeWorldWeather(worldID: "world-a", value: .clear)
        precondition(bridge.snapshot()["weather"] as? String == "clear", "real authority weather change clears override")
        bridge.observeWorldWeather(worldID: "world-a", value: .snow)
        precondition(bridge.snapshot()["weather"] as? String == "rain")

        let camera = Task { try await bridge.moveCamera(direction: .forward, distance: 50) }
        let cameraRequest = await request(bridge)
        precondition(cameraRequest["distance"] as? Double == 10 && writes == [.rain])
        var cameraFrame: [String: Any] = ["renderedFrame": 10, "normalWorldVisible": true,
            "direction": "forward", "distance": 10,
            "camera": ["position": ["x": 1, "y": 2, "z": 3],
                       "rotation": ["x": 0, "y": 0, "z": 0, "w": 1], "fieldOfViewDegrees": 66]]
        cameraFrame["normalWorldVisible"] = false
        precondition(!bridge.command(receipt(cameraRequest, readback: cameraFrame)))
        cameraFrame["normalWorldVisible"] = true
        precondition(bridge.command(receipt(cameraRequest, readback: cameraFrame)))
        try await camera.value
        let rejected = Task { try await bridge.moveCamera(direction: .reset, distance: 2) }
        let rejectedRequest = await request(bridge)
        var failure = receipt(rejectedRequest, readback: [:]); failure["applied"] = false; failure["error"] = "normal_world_not_visible"
        precondition(bridge.command(failure))
        do { try await rejected.value; preconditionFailure("renderer rejection accepted as success") }
        catch UnitySpatialPresentationBridge.PresentationError.rendererRejected(let code) { precondition(code == "normal_world_not_visible") }
        let switching = Task { try await bridge.moveCamera(direction: .left, distance: 2) }
        let switchingRequest = await request(bridge)
        world = "world-b"; bridge.observeWorldWeather(worldID: "world-b", value: .clear)
        precondition(!bridge.command(receipt(switchingRequest, readback: cameraFrame)))
        do { try await switching.value; preconditionFailure("world switch accepted old request") }
        catch UnitySpatialPresentationBridge.PresentationError.worldChanged { }
        let cancelled = Task { try await bridge.moveCamera(direction: .right, distance: 2) }
        _ = await request(bridge); cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("cancelled request completed") }
        catch is CancellationError { }
        let closing = Task { try await bridge.moveCamera(direction: .backward, distance: 2) }
        _ = await request(bridge); bridge.close()
        do { try await closing.value; preconditionFailure("closed bridge completed request") }
        catch UnitySpatialPresentationBridge.PresentationError.closed { }
        let timeout = UnitySpatialPresentationBridge(currentWorldID: { "world-c" }, changeWeather: { _ in }, timeoutNanoseconds: 10_000_000)
        do { try await timeout.moveCamera(direction: .forward, distance: 2); preconditionFailure("missing renderer receipt completed") }
        catch UnitySpatialPresentationBridge.PresentationError.timedOut { }
        print("PASS spatial presentation: read-only normal-frame confirmation, actual-frame receipt gate, thunderstorm base override, authority change, camera clamp, hidden/stale/replay rejection, cancellation/world switch/close/timeout; no production writes")
    }
}
