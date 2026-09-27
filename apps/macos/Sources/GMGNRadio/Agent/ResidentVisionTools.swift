import Foundation

// MARK: - 居民视觉观察工具(第一增量)
//
// 稳定的模型可调用工具合同:请求"当前空间照片",返回
// image(file_url/强类型产物) + metadata(worldID/camera/time)。
//
// 语义边界(与本仓库现有工具一致,均须在接线处保留):
//  - 画面只服务当前居民会话(sessionID),不属于任何新生成授权;
//  - 工具合同没有任何"路径"参数,模型无法指定写入位置;
//  - 只暴露 ResidentVisionCatalog 已登记的视角;头眼/全局等离屏视角未实现,
//    因此不出现在 schema enum 中,也不可调用;
//  - 返回帧必须通过 ResidentVisionGate:旧空间/旧帧/无画面/超时直接失败;
//  - 文本 JSON 永远不含 base64:真实 PNG 走 `handleImage` 的强类型产物
//    (ResidentVisionImage),JSON 只放元数据/位置,模型不会"假装看到"图片;
//  - 元数据里的 expected_world_revision 只是请求方的期望条件,不是对画面帧
//    世界 revision 的证明(渲染器当前不提供帧的真实世界 revision)。
//
// 本文件不依赖渲染器/会话分发器具体类型,便于离线测试跑生产逻辑;
// 接线方把它挂到自己的工具通道即可(见 ResidentVisionToolContract 的 schema
// 与 ResidentVisionToolbox.handle / handleImage)。

enum ResidentVisionToolContract {
    static let toolName = "capture_space_photo"
    static let toolNames = [toolName]

    static let toolDescription =
        "请求居民当前所在空间的一张真实观察照片(仅渲染器自身画面,非桌面截图)。"
        + "返回 PNG 与画面元数据(world_id / camera / captured_at / frame_index 等);"
        + "真实 PNG 经图片通道送达,模型可见文本只含元数据与文件位置,不含图片字节。"
        + "expected_world_revision 仅为请求方在发起时的期望条件,不是对画面帧世界 revision"
        + "的证明。若空间切换、画面过期、无画面或超时会失败,请稍后重试或改用文本观察工具。"
    static let maximumReasonLength = 200

    /// 输入 schema(provider/模型通用 JSON Schema 形式)。
    static func providerTool() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": toolName,
                "description": toolDescription,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "perspective": [
                            "type": "string",
                            "description": "观察视角;只列出已真实实现的视角。",
                            "enum": ResidentVisionCatalog.registeredIDs,
                        ],
                        "reason": [
                            "type": "string",
                            "description": "为什么需要当前画面(简短)。",
                            "maxLength": maximumReasonLength,
                        ],
                        "expected_world_revision": [
                            "type": "integer",
                            "description":
                                "发起请求时调用方已知(期望)的居民世界 revision;仅作为本次请求的期望条件用于旧状态检测,不是对画面帧 revision 的证明(画面帧的真实世界 revision 渲染器当前不提供)。",
                        ],
                    ],
                    "required": [],
                    "additionalProperties": false,
                ],
            ],
        ]
    }

    /// ResidentWorldToolSession.AdditionalTool / ResidentLoopTools 风格的 schema 行。
    static func additionalToolSchemas() -> [[String: Any]] {
        [
            [
                "name": toolName,
                "description": toolDescription,
                "inputSchema":
                    providerTool()["function"].flatMap {
                        ($0 as? [String: Any])?["parameters"] as? [String: Any]
                    } ?? [:],
            ],
        ]
    }
}

/// 工具输入(校验后的强类型)。
struct ResidentVisionToolInput: Equatable, Sendable {
    let perspective: ResidentVisionPerspective
    let reason: String?
    let expectedWorldRevision: UInt64?
}

enum ResidentVisionToolArgumentError: Error, Equatable {
    case invalid(String)

    var message: String {
        if case let .invalid(message) = self { return message }
        return "参数不合法"
    }
}

