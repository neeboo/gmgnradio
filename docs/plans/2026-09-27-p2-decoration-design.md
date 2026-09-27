# P2 设计：装修可玩性（摆放面派生）

日期：2026-09-27
状态：设计待实施
上游：`docs/plans/2026-09-27-space-first-plan.md` 的 P2
前置：P0（仓库止血）与 P1（默认呈现面）已完成并推送

## 1. 问题

"让大家把装修搞起来"卡在三个具体的地方，全部已核实：

| # | 卡点 | 证据 |
| --- | --- | --- |
| 1 | 同时只能摆 **4 件** | `WorldSimulation.swift:142` 与 `:175` 两处 `guard count < 4 else { throw WorldPropLayoutError.visibleLimit }` |
| 2 | 只有 **2 个手写摆放面**，且写死在这间屋子 | `ResidentPropPlacementConfiguration.swift`：`resident.floor`（中心 `(-2.6,-0.03,-3)`，半尺寸 `(0.4,0,0.5)` = 0.8 m × 1.0 m）与 `resident.display_table`。注释自陈 "verified against this cabin's shipped collider" |
| 3 | 摆放面被哈希锁进导航烘焙门禁 | `build-package.mjs:69` 对 `ResidentPropPlacementConfiguration.swift` 取 SHA-256 写入 `navigation.source`，`:72` 不匹配即抛 "Baked navigation is stale" |

第 3 条的因果是**反的**，这是本设计的核心：

```text
手写摆放面  ──是──▶  导航烘焙的【输入】
                    （cabinSupportReservationIntersects 在面周围预留 0.25 / 0.30 m 净空，
                      让 waypoint 不生成在摆放区里）
```

所以"改摆放面 → 导航失效"不是官僚主义，是**真实的依赖**。自由装修要求摆放面不是手写常量。

## 2. 当前模型的完整形状（已核实）

**摆放校验**（`ResidentPropPlacementService`，213 行）依次判：

1. `unknownSurface` / `outsideSurface` — 必须落在某个手写面内；
2. `collision(name)` — 不撞居民或其它物件；
3. `blockedRoute(name)` — **不挡活动入口或通道**；
4. 手持另有 `avatarUnavailable` / `attachmentUnsupported` / `propTooLarge`（>45 cm 只能摆放）等。

**几何能力已经具备**（不需要新建）：

- `WorldRuntime` 已有 `TriangleMeshCollisionWorld`（483 行）、`GLBColliderDecoder`（446 行）、`CollisionVolumeWorld`（236 行）、`ReplaceableCollisionWorld`（43 行）、`WorldGeometry`（111 行）。
- `tools/navigation/LivingCabinNavigation.swift` 已在用同一套原语做格子扫描：`report.surfaceCandidates = 2421`、`blockedCandidates = 729`、`supportReservedCandidates`，以及 `cabinSupportReservationIntersects`。

**关键区分**：烘焙器的 `surfaceCandidates` 判据是"**胶囊能否站立**"（`physics.canOccupy(capsule, at:)`），**不是**"物件能否放置"。两者共用同一套几何原语，但判定条件不同（承托面积、物件包围盒、净空高度）。所以这是**复用原语、新增判据**，不是新建能力。

## 3. 目标模型

摆放面从**碰撞几何在运行时派生**，不再手写、不再作为手写文件参与门禁。

```text
collider.glb ──▶ TriangleMeshCollisionWorld
                      │
                      ├─▶ （既有）导航烘焙：胶囊可站立 ──▶ waypoints/routes
                      │
                      └─▶ （新增）PropSupportGrid：可承托 + 净空 + 不撞阻挡体积
                                     │
                                     └─▶ 用户选格 + 面内偏移 + 旋转
```

派生输出 `PropSupportGrid`：每个格子记录承托高度层（一列可能有多层：地面、桌面、台阶）、该层的可用净空、以及是否允许放置。

**派生放在 `WorldRuntime`**（保持 Foundation-only），因此可以离线单测，且烘焙器能复用同一实现 —— 这一点很重要，见 §4 取舍 3。

## 4. 三个必须现在决定的取舍

### 取舍 1：物件是否阻挡导航？

这在今天已经是**真实约束**（`blockedRoute`），自由摆放会让它变尖锐：20 件物件可以把点唱机围死。

| 方案 | 代价 |
| --- | --- |
| (a) 物件成为导航障碍，运行时重规划 | 每摆一件都可能让既有权图失效；路径重算成本随物件数增长 |
| (b) 物件**不阻挡通行**，但放置时**禁止切断连通性** | 需要一个可达性检查；不需要重烘焙 |
| (c) 完全不管 | 用户能把居民关在外面，且看起来像 bug |

**建议 (b)。** 理由：保留"不许把点唱机围死"这条用户能理解的约束，又不需要重烘焙；而连通性检查可以由已有的 `WaypointNavigationGraph`（309 行，含 `route(from:to:canTraverse:)` 与惰性重规划）直接做。

