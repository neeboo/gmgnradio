import Foundation

public enum WorldSimulationError: Error, Equatable, Sendable {
    case staleRevision(submitted: UInt64, current: UInt64)
    case invalidDuration(TimeInterval)
    case activityAlreadyActive(activityID: String)
    case noActiveActivity
    case activityIsNotInterrupted(activityID: String)
    case goalAlreadyCompleted(goalID: String)
    case propIsHeld(objectID: String)
}

extension WorldSimulationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .staleRevision(_, current): "世界状态已经变化，请按版本 \(current) 重试。"
        case .invalidDuration: "世界时间增量无效。"
        case let .activityAlreadyActive(activityID): "居民正在进行活动 \(activityID)。"
        case .noActiveActivity: "居民当前没有活动。"
        case let .activityIsNotInterrupted(activityID): "活动 \(activityID) 当前不能恢复。"
        case let .goalAlreadyCompleted(goalID): "目标 \(goalID) 已经完成。"
        case let .propIsHeld(objectID): "居民正在手持物件 \(objectID)，请先放回。"
        }
    }
}

public struct WorldSimulation: Sendable {
    public private(set) var state: WorldState
    /// Fixed capacity of the in-memory retained window, counted **including** the
    /// session-boundary marker (`.worldLoaded`/`.worldRestored`), which is never
    /// evicted. The window therefore holds at most `retainedEventCapacity - 1`
    /// non-marker events at any time.
    ///
    /// The capacity is chosen to stay far above the number of retained events a
    /// normally consuming host records between two consecutive observation
    /// drains. Continuous movement adds at most one `.agentTransformUpdated` per
    /// 30 Hz tick and the host drains at every tick, so a per-tick consumer never
    /// falls behind the window; the bound is what keeps a resident that walks for
    /// minutes from growing memory without limit. A consumer that *stops* draining
    /// (or attaches late) can lag beyond the window — that is a detectable gap, see
    /// `trimmedNewestSequence` — never a silently "complete" replay.
    public static let retainedEventCapacity = 64

    /// Retained, fixed-capacity world-event window: the session-boundary marker
    /// (`.worldLoaded` or `.worldRestored`) always occupies `events[0]` and is
    /// never evicted, followed by the newest retained events in recording order.
    /// Disposable clock events (`.timeAdvanced` / `.timeCaughtUp`) are returned by
    /// the mutating API but are never retained, so an idling resident cannot grow
    /// this window at the 30 Hz tick cadence.
    ///
    /// Window positions are **not** stable storage for cursors: when the window
    /// overflows, the oldest non-marker events are dropped from the front. Every
    /// event carries a strictly monotonic `sequence` (the mutation watermark), so
    /// consumers must track a sequence cursor and detect skips through
    /// `trimmedNewestSequence` — never by remembering an absolute array index.
    public private(set) var events: [WorldEvent]
    /// Sequence of the newest retained event ever evicted from the front of the
    /// window, or `nil` while nothing has been evicted yet. Monotonic: once an
    /// event with sequence `s` is dropped, every later drop has a larger sequence.
    ///
    /// A consumer whose sequence cursor is `c` can detect an honest gap with
    /// `c < trimmedNewestSequence`: at least one retained event newer than the
    /// cursor no longer exists in `events`. (Clock events consume sequence numbers
    /// between retained events, so sequence gaps inside the window are normal and
    /// must not be mistaken for trimming; only this counter distinguishes real
    /// evictions from clock noise.) The session marker is never counted here.
    public private(set) var trimmedNewestSequence: UInt64?

    public init(
        manifest: WorldManifest,
        startedAt: Date,
        weather: WorldWeather = .clear
    ) {
        state = WorldState(
            revision: 0,
            worldID: manifest.worldID,
            worldTime: startedAt,
            lastObservedWallTime: startedAt,
            weather: weather,
            agentTransform: manifest.spawn
        )
        events = [
            WorldEvent(
                sequence: 0,
                revision: 0,
                worldTime: startedAt,
                kind: .worldLoaded(worldID: manifest.worldID)
            ),
        ]
    }

    public init(restoring state: WorldState) {
        self.state = state
        // The restore marker carries the persisted mutation watermark
        // (sequence == revision). Later records keep numbering strictly above it,
        // so event sequences never restart at zero after a restore.
        events = [
            WorldEvent(
                sequence: state.revision,
                revision: state.revision,
                worldTime: state.worldTime,
                kind: .worldRestored(worldID: state.worldID)
            ),
        ]
    }

