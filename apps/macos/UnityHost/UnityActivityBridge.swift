import Foundation

/// One authority context drives navigation and activity phases; Unity only projects it.
/// Effects must wait for a matching rendered-position acknowledgement, never a click.
@MainActor
final class UnityActivityBridge {
    let context: WorldAgentContext
    private var closed = false
    private var renderedRequestID: String?
    private var renderedPhase: String?
    private var renderedPosition: [Double]?
    private var renderedAt: Date?
    var motionProjection: (@MainActor () -> (required: Bool, motion: [String: Any]?))?
    var contactProjection: (@MainActor () -> [Double]?)?
    var contactObjectProjection: (@MainActor () -> String?)?
    private var contactedRequestID: String?
    private var contactedObjectID: String?
    var onFiniteMotionCompleted: (@MainActor (String, String) -> Void)?
    private var renderedMotionReady = false
    private var projectionDiagnostic = "not_received"
    private var completedProjectionKey: String?
    private var diagnosticRequestID: String?
    private var snapshotDiagnosticPhases = Set<String>()
    private var receiptDiagnosticPhases = Set<String>()

    init(context: WorldAgentContext) { self.context = context }

    func start() { guard !closed else { return }; context.startTicking() }

    func close() {
        closed = true
        // A successor may already own the verified authority revision. Retiring
        // this projection must not write an idle checkpoint behind its readback.
        context.stopTicking(checkpoint: false)
        invalidateProjection()
    }

