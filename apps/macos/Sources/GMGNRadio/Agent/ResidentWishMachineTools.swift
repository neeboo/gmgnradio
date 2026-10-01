import Foundation
import CoreFoundation

/// One resident lease sees primitive capabilities; it never selects files, worlds or spending grants.
@MainActor final class ResidentWishMachineTools {
    private let coordinator: WishMachineCoordinator
    private let worldID: String
    private let residentScope: String
    private let authorizationID: UUID?
    private let isCurrent: @MainActor () -> Bool
    /// "本轮是否载有人类明确指令"。任务级 `autoContinuationPaused` 只停**自主**
    /// 续办（自行前往领取、自行摆放、后台新建生成）：它绝不吊销人类当轮明确
    /// 下令的领取。这里按**每次调用**求值，而不是在建租约时拍快照——后台 run
    /// 被人类引导接手后，这一轮就已经是奉命轮。
    private let humanOrderedClaim: @MainActor () -> Bool
    private let continuationResumeAuthorizationID: UUID?
    private let resumePlacementStatus: @MainActor (WishMachineJob) -> Bool?

    init(coordinator: WishMachineCoordinator, worldID: String, residentScope: String,
         authorizationID: UUID?, isCurrent: @escaping @MainActor () -> Bool,
         humanOrderedClaim: @escaping @MainActor () -> Bool = { false },
         continuationResumeAuthorizationID: UUID? = nil,
         resumePlacementStatus: @escaping @MainActor (WishMachineJob) -> Bool? = { _ in nil }) {
        self.coordinator = coordinator; self.worldID = worldID; self.residentScope = residentScope
        self.authorizationID = authorizationID; self.isCurrent = isCurrent
        self.humanOrderedClaim = humanOrderedClaim
        self.continuationResumeAuthorizationID = continuationResumeAuthorizationID
        self.resumePlacementStatus = resumePlacementStatus
    }

