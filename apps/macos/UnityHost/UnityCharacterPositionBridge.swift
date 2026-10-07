import Foundation
import CoreFoundation

/// Human coordinate requests use the existing authority movement executor.
/// Completion requires arrival, a real camera-frame receipt and durable readback.
@MainActor
final class UnityCharacterPositionBridge {
    struct State {
        let worldID: String
        let revision: UInt64
        let layoutRevision: UInt64
        let position: [Double]
        let movementRequestID: String?
        var failure: String? = nil
    }
    private struct Pending {
        let requestID: String
        let target: [Double]
        let submittedRevision: UInt64
        let deadline: Date
    }
    private let worldID: String, spawn: [Double]
    private let state: () -> State
    private let move: ([Double], String, UInt64) throws -> [Double]
    private let durableReadback: () async throws -> State
    private let now: () -> Date
    private var pending: Pending?
    private var readbackTask: Task<Void, Never>?
    private var closed = false
    private var status = "idle", notice: String?
    private var lastRequestID: String?

    init(worldID: String, spawn: [Double], state: @escaping () -> State,
         move: @escaping ([Double], String, UInt64) throws -> [Double],
         durableReadback: @escaping () async throws -> State,
         now: @escaping () -> Date = Date.init) {
        self.worldID = worldID; self.spawn = spawn; self.state = state
        self.move = move; self.durableReadback = durableReadback; self.now = now
    }

    static func positionsMatch(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == 3 && b.count == 3 && a.allSatisfy(\.isFinite) && b.allSatisfy(\.isFinite)
            && zip(a, b).reduce(0, { $0 + pow($1.0 - $1.1, 2) }) <= 0.0025
    }
    func snapshot() -> [String: Any] {
        let current = state()
        if let pending, !closed {
            if now() > pending.deadline { fail("人物移动或画面确认超时，请重试。") }
            else if let failure = current.failure { fail(failure) }
            else if current.worldID != worldID { fail("当前空间已更换。") }
            else if current.movementRequestID != nil && current.movementRequestID != pending.requestID {
                fail("人物移动已被新的请求替换。")
            } else if current.movementRequestID == nil && current.revision > pending.submittedRevision {
                if Self.positionsMatch(current.position, pending.target) {
                    if readbackTask == nil { status = "awaiting-render" }
                } else { fail("人物未到达指定位置。") }
            }
        }
        var result: [String: Any] = ["worldID": worldID, "revision": current.revision,
            "layoutRevision": current.layoutRevision,
            "position": current.position, "spawn": spawn, "status": status,
            "working": pending != nil, "available": !closed && current.worldID == worldID,
            "requestID": lastRequestID as Any? ?? NSNull(), "notice": notice as Any? ?? NSNull()]
        if let pending, status == "awaiting-render" {
            result["renderRequest"] = ["requestID": pending.requestID, "worldID": worldID,
                "revision": current.revision, "position": pending.target, "groundY": pending.target[1]]
        }
        return result
    }

