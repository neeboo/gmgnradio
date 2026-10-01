import Foundation
import WorldRuntime

/// 回执里那两块**可选**的生成工作流碰撞数据 → `WorldRuntime` 的契约类型。
///
/// 为什么单独一个文件：`PropGenerationClient.swift` 是**纯传输**层（只认识 JSON 字段名），
/// 让它 import WorldRuntime 会把传输与几何耦在一起。这里做唯一的换算，于是
/// "回执字段 → 世界几何"只有一个入口，也只有一个地方要测。
///
/// 两块都是**严格可选**的：
/// - 字段整块缺失 ⇒ `nil` ⇒ 调用方退回今天的行为（yaw 盒子 + app 量的尺寸），逐字节不变；
/// - 字段出现但不合法 ⇒ 也是 `nil`，但调用方**不能**把它当成"没有代理"：把 `collision`
///   原样传给 `WorldGeneratedProp` 会让 `isValid` 判假 ⇒ 走既有的
///   `unmodelledPlacedProp` 可见拒绝。所以这里返回的是"构造得出的合法描述"，而不是
///   "回执有没有声明" —— 声明的判定由 `collision_*` 是否出现来表达。
extension PropGenerationResult {
    /// 回执声明的碰撞代理（不合法时为 nil）。
    var workflowCollision: WorldPropCollisionProxy? {
        WorldPropCollisionProxy.fromReceipt(
            url: collisionURL, format: collisionFormat, sha256: collisionSHA256,
            bytes: collisionBytes, triangles: collisionTriangles
        )
    }

    /// 回执是否**声明**了碰撞代理（有没有那五个字段里的任意一个）。
    ///
    /// 与 `workflowCollision` 分开是刻意的：`declares == true && workflowCollision == nil`
    /// 就是"声明了但描述非法"，必须可见拒绝，而不是静默退回盒子。
    var declaresWorkflowCollision: Bool {
        collisionURL != nil || collisionFormat != nil || collisionSHA256 != nil
            || collisionBytes != nil || collisionTriangles != nil
    }

    /// 回执声明的权威尺寸（缺失或不合法时为 nil）。
    var workflowAuthoritativeSize: WorldPropAuthoritativeSize? {
        WorldPropAuthoritativeSize.fromReceipt(
            dimensions: authoritativeSize?.dimensions, units: authoritativeSize?.units,
            upAxis: authoritativeSize?.upAxis, forwardAxis: authoritativeSize?.forwardAxis
        )
    }
}