    var tools: [ResidentWorldToolSession.AdditionalTool] {
        let names = ["submit_wish_generation", "read_wish_generation", "retry_wish_generation", "cancel_wish_generation", "claim_wish_output", "resume_wish_continuation"]
        return names.map { name in
            var properties: [String: Any] = name == "submit_wish_generation" ? [
                "attachment_id": ["type": "string", "description": "本轮参考图编号：用户附件或用 register_wish_reference_image 登记的网页参考图；可用 read_wish_generation 空参数查询"],
                "name": ["type": "string", "description": "物件名称"],
                "size_intent": [
                    "type": ["object", "null"],
                    "description": "这次生成要按**哪根轴**做成**多少米**。用户说了尺寸就必须照他说的填；用户没提尺寸就**先问一句**，不要自己猜、也不要默认按高度。例：\"一把 1.1 米的剑\" ⇒ {axis:\"longest\", meters:1.1}；\"高 35 厘米的咖啡机\" ⇒ {axis:\"height\", meters:0.35}。",
                    "properties": [
                        "axis": ["type": "string", "enum": ["longest", "height"],
                                 "description": "longest = 最长边（剑、扫帚、滑雪板这类横着放的东西）；height = 高度（咖啡机、椅子这类立着的东西）"],
                        "meters": ["type": "number", "description": "米，0.01—3；必须是用户说的数字（或服务建议），不得自己编"],
                        "source": ["type": "string", "enum": ["user", "suggested"],
                                   "description": "user = 用户原话里的尺寸（缺省）；suggested = 生成服务的建议尺寸"]],
                    "required": ["axis", "meters"], "additionalProperties": false],
                "height_meters": ["type": "number", "description": "（旧字段，仅为兼容保留）期望高度 0.01—3 米，等价于 size_intent.axis=height；它与 size_intent 只能给一个。新调用请用 size_intent，它才说得清\"按最长边还是按高度\""],
                "destination": ["type": ["object", "null"], "description": "仅当用户明确要求把成品摆到指定支撑面时提供；surface_ids 取自 list_placement_surfaces，position 为用户明确指定的绝对位置与朝向（可选）",
                    "properties": ["surface_ids": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 8],
                        "position": ["type": ["object", "null"], "properties": ["surface_id": ["type": "string"], "x": ["type": "number"], "y": ["type": "number"], "z": ["type": "number"], "yaw": ["type": "number"]],
                            "required": ["surface_id", "x", "y", "z", "yaw"], "additionalProperties": false]],
                    "required": ["surface_ids"], "additionalProperties": false]
            ] : ["wish_id": ["type": "string", "description": "许愿任务编号"]]
            if name == "resume_wish_continuation" {
                properties["confirm_resume"] = ["type": "boolean", "enum": [true], "description": "仅本轮用户明确要求恢复此原许愿任务的自动领取及原目的地摆放时设为 true；普通聊天、查询和后台事件不得确认。"]
            }
            let descriptions = [
                "submit_wish_generation": "仅在用户本轮明确要求制作物件时，用登记图片提交一次异步生成。**提交前必须说清尺寸意图**：用户说了尺寸就照他说的填 size_intent（\"一把 1.1 米的剑\"⇒axis=longest,meters=1.1；\"高 35 厘米的咖啡机\"⇒axis=height,meters=0.35）；用户没提尺寸就**先问一句**要多长／多高，不要自己猜、也不要默认按高度（猜出来的尺寸会让物件在房间里太大或太小）。用户没给参考图时，先用 search_wish_reference_images 找图并用 register_wish_reference_image 登记，再提交；不要要求用户自己找图。用户只要求看图或描述图片时不得调用。本地持久受理即返回 wish_id；宿主后台提交，重要状态和终态按同一 wish_id 异步通知，无需反复查询。受理不代表远端接单或生成完成；不移动居民。",
                "read_wish_generation": "省略 wish_id 可查看当前居民任务和本轮登记的参考图（含来源与许可未核验标记）；提供 wish_id 可查询任务并下载完成产物。生成完成、可展示与实际领取分别记录。",
                "retry_wish_generation": "确认结果未明的原提交，复用原图片和幂等编号，不创建新任务、不额外消费生成授权。仅显式调用，不自动重试。",
                "cancel_wish_generation": "请求取消当前居民的生成任务。取消请求或中断不保证远端计算已经停止。",
                "claim_wish_output": "居民真实到达许愿机领取活动位置、托盘实际显示产物后登记领取。重复领取返回同一物件编号，不代表已手持或摆放。",
                "resume_wish_continuation": "仅本轮用户明确要求恢复指定旧许愿委托时调用。恢复该任务的自动领取和原目的地摆放权限，不重新生成、不改变目的地、不重复摆放已有物件。成功后还需按用户指令通过 update_resident_intent 的 resume_paused_intent 恢复居民意图；本工具不修改居民意图。"
            ]
            // `submit_wish_generation` 的尺寸是**二选一**（`size_intent` 或旧的 `height_meters`），
            // 所以这里不能把它们都列成必需 —— 一个都不给会被 `sizeIntentProblem` 明确拒绝
            // （"还差一个尺寸：先问用户"），而不是让 app 替用户猜一个。
            let required: [String] = switch name {
            case "read_wish_generation": []
            case "submit_wish_generation": ["attachment_id", "name"]
            default: properties.keys.filter { $0 != "destination" }.sorted()
            }
            return .init(name: name, description: descriptions[name]!, inputSchema: [
                "type": "object", "properties": properties, "required": required, "additionalProperties": false
            ], validate: { Self.validate($0, name: name) },
               handle: { [self] callID, arguments in await handle(name: name, callID: callID, data: arguments) })
        }
    }

    private static func validate(_ arguments: [String: Any], name: String) -> Bool {
        if name == "read_wish_generation" && arguments.isEmpty { return true }
        if name == "resume_wish_continuation" {
            guard Set(arguments.keys) == ["wish_id", "confirm_resume"],
                  (arguments["wish_id"] as? String).flatMap(UUID.init(uuidString:)) != nil,
                  let confirmed = arguments["confirm_resume"] as? NSNumber,
                  CFGetTypeID(confirmed) == CFBooleanGetTypeID() else { return false }
            return confirmed.boolValue
        }
        if name != "submit_wish_generation" { return Set(arguments.keys) == ["wish_id"] && (arguments["wish_id"] as? String).flatMap(UUID.init(uuidString:)) != nil }
        guard Set(arguments.keys).isSubset(of: ["attachment_id", "name", "size_intent", "height_meters", "destination"]),
              let attachment = arguments["attachment_id"] as? String, UUID(uuidString: attachment) != nil,
              let name = arguments["name"] as? String, (1...100).contains(name.count),
              sizeIntentProblem(arguments) == nil else { return false }
        if let rawDestination = arguments["destination"], !(rawDestination is NSNull) {
            guard let destination = rawDestination as? [String: Any],
                  Set(destination.keys).isSubset(of: ["surface_ids", "position"]),
                  let surfaces = destination["surface_ids"] as? [String], !surfaces.isEmpty, surfaces.count <= 8,
                  surfaces.allSatisfy({ !$0.isEmpty && $0.count <= 256 }), Set(surfaces).count == surfaces.count else { return false }
            if let rawPosition = destination["position"], !(rawPosition is NSNull) {
                guard let position = rawPosition as? [String: Any], position.count == 5,
                      let surface = position["surface_id"] as? String, surfaces.contains(surface),
                      ["x", "y", "z", "yaw"].allSatisfy({ key in
                          guard let number = position[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
                          return number.doubleValue.isFinite
                      }) else { return false }
            }
        }
        return true
    }

    /// 尺寸意图的**唯一**判据：`nil` = 通过，否则是一句**给用户看的原因**。
    ///
    /// 为什么把它单独抽出来：`validate` 只能用 Bool 回答"行不行"，而"为什么不行"必须
    /// 说给用户听（"用户没说尺寸 ⇒ 先问一句"和"0.01—3 米之外"是完全不同的两件事）。
    /// 两条路共用这一个函数，于是不可能出现"校验放行、拒绝理由说另一套"。
    ///
    /// 规则：
    /// - `size_intent` 与 `height_meters` **二选一**：一个都不给 ⇒ 让 agent 先去问用户
    ///   （不是替用户猜一个）；两个都给 ⇒ 两份真相，拒绝。
    /// - `size_intent.axis` 只能是 `longest`（最长边）或 `height`（高度）。
    /// - `meters` 必须有限且在 0.01—3 米（与守护进程 `SIZE_INTENT_*_METERS` 同一条范围）。
    /// - `source` 只接受 `user` / `suggested`；**不接受 `default`** —— 那一位的语义是
    ///   "这个数字是猜的"，而本工具存在的意义就是不许猜。
    static func sizeIntentProblem(_ arguments: [String: Any]) -> String? {
        let rawIntent = arguments["size_intent"].flatMap { $0 is NSNull ? nil : $0 }
        let rawHeight = arguments["height_meters"].flatMap { $0 is NSNull ? nil : $0 }
        switch (rawIntent, rawHeight) {
        case (nil, nil):
            return "还差一个尺寸：先问用户「要多长／多高」，再用 size_intent 填 axis（longest=最长边，height=高度）和 meters。不要自己猜一个尺寸，也不要默认按高度。"
        case (.some, .some):
            return "尺寸给了两遍：size_intent 与 height_meters 只能给一个（height_meters 是旧字段，等价于 axis=height）。"
        case (nil, .some(let raw)):
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0.01...3).contains(number.doubleValue) else {
                return "height_meters 必须是 0.01—3 米之间的数。"
            }
            return nil
        case (.some(let raw), nil):
            guard let value = raw as? [String: Any] else {
                return "size_intent 必须是一个对象：{axis, meters, source?}。"
            }
            guard Set(value.keys).isSubset(of: ["axis", "meters", "source"]) else {
                return "size_intent 只认 axis / meters / source 三个键。"
            }
            guard let axisText = value["axis"] as? String else {
                return "size_intent 缺 axis：longest=最长边（\"一把 1.1 米的剑\"），height=高度（\"高 35 厘米的咖啡机\"）。"
            }
            guard ["longest", "height"].contains(axisText) else {
                return "size_intent.axis 只能是 longest 或 height（收到 \(axisText)）。"
            }
            guard let number = value["meters"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else {
                return "size_intent.meters 必须是米数。"
            }
            guard (0.01...3).contains(number.doubleValue) else {
                return "size_intent.meters 超出范围：允许 0.01—3 米（收到 \(number.doubleValue)）。"
            }
            if let source = value["source"] {
                guard let text = source as? String, ["user", "suggested"].contains(text) else {
                    return "size_intent.source 只能是 user（用户原话里的尺寸）或 suggested（生成服务的建议尺寸）。猜出来的尺寸（default）不接受：用户没说尺寸时先问他一句。"
                }
            }
            return nil
        }
    }

    /// `size_intent`（或空的旧字段）→ 提交契约类型。
    ///
    /// **旧字段 `height_meters` 不给意图**（返回 nil）：老路径的尺寸推断与线上字节因此
    /// 逐位不变 —— "没有意图"是兼容性的定义，不是"补一个 axis=height 的意图"。
    static func parseSizeIntent(_ arguments: [String: Any]) -> PropSizeIntent? {
        if let legacy = arguments["height_meters"], !(legacy is NSNull) { return nil }
        guard let value = arguments["size_intent"] as? [String: Any],
              let axis = (value["axis"] as? String).flatMap(PropSizeIntent.Axis.init(rawValue:)),
              let meters = (value["meters"] as? NSNumber)?.doubleValue else { return nil }
        let source = (value["source"] as? String).flatMap(PropSizeIntent.Source.init(rawValue:)) ?? .user
        guard source != .fallback else { return nil }
        return PropSizeIntent(axis: axis, meters: meters, source: source)
    }

    private func handle(name: String, callID: String, data: Data) async -> RealtimeDJToolResult {
        guard !Task.isCancelled, isCurrent() else { return failure(callID, code: "stale_wish_session", message: "本轮空间操作已停止。") }
        guard let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return failure(callID, code: "invalid_arguments", message: "许愿工具参数不符合当前契约。")
        }
        // 尺寸有毛病时给**可读原因**（"还差一个尺寸：先问用户"和"超出 0.01—3 米"是两件事），
        // 而不是笼统的"参数不符合契约"——更不是静默按"没有意图"提交。
        if name == "submit_wish_generation", let problem = Self.sizeIntentProblem(arguments) {
            return failure(callID, code: "invalid_size_intent", message: problem)
        }
        guard Self.validate(arguments, name: name) else {
            return failure(callID, code: "invalid_arguments", message: "许愿工具参数不符合当前契约。")
        }
        if name == "read_wish_generation" && arguments.isEmpty { return discovery(callID: callID) }
        do {
            let job: WishMachineJob
            switch name {
            case "submit_wish_generation":
                guard let authorizationID else { throw WishMachineError.unauthorized }
                let destination = (arguments["destination"] as? [String: Any]).map { value -> WishPlacementDestination in
                    let surfaces = value["surface_ids"] as! [String]
                    let explicit: WishPlacementTarget?
                    if let position = value["position"] as? [String: Any] {
                        func number(_ key: String) -> Double { (position[key] as! NSNumber).doubleValue }
                        explicit = .init(surfaceID: position["surface_id"] as! String,
                            position: .init(x: number("x"), y: number("y"), z: number("z")), yaw: number("yaw"))
                    } else { explicit = nil }
                    return .init(surfaceIDs: surfaces, explicitTarget: explicit)
                }
                // 尺寸意图随提交一起下去；旧字段 `height_meters` 只提供"生成请求的那个数字"，
                // 不产生意图（老路径的推断与线上字节都不变）。
                let sizeIntent = Self.parseSizeIntent(arguments)
                let legacyHeight = (arguments["height_meters"] as? NSNumber).map(\.doubleValue)
                // 判据（`sizeIntentProblem`）与解析（`parseSizeIntent`）**必须一致**；万一将来分叉，
                // 这里明确拒绝并说清楚，绝不 force-unwrap 崩在工具里（用户会看成"点了没反应"）。
                guard let heightMeters = sizeIntent?.heightMetersForSubmission ?? legacyHeight, heightMeters > 0 else {
                    return failure(callID, code: "invalid_size_intent",
                        message: "这次提交没有可用的尺寸：请按用户说的尺寸重填 size_intent（axis + meters，0.01—3 米）。")
                }
                job = try await coordinator.submit(requestID: callID, authorizationID: authorizationID,
                    attachmentID: UUID(uuidString: arguments["attachment_id"] as! String)!, name: arguments["name"] as! String,
                    heightMeters: heightMeters, sizeIntent: sizeIntent, worldID: worldID, residentScope: residentScope,
                    destination: destination)
            case "read_wish_generation":
                job = try await coordinator.refresh(id: UUID(uuidString: arguments["wish_id"] as! String)!, worldID: worldID, residentScope: residentScope)
            case "cancel_wish_generation":
                job = try await coordinator.cancel(id: UUID(uuidString: arguments["wish_id"] as! String)!, worldID: worldID, residentScope: residentScope)
            case "retry_wish_generation":
                job = try await coordinator.retry(id: UUID(uuidString: arguments["wish_id"] as! String)!, worldID: worldID, residentScope: residentScope)
            case "resume_wish_continuation":
                guard let continuationResumeAuthorizationID else { throw WishMachineError.continuationResumeUnauthorized }
                let id = UUID(uuidString: arguments["wish_id"] as! String)!
                let existing = try coordinator.read(id: id, worldID: worldID, residentScope: residentScope)
                job = try coordinator.resumeContinuations(id: id, worldID: worldID, residentScope: residentScope,
                    authorizationID: continuationResumeAuthorizationID,
                    placementAlreadyCompleted: existing.stage == .claimed ? resumePlacementStatus(existing) : nil)
            default:
                job = try await claimWhenArrived(id: UUID(uuidString: arguments["wish_id"] as! String)!)
            }
            guard !Task.isCancelled, isCurrent() else {
                return failure(callID, code: "stale_wish_session", message: "会话已停止；已发起任务仍保留在原空间，可稍后查询。", wishID: job.id)
            }
            let message: String
            switch job.stage {
            case .submitting: message = "任务已在本地受理，正在后台提交。后续状态会按此任务编号异步通知，可继续对话，无需轮询。"
            case .ready: message = "产物已下载检查，等待托盘实际显示；到达许愿机后可领取。"
            case .claimed: message = "领取已登记，物件编号保持不变。用 read_owned_props 核对入库，再通过正式物件工具执行本轮用户授权的操作。"
            case .generated: message = "服务已生成，尚待下载检查。"
            case .submissionUncertain: message = "提交结果尚未确认，可用 retry_wish_generation 确认原提交；复用旧身份，不要发起新生成。"
            default: message = job.lastError ?? "任务状态已更新。"
            }
            var payload: [String: Any] = ["ok": true, "wish_id": job.id.uuidString, "object_id": job.objectID,
                "stage": job.stage.rawValue, "compute_may_continue": job.computeMayContinue,
                "auto_continuation_paused": job.autoContinuationPaused == true,
                "message": job.autoContinuationPaused == true ? message + " 自动续办已停止：不会自行前往领取或摆放；本轮人类明确下令仍可直接领取，无需先恢复续办。" : message]
            payload["accepted"] = job.daemonAccepted == true
            payload["notification"] = "async_task_events"
            payload["cancel_requested"] = job.cancelRequested == true
            // 回执里回读尺寸是怎么定的：agent（和它转述给用户的话）不必猜"我说的是哪根轴"。
            if name == "submit_wish_generation" {
                if let intent = job.sizeIntent {
                    payload["size_intent"] = ["axis": intent.axis.rawValue, "meters": intent.meters,
                                              "source": intent.source.rawValue, "summary": intent.summary]
                } else {
                    payload["size_intent"] = ["summary": "未声明尺寸意图：按生成请求高度自动推断"]
                }
            }
            if name == "resume_wish_continuation" {
                payload["continuation_resumed"] = job.autoContinuationPaused != true
                payload["resident_intent_updated"] = false
                payload["message"] = "原许愿任务的自动续办权限已恢复，未重新生成或执行领取、摆放。居民意图需另行通过 update_resident_intent 的 resume_paused_intent 恢复。"
                if let delegation = coordinator.placementDelegation(worldID: worldID, residentScope: residentScope, objectID: job.objectID) {
                    payload["placement_delegation_state"] = delegation.state.rawValue
                }
            }
            if let remote = job.remoteState { payload["generation_state"] = remote.rawValue }
            return .init(callID: callID, resultJSON: try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys), isError: false)
        } catch { return failure(callID, code: "wish_operation_failed", message: error.localizedDescription) }
    }
    private func discovery(callID: String) -> RealtimeDJToolResult {
        let jobs = coordinator.residentJobs(worldID: worldID, residentScope: residentScope)
        let choices = authorizationID.map { coordinator.attachmentChoices(authorizationID: $0, worldID: worldID, residentScope: residentScope) } ?? []
        let available = authorizationID.map { grant in !choices.isEmpty && !jobs.contains { $0.authorizationID == grant } } ?? false
        let payload: [String: Any] = ["ok": true, "generation_authorized": available,
            "attachments": choices.map { choice -> [String: Any] in
                let reference = coordinator.webReference(attachmentID: choice.id)
                return ["attachment_id": choice.id.uuidString, "display_name": choice.displayName,
                    "source_kind": reference == nil ? "user_upload" : "public_web_reference",
                    "source_image_url": reference?.imageURL.absoluteString ?? "",
                    "license_verified": false]
            },
            "jobs": jobs.suffix(50).map { job -> [String: Any] in ["wish_id": job.id.uuidString, "object_id": job.objectID,
                "name": job.name, "stage": job.stage.rawValue, "auto_continuation_paused": job.autoContinuationPaused == true] },
            "placement_delegations": coordinator.placementDelegations(worldID: worldID, residentScope: residentScope).map { delegation -> [String: Any] in
                ["authorization_id": delegation.authorizationID.uuidString, "request_id": delegation.requestID,
                 "object_id": delegation.objectID ?? "", "state": delegation.state.rawValue,
                 "allowed_surfaces": delegation.allowedSurfaceIDs, "last_error": delegation.lastError ?? ""]
            },
            "total_jobs": jobs.count]
        return .init(callID: callID, resultJSON: (try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)) ?? Data("{}".utf8), isError: false)
    }
    private func claimWhenArrived(id: UUID) async throws -> WishMachineJob {
        let existing = try coordinator.read(id: id, worldID: worldID, residentScope: residentScope)
        // 任务级暂停只拦"自主"领取：没有本轮人类明确指令时拒绝；有明确指令时
        // 直接按令领取，不要求先 resume_wish_continuation（那不是领取的前置条件，
        // 它只重新打开自动续办）。
        guard humanOrderedClaim() || existing.autoContinuationPaused != true else { throw WishMachineError.automaticContinuationPaused }
        if existing.stage == .claimed { return existing }
        guard existing.stage == .ready else { throw WishMachineError.notReady }
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while clock.now < deadline {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let current = try coordinator.read(id: id, worldID: worldID, residentScope: residentScope)
            guard humanOrderedClaim() || current.autoContinuationPaused != true else { throw WishMachineError.automaticContinuationPaused }
            guard let evidence = try coordinator.claimEvidence(id: id, worldID: worldID, residentScope: residentScope),
                  evidence.worldID == worldID, evidence.activityID == "wish_machine.collect" else { throw WishMachineError.notAtMachine }
            do { return try coordinator.claim(id: id, worldID: worldID, residentScope: residentScope) }
            catch WishMachineError.notAtMachine { /* The already-started collection activity may still be approaching. */ }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw WishMachineError.notAtMachine
    }
    private func failure(_ callID: String, code: String, message: String, wishID: UUID? = nil) -> RealtimeDJToolResult {
        var payload: [String: Any] = ["ok": false, "code": code, "message": message]
        if let wishID { payload["wish_id"] = wishID.uuidString }
        return .init(callID: callID, resultJSON: (try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)) ?? Data("{}".utf8), isError: true)
    }
}
