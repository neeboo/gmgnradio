//
//  WishMachineContract.swift
//  GMGNRadio
//
//  许愿机参数的**唯一**真相（2026-10-02）。
//
//  为什么要有这个文件：这套参数过去散在三处 —— `GMGNRadioApp.swift` 的
//  `wishMachinePromptContext` 系统提示一段、`Agent/ResidentWishMachineTools.swift` 的
//  工具 schema 与拒绝文案一份、`docs/plans/**` 文档再一份。今天已经因此漂移出过事：
//  尺寸只认单一"高度"轴 ⇒ 真机那把剑被算成 8.28 m、比舱室还长 ⇒ 用户看到"太大"和
//  "消失"。三份真相里改到两份就等于没改。
//
//  所以：**只有这一处**允许出现轴名、米数范围、例子、"用户没说就先问"这类参数事实。
//  提示词与工具 schema 一律降级成一句指针（`WishMachineContract.pointer`），
//  agent 需要参数就调用只读工具 `read_wish_machine_contract` 现读。
//
//  而且这里**不新抄常量**：轴的字面量属于 `PropSizeIntent.Axis`，米数范围属于
//  `PropSizeIntent.minimumMeters/maximumMeters`，来源属于 `PropSizeIntent.Source`。
//  本类型只把那些已存在的事实组织成 agent 能读的一份；谁改了 enum，接口跟着改。
//
//  fail-closed 的两条纪律在下面用类型而不是注释表达：
//    · `WishSizeIntentCapability` 只有「读到了」和「读不到」两种形态，`unreadable`
//      里根本没有 `axes` 可取 —— 不可能把"没读到"误表示成"支持"。
//    · 信息不足是**结构化成功返回**（`needs_input`），不是错误、更不是默认值。

import Foundation

/// 生成服务**声明**的尺寸轴能力。
///
/// 只有两种形态：读到了，或者没读到。这不是"布尔标志 + 可能为空的数组" ——
/// `.unreadable` 里没有 `axes` 这个成员可取，于是"读不到 ⇒ 当成支持"在类型上就写不出来。
enum WishSizeIntentCapability: Equatable, Sendable {
    /// 服务声明读不到（没配探测、网络失败、没有 `provider` 块…）。这一条不发。
    case unreadable
    /// 服务自报：接受哪些轴、米数范围、`applies`（`echo` = 只回显不归一）。
    case declared(axes: [String], minimumMeters: Double, maximumMeters: Double, applies: String)

    /// 服务声明接受的轴。`.unreadable` ⇒ **空**：绝不拿契约词汇冒充服务能力。
    var declaredAxes: [String] {
        if case let .declared(axes, _, _, _) = self { return axes }
        return []
    }

    var isReadable: Bool {
        if case .declared = self { return true }
        return false
    }
}

/// 许愿机参数与规则的一处定义。
enum WishMachineContract {
    static let version = 1

    /// agent 现读参数的**唯一**入口。
    static let toolName = "read_wish_machine_contract"

    /// 提示词与工具描述里唯一允许出现的那句话（指针，不是第二份参数）。
    static let pointer = "许愿机的参数与尺寸规则只有一处定义：填任何参数之前先调用 \(toolName)（空参数）读取，不要凭记忆填。"

    // MARK: - 信息不足的词汇（结构化返回，不是错误）

    /// `needs_input` 里 `needs` 的取值。
    enum Need: String, CaseIterable, Sendable {
        case size
        case sizeAxis = "size_axis"
        case sizeMeters = "size_meters"
        case pendingId = "pending_id"
    }

    /// 为什么信息不足。`unspecified` = 用户还没说；其余是"说要了，但当前能力收不下"。
    enum NeedReason: String, Sendable {
        case unspecified
        case axisNotDeclared = "axis_not_declared"
        case metersOutOfRange = "meters_out_of_range"
        case ambiguousDelegation = "ambiguous_delegation"
    }