enum ResidentVisionToolArgumentPolicy {
    static func validate(
        _ arguments: [String: Any]
    ) -> Result<ResidentVisionToolInput, ResidentVisionToolArgumentError> {
        guard Set(arguments.keys).isSubset(
            of: [
                "perspective", "reason", "expected_world_revision",
            ]
        ) else {
            return .failure(.invalid("包含不支持的参数"))
        }

        var perspective = ResidentVisionPerspective.currentObservation
        if let raw = arguments["perspective"] {
            guard let text = raw as? String,
                  let parsed = ResidentVisionPerspective(rawValue: text),
                  ResidentVisionCatalog.isRegistered(parsed.rawValue)
            else {
                return .failure(.invalid("视角尚未实现或不可用"))
            }
            perspective = parsed
        }

        var reason: String?
        if let raw = arguments["reason"] {
            guard let text = raw as? String else {
                return .failure(.invalid("reason 需要是字符串"))
            }
            let trimmed = text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard trimmed.count <= ResidentVisionToolContract
                .maximumReasonLength
            else {
                return .failure(.invalid("reason 过长"))
            }
            reason = trimmed.isEmpty ? nil : trimmed
        }

        var expectedWorldRevision: UInt64?
        if let raw = arguments["expected_world_revision"] {
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID()
            else {
                return .failure(.invalid("expected_world_revision 需要是非负整数"))
            }
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite,
                  doubleValue >= 0,
                  doubleValue == doubleValue.rounded(.down)
            else {
                return .failure(.invalid("expected_world_revision 需要是非负整数"))
            }
            expectedWorldRevision = number.uint64Value
        }

        return .success(
            ResidentVisionToolInput(
                perspective: perspective,
                reason: reason,
                expectedWorldRevision: expectedWorldRevision
            )
        )
    }
}

// MARK: - 工具处理器(稳定 JSON 输出;接线方直接路由到 handle)

@MainActor
final class ResidentVisionToolbox {
    /// 当前居民会话:runID 决定画面归属;worldID/revision 仅作门控上下文
    /// (旧空间/重载检测)。worldRevision **不**会被回显成画面帧的 revision。
    struct Session: Equatable, Sendable {
        let runID: UUID
        let worldID: String
        let worldRevision: UInt64?
    }

    private let service: ResidentVisionCaptureService
    private let currentSession: @MainActor () -> Session?

    init(
        surface: (any ResidentVisionSurface)?,
        fileRoot: URL? = ResidentVisionFilePolicy.defaultRoot(),
        currentSession: @escaping @MainActor () -> Session?,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.currentSession = currentSession
        // 门控上下文 = 每次求值时的最新居民会话快照。
        service = ResidentVisionCaptureService(
            surface: surface,
            fileRoot: fileRoot,
            context: { currentSession().map {
                ResidentVisionGate.ContextSnapshot(
                    worldID: $0.worldID,
                    worldRevision: $0.worldRevision
                )
            } },
            now: now
        )
    }

    func handles(_ name: String) -> Bool {
        ResidentVisionToolContract.toolNames.contains(name)
    }

    /// 内部失败值:稳定的 code + 面向模型的安全 message。
    private struct ToolFailure: Error, Equatable {
        let code: String
        let message: String
    }

    /// 兼容的 JSON 通道(文本模型/既有工具分发):成功与失败都只回 JSON。
    /// 文本载荷绝不含 base64 图片字节(真实 PNG 请走 `handleImage`)。
    func handle(
        name: String,
        argumentsJSON: Data
    ) async -> (data: Data, isError: Bool) {
        let outcome = await run(name: name, argumentsJSON: argumentsJSON)
        switch outcome {
        case let .success(image):
            return (successJSON(image: image), false)
        case let .failure(error):
            return (failureJSON(code: error.code, message: error.message), true)
        }
    }

    /// 图片通道的强类型产物(供 DSH/Codex 原生图片接线):
    /// 成功时返回真实 `ResidentVisionImage`(PNG 字节/文件与元数据),同时
    /// `payloadJSON` 只含元数据与文件位置 —— 图片字节绝不放进模型可见文本,
    /// 模型不会"假装看到"图片;失败时 `image == nil` 且 `isError == true`。
    func handleImage(
        name: String,
        argumentsJSON: Data
    ) async -> ResidentVisionToolImageReply {
        let outcome = await run(name: name, argumentsJSON: argumentsJSON)
        switch outcome {
        case let .success(image):
            return ResidentVisionToolImageReply(
                image: image,
                payloadJSON: successJSON(image: image),
                isError: false
            )
        case let .failure(error):
            return ResidentVisionToolImageReply(
                image: nil,
                payloadJSON: failureJSON(code: error.code, message: error.message),
                isError: true
            )
        }
    }

