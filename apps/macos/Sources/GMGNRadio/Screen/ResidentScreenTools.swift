import Foundation

// MARK: - 屏幕控制面（面板与 agent 工具共用的**唯一**入口）

/// 一台电视在面板/回执里的样子。只读快照，不含任何 UI 类型。
struct WorldScreenSnapshot: Equatable, Sendable {
    let objectID: String
    let displayName: String
    /// 几何出处（标定 / 推断 / 缺省）。
    let source: WorldScreenSource?
    /// 几何出处的**原话**。缺省与推断时**日志与 agent 回执**必须显示它（"不猜"要看得见）。
    ///
    /// ⚠️ 它**不进面板**：那句话是给工程的（"法向 +Z、面积 1.244 m²、24 × 14 格、117.98 ms"
    /// 这一族）。面板要的是 `ScreenPanelCopy.screenRangeLine(source:hasGeometryIssue:)`
    /// 那一句人话 —— 真机 2026-10-02 用户原话：「不要搞为什么然后给展开折叠，普通人看得懂吗，
    /// 里面一堆 key-value 的东西」。
    let note: String
    let aspect: Float
    /// 几何给不出来时的具名原因。
    let geometryIssue: WorldScreenGeometryIssue?
    /// 当前内容（官方嵌入 URL）。
    let contentURL: String?
    /// 状态的一行话（工具/日志口径）。
    let stateText: String
    let isPlaying: Bool
    /// **前景遮挡**的一行账（"挡了 63/336 格" + 掩码耗时）。`nil` = 还没算过。
    ///
    /// 它是"角色站在屏前时屏幕被裁掉哪一块"在**工具回执与日志上**的唯一出口 ——
    /// 没有它，遮挡做没做在外面就是看不见的。刻意带默认值：既有构造点（含判据里的
    /// 替身）一个都不用改，而新调用点显式给值。
    ///
    /// ⚠️ 与 `note` 同理：带格数与毫秒的账**不进面板**（面板读 `isBlocked`）。
    var occlusionText: String? = nil
    /// 这一帧这块屏幕**是不是真的有一部分被前面的东西挡住了**。
    ///
    /// 面板据此说**一句**人话，而且只在真被挡时说（`ScreenPanelCopy.occlusionLine`）。
    /// 它是个 `Bool` 而不是那句账：账里有格数、有毫秒，每帧都在变 —— 直接显示就是刷屏。
    /// 默认 `false`，既有构造点一个都不用改。
    var isBlocked: Bool = false
    /// 状态的**值本身**，面板据此说人话（`ScreenPanelCopy.statusLine`）。
    ///
    /// 为什么不复用 `stateText`：那一份是工程口径（带 host、带 HTTP 码、带 WebKit 的原因），
    /// 面板要的是"这台电视现在放不出来，大概因为什么"。默认 `nil`，既有构造点不用改。
    /// 声明在最后（带默认值的那几个一起）：既有构造点的实参顺序一个都不用动。
    var surfaceState: WorldScreenSurfaceState? = nil
}

// MARK: - 面板上给**普通人**看的那几句话