    @discardableResult func command(_ value: [String: Any]) -> Bool {
        guard let op = value["op"] as? String,
              op == "presence.position" || op == "presence.position.reset" else { return false }
        guard !closed, pending == nil else { return false }
        do {
            guard value["worldID"] as? String == worldID,
                  let id = value["requestID"] as? String, !id.isEmpty, id.utf8.count <= 256,
                  let revision = value["expectedRevision"] as? NSNumber,
                  let layout = value["expectedLayoutRevision"] as? NSNumber,
                  CFGetTypeID(revision) != CFBooleanGetTypeID(), revision.doubleValue >= 0,
                  CFGetTypeID(layout) != CFBooleanGetTypeID(), layout.doubleValue >= 0,
                  layout.doubleValue <= 9_007_199_254_740_991,
                  layout.doubleValue.rounded() == layout.doubleValue,
                  revision.doubleValue <= 9_007_199_254_740_991,
                  revision.doubleValue.rounded() == revision.doubleValue else { throw Failure.invalidRequest }
            let current = state()
            // Idle clock ticks also advance revision. Absolute target coordinates
            // do not depend on that earlier pose; revalidate geometry now and use
            // the current revision in the authority's normal CAS executor.
            guard current.worldID == worldID, revision.uint64Value <= current.revision else { throw Failure.staleWorld }
            guard layout.uint64Value == current.layoutRevision else { throw Failure.geometryChanged }
            let target = op == "presence.position.reset" ? spawn : value["position"] as? [Double] ?? []
            guard target.count == 3, target.allSatisfy(\.isFinite) else { throw Failure.invalidRequest }
            // The injected authority hook must validate ground Y, capsule fit and
            // the whole route before replacing a run; its persistence retains CAS.
            let admitted = try move(target, id, current.revision)
            let after = state()
            guard admitted.count == 3, admitted.allSatisfy(\.isFinite),
                  abs(admitted[0] - target[0]) <= 0.00001, abs(admitted[2] - target[2]) <= 0.00001,
                  abs(admitted[1] - target[1]) <= 0.05, after.worldID == worldID,
                  after.revision > current.revision else { throw Failure.invalidAdmission }
            pending = Pending(requestID: id, target: admitted, submittedRevision: current.revision,
                              deadline: now().addingTimeInterval(120))
            lastRequestID = id; status = "moving"; notice = "人物正在移动，等待空间与画面确认。"
        } catch { fail(error.localizedDescription) }
        return true
    }

    @discardableResult func acknowledgeRendered(_ value: [String: Any]) -> Bool {
        guard !closed, status == "awaiting-render", readbackTask == nil, let pending,
              value["worldID"] as? String == worldID,
              value["requestID"] as? String == pending.requestID,
              let revision = value["revision"] as? NSNumber,
              revision.uint64Value > pending.submittedRevision,
              revision.uint64Value <= state().revision,
              state().movementRequestID == nil,
              Self.positionsMatch(state().position, pending.target),
              ((value["renderedFrame"] as? NSNumber)?.intValue ?? 0) > 0,
              value["normalWorldVisible"] as? Bool == true,
              let rootY = value["rootY"] as? Double, let groundY = value["groundY"] as? Double,
              rootY.isFinite, groundY.isFinite,
              abs(rootY - pending.target[1]) <= 0.05, abs(groundY - pending.target[1]) <= 0.001,
              let position = value["position"] as? [Double],
              Self.positionsMatch(position, pending.target) else { return false }
        status = "confirming"
        readbackTask = Task { [weak self] in
            guard let self else { return }
            defer { self.readbackTask = nil }
            do {
                let saved = try await self.durableReadback()
                guard !Task.isCancelled, !self.closed,
                      self.pending?.requestID == pending.requestID else { return }
                guard saved.worldID == self.worldID, saved.revision > pending.submittedRevision,
                      saved.movementRequestID == nil,
                      Self.positionsMatch(saved.position, pending.target),
                      Self.positionsMatch(self.state().position, pending.target),
                      self.state().movementRequestID == nil else { throw Failure.readbackMismatch }
                self.pending = nil; self.status = "completed"; self.notice = "人物位置已更新。"
            } catch { if !Task.isCancelled && !self.closed { self.fail(error.localizedDescription) } }
        }
        return true
    }
    func close() { closed = true; readbackTask?.cancel(); readbackTask = nil; pending = nil }
    private func fail(_ message: String) { pending = nil; status = "failed"; notice = message }
    private enum Failure: LocalizedError {
        case invalidRequest, staleWorld, geometryChanged, invalidAdmission, readbackMismatch
        var errorDescription: String? {
            switch self {
            case .invalidRequest: "人物坐标请求无效。"
            case .staleWorld: "空间状态已变化，请重新读取坐标。"
            case .geometryChanged: "空间布局已变化，请重新读取坐标。"
            case .invalidAdmission: "空间未确认合法的地面目标。"
            case .readbackMismatch: "人物位置尚未完成空间持久确认。"
            }
        }
    }
}