    func snapshot() -> [String: Any] {
        guard !closed else { return ["status": "unavailable"] }
        let snapshot = context.snapshot
        guard let data = try? JSONEncoder().encode(snapshot),
              var value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return ["status": "unavailable"] }
        value["requestID"] = context.currentActivityRequestID ?? ""
        value["status"] = "ready"
        let active = snapshot.activeActivity
        let phase = active?.phase.rawValue ?? "idle"
        resetDiagnosticsIfNeeded()
        if snapshotDiagnosticPhases.insert(phase).inserted {
            let contract = active.flatMap { context.activityCatalog.definition(id: $0.id)?.contract(for: $0.phase) }
            NSLog("[UnityActivityPhase] snapshot phase=%@ revision=%llu contractMotionCount=%ld contractDuration=%.3f waitGate=%d stateActive=%d executorActive=%d",
                  phase, context.state.revision, contract?.motionIDs.count ?? 0,
                  contract?.durationSeconds ?? -1, context.waitsForRenderedActivityCompletion?() == true ? 1 : 0,
                  context.state.activeActivity != nil ? 1 : 0, context.runningActivity != nil ? 1 : 0)
        }
        if contactedRequestID == context.currentActivityRequestID,
           let objectID = contactedObjectID {
            value["contactConfirmedObjectID"] = objectID
        }
        if let seat = context.activeSeatProjection {
            value["seatRequired"] = true
            value["seatObjectID"] = seat.objectID
            value["seatTarget"] = ["x": Double(seat.contactPoint.x),
                "y": Double(seat.contactPoint.y), "z": Double(seat.contactPoint.z)]
        }
        if let contact = contactProjection?(), contact.count == 3 {
            value["contactRequired"] = true
            value["contactTarget"] = ["x": contact[0], "y": contact[1], "z": contact[2]]
        }
        if let projection = motionProjection?() {
            value["motionRequired"] = projection.required
            if let motion = projection.motion { value["motion"] = motion }
        }
        return value
    }

    /// A stale acknowledgement from a previous request/world cannot authorize effects.
    func acknowledgeProjection(_ value: [String: Any]) -> Bool {
        guard !closed, value["worldID"] as? String == context.manifest.worldID,
              let request = value["requestID"] as? String,
              request == context.currentActivityRequestID,
              let phase = value["phase"] as? String,
              phase == context.activeActivitySnapshot?.phase.rawValue,
              let position = value["position"] as? [Double], position.count == 3,
              position.allSatisfy(\.isFinite) else { projectionDiagnostic = "identity_phase_or_position_invalid"; return false }
        let expected = context.state.agentTransform.position
        let distanceSquared = pow(position[0] - Double(expected.x), 2)
            + pow(position[1] - Double(expected.y), 2)
            + pow(position[2] - Double(expected.z), 2)
        guard distanceSquared <= 0.0025 else { projectionDiagnostic = "position_not_arrived"; return false }
        if let seat = context.activeSeatProjection {
            guard value["seatReady"] as? Bool == true,
                  value["seatObjectID"] as? String == seat.objectID,
                  let pelvis = value["seatPosition"] as? [Double], pelvis.count == 3,
                  pelvis.allSatisfy(\.isFinite),
                  pow(pelvis[0] - Double(seat.contactPoint.x), 2)
                    + pow(pelvis[1] - Double(seat.contactPoint.y), 2)
                    + pow(pelvis[2] - Double(seat.contactPoint.z), 2) <= 0.0025
            else { projectionDiagnostic = "seat_pelvis_not_contacted"; return false }
        }
        resetDiagnosticsIfNeeded()
        if receiptDiagnosticPhases.insert(phase).inserted {
            NSLog("[UnityActivityPhase] receipt phase=%@ revision=%llu motionReady=%d motionPlaying=%d motionCompleted=%d",
                  phase, context.state.revision, value["motionReady"] as? Bool == true ? 1 : 0,
                  value["motionPlaying"] as? Bool == true ? 1 : 0,
                  value["motionCompleted"] as? Bool == true ? 1 : 0)
        }
        var contactObserved = false
        if phase != "approach", contactedRequestID != request, let target = contactProjection?() {
            if value["contactReady"] as? Bool == true,
               let hand = value["contactPosition"] as? [Double], hand.count == 3,
               hand.allSatisfy(\.isFinite), target.count == 3,
               zip(hand,target).reduce(0, { $0 + pow($1.0-$1.1,2) }) <= 0.01 {
                contactObserved = true
            }
            // Contact authorizes the device effect in hasRenderedLoop. It must
            // not discard the finite clip's completion after its contact window.
        }
        let projection = motionProjection?()
        if projection?.required == true {
            guard let expectedID = projection?.motion?["id"] as? String,
                  value["motionID"] as? String == expectedID,
                  value["motionReady"] as? Bool == true else { projectionDiagnostic = "motion_id_or_readiness_mismatch"; return false }
            if projection?.motion?["loop"] as? Bool == true {
                guard value["motionPlaying"] as? Bool == true else { projectionDiagnostic = "loop_motion_not_playing"; return false }
            }
        }
        if contactObserved {
            contactedRequestID = request
            contactedObjectID = contactObjectProjection?()
        }
        renderedRequestID = request
        renderedPhase = phase
        renderedPosition = position
        renderedAt = Date()
        renderedMotionReady = projection?.required != true || value["motionReady"] as? Bool == true
        projectionDiagnostic = contactProjection?() != nil && contactedRequestID != request
            ? "hand_not_at_device" : "accepted"
        if projection?.required == true,
           projection?.motion?["loop"] as? Bool == false,
           value["motionCompleted"] as? Bool == true,
           value["motionPlaying"] as? Bool == false,
           let motionID = projection?.motion?["id"] as? String {
            let key = request + "|" + phase + "|" + motionID
            if completedProjectionKey != key {
                completedProjectionKey = key
                onFiniteMotionCompleted?(request, phase)
            }
        }
        return true
    }

    private func resetDiagnosticsIfNeeded() {
        let request = context.currentActivityRequestID
        guard diagnosticRequestID != request else { return }
        diagnosticRequestID = request
        snapshotDiagnosticPhases.removeAll(keepingCapacity: true)
        receiptDiagnosticPhases.removeAll(keepingCapacity: true)
    }

    func hasRenderedLoop(activityID: String) -> Bool {
        guard !closed else { return false }
        let active = context.activeActivitySnapshot
        return active?.id == activityID
            && active?.phase.rawValue == "loop"
            && context.currentActivityRequestID == renderedRequestID
            && renderedPhase == "loop" && projectionIsCurrent && renderedMotionReady
            && (contactProjection?() == nil || contactedRequestID == context.currentActivityRequestID)
    }

    /// Called by the existing outcome's play closure. Authority reaching loop alone
    /// cannot perform a device effect before the character is actually projected.
    func waitForRenderedLoop(activityID: String, requestID: String,
                             timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !hasRenderedLoop(activityID: activityID) {
            try Task.checkCancellation()
            guard !closed, context.currentActivityRequestID == requestID,
                  context.activeActivitySnapshot?.id == activityID else {
                throw CancellationError()
            }
            guard Date() < deadline else {
                NSLog("[UnityActivity] render_wait_failed activity=%@ phase=%@ projection=%@",activityID,
                      context.activeActivitySnapshot?.phase.rawValue ?? "none",projectionDiagnostic)
                throw ProjectionError.notRendered
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    enum ProjectionError: Error { case notRendered }

    private var projectionIsCurrent: Bool {
        guard let position = renderedPosition, let renderedAt,
              Date().timeIntervalSince(renderedAt) < 1 else { return false }
        let expected = context.state.agentTransform.position
        return pow(position[0] - Double(expected.x), 2)
            + pow(position[1] - Double(expected.y), 2)
            + pow(position[2] - Double(expected.z), 2) <= 0.0025
    }

    func invalidateProjection() {
        renderedRequestID = nil
        renderedPhase = nil
        renderedPosition = nil
        renderedAt = nil
        renderedMotionReady = false
        contactedRequestID = nil
        contactedObjectID = nil
        projectionDiagnostic = "not_received"
        completedProjectionKey = nil
    }
}