/// 电视面板上所有给用户看的字 —— **唯一**一份，纯函数、无 UI、可离线逐字断言。
///
/// ## 为什么要把"字"抽出来
///
/// 真机 2026-10-02，面板上摆着的是这样的东西：
///
/// ```text
/// 平面电视  [推断]
/// 由最大平坦面推断：法向 +Z（正面），面积 1.244 m²（1.24 m × 0.74 m）。不是标定值，可在面板里改。
/// 前景遮挡：24 × 14 格全部可见（117.98 ms）
/// ```
///
/// 用户的原话是「**什么玩意儿**」，以及上一轮同一件事的说法：「不要搞为什么然后给展开折叠，
/// 普通人看得懂吗，里面一堆 key-value 的东西」。这段话里**没有一个字**是用户要的：
/// 他不知道"法向"、不关心"面积 1.244 m²"，"24 × 14 格 / 117.98 ms"更是**调试读数**。
///
/// 所以分工是这样切的，而且只有这一处切：
///
/// | 谁看 | 看什么 | 在哪 |
/// |---|---|---|
/// | 用户 | 这台叫什么 / 屏幕是自动认出来的还是你标定的 / 能不能放 | 本枚举 |
/// | 工程 | 法向、面积、来源、格数、毫秒 | `WorldScreenSnapshot.note` /
///   `.occlusionText` / `.stateText` → 日志（`subsystem = ai.gmgn.radio`）与 agent 工具 |
///
/// ## 三条纪律
///
/// 1. **没有人话就不说**：`occlusionLine` 在不被挡时返回 `nil`（面板一个像素都不占）；
/// 2. **只说一次、不刷屏**：`occlusionLine` 返回的是一个**常量**句子 —— 没有格数、没有
///    毫秒，所以它在被挡的整段时间里**逐字不变**（每帧都在变的数字才会刷屏）；
/// 3. **不出现工程术语**：法向 / 面积 / m² / 格 / ms / `key=value` 一个都不许有，
///    `tools/test-resident-screen-overlay.swift` 的"面板文案"那一条逐字扫。
enum ScreenPanelCopy {
    /// 「这块屏幕的范围是哪来的」——一句话，人话。
    ///
    /// 判据一字未动：`source` 还是那个三级出处（标定 / 推断 / 缺省），这里只换说法。
    /// `hasGeometryIssue` 为真时出处根本不存在（连猜都猜不出来），所以单独一句。
    static func screenRangeLine(source: WorldScreenSource?, hasGeometryIssue: Bool) -> String {
        if hasGeometryIssue {
            return "屏幕范围：还没认出来 —— 点「调整屏幕范围」告诉它屏幕在哪。"
        }
        switch source {
        case .calibrated: return "屏幕范围：你标定的。"
        case .inferred: return "屏幕范围：自动识别。"
        case .default: return "屏幕范围：自动识别的（大致位置，可以调）。"
        case nil: return "屏幕范围：还没认出来 —— 点「调整屏幕范围」告诉它屏幕在哪。"
        }
    }

    /// 「这块屏幕现在怎么样」——一句话，人话。`nil` = 播放中，画面本身就是状态。
    static func statusLine(for state: WorldScreenSurfaceState?, isPlaying: Bool) -> String? {
        guard !isPlaying else { return nil }
        guard let state else { return "还没放东西 —— 粘一个链接，按「放」。" }
        switch state {
        case .idle: return "还没放东西 —— 粘一个链接，按「放」。"
        case .loading: return "正在打开，请稍等。"
        case .playing: return nil
        case .stopped: return "已经停了。"
        case let .failed(failure): return failure.panelText
        }
    }

    /// 「画面被挡住了」——**只在真的被挡时**给一句，而且每次都是**同一句**。
    ///
    /// 被挡是常态里的一件小事（居民从屏前走过），所以它不该有数字、不该有区域、
    /// 更不该每帧换一个说法。面板把它显示成一行就好。
    static func occlusionLine(isBlocked: Bool) -> String? {
        isBlocked ? "画面有一部分被前面挡住了。" : nil
    }

    /// 面板上那三个动作的名字。放 / 停 / 标定 —— 第三个说人话。
    static let playActionTitle = "放"
    static let stopActionTitle = "停"
    static let adjustRangeActionTitle = "调整屏幕范围"
    /// 换片输入框的提示（"官方嵌入链接"是工程话，用户只知道"视频链接"）。
    static let contentPlaceholder = "粘贴视频链接（YouTube、哔哩哔哩、Twitch）"
    /// 面板上唯一一处提到"同时能放几台"的话。
    static func capacityLine(maximum: Int) -> String {
        "同时最多放 \(maximum) 台；看不见的会自动暂停（不影响登录）。"
    }
}

/// 一条命令的结果。`isError == false` 且 `code == insufficient_input` 表示**信息不足**：
/// 这是**成功**通道（与 `WishMachineContract.Code.needsInput` 同一语义、同一字面量）。
struct WorldScreenCommandOutcome: Equatable, Sendable {
    enum Code: String, Sendable {
        case ok
        case insufficientInput = "insufficient_input"
        case screenGeometryMissing = "screen_geometry_missing"
        case screenContentRejected = "screen_content_rejected"
        case screenNotFound = "screen_not_found"
        case screenLoadFailed = "screen_load_failed"
        case screenCapacityExceeded = "screen_capacity_exceeded"
        /// 屏幕**功能点是真的**（几何解析出来了、`read_owned_props` 里读得到），
        /// 但贴画面的那一层还没接上（舞台窗口一次都还没出现过）。
        ///
        /// 它与 `screenNotFound` 是两件事，必须分开：前者说"这件东西不是屏幕"，
        /// 后者说"这件东西是屏幕，画面还挂不上去"。混成一句会让居民把"窗口没开"
        /// 说成"这台电视不能放" —— 真机 2026-10-03 用户撞到的正是这个形状。
        case screenSurfaceUnavailable = "screen_surface_unavailable"
        case invalidArguments = "invalid_arguments"

