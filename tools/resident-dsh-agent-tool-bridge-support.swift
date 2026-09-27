//  ResidentDSHAgentToolBridge 的测试辅助模块（离线，仅编译进测试，不进 App）。
//  提供：检查计数、常用原 schema 样例、类型化事件序列样例。
//
//  由 tools/test-resident-dsh-agent-tool-bridge.swift 复制到临时目录，
//  与生产文件 ResidentDSHAgentToolBridge.swift 一起经 swiftc 编译后运行。

import Foundation

/// 极简检查器：所有断言只影响计数器，最后以 exit code 汇报。
public struct ResidentDSHBridgeChecks {
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

public enum ResidentDSHBridgeSchemaSamples {
    static func data(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func json(_ object: [String: Any]) -> Data {
        data(object)
    }

    /// read_wish_generation：空参数 = 查询当前任务，或给 wish_id 查询。
    public static let readWishGeneration: Data = json([
        "type": "object",
        "properties": [
            "wish_id": ["type": "string", "description": "许愿任务编号"],
        ],
        "required": [],
        "additionalProperties": false,
    ])

    /// submit_wish_generation 的契约子集（与生产合同同形状：可空并集 /
    /// 数组 minItems / 嵌套对象 required / additionalProperties）。
    public static let submitWishGeneration: Data = json([
        "type": "object",
        "properties": [
            "attachment_id": ["type": "string", "description": "登记的图片附件编号"],
            "name": ["type": "string", "description": "物件名称"],
            "height_meters": ["type": "number", "description": "期望高度"],
            "destination": [
                "type": ["object", "null"],
                "description": "仅当用户明确要求摆放时提供",
                "properties": [
                    "surface_ids": [
                        "type": "array", "items": ["type": "string"],
                        "minItems": 1, "maxItems": 8,
                    ],
                    "position": [
                        "type": ["object", "null"],
                        "properties": [
                            "surface_id": ["type": "string"],
                            "x": ["type": "number"], "y": ["type": "number"],
                            "z": ["type": "number"], "yaw": ["type": "number"],
                        ],
                        "required": ["surface_id", "x", "y", "z", "yaw"],
                        "additionalProperties": false,
                    ],
                ],
                "required": ["surface_ids"],
                "additionalProperties": false,
            ],
        ],
        "required": ["attachment_id", "name", "height_meters"],
        "additionalProperties": false,
    ])

    /// resume_wish_continuation：boolean + enum [true]，拒绝非确认值。
    public static let resumeWishContinuation: Data = json([
        "type": "object",
        "properties": [
            "wish_id": ["type": "string"],
            "confirm_resume": ["type": "boolean", "enum": [true]],
        ],
        "required": ["wish_id", "confirm_resume"],
        "additionalProperties": false,
    ])
}

public enum ResidentDSHBridgeJSON {
    public static func args(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