    /// 工具回执里的代码。`needsInput` 是**成功**通道（`isError: false`），其余是错误。
    ///
    /// 线上字面量取 `insufficient_input`：另一条设计线
    /// （`docs/plans/2026-10-02-rust-world-authority-and-mcp.md` §6.4/§6.5）已经把
    /// "参数不足"这一个语义写成这个名字，同一个语义在两个面上不许叫两个名字。
    enum Code: String, Sendable {
        case needsInput = "insufficient_input"
        case invalidSizeIntent = "invalid_size_intent"
        case invalidArguments = "invalid_arguments"
        case staleWishSession = "stale_wish_session"
        case wishOperationFailed = "wish_operation_failed"
        case delegationExpired = "delegation_expired"
        case delegationAlreadySubmitted = "delegation_already_submitted"
    }

    // MARK: - 尺寸意图（轴 / 范围 / 来源）

    struct AxisFact: Equatable, Sendable {
        let id: String
        let title: String
        /// 用户没说尺寸时**只问一句**的那句话。
        let ask: String
        /// 一句用户原话怎么落到这根轴。
        let example: String
    }

    /// 轴词汇的唯一拥有者是 `PropSizeIntent.Axis`；这里只补"给人看的话"。
    static var axes: [AxisFact] {
        PropSizeIntent.Axis.allCases.map { axis in
            switch axis {
            case .longest:
                AxisFact(id: axis.rawValue, title: "最长边",
                    ask: "你要的这件东西，最长的那一边大约多少米？",
                    example: "「一把 1.1 米的剑」⇒ axis=longest, meters=1.1")
            case .height:
                AxisFact(id: axis.rawValue, title: "高度",
                    ask: "你要的这件东西，立起来大约多高？",
                    example: "「高 35 厘米的咖啡机」⇒ axis=height, meters=0.35")
            }
        }
    }

    /// 允许的出处：用户原话、生成服务建议。
    static let acceptedSources: [PropSizeIntent.Source] = [.user, .suggested]
    /// 不接受的出处：`default` 的语义是"这个数字是猜的"，而本契约存在的意义就是不许猜。
    static let rejectedSources: [PropSizeIntent.Source] = [.fallback]

    static var minimumMeters: Double { PropSizeIntent.minimumMeters }
    static var maximumMeters: Double { PropSizeIntent.maximumMeters }

    /// 三轴的毫米边界：与米数**同一条边界**，常量属于 `PropSizeIntent`。
    static var minimumMillimeters: Double { PropSizeIntent.minimumMillimeters }
    static var maximumMillimeters: Double { PropSizeIntent.maximumMillimeters }
    /// 线上 `mode` 的字面量（唯一拥有者是 `PropSizeIntent`）。
    static var dimensionsModeValue: String { PropSizeIntent.dimensionsModeValue }

    /// 三根轴的**名字与朝向**。轴序不是我们发明的：`up_axis` 在本仓钉死在 `±Y`
    /// （守护进程 `UP_AXES = ["+Y","-Y"]`），所以"高"永远是 `y`。
    static let dimensionEdges: [[String: String]] = [
        ["id": "x", "title": "宽", "note": "左右方向（±X）。用户说「1443 x 862 x 302 mm」时它是第一个数 1443。"],
        ["id": "y", "title": "高", "note": "上下方向（±Y；本仓 up 轴固定在 ±Y）。它是 862，也是提交里的 \(legacyHeightField)。"],
        ["id": "z", "title": "深", "note": "前后方向。它是 302 —— 平面电视的 302 是**底座进深**（整体最深的那一维），不是面板厚度。"],
    ]

    /// 用户原话的「长 × 宽 × 高」怎么落到三根轴：按 x 宽 / y 高 / z 深**照实**填。
    static let dimensionOrderNote = "用户说「1443 x 862 x 302 mm」时按 x=1443（宽）、y=862（高）、z=302（深）照实填，不要重排、不要换算成米、不要只挑最长边。"

    /// 毫米数给人看的写法（整数不带小数点）。
    static func millimetersText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// 旧字段：等价于 `axis=height`，与 `size_intent` 只能给一个。
    static let legacyHeightField = "height_meters"

