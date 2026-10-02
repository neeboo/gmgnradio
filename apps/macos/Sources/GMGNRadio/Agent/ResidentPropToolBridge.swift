import Foundation
import CoreFoundation
import os
import WorldRuntime

/// Narrow background mutation grant: the completion round may apply only this object on the
/// allowed surfaces at the exact absolute target, under the delegation's stable requestID.
struct ResidentPropDelegatedGrant: Equatable, Sendable {
    let objectID: String
    let allowedSurfaceIDs: Set<String>
    let target: WorldPropPlacement?
    let requestID: String
}

enum ResidentPropDelegationError: Error, Equatable {
    case inactiveDelegation, surfaceNotAllowed, targetMismatch, requestChanged
}
extension ResidentPropDelegationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .inactiveDelegation: "当前没有有效的摆放委托，或委托已停止；物件保留在库存。"
        case .surfaceNotAllowed: "该落点不在委托允许的支撑面内。"
        case .targetMismatch: "落点与委托授权的绝对位置或朝向不一致。"
        case .requestChanged: "摆放委托在等待期间发生变化，请重新读取后重试。"
        }
    }
}

/// Stable primitive tools. Assets are registered by the host's claim bridge only.
@MainActor final class ResidentPropToolBridge {
    private let service: ResidentPropPlacementService
    private let allowsMutation: Bool
    private let delegatedGrant: ResidentPropDelegatedGrant?
    private let isCurrent: () -> Bool
    private let onChange: () -> Void
    private let prepareMutation: (WorldPropLayoutCommand) async throws -> Void
    private let resolveDelegatedGrant: (String, WorldPropPlacement) throws -> ResidentPropDelegatedGrant?
    private let recordDelegatedPlacement: (ResidentPropDelegatedGrant, WorldPropPlacement) throws -> Void
    init(service: ResidentPropPlacementService, allowsMutation: Bool,
         isCurrent: @escaping () -> Bool, onChange: @escaping () -> Void = {},
         prepareMutation: @escaping (WorldPropLayoutCommand) async throws -> Void = { _ in },
         delegatedGrant: ResidentPropDelegatedGrant? = nil,
         resolveDelegatedGrant: @escaping (String, WorldPropPlacement) throws -> ResidentPropDelegatedGrant? = { _,_ in nil },
         recordDelegatedPlacement: @escaping (ResidentPropDelegatedGrant, WorldPropPlacement) throws -> Void = { _,_ in }) {
        self.service = service; self.allowsMutation = allowsMutation
        self.isCurrent = isCurrent; self.onChange = onChange
        self.prepareMutation = prepareMutation
        self.delegatedGrant = delegatedGrant
        self.resolveDelegatedGrant = resolveDelegatedGrant
        self.recordDelegatedPlacement = recordDelegatedPlacement
    }

