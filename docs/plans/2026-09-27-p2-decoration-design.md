# P2 设计：装修可玩性（Sims 式格子摆放）

日期：2026-09-27（修订）
状态：待实施
上游：`docs/plans/2026-09-27-space-first-plan.md` 的 P2
前置：P0（仓库止血）与 P1（默认呈现面）已完成并推送

## 0. 标准

> **要像 The Sims 那样才算 OK。**

具体是这五条，后文全部围绕它们：

1. **进建造模式 → 整个房间浮出格子**，不是几个画好的小方块。
2. **不限件数**。你能放多少由房间和你的耐心决定，不由渲染预算决定。
3. **鼠标直接指着放**：悬停高亮、绿/红判定、吸附到格、一键旋转。
4. **格子被墙和家具正确遮挡**，不是浮在画面最上层。
5. **退出重进，东西还在原处。**

## 1. 问题（已核实）

| # | 卡点 | 证据 |
| --- | --- | --- |
| 1 | 同时只能摆 **4 件** | `WorldSimulation.swift:142`、`:175`；`ResidentPropPlacementService.swift:144`；**另有 2 处静默截断**：`ResidentPropRenderer.swift:53`（`removeLast()`）、`WishMachineOutputDescriptor.swift:49`（`.prefix(4)`） |
| 2 | 只有 **2 个手写摆放面**，写死在这间屋子 | `ResidentPropPlacementConfiguration.swift`：`resident.floor`（0.8 m × 1.0 m）与 `resident.display_table` |
| 3 | 摆放面被哈希锁进导航烘焙门禁 | `build-package.mjs:69` 对该 Swift 文件取 SHA-256 写入 `navigation.source`，`:72` 不匹配即 "Baked navigation is stale" |

**这不是技术限制，是刻意的范围缩小。** 出处：`todos/002-ready-p2-generated-prop-placement.md:29`

> "**先批准一块地面和一张独立展示台**……**至多四件同时摆出**，其他留在物件库。手持、网页、交易和**完整装修不在本批范围**。"

那一批的目的是跑通"生成 → 领取 → 摆放 → 存档"链路。P2 就是那句**完整装修**。

**差距**：房间地面 13.5 m × 23.0 m = **310 m²**；可站立格点 2,421 个 ≈ 605 m²（含桌面、多层）；当前可放 **1.39 m² = 0.23%**。

## 2. 几何事实

| 事实 | 值 | 来源 |
| --- | --- | --- |
| 房间地面范围 | 13.5 m × 23.0 m | `layout.json` → `navigation.report.groundBounds` |
| 可站立格点 | 2,421（0.5 m 间距） | 同上 |
| 碰撞网格 | 161,600 三角形 | `MarbleLivingCabinPackageTests` 实测 |
| 被拒格点 | `capsuleCollision` 104、`meshTraversal` 69、`combinedTraversal` 61、`stepHeight` 15、`supportReservation` 3、`missingGround` 1 | `report.rejectedEdges` |

## 3. 三个决定

### 决定 1：物件不阻挡通行，但放置不得切断连通性

今天已经是**半约束**（`blockedRoute`）。放开后会变尖锐：物件多了能把点唱机围死。

| 方案 | 代价 |
| --- | --- |
| (a) 物件成为导航障碍 | 每放一件都要重算走路地图；放置时卡顿 |
| **(b) 物件不阻挡通行，但放置时禁止切断活动入口连通性** | 只需一次可达性检查；不重烘焙 |
| (c) 完全不管 | 用户能把角色关在外面，像 bug |

**采用 (b)。** 判据：以本次放置为附加障碍，检查 6 个活动入口是否仍能从 `wp.spawn` 到达；不可达则拒绝并给出可读原因。用已有的 `WaypointNavigationGraph`（309 行，含惰性重规划）。

代价说清楚：**角色会从你放的家具上走过去。** 对一个以装修为主的功能，这比角色卡在半路好。

### 决定 2：取消件数上限

**不是调大，是取消。** 删掉 §1 表格里全部 5 处，并删掉 `WorldPropLayoutError.visibleLimit`（它保护的是一个不该存在的约束）。

**并确立一条原则：**

> **渲染预算永远不该变成"你不许放"。**

渲染端按距离与重要性裁剪（近处优先、远处淡出），必要时降级；**绝不因渲染理由拒绝用户的放置**。因此压测决定的是「同时可见多少、多远内可见」，不是「能放多少」。

### 决定 3：门禁改锁输入与算法，不再锁手写产物

| | 现在 | 改成 |
| --- | --- | --- |
| 哈希对象 | `ResidentPropPlacementConfiguration.swift` 的字节 | `collider.glb` SHA-256、`framing`、`collisionVolumes`、`manualWaypoints`、**派生算法版本号 + 派生参数** |

