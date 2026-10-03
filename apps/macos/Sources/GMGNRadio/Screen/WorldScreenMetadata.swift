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

// MARK: - 屏幕功能点的**运行时注册表**

/// 「这个空间里哪几件物件真的有屏幕、能播」在运行时的唯一一份派生。
///
/// ## 为什么是注册表，而不是一份新存档 / 一个新命令
///
/// 与 `WorldPropAnchorRegistry`（`Packages/WorldRuntime/.../WorldPropFunctionAnchors.swift`，
/// 文件头：「锚点**不落盘**：每次布局变化都从当前物件状态重新派生，纯值、永不写权威」）
/// **逐字同一条纪律**。屏幕功能点走同一条路：
///
/// - 判据只有一处：`WorldScreenResolution.resolve`（标定 → 推断 → 缺省），
///   与 `WorldScreenStore.rebuild()` 调的是**同一个函数** —— 于是"agent 读到它有屏幕"
///   与"覆盖层真的贴上去"不可能各说各的；
/// - 入场词法判据也只有一处：`WorldScreenEligibility.isScreenCandidate`；
/// - 于是没有第二份"这台电视有没有屏幕"，没有新键、没有新命令、
///   `world_*` 权威语义一个字不动。
///
/// 为什么不写 `metadata["gmgn.screen.v1"]`（那个写入口就在上面、今天**零调用点**）：
/// 写物件元数据是一次权威变更，App 侧今天没有、也不该在这一轮新开一条权威命令。
/// 派生与"标定值"合起来仍然是**一个**判据 —— 标定在 metadata 里，推断/缺省在这里。
///
/// ## 它为什么必须能在**没有覆盖层**的地方跑
///
/// 真机 2026-10-03 那一轮，居民的工具清单里一条屏幕工具都没有（它答"我这轮没有能把
/// 视频投到屏幕上的能力"），而它读到的物件描述写着 `interaction_status: appearance_only`
/// （它答"这台电视登记的是纯外形摆件"）。两句话是**同一个断点**的两面：屏幕这件事原先
/// 只活在覆盖层 store 里，而 store 要等舞台窗口出现过才建。本注册表只读
/// `WorldObjectState`，与窗口、视图树、覆盖层**无关**。
enum WorldScreenCapabilityRegistry {
    /// 从当前物件状态派生一份注册结果。
    ///
    /// 过滤与分类**逐条同式**于 `WorldScreenStore.rebuild()` /
    /// `WorldScreenStore.unrecognizedScreenCandidates()`：几何成立 ⇒ `registered`；
    /// 只有"看起来像屏幕却没读出范围"的 ⇒ `candidates`。两处若判据不一致，
    /// 「agent 说能放」与「覆盖层贴不上」就会各说各的 —— 那正是这次要修的东西。
    static func derive(
        objectStates: [String: WorldObjectState],
        displayName: (String) -> String
    ) -> WorldScreenRegistrySnapshot {
        var snapshot = WorldScreenRegistrySnapshot()
        let ordered = objectStates.sorted { $0.key < $1.key }

        // 第一趟：与 `WorldScreenStore.rebuild()` 的入场判据同式。
        // `recognized` = 覆盖层那一边的 `definitions ∪ issues`：凡进了这一趟的物件，
        // 候选那一趟**都不再**报它（同 `definitions[id] == nil, issues[id] == nil`）。
        var recognized: Set<String> = []
        for (objectID, state) in ordered where state.isEnabled {
            let name = displayName(objectID)
            let calibratedJSON = state.metadata[WorldScreenMetadataKey.definition]
            let nameLike = WorldScreenEligibility.isScreenCandidate(
                objectID: objectID, displayName: name
            )
            guard calibratedJSON != nil
                || state.metadata[WorldScreenMetadataKey.content] != nil
                || nameLike
            else { continue }
            recognized.insert(objectID)
            let resolution = WorldScreenResolution.resolve(
                objectID: objectID, calibratedJSON: calibratedJSON,
                size: size(state), allowsDefault: nameLike
            )
            guard case let .success(definition) = resolution else { continue }
            snapshot.registered.append(WorldScreenCapability(
                objectID: objectID, displayName: name,
                source: definition.source, note: definition.note,
                aspect: definition.quad.aspect
            ))
        }

        // 第二趟：与 `WorldScreenStore.unrecognizedScreenCandidates()` 同式。
        // 只有"像一块板"的物件才报 —— 把屋里每件东西（斧头、椅子、零件）都说成
        // "还没被认成屏幕"等于没有信息。
        for (objectID, state) in ordered where state.isEnabled {
            guard !recognized.contains(objectID) else { continue }
            let name = displayName(objectID)
            if WorldScreenEligibility.isScreenCandidate(objectID: objectID, displayName: name) {
                // 名字像电视却不在上面那一趟里：这一帧的世界状态与几何对不上。
                // 如实说"没读出来"，不硬猜一个原因。
                snapshot.candidates.append(WorldScreenCandidate(
                    objectID: objectID, displayName: name,
                    reason: "名字像电视，但这一帧没读出可用的屏幕范围"
                ))
                continue
            }
            guard let prop = state.generatedProp else { continue }
            let propSize = SIMD3<Float>(
                prop.effectiveSize.x, prop.effectiveSize.y, prop.effectiveSize.z
            )
            guard propSize.x > 0, propSize.y > 0, propSize.z > 0,
                  WorldScreenFaceInference.rejection(size: propSize, objectID: objectID) == nil
            else { continue }
            snapshot.candidates.append(WorldScreenCandidate(
                objectID: objectID, displayName: name,
                reason: "这块面像一块屏幕，但名字里没有「电视」或「屏幕」"
            ))
        }
        return snapshot
    }

    private static func size(_ state: WorldObjectState) -> SIMD3<Float>? {
        state.generatedProp.map {
            SIMD3<Float>($0.effectiveSize.x, $0.effectiveSize.y, $0.effectiveSize.z)
        }
    }
}