        /// 只有"信息不足"走成功通道。其余都是错误 —— 不许把失败伪装成成功。
        var isError: Bool { self != .ok && self != .insufficientInput }
    }

    let code: Code
    /// 给用户/agent 的**一句**人话。与面板那一行是同一份文案。
    let message: String
    /// 结构化补充（`screen_id` / `url` 之类），可为空。
    let details: [String: String]

    static func ok(_ message: String, details: [String: String] = [:]) -> Self {
        Self(code: .ok, message: message, details: details)
    }

    static func needsInput(_ message: String, details: [String: String] = [:]) -> Self {
        Self(code: .insufficientInput, message: message, details: details)
    }

    static func failure(_ code: Code, _ message: String, details: [String: String] = [:]) -> Self {
        Self(code: code, message: message, details: details)
    }
}

/// 一件**看起来该有屏幕、但还没被认成屏幕**的物件（从运行时注册的物件状态里来）。
///
/// `read_screen` 靠它回答「有没有、是哪一件」里那个「哪一件」：没有它，工具只能说
/// "这个空间里没有电视"，而说不出**是哪件**物件、为什么。
///
/// `reason` 必须是**运行时**给出的具名原因（名字不像电视 / 板形或尺寸不够 / 已收回）。
/// 工具层与表述层都不得自己编一句 —— 编出来的原因会让居民把"名字里没有电视"说成
/// "这台电视坏了"，用户据此去修一台根本没坏的东西。
struct WorldScreenCandidate: Equatable, Sendable {
    let objectID: String
    let displayName: String
    /// 具名原因（人话，来自运行时注册与几何判据）。
    let reason: String
}

/// 屏幕的**控制面**。`WorldScreenStore` 是生产实现；harness 用替身。
@MainActor
protocol WorldScreenControlling: AnyObject {
    func listScreens() -> [WorldScreenSnapshot]
    /// 空间里**还没被认成屏幕**的物件（各带一句具名原因），只从运行时注册表来。
    ///
    /// 刻意是**必答**的（没有默认实现）：一个拿不到这份信息的实现不许猜 —— 猜出来
    /// 的"是哪一件"与编造没有区别。
    func unrecognizedScreenCandidates() -> [WorldScreenCandidate]
    /// `rawContent` 可以是官方嵌入链接、公开观看链接或裸 id；白名单校验由实现负责。
    ///
    /// 异步的：实现会等一小段时间（≤3 s）看嵌入页是**立刻**失败（网络不通 / 4xx /
    /// 被拒）还是真的开始加载，于是"放不出来"能在**这一次调用**里具名报出去，
    /// 而不是留给 `read_screen` 去发现。
    func playScreen(objectID: String?, rawContent: String) async -> WorldScreenCommandOutcome
    func stopScreen(objectID: String?) -> WorldScreenCommandOutcome
    /// 手动标定（米）。这是"① 用户/编辑器标定"那一级的入口。
    func calibrateScreen(
        objectID: String, widthMeters: Float, heightMeters: Float, centerHeightMeters: Float
    ) async -> WorldScreenCommandOutcome
}

// MARK: - 工具声明

/// 一条 agent 工具。**不依赖** `ResidentWorldToolSession`：回执用本文件自带的
/// `WorldScreenToolReply`，App 侧一行适配即可（见粘贴补丁）。这样这个文件能被
/// 离线 harness 直接编译，而工具的形状与 `AdditionalTool` 一一对应。
struct WorldScreenTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let handle: @MainActor (String, Data) async -> WorldScreenToolReply
}

/// 工具回执。`payloadJSON` 直接进 agent 的账本。
struct WorldScreenToolReply {
    let payloadJSON: Data
    let isError: Bool
    let code: String
}