    /// Mutates a value candidate. Callers persist that candidate before publishing it.
    public mutating func applyPropLayout(_ command: WorldPropLayoutCommand, expectedLayoutRevision: UInt64, requestID: String) throws {
        guard !requestID.isEmpty, requestID.count <= 256 else { throw WorldPropLayoutError.requestConflict }
        if let receipt = state.layoutReceipts[requestID] {
            guard receipt == command else { throw WorldPropLayoutError.requestConflict }
            return
        }
        guard expectedLayoutRevision == state.layoutRevision else {
            throw WorldPropLayoutError.staleRevision(submitted: expectedLayoutRevision, current: state.layoutRevision)
        }
        var next = state
        let objectID: String
        /// 删除这一条命令留下的墓碑（其它命令一律 nil）。事件日志里那一条**具名事实**
        /// 就读它 —— 「删除」在日志里是可查的一等公民，不是"布局变了一下"。
        var deletionTombstone: WorldPropTombstone?
        switch command {
        case let .register(prop):
            guard prop.isValid else { throw WorldPropLayoutError.invalidObject }
            objectID = prop.objectID
            if let existing = state.objectStates[objectID] {
                guard existing.generatedProp == prop else { throw WorldPropLayoutError.invalidObject }
                state.layoutReceipts[requestID] = command
                return
            }
            guard !state.objectStates.values.contains(where: { $0.generatedProp?.sourceWishID == prop.sourceWishID }) else { throw WorldPropLayoutError.invalidObject }
            let json = String(decoding: try JSONEncoder().encode(prop), as: UTF8.self)
            let scale = prop.size.y / prop.sourceHeight
            next.objectStates[objectID] = WorldObjectState(isEnabled: false,
                transform: .init(position: .init(x: 0,y: 0,z: 0),rotation: .init(x: 0,y: 0,z: 0,w: 1),scale: .init(x: scale,y: scale,z: scale)),
                metadata: ["gmgn.generated-prop.v1": json])
            next.layoutUndo = nil
        case let .place(id, placement):
            objectID = id
            guard var item = state.objectStates[id], let prop = item.generatedProp, prop.objectID == id else { throw WorldPropLayoutError.invalidObject }
            guard state.heldProp?.objectID != id else { throw WorldPropLayoutError.objectIsHeld(objectID: id) }
            guard !placement.surfaceID.isEmpty, [placement.position.x,placement.position.y,placement.position.z,placement.yaw].allSatisfy(\.isFinite) else { throw WorldPropLayoutError.invalidPlacement }
            next.layoutUndo = .init(objectID: id, previous: item, previousHeldProp: state.heldProp)
            let scale = prop.size.y / prop.sourceHeight
            item.isEnabled = true
            item.transform = .init(position: placement.position,rotation: .init(x: 0,y: sin(placement.yaw/2),z: 0,w: cos(placement.yaw/2)),scale: .init(x: scale,y: scale,z: scale))
            item.metadata["gmgn.support-surface.v1"] = placement.surfaceID
            next.objectStates[id] = item
        case let .withdraw(id):
            objectID = id
            guard var item = state.objectStates[id], item.generatedProp?.objectID == id else { throw WorldPropLayoutError.invalidObject }
            guard state.heldProp?.objectID != id else { throw WorldPropLayoutError.objectIsHeld(objectID: id) }
            next.layoutUndo = .init(objectID: id, previous: item, previousHeldProp: state.heldProp)
            item.isEnabled = false
            next.objectStates[id] = item
        case let .resize(id, size):
            objectID = id
            guard var item = state.objectStates[id], let prop = item.generatedProp, prop.objectID == id else {
                throw WorldPropLayoutError.invalidObject
            }
            guard state.heldProp?.objectID != id else { throw WorldPropLayoutError.objectIsHeld(objectID: id) }
            // 越界（太小看不见 / 太大撑满房间）由**唯一**那份尺寸策略拒绝，原因可读。
            _ = try WorldPropSizePolicy.manualSize(current: prop.effectiveSize,
                                                   targetLongestEdge: WorldPropSizePolicy.longestEdge(of: size))
            // 必须是当前尺寸的等比缩放：渲染端只有一份等比缩放，非等比会让碰撞盒与画面对不上。
            guard WorldPropSizePolicy.uniformFactor(from: prop.effectiveSize, to: size) != nil else {
                throw WorldPropLayoutError.invalidSize("尺寸必须等比缩放：画面用一份等比缩放，非等比会让碰撞盒与画面对不上。")
            }
            let resized = prop.withSize(size)
            guard resized.isValid else { throw WorldPropLayoutError.invalidSize("尺寸必须是有限的正数。") }
            // 尺寸变了 ⇒ 物件自身的字节变了。以物件字节为有效性前提的旧撤销记录必须作废，
            // 否则「撤销上次」会拿一条已经不适用的记录去复原（`undo` 会判 invalidObject）。
            // 与 hold / adjustGrip / enableCapability 同族：就地调整，不占用撤销槽。
            next.layoutUndo = nil
            item.metadata["gmgn.generated-prop.v1"] = String(decoding: try JSONEncoder().encode(resized), as: UTF8.self)
            // 画面那一份缩放必须与"这件东西多大"的**唯一**出口一致（`effectiveSize`）。
            let resizedScale = resized.effectiveSize.y / resized.sourceHeight
            guard resizedScale.isFinite, resizedScale > 0 else {
                throw WorldPropLayoutError.invalidSize("尺寸换算失败，请重新拖动。")
            }
            item.transform = .init(position: item.transform.position, rotation: item.transform.rotation,
                                   scale: .init(x: resizedScale, y: resizedScale, z: resizedScale))
            next.objectStates[id] = item
        case let .rebase(prop):
            objectID = prop.objectID
            guard var item = state.objectStates[objectID], let existing = item.generatedProp else {
                throw WorldPropLayoutError.invalidObject
            }
            // **只有派生字段可以换**：身份（objectID/sourceWishID/assetID/displayName）与
            // 用户自己的字段（sizeLocked/sizeIntent/collision/authoritativeSize）逐位不许变。
            // 少了这道守卫，`.rebase` 就成了一条"不搬位置但能改任何东西"的后门。
            guard WorldPropArchiveRebase.isDerivedOnlyRewrite(from: existing, to: prop) else {
                throw WorldPropLayoutError.invalidObject
            }
            guard prop.isValid else { throw WorldPropLayoutError.invalidObject }
            // 渲染色调跟着"这件东西多大"的**唯一**出口走（与上面的 `.resize` 同一处换算）；
            // 位置与朝向一个字节都不动 —— 修的是"档案对这份资产的描述"，不是它的落点。
            let rebasedScale = prop.effectiveSize.y / prop.sourceHeight
            guard rebasedScale.isFinite, rebasedScale > 0 else {
                throw WorldPropLayoutError.invalidSize("对齐后的尺寸换算失败，已保留原记录。")
            }
            item.metadata["gmgn.generated-prop.v1"] = String(decoding: try JSONEncoder().encode(prop), as: UTF8.self)
            item.transform = .init(position: item.transform.position, rotation: item.transform.rotation,
                                   scale: .init(x: rebasedScale, y: rebasedScale, z: rebasedScale))
            next.objectStates[objectID] = item
            // 撤销记录里存着的是**这件物件的旧字节**（`.undo` 的守卫要求它与现状逐位相同），
            // 一改就作废：那一槽只能作废，不能留着让"撤销上次"变成一次看不懂的失败。
            // 指**别的**物件的那一槽不受影响，原样保留 —— 自动修复不该吃掉用户的撤销。
            if next.layoutUndo?.objectID == objectID { next.layoutUndo = nil }
        case let .hold(id, avatarAssetID, calibration):
            objectID = id
            guard state.activeActivity == nil else {
                throw WorldPropLayoutError.activeActivityConflict(activityID: state.activeActivity!.activityID)
            }
            if let held = state.heldProp {
                throw WorldPropLayoutError.heldPropAlreadyExists(objectID: held.objectID)
            }
            guard !avatarAssetID.isEmpty, avatarAssetID.count <= 256,
                  calibration.isValid, calibration.avatarAssetID == avatarAssetID else {
                throw WorldPropLayoutError.invalidGripCalibration
            }
            guard var item = state.objectStates[id], item.generatedProp?.objectID == id else {
                throw WorldPropLayoutError.invalidObject
            }
            next.layoutUndo = nil
            item.metadata["gmgn.prop-grip.v1"] = String(decoding: try JSONEncoder().encode(calibration), as: UTF8.self)
            let returnState = item
            item.isEnabled = false
            next.objectStates[id] = item
            // 挂在哪个挂点是**标定自己说的话**（`calibration.hand`），不是这里再判一次
            // "必须是右手"：旧存档仍然是 `rightHand`，行为逐字节不变。
            next.heldProp = WorldHeldProp(
                objectID: id,
                avatarAssetID: avatarAssetID,
                hand: calibration.hand,
                returnState: returnState
            )
        case let .adjustGrip(id, avatarAssetID, calibration):
            objectID = id
            guard calibration.isValid else {
                throw WorldPropLayoutError.invalidGripCalibration
            }
            guard var held = state.heldProp,
                  held.objectID == id, held.avatarAssetID == avatarAssetID else {
                throw WorldPropLayoutError.heldPropMismatch
            }
            guard calibration.avatarAssetID == avatarAssetID else {
                throw WorldPropLayoutError.invalidGripCalibration
            }
            guard var item = state.objectStates[id], item.generatedProp?.objectID == id else {
                throw WorldPropLayoutError.invalidObject
            }
            next.layoutUndo = nil
            let json = String(decoding: try JSONEncoder().encode(calibration), as: UTF8.self)
            item.metadata["gmgn.prop-grip.v1"] = json
            held.returnState.metadata["gmgn.prop-grip.v1"] = json
            // 挂点跟着标定走：`.adjustGrip` 就是"把这件东西挪到另一个挂点/微调它的姿势"
            // 那条既有命令。`returnState` 一个字不改 —— 放回哪儿仍然是拿起前那一处。
            held.hand = calibration.hand
            next.objectStates[id] = item
            next.heldProp = held
        case let .returnHeld(id, avatarAssetID):
            objectID = id
            guard let held = state.heldProp,
                  held.objectID == id, held.avatarAssetID == avatarAssetID else {
                throw WorldPropLayoutError.heldPropMismatch
            }
            guard let item = state.objectStates[id], item.generatedProp?.objectID == id,
                  held.returnState.generatedProp == item.generatedProp else {
                throw WorldPropLayoutError.invalidObject
            }
            next.layoutUndo = nil
            next.objectStates[id] = held.returnState
            next.heldProp = nil
        case let .enableCapability(id, templateID):
            objectID = id
            guard var item = state.objectStates[id], item.generatedProp?.objectID == id else {
                throw WorldPropLayoutError.invalidObject
            }
            guard state.heldProp?.objectID != id else {
                throw WorldPropLayoutError.objectIsHeld(objectID: id)
            }
            guard WorldPropActivityTemplate.supported[templateID] != nil else {
                throw WorldPropLayoutError.unsupportedCapability(templateID: templateID)
            }
            if let existing = item.propCapability {
                guard existing.templateID == templateID, existing.objectID == id else {
                    throw WorldPropLayoutError.unsupportedCapability(templateID: templateID)
                }
                state.layoutReceipts[requestID] = command
                return
            }
            let capability = WorldPropCapability(objectID: id, templateID: templateID)
            guard capability.isValid,
                  let json = try? String(data: JSONEncoder().encode(capability), encoding: .utf8) else {
                throw WorldPropLayoutError.unsupportedCapability(templateID: templateID)
            }
            next.layoutUndo = nil
            item.metadata["gmgn.prop-capability.v1"] = json
            next.objectStates[id] = item
        case let .delete(id, reason):
            objectID = id
            // 「找不到」必须是**具名失败**：静默成功会让 agent 对用户说"删掉了"，
            // 而东西还在。已经在墓碑里的那一件说得更具体（它确实删过了）。
            guard let item = state.objectStates[id], let prop = item.generatedProp,
                  prop.objectID == id else {
                if state.propTombstones?[id] != nil {
                    throw WorldPropLayoutError.objectAlreadyDeleted(objectID: id)
                }
                throw WorldPropLayoutError.objectNotFound(objectID: id)
            }
            let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            let recordedReason = (trimmedReason?.isEmpty ?? true) ? nil : trimmedReason
            guard (recordedReason?.count ?? 0) <= 200 else {
                throw WorldPropLayoutError.deletionReasonTooLong
            }
            // ---- 收场：同一次提交里做完（见 `WorldPropDeletionSettlement`）----
            // 手持/挂载**必须先放回**：直接抹掉记录会留下一条指向不存在物件的 `heldProp`，
            // 渲染与回执都会去读一件没有的东西。放回的位置不需要新信息 ——
            // `heldProp.returnState` 就是"拿起前那一处"（那个字段存在的全部理由）。
            let settlement: WorldPropDeletionSettlement
            if let held = state.heldProp, held.objectID == id {
                settlement = .returnedFromSlot(slot: held.hand,
                                               position: held.returnState.transform.position)
                next.heldProp = nil
            } else if item.isEnabled {
                settlement = .withdrawn(surfaceID: item.supportSurfaceID ?? "",
                                        position: item.transform.position)
            } else {
                settlement = .inventory
            }
            let tombstone = WorldPropTombstone(
                objectID: id, displayName: prop.displayName,
                releasedBlobRefs: WorldPropAssetReferences.blobRefs(of: prop),
                settlement: settlement, reason: recordedReason,
                deletedAt: state.worldTime, previous: prop)
            guard tombstone.isValid else { throw WorldPropLayoutError.invalidObject }
            // **记录层**：这一条离开文档（权威据此把它置墓碑并派生 `object.removed`），
            // 但它不是硬删 —— 身份与释放的引用都留在墓碑里。
            next.objectStates.removeValue(forKey: id)
            var tombstones = next.propTombstones ?? [:]
            tombstones[id] = tombstone
            next.propTombstones = tombstones
            deletionTombstone = tombstone
            // 指向这一件的撤销记录作废（与 `.rebase` 同族）：留着它，"撤销上次"会去复原
            // 一件已经不存在的物件 —— 那是一次看不懂的失败，而不是用户的意图。
            if next.layoutUndo?.objectID == id { next.layoutUndo = nil }
        case .undo:
            if let held = state.heldProp {
                throw WorldPropLayoutError.objectIsHeld(objectID: held.objectID)
            }
            guard let undo = state.layoutUndo else { throw WorldPropLayoutError.nothingToUndo }
            guard undo.previousHeldProp == nil else { throw WorldPropLayoutError.heldPropMismatch }
            objectID = undo.objectID
            guard state.objectStates[objectID]?.generatedProp == undo.previous.generatedProp, undo.previous.generatedProp != nil else { throw WorldPropLayoutError.invalidObject }
            next.objectStates[objectID] = undo.previous
            next.layoutUndo = nil
        }
        next.layoutRevision += 1
        next.layoutReceipts[requestID] = command
        try invalidateRunningUsage(after: &next)
        state = next
        // 删除记**它自己的事实**（与权威的 `object.removed` 同族），不是笼统的"布局变了"：
        // 一次提交恰好一条事件，`sequence`（= revision 水位）的节奏一个字不改。
        if let tombstone = deletionTombstone {
            _ = record(.propDeleted(objectID: objectID, displayName: tombstone.displayName,
                                    layoutRevision: next.layoutRevision,
                                    settled: tombstone.settlement.name,
                                    releasedBlobRefs: tombstone.releasedBlobRefs))
        } else {
            _ = record(.propLayoutChanged(objectID: objectID, layoutRevision: next.layoutRevision))
        }
    }

