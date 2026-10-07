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

/// 一件物件身上「**它有屏幕、能播**」这件事，在 `read_owned_props` 回执里的形态。
///
/// 刻意定义在本文件里、只用 Foundation 类型：`tools/test-resident-prop-tools.swift`
/// 单独编译本文件 + 夹具，把 `Screen/**` 整条几何推断链拖进来只会让门禁红在与断言无关
/// 的地方。屏幕几何的**判据**仍然只有一处（`WorldScreenResolution.resolve`），
/// 这里只是它在回执里的那一行字。
///
/// ⚠️ 它**不是**"夸口"：只有屏幕功能点真的注册到这件物件上（几何解析成立）时才存在。
/// 没注册的物件根本构造不出这个值，回执里也就不写 `screen` 这个键。
struct ResidentPropScreenCapability: Equatable, Sendable {
    /// 物件元数据里那个键。字面量与 `WorldScreenMetadataKey.definition` 同一份。
    let key: String
    /// 几何出处（标定 / 推断 / 缺省）。不确定时**必须**说得出来源。
    let source: String
    /// 出处原话（`WorldScreenDefinition.note`）。
    let note: String
    /// 屏幕面宽高比。
    let aspect: Float

    /// 回执里那一行。`can_play: true` 是**结论**，不是承诺：
    /// 它只在几何成立时出现（见类型说明）。
    var payload: [String: Any] {
        [
            "key": key,
            "can_play": true,
            "source": source,
            "note": note,
            "aspect": String(format: "%.4f", aspect),
        ]
    }
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
    /// 「这一件现在是什么状态」——**唯一投影** `ResidentOwnershipProjection.row` 的注入点。
    ///
    /// 回执里那两句（`ownership_state` / `ownership_status`）必须与面板那一行、任务行
    /// 那一句**逐字同源**：所以桥自己**不判**状态、不存状态，只问这一处。
    /// 查不到（例如刚删掉的物件）就是 `nil` —— 那是"读不到"，回执里不写这两个键，
    /// 绝不编一句。
    private let ownershipRow: (String) -> OwnershipRow?
    /// 「这一件物件自己**有没有屏幕、能不能播**」——屏幕功能点运行时注册表的注入点。
    ///
    /// 与 `ownershipRow` 同一条纪律：桥**不判**、**不存**、**不猜**。真注册了才写
    /// `screen` 那一行；没注册就是 `nil`，回执里就不写这个键 —— 于是
    /// "居民敢不敢说能播"与"物件上到底有没有屏幕功能点"是同一件事，不可能各说各的。
    ///
    /// 现场（真机 2026-10-03）：居民读到 `interaction_status: appearance_only`、
    /// 回执里一件带功能的物件都没有，于是它答"这台电视在空间里登记的是纯外形摆件"。
    private let screenCapability: (String) -> ResidentPropScreenCapability?
    init(service: ResidentPropPlacementService, allowsMutation: Bool,
         isCurrent: @escaping () -> Bool, onChange: @escaping () -> Void = {},
         prepareMutation: @escaping (WorldPropLayoutCommand) async throws -> Void = { _ in },
         delegatedGrant: ResidentPropDelegatedGrant? = nil,
         resolveDelegatedGrant: @escaping (String, WorldPropPlacement) throws -> ResidentPropDelegatedGrant? = { _,_ in nil },
         recordDelegatedPlacement: @escaping (ResidentPropDelegatedGrant, WorldPropPlacement) throws -> Void = { _,_ in },
         ownershipRow: @escaping (String) -> OwnershipRow? = { _ in nil },
         screenCapability: @escaping (String) -> ResidentPropScreenCapability? = { _ in nil }) {
        self.service = service; self.allowsMutation = allowsMutation
        self.isCurrent = isCurrent; self.onChange = onChange
        self.prepareMutation = prepareMutation
        self.delegatedGrant = delegatedGrant
        self.resolveDelegatedGrant = resolveDelegatedGrant
        self.recordDelegatedPlacement = recordDelegatedPlacement
        self.ownershipRow = ownershipRow
        self.screenCapability = screenCapability
    }