/// `play_screen` / `stop_screen` / `read_screen` 的**唯一**实现处。
///
/// 三条工具与"信息不足走成功通道"是**同一份**判据里的东西：
/// 缺 URL 不是失败，是"还没说"（`insufficient_input`，`isError: false`）。
@MainActor
final class ResidentScreenTools {
    static let playName = "play_screen"
    static let stopName = "stop_screen"
    static let readName = "read_screen"
    static var toolNames: [String] { [playName, stopName, readName] }

    private let control: any WorldScreenControlling
    private let isCurrent: @MainActor () -> Bool

    init(control: any WorldScreenControlling, isCurrent: @escaping @MainActor () -> Bool) {
        self.control = control
        self.isCurrent = isCurrent
    }

    var tools: [WorldScreenTool] {
        // **强引用**捕获 `control` / `isCurrent`，不捕获 `self`：
        // 调用方通常只留住这个数组（`additionalTools + screenTools`），
        // `[weak self]` 会让工具在创建它的那一刻就变成永远失败的哑工具
        // （`guard let self else` 命中的是"本轮已经结束"）。
        // 这个坑在第一次跑 harness 时就被抓到了（四条"应该成功"的断言全红）。
        let control = self.control
        let isCurrent = self.isCurrent
        return [
            WorldScreenTool(
                name: Self.playName,
                description: "把这个空间里的一台电视打开、放用户给的视频链接。"
                    + "用户说「用电视放这个链接」「投到电视上」「电视播放这个链接」时就用它，"
                    + "url 直接给用户给的那个链接就行（YouTube、哔哩哔哩、Twitch 的官方嵌入链接、"
                    + "公开观看链接或视频 id 都接受）。"
                    + "空间里只有一台电视时可以省略 object_id。"
                    + "放不了时回执会说明是哪一件物件、为什么放不了、该怎么改，把这三样转告用户。"
                    + "只说「放个视频」而没给内容时会返回 insufficient_input（信息不足，不是失败），"
                    + "这时问用户要一个链接。"
                    + "不许抓流、不许绕过登录或地区限制。",
                inputSchema: Self.schema(
                    properties: [
                        "object_id": [
                            "type": "string",
                            "description": "哪一台电视。空间里只有一台时可以省略。",
                        ],
                        "url": [
                            "type": "string",
                            "description": "官方嵌入链接、公开观看链接，或裸视频 id（YouTube 11 位 / 哔哩哔哩 BV 号）。",
                        ],
                    ],
                    required: ["url"]
                ),
                handle: { _, arguments in
                    await Self.play(control: control, isCurrent: isCurrent, arguments: arguments)
                }
            ),
            WorldScreenTool(
                name: Self.stopName,
                description: "关掉这个空间里的一台电视：停止播放并回到黑屏。"
                    + "用户说「关掉电视」「别放了」时用它。object_id 省略时关掉唯一的那一台。",
                inputSchema: Self.schema(
                    properties: ["object_id": ["type": "string", "description": "哪一台电视。"]],
                    required: []
                ),
                handle: { _, arguments in
                    Self.stop(control: control, isCurrent: isCurrent, arguments: arguments)
                }
            ),
            WorldScreenTool(
                name: Self.readName,
                description: "先看这个空间里有没有带屏幕的物件、是哪一件、现在放的是什么。"
                    + "用户让你放视频而你不确定哪一件能放时，先调它看一眼。"
                    + "它会列出每件的屏幕范围是怎么来的、当前的视频和播放状态。"
                    + "一件都没有时会说明是哪件物件还没被认成屏幕、以及怎么改。只读，不改变任何东西。",
                inputSchema: Self.schema(properties: [:], required: []),
                handle: { _, _ in Self.read(control: control) }
            ),
        ]
    }

    // MARK: 三条工具