    /// 尺寸的问题只有一句。**只问一句**：不连问五个问题，也不替用户挑轴。
    static func question(for need: Need, name: String) -> String {
        switch need {
        case .size:
            "你要的「\(name)」大约多大？给**完整长宽高**最好（例如「1443 × 862 × 302 毫米」，宽 × 高 × 深），我照实填三轴；只说得出一根轴也行（例如「1 米」，我按最长边算）。"
        case .sizeAxis:
            "你要的「\(name)」是按最长边算，还是按高度算？顺便给个米数。"
        case .sizeMeters:
            "「\(name)」要做多大？给我一个 \(metersText(minimumMeters))—\(metersText(maximumMeters)) 米之间的数。"
        case .pendingId:
            "你刚才说的要做的是哪一件？后台有不止一件还没做完的委托，我需要你说是哪一件。"
        }
    }

    static func metersText(_ meters: Double) -> String {
        meters == meters.rounded() ? String(Int(meters)) : String(meters)
    }

    // MARK: - 只读接口的载荷

    /// `read_wish_machine_contract` 的全部内容。`openDrafts` 由调用方按本 scope 组装。
    static func readOnlyPayload(serviceConfigured: Bool, serviceNotice: String,
                                capability: WishSizeIntentCapability,
                                openDrafts: [[String: Any]]) -> [String: Any] {
        [
            "ok": true,
            "contract_version": version,
            "instruction": pointer,
            "size_intent": [
                "required": "size_intent 与旧字段 \(legacyHeightField) 二选一；一个都不给就是信息不足，不是默认值。",
                "shapes": [
                    "two_shapes_pick_one": "size_intent 有两种**形状**，只能给一种：给了完整三维就用 mode=\(dimensionsModeValue) + millimeters（三轴）；只说得出一根轴才用 axis + meters（旧形状）。两种同时给是畸形（守护进程码 size_intent_shape_conflict）。",
                    "dimensions": [
                        "shape": "{\"mode\": \"\(dimensionsModeValue)\", \"millimeters\": {\"x\": 1443, \"y\": 862, \"z\": 302}, \"source\": \"user\"}",
                        "when": "用户说了**完整长宽高**时用这个（例如「1443 x 862 x 302 mm」「宽 1.4 米、高 0.86 米、深 0.3 米」）。**照实填三个数** —— 只挑一根轴报上来会让另外两维没有位置。",
                        "edges": dimensionEdges,
                        "order_note": dimensionOrderNote,
                        "unit": "毫米（整数）。不要换算成米：契约里记的是**用户说的那个数**，面板会逐位显示给他核对。",
                        "min_millimeters": minimumMillimeters,
                        "max_millimeters": maximumMillimeters,
                        "all_three_required": "x / y / z 三个都要给，缺一个就是畸形（缺的那一维「默认成什么」都是猜）。三根轴都必须落在 \(millimetersText(minimumMillimeters))—\(millimetersText(maximumMillimeters)) 毫米。",
                        "height_field_rule": "三轴的 y（高）**必须**等于提交里的 \(legacyHeightField)（守护进程强制相等，否则 size_intent_conflict）。",
                        "normalization": "场景里按**最长边等比**归一（三根轴同乘一个比例），另外两维只作为**期望值**记录：渲染端只有一份等比缩放，非等比会让碰撞盒与画面对不上。",
                        "forwarding": "三轴意图**不会**发给生成服务（线上那个键只有「一根轴 + 一个米数」这一种形状）：远端只收到 \(legacyHeightField) = 三轴的 y。",
                    ],
                    "axes": "旧形状：{\"axis\": \"longest\", \"meters\": 1.1, \"source\": \"user\"}。只在用户确实只给了一个尺寸时用。",
                ],
                "legacy_field": [
                    "id": legacyHeightField,
                    "description": "旧字段，等价于 axis=\(PropSizeIntent.Axis.height.rawValue)；与 size_intent 只能给一个。只给它的调用线上不出现 size_intent 这个键（逐字节兼容）。",
                ],
                "axes": axes.map { ["id": $0.id, "title": $0.title, "ask": $0.ask, "example": $0.example] },
                "sources": acceptedSources.map { ["id": $0.rawValue] },
                "rejected_sources": rejectedSources.map(\.rawValue),
                "min_meters": minimumMeters,
                "max_meters": maximumMeters,
                "when_unknown": [
                    "code": Code.needsInput.rawValue,
                    "do": "只问一句（三轴或轴 + 一个米数），拿到答案后用 needs_input 回执里的 pending_id 再调一次 submit_wish_generation。",
                    "never": "不要自己猜一个尺寸，不要默认按高度，不要把「没说」当成最后一次机会，不要只挑最长边把另外两维丢掉。",
                ],
            ],
            "codes": codesPayload,
            "service": ["configured": serviceConfigured, "notice": serviceNotice],
            "capability": capabilityPayload(capability),
            "local_normalization": [
                "by": "app",
                "axes": axes.map(\.id),
                "note": "轴由 app 在场景内归一（WorldPropSizePolicy.intended）；生成服务是否 echo 与场景里的尺寸无关，两件事不许混成一句。",
            ],
            "open_drafts": openDrafts,
            "single_source_of_truth": [
                "owner": toolName,
                "prompt_and_tool_text": "只指向这里，不再各存一份参数。",
            ],
        ]
    }

