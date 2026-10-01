import Foundation
import CoreFoundation

/// One resident lease sees primitive capabilities; it never selects files, worlds or spending grants.
///
/// 参数与规则**只有一处定义**：`WishMachineContract`（agent 用只读工具
/// `read_wish_machine_contract` 现读）。本文件里的 schema 与文案只允许出现"去读它"这句指针，
/// 不许再抄轴名、米数范围或例子 —— 过去提示词/schema/文档三处各存一份，已经漂移出过
/// "那把剑被算成 8.28 m"的事故。
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
    /// 生成服务**声明**的尺寸轴能力。默认 `.unreadable`：读不到就不声称支持任何轴。
    /// 生产接线见 `GMGNRadioApp.makeResidentWorldTools`（本轮恒为未读到 —— 桌面那侧
    /// 的 `provider_probe` 是另一条线，见 docs/plans/2026-10-02-wish-machine-agent-interface.md §7）。
    private let sizeIntentCapability: @MainActor () -> WishSizeIntentCapability
    /// 服务是否已配置 + 给用户看的一句话。只读接口照实转述，不加工。
    private let serviceFacts: @MainActor () -> (configured: Bool, notice: String)
    private let now: @MainActor () -> Date

    init(coordinator: WishMachineCoordinator, worldID: String, residentScope: String,
         authorizationID: UUID?, isCurrent: @escaping @MainActor () -> Bool,
         humanOrderedClaim: @escaping @MainActor () -> Bool = { false },
         continuationResumeAuthorizationID: UUID? = nil,
         resumePlacementStatus: @escaping @MainActor (WishMachineJob) -> Bool? = { _ in nil },
         sizeIntentCapability: @escaping @MainActor () -> WishSizeIntentCapability = { .unreadable },
         serviceFacts: @escaping @MainActor () -> (configured: Bool, notice: String) = { (false, "") },
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.coordinator = coordinator; self.worldID = worldID; self.residentScope = residentScope
        self.authorizationID = authorizationID; self.isCurrent = isCurrent
        self.humanOrderedClaim = humanOrderedClaim
        self.continuationResumeAuthorizationID = continuationResumeAuthorizationID
        self.resumePlacementStatus = resumePlacementStatus
        self.sizeIntentCapability = sizeIntentCapability
        self.serviceFacts = serviceFacts
        self.now = now
    }

    var tools: [ResidentWorldToolSession.AdditionalTool] {
        let names = ["submit_wish_generation", "read_wish_generation", WishMachineContract.toolName,
                     "retry_wish_generation", "cancel_wish_generation", "claim_wish_output", "resume_wish_continuation"]
        return names.map { name in
            var properties: [String: Any] = switch name {
            case "submit_wish_generation":
                [
                "attachment_id": ["type": "string", "description": "本轮参考图编号：用户附件或用 register_wish_reference_image 登记的网页参考图；可用 read_wish_generation 空参数查询"],
                "name": ["type": "string", "description": "物件名称"],
                // 参数事实（轴的 id、米数范围、例子）**只在** WishMachineContract 里；
                // 这里只说形状与"去哪儿读"，不再各存一份。
                "size_intent": [
                    "type": ["object", "null"],
                    "description": "尺寸意图：\(WishMachineContract.pointer)",
                    "properties": [
                        "axis": ["type": "string", "description": "哪根轴。合法取值与例子见 \(WishMachineContract.toolName)"],
                        "meters": ["type": "number", "description": "米数。允许范围见 \(WishMachineContract.toolName)"],
                        "source": ["type": "string", "description": "这个数字是谁说的。合法取值见 \(WishMachineContract.toolName)"]],
                    "required": [String](), "additionalProperties": false],
                "height_meters": ["type": "number", "description": "\(WishMachineContract.legacyHeightField)：旧字段，等价于 \(PropSizeIntent.Axis.height.rawValue) 轴；与 size_intent 只能给一个。只给它的调用线上不出现 size_intent 这个键（逐字节兼容）。"],
                "pending_id": ["type": "string", "description": "续上一次**未完成**的委托时原样回填：上一次 submit_wish_generation 的 info 不足回执或 read_wish_generation 的 open_drafts 里给的编号。给了它就复用原授权与原提交编号，不会变成新的委托、不会重复生成。"],
                "destination": ["type": ["object", "null"], "description": "仅当用户明确要求把成品摆到指定支撑面时提供；surface_ids 取自 list_placement_surfaces，position 为用户明确指定的绝对位置与朝向（可选）",
                    "properties": ["surface_ids": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 8],
                        "position": ["type": ["object", "null"], "properties": ["surface_id": ["type": "string"], "x": ["type": "number"], "y": ["type": "number"], "z": ["type": "number"], "yaw": ["type": "number"]],
                            "required": ["surface_id", "x", "y", "z", "yaw"], "additionalProperties": false]],
                    "required": ["surface_ids"], "additionalProperties": false]
                ]
            case WishMachineContract.toolName: [:]
            default: ["wish_id": ["type": "string", "description": "许愿任务编号"]]
            }
            if name == "resume_wish_continuation" {
                properties["confirm_resume"] = ["type": "boolean", "enum": [true], "description": "仅本轮用户明确要求恢复此原许愿任务的自动领取及原目的地摆放时设为 true；普通聊天、查询和后台事件不得确认。"]
            }
            let descriptions = [
                "submit_wish_generation": "仅在用户本轮明确要求制作物件时，用登记图片提交一次异步生成。\(WishMachineContract.pointer) 尺寸没说清楚时本工具**不会**替你猜、也不会提交：它会返回一个 `\(WishMachineContract.Code.needsInput.rawValue)` 的结果，里面有一句 `question`（问给用户）和一个 `pending_id`；把那一句问给用户，拿到答案后用同一个 `pending_id` 再调一次本工具，就会续上**同一次**委托（不重复生成、不消耗新授权）。用户没给参考图时，先用 search_wish_reference_images 找图并用 register_wish_reference_image 登记，再提交；不要要求用户自己找图。用户只要求看图或描述图片时不得调用。本地持久受理即返回 wish_id；宿主后台提交，重要状态和终态按同一 wish_id 异步通知，无需反复查询。受理不代表远端接单或生成完成；不移动居民。",
                "read_wish_generation": "省略 wish_id 可查看当前居民任务、本轮登记的参考图和还没做完的委托（open_drafts，含续办要用的 pending_id）；提供 wish_id 可查询任务并下载完成产物。生成完成、可展示与实际领取分别记录。",
                WishMachineContract.toolName: "只读地读回许愿机的**全部参数、限制与当前能力**（唯一真相，空参数调用）。填 submit_wish_generation 的任何参数之前先读它：轴的合法取值、米数范围、允许的出处、旧字段、错误与 `\(WishMachineContract.Code.needsInput.rawValue)` 的词汇、服务是否配置、生成服务**声明**的轴能力（读不到就明确说读不到，绝不会声称支持）、以及还没做完的委托。不产生任何副作用。",
                "retry_wish_generation": "确认结果未明的原提交，复用原图片和幂等编号，不创建新任务、不额外消费生成授权。仅显式调用，不自动重试。",
                "cancel_wish_generation": "请求取消当前居民的生成任务。取消请求或中断不保证远端计算已经停止。",
                "claim_wish_output": "居民真实到达许愿机领取活动位置、托盘实际显示产物后登记领取。重复领取返回同一物件编号，不代表已手持或摆放。",
                "resume_wish_continuation": "仅本轮用户明确要求恢复指定旧许愿委托时调用。恢复该任务的自动领取和原目的地摆放权限，不重新生成、不改变目的地、不重复摆放已有物件。成功后还需按用户指令通过 update_resident_intent 的 resume_paused_intent 恢复居民意图；本工具不修改居民意图。"
            ]
            // `submit_wish_generation` 的尺寸是**二选一**（`size_intent` 或旧的 `height_meters`），
            // 所以这里不能把它们都列成必需 —— 一个都不给会被尺寸判据明确判成"信息不足"
            // （结构化 `\(WishMachineContract.Code.needsInput.rawValue)`：问用户一句），
            // 而不是让 app 替用户猜一个。
            let required: [String] = switch name {
            case "read_wish_generation", WishMachineContract.toolName: []
            case "submit_wish_generation": ["attachment_id", "name"]
            default: properties.keys.filter { $0 != "destination" }.sorted()
            }
            return .init(name: name, description: descriptions[name]!, inputSchema: [
                "type": "object", "properties": properties, "required": required, "additionalProperties": false
            ], validate: { Self.validate($0, name: name) },
               handle: { [self] callID, arguments in await handle(name: name, callID: callID, data: arguments) })
        }
    }

    /// **结构性**校验：形状对不对（未知键、类型）。语义判据在 `sizeIntentVerdict`。
    ///
    /// 为什么不再要求尺寸齐全：尺寸没说清楚是"信息不足"，要走**结构化成功返回**
    /// （`validate` 只能答 Bool，说不出"缺什么、该问哪一句"）。这里放行之后，
    /// `handle` 的第一件事就是拿到三态判据 —— 不齐全时它只回执、**不发提交**。
    private static func validate(_ arguments: [String: Any], name: String) -> Bool {
        if (name == "read_wish_generation" || name == WishMachineContract.toolName) && arguments.isEmpty { return true }
        if name == "resume_wish_continuation" {
            guard Set(arguments.keys) == ["wish_id", "confirm_resume"],
                  (arguments["wish_id"] as? String).flatMap(UUID.init(uuidString:)) != nil,
                  let confirmed = arguments["confirm_resume"] as? NSNumber,
                  CFGetTypeID(confirmed) == CFBooleanGetTypeID() else { return false }
            return confirmed.boolValue
        }
        if name != "submit_wish_generation" { return Set(arguments.keys) == ["wish_id"] && (arguments["wish_id"] as? String).flatMap(UUID.init(uuidString:)) != nil }
        guard Set(arguments.keys).isSubset(of: ["attachment_id", "name", "size_intent", "height_meters", "destination", "pending_id"]),
              let attachment = arguments["attachment_id"] as? String, UUID(uuidString: attachment) != nil,
              let name = arguments["name"] as? String, (1...100).contains(name.count),
              isStructurallySoundSizeFields(arguments),
              arguments["pending_id"] == nil
                || (arguments["pending_id"] as? String).flatMap(UUID.init(uuidString:)) != nil else { return false }
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

    private static func isFiniteNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite
    }

    /// 尺寸字段的**形状**：`size_intent` 是对象、只有三个已知键、成员类型对；旧字段是米数。
    /// 不判断"轴在不在词汇表里""米数在不在范围内" —— 那是语义，判据在 `sizeIntentVerdict`。
    private static func isStructurallySoundSizeFields(_ arguments: [String: Any]) -> Bool {
        if let raw = arguments["height_meters"], !(raw is NSNull), !isFiniteNumber(raw) { return false }
        guard let rawIntent = arguments["size_intent"], !(rawIntent is NSNull) else { return true }
        guard let intent = rawIntent as? [String: Any],
              Set(intent.keys).isSubset(of: ["axis", "meters", "source"]) else { return false }
        if let axis = intent["axis"], !(axis is NSNull), !(axis is String) { return false }
        if let meters = intent["meters"], !(meters is NSNull), !isFiniteNumber(meters) { return false }
        if let source = intent["source"], !(source is NSNull), !(source is String) { return false }
        return true
    }

    /// 尺寸意图的判据：**三态**，不是 Bool，也不是一句 `String?`。
    ///
    /// 为什么必须三态：`validate` 只能答"行不行"，而"为什么不行"分成两类完全不同的处理 ——
    /// 「信息不足」（去问用户**一句**，然后用结构化回执把缺什么、该问什么交出去，**不发提交**）
    /// 和「输入畸形」（调用方写错了：轴不是契约词、两个尺寸字段都给、出处是猜的）。
    /// 混成一句话就没法结构化回问，session 层的 Bool 校验更是连"缺什么"都传不出去。
    ///
    /// 规则（参数事实一律来自 `WishMachineContract`，本文件不抄第二份）：
    /// - 两个尺寸字段**二选一**：都不给 ⇒ 信息不足；都给 ⇒ 两份真相，畸形。
    /// - 轴缺 ⇒ 信息不足（问"按最长边还是按高度"，不替用户挑）；轴不在契约词汇 ⇒ 畸形。
    /// - 米数缺 ⇒ 信息不足；不在契约范围 ⇒ 畸形（与守护进程 `invalid_size_intent` 同一个码）。
    /// - 轴是契约词但**服务声明不收** ⇒ 信息不足（发了就是远端 400 ⇒ 整件任务失败）。
    ///   能力**读不到**时**不声称任何轴被支持**，也不据此拦截：线上那个键不发（协商的 fail-closed
    ///   方向是"这一条不发"，见 docs/plans/2026-10-02-dgx-size-axis-negotiation.md §1）。
    /// - `source` 只接受契约列出的来源；`default` 一位的语义是"这个数字是猜的"，而本契约
    ///   存在的意义就是不许猜。
    enum SizeIntentVerdict: Equatable {
        /// 可以提交。`heightMeters` 是提交契约里的那个数字；`intent` 为 nil 表示走旧字段路径
        /// （老路径的推断与线上字节因此逐位不变）。
        case ok(heightMeters: Double, intent: PropSizeIntent?)
        /// 信息不足：**结构化成功返回**，不发提交、不落默认值。
        case needsInput(need: WishMachineContract.Need, reason: WishMachineContract.NeedReason,
                        unsupportedAxis: String? = nil)
        /// 输入畸形：可读错误。
        case invalid(reason: String)
    }

    static func sizeIntentVerdict(_ arguments: [String: Any],
                                  capability: WishSizeIntentCapability) -> SizeIntentVerdict {
        let rawIntent = arguments["size_intent"].flatMap { $0 is NSNull ? nil : $0 }
        let rawHeight = arguments["height_meters"].flatMap { $0 is NSNull ? nil : $0 }
        if rawIntent != nil, rawHeight != nil {
            return .invalid(reason: "尺寸给了两遍：size_intent 与 \(WishMachineContract.legacyHeightField) 只能给一个（后者是旧字段，等价于 axis=\(PropSizeIntent.Axis.height.rawValue)）。")
        }
        if let raw = rawHeight {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else {
                return .invalid(reason: "\(WishMachineContract.legacyHeightField) 必须是 \(rangeText()) 米之间的数。")
            }
            // 旧字段走契约范围，不查服务声明的轴：它上线时**根本不带** size_intent 这个键。
            guard contractRangeContains(number.doubleValue) else {
                return .invalid(reason: "\(WishMachineContract.legacyHeightField) 必须是 \(rangeText()) 米之间的数。")
            }
            return .ok(heightMeters: number.doubleValue, intent: nil)
        }
        guard let raw = rawIntent else {
            return .needsInput(need: .size, reason: .unspecified)
        }
        guard let value = raw as? [String: Any] else {
            return .invalid(reason: "size_intent 必须是一个对象：{axis, meters, source?}。")
        }
        guard Set(value.keys).isSubset(of: ["axis", "meters", "source"]) else {
            return .invalid(reason: "size_intent 只认 axis / meters / source 三个键。")
        }
        let rawAxis = value["axis"].flatMap { $0 is NSNull ? nil : $0 }
        let axis: PropSizeIntent.Axis
        switch rawAxis {
        case nil:
            return .needsInput(need: .sizeAxis, reason: .unspecified)
        case let text as String:
            guard let parsed = PropSizeIntent.Axis(rawValue: text) else {
                return .invalid(reason: "size_intent.axis 只能是 \(axisText())（收到 \(text)）。")
            }
            axis = parsed
        default:
            return .invalid(reason: "size_intent.axis 必须是字符串。")
        }
        // 服务**声明**不收这根轴 ⇒ 不发提交（远端会 400，整件任务失败），结构化地问用户一句。
        // 读不到能力 ⇒ 这里一个字都不声称，也绝不据此放行。
        if capability.isReadable, !capability.declaredAxes.contains(axis.rawValue) {
            return .needsInput(need: .sizeAxis, reason: .axisNotDeclared, unsupportedAxis: axis.rawValue)
        }
        let source: PropSizeIntent.Source
        if let rawSource = value["source"].flatMap({ $0 is NSNull ? nil : $0 }) {
            guard let text = rawSource as? String else {
                return .invalid(reason: "size_intent.source 必须是字符串。")
            }
            guard let parsed = PropSizeIntent.Source(rawValue: text) else {
                return .invalid(reason: "size_intent.source 只能是 \(sourceText())。")
            }
            guard WishMachineContract.acceptedSources.contains(parsed) else {
                return .invalid(reason: "size_intent.source = \(parsed.rawValue) 不接受：那一位的语义是\"这个数字是猜的\"，而本契约存在的意义就是不许猜 —— 用户没说尺寸就先问他一句。")
            }
            source = parsed
        } else {
            source = .user
        }
        guard let rawMeters = value["meters"].flatMap({ $0 is NSNull ? nil : $0 }) else {
            return .needsInput(need: .sizeMeters, reason: .unspecified)
        }
        guard let number = rawMeters as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            return .invalid(reason: "size_intent.meters 必须是米数。")
        }
        // 契约范围是硬边界（守护进程与客户端同一条）。越界一律拒绝，**绝不夹取**。
        guard contractRangeContains(number.doubleValue) else {
            return .invalid(reason: "size_intent.meters 超出范围：允许 \(rangeText()) 米（收到 \(number.doubleValue)）。")
        }
        // 服务声明的范围可能更窄。读到了且更窄 ⇒ 不发提交，结构化地问用户一句并给出真实上下界。
        // 读不到 ⇒ 不作任何声称，按契约范围放行（守护进程也会按"没声明就不发"处理）。
        if case let .declared(_, declaredMinimum, declaredMaximum, _) = capability,
           number.doubleValue < declaredMinimum || number.doubleValue > declaredMaximum {
            return .needsInput(need: .sizeMeters, reason: .metersOutOfRange)
        }
        guard let intent = PropSizeIntent(axis: axis, meters: number.doubleValue, source: source) else {
            return .invalid(reason: "size_intent 无法构成合法的尺寸意图。")
        }
        // 轴是高度时提交的 height_meters 就是同一个数（守护进程强制相等，否则 size_intent_conflict）。
        return .ok(heightMeters: intent.heightMetersForSubmission, intent: intent)
    }

    /// 契约范围（唯一硬边界）：`WishMachineContract` 从 `PropSizeIntent` 常量取。
    static func contractRangeContains(_ meters: Double) -> Bool {
        meters >= WishMachineContract.minimumMeters && meters <= WishMachineContract.maximumMeters
    }

    static func rangeText() -> String {
        "\(WishMachineContract.metersText(WishMachineContract.minimumMeters))—\(WishMachineContract.metersText(WishMachineContract.maximumMeters))"
    }

    static func axisText() -> String {
        WishMachineContract.axes.map(\.id).joined(separator: " 或 ")
    }

    static func sourceText() -> String {
        WishMachineContract.acceptedSources.map(\.rawValue).joined(separator: " 或 ")
    }


    private func handle(name: String, callID: String, data: Data) async -> RealtimeDJToolResult {
        guard !Task.isCancelled, isCurrent() else {
            return failure(callID, code: WishMachineContract.Code.staleWishSession.rawValue, message: "本轮空间操作已停止。")
        }
        guard let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return failure(callID, code: WishMachineContract.Code.invalidArguments.rawValue, message: "许愿工具参数不符合当前契约。")
        }
        if name == WishMachineContract.toolName {
            guard Self.validate(arguments, name: name) else {
                return failure(callID, code: WishMachineContract.Code.invalidArguments.rawValue, message: "只读参数接口不接受任何参数。")
            }
            return self.contract(callID: callID)
        }
        // 尺寸判据**先于**结构性校验：`validate` 只能答 Bool，说不出"缺什么、该问哪一句"。
        // 畸形 → 可读错误；信息不足 → 结构化成功返回（不发提交）。
        var submitVerdict: SizeIntentVerdict?
        if name == "submit_wish_generation" {
            let verdict = Self.sizeIntentVerdict(arguments, capability: sizeIntentCapability())
            switch verdict {
            case let .needsInput(need, reason, unsupportedAxis):
                return await needsInput(callID: callID, need: need, reason: reason,
                    unsupportedAxis: unsupportedAxis, arguments: arguments)
            case let .invalid(reason):
                return failure(callID, code: WishMachineContract.Code.invalidSizeIntent.rawValue, message: reason)
            case .ok:
                submitVerdict = verdict
            }
        }
        guard Self.validate(arguments, name: name) else {
            return failure(callID, code: WishMachineContract.Code.invalidArguments.rawValue, message: "许愿工具参数不符合当前契约。")
        }
        if name == "read_wish_generation" && arguments.isEmpty { return discovery(callID: callID) }
        do {
            let job: WishMachineJob
            // 这次提交用的是哪一份授权（续办时是**草稿**那一对，而不是本轮新开的），
            // 提到 switch 外面才写得出回执；初值 nil = 还没走到提交。
            var usedAuthorityID: UUID?
            var usedRequestID: String?
            var resumedDraft: WishMachinePendingDraft?
            var replayedSubmission = false
            switch name {
            case "submit_wish_generation":
                guard case let .ok(heightMeters, sizeIntent)? = submitVerdict else {
                    // 判据与这里**必须**一致；万一将来分叉就明确拒绝，绝不 force-unwrap 崩在工具里
                    // （用户会看成"点了没反应"），更不静默按"没有意图"提交。
                    return failure(callID, code: WishMachineContract.Code.invalidSizeIntent.rawValue,
                        message: "这次提交没有可用的尺寸：请按用户说的尺寸重填 size_intent，或先问用户一句。")
                }
                let attachmentID = UUID(uuidString: arguments["attachment_id"] as! String)!
                let name = arguments["name"] as! String
                let destination = Self.destination(arguments)
                // 这次调用是"回答上一句问话"，还是新的一次委托？答案决定用哪一份授权：
                // 续办**必须**用草稿里的原授权 + 原 requestID，否则就是另一次委托。
                let resolution = resolveDraft(arguments, attachmentID: attachmentID, name: name)
                if case let .ambiguous(options) = resolution {
                    return await needsInput(callID: callID, need: .pendingId, reason: .ambiguousDelegation,
                        drafts: options, arguments: arguments)
                }
                if case let .resume(draft) = resolution {
                    usedAuthorityID = draft.authorityID
                    usedRequestID = draft.requestID
                    resumedDraft = draft
                    // 这一份委托**唯一**对应的任务（如有）⇒ 幂等重放：回同一个 job，绝不新建。
                    // 判据是"这份授权下有没有任务"，而不是草稿上的标记 —— 标记之前崩掉也一样查出。
                    if let existing = coordinator.residentJobs(worldID: worldID, residentScope: residentScope)
                        .first(where: { $0.authorizationID == draft.authorityID }) {
                        replayedSubmission = true
                        job = try coordinator.read(id: existing.id, worldID: worldID, residentScope: residentScope)
                    } else {
                        // 原授权必须还在、原图还在（否则宁可让用户重说一次，也不新建生成）。
                        guard coordinator.attachmentChoices(authorizationID: draft.authorityID,
                            worldID: worldID, residentScope: residentScope)
                            .contains(where: { $0.id == draft.attachmentID }) else {
                            return failure(callID, code: WishMachineContract.Code.delegationExpired.rawValue,
                                message: "这份委托已经不能续了（原授权已不在或已换空间）。请让用户重新说一次要做什么；不会因此新建一次生成。")
                        }
                        job = try await coordinator.submit(requestID: draft.requestID, authorizationID: draft.authorityID,
                            attachmentID: attachmentID, name: name,
                            heightMeters: heightMeters, sizeIntent: sizeIntent, worldID: worldID,
                            residentScope: residentScope, destination: destination)
                        try? coordinator.markPendingDraftSubmitted(id: draft.id, jobID: job.id)
                    }
                } else {
                    // 新的一次委托：用**本轮**授权，走今天的路径（同授权第二次不同 requestID
                    // 仍然报 consumedAuthorization —— 那条 fail-closed 没有被放宽）。
                    guard let authorizationID else { throw WishMachineError.unauthorized }
                    usedAuthorityID = authorizationID
                    usedRequestID = callID
                    job = try await coordinator.submit(requestID: callID, authorizationID: authorizationID,
                        attachmentID: attachmentID, name: name,
                        heightMeters: heightMeters, sizeIntent: sizeIntent, worldID: worldID,
                        residentScope: residentScope, destination: destination)
                }
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
                return failure(callID, code: WishMachineContract.Code.staleWishSession.rawValue,
                    message: "会话已停止；已发起任务仍保留在原空间，可稍后查询。", wishID: job.id)
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
                // 这一次用的是哪一份授权：续办必须复用原委托，不然"同一个委托"只是口号。
                var authorization: [String: Any] = [
                    "reused": resumedDraft != nil,
                    "source": resumedDraft == nil ? "this_turn" : "pending_draft",
                    "authority_id": usedAuthorityID?.uuidString ?? "",
                    "request_id": usedRequestID ?? "",
                ]
                if let resumedDraft { authorization["pending_id"] = resumedDraft.id.uuidString }
                if replayedSubmission {
                    // 幂等重放：同一个 pending_id 的第 N 次调用回的是**同一个**任务。
                    authorization["replayed"] = true
                    payload["replayed"] = true
                    payload["message"] = "这份委托已经提交过，回的是同一个任务（\(job.id.uuidString)）：没有重复生成，也没有消耗新的授权。"
                }
                payload["authorization"] = authorization
                // 线上到底发不发这个键：读不到服务声明就**不声称**（守护进程按"没声明就不发"处理）。
                let capability = sizeIntentCapability()
                if job.sizeIntent == nil {
                    payload["size_intent_forwarding"] = "legacy_height_only"
                } else if capability.isReadable {
                    payload["size_intent_forwarding"] = capability.declaredAxes.contains(job.sizeIntent!.axis.rawValue)
                        ? "declared_by_service" : "not_declared_by_service"
                } else {
                    payload["size_intent_forwarding"] = "capability_unreadable_not_claimed"
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
        } catch {
            return failure(callID, code: WishMachineContract.Code.wishOperationFailed.rawValue,
                message: error.localizedDescription)
        }
    }

    /// 只读参数接口：许愿机的全部参数、限制、当前能力与还没做完的委托。
    ///
    /// 唯一的真相在 `WishMachineContract`；这里只负责把**当前**的动态部分（服务是否配置、
    /// 服务声明的轴能力、本 scope 的草稿）拼上去。
    private func contract(callID: String) -> RealtimeDJToolResult {
        let facts = serviceFacts()
        let payload = WishMachineContract.readOnlyPayload(
            serviceConfigured: facts.configured, serviceNotice: facts.notice,
            capability: sizeIntentCapability(),
            openDrafts: coordinator.pendingDrafts(worldID: worldID, residentScope: residentScope, now: now())
                .map(Self.draftPayload))
        return .init(callID: callID,
            resultJSON: (try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)) ?? Data("{}".utf8),
            isError: false)
    }

    static func draftPayload(_ draft: WishMachinePendingDraft) -> [String: Any] {
        var value: [String: Any] = ["pending_id": draft.id.uuidString, "name": draft.name,
            "attachment_id": draft.attachmentID.uuidString, "needs": draft.needs,
            "attempt": draft.attempt, "world_id": draft.worldID]
        if let surfaces = draft.destinationSurfaceIDs { value["destination_surface_ids"] = surfaces }
        if let submitted = draft.submittedJobID { value["submitted_wish_id"] = submitted.uuidString }
        return value
    }

    /// 这次调用是"回答上一句问话"（续同一份委托）还是"新的一次委托"？
    enum DraftResolution: Equatable {
        case fresh
        case resume(WishMachinePendingDraft)
        /// 说不清是哪一件：**不猜**，把候选交回去让 agent 先问用户。
        case ambiguous([WishMachinePendingDraft])
    }

    private func resolveDraft(_ arguments: [String: Any], attachmentID: UUID, name: String) -> DraftResolution {
        let drafts = coordinator.pendingDrafts(worldID: worldID, residentScope: residentScope, now: now())
        guard !drafts.isEmpty else { return .fresh }
        if let text = arguments["pending_id"] as? String, let id = UUID(uuidString: text) {
            // 给了编号就必须逐项对上：对不上就是"把回答当成了另起一件"，宁可再问一次。
            guard let match = drafts.first(where: { $0.id == id }),
                  match.attachmentID == attachmentID, match.name == name else { return .ambiguous(drafts) }
            return .resume(match)
        }
        // 只自动命中**还没提交**的草稿：已提交的那份只认显式 pending_id（否则用户
        // 过一会儿真心想再做一件同名同图的，会被当成重放）。
        let matches = drafts.filter { $0.attachmentID == attachmentID && $0.name == name && $0.submittedJobID == nil }
        if matches.count == 1 { return .resume(matches[0]) }
        if matches.isEmpty { return .fresh }
        return .ambiguous(matches)
    }

    /// 信息不足的**结构化成功**回执：不发提交、不填默认值，并把原委托记成草稿。
    private func needsInput(callID: String, need: WishMachineContract.Need,
                            reason: WishMachineContract.NeedReason,
                            unsupportedAxis: String? = nil,
                            drafts: [WishMachinePendingDraft] = [],
                            arguments: [String: Any]) async -> RealtimeDJToolResult {
        let objectName = arguments["name"] as? String ?? "这件东西"
        let capability = sizeIntentCapability()
        var pendingID: UUID?
        var attempt = 1
        var draftPayload: [String: Any]?
        // 有了原授权与原图才能把"同一个委托"钉下来：钉的是**原来**那一对
        // (authorityID, requestID)，不是本轮的 —— 否则用户回答的那一轮就变成新授权。
        if let attachmentID = (arguments["attachment_id"] as? String).flatMap(UUID.init(uuidString:)) {
            let resolution = resolveDraft(arguments, attachmentID: attachmentID, name: objectName)
            let existing: WishMachinePendingDraft?
            let authorityID: UUID
            let requestID: String
            switch resolution {
            case let .resume(draft):
                existing = draft; authorityID = draft.authorityID; requestID = draft.requestID
            case .ambiguous:
                existing = nil; authorityID = UUID(); requestID = ""
            case .fresh:
                existing = nil
                guard let authorizationID else {
                    return failure(callID, code: "unauthorized", message: "本轮没有用户授权的图片生成请求。")
                }
                authorityID = authorizationID; requestID = callID
            }
            if !requestID.isEmpty {
                if let draft = try? coordinator.recordPendingDraft(
                    id: existing?.id ?? UUID(), authorityID: authorityID, requestID: requestID,
                    attachmentID: attachmentID, name: objectName, destination: Self.destination(arguments),
                    needs: [need.rawValue], worldID: worldID, residentScope: residentScope, now: now()) {
                    pendingID = draft.id
                    attempt = draft.attempt
                    draftPayload = Self.draftPayload(draft)
                }
            }
        }
        let payload = WishMachineContract.needsInputPayload(need: need, reason: reason, name: objectName,
            pendingID: pendingID, attempt: attempt, capability: capability,
            unsupportedAxis: unsupportedAxis, draft: draftPayload,
            choices: need == .pendingId ? drafts.map { $0.id.uuidString } : nil)
        return .init(callID: callID,
            resultJSON: (try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)) ?? Data("{}".utf8),
            isError: false)
    }

    /// 工具参数里的目的地（`validate` 已保证形状；这里仍然不 force-unwrap）。
    static func destination(_ arguments: [String: Any]) -> WishPlacementDestination? {
        guard let value = arguments["destination"] as? [String: Any],
              let surfaces = value["surface_ids"] as? [String], !surfaces.isEmpty else { return nil }
        var explicit: WishPlacementTarget?
        if let position = value["position"] as? [String: Any],
           let surface = position["surface_id"] as? String,
           let x = (position["x"] as? NSNumber)?.doubleValue,
           let y = (position["y"] as? NSNumber)?.doubleValue,
           let z = (position["z"] as? NSNumber)?.doubleValue,
           let yaw = (position["yaw"] as? NSNumber)?.doubleValue {
            explicit = .init(surfaceID: surface, position: .init(x: x, y: y, z: z), yaw: yaw)
        }
        return .init(surfaceIDs: surfaces, explicitTarget: explicit)
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
            "open_drafts": coordinator.pendingDrafts(worldID: worldID, residentScope: residentScope, now: now())
                .map(Self.draftPayload),
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
