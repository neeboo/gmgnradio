import Foundation
import WorldRuntime

/// Local presentation commands complete only after the matching Unity render receipt.
/// Weather persistence belongs to the supplied existing world-authority hook.
@MainActor
final class UnitySpatialPresentationBridge {
    enum PresentationError: Error, LocalizedError {
        case closed, worldUnavailable, worldChanged, busy, timedOut, invalidDistance
        case rendererRejected(String)
        var errorDescription: String? {
            switch self {
            case .closed: "空间展示会话已结束。"
            case .worldUnavailable: "请先打开完整空间。"
            case .worldChanged: "空间已切换，旧展示请求已取消。"
            case .busy: "上一项空间展示尚未完成。"
            case .timedOut: "空间展示尚未获得渲染确认。"
            case .invalidDistance: "镜头移动距离无效。"
            case .rendererRejected(let code): "空间展示未应用：\(code)"
            }
        }
    }
    private struct Pending {
        let id: String
        let worldID: String
        let payload: [String: Any]
        let continuation: CheckedContinuation<Void, Error>
    }
    private let currentWorldID: @MainActor () -> String?
    private let changeWeather: @MainActor (WorldWeather) async throws -> Void
    private let timeoutNanoseconds: UInt64
    private var pending: Pending?
    private var timeout: Task<Void, Never>?
    private var closed = false
    private var worldID: String?
    private var observedWeather: WorldWeather?
    private var overrideBase: WorldWeather?
    private var weather = SpatialWeather.clear
    private var generation: UInt64 = 0
    private var lastReceipt: [String: Any]?

    init(currentWorldID: @escaping @MainActor () -> String?,
         changeWeather: @escaping @MainActor (WorldWeather) async throws -> Void,
         timeoutNanoseconds: UInt64 = 5_000_000_000) {
        self.currentWorldID = currentWorldID
        self.changeWeather = changeWeather
        self.timeoutNanoseconds = timeoutNanoseconds
        worldID = currentWorldID()
    }

    func setWeather(_ value: SpatialWeather) async throws {
        try Task.checkCancellation()
        let world = try availableWorld()
        let base: WorldWeather = value == .clear ? .clear : .rain
        let prior = (weather, overrideBase)
        weather = value; overrideBase = base
        do { try await changeWeather(base) }
        catch { weather = prior.0; overrideBase = prior.1; throw error }
        generation &+= 1
        try await request(worldID: world, payload: ["operation": "weather", "weather": value.rawValue])
    }

    func moveCamera(direction: SpatialCameraCommandDirection, distance: Float) async throws {
        guard distance.isFinite else { throw PresentationError.invalidDistance }
        let world = try availableWorld()
        try await request(worldID: world, payload: ["operation": "camera", "direction": direction.rawValue,
                                                   "distance": Double(min(max(distance, 0.5), 10))])
    }

    /// Read-only preflight for actions that persist weather or start a paid scene job.
    func confirmVisible() async throws {
        let world = try availableWorld()
        try await request(worldID: world, payload: ["operation": "visibility"])
    }

    func observeWorldWeather(worldID id: String, value: WorldWeather) {
        guard !closed, currentWorldID() == id else { return }
        synchronizeWorld()
        observedWeather = value
        if let base = overrideBase, value != base { overrideBase = nil }
        if overrideBase == nil {
            let next: SpatialWeather = value == .rain || value == .snow ? .rain : .clear
            if weather != next { weather = next; generation &+= 1 }
        }
    }

    func snapshot() -> [String: Any] {
        synchronizeWorld()
        var result: [String: Any] = ["generation": generation,
            "status": closed ? "closed" : pending == nil ? "idle" : "pending",
            "worldID": worldID as Any? ?? NSNull(), "weather": weather.rawValue,
            "request": pending?.payload as Any? ?? NSNull()]
        if let lastReceipt { result["lastReceipt"] = lastReceipt }
        return result
    }

    @discardableResult
    func command(_ receipt: [String: Any]) -> Bool {
        synchronizeWorld()
        guard !closed, receipt["op"] as? String == "spatial.presentation.receipt", let pending,
              receipt["id"] as? String == pending.id, receipt["worldID"] as? String == pending.worldID,
              receipt["operation"] as? String == pending.payload["operation"] as? String,
              let applied = receipt["applied"] as? Bool else { return false }
        if !applied {
            lastReceipt = receipt
            finish(.failure(PresentationError.rendererRejected(receipt["error"] as? String ?? "renderer_unavailable")))
            return true
        }
        guard let readback = receipt["readback"] as? [String: Any],
              let frame = readback["renderedFrame"] as? NSNumber, frame.int64Value > 0,
              readback["normalWorldVisible"] as? Bool == true else { return false }
        if pending.payload["operation"] as? String == "weather" {
            guard readback["weather"] as? String == pending.payload["weather"] as? String,
                  readback["overlayVisible"] as? Bool == true,
                  readback["passive"] as? Bool == true else { return false }
        } else {
            guard let camera = readback["camera"] as? [String: Any],
                  let position = camera["position"] as? [String: Any],
                  let rotation = camera["rotation"] as? [String: Any],
                  Self.finite(position, keys: ["x", "y", "z"]),
                  Self.finite(rotation, keys: ["x", "y", "z", "w"]),
                  let fov = camera["fieldOfViewDegrees"] as? NSNumber, fov.doubleValue.isFinite,
                  fov.doubleValue > 0 else { return false }
            if pending.payload["operation"] as? String == "camera" {
                guard readback["direction"] as? String == pending.payload["direction"] as? String,
                      let distance = readback["distance"] as? NSNumber,
                      let requested = pending.payload["distance"] as? Double,
                      abs(distance.doubleValue - requested) < 0.00001 else { return false }
            }
        }
        lastReceipt = receipt
        finish(.success(()))
        return true
    }

    func close() {
        guard !closed else { return }
        closed = true
        finish(.failure(PresentationError.closed))
        generation &+= 1
    }

    private static func finite(_ value: [String: Any], keys: [String]) -> Bool {
        keys.allSatisfy { (value[$0] as? NSNumber)?.doubleValue.isFinite == true }
    }
    private func availableWorld() throws -> String {
        synchronizeWorld()
        guard !closed else { throw PresentationError.closed }
        guard let worldID, !worldID.isEmpty else { throw PresentationError.worldUnavailable }
        guard pending == nil else { throw PresentationError.busy }
        return worldID
    }
    private func synchronizeWorld() {
        let current = currentWorldID()
        guard current != worldID else { return }
        finish(.failure(PresentationError.worldChanged))
        worldID = current; observedWeather = nil; overrideBase = nil
        weather = .clear; lastReceipt = nil; generation &+= 1
    }
    private func request(worldID: String, payload: [String: Any]) async throws {
        let id = UUID().uuidString
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                var command = payload
                command["id"] = id; command["worldID"] = worldID
                pending = Pending(id: id, worldID: worldID, payload: command, continuation: continuation)
                generation &+= 1
                timeout = Task { [weak self] in
                    guard let self else { return }
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    guard pending?.id == id else { return }
                    if currentWorldID() != worldID { synchronizeWorld() }
                    else { finish(.failure(PresentationError.timedOut)) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pending?.id == id else { return }
                self?.finish(.failure(CancellationError()))
            }
        }
    }
    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel(); timeout = nil
        guard let active = pending else { return }
        pending = nil; generation &+= 1
        active.continuation.resume(with: result)
    }
}