    static var codesPayload: [String: Any] {
        [
            Code.needsInput.rawValue: "信息不足（**不是错误**）：没有发出任何提交。按 needs 问用户一句，然后用 pending_id 续同一次委托。",
            Code.invalidSizeIntent.rawValue: "尺寸本身畸形（形状说不清：三轴的 mode=dimensions 与一根轴的 axis/meters 同时给；轴不是契约词；米数或毫米数不是数、越界；三轴缺一两维；出处是猜的；两个尺寸字段都给了）：这是调用方的问题，不是「再问一句」。（守护进程对「两种形状同时给」另有一个更具体的码：size_intent_shape_conflict。）",
            Code.invalidArguments.rawValue: "参数不符合工具 schema。",
            Code.staleWishSession.rawValue: "这一轮空间操作已停止。",
            Code.wishOperationFailed.rawValue: "宿主侧操作失败，原因见 message。",
            Code.delegationExpired.rawValue: "原委托已不可续（授权不在、过期或换了空间）：让用户重新说一次，绝不因此新建一次生成。",
            Code.delegationAlreadySubmitted.rawValue: "这份委托已经提交过（回执带 wish_id）：去查询原任务，不要重复生成。",
        ]
    }

    /// 能力块的序列化。`readable: false` ⇒ `axes: []`、上下界与 `applies` 为 `null`。
    static func capabilityPayload(_ capability: WishSizeIntentCapability) -> [String: Any] {
        switch capability {
        case .unreadable:
            [
                "readable": false,
                "axes": [String](),
                "min_meters": NSNull(),
                "max_meters": NSNull(),
                "applies": NSNull(),
                "note": "服务声明读不到：**不声称任何轴被支持**，线上不发这个键（字节与没有意图时逐位相同），提交本身照常 —— 协商失败的 fail-closed 方向是\"这一条不发\"，不是\"提交不发\"。",
            ]
        case let .declared(axes, minimum, maximum, applies):
            [
                "readable": true,
                "axes": axes,
                "min_meters": minimum,
                "max_meters": maximum,
                "applies": applies,
                "note": "服务自报的接受范围；`applies` = \(applies)（echo = 只收下并原样回显，不归一几何）。归一仍然由 app 做。",
            ]
        }
    }