    private static func play(
        control: any WorldScreenControlling,
        isCurrent: @MainActor () -> Bool,
        arguments: Data
    ) async -> WorldScreenToolReply {
        guard isCurrent() else {
            return reply(.failure(.invalidArguments, "本轮对话已经被替换，这次操作没有生效。"))
        }
        let object = string(arguments, "object_id")
        let raw = string(arguments, "url") ?? ""
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return reply(.needsInput(
                WorldScreenContentIssue.missingInput.errorDescription,
                details: ["screens": String(control.listScreens().count)]
            ))
        }
        return reply(await control.playScreen(objectID: object, rawContent: raw))
    }

    private static func stop(
        control: any WorldScreenControlling,
        isCurrent: @MainActor () -> Bool,
        arguments: Data
    ) -> WorldScreenToolReply {
        guard isCurrent() else {
            return reply(.failure(.invalidArguments, "本轮对话已经被替换，这次操作没有生效。"))
        }
        return reply(control.stopScreen(objectID: string(arguments, "object_id")))
    }

    private static func read(control: any WorldScreenControlling) -> WorldScreenToolReply {
        let screens = control.listScreens()
        // 「是哪一件」只能从**运行时注册表**来：`listScreens()` 是能被放的，候选是
        // 看起来像屏幕但还没被认成屏幕的。两条都从 control 现取，一个字都不写死。
        let candidates = control.unrecognizedScreenCandidates()
        guard !screens.isEmpty else {
            return reply(.needsInput(
                screenlessMessage(candidates),
                details: [
                    "screens": "0",
                    "unrecognized": String(candidates.count),
                    "unrecognized_ids": candidates.map(\.objectID).joined(separator: ","),
                ]
            ))
        }
        // 只读工具**必须真的把状态带回去**：只报一个数量，agent 就拿不到
        // "这块屏的几何是猜的 / 现在放的是什么 / 失败原因是什么"这几件它要判断的事。
        var payload: [String: Any] = [
            "code": WorldScreenCommandOutcome.Code.ok.rawValue,
            "message": "读到 \(screens.count) 块屏幕。",
            "ok": true,
            "screens": screens.map(\.jsonObject),
        ]
        // 已经被认成屏幕的之外还有"看起来像屏幕"的物件时，一并说清楚是哪几件 ——
        // 否则居民只知道"有电视"，用户问"那台大的呢"就没有答案。
        if !candidates.isEmpty {
            payload["unrecognized"] = candidates.map(\.jsonObject)
        }
        return reply(payload: payload, isError: false, code: WorldScreenCommandOutcome.Code.ok.rawValue)
    }

    /// 「这个空间里没有能放的屏幕」时给模型的**具名 + 可行动**答复。
    ///
    /// 三条纪律，缺一不可：
    /// - 具名：说得出**是哪一件**物件还没被认成屏幕（名字与原因都来自运行时）；
    /// - 可行动：说得出**怎么改**（名字里带上「电视」或「屏幕」，或换一件）；
    /// - 不编：候选为空时就说"一件都没有"，绝不替用户认领一件。
    /// `fileprivate`（不是 `private`）：`WorldScreenControlRelay` 没有 live 覆盖层时
    /// 用的是**同一句**话 —— 两条路的"是哪一件、怎么改"必须逐字同源，不许各写一份。
    fileprivate static func screenlessMessage(_ candidates: [WorldScreenCandidate]) -> String {
        guard !candidates.isEmpty else {
            return "这个空间里现在没有电视：没有一件物件被认成屏幕。"
                + "先生成一件名字里带「电视」或「屏幕」的物件，它就会被认成屏幕。"
        }
        let named = candidates.prefix(3)
            .map { "「\($0.displayName)」（\($0.reason)）" }
            .joined(separator: "；")
        return "这个空间里现在没有电视。"
            + "这些物件还没被认成屏幕：\(named)。把名字里带上「电视」或「屏幕」，或者换一件。"
    }

    // MARK: 回执编码

    private static func reply(_ outcome: WorldScreenCommandOutcome) -> WorldScreenToolReply {
        var payload: [String: Any] = [
            "code": outcome.code.rawValue,
            "message": outcome.message,
            "ok": !outcome.code.isError,
        ]
        for (key, value) in outcome.details { payload[key] = value }
        return reply(payload: payload, isError: outcome.code.isError, code: outcome.code.rawValue)
    }

    private static func reply(
        payload: [String: Any], isError: Bool, code: String
    ) -> WorldScreenToolReply {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data(#"{"code":"invalid_arguments","message":"回执编码失败","ok":false}"#.utf8)
        return WorldScreenToolReply(payloadJSON: data, isError: isError, code: code)
    }

    private static func schema(properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false,
        ]
    }

    private static func string(_ arguments: Data, _ key: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              let value = object[key] as? String
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension WorldScreenSnapshot {
    /// `read_screen` 的载荷。
    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "screen_id": objectID,
            "name": displayName,
            "aspect": String(format: "%.4f", aspect),
            "state": stateText,
            "playing": isPlaying,
        ]
        if let source { object["geometry_source"] = source.rawValue }
        object["geometry_note"] = note
        if let geometryIssue { object["geometry_problem"] = geometryIssue.errorDescription }
        if let contentURL { object["content_url"] = contentURL }
        if let occlusionText { object["occlusion"] = occlusionText }
        return object
    }
}