    /// A moved, withdrawn or re-held prop can no longer be operated in place.
    /// Its running usage ends here as `stopped` — never as a fabricated
    /// completion — so readback never reports a use that physically cannot
    /// continue. Enabling a capability alone does not touch placement.
    private mutating func invalidateRunningUsage(after next: inout WorldState) throws {
        for (id, item) in next.objectStates {
            guard var usage = item.propUsage, usage.status == .running,
                  let previous = state.objectStates[id],
                  previous.isEnabled != item.isEnabled || previous.transform != item.transform
            else { continue }
            usage = WorldPropUsageState(templateID: usage.templateID, status: .stopped,
                activityRequestID: usage.activityRequestID, updatedAt: next.worldTime,
                reason: "物件被移动或收回，使用中止")
            next.objectStates[id]?.metadata[WorldPropUsageState.metadataKey] =
                String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
        }
    }

    @discardableResult
    public mutating func advance(
        by duration: TimeInterval,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        guard duration.isFinite, duration >= 0 else {
            throw WorldSimulationError.invalidDuration(duration)
        }

        state.worldTime = state.worldTime.addingTimeInterval(duration)
        if state.activeActivity?.status == .running {
            state.activeActivity?.elapsedActiveTime += duration
        }
        return record(.timeAdvanced(duration: duration))
    }

