import Foundation
import WorldRuntime

/// 屏幕定义与屏幕内容在**世界状态**里的读写口。
///
/// 两个键、两种生命周期：
/// - `gmgn.screen.v1`：屏幕**在哪**（几何 + 出处）。跟物件走。
/// - `gmgn.screen-content.v1`：这一台**现在放什么**。跟"这台电视当前的状态"走。
///
/// 读取一律走 `WorldScreenDefinitionCoding`（唯一解码口），于是"合法"只有一处定义；
/// 写入只管编码，合法性由同一个口子判定，写不出不合法的字节。
extension WorldObjectState {
    /// 物件标定的屏幕。缺失或非法一律 `nil`，绝不猜。
    ///
    /// 与 `WorldPropFunctionPointDeclaration` 的同名访问器同一条纪律：生成道具的自称
    /// 必须等于它自己的 objectID（元数据不许张冠李戴到别的物件上）。
    /// `objectID` 必须由调用方给：`WorldObjectState` 自己不存 id（它是 `objectStates` 的键），
    /// 猜一个 id 就等于让"这份元数据属于谁"变成第二处事实。
    func screenDefinition(objectID: String) -> WorldScreenDefinition? {
        guard let json = metadata[WorldScreenMetadataKey.definition] else { return nil }
        return WorldScreenDefinitionCoding.decode(json, expecting: generatedProp?.objectID ?? objectID)
    }

    /// 这一台电视现在放什么。非法/缺失一律 `nil`。
    func screenContent(objectID: String) -> WorldScreenContent? {
        guard let json = metadata[WorldScreenMetadataKey.content],
              let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(WorldScreenContent.self, from: data),
              value.isValid, value.objectID == objectID
        else { return nil }
        return value
    }

    /// 写入屏幕定义的**字节**（不落盘、不走权威 —— 落盘由调用方决定）。
    ///
    /// 返回 `false` = 这份定义不合法，**一个字节都没改**。调用方据此报具名失败。
    mutating func writeScreenDefinition(_ definition: WorldScreenDefinition, objectID: String) -> Bool {
        guard definition.objectID == objectID,
              let json = WorldScreenDefinitionCoding.encode(definition)
        else { return false }
        metadata[WorldScreenMetadataKey.definition] = json
        return true
    }

    mutating func writeScreenContent(_ content: WorldScreenContent, objectID: String) -> Bool {
        guard content.objectID == objectID, content.isValid,
              let data = try? JSONEncoder().encode(content),
              let json = String(data: data, encoding: .utf8)
        else { return false }
        metadata[WorldScreenMetadataKey.content] = json
        return true
    }

    mutating func clearScreen() {
        metadata[WorldScreenMetadataKey.definition] = nil
        metadata[WorldScreenMetadataKey.content] = nil
    }
}