extension WorldScreenCandidate {
    /// `read_screen` 载荷里"还没被认成屏幕"的那一条。
    ///
    /// 键名与屏幕快照分开（`object_id` 而不是 `screen_id`）：它不是一块屏幕，
    /// 消费方不该把它当屏幕读 —— 这正是"不编"在载荷形状上的落地。
    var jsonObject: [String: Any] {
        ["object_id": objectID, "name": displayName, "reason": reason]
    }
}

// MARK: - 屏幕功能点的**运行时**注册

/// 一件物件**真的有屏幕、能播**这件事，在运行时的注册结果。
///
/// ## 为什么是派生，而不是落一份新存档
///
/// 与 `WorldPropAnchorRegistry`（`WorldPropFunctionAnchors.swift`，文件头写明
/// "锚点不落盘：每次布局变化都从当前物件状态重新派生"）**逐字同一条纪律**：
/// 纯值、每次重读物件状态重新注册、永不写权威。屏幕走同一条路 ——
/// - 判据只有一处：`WorldScreenResolution.resolve`（标定 → 推断 → 缺省），
///   与 `WorldScreenStore.rebuild()` 调的是**同一个函数**，所以"agent 读到它有屏幕"
///   与"覆盖层真的贴上去"不可能各说各的；
/// - 入场词法判据也只有一处：`WorldScreenEligibility.isScreenCandidate`；
/// - 于是**没有任何第二份"这台电视有没有屏幕"**，也没有一个新的落盘键。
///
/// 为什么它必须能从**没有覆盖层**的地方派生：真机 2026-10-03 那一轮，居民的工具清单里
/// 一条屏幕工具都没有（因此它答"我这轮没有能把视频投到屏幕上的能力"），而它读到的
/// 物件描述又写着 `interaction_status: appearance_only`（因此它答"这台电视登记的是
/// 纯外形摆件"）。两句话是**同一个断点**的两面：屏幕这件事原先只活在覆盖层 store 里。
/// 本结构只读 `WorldObjectState`，与窗口、视图树、覆盖层**无关**。
struct WorldScreenCapability: Equatable, Sendable {
    let objectID: String
    let displayName: String
    /// 几何出处（标定 / 推断 / 缺省）—— 逐字来自 `WorldScreenDefinition.source`。
    let source: WorldScreenSource
    /// 出处原话（`WorldScreenDefinition.note`）：不确定就必须说得出来。
    let note: String
    /// 屏幕面宽高比（`WorldScreenDefinition.quad.aspect`）。
    let aspect: Float

    /// 覆盖层还没接上时 `read_screen` 用的只读快照。
    ///
    /// 它**不是**"假装有一块屏"：几何与出处来自**同一份** `WorldScreenDefinition`，
    /// 只有"现在放的是什么"这一栏是空的 —— 覆盖层确实还没接上，确实什么都还没放。
    var snapshot: WorldScreenSnapshot {
        WorldScreenSnapshot(
            objectID: objectID, displayName: displayName,
            source: source, note: note, aspect: aspect,
            geometryIssue: nil, contentURL: nil,
            stateText: Self.surfacePendingText, isPlaying: false
        )
    }

    /// 「画面还没接上」那一句：只有覆盖层不存在时会读到它。
    static let surfacePendingText = "画面还没接上：先打开一次空间窗口。"
}

/// 一个空间里屏幕功能点的**全部**运行时注册结果。
struct WorldScreenRegistrySnapshot: Equatable, Sendable {
    /// 真的有屏幕、能播的物件。
    var registered: [WorldScreenCapability] = []
    /// 看起来该有屏幕、但这一帧还没读出可用屏幕范围的物件
    /// （`read_screen` 回答"是哪一件"的唯一来源）。
    var candidates: [WorldScreenCandidate] = []

    static let empty = WorldScreenRegistrySnapshot()
}