    @discardableResult
    public mutating func catchUp(
        to wallTime: Date,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        let duration = wallTime.timeIntervalSince(state.lastObservedWallTime)
        guard duration.isFinite, duration >= 0 else {
            throw WorldSimulationError.invalidDuration(duration)
        }

        state.worldTime = state.worldTime.addingTimeInterval(duration)
        state.lastObservedWallTime = wallTime
        if state.activeActivity?.status == .running {
            state.activeActivity?.elapsedActiveTime += duration
        }
        return record(.timeCaughtUp(duration: duration))
    }

    @discardableResult
    public mutating func updateAgentTransform(
        _ transform: WorldTransform,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        state.agentTransform = transform
        return record(.agentTransformUpdated(transform: transform))
    }

    @discardableResult
    public mutating func setWeather(
        _ weather: WorldWeather,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        state.weather = weather
        return record(.weatherChanged(weather: weather))
    }

    @discardableResult
    public mutating func setLiveCamera(
        _ camera: WorldCameraState,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        state.liveCamera = camera
        return record(.liveCameraChanged(camera: camera))
    }

    @discardableResult
    public mutating func startActivity(
        _ activityID: String,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        if let activeActivity = state.activeActivity {
            throw WorldSimulationError.activityAlreadyActive(
                activityID: activeActivity.activityID
            )
        }
        if let heldProp = state.heldProp {
            throw WorldSimulationError.propIsHeld(objectID: heldProp.objectID)
        }

        state.activeActivity = WorldActivityState(
            activityID: activityID,
            status: .running,
            startedAt: state.worldTime
        )
        return record(.activityStarted(activityID: activityID))
    }

