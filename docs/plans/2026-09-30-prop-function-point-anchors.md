# 道具功能点：运行时注册（2026-09-30）

用户要求（原话）：「物品上的功能点都需要动态注册才行，不能靠写死」。

这份文档记录**锚点的类型学、接口、生命周期与迁移边界**。实现见
`apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldPropFunctionAnchors.swift`、
`WorldManifest.swift`（`WorldActivityEntry`）、仓库里的 `wish-machine.json` /
`jukebox.json`，以及 `tools/test-resident-prop-function-anchors.swift`。

## 1. 锚点的类型学

| | 世界固有锚点 | 道具功能点锚点 |
|---|---|---|
| 谁声明 | 世界包（`world.json.activities`） | 道具声明（`prop.procedural` 的 `functionPoints`） |
| 几何 | 烘焙：`entryWaypointID` + `transform` | 本体坐标系下的局部点，**没有**世界坐标 |
| 世界位置 | 直接读 | `摆放 transform ∘ 局部点`（运行时派生） |
| 生命周期 | 随世界 | 随摆放：注册 / 注销 |
| 落盘 | 随世界包 | **永不落盘**（存档里只有摆放位置） |
| 例子 | `wp.spawn`、`wp.center`、`home.idle`、`home.walk`、`performance.*` | `wish_machine.device#pickup/#outlet/#interact`、`prop.jukebox#interact` |

**判定标准（不是举例）**：一个锚点能不能写成「某件可摆放道具的局部点 × 摆放 transform」？

- 能 ⇒ 它是**道具功能点**。推论：把这件道具收回/删掉，这个锚点**必须**消失；只要有摆放位置，
  它就能被重新算出来（不需要任何别的数据）。
- 不能 ⇒ 它由居民/环境本身决定（出生点、房间中心、巡逻点）。收回任何道具它都还在。

在类型上二者是**互斥**的：`WorldActivityEntry` 是
`.waypoint(id:transform:)` 或 `.functionPoint(propID:)` 的二选一，解码时
两份几何或一份都没有都直接拒绝装载。所以"同一个锚点有两份真相"是不可表达的。

## 2. 接口

**声明（局部坐标 + 角色）**——世界包 `prop.procedural` JSON，字段名 `functionPoints`：

```json
{"role": "pickup", "kind": "standingSpot",
 "position": [0, -0.019016094, -0.95], "yaw": 3.141592653589793,
 "activityID": "wish_machine.collect"}
```

- `position`：本体坐标系（原点 = 道具落地点，+Y 向上）。
- `yaw`：可省。省略时**面向**同一声明里的 `interaction` 点，再退到原点。角色前方是 **-Z**，
  所以"面向 (dx,dz)"是 `atan2(-dx,-dz)`（迁移前两个烘焙朝向都由它重现：音箱 -π/2、许愿机 π）。
- `kind`：`standingSpot`（居民站的地方，**只有它**参与"站得住/走得到"判据）、`emitter`
  （出货口，不站人）、`interaction`（按钮/机身正面，用来定向）。
- `activityID`：把这个点绑成某活动的**接近锚点**。一个活动最多一个接近锚点，冲突 = 拒绝。

生成道具用同一个结构，放在 `WorldObjectState.metadata["gmgn.prop-function-points.v1"]`。

**注册表** `WorldPropAnchorRegistry`（`WorldRuntime`）：

- key = `"<objectID>#<role>"`（确定性、与摆放无关）；另有 `activityID → 接近锚点`。
- 谁持有：`WorldAgentContext.propAnchorRegistry`；每次布局变化后重建。
- 从什么派生：`WorldPropAnchorRegistry.derive(sources:objectStates:)`。
  世界固有道具的**种子**摆放来自世界包；**存档里有这件道具时存档是唯一事实源**，
  包括"它被收回了"（停用 ⇒ 注销，且不回退到种子）。
- 活动规划取锚点：`WorldAgentContext` 只从注册表拿入口（`entry(activityID:)`）。
  `manifest.activities` 里**没有**道具功能点锚点的几何，所以不存在"回退到烘焙值"这条路；
  没注册出来 = 活动不可用（`unknownActivity`）。路点解析：锚点上恰好有烘焙路点就用它
  （种子摆放下与旧路线逐字一致），否则"最近可站立路点 + 一段碰撞校验过的最后接近"。

## 3. 重注册的时机与原子性

注册表是**纯值**：由（声明，摆放）一次性派生，没有增量状态，所以**不存在半注册**。
"新位置不行"的回滚 = 保留旧值（旧值始终完整可用）。

| 事件 | 发生什么 |
|---|---|
| 摆放/移动 | 判定在**候选状态**上跑（先试算）；提交成功后从新状态重建注册表 |
| 撤销 | 同摆放（`layoutUndo` 走同一条 `commitPropLayout`） |
| 收回 | `isEnabled = false` ⇒ 该件全部锚点注销；正在跑的活动在提交时被中止 |
| 加载存档 | `WorldState` 恢复后重建（种子只在存档里没有这件道具时生效） |
| 换世界 | 新上下文的声明与状态一起换；注册表随之重建 |
| 判定校验 | 只用候选状态派生出来的锚点（含这件道具**自己**的新位置） |
| 失败 | 提交抛错 ⇒ 状态、碰撞、执行器、注册表**一个字节都不动** |

