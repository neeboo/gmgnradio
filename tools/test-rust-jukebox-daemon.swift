import Foundation

@main struct JukeboxClientAcceptance {
    static func main() async throws {
        let endpoint = CommandLine.arguments[1]
        func client(_ world: String, host: String = "private-host") -> RustJukeboxClient {
            .init(endpointFile: endpoint, helperPath: "/no-launch", worldID: world,
                scopeID: "resident-private", hostSessionID: host)
        }
        func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        func stage(_ value: String) { FileHandle.standardError.write(Data("STAGE \(value)\n".utf8)) }
        let operation = try data(["kind": "resume_music", "args": [:]])
        let authority = client("fixture")
        let begun = try await authority.begin(operation: operation, requestID: "business-request")
        let duplicate = try await authority.begin(operation: operation, requestID: "business-request")
        precondition(begun.compoundID == duplicate.compoundID)
        let prepare = try await authority.claim(compoundID: begun.compoundID, actionID: begun.action!.actionID)
        precondition(prepare.action?.status == "claimed")
        do {
            _ = try await authority.receipt(compoundID: begun.compoundID, actionID: prepare.action!.actionID,
                outcome: "completed", facts: data(["worldRevision": 1, "objectID": "missing-object",
                    "interactionTarget": ["x": 0, "y": 0, "z": 0], "contactTarget": NSNull(),
                    "motionRequired": false, "requiredMotionID": NSNull(), "avatarFormat": NSNull()]))
            fatalError("missing materialized object accepted")
        } catch WorldAuthorityError.daemon(let code) {
            precondition(code == "jukebox_invalid_facts")
        }
        stage("prepare receipt")
        let prepared = try await authority.receipt(compoundID: begun.compoundID, actionID: prepare.action!.actionID,
            outcome: "completed", facts: data(["worldRevision": 1, "objectID": "jukebox",
                "interactionTarget": ["x": 0, "y": 0, "z": 0], "contactTarget": NSNull(),
                "motionRequired": false, "requiredMotionID": NSNull(), "avatarFormat": NSNull()]))
        precondition(prepared.action?.kind == "start")
        let start = try await authority.claim(compoundID: begun.compoundID, actionID: prepared.action!.actionID)
        let run = try await authority.observeActivity()
        stage("start receipt")
        let waiting = try await authority.receipt(compoundID: begun.compoundID, actionID: start.action!.actionID,
            outcome: "completed", facts: data(["runRequestID": run.runRequestID, "generation": run.generation]))
        precondition(waiting.state == "wait_render" && waiting.action == nil)
        let fence = waiting.runFence!
        let raw: [String: Any] = ["runRequestID": fence.runRequestID, "generation": fence.generation,
            "phaseGeneration": fence.phaseGeneration, "phase": fence.phase,
            "position": ["x": 0.06, "y": 0, "z": 0], "motionReady": false]
        stage("renderer outside boundary")
        let notArrived = try await authority.read(compoundID: begun.compoundID, renderFacts: data(raw))
        precondition(notArrived.state == "wait_render" && notArrived.action == nil)
        var valid = raw; valid["position"] = ["x": 0.04, "y": 0, "z": 0]
        let allowed = try await authority.read(compoundID: begun.compoundID, renderFacts: data(valid))
        precondition(allowed.action?.kind == "play" && allowed.action?.status == "pending")
        let play = try await authority.claim(compoundID: begun.compoundID, actionID: allowed.action!.actionID)
        let playerFacts = try data(["hasSnapshot": true, "isPlaying": true, "playbackState": "playing",
            "trackID": "netease:fixture", "programID": NSNull(), "slotIndex": NSNull()])
        let completed = try await authority.receipt(compoundID: begun.compoundID, actionID: play.action!.actionID,
            outcome: "completed", facts: playerFacts)
        precondition(completed.state == "completed")
        let repeated = try await authority.receipt(compoundID: begun.compoundID, actionID: play.action!.actionID,
            outcome: "completed", facts: playerFacts)
        precondition(repeated.state == "completed")
        do { _ = try await client("fixture", host: "foreign").read(compoundID: begun.compoundID)
            fatalError("foreign session accepted")
        } catch WorldAuthorityError.daemon(let code) {
            precondition(code == "jukebox_identity_mismatch")
        }
        let crash = client("restart")
        let pending = try await crash.begin(operation: operation, requestID: "restart-business")
        _ = try await crash.claim(compoundID: pending.compoundID, actionID: pending.action!.actionID)
        try data(["compoundID": pending.compoundID, "actionID": pending.action!.actionID])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .withoutOverwriting)
        print("PASS actual typed jukebox RPC: identity/idempotence/claimed-before-effect/renderer-boundary/player-receipt")
    }
}