    /// 一次「信息不足」的**成功**回执（`isError: false`）。
    ///
    /// 为什么走成功通道：宿主桥把 `isError` 翻成协议级 `ok:false + error.message`，
    /// 插件随即 `throw new Error(message)`（`ResidentDSHHostToolBridge.swift:391-395`、
    /// `:989-999`）。走错误通道的话，这个结构化体只会变成一段异常文本，
    /// "信息不足"就退化成"工具挂了"。
    static func needsInputPayload(need: Need, reason: NeedReason, name: String,
                                  pendingID: UUID?, attempt: Int,
                                  capability: WishSizeIntentCapability,
                                  unsupportedAxis: String? = nil,
                                  draft: [String: Any]? = nil,
                                  choices: [String]? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "ok": false,
            "code": Code.needsInput.rawValue,
            "status": Code.needsInput.rawValue,
            "needs": [need.rawValue],
            "reason": reason.rawValue,
            "question": question(for: need, name: name),
            "missing": missingEntries(for: need, why: whyText(for: reason, name: name), choices: choices),
            "options": [
                "axes": axes.map { ["id": $0.id, "title": $0.title, "example": $0.example] },
                "min_meters": minimumMeters,
                "max_meters": maximumMeters,
                "dimensions": [
                    "shape": "{\"mode\": \"\(dimensionsModeValue)\", \"millimeters\": {\"x\": 1443, \"y\": 862, \"z\": 302}, \"source\": \"user\"}",
                    "edges": dimensionEdges,
                    "order_note": dimensionOrderNote,
                    "min_millimeters": minimumMillimeters,
                    "max_millimeters": maximumMillimeters,
                ],
            ],
            "attempt": attempt,
            "ask_again": attempt <= 2,
            "action": "把 question 这一句问给用户（只问这一句），拿到答案后用同一个 pending_id 再调一次 submit_wish_generation。",
            "contract": toolName,
        ]
        if let pendingID { payload["pending_id"] = pendingID.uuidString }
        if let unsupportedAxis { payload["unsupported_axis"] = unsupportedAxis }
        if case let .declared(axes, _, _, _) = capability, !axes.isEmpty {
            payload["service_declared_axes"] = axes
        }
        if let draft { payload["draft"] = draft }
        if attempt > 2 {
            payload["guidance"] = "用户已经 \(attempt - 1) 次没有给尺寸：这一轮改用给选项的一句话（例如「大约 1 米，还是 30 厘米左右？」）；仍然不说就说明\"必须给一个尺寸才能制作\"并停下，不要替他猜。"
        }
        return payload
    }

    /// `missing[]`：字段路径与工具 schema 路径逐字一致（可直接照着拼补丁），
    /// 而 `question` 始终只有**一句** —— 结构化给模型、一句话给人。
    static func missingEntries(for need: Need, why: String, choices: [String]?) -> [[String: Any]] {
        // 「问哪一句」也由这里派生：轴的名字与例子来自 `axes`，不再手写第二份。
        let axisAsk = axes.map { "\($0.title)（\($0.example)）" }.joined(separator: "／")
        switch need {
        case .size:
            return [
                ["field": "size_intent.axis", "why": why, "ask": "按哪根轴：\(axisAsk)？", "choices": axes.map(\.id)],
                ["field": "size_intent.meters", "why": why, "ask": "多少米？", "choices": [String]()],
            ]
        case .sizeAxis:
            return [["field": "size_intent.axis", "why": why, "ask": "按哪根轴：\(axisAsk)？", "choices": axes.map(\.id)]]
        case .sizeMeters:
            return [["field": "size_intent.meters", "why": why,
                     "ask": "多少米？（\(metersText(minimumMeters))—\(metersText(maximumMeters))）", "choices": [String]()]]
        case .pendingId:
            return [["field": "pending_id", "why": why, "ask": "是哪一件？", "choices": choices ?? [String]()]]
        }
    }

    static func whyText(for reason: NeedReason, name: String) -> String {
        switch reason {
        case .unspecified: "用户还没说「\(name)」的尺寸；没有尺寸就无法决定它多大。"
        case .axisNotDeclared: "生成服务没有声明接受这根轴；照发会让整件任务被服务拒绝。"
        case .metersOutOfRange: "这个米数超出了生成服务声明的范围；照发会让整件任务被服务拒绝。"
        case .ambiguousDelegation: "同时有多件还没做完的委托，说不清这一句是在回答哪一件。"
        }
    }
}