    var tools: [ResidentWorldToolSession.AdditionalTool] {
        ["read_owned_props", "list_placement_surfaces", "preview_prop_placement", "apply_prop_placement", "withdraw_prop", "undo_prop_placement",
         "hold_prop", "adjust_held_prop_grip", "return_held_prop", "enable_prop_capability", "delete_prop"].map { name in
            var properties: [String: Any] = [:]
            if ["preview_prop_placement", "apply_prop_placement", "withdraw_prop", "hold_prop", "adjust_held_prop_grip", "return_held_prop", "enable_prop_capability", "delete_prop"].contains(name) {
                properties["object_id"] = ["type": "string", "description": "read_owned_props 返回的已拥有物件编号"]
            }
            if name == "delete_prop" {
                // `reason` 与 `slot` 同族：**唯一可省**的业务参数。省缺 = 没有给理由，
                // 删除照样成立（理由只进审计，不是许可）。
                properties["reason"] = ["type": "string",
                    "description": "（可省）删除的理由，最多 200 字。用户说了为什么就照实写；没说就不写，绝不替他编一个。"]
            }
            if name == "enable_prop_capability" {
                properties["capability"] = ["type": "string", "description": "受支持的使用能力模板，当前仅支持 coffee.brew"]
            }
            if name == "hold_prop" {
                // 挂点：三个字面量与 `WorldPropSlot.rawValue` 同一份（`PropAttachmentSlots.acceptedNames`）。
                // **可省**（省缺 = rightHand）：既有调用点与旧提示词一个字都不用改。
                properties["slot"] = ["type": "string", "enum": PropAttachmentSlots.acceptedNames,
                    "description": "挂点：rightHand 拿在手里 / back 挂在背后 / waist 挂在腰间。用户说「挂背后 / 挂腰上 / 拿手里」时选对应项；不写就是 rightHand。已经拿在手上的同一件物件换挂点时也用它。"]

            }
            if ["preview_prop_placement", "apply_prop_placement"].contains(name) {
                properties["surface_id"] = ["type": "string", "description": "list_placement_surfaces 返回的承托层编号（layer.<n>）。摆放是否成立由坐标决定。"]
                for key in ["x", "y", "z", "yaw"] { properties[key] = ["type": "number"] }
            }
            if name == "adjust_held_prop_grip" {
                for key in ["offset_x", "offset_y", "offset_z", "rotation_yaw"] { properties[key] = ["type": "number"] }
            }
            if Self.isMutation(name) { properties["layout_revision"] = ["type": "integer", "minimum": 0] }
            let descriptions = [
                "read_owned_props": "读取真实已拥有物件、是否摆出、位置、能力绑定、最近一次使用状态（running/completed/stopped/failed，以回执为准）与布局版本。每件物件的 `hold_slots` **逐挂点**给出「能不能挂在那个挂点上」以及那一个挂点自己的原因（手/背后/腰间各自具名，右手不行不代表背后不行）。`deleted` 列出已经被永久删除的物件（墓碑：名字、删除时的结算动作与理由、释放的内容引用）—— 已经删掉的东西不会出现在 objects 里。生成物件默认仅有外形；只有明确启用 coffee.brew 冲泡模板的咖啡机才可按模板在空间内模拟使用，不涉及现实硬件或物理结构。",
                "list_placement_surfaces": "读取可摆放的承托层：承托高度、格数与水平范围（不再逐个列出格子）。位置为底部中心，yaw 为弧度。",
                "preview_prop_placement": "只验证候选摆放，不改变世界、不显示预览。碰撞或通道错误可用于调整计划。",
                "apply_prop_placement": "按本轮人类摆放或移动委托提交已拥有物件的位置和朝向；后台仅可续办原生成任务仍有效的有限摆放委托，只能摆该产物到允许的支撑面。先查询布局版本和支撑面并预检，位置和朝向使用绝对值。",
                "withdraw_prop": "仅按本轮人类委托收回已拥有摆件，保留物件和来源，不删除或重新生成。",
                "undo_prop_placement": "仅按本轮人类要求撤销最近一次摆放或收回；只能撤销一步。",
                // 工具描述是 agent 真正读到的"能拿多大"：与判据**同源**（插值同一份上限），
                // 否则提示词说 1.6 m、工具描述说另一个数，agent 会照着错的那一份拒绝用户。
                "hold_prop": "仅按本轮人类明确要求，让当前已适配居民拿起 / 挂上一件最长边不超过\(ResidentPropAttachmentEligibility.holdableLongestEdgeText)的小道具展示；slot 决定挂点（rightHand 拿在手里 / back 挂在背后 / waist 挂在腰间），省缺为 rightHand。用户说「挂背后 / 挂腰上 / 拿手里」时就是选它。物件保持同一身份并保留原放回位置。read_owned_props 的回执里 `hold_slots` **逐挂点**给出可用性与各自的原因：右手不行**不代表**背后或腰间不行，别拿一个挂点的答案替用户回答另一个挂点；失败回执里的 slot/slot_name 是这次**真正**按哪个挂点算的（没给 slot 时就是省缺的右手）。",
                "adjust_held_prop_grip": "仅按本轮人类要求，微调**当前挂点**上那件道具相对该挂点骨骼的米制偏移和局部旋转。先读取当前握点，参数为绝对值；它不会改变挂点本身（换挂点用 hold_prop 的 slot）。",
                "return_held_prop": "仅按本轮人类要求把当前挂载的道具精确放回拿起前的位置；原来在库存则回库存，不接受放回坐标。",
                "enable_prop_capability": "仅按本轮人类明确要求使用某物件时，为已拥有摆件启用受支持的使用能力模板（当前仅支持 coffee.brew 冲泡模板）。能力持久化；启用后通过 start_activity 走到物件前面向它执行按钮动作并等待播放完成，属于空间内模拟使用，不宣称物理冲煮结构。按名字猜想的物件不得启用。",
                // 删除是**永久**的：描述里逐字写出来，agent 才不会把它当成又一次"收回"。
                "delete_prop": "仅按本轮人类明确要求，**永久删除**一件已拥有的生成资产（不可恢复，没有撤销）。先用 read_owned_props 确认是哪一件。删除会自动收场：正在房间里摆着的、正拿在居民手里的或挂在身上的，都会在同一次提交里先收回/放回再删掉，不需要先调用 withdraw_prop 或 return_held_prop。回执里会说明删了什么、做了哪种收场、以及释放了哪些共享内容（还被别的物件引用的内容一律保留，不会误删）。只有这一件物件独占的内容才会进入可回收集合。删除后该物件不再出现在库存与回执的 objects 里，而是出现在 deleted 里。"
            ]
            return .init(name: name, description: descriptions[name]!, inputSchema: [
                "type": "object", "properties": properties,
                // `slot` 是 hold_prop 上**唯一可省**的参数：不写就是右手。
                "required": properties.keys.filter { !(name == "hold_prop" && $0 == "slot") }.sorted(),
                "additionalProperties": false
            ], validate: { Self.validate($0, name: name) }, handle: { [self] id, data in await handle(name, id, data) })
        }
    }