    // MARK: 共享执行(校验 → 会话门 → 捕获 → 门控/编码/落盘)

    private func run(
        name: String,
        argumentsJSON: Data
    ) async -> Result<ResidentVisionImage, ToolFailure> {
        guard handles(name) else {
            return .failure(ToolFailure(code: "tool_not_allowed", message: "未开放这个居民视觉工具"))
        }
        guard let arguments = (try? JSONSerialization.jsonObject(
            with: argumentsJSON
        )) as? [String: Any] else {
            return .failure(ToolFailure(code: "invalid_arguments", message: "参数需要是 JSON 对象"))
        }
        let input: ResidentVisionToolInput
        switch ResidentVisionToolArgumentPolicy.validate(arguments) {
        case let .success(parsed):
            input = parsed
        case let .failure(error):
            return .failure(ToolFailure(code: "invalid_arguments", message: error.message))
        }
        guard let session = currentSession() else {
            return .failure(ToolFailure(
                code: ResidentVisionErrorCode.sessionMismatch.rawValue,
                message: "本轮居民会话已结束或切换,请重新发起"
            ))
        }

        // expected_world_revision 只取模型/调用方显式提供的期望条件,绝不把
        // 当前会话的 worldRevision 自动填进去冒充画面帧的 revision。
        let request = ResidentVisionCaptureRequest(
            sessionID: session.runID,
            perspective: input.perspective,
            worldID: session.worldID,
            expectedWorldRevision: input.expectedWorldRevision,
            reason: input.reason,
            includeFileURL: true
        )
        let outcome = await service.capture(request)
        switch outcome {
        case let .failure(code, message):
            return .failure(ToolFailure(code: code.rawValue, message: message))
        case let .success(image):
            return .success(image)
        }
    }

    // MARK: 输出载荷(成功 JSON 仅元数据/位置,不含图片字节)

    private struct ErrorPayload: Codable {
        let code: String
        let message: String
    }

    private struct FailurePayload: Codable {
        let ok: Bool
        let error: ErrorPayload
    }

    private struct ImagePayload: Codable {
        let mime: String
        let bytes: Int
        let width: Int
        let height: Int
        let fileURL: URL?
    }

    private struct PolicyPayload: Codable {
        let sessionScoped: Bool
        let currentResidentSessionOnly: Bool
        let notGenerationAuthorization: Bool
        let neverAutomaticCapture: Bool
    }

    private struct SuccessPayload: Codable {
        let ok: Bool
        let image: ImagePayload
        let metadata: ResidentVisionMetadata
        let policy: PolicyPayload
    }

    private func successJSON(image: ResidentVisionImage) -> Data {
        let payload = SuccessPayload(
            ok: true,
            image: ImagePayload(
                mime: "image/png",
                bytes: image.pngData.count,
                width: image.metadata.width,
                height: image.metadata.height,
                fileURL: image.fileURL
            ),
            metadata: image.metadata,
            policy: PolicyPayload(
                sessionScoped: true,
                currentResidentSessionOnly: true,
                notGenerationAuthorization: true,
                neverAutomaticCapture: true
            )
        )
        return encode(payload)
    }

    private func failureJSON(code: String, message: String) -> Data {
        encode(
            FailurePayload(
                ok: false,
                error: ErrorPayload(code: code, message: message)
            )
        )
    }

    private func encode<Value: Encodable>(_ value: Value) -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }
}

/// `ResidentVisionToolbox.handleImage` 的强类型产物。
/// - `image`:成功时的真实 PNG 产物;失败为 nil。
/// - `payloadJSON`:成功时仅元数据/位置的 JSON;失败时为 `{"ok":false,error}`。
/// - `isError`:`payloadJSON` 是否为错误载荷。
struct ResidentVisionToolImageReply: Sendable, Equatable {
    let image: ResidentVisionImage?
    let payloadJSON: Data
    let isError: Bool
}
