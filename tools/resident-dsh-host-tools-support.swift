//  ResidentDSHHostToolsBridge 的离线测试辅助模块（仅编译进测试，不进 App）。
//  提供：检查计数、生产同形 schemasJSON 样例、宿主调用日志、UDS IPC 客户端。
//  与 apps/.../ResidentDSHHostToolsBridge.swift 同模块编译，可访问其 internal API。

import Foundation
import Darwin

// MARK: - Checks

public struct ResidentDSHHostChecks {
    public private(set) var passed = 0
    public private(set) var failures: [String] = []

    public init() {}

    public mutating func check(_ condition: Bool, _ description: String) {
        if condition {
            passed += 1
        } else {
            failures.append(description)
            print("FAIL: \(description)")
        }
    }

    public mutating func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ description: String) {
        check(lhs == rhs, "\(description) (期望 \(rhs)，实际 \(lhs))")
    }

    public mutating func expectContains(_ haystack: String, _ needle: String, _ description: String) {
        check(haystack.contains(needle), "\(description)（未找到「\(needle)」）")
    }
}

// MARK: - Sample schemas (production-shaped contract)

public enum ResidentDSHHostSupportSchema {
    static func data(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// 与 ResidentWorldToolSession.toolSchemasJSON 同形状的条目数组：
    /// [{name, description, inputSchema}].
    public static let schemas: Data = {
        let read: [String: Any] = [
            "name": "read_wish_generation",
            "description": "查询许愿机当前任务状态",
            "inputSchema": [
                "type": "object",
                "properties": ["wish_id": ["type": "string", "description": "许愿任务编号"]],
                "required": [],
                "additionalProperties": false,
            ],
        ]
        let submit: [String: Any] = [
            "name": "submit_wish_generation",
            "description": "提交许愿机生成",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "attachment_id": ["type": "string"],
                    "name": ["type": "string"],
                    "height_meters": ["type": "number"],
                    "destination": [
                        "type": ["object", "null"],
                        "properties": [
                            "surface_ids": [
                                "type": "array", "items": ["type": "string"],
                                "minItems": 1, "maxItems": 8,
                            ],
                        ],
                        "required": ["surface_ids"],
                        "additionalProperties": false,
                    ],
                ],
                "required": ["attachment_id", "name", "height_meters"],
                "additionalProperties": false,
            ],
        ]
        let array: [[String: Any]] = [read, submit]
        return try! JSONSerialization.data(withJSONObject: array, options: [.sortedKeys])
    }()

    public static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func callArguments(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

// MARK: - Host call log (deterministic; used by tests instead of world tools)

public final class ResidentDSHHostCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String] = []

    public init() {}

    public func append(_ canonical: String, callID: String, argumentsJSON: Data) {
        lock.lock()
        defer { lock.unlock() }
        let text = String(decoding: argumentsJSON, as: UTF8.self)
        records.append("\(callID)|\(canonical)|\(text)")
    }

    public var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public func contains(canonical: String) -> Bool {
        all.contains { $0.hasSuffix("|\(canonical)|") || $0.contains("|\(canonical)|") }
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return records.count
    }
}

/// 生产同形的宿主 handler：记录调用并按 canonical 返回确定性结果；isError 由参数
/// fail_submit 触发（仅测试用）。
public func residentDSHHostToolsTestHandler(
    log: ResidentDSHHostCallLog,
    scope: String
) -> @MainActor @Sendable (ResidentDSHHostToolRequest) async -> ResidentDSHHostToolReply {
    { request in
        log.append(request.canonicalName, callID: request.callID, argumentsJSON: request.argumentsJSON)
        switch request.canonicalName {
        case "read_wish_generation":
            let payload = try! JSONSerialization.data(withJSONObject: [
                "ok": true,
                "running": false,
                "wish_id": NSNull(),
                "scope": scope,
            ], options: [.sortedKeys])
            return ResidentDSHHostToolReply(resultJSON: payload, isError: false)
        case "submit_wish_generation":
            let arguments = ResidentDSHHostSupportSchema.object(request.argumentsJSON) ?? [:]
            let fail = (arguments["name"] as? String) == "fail"
            if fail {
                let payload = try! JSONSerialization.data(withJSONObject: [
                    "ok": false,
                    "error": ["code": "wish_denied", "message": "测试拒绝"],
                ], options: [.sortedKeys])
                return ResidentDSHHostToolReply(resultJSON: payload, isError: true)
            }
            let payload = try! JSONSerialization.data(withJSONObject: [
                "ok": true,
                "wish_id": "w-\(arguments["name"] as? String ?? "x")",
            ], options: [.sortedKeys])
            return ResidentDSHHostToolReply(resultJSON: payload, isError: false)
        default:
            let payload = try! JSONSerialization.data(withJSONObject: [
                "ok": false, "error": ["code": "tool_not_allowed", "message": "未开放"],
            ], options: [.sortedKeys])
            return ResidentDSHHostToolReply(resultJSON: payload, isError: true)
        }
    }
}

// MARK: - UDS IPC client (mirrors the DSH plugin's wire behaviour)

public func residentDSHHostClientCall(
    socketPath: String,
    secret: String,
    name: String,
    arguments: [String: Any],
    callID: String = "test-call"
) -> (payload: NSDictionary?, error: String?) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return (nil, "socket() 失败") }
    defer { close(fd) }
    guard let port = UInt16(socketPath.split(separator: ":").last ?? "") else { return (nil, "invalid endpoint") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = port.bigEndian
    let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else { return (nil, "connect() 失败 errno=\(errno)") }

    // peer 提前关闭时 write 返回 EPIPE 而不是 SIGPIPE 杀死调用进程。
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 8, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let body: [String: Any] = [
        "v": 1,
        "secret": secret,
        "callId": callID,
        "name": name,
        "arguments": arguments,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
        return (nil, "请求序列化失败")
    }
    var written = 0
    let bytes = [UInt8](data)
    while written < bytes.count {
        let count = write(fd, Array(bytes[written...]), bytes.count - written)
        if count <= 0 { return (nil, "write() 失败") }
        written += count
    }
    if write(fd, [0x0A], 1) != 1 { return (nil, "write(\\n) 失败") }
    guard let frame = ResidentDSHHostWire.readFrame(from: fd, maximumBytes: ResidentDSHHostWire.maximumFrameBytes) else {
        return (nil, "未收到回复帧")
    }
    let object = ResidentDSHHostSupportSchema.object(frame)
    return (object.map { NSDictionary(dictionary: $0) }, nil)
}