    private static func isMutation(_ name: String) -> Bool {
        ["apply_prop_placement", "withdraw_prop", "undo_prop_placement", "hold_prop", "adjust_held_prop_grip", "return_held_prop", "enable_prop_capability", "delete_prop"].contains(name)
    }
    private static func validate(_ values: [String: Any], name: String) -> Bool {
        var keys = Set<String>()
        if ["preview_prop_placement", "apply_prop_placement", "withdraw_prop", "hold_prop", "adjust_held_prop_grip", "return_held_prop", "enable_prop_capability", "delete_prop"].contains(name) { keys.insert("object_id") }
        if name == "enable_prop_capability" { keys.insert("capability") }
        if name == "delete_prop" { keys.insert("reason") }
        if ["preview_prop_placement", "apply_prop_placement"].contains(name) { keys.formUnion(["surface_id", "x", "y", "z", "yaw"]) }
        if name == "adjust_held_prop_grip" { keys.formUnion(["offset_x", "offset_y", "offset_z", "rotation_yaw"]) }
        if isMutation(name) { keys.insert("layout_revision") }
        // 可省的业务参数只有两个：`hold_prop` 的 `slot`（省缺 = rightHand）与
        // `delete_prop` 的 `reason`（省缺 = 没给理由）。别的参数一个都不许省。
        var allowed = keys
        if name == "hold_prop" { allowed.insert("slot") }
        if name == "delete_prop" { allowed.remove("reason") }
        guard Set(values.keys) == keys || Set(values.keys) == allowed else { return false }
        for key in values.keys {
            if ["object_id", "surface_id", "capability", "slot", "reason"].contains(key) {
                guard let text = values[key] as? String, !text.isEmpty, text.count <= 256 else { return false }
                // 删除理由的**判据只有一处**（世界层 `WorldSimulation` 的 200 字上限）：
                // 这里只做"是个不空的字符串"，长度由那条命令自己拒绝并给出可读原因。
                if key == "reason", name == "delete_prop", text.trimmingCharacters(in: .whitespacesAndNewlines).count > 200 { return false }
                // 挂点名必须**认识**：认不出来的就地拒绝，绝不猜一个挂点出来。
                if key == "slot", PropAttachmentSlots.resolve(name: text) == nil { return false }
            } else {
                guard let number = values[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return false }
                if key == "layout_revision" {
                    guard number.doubleValue >= 0, number.doubleValue < Double(UInt64.max), number.doubleValue.rounded() == number.doubleValue else { return false }
                }
            }
        }
        return true
    }