**并且**：烘焙时的 `supportReservation` **保留**，但输入从"手写面"改为"**同一套派生实现算出的面**"。这保证导航点不会生成在合法摆放区里，两边用同一个真相。

> 这是最容易做错的一处：若烘焙时去掉 `supportReservation`，waypoint 会生成在摆放区里，之后用户在那儿放东西就会出现"导航点落在物件内部"。

## 4. 为什么摆放面必须派生（而不是删掉）

依赖方向是**反的**，这是本设计的核心：

```text
手写摆放面 ──是──▶ 导航烘焙的【输入】
                  cabinSupportReservationIntersects 在每个面周围预留 0.25 / 0.30 m 净空，
                  让 waypoint 不生成在摆放区里
```

所以"改摆放面 → 导航失效"不是官僚主义，是真实依赖。自由装修要求摆放面不是手写常量；正确解法是让**派生面成为导航与摆放的共同真相**。

## 5. 格子怎么看到（Sims 标准）

### 5.1 现状（已核实）

- **完全没有任何 3D 鼠标拾取**：`MarbleSpatialView.swift`（3,080 行）里只有一个 `hitTest`（:1049），没有 `mouseDragged` / `mouseMoved` / 射线求交。今天的摆放是"在下拉框里选一个命名的面"。
- **但深度缓冲已共用**：`ResidentPropRenderer` 用 `depthAttachment.storeAction = .store` + reversed depth（:130 / :182）。**所以格子画进同一个 pass 就会被墙和家具正确遮挡**——标准第 4 条几乎免费。

### 5.2 设计

| 项 | 设计 |
| --- | --- |
| 出现时机 | **建造模式开关**。生活模式不显示 |
| 画在哪 | 派生出的承托面。**一层一个平面**：地面、桌面、台阶 |
| 怎么画 | 实例化四边形（一格一个 quad），同一深度缓冲 + 深度测试；按距离淡出；贴地抬高约 1 mm 防 z-fighting |
| 颜色 | 🟢 可放 · 🔴 不可放（插墙/家具、越界） · 🟡 悬停格 + 物件 footprint · ⬜ 已被占用 |
| 怎么选 | **光标射线 → 与格子平面求交 → 取最近命中**。纯 CPU，不做 GPU readback。矩阵取自 `StageCameraCoordinator` / `StageUniforms` |
| 吸附 / 旋转 | 位置吸附到格；旋转默认 **90° 步进**，修饰键自由转 |
| 多格占用 | footprint 由物件 `size` 算（0.45 m 物件在 0.25 m 格上占 **2×2**），**整块一起高亮、一起变绿/红** |
| 键盘 | 旋转 / Esc 取消 / Delete 收回 / 撤销（复用已有单槽 undo） |

### 5.3 间距不必与导航相同

| 网格 | 间距 | 理由 |
| --- | --- | --- |
| 导航 | 0.5 m | 只需"角色能站" |
| **摆放** | **0.25 m 起步**（小物件可到 0.1 m） | 需要贴合物件尺寸 |

两者只在**"哪些区域要预留"这个粗粒度问题**上必须一致——这正是让烘焙器复用同一份派生结果的原因。

### 5.4 连续性

今天编辑器里的 2 个"面"（`ResidentPropEditorSurface`）**正好对应未来的 2 个"层"**。UI 上那个"选面"下拉框不用删，升级为"选层"（地面 / 桌面 / 台阶）：用户习惯不变，只是每层从 0.8 m 小方块变成整片区域。

## 6. 实施约束（已核实，直接影响可行性）

### 6.1 `canPlace` 是 O(三角形数)，必须做空间分桶

`WorldPropMeshClearance.canPlace(box:supportHeight:triangles:)` 会遍历**传入的全部**三角形。它的文档注释已经写明：

> "Placement-only triangle/box test. **Callers cache the local triangles for authored support regions.**"

若对 2,000 格 × 161,600 三角形直接调用 = **3.2 亿次**检测，不可行。

**解法**：`TriangleMeshCollisionWorld` 内部**已经有** 0.25 m 的三角形空间哈希（`Cell` + `candidateIndices`），但 `triangles` 是 `private`。需要**加一个公开的按范围取三角形的方法**。

> 这个测试还要求 `abs(q.x) < 0.0001 && abs(q.z) < 0.0001`（只支持 yaw 旋转），并且**允许与承托面接触、但拒绝任何穿入物件的三角形**。正好是摆放校验要的语义。

### 6.2 需要一个新的窄协议

```swift
/// 摆放派生需要三角形几何，而 WorldCollisionQuerying 只有胶囊查询。
/// CollisionVolumeWorld 没有三角形，因此不实现它。
public protocol WorldPropSupportQuerying: WorldCollisionQuerying {
    func triangles(in bounds: WorldPlanarBounds) -> [WorldTriangle]
}
```

由 `TriangleMeshCollisionWorld` 与 `ReplaceableCollisionWorld` 实现。`CollisionVolumeWorld` 不实现（摆放派生要求网格几何）。

