import Foundation

@main struct CharacterPositionChecks {
    @MainActor static func main() async throws {
        typealias State = UnityCharacterPositionBridge.State
        var position = [0.0, 0.12, 0.0], revision: UInt64 = 7
        var moving: String?, target: [Double]?, durable = position, commits = 0
        var layoutRevision: UInt64 = 2
        var durableRevision = revision
        let bridge = UnityCharacterPositionBridge(worldID: "fixture-a", spawn: [0, 0.12, 0],
            state: { State(worldID: "fixture-a", revision: revision, layoutRevision: layoutRevision, position: position, movementRequestID: moving) },
            move: { requested, id, expected in
                precondition(expected == revision)
                guard abs(requested[1] - 0.12) <= 0.05, abs(requested[0]) <= 2 else { throw TestFailure.blocked }
                let grounded = [requested[0], 0.12, requested[2]]
                target = grounded; moving = id; revision += 1; commits += 1
                return grounded
            }, durableReadback: {
                State(worldID: "fixture-a", revision: durableRevision, layoutRevision: layoutRevision, position: durable, movementRequestID: nil)
            })
        func request(_ id: String, _ coordinates: [Double], _ world: String = "fixture-a", _ expected: UInt64? = nil) -> [String: Any] {
            ["op": "presence.position", "worldID": world, "requestID": id,
             "expectedRevision": expected ?? revision, "position": coordinates]
                .merging(["expectedLayoutRevision": layoutRevision], uniquingKeysWith: { _, new in new })
        }
        precondition(bridge.command(request("wrong-world", [1, 0.12, 0], "fixture-b")))
        precondition(bridge.snapshot()["status"] as? String == "failed" && commits == 0)
        precondition(bridge.command(request("future-revision", [1, 0.12, 0], "fixture-a", 99)))
        precondition(commits == 0)
        let oldGeometry = request("geometry-changed", [1, 0.12, 0])
        layoutRevision += 1
        precondition(bridge.command(oldGeometry))
        precondition(commits == 0 && bridge.snapshot()["status"] as? String == "failed")
        precondition(bridge.command(request("floating", [1, 1, 0])))
        precondition(bridge.snapshot()["status"] as? String == "failed" && commits == 0)
        precondition(bridge.command(request("blocked", [4, 0.12, 0])))
        precondition(commits == 0)
        precondition(bridge.command(request("move", [1, 0.10, 0], "fixture-a", 1))) // idle drift + small Y mismatch normalizes
        precondition(bridge.snapshot()["status"] as? String == "moving")
        precondition(!bridge.command(request("busy", [1, 0.12, 1])))
        position = target!; moving = nil; revision += 1
        let arrived = bridge.snapshot()
        precondition(arrived["status"] as? String == "awaiting-render")
        precondition((arrived["renderRequest"] as? [String: Any])?["groundY"] as? Double == 0.12)
        var receipt: [String: Any] = ["worldID": "fixture-a", "requestID": "move", "revision": revision,
            "position": position, "rootY": position[1], "groundY": position[1],
            "renderedFrame": 1, "normalWorldVisible": true]
        receipt["worldID"] = "fixture-b"; precondition(!bridge.acknowledgeRendered(receipt))
        receipt["worldID"] = "fixture-a"; receipt["rootY"] = 1.0
        precondition(!bridge.acknowledgeRendered(receipt))
        receipt["rootY"] = position[1]; receipt["renderedFrame"] = 0
        precondition(!bridge.acknowledgeRendered(receipt))
        receipt["renderedFrame"] = 1
        precondition(bridge.acknowledgeRendered(receipt))
        while bridge.snapshot()["status"] as? String == "confirming" { await Task.yield() }
        precondition(bridge.snapshot()["status"] as? String == "failed") // durable still old
        precondition(bridge.command(request("verified", [1, 0.12, 1])))
        position = target!; durable = position; moving = nil; revision += 1
        durableRevision = revision; revision += 10 // Idle clock is newer than the durable arrival checkpoint.
        _ = bridge.snapshot(); receipt["requestID"] = "verified"; receipt["revision"] = revision; receipt["position"] = position
        precondition(bridge.acknowledgeRendered(receipt))
        while bridge.snapshot()["status"] as? String == "confirming" { await Task.yield() }
        precondition(bridge.snapshot()["status"] as? String == "completed")
        precondition(bridge.command(request("replaced", [1, 0.12, -1])))
        moving = "another-owner"
        precondition(bridge.snapshot()["status"] as? String == "failed")
        moving = nil
        precondition(bridge.command(["op": "presence.position.reset", "worldID": "fixture-a", "expectedRevision": revision,
            "expectedLayoutRevision": layoutRevision, "requestID": "reset"]))
        precondition(target! == [0, 0.12, 0])
        bridge.close(); precondition(!bridge.command(request("closed", [0, 0.12, 0])))
        for (admitted, advances) in [([2.0, 0.12, 0.0], true), ([1.0, 1.0, 0.0], true),
                                     ([1.0, Double.nan, 0.0], true), ([1.0, 0.12, 0.0], false)] {
            var version: UInt64 = 1
            let rejected = UnityCharacterPositionBridge(worldID: "admission", spawn: [0, 0.12, 0],
                state: { State(worldID: "admission", revision: version, layoutRevision: 0,
                    position: [0, 0.12, 0], movementRequestID: nil) },
                move: { _, _, _ in if advances { version += 1 }; return admitted },
                durableReadback: { fatalError("Invalid admission must not request durable readback") })
            precondition(rejected.command(["op": "presence.position", "worldID": "admission", "requestID": "invalid",
                "expectedRevision": 1, "expectedLayoutRevision": 0, "position": [1.0, 0.12, 0.0]]))
            precondition(rejected.snapshot()["status"] as? String == "failed")
        }
        print("Character position: world/layout isolation, clock drift, normalized ground admission, path rejection, replacement, arrival/render/durable gate, reset passed")
    }
    enum TestFailure: LocalizedError {
        case blocked
        var errorDescription: String? { "Fixture floor or path rejected" }
    }
}