    private func handle(_ name: String, _ callID: String, _ data: Data) async -> RealtimeDJToolResult {
        func result(_ payload: [String: Any], error: Bool = false) -> RealtimeDJToolResult {
            .init(callID: callID, resultJSON: (try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)) ?? Data("{}".utf8), isError: error)
        }
        guard !Task.isCancelled, isCurrent() else { return result(["ok": false, "code": "stale_prop_session", "message": "本轮空间操作已停止。"], error: true) }
        guard let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], Self.validate(values, name: name) else {
            return result(["ok": false, "code": "invalid_arguments", "message": "摆放参数无效，请查询当前物件和支撑面。"], error: true)
        }
        if name == "preview_prop_placement", !allowsMutation, let grant = delegatedGrant,
           values["object_id"] as? String != grant.objectID {
            return result(["ok": false, "code": "delegation_violation", "message": "后台委托只能查询和预检该委托指定的产物。"], error: true)
        }
        guard !Self.isMutation(name) || allowsMutation || name == "apply_prop_placement" || delegationAllows(name, values) else {
            return result(["ok": false, "code": delegatedGrant == nil ? "human_guidance_required" : "delegation_violation",
                "message": delegatedGrant == nil ? "后台可查询和预检；摆放、手持、握点调整、放回、撤销、启用使用能力或永久删除需要本轮人类委托。"
                    : "后台委托只允许把该产物按授权落点摆放到允许的支撑面；不能移动其他物件、收回、撤销、手持、启用使用能力或删除。"], error: true)
        }
        do {
            /// 这次调用真的删掉了一件东西时的回执（只在 `delete_prop` 成功那一支里被写）。
            var deletion: ResidentPropDeletionReceipt?
            if name == "list_placement_surfaces" {
                // 承托面现在是"层"：按承托高度归并，不再逐格列出（见 `listedSupportLayers`）。
                return result(["ok": true, "surfaces": service.listedSupportLayers().map {
                    ["id": $0.id, "support_height": $0.supportHeight, "cell_count": $0.cellCount,
                     "center": Self.vector($0.center), "half_extents": Self.vector($0.halfExtents), "yaw": Float.zero]
                }])
            }
            var preview: WorldObjectState?
            if ["preview_prop_placement", "apply_prop_placement"].contains(name) {
                func value(_ key: String) -> Float { (values[key] as! NSNumber).floatValue }
                let placement = WorldPropPlacement(surfaceID: values["surface_id"] as! String,
                    position: .init(x: value("x"), y: value("y"), z: value("z")), yaw: value("yaw"))
                if name == "preview_prop_placement" { preview = try service.preview(objectID: values["object_id"] as! String, placement: placement) }
                else {
                    let objectID = values["object_id"] as! String
                    let command = WorldPropLayoutCommand.place(objectID: objectID, placement: placement)
                    let resolved = try resolveGrantForApply(objectID: objectID, placement: placement)
                    try await prepareMutation(command)
                    guard !Task.isCancelled, isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
                    let confirmed = try recheckGrantAfterAwait(objectID: objectID, placement: placement, previous: resolved)
                    let requestID = (!allowsMutation && confirmed != nil) ? confirmed!.requestID : callID
                    try service.commit(command, expectedLayoutRevision: (values["layout_revision"] as! NSNumber).uint64Value, requestID: requestID)
                    if !allowsMutation, let confirmed { try recordDelegatedPlacement(confirmed, placement) }
                }
            } else if name == "withdraw_prop" {
                try service.commit(.withdraw(objectID: values["object_id"] as! String), expectedLayoutRevision: (values["layout_revision"] as! NSNumber).uint64Value, requestID: callID)
            } else if name == "undo_prop_placement" {
                try await prepareMutation(.undo)
                guard !Task.isCancelled, isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
                try service.commit(.undo, expectedLayoutRevision: (values["layout_revision"] as! NSNumber).uint64Value, requestID: callID)
            } else if name == "hold_prop" {
                // 挂点由 `slot` 说；不写就是右手（与面板、系统提示词同一份字面量）。
                let point = (values["slot"] as? String).flatMap(PropAttachmentSlots.resolve(name:)) ?? .rightHand
                let command = try service.holdCommand(objectID: values["object_id"] as! String, point: point)
                try await prepareMutation(command)
                guard !Task.isCancelled, isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
                try service.commit(command, expectedLayoutRevision: (values["layout_revision"] as! NSNumber).uint64Value, requestID: callID)
            } else if name == "adjust_held_prop_grip" {
                func value(_ key: String) -> Float { (values[key] as! NSNumber).floatValue }
                let yaw = value("rotation_yaw")
                let command = try service.adjustGripCommand(objectID: values["object_id"] as! String,
                    localOffset: .init(x: value("offset_x"), y: value("offset_y"), z: value("offset_z")),
                    localRotation: .init(x: 0, y: sin(yaw/2), z: 0, w: cos(yaw/2)))
                try service.commit(command, expectedLayoutRevision: (values["layout_revision"] as! NSNumber).uint64Value, requestID: callID)
            } else if name == "return_held_prop" {
                let command = try service.returnHeldCommand(objectID: values["object_id"] as! String)
                try await prepareMutation(command)
                guard !Task.isCancelled, isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
                try service.commit(command, expectedLayoutRevision: (values["layout_revision"] as! NSNumber).uint64Value, requestID: callID)
            } else if name == "enable_prop_capability" {
                let command = WorldPropLayoutCommand.enableCapability(
                    objectID: values["object_id"] as! String,
                    templateID: values["capability"] as! String)
                try await prepareMutation(command)
                guard !Task.isCancelled, isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
                try service.commit(command, expectedLayoutRevision: (values["layout_revision"] as! NSNumber).uint64Value, requestID: callID)
            } else if name == "delete_prop" {
                // 命令构造在服务里（归属 + 命名），收场与世界变更都在 `commit` 那**同一条**
                // 路径上：面板按同一个按钮走的是同一份代码，不存在第二套删除逻辑。
                let objectID = values["object_id"] as! String
                let command = try service.deleteCommand(objectID: objectID, reason: values["reason"] as? String)
                try await prepareMutation(command)
                guard !Task.isCancelled, isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
                try service.commit(command, expectedLayoutRevision: (values["layout_revision"] as! NSNumber).uint64Value, requestID: callID)
                if let receipt = service.deletionReceipt(objectID: objectID) { deletion = receipt }
            }
            if Self.isMutation(name) { onChange() }
            // **逐挂点**问可用性（与面板同一份推导：`holdEligibility(objectID:point:)`）。
            //
            // 以前这里对每件物件只问一次（省缺 = 右手），回执里的 `hold_eligible` /
            // `hold_unavailable_reason` 于是是**右手**的答案。agent 读到 `hold_eligible:false`
            // 就以为"这件东西挂不上"，用户说的"挂到背后"根本传不到 `hold_prop` 的 slot 上
            // —— 真机 2026-10-02 12:28:21.388 那两条 `挂点=右手` 的拒绝就是这么发出去的。
            // 现在三个挂点各问一次、各自具名；判据一个字没改。
            // 多语句闭包的返回类型**不参与**类型推断（Swift 的既有约束），所以这里显式写出来。
            let objects = service.context.state.objectStates.values.compactMap { item -> [String: Any]? in
                guard let objectID = item.generatedProp?.objectID else { return nil }
                return Self.object(item, heldObjectID: service.context.state.heldProp?.objectID,
                                   holdUnavailableBySlot: Self.holdUnavailableBySlot(service, objectID: objectID))
            }
            let interactionStatus = objects.contains { $0["capability"] != nil }
                ? "capability_bound_use_only" : "appearance_only"
            var payload: [String: Any] = ["ok": true, "layout_revision": service.context.state.layoutRevision,
                "objects": objects, "can_undo": service.context.state.layoutUndo != nil,
                "mutation_authorized": allowsMutation, "interaction_status": interactionStatus]
            // 墓碑是**只读入口的答案**："这件东西去哪了" —— 已经删掉的不会出现在 objects 里，
            // 但它必须查得到（否则用户与 agent 只会看到"少了一件"，与"意外丢了"分不开）。
            let tombstones = (service.context.state.propTombstones ?? [:]).values
                .sorted { $0.objectID < $1.objectID }
            if !tombstones.isEmpty {
                payload["deleted"] = tombstones.map { tombstone -> [String: Any] in
                    var entry: [String: Any] = [
                        "object_id": tombstone.objectID, "name": tombstone.displayName,
                        "settled": tombstone.settlement.name,
                        "settlement": tombstone.settlement.summary,
                        "released_blob_refs": tombstone.releasedBlobRefs,
                    ]
                    if let reason = tombstone.reason { entry["reason"] = reason }
                    return entry
                }
            }
            if let deletion { payload["deletion"] = deletion.payload }
            // 挂在哪个挂点**只回执世界状态里那一份**（不读调用参数）：回执说的就是"它现在挂在哪儿"。
            if let held = service.context.state.heldProp {
                let point = held.hand.attachmentPoint
                payload["held_slot"] = held.hand.rawValue
                payload["held_slot_name"] = PropAttachmentSlots.displayName(for: point)
                // 挂点那句话里带着**净空那个数**：agent 只有读到它，才能对用户说清"贴不贴身子"。
                if let prop = service.context.state.objectStates[held.objectID]?.generatedProp,
                   let notice = PropAttachmentSlots.notice(for: prop, point: point) {
                    payload["slot_notice"] = notice
                }
            }
            if let preview { payload["preview"] = Self.object(preview, heldObjectID: nil, holdUnavailableBySlot: [:]) }
            return result(payload)
        } catch {
            // **失败具名**：`delete_prop` 的两种"找不到"各给一个机器读的 code（agent 据此
            // 决定"换一件"还是"告诉用户它已经删了"），不是一律"摆放被拒"。
            let code: String
            switch error {
            case WorldPropLayoutError.objectNotFound: code = "object_not_found"
            case WorldPropLayoutError.objectAlreadyDeleted: code = "object_already_deleted"
            default: code = "placement_rejected"
            }
            var failure: [String: Any] = ["ok": false, "code": code, "message": error.localizedDescription,
                           "layout_revision": service.context.state.layoutRevision]
            // 失败回执**总是**带上挂点名 —— 包括调用方**没给** `slot` 的时候（那时省缺是右手）。
            // 只带一半（传了才带）会让"系统在按右手算"这件事在回执与日志里都看不见。
            if name == "hold_prop" {
                let declared = values["slot"] as? String
                let point = declared.flatMap(PropAttachmentSlots.resolve(name:)) ?? .rightHand
                failure["slot"] = point.worldSlot.rawValue
                failure["slot_name"] = PropAttachmentSlots.displayName(for: point)
                failure["slot_source"] = declared == nil ? "省缺（调用方没有给 slot）" : "参数 slot=\(declared!)"
            }
            // 回执是给 agent 看的；**日志是给排障的人看的**。这条工具调用失败时，
            // 统一日志里必须留下同一个名字与同一句话 —— 否则"用户说挂不上、日志里什么都没有"
            // 就会再次发生（真机 2026-10-02）。
            Self.log.notice("挂件工具失败 tool=\(name, privacy: .public) code=\(code, privacy: .public) 物件=\((values["object_id"] as? String) ?? "nil", privacy: .public) 挂点=\((failure["slot_name"] as? String) ?? "-", privacy: .public) 原因=\(error.localizedDescription, privacy: .public)")
            return result(failure, error: true)
        }
    }
    private static let log = Logger(subsystem: "ai.gmgn.radio", category: "LivingWorld")
    private func delegationAllows(_ name: String, _ values: [String: Any]) -> Bool {
        guard name == "apply_prop_placement", let grant = delegatedGrant,
              values["object_id"] as? String == grant.objectID,
              let surface = values["surface_id"] as? String, grant.allowedSurfaceIDs.contains(surface) else { return false }
        guard let target = grant.target else { return true }
        func value(_ key: String) -> Float { (values[key] as! NSNumber).floatValue }
        return value("x") == target.position.x && value("y") == target.position.y
            && value("z") == target.position.z && value("yaw") == target.yaw
    }
    private func resolveGrantForApply(objectID: String, placement: WorldPropPlacement) throws -> (ResidentPropDelegatedGrant?, Bool) {
        guard !allowsMutation else { return (nil, false) }
        if let dynamic = try resolveDelegatedGrant(objectID, placement) {
            try Self.validateGrant(dynamic, objectID: objectID, placement: placement)
            return (dynamic, true)
        }
        guard let staticGrant = delegatedGrant else { throw ResidentPropDelegationError.inactiveDelegation }
        try Self.validateGrant(staticGrant, objectID: objectID, placement: placement)
        return (staticGrant, false)
    }
    private func recheckGrantAfterAwait(objectID: String, placement: WorldPropPlacement,
                                        previous: (ResidentPropDelegatedGrant?, Bool)) throws -> ResidentPropDelegatedGrant? {
        guard !allowsMutation else { return nil }
        if let dynamic = try resolveDelegatedGrant(objectID, placement) {
            try Self.validateGrant(dynamic, objectID: objectID, placement: placement)
            if let prior = previous.0 { guard dynamic.requestID == prior.requestID else { throw ResidentPropDelegationError.requestChanged } }
            return dynamic
        }
        guard !previous.1 else { throw ResidentPropDelegationError.inactiveDelegation }
        guard let staticGrant = delegatedGrant else { throw ResidentPropDelegationError.inactiveDelegation }
        try Self.validateGrant(staticGrant, objectID: objectID, placement: placement)
        return staticGrant
    }
    private static func validateGrant(_ grant: ResidentPropDelegatedGrant, objectID: String, placement: WorldPropPlacement) throws {
        guard grant.objectID == objectID, grant.allowedSurfaceIDs.contains(placement.surfaceID) else { throw ResidentPropDelegationError.surfaceNotAllowed }
        if let target = grant.target {
            guard placement.surfaceID == target.surfaceID
                && placement.position.x == target.position.x && placement.position.y == target.position.y && placement.position.z == target.position.z
                && placement.yaw == target.yaw else { throw ResidentPropDelegationError.targetMismatch }
        }
    }
    private static func vector(_ p: WorldVector3) -> [Float] { [p.x, p.y, p.z] }

    /// 逐挂点问一次可用性：返回"**不可用**的挂点（`WorldPropSlot.rawValue`）→ 那个挂点自己的原因"。
    ///
    /// 可用的挂点不在表里（=`ok`）。与面板那一条读的是**同一个**判据出口
    /// （`ResidentPropPlacementService.holdEligibility(objectID:point:)`），所以两边不可能分叉。
    private static func holdUnavailableBySlot(_ service: ResidentPropPlacementService,
                                               objectID: String) -> [String: String] {
        var result: [String: String] = [:]
        for point in PropAttachmentPoint.allCases {
            if let reason = service.holdEligibility(objectID: objectID, point: point) {
                result[point.worldSlot.rawValue] = reason
            }
        }
        return result
    }

    private static func object(_ item: WorldObjectState, heldObjectID: String?,
                               holdUnavailableBySlot: [String: String]) -> [String: Any]? {
        guard let prop = item.generatedProp else { return nil }
        let q = item.transform.rotation
        // 逐挂点的答案**单独拼**（不塞进下面那个大字典字面量里）：嵌套闭包 + `Any` 字面量
        // 会把类型检查器逼到报"generic parameter could not be inferred"那种假错误。
        var slots: [String: [String: Any]] = [:]
        for point in PropAttachmentPoint.allCases {
            let slot = point.worldSlot.rawValue
            var entry: [String: Any] = ["eligible": holdUnavailableBySlot[slot] == nil,
                                        "name": PropAttachmentSlots.displayName(for: point)]
            if let reason = holdUnavailableBySlot[slot] { entry["reason"] = reason }
            slots[slot] = entry
        }
        // 「这件东西能不能挂在身上」= **至少有一个挂点**可用 —— 不是"右手可用"。
        // 逐挂点的答案在 `hold_slots` 里：手不行**不代表**背后不行（真机 2026-10-02 的缺陷形状）。
        var result: [String: Any] = ["object_id": prop.objectID, "name": prop.displayName, "is_placed": item.isEnabled,
            "is_held": heldObjectID == prop.objectID,
            "hold_eligible": holdUnavailableBySlot.count < PropAttachmentPoint.allCases.count,
            "hold_slots": slots,
            "position": vector(item.transform.position), "size": vector(prop.size), "yaw": atan2(2*q.w*q.y,1-2*q.y*q.y)]
        // 只有**三个挂点都不行**时才有"这件东西整体挂不上"这句话；否则它会冒充别的挂点的答案。
        if holdUnavailableBySlot.count == PropAttachmentPoint.allCases.count {
            result["hold_unavailable_reason"] = PropAttachmentPoint.allCases
                .map { "\(PropAttachmentSlots.displayName(for: $0))：\(holdUnavailableBySlot[$0.worldSlot.rawValue] ?? "不可用")" }
                .joined(separator: "；")
        }
        if let capability = item.propCapability {
            result["capability"] = [
                "template_id": capability.templateID,
                "activity_id": WorldPropActivityTemplate.activityID(
                    objectID: capability.objectID, templateID: capability.templateID),
            ]
        }
        if let usage = item.propUsage {
            var usagePayload: [String: Any] = ["template_id": usage.templateID,
                "status": usage.status.rawValue, "activity_request_id": usage.activityRequestID]
            if let reason = usage.reason { usagePayload["reason"] = reason }
            result["usage"] = usagePayload
        }
        if let grip = item.gripCalibration {
            let rotationYaw = atan2(2 * (grip.localRotation.w * grip.localRotation.y + grip.localRotation.x * grip.localRotation.z),
                                    1 - 2 * (grip.localRotation.y * grip.localRotation.y + grip.localRotation.z * grip.localRotation.z))
            result["grip"] = ["normalized_grip": vector(grip.normalizedGrip), "offset": vector(grip.localOffset),
                              "rotation_yaw": rotationYaw]
        }
        if let id = item.supportSurfaceID { result["surface_id"] = id }
        return result
    }
}