    @discardableResult
    public mutating func interruptActivity(
        reason: String,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        guard var activity = state.activeActivity else {
            throw WorldSimulationError.noActiveActivity
        }
        guard activity.status == .running else {
            throw WorldSimulationError.activityIsNotInterrupted(
                activityID: activity.activityID
            )
        }

        activity.status = .interrupted
        activity.interruptionReason = reason
        state.activeActivity = activity
        return record(
            .activityInterrupted(
                activityID: activity.activityID,
                reason: reason
            )
        )
    }

    @discardableResult
    public mutating func resumeActivity(
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        guard var activity = state.activeActivity else {
            throw WorldSimulationError.noActiveActivity
        }
        guard activity.status == .interrupted else {
            throw WorldSimulationError.activityIsNotInterrupted(
                activityID: activity.activityID
            )
        }

        activity.status = .running
        activity.interruptionReason = nil
        state.activeActivity = activity
        return record(.activityResumed(activityID: activity.activityID))
    }

    @discardableResult
    public mutating func completeActivity(
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        guard let activity = state.activeActivity else {
            throw WorldSimulationError.noActiveActivity
        }

        state.activeActivity = nil
        return record(.activityCompleted(activityID: activity.activityID))
    }

    @discardableResult
    public mutating func cancelActivity(
        reason: String? = nil,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        guard let activity = state.activeActivity else {
            throw WorldSimulationError.noActiveActivity
        }

        state.activeActivity = nil
        return record(.activityCancelled(
            activityID: activity.activityID,
            reason: reason
        ))
    }