    var tools: [ResidentWorldToolSession.AdditionalTool] {
        ["read_owned_props", "list_placement_surfaces", "preview_prop_placement", "apply_prop_placement", "withdraw_prop", "undo_prop_placement",
         "hold_prop", "adjust_held_prop_grip", "return_held_prop", "drop_held_prop", "enable_prop_capability", "delete_prop"].map { name in
            var properties: [String: Any] = [:]
            if ["preview_prop_placement", "apply_prop_placement", "withdraw_prop", "hold_prop", "adjust_held_prop_grip", "return_held_prop", "drop_held_prop", "enable_prop_capability", "delete_prop"].contains(name) {
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
                    "description": "挂点（**可省**，不写就是 rightHand）。取值只有 \(Self.slotChoicesText)：用户说「挂背后 / 挂腰上 / 拿手里」时选对应项；已经拿在手上的同一件物件换挂点时也用它。"]

            }
            if ["preview_prop_placement", "apply_prop_placement"].contains(name) {
                properties["surface_id"] = ["type": "string", "description": "list_placement_surfaces 返回的承托层编号（layer.<n>）。摆放是否成立由坐标决定。"]
                for key in ["x", "y", "z", "yaw"] { properties[key] = ["type": "number"] }
            }
            if name == "adjust_held_prop_grip" {
                for key in ["offset_x", "offset_y", "offset_z", "rotation_yaw"] { properties[key] = ["type": "number"] }
            }
            if Self.isMutation(name) {
                // ⚠️ 这里**只能**出现宿主校验器认得的键
                // （`ResidentDSHOriginalSchemaValidator.allowedSchemaKeys`）。`minimum` 属于
                // "不支持也不猜"的那一族：它不会在执行时被忽略，而是让**整条** schema 在派发前
                // 被判 `schema_unsupported`，于是这个工具**一次都执行不到**。
                //
                // 真机 2026-10-02 那两次"挂到身上被挡回"就是这么来的，逐字两条：
                //   ① `$.layout_revision: 含无法核验的约束键 minimum`（"工具描述有问题"）
                //   ② `$: 缺少必需属性 layout_revision`（agent 去掉它之后撞上的"缺参数"）
                // 下界仍然只有**一份判据**（`argumentVerdict`：非负整数），只是改由
                // `description` 教会 agent，而不是写一个宿主读不懂的键。
                properties["layout_revision"] = ["type": "integer",
                    "description": "布局版本（**必填**）：把 read_owned_props 回执里的 layout_revision **原样**填进来（非负整数；不许猜、不许用上一轮的旧值）。世界在这之间变过时会被拒绝，回执里会带最新版本号，读回来再试一次。"]
            }
            let descriptions = [
                "read_owned_props": "读取真实已拥有物件、是否摆出、位置、能力绑定、最近一次使用状态（running/completed/stopped/failed，以回执为准）与布局版本。每件物件的 `ownership_state`（机器读的一档）与 `ownership_status`（界面上那句话）来自**同一个**唯一投影，与「我的物件」列表那一行、任务行那一句**逐字同源**——对用户说状态时照它说，别自己另编一个词。每件物件的 `hold_slots` **逐挂点**给出「能不能挂在那个挂点上」以及那一个挂点自己的原因（手/背后/腰间各自具名，右手不行不代表背后不行）。`deleted` 列出已经被永久删除的物件（墓碑：名字、删除时的结算动作与理由、释放的内容引用）—— 已经删掉的东西不会出现在 objects 里。生成物件默认仅有外形；只有明确启用 coffee.brew 冲泡模板的咖啡机才可按模板在空间内模拟使用，不涉及现实硬件或物理结构。",
                "list_placement_surfaces": "读取可摆放的承托层：承托高度、格数与水平范围（不再逐个列出格子）。位置为底部中心，yaw 为弧度。",
                "preview_prop_placement": "只验证候选摆放，不改变世界、不显示预览。碰撞或通道错误可用于调整计划。",
                "apply_prop_placement": "按本轮人类摆放或移动委托提交已拥有物件的位置和朝向；后台仅可续办原生成任务仍有效的有限摆放委托，只能摆该产物到允许的支撑面。先查询布局版本和支撑面并预检，位置和朝向使用绝对值。",
                "withdraw_prop": "仅按本轮人类委托收回已拥有摆件，保留物件和来源，不删除或重新生成。",
                "undo_prop_placement": "仅按本轮人类要求撤销最近一次摆放或收回；只能撤销一步。",
                // 工具描述是 agent 真正读到的"能拿多大"：与判据**同源**（插值同一份上限），
                // 否则提示词说 1.6 m、工具描述说另一个数，agent 会照着错的那一份拒绝用户。
                "hold_prop": "仅按本轮人类明确要求，让当前已适配居民拿起 / 挂上一件最长边不超过\(ResidentPropAttachmentEligibility.holdableLongestEdgeText)的小道具展示。**必填两个**：object_id（read_owned_props 回执里的物件编号）与 layout_revision（**同一份**回执里的布局版本，原样填）。**挂点由 slot 决定，可省**：取值只有 \(Self.slotChoicesText)；用户说「挂背后 / 挂腰上 / 拿手里」就选对应项，**不写就是 rightHand（拿在右手）**，已经拿在手上的同一件物件换挂点也用它。用户说「重新握好 / 握把位置不对 / 拿住剑柄」时，先用最新 read_owned_props 确认该物件仍由当前居民持有；已放回时报告现状，不重放旧拿取。仍持有时，同一 object_id、slot=rightHand 会按经验证网格重新计算 normalizedGrip 与朝向，走 adjustGrip 原地保存，不先放回、不重新生成；offset 微调无法完成这件事。物件保持同一身份并保留原放回位置。read_owned_props 的回执里 `hold_slots` **逐挂点**给出可用性与各自的原因：右手不行**不代表**背后或腰间不行，别拿一个挂点的答案替用户回答另一个挂点；失败回执里的 slot/slot_name 是这次**真正**按哪个挂点算的（没给 slot 时就是省缺的右手）。",
                "adjust_held_prop_grip": "仅按本轮人类要求，微调**当前挂点**上那件道具相对该挂点骨骼的米制偏移和局部旋转。**必填**：object_id（read_owned_props 回执里的物件编号）、layout_revision（同一份回执里的布局版本，原样填）、以及 offset_x / offset_y / offset_z（米）与 rotation_yaw（弧度）—— 四个都是**绝对值**，不是增量。先读取当前握点再给。它保留 normalizedGrip，无法纠正握在剑尖或重新选择柄部。用户说「重新握好 / 握把位置不对 / 拿住剑柄」时，调用 hold_prop，对已持有的同一 object_id 设置 slot=rightHand，按经验证网格重新标定完整握点；不要用本工具替代。换挂点也用 hold_prop 的 slot。",
                "return_held_prop": "仅按本轮人类要求把当前挂载的道具精确放回拿起前的位置。**必填**：object_id（read_owned_props 回执里的物件编号）与 layout_revision（同一份回执里的布局版本，原样填）。原来在库存则回库存，不接受放回坐标。",
                "drop_held_prop": "仅按本轮人类要求就近放下当前手持道具。服务自动选择居民身边0.6米内最近的合法真实承托位置，验证地面、整块占地、角色及其他物件碰撞和通路；没有安全位置时仍拿在手中。用户说「放下/放身边」优先用这个；说「放回原位」用return_held_prop。必填object_id与最新layout_revision，不接受远处坐标，不收进库存。",
                "enable_prop_capability": "仅按本轮人类明确要求使用某物件时，为已拥有摆件启用受支持的使用能力模板（当前仅支持 coffee.brew 冲泡模板）。能力持久化；启用后通过 start_activity 走到物件前面向它执行按钮动作并等待播放完成，属于空间内模拟使用，不宣称物理冲煮结构。按名字猜想的物件不得启用。",
                // 删除是**永久**的：描述里逐字写出来，agent 才不会把它当成又一次"收回"。
                "delete_prop": "仅按本轮人类明确要求，**永久删除**一件已拥有的生成资产（不可恢复，没有撤销）。先用 read_owned_props 确认是哪一件。删除会自动收场：正在房间里摆着的、正拿在居民手里的或挂在身上的，都会在同一次提交里先收回/放回再删掉，不需要先调用 withdraw_prop 或 return_held_prop。回执里会说明删了什么、做了哪种收场、以及释放了哪些共享内容（还被别的物件引用的内容一律保留，不会误删）。只有这一件物件独占的内容才会进入可回收集合。删除后该物件不再出现在库存与回执的 objects 里，而是出现在 deleted 里。"
            ]
            let description = descriptions[name]! + (name == "hold_prop"
                ? " 已摆物件首次拿取必须在真实占地外缘 \(WorldPropActivityTemplate.interactionReach) 米内；远处先 move_to(place_id: object_id)，等 inspect_world 确认到达，再读取最新 read_owned_props 的 layout_revision 后拿取。prop_out_of_reach 是需要走近，不能用撤回库存来绕过距离。库存取出与当前持有同件的重新握持无需再次走近。"
                : "")
            return .init(name: name, description: description, inputSchema: [
                "type": "object", "properties": properties,
                // `slot` 是 hold_prop 上**唯一可省**的参数：不写就是右手。
                "required": properties.keys.filter { !(name == "hold_prop" && $0 == "slot") }.sorted(),
                "additionalProperties": false
            ], validate: { Self.validate($0, name: name) }, handle: { [self] id, data in await handle(name, id, data) })
        }
    }

    private static func isMutation(_ name: String) -> Bool {
        ["apply_prop_placement", "withdraw_prop", "undo_prop_placement", "hold_prop", "adjust_held_prop_grip", "return_held_prop", "drop_held_prop", "enable_prop_capability", "delete_prop"].contains(name)
    }
    /// 挂点那三个取值的**人话名**（"rightHand（右手） / back（背后） / waist（腰间）"）。
    ///
    /// 取值表只有一处来源 `PropAttachmentSlots`：schema 的 `enum`、参数与工具描述、
    /// 传错参数时的失败回执，读的都是它 —— 三处不可能各说一套。
    private static var slotChoicesText: String {
        PropAttachmentPoint.allCases
            .map { "\($0.worldSlot.rawValue)（\(PropAttachmentSlots.displayName(for: $0))）" }
            .joined(separator: " / ")
    }

    /// 一次调用的**参数裁决**：不是一句 Bool，而是"哪儿不对、该怎么改"。
    ///
    /// 判据只有这一份：`validate`（宿主侧 `AdditionalTool.validate` 的 Bool 合同）与
    /// 失败回执（agent 读到的那一句话）都从它派生。所以"拒绝的理由"与"回执教他怎么改"
    /// 不可能分叉，也不会多出第二套必填 / 可选表。
    ///
    /// 真机 2026-10-02：`hold_prop` 两次被系统挡回，而回执只有一句笼统的
    /// "摆放参数无效，请查询当前物件和支撑面"，agent 不知道该改哪个参数 —— 对治就是这里。
    private enum ArgumentVerdict: Equatable {
        case accepted
        /// 缺的**必填**参数（按声明序）。
        case missing([String])
        /// **未声明**的参数（按键名序）。
        case unknown([String])
        /// 哪个参数、期望什么。
        case badValue(parameter: String, expectation: String)
    }

    /// 这个工具的**必填**参数 —— 与 schema 的 `required` 是同一份（见 `tools` 里那行 filter）。
    private static func declaredKeys(_ name: String) -> Set<String> {
        var keys = Set<String>()
        if ["preview_prop_placement", "apply_prop_placement", "withdraw_prop", "hold_prop", "adjust_held_prop_grip", "return_held_prop", "drop_held_prop", "enable_prop_capability", "delete_prop"].contains(name) { keys.insert("object_id") }
        if name == "enable_prop_capability" { keys.insert("capability") }
        if name == "delete_prop" { keys.insert("reason") }
        if ["preview_prop_placement", "apply_prop_placement"].contains(name) { keys.formUnion(["surface_id", "x", "y", "z", "yaw"]) }
        if name == "adjust_held_prop_grip" { keys.formUnion(["offset_x", "offset_y", "offset_z", "rotation_yaw"]) }
        if isMutation(name) { keys.insert("layout_revision") }
        return keys
    }
    /// 可省的业务参数只有两个：`hold_prop` 的 `slot`（省缺 = rightHand）与
    /// `delete_prop` 的 `reason`（省缺 = 没给理由）。别的参数一个都不许省。
    private static func optionalKeys(_ name: String) -> Set<String> {
        name == "hold_prop" ? ["slot"] : []
    }

    /// 传错参数时回执里"该怎么改"那句话。**取值表只有一处来源**：挂点读
    /// `PropAttachmentSlots`（和 schema 的 `enum`、工具描述同一份），其余是"去哪儿读、什么类型"。
    private static func guidance(parameter: String) -> String {
        let templates = WorldPropActivityTemplate.supported.keys.sorted().joined(separator: " / ")
        switch parameter {
        case "slot":
            return "slot 只能取 \(slotChoicesText)；用户说「挂背后 / 挂腰上 / 拿手里」时选对应项，**不写就是 rightHand**。"
        case "layout_revision":
            return "layout_revision 必须是**非负整数**，而且要**原样**取 read_owned_props 回执里的那一个（不是猜的、不是上一轮的旧值）；被拒时回执里带最新版本号，读回来再试。"
        case "object_id":
            return "object_id 取 read_owned_props 回执里 objects[].object_id 的**原文**（非空字符串）。"
        case "surface_id":
            return "surface_id 取 list_placement_surfaces 回执里的承托层编号（layer.<n>）。"
        case "capability":
            return "capability 取该物件 read_owned_props 回执里 capability.template_id（当前支持：\(templates)）。「按名字猜一个能力」一律不启用。"
        case "reason":
            return "reason 是（可省的）删除理由：用户说了为什么就照实写、最多 200 字；没说就不写，绝不替他编一个。"
        default:
            return "\(parameter) 必须是有限数字（number），不接受字符串、布尔或 null。"
        }
    }

    private static func argumentVerdict(_ values: [String: Any], name: String) -> ArgumentVerdict {
        let declared = declaredKeys(name)
        let allowed = declared.union(optionalKeys(name))
        // 键集合的判据（与旧 `validate` 逐位等价）：必填一个都不能少、未声明的键一个都不能多。
        let missing = declared.subtracting(values.keys).sorted()
        if !missing.isEmpty { return .missing(missing) }
        let unknown = Set(values.keys).subtracting(allowed).sorted()
        if !unknown.isEmpty { return .unknown(unknown) }
        for key in values.keys.sorted() {
            if ["object_id", "surface_id", "capability", "slot", "reason"].contains(key) {
                guard let text = values[key] as? String, !text.isEmpty, text.count <= 256 else {
                    return .badValue(parameter: key, expectation: guidance(parameter: key))
                }
                // 删除理由的**判据只有一处**（世界层 `WorldSimulation` 的 200 字上限）：
                // 这里只做"是个不空的字符串"，长度由那条命令自己拒绝并给出可读原因。
                if key == "reason", name == "delete_prop", text.trimmingCharacters(in: .whitespacesAndNewlines).count > 200 {
                    return .badValue(parameter: key, expectation: guidance(parameter: key))
                }
                // 挂点名必须**认识**：认不出来的就地拒绝，绝不猜一个挂点出来。
                if key == "slot", PropAttachmentSlots.resolve(name: text) == nil {
                    return .badValue(parameter: key, expectation: guidance(parameter: key))
                }
            } else {
                guard let number = values[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                    return .badValue(parameter: key, expectation: guidance(parameter: key))
                }
                if key == "layout_revision" {
                    guard number.doubleValue >= 0, number.doubleValue < Double(UInt64.max), number.doubleValue.rounded() == number.doubleValue else {
                        return .badValue(parameter: key, expectation: guidance(parameter: key))
                    }
                }
            }
        }
        return .accepted
    }
    private static func validate(_ values: [String: Any], name: String) -> Bool {
        argumentVerdict(values, name: name) == .accepted
    }

    /// 传错参数时的回执：**哪个参数、期望什么、该怎么改**，一句到位。
    ///
    /// `message` 保留既有的那句前缀（"摆放参数无效…"），后面接上可行动的那一半；
    /// 机器读的字段（`missing` / `unknown` / `parameter` / `how_to_fix`）同时给出，
    /// 别处不必解析中文，`code` 仍是既有的 `invalid_arguments`。
    private static func invalidArgumentsReceipt(_ verdict: ArgumentVerdict, name: String) -> [String: Any] {
        var payload: [String: Any] = ["ok": false, "code": "invalid_arguments"]
        let howToFix: String
        switch verdict {
        case .accepted:
            // 调用方只在非 accepted 时进来；这里仍给一句实话，不编。
            howToFix = "参数没有通过本工具的校验。"
        case let .missing(keys):
            payload["missing"] = keys
            howToFix = "缺少必填参数：" + keys.map { "\($0) —— \(guidance(parameter: $0))" }.joined(separator: "；")
        case let .unknown(keys):
            payload["unknown"] = keys
            let declared = declaredKeys(name).union(optionalKeys(name)).sorted()
            howToFix = "不认识参数 \(keys.joined(separator: " / "))；本工具只接受 \(declared.joined(separator: " / "))。"
        case let .badValue(parameter, expectation):
            payload["parameter"] = parameter
            howToFix = "参数 \(parameter) 的取值不对：\(expectation)"
        }
        payload["how_to_fix"] = howToFix
        payload["message"] = "摆放参数无效，请查询当前物件和支撑面。\(howToFix)"
        return payload
    }

    private func handle(_ name: String, _ callID: String, _ data: Data) async -> RealtimeDJToolResult {
        func result(_ payload: [String: Any], error: Bool = false) -> RealtimeDJToolResult {
            .init(callID: callID, resultJSON: (try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)) ?? Data("{}".utf8), isError: error)
        }
        guard !Task.isCancelled, isCurrent() else { return result(["ok": false, "code": "stale_prop_session", "message": "本轮空间操作已停止。"], error: true) }
        guard let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return result(["ok": false, "code": "invalid_arguments",
                "message": "摆放参数无效，请查询当前物件和支撑面。参数必须是一个 JSON 对象（键值对），本工具不接受数组或裸值。"], error: true)
        }
        let verdict = Self.argumentVerdict(values, name: name)
        guard verdict == .accepted else {
            // 失败信息必须**可行动**：agent 读了就知道该改哪个参数、改成什么。
            return result(Self.invalidArgumentsReceipt(verdict, name: name), error: true)
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
            } else if name == "drop_held_prop" {
                let command = try service.dropHeldCommand(objectID:values["object_id"] as! String)
                try await prepareMutation(command)
                guard !Task.isCancelled, isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
                try service.commit(command,expectedLayoutRevision:(values["layout_revision"] as! NSNumber).uint64Value,requestID:callID)
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
                                   holdUnavailableBySlot: Self.holdUnavailableBySlot(service, objectID: objectID),
                                   ownership: ownershipRow(objectID),
                                   screen: screenCapability(objectID))
            }
            // 「这个空间里有没有一件东西是**真的能用**的」——`appearance_only` 的意思是
            // "每一件都只是外形"。这句话原先只数 `capability`（咖啡机那条绑定能力），
            // 于是屋里摆着一台**有屏幕、能播**的电视时它照样说 `appearance_only`：
            // 真机 2026-10-03 居民就是读着它答出"这台电视在空间里登记的是纯外形摆件"的。
            // 屏幕功能点注册了 ⇒ 这句话就不再成立。判据仍然只有一处（有没有那个键），
            // 不为屏幕另造一套状态词。
            let hasUsableCapability = objects.contains {
                $0["capability"] != nil || $0["screen"] != nil
            }
            let interactionStatus = hasUsableCapability
                ? "capability_bound_use_only" : "appearance_only"
            var payload: [String: Any] = ["ok": true, "layout_revision": service.context.state.layoutRevision,
                "objects": objects, "can_undo": service.context.state.layoutUndo != nil,
                "mutation_authorized": allowsMutation, "interaction_status": interactionStatus]
            if name == "return_held_prop" || name == "drop_held_prop",
               let id = values["object_id"] as? String,let item = service.context.state.objectStates[id] {
                payload["release_disposition"] = name == "drop_held_prop" ? "dropped_nearby" : (item.isEnabled ? "returned_to_origin" : "returned_to_inventory")
                payload["released_object_id"] = id
                payload["released_position"] = ["x":item.transform.position.x,"y":item.transform.position.y,"z":item.transform.position.z]
            }
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
            case ResidentPropPlacementError.objectOutOfReach: code = "prop_out_of_reach"
            default: code = "placement_rejected"
            }
            var failure: [String: Any] = ["ok": false, "code": code, "message": error.localizedDescription,
                           "layout_revision": service.context.state.layoutRevision]
            if case let ResidentPropPlacementError.objectOutOfReach(objectID, distance) = error {
                failure["required_place_id"] = objectID
                failure["distance_to_edge_meters"] = distance
                failure["maximum_edge_distance_meters"] = WorldPropActivityTemplate.interactionReach
                failure["next_step"] = "move_to(place_id: required_place_id)，等 inspect_world 确认到达后再用最新布局版本 hold_prop。"
            }
            // 失败回执**总是**带上挂点名 —— 包括调用方**没给** `slot` 的时候（那时省缺是右手）。
            // 只带一半（传了才带）会让"系统在按右手算"这件事在回执与日志里都看不见。
            if name == "hold_prop" {
                let declared = values["slot"] as? String
                let point = declared.flatMap(PropAttachmentSlots.resolve(name:)) ?? .rightHand
                failure["slot"] = point.worldSlot.rawValue
                failure["slot_name"] = PropAttachmentSlots.displayName(for: point)
                failure["slot_source"] = declared == nil ? "省缺（调用方没有给挂点）" : "调用方指定的挂点：\(declared!)"
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
                               holdUnavailableBySlot: [String: String],
                               ownership: OwnershipRow? = nil,
                               screen: ResidentPropScreenCapability? = nil) -> [String: Any]? {
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
        // 屏幕功能点：**只有这件物件真的有屏幕**时才写这一行（`screen` 由运行时注册表
        // 现取，桥自己不判）。没有屏幕的物件不会被说成"能播" —— 判据是"注册表里有没有
        // 这一件"，不是"名字里像不像电视"。
        if let screen {
            result["screen"] = screen.payload
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
        // 状态那两句**逐字**来自唯一投影（`OwnershipSentence`，与面板那一行、任务行那一句
        // 同一份字面量）：agent 读到的状态与用户看到的因此不可能各说各的。
        // `ownership_state` 是机器读的那一档（`OwnershipDisplayState.rawValue`），
        // `ownership_status` 就是界面上那句话。
        //
        // 投影查不到这一件（例如刚被删掉）时**不写键**：那是"读不到"，
        // 不是编一句"看起来差不多"的话。
        if let ownership {
            result["ownership_state"] = ownership.state.rawValue
            result["ownership_status"] = ownership.statusText
        }
        return result
    }
}