### 6.3 摆设校验要同时覆盖网格与阻挡体积

`collider.glb` 是环境；但点唱机、许愿机、展示台是**独立的** `WorldCollisionVolume`（`isBlocking: true`）。所以格子判定必须两样都测：

- 网格：`WorldPropMeshClearance.canPlace`
- 体积：盒 vs 盒（**目前无现成实现**，需新增一个 OBB-OBB SAT 辅助，约 30 行）

## 7. 工作分解

| # | 工作 | 位置 | 验收 |
| --- | --- | --- | --- |
| 1 | `WorldPlanarBounds` + `WorldPropSupportQuerying` + 三角形范围查询 | `WorldRuntime` | 单测：范围查询返回的三角形与暴力全量筛选一致 |
| 2 | `PropSupportGrid` 派生：多层枚举 + 网格/体积校验 + 确定性 | `WorldRuntime` | 单测：同一几何必产出同一网格；地面/桌面/台阶多层；插墙格被拒；跨列确定性 |
| 3 | 物件 footprint 与放置判定（含多格占据、占用互斥） | `WorldRuntime` | 单测：2×2 footprint 整块判定；重叠被拒；旋转 90° 后 footprint 正确 |
| 4 | 烘焙器改用同一派生；门禁改锁输入 + 算法版本 | `tools/navigation/`、`build-package.mjs` | Python 守卫仍能重建 committed world.json |
| 5 | **重烘焙一次** `marble-living-cabin`，核对 report | `authoring/` + `Resources/` | `triangleCount 161600` / waypoint / edge 数与预期一致或有据可查 |
| 6 | 删除 5 处件数限制与 `visibleLimit` | `WorldSimulation`、`ResidentPropPlacementService`、`ResidentPropRenderer`、`WishMachineOutputDescriptor` | 放 30 件全部可见、可存档；既有 12 项 `WorldPropLayout` 测试不回归 |
| 7 | 格子渲染 pass（实例化 quad + 距离淡出 + 深度测试） | `ResidentPropRenderer` 旁 | 视觉验收：被墙遮挡、不闪烁、60 fps |
| 8 | 光标拾取：射线 → 格子平面求交 → 最近命中 | 渲染/相机层 | 悬停高亮跟手；远处格子也能选中 |
| 9 | 编辑器改成"格子 + footprint"（保留不碰撞 + 连通性检查） | `ResidentPropEditorState/Service` + `View` | 悬停绿/红正确；吸附；90° 旋转；Esc/Delete/撤销 |
| 10 | 回归 | — | `make test-all` 全绿；`make build` 成功 |

**串行**：1 → 2 → 3；4 → 5；6 依赖 2/3；7、8、9 依赖 2/3。
**可并行**：6 与 7/8/9 无依赖关系。

## 8. 验收（Sims 标准逐条）

| # | 标准 | 怎么验 |
| --- | --- | --- |
| 1 | 进建造模式整个房间浮出格子 | 真人看 |
| 2 | 不限件数 | 放 30 件，全部可见、可存档、可再进入 |
| 3 | 鼠标指着放：悬停高亮、绿红判定、吸附、旋转 | **真人手感**（测试不能代替） |
| 4 | 格子被墙/家具正确遮挡 | 真人看；以及深度测试的离线检查 |
| 5 | 退出重进还在原处 | 离线可测（`WorldStatePersistence` 原子 JSON） |
| 附加 | 改摆放面不再让导航失效 | 门禁测试 |
| 附加 | `make test-all` 全绿 | 自动 |

**第 3 条只有真人能判**，明确列为真人验收，不用状态测试顶替。

## 9. 非目标

- 不做任意 GLB 家具系统（点唱机等仍是专用实现）。
- 不做物理仿真（无重力掉落、无堆叠、无碰撞反弹）。
- 不做墙体物件（挂画、壁灯）——Sims 有墙格，本期不做。
- 不做分享 / 导入（那是 P3）。
- 不做多 agent 同场。

## 10. 风险

| 风险 | 缓解 |
| --- | --- |
| `canPlace` 全量遍历导致不可用 | §6.1 的空间分桶必须先做（工作项 1） |
| 去除 `supportReservation` 旧语义 → 导航点落在摆放区 | 保留它，只把输入换成派生面（决定 3） |
| 格子数量大导致渲染/拾取变慢 | 距离裁剪 + 分块上传；拾取按层过滤 |
| 多高度层（桌面/台阶）语义不清 | 派生输出显式带"层"，UI 选层 |
| 连通性检查随物件数增长 | 只在放置时算一次；`WaypointNavigationGraph` 已有惰性与缓存 |
| 重烘焙产出与既有 `layout.json` 不一致 | 先跑 `test_cabin_navigation_package.py` 的重建比对再动 app 资源 |
| 真人手感无法离线验证 | 明确列为真人验收项 |