    @discardableResult
    public mutating func completeGoal(
        _ goalID: String,
        summary: String? = nil,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        guard state.completedGoals[goalID] == nil else {
            throw WorldSimulationError.goalAlreadyCompleted(goalID: goalID)
        }

        state.completedGoals[goalID] = WorldGoalState(
            goalID: goalID,
            completedAt: state.worldTime,
            summary: summary
        )
        return record(.goalCompleted(goalID: goalID))
    }

    @discardableResult
    public mutating func failActivity(reason: String, expectedRevision: UInt64) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        guard let activity = state.activeActivity else { throw WorldSimulationError.noActiveActivity }
        state.activeActivity = nil
        return record(.activityFailed(activityID: activity.activityID, reason: reason))
    }

    @discardableResult
    public mutating func recordMovementOutcome(requestID: String, destinationID: String,
                                               failure: String? = nil, expectedRevision: UInt64) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        if let failure {
            return record(.movementFailed(requestID: requestID, destinationID: destinationID, reason: failure))
        }
        return record(.movementCompleted(requestID: requestID, destinationID: destinationID))
    }

    /// Annotates the prop object with its persisted usage state. The write is
    /// valid only while the capability binding still matches, so a withdrawn or
    /// rebound object can never be completed by a stale in-flight activity.
    /// Revision-neutral on purpose: the driving activity/layout events already
    /// exist, this only annotates the object for later readback.
    public mutating func recordPropUsage(objectID: String, usage: WorldPropUsageState,
                                         expectedRevision: UInt64) throws {
        try validateRevision(expectedRevision)
        guard var item = state.objectStates[objectID],
              item.generatedProp?.objectID == objectID,
              let capability = item.propCapability,
              capability.objectID == objectID, capability.templateID == usage.templateID,
              usage.isValid
        else { throw WorldPropLayoutError.invalidObject }
        item.metadata[WorldPropUsageState.metadataKey] =
            String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
        state.objectStates[objectID] = item
    }

    private func validateRevision(_ submitted: UInt64) throws {
        guard submitted == state.revision else {
            throw WorldSimulationError.staleRevision(
                submitted: submitted,
                current: state.revision
            )
        }
    }

    /// Whether a recorded event is disposable clock bookkeeping.
    ///
    /// The resident advances the world on a 30 Hz tick and `advance`/`catchUp`
    /// previously appended one `.timeAdvanced`/`.timeCaughtUp` event per tick — the
    /// unbounded log growth this retention policy removes. No observer consumes
    /// those kinds: `WorldAgentContext.publishObservations` filters them before
    /// delivery and `ResidentWorldObservation.event` maps them to `nil`. The events
    /// are still returned from the mutating API and the revision still advances;
    /// they are simply not retained.
    ///
    /// `.observationGap` is classified here only to keep the switch exhaustive and
    /// to make the invariant explicit: the simulation never records it (it is a host
    /// delivery notice built by `publishObservations`), and if it were ever routed
    /// through `record` it must not enter the world log.
    ///
    /// Everything else — formal activity/movement/layout results, weather, goals,
    /// and the pose/camera mutations that existing consumers read through
    /// `events` — stays retained. Keep this set in sync with what consumers of the
    /// log need; do not widen it to the clock stream again.
    private static func isDisposableClockEvent(_ kind: WorldEventKind) -> Bool {
        switch kind {
        case .timeAdvanced, .timeCaughtUp, .observationGap:
            return true
        case .worldLoaded, .worldRestored, .agentTransformUpdated, .weatherChanged,
             .liveCameraChanged, .activityStarted, .activityInterrupted,
             .activityResumed, .activityCompleted, .activityCancelled, .activityFailed,
             .movementCompleted, .movementFailed, .goalCompleted, .propLayoutChanged,
             .propDeleted:
            return false
        }
    }

    private mutating func record(_ kind: WorldEventKind) -> WorldEvent {
        state.revision += 1
        // The event sequence is the world's mutation watermark (== revision), not an
        // array-derived index: it is strictly monotonic for the whole lifetime of a
        // world state and can never restart at zero, even across restores or after
        // the fixed-capacity eviction below.
        let event = WorldEvent(
            sequence: state.revision,
            revision: state.revision,
            worldTime: state.worldTime,
            kind: kind
        )
        if !Self.isDisposableClockEvent(kind) {
            appendRetained(event)
        }
        return event
    }

    /// Appends one retained event under the fixed-capacity contract. When the
    /// window is full the oldest **non-marker** event is dropped from the front, so
    /// the session-boundary marker stays addressable at `events[0]` and memory stays
    /// bounded even while a resident moves continuously. Dropped events are still
    /// reported through `trimmedNewestSequence` so sequence-cursor consumers can
    /// tell an honest gap from a complete history; the real action receipts returned
    /// by the mutating API are unaffected by eviction.
    private mutating func appendRetained(_ event: WorldEvent) {
        events.append(event)
        while events.count > Self.retainedEventCapacity, events.count > 1 {
            let evicted = events.remove(at: 1)
            trimmedNewestSequence = evicted.sequence
        }
    }
}