/// 三条工具持有的**无条件存在**的 control。
///
/// ## 为什么需要它（真机 2026-10-03 的现场）
///
/// 之前 App 侧是 `screenStore.map { … } ?? []`，而 `screenStore` 只在
/// `installScreenOverlayIfNeeded()` 里创建 —— 那一条路要求舞台窗口**已经出现过**
/// （`StageWindowController.stageContentView != nil`）。居民开机后的自主那一轮
/// （08:53:45）比人类打开空间窗口早，于是那一轮的 lease 里**没有**这三条工具；
/// 而 DSH 的会话清单是**建会话时**定的，人类两分钟后说话时清单里依然没有它们 ——
/// 居民只能回一句"我这轮没有能把视频投到屏幕上的能力"。
///
/// 所以"三条工具在不在"这件事**不许**再挂在"覆盖层有没有装好"这个纯画面时机上。
/// 转发器在任何时刻都构造得出来，因此三条工具**永远在当轮 lease 里**；真有调用进来时
/// 才去问 `live`（那时窗口可能已经开了）。拿不到 live 时返回**具名且可行动**的答复，
/// 而不是从清单里消失 —— "清单里没有"会让模型说"我没有能力"，"清单里有但答复具名"
/// 才会让它把"是哪一件、为什么、怎么改"转告用户。
@MainActor
final class WorldScreenControlRelay: WorldScreenControlling {
    private let live: @MainActor () -> (any WorldScreenControlling)?
    private let registered: @MainActor () -> WorldScreenRegistrySnapshot

    init(
        live: @escaping @MainActor () -> (any WorldScreenControlling)?,
        registered: @escaping @MainActor () -> WorldScreenRegistrySnapshot
    ) {
        self.live = live
        self.registered = registered
    }

    /// 覆盖层真的接上了没有。只读，不改任何状态。
    var hasLiveOverlay: Bool { live() != nil }

    func listScreens() -> [WorldScreenSnapshot] {
        if let live = live() { return live.listScreens() }
        return registered().registered.map(\.snapshot)
    }

    func unrecognizedScreenCandidates() -> [WorldScreenCandidate] {
        if let live = live() { return live.unrecognizedScreenCandidates() }
        return registered().candidates
    }

    func playScreen(objectID: String?, rawContent: String) async -> WorldScreenCommandOutcome {
        guard let live = live() else { return surfaceUnavailable(objectID: objectID) }
        return await live.playScreen(objectID: objectID, rawContent: rawContent)
    }

    func stopScreen(objectID: String?) -> WorldScreenCommandOutcome {
        guard let live = live() else {
            return .failure(.screenSurfaceUnavailable, "现在没有正在放的电视。")
        }
        return live.stopScreen(objectID: objectID)
    }

    func calibrateScreen(
        objectID: String, widthMeters: Float, heightMeters: Float, centerHeightMeters: Float
    ) async -> WorldScreenCommandOutcome {
        guard let live = live() else {
            return .failure(.screenSurfaceUnavailable, "画面还没接上，现在标定不了屏幕范围。")
        }
        return await live.calibrateScreen(
            objectID: objectID, widthMeters: widthMeters,
            heightMeters: heightMeters, centerHeightMeters: centerHeightMeters
        )
    }

    /// 放不了时**具名 + 可行动**：是哪一件、为什么、怎么改。
    ///
    /// 两件事必须分开说：
    /// - 空间里**没有**能播的屏幕 ⇒ 复用 `screenlessMessage`（与 `read_screen` 逐字同源）；
    /// - 空间里**有**屏幕、只是画面还没接上 ⇒ 说出**是哪一台** + 怎么改（打开一次空间窗口）。
    private func surfaceUnavailable(objectID: String?) -> WorldScreenCommandOutcome {
        let snapshot = registered()
        guard let screen = snapshot.registered.first(where: {
            objectID == nil || $0.objectID == objectID
        }) else {
            return .failure(
                .screenNotFound,
                ResidentScreenTools.screenlessMessage(snapshot.candidates),
                details: ["unrecognized": String(snapshot.candidates.count)]
            )
        }
        return .failure(
            .screenSurfaceUnavailable,
            "「\(screen.displayName)」的画面还没接上：空间窗口还没打开过。"
                + "先打开一次空间窗口，我就能把这条链接放上去。",
            details: ["screen_id": screen.objectID]
        )
    }
}
