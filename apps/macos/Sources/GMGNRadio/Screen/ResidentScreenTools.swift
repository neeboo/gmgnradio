import Foundation

// MARK: - 屏幕控制面（面板与 agent 工具共用的**唯一**入口）

/// 一台电视在面板/回执里的样子。只读快照，不含任何 UI 类型。
struct WorldScreenSnapshot: Equatable, Sendable {
    let objectID: String
    let displayName: String
    /// 几何出处（标定 / 推断 / 缺省）。
    let source: WorldScreenSource?
    /// 几何出处的**原话**。缺省与推断时面板必须显示它（"不猜"要看得见）。
    let note: String
    let aspect: Float
    /// 几何给不出来时的具名原因。
    let geometryIssue: WorldScreenGeometryIssue?
    /// 当前内容（官方嵌入 URL）。
    let contentURL: String?
    /// 状态的一行话。
    let stateText: String
    let isPlaying: Bool
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

/// 屏幕的**控制面**。`WorldScreenStore` 是生产实现；harness 用替身。
@MainActor
protocol WorldScreenControlling: AnyObject {
    func listScreens() -> [WorldScreenSnapshot]
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
    ) -> WorldScreenCommandOutcome
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
                description: "让这个空间里的一台电视播放官方嵌入页（YouTube / 哔哩哔哩 / Twitch）。"
                    + "参数 url 接受官方嵌入链接、公开观看链接或视频 id。"
                    + "只说「放个视频」而没给内容时，会返回 insufficient_input（信息不足，不是失败），"
                    + "这时应当问用户要一个链接。不许抓流、不许绕过登录或地区限制。",
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
                description: "关掉一台电视（停止播放并回到黑屏）。object_id 省略时作用于唯一的那一台。",
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
                description: "读这个空间里所有电视的状态：几何出处（标定 / 推断 / 缺省）、出处原话、"
                    + "宽高比、当前内容、播放状态、以及几何缺失的具名原因。只读，不改变任何东西。",
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
        guard !screens.isEmpty else {
            return reply(.needsInput(
                "这个空间里没有电视。先在面板里把一件物件标定成屏幕，或生成一件电视。",
                details: ["screens": "0"]
            ))
        }
        // 只读工具**必须真的把状态带回去**：只报一个数量，agent 就拿不到
        // "这块屏的几何是猜的 / 现在放的是什么 / 失败原因是什么"这几件它要判断的事。
        let payload: [String: Any] = [
            "code": WorldScreenCommandOutcome.Code.ok.rawValue,
            "message": "读到 \(screens.count) 块屏幕。",
            "ok": true,
            "screens": screens.map(\.jsonObject),
        ]
        return reply(payload: payload, isError: false, code: WorldScreenCommandOutcome.Code.ok.rawValue)
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
        return object
    }
}