注册表派生本身失败（角色重复、两件道具抢同一个活动入口、摆放坐标非有限）⇒
保留旧注册表并记录原因（`propAnchorRegistryFault`），绝不发布"一半新一半旧"。

## 4. 校验如何复用

「这个位置能不能放」= `ResidentPropPlacementService.validate`，其中路点判据仍是
`WorldPlacementRouteMap`（格子图 BFS），只是锚点集合变成
**世界固有锚点（烘焙） ∪ 候选状态派生出来的注册锚点**。
顺序天然是「先试算、后提交」：

1. `previewState` / `preview` 在 `WorldSimulation(restoring:)` 的副本上施加摆放；
2. `validate(候选)` 从候选 `objectStates` 派生注册表 → 合并锚点 → `decision(...)`；
3. 只有全过才 `persistence.save(candidate)` + 发布，然后重建注册表。

于是"移动后居民还走得到新的取物点吗"和"别把走廊堵死"是同一条判据，
拒绝理由直接点名**注册出来的锚点**（`wish_machine.device#pickup`），而不是某个烘焙路点。

## 5. 迁移

- `jukebox.json` / `wish-machine.json`：删掉 `pickupPosition`/`pickupYaw`/`outletPosition`
  （世界坐标），改成 `functionPoints`（局部坐标 + 角色）；`world.json` 里两个活动的
  `entryWaypointID` + `transform` 删掉，改成 `functionPoint: {propID}`。
  `activities` / `activityDefinitions` 的 id、动作、相位契约**一个字没改**，
  所以 `music.listen` / `wish_machine.collect` 对工具、TTS、协调器都无缝。
- 数值等价（实测断言）：种子摆放下 `wish_machine.device#pickup` == 旧 `wish_machine.pickup`
  路点（误差 < 1 mm），`prop.jukebox#interact` == 旧 `wp.jukebox`（< 1 mm），
  朝向也逐位相同。
- 作者源头 `authoring/worlds/marble-living-cabin/layout.json` 同步迁移（同一个声明结构）。
- **保留为世界固有**：`home.idle`(`wp.spawn`)、`home.walk`(`wp.center`)、
  `performance.*`(`wp.spawn`)。它们与居民/环境绑定，不随任何道具；`wp.jukebox`、
  `wish_machine.pickup` 仍是普通导航路点（路线数据），但**不再是任何活动的入口真相**。
- 过渡期边界（明确列出，不留两套真相）：
  - `WishMachineScene` 的视觉放置/取物点/出货口已改为**从声明派生**（`install(declaration:)`），
    App 里不再有第二份数字；声明缺失 ⇒ 机器不出现、输出不渲染（fail-closed）。
  - **未迁移**：`WishMachineOutputRenderer` 的出货口读的是声明的**种子**摆放，
    不是注册表里当前摆放的 `outlet` 锚点 —— 真机上把许愿机搬走之后，活动与人会跟着走，
    生成物件的落点还留在种子位置。许愿机目前不是可摆放物件（没有 `objectStates`），
    所以这条现在不会触发；要做"可搬走的许愿机"时，把出口传成
    `context.propAnchorRegistry.anchor(objectID:role:)?.position` 即可。
  - **未迁移**：`collision.jukebox` / `resident.display_table.collision` 仍是世界包里的
    碰撞体积；`prop.jukebox` 的摆放还没有 `objectStates`（音箱在 App 里仍是固定场景节点）。

## 6. 风险（最可能出错的地方）

1. **活动进行中移动设备**：锚点从居民脚下移走。已处理：提交时按候选锚点重算，
   位置变了/消失了/不可站 ⇒ 中止该次活动（不是让居民在旧入口上等回执）。
2. **路线缓存失效**：`navigationTraversalCache` 在碰撞/布局提交后清空；
   注册表变化也在这条路径上。漏清 ⇒ 用旧障碍规划。
3. **世界切换**：注册表随上下文重建；声明来自各自的世界包。跨世界残留 = 用错声明。
4. **多件同角色/同活动道具**：两件道具抢同一个活动入口 ⇒ **拒绝**（
   `activityEntryConflict`），绝不"取最近的一个"。同一声明里角色重复 ⇒ 拒绝。
5. **声明与烘焙值分叉**：已用 `WorldActivityEntry` 消除（结构上只能有一份几何）；
   校验器还会在装载期检查 `functionPoint` 指向的道具真的能读出声明，
   否则拒绝装载（不留下"活动悄悄没有锚点"）。
6. **种子摆放被当成事实源**：存档里一旦有这件道具（含"停用"），种子就不再参与；
   这条错了会让收回的道具"复活"锚点，harness 专门盯它。