具体判据：以本次放置为障碍重算一次可达性，若**任一活动入口**（`activity.entry`，共 6 个活动）从 `wp.spawn` 变为不可达，则拒绝并给出可读原因（复用 `blockedRoute` 文案风格）。

### 取舍 2：上限提到多少？

**先 20，压测后再定。** p95 帧率不达标就回到 10，不带病上线（`FrameRateSampler` 已有 p95）。

注意这不只是改数字：`objectStates` 是字典（无碍），但渲染路径（`ResidentPropRenderer` / `MarbleSpatialView`）与派生格子的承托判定要跟得上。

### 取舍 3：手写面消失后，烘焙门禁锁什么？

门禁**必须保留**（它防的是"用旧导航配新碰撞"），但锁的对象要改：

| | 现在 | 改成 |
| --- | --- | --- |
| 锁 | `ResidentPropPlacementConfiguration.swift` 的文件字节 | `collider.glb` SHA-256、`framing`、`collisionVolumes`、`manualWaypoints`，**加上派生算法版本号 + 派生参数** |

这样门禁锁的是**输入与算法**，而不是手写产物。用户摆放不再可能让导航失效，但"碰撞几何或派生规则变了"仍然会被抓住。

**并且**：烘焙时的 `supportReservation` 继续保留，但它的输入从"手写面"改成"**同一套派生实现算出的面**"。这保证导航与摆放不会互相踩（waypoint 不生成在合法摆放区里），而两边用的是同一个真相。

> 这一条是本设计里最容易做错的地方：如果烘焙时去掉了 supportReservation，waypoint 会生成在原摆放区里，之后用户在那儿放东西就会出现"导航点落在物件内部"的诡异状态。

## 5. 工作分解

| # | 工作 | 位置 | 验收 |
| --- | --- | --- | --- |
| 1 | `PropSupportGrid`：从碰撞几何派生可放置格子 + 查询接口 | `Packages/WorldRuntime` | 单测：同一几何必产出同一网格（确定性）；多高度层（地面/桌面）；非平地承托 |
| 2 | 烘焙器改用同一派生实现；门禁改锁输入 + 派生版本 | `tools/navigation/LivingCabinNavigation.swift`、`authoring/.../build-package.mjs` | Python 守卫测试仍能重建出 committed world.json（`test_cabin_navigation_package.py`） |
| 3 | **重烘焙一次** `marble-living-cabin` 并核对 report | `authoring/` + `Resources/Worlds/` | `triangleCount 161600` / `waypointCount` / `bidirectionalEdgeCount` 与预期一致或有据可查的变化 |
| 4 | 上限 4 → 20 | `WorldSimulation.swift` 两处 | `WorldPropLayout` 既有 12 项测试不回归；新增上限行为测试 |
| 5 | 摆放校验：从"选面"改为"格子 + 面内偏移"；保留 collision / blockedRoute，新增连通性检查（取舍 1b） | `ResidentPropPlacementService.swift` | 新增：切断连通性被拒绝；合法放置仍通过 |
| 6 | 编辑器 UX：格子高亮 → 拖放 → 旋转 → 吸附 → 撤销 | `ResidentPropEditorView/State`（现 121 + 224 行） | **真人鼠标手感确认**，离线测试不代替 |
| 7 | 回归 | — | `make test-all` 全绿；`make build` 成功 |

顺序上 **1 → 2 → 3 必须串行**（3 依赖 2，2 依赖 1）；4 与 5 依赖 1；6 依赖 5。

## 6. 验收

- 一个没玩过的人，**5 分钟内自己摆 10 件物件**，无需指导（需真人）。
- 摆放过程中 60 fps 不塌（p95）。
- 摆完退出重进，位置与朝向完整保留。
- **改摆放面不再导致导航失效。**
- `make test-all` 全绿；`WorldRuntime` 测试 ≥143 + 新增。

## 7. 非目标

- 不做任意 GLB 家具系统（点唱机等仍是专用实现）。
- 不做物理仿真（无重力掉落、无堆叠、无碰撞反弹）。
- 不做分享/导入（那是 P3）。
- 不做多 agent 同场。

## 8. 风险

| 风险 | 缓解 |
| --- | --- |
| 去掉 supportReservation 旧语义 → 导航点落在摆放区 | 保留它，只把输入换成派生面（取舍 3） |
| 上限提升撞渲染性能 | 先压测 20；不达标回 10 |
| 多高度层（桌面/台阶）承托语义不清 | 派生输出显式带"层"，放置时用户选层 |
| 连通性检查成本随物件数增长 | 只在放置时算一次；`WaypointNavigationGraph` 已有惰性重规划与缓存 |
| 重烘焙产出与既有 `layout.json` 不一致 | 先跑 `test_cabin_navigation_package.py` 的重建比对，再动 app 资源 |
| 真人手感无法离线验证 | 明确列为真人验收项，不用状态测试顶替 |
